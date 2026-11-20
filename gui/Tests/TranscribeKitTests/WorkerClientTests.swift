import Foundation
import Testing
@testable import TranscribeKit

/// Runs `WorkerClient` against `scripts/fake-serve.py`, which replays sessions recorded from the
/// real `transcribe serve` and answers ops on stdin. No model needed.
@Suite(.serialized) struct WorkerClientTests {
    func command(speed: Double = 40, env extra: [String: String] = [:]) -> CLICommand {
        var env = CLILocator(environment: ProcessInfo.processInfo.environment).childEnvironment
        env["FAKE_SERVE_SPEED"] = String(speed)
        env.merge(extra) { $1 }
        return CLICommand(executable: Fixtures.fakeServe, environment: env, source: .debugEnvironment)
    }

    /// Reads updates until `until` is satisfied or the stream ends.
    final class Reader: @unchecked Sendable {
        var iterator: AsyncStream<WorkerUpdate>.Iterator
        var events: [ServeEvent] = []
        var exit: WorkerExit?
        init(_ stream: AsyncStream<WorkerUpdate>) { iterator = stream.makeAsyncIterator() }

        @discardableResult
        func until(_ pred: (ServeEvent) -> Bool) async -> ServeEvent? {
            while let u = await iterator.next() {
                switch u {
                case .event(let e):
                    events.append(e)
                    if pred(e) { return e }
                case .exited(let x): exit = x; return nil
                case .stderr: break
                }
            }
            return nil
        }

        func drain() async { _ = await until { _ in false } }
    }

    func job(_ id: String, _ url: URL, _ options: TranscribeOptions = TranscribeOptions()) -> ServeOp {
        .enqueue(ServeJob(id: id, url: url, options: options))
    }

    @Test func runsJobsOneByOneAndShutsDown() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("podcast-zh.m4a"), b = try tmp.file("chapter-en.mp3")
        let client = WorkerClient(command: command())
        let r = Reader(try await client.launch())
        await client.send(.models)
        #expect(await r.until { if case .models = $0 { true } else { false } } != nil)
        await client.send(job("a", a, TranscribeOptions(formats: [.md, .srt], language: "zh")))
        await client.send(job("b", b, TranscribeOptions(formats: [.txt], model: .fast)))
        await r.until { $0 == .fileDone(id: "b", FileResult()) || ($0.jobID == "b" && $0.isTerminal) }

