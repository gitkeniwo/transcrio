import Foundation
import Testing
@testable import TranscribeKit

@Suite struct CLIVersionTests {
    @Test func parsesVersionLine() throws {
        #expect(try #require(CLIVersion("transcribe 0.1.0")).components == [0, 1, 0])
        #expect(try #require(CLIVersion("transcribe 0.1.0\n")).description == "0.1.0")
        #expect(CLIVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(CLIVersion("0.2.0rc1")?.components == [0, 2, 0])
        #expect(CLIVersion("1.4.dev3")?.components == [1, 4])
    }

    @Test func rejectsGarbage() {
        #expect(CLIVersion("") == nil)
        #expect(CLIVersion("transcribe") == nil)
        #expect(CLIVersion("usage: transcribe [-h]") == nil)
    }

    @Test func comparesNumerically() throws {
        let v = { (s: String) in CLIVersion(s)! }
        #expect(v("0.1.0") < v("0.1.1"))
        #expect(v("0.9.0") < v("0.10.0"))
        #expect(v("0.1") == v("0.1.0"))
        #expect(!(v("1.0.0") < v("1.0.0")))
    }

    @Test func mismatchReportsTheInstalledVersion() {
        #expect(CLIInstaller.mismatch(cliOutput: "transcribe 0.1.0\n", appVersion: "0.1.1")?.description == "0.1.0")
        #expect(CLIInstaller.mismatch(cliOutput: "transcribe 0.2.0", appVersion: "0.1.1")?.description == "0.2.0")
        #expect(CLIInstaller.mismatch(cliOutput: "transcribe 0.1.0", appVersion: "0.1.0") == nil)
        #expect(CLIInstaller.mismatch(cliOutput: "", appVersion: "0.1.0") == nil)
        #expect(CLIInstaller.mismatch(cliOutput: "transcribe 0.1.0", appVersion: nil) == nil)
    }

    @Test func onlyTheManagedInstallIsVersionChecked() {
        #expect(CLIInstaller.checksVersion(of: .localBin))
        #expect(!CLIInstaller.checksVersion(of: .settingsOverride))
        #expect(!CLIInstaller.checksVersion(of: .uvRun))
        #expect(!CLIInstaller.checksVersion(of: .debugEnvironment))
    }
}

@Suite struct CLIInstallerTests {
    @Test func wheelNames() {
        #expect(CLIInstaller.wheelFileName(version: "0.1.0") == "transcribe-0.1.0-py3-none-any.whl")
        #expect(CLIInstaller.wheelVersion("transcribe-0.1.0-py3-none-any.whl")?.description == "0.1.0")
        #expect(CLIInstaller.wheelVersion("other-0.1.0-py3-none-any.whl") == nil)
        #expect(CLIInstaller.wheelVersion("transcribe-0.1.0.tar.gz") == nil)
    }

