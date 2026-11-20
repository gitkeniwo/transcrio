import Foundation
import Testing
@testable import TranscribeKit

@Suite struct CommandBuilderTests {
    let files = [URL(fileURLWithPath: "/Users/me/a b/zh.mp3"), URL(fileURLWithPath: "/Users/me/x/../en.mp4")]

    @Test func defaultsWriteNextToSource() throws {
        let args = try CommandBuilder.arguments(files: files, options: TranscribeOptions())
        #expect(args == ["run", "/Users/me/a b/zh.mp3", "/Users/me/en.mp4", "-f", "md", "-m", "1.7b",
                         "--json", "--progress", "ndjson"])
        #expect(!args.contains("-o"))
    }

    @Test func everyOption() throws {
        let opts = TranscribeOptions(formats: [.md, .srt, .md], timestamps: true,
                                     outputDirectory: URL(fileURLWithPath: "/tmp/out/./subs"),
                                     language: "zh", model: .fast, contextTerms: ["Kubernetes", " 张三 ", ""],
                                     overwrite: true)
        let args = try CommandBuilder.arguments(files: [files[0]], options: opts)
        #expect(args == ["run", "/Users/me/a b/zh.mp3", "-f", "md,srt", "-o", "/tmp/out/subs", "-t", "-l", "zh",
                         "-m", "0.6b", "--context=Kubernetes 张三", "--overwrite", "--json", "--progress", "ndjson"])
    }

    @Test func autoLanguageAndEmptyContextAreOmitted() throws {
        let args = try CommandBuilder.arguments(files: files, options: TranscribeOptions(language: "auto", contextTerms: ["  "]))
        #expect(!args.contains("-l"))
        #expect(!args.contains { $0.hasPrefix("--context") })
    }

    @Test func contextStartingWithDashStaysOneValue() throws {
        let args = try CommandBuilder.arguments(files: files, options: TranscribeOptions(contextTerms: ["-v", "--json"]))
        #expect(args.contains("--context=-v --json"))
    }

    @Test func atLeastOneFormatAndFile() {
        #expect(throws: CommandBuilderError.noFormats) {
            try CommandBuilder.arguments(files: files, options: TranscribeOptions(formats: []))
        }
        #expect(throws: CommandBuilderError.noFiles) {
            try CommandBuilder.arguments(files: [], options: TranscribeOptions())
        }
    }

    @Test func wantsCues() {
        #expect(!TranscribeOptions(formats: [.md, .txt, .json]).wantsCues)
        #expect(TranscribeOptions(formats: [.vtt]).wantsCues)
    }

    @Test func optionsRoundTripThroughCodable() throws {
        let opts = TranscribeOptions(formats: [.txt, .vtt], outputDirectory: URL(fileURLWithPath: "/tmp/o"), language: "ja")
        let back = try JSONDecoder().decode(TranscribeOptions.self, from: JSONEncoder().encode(opts))
        #expect(back == opts)
    }
}

@Suite struct CLILocatorTests {
    let home = "/Users/me"
    var localBin: String { "\(home)/.local/bin/transcribe" }

    func locator(_ probe: FakeProbe, env: [String: String] = ["PATH": "/usr/bin:/bin"]) -> CLILocator {
        CLILocator(probe: probe, environment: env, homeDirectory: home)
    }

    @Test func settingsOverrideWins() throws {
        let probe = FakeProbe(executables: ["/opt/custom/transcribe", localBin])
        let cmd = try locator(probe).locate(overridePath: "/opt/custom/transcribe", repoPath: nil)
        #expect(cmd.executable.path == "/opt/custom/transcribe")
        #expect(cmd.leadingArguments.isEmpty)
        #expect(cmd.source == .settingsOverride)
    }

    @Test func overrideExpandsTilde() throws {
        let probe = FakeProbe(executables: ["\(home)/bin/t"])
        #expect(try locator(probe).locate(overridePath: "~/bin/t").executable.path == "\(home)/bin/t")
    }