        let segA = r.events.filter { if case .segment("a", _) = $0 { true } else { false } }
        let segB = r.events.filter { if case .segment("b", _) = $0 { true } else { false } }
        #expect(segA.count == 8 && segB.count == 6)
        // a finished before b started.
        let lastA = r.events.lastIndex { $0.jobID == "a" }!, firstB = r.events.firstIndex { $0 == .accepted(id: "b") }!
        let firstBProgress = r.events.firstIndex { if case .progress("b", _) = $0 { true } else { false } }!
        #expect(firstB < lastA && lastA < firstBProgress)
        #expect(r.events.contains(.unloaded(model: "Qwen/Qwen3-ASR-1.7B", reason: .switch)))
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("podcast-zh.srt").path))
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("chapter-en.txt").path))
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("chapter-en.md").path))
        if case .fileDone(_, let res) = r.events.first(where: { if case .fileDone("a", _) = $0 { true } else { false } }) {
            #expect(res.segments.count == 8)
        } else { Issue.record("a should finish") }

        await client.shutdown()
        await r.drain()
        #expect(r.exit == WorkerExit(code: 0, signaled: false, requested: true))
        #expect(await !client.isRunning)
    }

    /// Library run with no prepared formats, then the export op makes them from the transcript.
    @Test func noFormatsRunThenExportFromTheTranscript() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("chapter-en.mp3")
        let staging = tmp.url.appendingPathComponent("staging")
        let client = WorkerClient(command: command())
        let r = Reader(try await client.launch())
        var o = TranscribeOptions()
        o.formats = []
        var j = ServeJob(id: "a", url: a, options: o)
        j.outputDir = staging.path
        j.transcriptPath = staging.appendingPathComponent("transcript.json").path
        j.align = true
        await client.send(.enqueue(j))
        let done = await r.until { $0.jobID == "a" && $0.isTerminal }
        guard case .fileDone(_, let res)? = done else { Issue.record("a should finish"); return }
        #expect(res.outputs.isEmpty)
        #expect(res.transcript == j.transcriptPath)

        await client.send(.export(ServeExport(id: "x1", transcript: j.transcriptPath!, formats: ["srt", "md"],
                                              outputDir: staging.path, timestamps: true, title: "Chapter")))
        let exported = await r.until { if case .exported = $0 { true } else { false } }
        guard case .exported("x1", let outputs, let estimated)? = exported else { Issue.record("no exported"); return }
        #expect(!estimated)
        #expect(outputs["md"] == staging.appendingPathComponent("Chapter.md").path)
        let md = try String(contentsOfFile: outputs["md"]!, encoding: .utf8)
        #expect(md.contains("**[00:"))
        #expect(FileManager.default.fileExists(atPath: outputs["srt"]!))

        await client.send(.export(ServeExport(id: "x2", transcript: "/nope.json", formats: ["md"], outputDir: staging.path)))
        let failed = await r.until { if case .exportError = $0 { true } else { false } }
        if case .exportError(let id, _)? = failed { #expect(id == "x2") } else { Issue.record("no export_error") }

        await client.shutdown()
        await r.drain()
    }

    @Test func cancelRunningStopsAtChunkBoundaryAndNextJobStarts() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("podcast-zh.m4a"), b = try tmp.file("chapter-en.mp3")
        let client = WorkerClient(command: command(speed: 10))
        let r = Reader(try await client.launch())
        await client.send(job("a", a))
        await client.send(job("b", b))
        await r.until { if case .segment("a", let s) = $0 { s.index == 2 } else { false } }
        await client.send(.cancel(id: "a"))
        let stopped = await r.until { $0.jobID == "a" && $0.isTerminal }
        guard case .fileStopped(_, let at) = stopped else { Issue.record("expected file_stopped, got \(String(describing: stopped))"); return }
        #expect(at > 0)
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("podcast-zh.md").path))
        await r.until { if case .segment("b", _) = $0 { true } else { false } }
        await client.send(.cancelAll)
        #expect(await r.until { $0.jobID == "b" && $0.isTerminal } != nil)
        await client.shutdown()
        await r.drain()
    }

    @Test func cancelQueuedJobAndErrors() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("chapter-en.mp3"), bad = try tmp.file("broken.wav")
        let client = WorkerClient(command: command(env: ["FAKE_SERVE_FAIL": "broken.wav"]))
        let r = Reader(try await client.launch())
        await client.send(job("a", a))
        await client.send(job("q", a))
        await client.send(.cancel(id: "q"))
        #expect(await r.until { $0.jobID == "q" && $0.isTerminal } == .fileStopped(id: "q", stoppedAt: 0))
        await client.send(job("missing", tmp.url.appendingPathComponent("nope.m4a")))
        await client.send(job("bad", bad))
        await client.send(job("a", a))  // duplicate id while queued or running → log, no events
        await r.until { $0.jobID == "bad" && $0.isTerminal }
        #expect(r.events.contains { if case .fileError("missing", let e) = $0 { e.contains("no such file") } else { false } })
        #expect(r.events.contains { if case .fileError("bad", let e) = $0 { e.contains("decode") } else { false } })
        #expect(r.events.contains { if case .log(_, "error", let m) = $0 { m.contains("already queued") } else { false } })
        // Existing outputs without overwrite.
        await client.send(job("again", a))
        let again = await r.until { $0.jobID == "again" && $0.isTerminal }
        guard case .fileError(_, let msg) = again else { Issue.record("expected an error"); return }
        #expect(msg.contains("output exists"))
        await client.shutdown()
        await r.drain()
    }

    @Test func crashIsReportedAndRelaunchWorks() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("chapter-en.mp3")
        let client = WorkerClient(command: command(env: ["FAKE_SERVE_CRASH_AFTER": "2"]))
        let r = Reader(try await client.launch())
        await client.send(job("a", a))
        await r.drain()
        #expect(r.exit?.isCrash == true)
        #expect(r.exit?.code == 1)
        #expect(await client.send(.models) == false)

        let r2 = Reader(try await client.launch())
        await client.send(.models)
        #expect(await r2.until { if case .models = $0 { true } else { false } } != nil)
        await client.shutdown()
        await r2.drain()
        #expect(r2.exit?.requested == true)
    }

    @Test func configureAndIdleUnload() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("chapter-en.mp3")
        let client = WorkerClient(command: command(speed: 50))
        let r = Reader(try await client.launch())
        await client.send(.configure(idleUnloadSec: 0.5))
        #expect(await r.until { if case .configured = $0 { true } else { false } } == .configured(idleUnloadSec: 0.5))
        await client.send(job("a", a, TranscribeOptions(model: .fast)))
        await r.until { $0 == .idle }
        #expect(await r.until { if case .unloaded = $0 { true } else { false } }
            == .unloaded(model: "Qwen/Qwen3-ASR-0.6B", reason: .idle))
        await client.shutdown()
        await r.drain()
    }

    @Test func modelOpsDownloadCancelResumeRemove() async throws {
        let client = WorkerClient(command: command(speed: 1, env: [
            "FAKE_SERVE_MODELS": "1.7b=not_downloaded,0.6b=not_downloaded,aligner=not_downloaded",
            "FAKE_SERVE_DOWNLOAD_SEC": "2",
        ]))
        let r = Reader(try await client.launch())
        var catalog = ModelCatalog()
        await client.send(.models)
        if let e = await r.until({ if case .models = $0 { true } else { false } }) { catalog.apply(e) }
        #expect(catalog.state(of: "0.6b") == .notDownloaded)

        await client.send(.download(model: "0.6b"))
        while let e = await r.until({ _ in true }) {
            catalog.apply(e)
            if case .download(_, let d) = e, d.downloadedBytes > 0 { break }
        }
        guard case .downloading = catalog.state(of: "0.6b") else { Issue.record("downloading"); return }
        await client.send(.cancelDownload(model: "0.6b"))
        if let e = await r.until({ if case .modelError = $0 { true } else { false } }) { catalog.apply(e) }
        await client.send(.models)
        if let e = await r.until({ if case .models = $0 { true } else { false } }) { catalog.apply(e) }
        guard case .partial(let bytes) = catalog.state(of: "0.6b") else { Issue.record("partial"); return }
        #expect(bytes > 0)

        // Resume continues from the partial bytes.
        await client.send(.download(model: "0.6b"))
        if let e = await r.until({ if case .download = $0 { true } else { false } }), case .download(_, let d) = e {
            #expect(d.downloadedBytes >= bytes)
            catalog.apply(e)
        }
        while let e = await r.until({ _ in true }) {
            catalog.apply(e)
            if case .modelReady = e { break }
        }
        #expect(catalog.state(of: "0.6b") == .downloaded)

        await client.send(.removeModel(model: "0.6b"))
        let removed = await r.until { if case .modelRemoved = $0 { true } else { false } }
        #expect(removed == .modelRemoved(model: "0.6b", freedBytes: catalog["0.6b"]!.sizeBytes))
        if let e = removed { catalog.apply(e) }
        #expect(catalog.state(of: "0.6b") == .notDownloaded)
        await client.shutdown()
        await r.drain()
    }

    @Test func removingTheLoadedModelUnloadsItFirst() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("chapter-en.mp3")
        let client = WorkerClient(command: command(speed: 50))
        let r = Reader(try await client.launch())
        await client.send(.preload(model: "0.6b"))
        #expect(await r.until { if case .modelReady = $0 { true } else { false } } == .modelReady(model: "0.6b"))
        // In use while a job runs.
        await client.send(job("a", a, TranscribeOptions(model: .fast)))
        await r.until { if case .segment("a", _) = $0 { true } else { false } }
        await client.send(.removeModel(model: "0.6b"))
        #expect(await r.until { if case .modelError = $0 { true } else { false } }
            == .modelError(model: "0.6b", error: "model is in use", cancelled: false))
        await r.until { $0 == .idle }
        await client.send(.removeModel(model: "0.6b"))
        await r.until { if case .modelRemoved = $0 { true } else { false } }
        let tail = r.events.suffix(2)
        #expect(tail.first == .unloaded(model: "Qwen/Qwen3-ASR-0.6B", reason: .remove))
        await client.shutdown()
        await r.drain()
    }

    @Test func shutdownStopsTheRunningJob() async throws {
        let tmp = try TempDir()
        let a = try tmp.file("podcast-zh.m4a")
        let client = WorkerClient(command: command(speed: 5, env: ["FAKE_SERVE_PAUSE_AT": "1"]))
        let r = Reader(try await client.launch())
        await client.send(job("a", a))
        await client.send(job("b", a))
        await r.until { if case .segment("a", _) = $0 { true } else { false } }
        let pid = await client.processIdentifier
        await client.shutdown()
        await r.drain()
        #expect(r.events.contains { if case .fileStopped("a", let at) = $0 { at > 0 } else { false } })
        #expect(r.events.contains(.fileStopped(id: "b", stoppedAt: 0)))
        #expect(r.exit?.requested == true)
        if let pid { #expect(kill(pid, 0) != 0) }
    }

    @Test func coalescerKeepsSegments() {
        let p = { (x: Double) in WorkerUpdate.event(.progress(id: "a", ProgressInfo(stage: .transcribe, progress: x, chunk: 1, totalChunks: 4))) }
        let seg = WorkerUpdate.event(.segment(id: "a", LiveSegment(index: 1, totalChunks: 4, segment: .init(start: 0, end: 1, text: "x"))))
        let out = WorkerEventCoalescer.coalesce([p(0.1), p(0.2), seg, p(0.3), p(0.4)])
        #expect(out == [p(0.2), seg, p(0.4)])
    }
}