    @Test func releaseURL() {
        #expect(CLIInstaller.releaseWheelURL(version: "0.1.0").absoluteString
                == "https://github.com/gitkeniwo/transcrio/releases/download/v0.1.0/transcribe-0.1.0-py3-none-any.whl")
    }

    @Test func findsTheNewestBundledWheel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CLIInstaller.bundledWheel(in: dir) == nil)
        for name in ["AppIcon.icns", "transcribe-0.9.0-py3-none-any.whl", "transcribe-0.10.0-py3-none-any.whl"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        #expect(CLIInstaller.bundledWheel(in: dir)?.lastPathComponent == "transcribe-0.10.0-py3-none-any.whl")
        #expect(CLIInstaller.bundledWheel(in: nil) == nil)
    }

    @Test func sourcePrefersTheBundledWheel() {
        let wheel = URL(fileURLWithPath: "/Applications/Transcrio.app/Contents/Resources/transcribe-0.1.0-py3-none-any.whl")
        #expect(CLIInstaller.source(bundledWheel: wheel, appVersion: "0.1.0") == .bundledWheel(wheel))
        #expect(CLIInstaller.source(bundledWheel: nil, appVersion: "0.2.0")
                == .release(CLIInstaller.releaseWheelURL(version: "0.2.0")))
        #expect(CLIInstaller.source(bundledWheel: nil, appVersion: nil) == nil)
    }

    @Test func installCommand() {
        let locator = CLILocator(probe: FakeProbe(), environment: ["PATH": "/usr/bin", "UV_TOOL_DIR": "/tmp/tools"],
                                 homeDirectory: "/Users/me")
        let wheel = URL(fileURLWithPath: "/A/Transcrio.app/Contents/Resources/transcribe-0.1.0-py3-none-any.whl")
        let cmd = CLIInstaller.command(uv: "/opt/homebrew/bin/uv", source: .bundledWheel(wheel), locator: locator)
        #expect(cmd.executable.path == "/opt/homebrew/bin/uv")
        #expect(cmd.leadingArguments == ["tool", "install", "--force", "--python", "3.12", wheel.path])
        #expect(cmd.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(cmd.environment["UV_TOOL_DIR"] == "/tmp/tools")
        let release = CLIInstaller.command(uv: "/u", source: .release(CLIInstaller.releaseWheelURL(version: "0.1.0")), locator: locator)
        #expect(release.leadingArguments.last?.hasPrefix("https://github.com/") == true)
    }

    @Test func findsUvOnTheExplicitPath() {
        let home = "/Users/me"
        let brew = CLILocator(probe: FakeProbe(executables: ["/opt/homebrew/bin/uv"]), environment: [:], homeDirectory: home)
        #expect(brew.findExecutable("uv") == "/opt/homebrew/bin/uv")
        let local = CLILocator(probe: FakeProbe(executables: ["\(home)/.local/bin/uv"]), environment: [:], homeDirectory: home)
        #expect(local.findExecutable("uv") == "\(home)/.local/bin/uv")
        #expect(CLILocator(probe: FakeProbe(), environment: [:], homeDirectory: home).findExecutable("uv") == nil)
    }

    @Test func toolBinDirectoryFollowsUv() throws {
        let home = "/Users/me"
        let custom = CLILocator(probe: FakeProbe(executables: ["/tmp/bin/transcribe", "\(home)/.local/bin/transcribe"]),
                                environment: ["UV_TOOL_BIN_DIR": "/tmp/bin"], homeDirectory: home)
        #expect(custom.toolBinDirectory == "/tmp/bin")
        #expect(try custom.locate().executable.path == "/tmp/bin/transcribe")
        #expect(custom.childEnvironment["PATH"]?.contains("/tmp/bin") == true)
        let xdg = CLILocator(probe: FakeProbe(), environment: ["XDG_BIN_HOME": "~/bin"], homeDirectory: home)
        #expect(xdg.toolBinDirectory == "\(home)/bin")
        #expect(CLILocator(probe: FakeProbe(), environment: [:], homeDirectory: home).toolBinDirectory == "\(home)/.local/bin")
    }
}

@Suite struct StreamingProcessTests {
    final class Lines: @unchecked Sendable {
        let lock = NSLock()
        var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
    }

    @Test func streamsMergedOutputAndKeepsTheTail() async throws {
        let lines = Lines()
        let cmd = CLICommand(executable: URL(fileURLWithPath: "/bin/sh"),
                             leadingArguments: ["-c", "for i in 1 2 3 4 5; do echo out $i; done; echo err >&2; exit 7"],
                             environment: ["PATH": "/usr/bin:/bin"], source: .localBin)
        let result = try await StreamingProcess.run(cmd, tailLines: 3) { lines.add($0) }
        #expect(result.status == 7)
        #expect(result.tail == ["out 4", "out 5", "err"])
        #expect(lines.all.count == 6)
    }

    @Test func launchFailureThrows() async {
        let cmd = CLICommand(executable: URL(fileURLWithPath: "/nonexistent/uv"), environment: [:], source: .localBin)
        await #expect(throws: RunnerError.self) { try await StreamingProcess.run(cmd) { _ in } }
    }
}
