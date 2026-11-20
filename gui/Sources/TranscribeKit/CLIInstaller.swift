import Foundation

/// The `transcribe` CLI version, as printed by `transcribe --version` ("transcribe 0.1.0").
public struct CLIVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var components: [Int]

    /// Parses "0.1.0", "v0.1.0" or the whole `--version` line. Pre-release suffixes
    /// ("0.2.0rc1", "0.2.0.dev3") are dropped from the last component.
    public init?(_ text: String) {
        let word = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let bare = word.hasPrefix("v") ? String(word.dropFirst()) : word
        var parts: [Int] = []
        for piece in bare.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = piece.prefix(while: \.isNumber)
            guard let n = Int(digits) else { break }
            parts.append(n)
            if digits.count != piece.count { break }
        }
        guard !parts.isEmpty else { return nil }
        components = parts
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Missing components count as 0, so 0.1 == 0.1.0.
    public static func < (a: CLIVersion, b: CLIVersion) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: CLIVersion, b: CLIVersion) -> Bool { !(a < b) && !(b < a) }
}

/// Installs or updates the `transcribe` CLI with `uv tool install`, from the wheel bundled
/// in Transcrio.app (release builds) or the release download (development bundles).
public enum CLIInstaller {
    public static let releaseBaseURL = "https://github.com/gitkeniwo/transcrio/releases/download"
    /// Shown, with Copy Command, when uv is missing.
    public static let uvInstallCommand = "brew install uv"
    /// The Python the CLI runs on (MLX wheels exist for it).
    public static let python = "3.12"

    /// What `uv tool install` installs from: a wheel file or its release URL.
    public enum Source: Sendable, Equatable {
        case bundledWheel(URL)
        case release(URL)

        public var argument: String {
            switch self {
            case .bundledWheel(let url): url.path
            case .release(let url): url.absoluteString
            }
        }
    }

    public static func wheelFileName(version: String) -> String { "transcribe-\(version)-py3-none-any.whl" }

    public static func releaseWheelURL(version: String) -> URL {
        URL(string: "\(releaseBaseURL)/v\(version)/\(wheelFileName(version: version))")!
    }

    /// The version in a wheel file name ("transcribe-0.1.0-py3-none-any.whl" → 0.1.0).
    public static func wheelVersion(_ fileName: String) -> CLIVersion? {
        guard fileName.hasPrefix("transcribe-"), fileName.hasSuffix(".whl") else { return nil }
        let parts = fileName.dropFirst("transcribe-".count).split(separator: "-")
        return parts.first.flatMap { CLIVersion(String($0)) }
    }

    /// The newest `transcribe-*.whl` in `directory` (the app's Resources), if any.
    public static func bundledWheel(in directory: URL?, fileManager: FileManager = .default) -> URL? {
        guard let directory, let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.compactMap { name in wheelVersion(name).map { (name, $0) } }
            .max { $0.1 < $1.1 }
            .map { directory.appendingPathComponent($0.0) }
    }

    /// The bundled wheel, else the release wheel for the app's version. Nil when neither is
    /// known (`swift run` has no Info.plist version).
    public static func source(bundledWheel: URL?, appVersion: String?) -> Source? {
        if let bundledWheel { return .bundledWheel(bundledWheel) }
        if let v = appVersion.flatMap(CLIVersion.init) { return .release(releaseWheelURL(version: v.description)) }
        return nil
    }

    public static func arguments(for source: Source) -> [String] {
        ["tool", "install", "--force", "--python", python, source.argument]
    }

    /// `uv tool install --force --python 3.12 <wheel>` with the locator's explicit PATH.
    /// The inherited environment passes through, so `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR`
    /// redirect the install (tests use them to leave `~/.local/bin` alone).
    public static func command(uv: String, source: Source, locator: CLILocator) -> CLICommand {
        var env = locator.childEnvironment
        env["NO_COLOR"] = "1"
        return CLICommand(executable: URL(fileURLWithPath: uv), leadingArguments: arguments(for: source),
                          environment: env, source: .localBin)
    }

    /// Whether the located CLI should match the app's version: only the uv tool install
    /// Transcrio manages (not a Settings override, the dev `uv run` fallback or `TRANSCRIBE_CLI`).
    public static func checksVersion(of source: CLICommand.Source) -> Bool { source == .localBin }

    /// The installed CLI's version when it differs from the app's, else nil (also nil when
    /// either version is unreadable).
    public static func mismatch(cliOutput: String, appVersion: String?) -> CLIVersion? {
        guard let installed = CLIVersion(cliOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
              let app = appVersion.flatMap(CLIVersion.init), installed != app else { return nil }
        return installed
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    /// The last output lines (stdout and stderr interleaved).
    public var tail: [String]
}

/// Runs a command to completion, reporting each output line (stdout and stderr merged).
public enum StreamingProcess {
    public static func run(_ command: CLICommand, tailLines: Int = 12,
                           onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = command.executable
        proc.arguments = command.leadingArguments
        proc.environment = command.environment
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let state = LineState(limit: tailLines, onLine: onLine)
        return try await withCheckedThrowingContinuation { cont in
            let done = DispatchGroup()
            done.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    state.finish()
                    done.leave()
                } else {
                    state.append(d)
                }
            }
            done.enter()
            proc.terminationHandler = { _ in done.leave() }
            do { try proc.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
                return
            }
            try? pipe.fileHandleForWriting.close()
            done.notify(queue: .global()) {
                cont.resume(returning: ProcessResult(status: proc.terminationStatus, tail: state.tail))
            }
        }
    }
}

private final class LineState: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = NDJSONLineSplitter()
    private var lines: [String] = []
    private let limit: Int
    private let onLine: @Sendable (String) -> Void

    init(limit: Int, onLine: @escaping @Sendable (String) -> Void) {
        self.limit = limit
        self.onLine = onLine
    }

    func append(_ d: Data) { emit(lock.withLock { splitter.append(d) }) }
    func finish() { emit(lock.withLock { splitter.finish() }) }
    var tail: [String] { lock.withLock { lines } }

    private func emit(_ new: [String]) {
        guard !new.isEmpty else { return }
        lock.withLock { lines = Array((lines + new).suffix(limit)) }
        new.forEach(onLine)
    }
}
