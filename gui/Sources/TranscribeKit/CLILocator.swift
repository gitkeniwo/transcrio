import Foundation

/// How to launch the CLI: the executable, arguments that go before the `transcribe`
/// arguments, and the child environment (always with an explicit PATH).
public struct CLICommand: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// `TRANSCRIBE_CLI` environment variable (development, e.g. the fake CLI).
        case debugEnvironment
        /// The path set in Settings.
        case settingsOverride
        /// `~/.local/bin/transcribe` (from `uv tool install`; `UV_TOOL_BIN_DIR` moves it).
        case localBin
        /// `uv run --project <repo> transcribe`.
        case uvRun
    }

    public var executable: URL
    public var leadingArguments: [String]
    public var environment: [String: String]
    public var source: Source

    public init(executable: URL, leadingArguments: [String] = [], environment: [String: String], source: Source) {
        self.executable = executable
        self.leadingArguments = leadingArguments
        self.environment = environment
        self.source = source
    }

    /// Human-readable form for Settings and the Environment card.
    public var displayString: String {
        ([executable.path] + leadingArguments).joined(separator: " ")
    }
}

/// File-system checks the locator needs; injectable for tests.
public protocol FileProbe: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
}

public struct LocalFileProbe: FileProbe {
    public init() {}
    public func isExecutableFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
    public func fileExists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

public enum CLILocatorError: Error, Equatable, LocalizedError {
    case overrideNotExecutable(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .overrideNotExecutable(let p): "The CLI path set in Settings is not an executable file: \(p)"
        case .notFound: "The transcribe command was not found in ~/.local/bin."
        }
    }
}

/// Finds the CLI: Settings override → `~/.local/bin/transcribe` (uv's tool bin directory)
/// → `uv run --project <repo> transcribe`.
///
/// Apps launched from Finder get a minimal PATH, so the child environment always gets an
/// explicit PATH that includes Homebrew (ffmpeg) and `~/.local/bin`.
public struct CLILocator: Sendable {
    public static let defaultRepoPath = "~/transcrio"
    public static let debugEnvironmentKey = "TRANSCRIBE_CLI"

    public var probe: any FileProbe
    public var environment: [String: String]
    public var homeDirectory: String

    public init(probe: any FileProbe = LocalFileProbe(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: String = NSHomeDirectory()) {
        self.probe = probe
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// Where `uv tool install` puts executables: `UV_TOOL_BIN_DIR`, else `XDG_BIN_HOME`,
    /// else `~/.local/bin` (uv's own order, minus the rarely set `XDG_DATA_HOME/../bin`).
    public var toolBinDirectory: String {
        for key in ["UV_TOOL_BIN_DIR", "XDG_BIN_HOME"] {
            if let dir = environment[key], !dir.isEmpty { return expand(dir) }
        }
        return "\(homeDirectory)/.local/bin"
    }

    /// PATH entries every child process gets, before whatever PATH the app inherited.
    public var searchPath: [String] {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", toolBinDirectory, "\(homeDirectory)/.local/bin",
                     "\(homeDirectory)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (fixed + inherited).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The inherited environment with an explicit PATH.
    public var childEnvironment: [String: String] {
        var env = environment
        env["PATH"] = searchPath.joined(separator: ":")
        // Keep stderr machine-readable; the CLI also sets this for non-bar progress.
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// - Parameters:
    ///   - overridePath: the CLI path from Settings, if any.
    ///   - repoPath: the project used by the `uv run --project` fallback.
    public func locate(overridePath: String? = nil, repoPath: String? = nil) throws -> CLICommand {
        let env = childEnvironment
        if let debug = environment[Self.debugEnvironmentKey], !debug.isEmpty, probe.isExecutableFile(atPath: expand(debug)) {
            return CLICommand(executable: URL(fileURLWithPath: expand(debug)), environment: env, source: .debugEnvironment)
        }
        if let raw = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let path = expand(raw)
            guard probe.isExecutableFile(atPath: path) else { throw CLILocatorError.overrideNotExecutable(path) }
            return CLICommand(executable: URL(fileURLWithPath: path), environment: env, source: .settingsOverride)
        }
        let localBin = "\(toolBinDirectory)/transcribe"
        if probe.isExecutableFile(atPath: localBin) {
            return CLICommand(executable: URL(fileURLWithPath: localBin), environment: env, source: .localBin)
        }
        let repo = expand(repoPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.defaultRepoPath)
        if probe.fileExists(atPath: "\(repo)/pyproject.toml"), findExecutable("uv") != nil {
            // `/usr/bin/env` resolves `uv` through the explicit PATH above.
            return CLICommand(executable: URL(fileURLWithPath: "/usr/bin/env"),
                              leadingArguments: ["uv", "run", "--project", repo, "transcribe"],
                              environment: env, source: .uvRun)
        }
        throw CLILocatorError.notFound
    }

    /// First executable named `name` on `searchPath`.
    public func findExecutable(_ name: String) -> String? {
        searchPath.lazy.map { "\($0)/\(name)" }.first(where: probe.isExecutableFile(atPath:))
    }

    private func expand(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + path.dropFirst(1) }
        return path
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
