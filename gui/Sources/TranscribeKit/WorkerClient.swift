import Foundation

/// What the worker client reports.
public enum WorkerUpdate: Sendable, Equatable {
    case event(ServeEvent)
    /// A stdout line that isn't a serve event, or a stderr line (library noise, tracebacks).
    case stderr(String)
    /// The process ended. Always the last update of a launch.
    case exited(WorkerExit)
}

public struct WorkerExit: Sendable, Equatable {
    public var code: Int32
    public var signaled: Bool
    /// The app asked it to stop (shutdown op / terminate). Anything else is a crash.
    public var requested: Bool

    public init(code: Int32, signaled: Bool, requested: Bool) {
        self.code = code
        self.signaled = signaled
        self.requested = requested
    }

    public var isCrash: Bool { !requested }
}

/// Runs one resident `transcribe serve` process: ops go to its stdin, events come back on
/// stdout. The queue lives in the GUI, which sends one job at a time; the client only keeps
/// the pipe. After an exit (crash or shutdown) `launch()` starts a fresh worker.
public actor WorkerClient {
    public let command: CLICommand
    private var process: Process?
    private var stdin: FileHandle?
    private var shutdownRequested = false
    private var continuation: AsyncStream<WorkerUpdate>.Continuation?

    public init(command: CLICommand) {
        self.command = command
    }

    public var isRunning: Bool { process?.isRunning ?? false }
    public var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    /// Starts the worker. The stream ends after `.exited`.
    public func launch(extraArguments: [String] = []) throws -> AsyncStream<WorkerUpdate> {
        if let process, process.isRunning { throw RunnerError.alreadyRunning }
        shutdownRequested = false
        let (stream, continuation) = AsyncStream.makeStream(of: WorkerUpdate.self, bufferingPolicy: .unbounded)
        let proc = Process()
        proc.executableURL = command.executable
        proc.arguments = command.leadingArguments + ["serve"] + extraArguments
        proc.environment = command.environment
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let collector = WorkerCollector(continuation: continuation)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; collector.stdoutClosed() } else { collector.stdout(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; collector.stderrClosed() } else { collector.stderr(d) }
        }
        proc.terminationHandler = { [weak self] p in
            let signaled = p.terminationReason == .uncaughtSignal
            let code = p.terminationStatus
            Task {
                let requested = await self?.processEnded(p) ?? true
                collector.exited(WorkerExit(code: code, signaled: signaled, requested: requested))
            }
        }
        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        try? inPipe.fileHandleForReading.close()
        process = proc
        stdin = inPipe.fileHandleForWriting
        self.continuation = continuation
        return stream
    }

    /// Writes one op. False when there is no worker to receive it.
    @discardableResult
    public func send(_ op: ServeOp) -> Bool {
        guard let stdin, process?.isRunning == true else { return false }
        do {
            try stdin.write(contentsOf: op.encoded())
            return true
        } catch {
            return false  // EPIPE: the worker is going away; its exit arrives on the stream.
        }
    }

    /// `shutdown`, then SIGTERM after `grace`, then SIGKILL. Returns once the process is gone.
    public func shutdown(grace: TimeInterval = 3) async {
        guard let proc = process, proc.isRunning else { return }
        shutdownRequested = true
        send(.shutdown)
        try? stdin?.close()
        stdin = nil
        if await waitForExit(proc, timeout: grace) { return }
        proc.terminate()
        if await waitForExit(proc, timeout: 2) { return }
        kill(proc.processIdentifier, SIGKILL)
        _ = await waitForExit(proc, timeout: 2)
    }

    /// Synchronous variant for `applicationWillTerminate`, where there is no time for tasks.
    public nonisolated static func shutdownBlocking(pid: Int32, stdin: FileHandle?, grace: TimeInterval = 2) {
        if let stdin { try? stdin.write(contentsOf: ServeOp.shutdown.encoded()); try? stdin.close() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            usleep(20_000)
        }
        kill(pid, SIGTERM)
        usleep(500_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// The pid and stdin, for `shutdownBlocking`.
    public var handles: (pid: Int32, stdin: FileHandle?)? {
        guard let process, process.isRunning else { return nil }
        shutdownRequested = true
        return (process.processIdentifier, stdin)
    }

    private func waitForExit(_ proc: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !proc.isRunning
    }

    private func processEnded(_ p: Process) -> Bool {
        let requested = shutdownRequested
        if process === p {
            process = nil
            stdin = nil
            continuation = nil
        }
        return requested
    }
}

/// Splits the worker's stdout into events and forwards stderr lines; finishes the stream once
/// the process has exited and stdout reached EOF.
private final class WorkerCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<WorkerUpdate>.Continuation
    private var out = NDJSONLineSplitter()
    private var err = NDJSONLineSplitter()
    private var stdoutDone = false
    private var exit: WorkerExit?
    private var finished = false

    init(continuation: AsyncStream<WorkerUpdate>.Continuation) {
        self.continuation = continuation
    }

    func stdout(_ data: Data) {
        lock.withLock { for line in out.append(data) { emit(line) } }
    }

    func stdoutClosed() {
        lock.withLock {
            for line in out.finish() { emit(line) }
            stdoutDone = true
            finishIfReady()
        }
    }

    func stderr(_ data: Data) {
        lock.withLock { for line in err.append(data) { continuation.yield(.stderr(line)) } }
    }

    func stderrClosed() {
        lock.withLock { for line in err.finish() { continuation.yield(.stderr(line)) } }
    }

    func exited(_ status: WorkerExit) {
        lock.withLock {
            exit = status
            finishIfReady()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                stdoutDone = true
                finishIfReady()
            }
        }
    }

    private func emit(_ line: String) {
        if let event = ServeEvent.decode(line) {
            continuation.yield(.event(event))
        } else {
            continuation.yield(.stderr(line))
        }
    }

    private func finishIfReady() {
        guard !finished, let exit, stdoutDone else { return }
        finished = true
        continuation.yield(.exited(exit))
        continuation.finish()
    }
}

/// Merges worker updates that arrive in the same main-queue turn: a progress event replaces the
/// previous one for the same job, stage and chunk, and a download event replaces the previous
/// one for the same job and model. Segments and everything else are kept, in order.
public enum WorkerEventCoalescer {
    public static func coalesce(_ updates: [WorkerUpdate]) -> [WorkerUpdate] {
        var out: [WorkerUpdate] = []
        for u in updates {
            if let last = out.last, supersedes(u, last) {
                out[out.count - 1] = u
            } else {
                out.append(u)
            }
        }
        return out
    }

    static func supersedes(_ new: WorkerUpdate, _ old: WorkerUpdate) -> Bool {
        switch (new, old) {
        case (.event(.progress(let i1, let a)), .event(.progress(let i0, let b))):
            i1 == i0 && a.stageName == b.stageName && a.chunk == b.chunk && a.totalChunks == b.totalChunks
        case (.event(.download(let i1, let a)), .event(.download(let i0, let b))):
            i1 == i0 && a.model == b.model
        default:
            false
        }
    }
}
