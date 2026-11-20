import Foundation

public enum RunnerError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case launchFailed(String)
    case commandFailed(code: Int32, stderr: String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The transcribe worker is already running."
        case .launchFailed(let why): "Could not start transcribe: \(why)"
        case .commandFailed(let code, let stderr): "transcribe exited with code \(code). \(stderr)"
        case .invalidOutput: "transcribe printed output this app could not read."
        }
    }
}

/// Runs short CLI helper commands (`doctor --json`, `backends --json`). Transcription itself
/// goes through `WorkerClient` (`transcribe serve`).
public actor CLIHelper {
    public let command: CLICommand

    public init(command: CLICommand) {
        self.command = command
    }

    /// Runs a short helper command (`doctor --json`, `backends --json`) and returns stdout.
    /// `doctor` exits 3 when it finds problems but still prints its report, so stdout is
    /// returned whenever there is some.
    public func output(of arguments: [String], timeout: TimeInterval = 60) async throws -> Data {
        let proc = makeProcess(arguments: arguments)
        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice
        let collector = HelperCollector()
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            collector.onFinish = { cont.resume(returning: $0) }
            stdout.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; collector.outClosed() } else { collector.appendOut(d) }
            }
            stderr.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; collector.errClosed() } else { collector.appendErr(d) }
            }
            proc.terminationHandler = { p in collector.exited(p.terminationStatus) }
            do { try proc.run() } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.onFinish = nil
                cont.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
                return
            }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [proc] in
                if proc.isRunning { proc.terminate() }
            }
        }
        let out = collector.out
        if out.isEmpty {
            throw RunnerError.commandFailed(code: status, stderr: String(decoding: collector.err, as: UTF8.self))
        }
        return out
    }

    public func doctor() async throws -> DoctorReport {
        let data = try await output(of: ["doctor", "--json"])
        guard let report = try? JSONDecoder().decode(DoctorReport.self, from: data) else { throw RunnerError.invalidOutput }
        return report
    }

    public func backends() async throws -> BackendsReport {
        let data = try await output(of: ["backends", "--json"])
        guard let report = try? JSONDecoder().decode(BackendsReport.self, from: data) else { throw RunnerError.invalidOutput }
        return report
    }

    private func makeProcess(arguments: [String]) -> Process {
        let proc = Process()
        proc.executableURL = command.executable
        proc.arguments = command.leadingArguments + arguments
        proc.environment = command.environment
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        return proc
    }
}

private final class HelperCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    private var openPipes = 2
    private var status: Int32?
    var onFinish: ((Int32) -> Void)?

    func appendOut(_ d: Data) { lock.withLock { _out.append(d) } }
    func appendErr(_ d: Data) { lock.withLock { _err.append(d) } }
    func outClosed() { closePipe() }
    func errClosed() { closePipe() }
    func exited(_ code: Int32) {
        lock.withLock { status = code }
        finishIfReady()
        // Don't hang if something else keeps a pipe open.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock { openPipes = 0 }
            finishIfReady()
        }
    }
    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }

    private func closePipe() {
        lock.withLock { openPipes -= 1 }
        finishIfReady()
    }

    private func finishIfReady() {
        let fire: ((Int32) -> Void)?, code: Int32
        lock.lock()
        if let status, openPipes <= 0, let f = onFinish { fire = f; code = status; onFinish = nil } else { fire = nil; code = 0 }
        lock.unlock()
        fire?(code)
    }
}