    @Test func brokenOverrideIsReportedNotSkipped() {
        let probe = FakeProbe(executables: [localBin])
        #expect(throws: CLILocatorError.overrideNotExecutable("/nope")) {
            try locator(probe).locate(overridePath: "/nope")
        }
    }

    @Test func blankOverrideFallsThroughToLocalBin() throws {
        let probe = FakeProbe(executables: [localBin])
        let cmd = try locator(probe).locate(overridePath: "  ", repoPath: nil)
        #expect(cmd.executable.path == localBin)
        #expect(cmd.source == .localBin)
    }

    @Test func uvRunFallback() throws {
        let probe = FakeProbe(executables: ["/opt/homebrew/bin/uv"], files: ["/repo/pyproject.toml"])
        let cmd = try locator(probe).locate(repoPath: "/repo")
        #expect(cmd.executable.path == "/usr/bin/env")
        #expect(cmd.leadingArguments == ["uv", "run", "--project", "/repo", "transcribe"])
        #expect(cmd.source == .uvRun)
    }

    @Test func uvRunUsesDefaultRepo() throws {
        let probe = FakeProbe(executables: ["\(home)/.local/bin/uv"], files: ["\(home)/transcrio/pyproject.toml"])
        let cmd = try locator(probe).locate()
        #expect(cmd.leadingArguments.contains("\(home)/transcrio"))
    }

    @Test func notFoundWithoutUvOrRepo() {
        #expect(throws: CLILocatorError.notFound) {
            try locator(FakeProbe(files: ["/repo/pyproject.toml"])).locate(repoPath: "/repo")
        }
        #expect(throws: CLILocatorError.notFound) {
            try locator(FakeProbe(executables: ["/opt/homebrew/bin/uv"])).locate(repoPath: "/repo")
        }
    }

    @Test func debugEnvironmentVariableComesFirst() throws {
        let probe = FakeProbe(executables: ["/dev/fake.sh", localBin, "/opt/custom/t"])
        let cmd = try locator(probe, env: ["TRANSCRIBE_CLI": "/dev/fake.sh"]).locate(overridePath: "/opt/custom/t")
        #expect(cmd.source == .debugEnvironment)
        #expect(cmd.executable.path == "/dev/fake.sh")
    }

    @Test func childPathIncludesHomebrewAndLocalBin() throws {
        let probe = FakeProbe(executables: [localBin])
        let cmd = try locator(probe, env: ["PATH": "/usr/bin:/bin:/custom", "HOME": home]).locate()
        let path = try #require(cmd.environment["PATH"]).split(separator: ":").map(String.init)
        #expect(path.first == "/opt/homebrew/bin")
        #expect(path.contains("\(home)/.local/bin"))
        #expect(path.contains("/custom"))
        #expect(path.count == Set(path).count)
        #expect(cmd.environment["HOME"] == home)
    }

    @Test func minimalFinderEnvironmentStillGetsAPath() {
        let env = locator(FakeProbe(), env: [:]).childEnvironment
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }
}

@Suite struct ModelCacheTests {
    @Test func reportsCachedAndMissingModels() throws {
        let tmp = try TempDir()
        let cache = ModelCache(root: tmp.url)
        #expect(!cache.isCached(.asr1_7b))
        // A directory without weights (interrupted download) is not cached.
        _ = try tmp.file("hub/models--Qwen--Qwen3-ASR-1.7B/snapshots/abc/config.json", contents: "{}")
        #expect(!cache.isCached(.asr1_7b))
        _ = try tmp.file("hub/models--Qwen--Qwen3-ASR-1.7B/snapshots/abc/model.safetensors", contents: "x")
        _ = try tmp.file("hub/models--Qwen--Qwen3-ForcedAligner-0.6B/snapshots/def/model-00001.safetensors", contents: "x")
        #expect(cache.status() == [.asr1_7b: true, .asr0_6b: false, .aligner: true])
    }

    @Test func rootResolution() {
        #expect(ModelCache(doctorHFCache: "/d", environment: ["HF_HOME": "/h"]).root.path == "/d")
        #expect(ModelCache(doctorHFCache: nil, environment: ["HF_HOME": "/h"]).root.path == "/h")
        #expect(ModelCache(doctorHFCache: "", environment: [:], homeDirectory: "/u").root.path == "/u/.cache/huggingface")
    }

    @Test func directoryNames() {
        #expect(CachedModel.asr1_7b.cacheDirectoryName == "models--Qwen--Qwen3-ASR-1.7B")
        #expect(CachedModel.asr0_6b.cacheDirectoryName == "models--Qwen--Qwen3-ASR-0.6B")
        #expect(CachedModel.aligner.cacheDirectoryName == "models--Qwen--Qwen3-ForcedAligner-0.6B")
        #expect(ModelChoice.fast.cacheModel == .asr0_6b)
    }
}

@Suite struct FormattingTests {
    @Test func clocks() {
        #expect(Formatting.clock(1445) == "24:05")
        #expect(Formatting.clock(3723.4) == "1:02:03")
        #expect(Formatting.clock(nil) == "–:––")
        #expect(Formatting.longClock(59) == "0:00:59")
        #expect(Formatting.stamp(1840.9) == "00:30:40")
    }

    @Test func tookSpeedPercent() {
        #expect(Formatting.took(42) == "42s")
        #expect(Formatting.took(192) == "3m 12s")
        #expect(Formatting.took(3840) == "1h 4m")
        #expect(Formatting.speed(duration: 600, elapsed: 50) == "12×")
        #expect(Formatting.speed(duration: 8.87, elapsed: 6.4) == "1.4×")
        #expect(Formatting.speed(duration: 1, elapsed: 0) == "–")
        #expect(Formatting.percent(0.629) == "62%")
        #expect(Formatting.percent(1.2) == "100%")
    }
}
