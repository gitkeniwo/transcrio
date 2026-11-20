import Foundation
import Testing
@testable import TranscribeKit

/// Decoding of every event in sessions recorded from the real `transcribe serve`, and op encoding.
struct ServeProtocolTests {
    @Test func recordedJobSessionDecodesEveryLine() throws {
        let out = try Fixtures.serveSession("serve-jobs").filter { $0.dir == "out" }
        let events = out.compactMap { ServeEvent.decode($0.line) }
        #expect(events.count == out.count)
        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
    }

    @Test func recordedJobEventsCarryWhatTheQueueNeeds() throws {
        let events = try Fixtures.serveEvents("serve-jobs")
        guard case .models(let models) = events.first else { Issue.record("models first"); return }
        #expect(models.map(\.id) == ["1.7b", "0.6b", "aligner"])
        #expect(models[0].repo == "Qwen/Qwen3-ASR-1.7B" && models[0].kind == .asr && models[0].sizeBytes > 4_000_000_000)
        #expect(models[2].kind == .aligner)
        #expect(events.contains(.configured(idleUnloadSec: 300)))
        #expect(events.contains(.accepted(id: "j1")))

        let segs = events.compactMap { e -> LiveSegment? in if case .segment("j1", let s) = e { s } else { nil } }
        #expect(segs.map(\.index) == Array(1...8))
        #expect(segs.allSatisfy { $0.totalChunks == 8 && $0.language == "Chinese" && !$0.segment.text.isEmpty })
        #expect(segs.first?.segment.start == 0 && segs.last?.segment.end == 150.02)

        let done = events.compactMap { e -> FileResult? in if case .fileDone("j1", let r) = e { r } else { nil } }.first
        #expect(done?.outputs.keys.sorted() == ["md", "srt"])
        #expect(done?.duration == 150.02)
        #expect(done?.segments.count == 8)
        #expect(done?.segments.first?.start == 0)
        #expect(done?.segments.last?.end == 150.02)
        #expect(done?.cueTiming != nil)

        #expect(events.contains(.unloaded(model: "Qwen/Qwen3-ASR-1.7B", reason: .switch)))
        #expect(events.contains(.unloaded(model: "Qwen/Qwen3-ASR-1.7B", reason: .shutdown)))
        #expect(events.contains(.idle))
        #expect(events.contains(.fileStopped(id: "j3", stoppedAt: 48.27)))
        #expect(events.contains { if case .fileError("j4", let e) = $0 { e.contains("no such file") } else { false } })
        // The transcribe stage reports chunks.
        #expect(events.contains { e in
            if case .progress("j1", let p) = e { p.stage == .transcribe && p.totalChunks == 8 } else { false }
        })
        // The last models event shows the loaded model.
        guard case .models(let after) = events.last(where: { if case .models = $0 { true } else { false } }) else { return }
        #expect(after.first { $0.id == "1.7b" }?.loaded == true)
    }

    @Test func recordedDownloadSessionDecodesBothDownloadShapes() throws {
        let events = try Fixtures.serveEvents("serve-download")
        // `download` op: no job id, `model` is the catalog id and `repo` the repo.
        let op = events.compactMap { e -> DownloadInfo? in if case .download(nil, let d) = e { d } else { nil } }
        #expect(!op.isEmpty)
        #expect(op.allSatisfy { $0.model == "Qwen/Qwen3-ASR-0.6B" && $0.modelID == "0.6b" && $0.totalBytes > 1_000_000_000 })
        #expect(op.last!.downloadedBytes > op.first!.downloadedBytes)
        // Inside a job: `model` is the repo, `model_id` the catalog id.
        let job = events.compactMap { e -> DownloadInfo? in if case .download("d1", let d) = e { d } else { nil } }
        #expect(!job.isEmpty)
        #expect(job.allSatisfy { $0.model == "Qwen/Qwen3-ASR-0.6B" && $0.modelID == "0.6b" })
        #expect(events.contains(.modelError(model: "0.6b", error: "cancelled", cancelled: true)))
        #expect(events.contains(.fileStopped(id: "d1", stoppedAt: 0)))
        let statuses = events.compactMap { e -> ModelInfo.Status? in
            if case .models(let m) = e { m.first { $0.id == "0.6b" }?.status } else { nil }
        }
        #expect(statuses == [.notDownloaded, .partial, .partial])
    }

    @Test func unknownAndJunkLines() {
        #expect(ServeEvent.decode("not json") == nil)
        #expect(ServeEvent.decode("{\"op\":\"models\"}") == nil)
        #expect(ServeEvent.decode("{\"event\":\"future_thing\"}") == .unknown(event: "future_thing"))
        #expect(ServeEvent.decode("{\"event\":\"segment\"}") == .unknown(event: "segment"))  // needs an id
        #expect(ServeEvent.decode("{\"event\":\"log\",\"level\":\"error\",\"message\":\"bad\"}")
            == .log(id: nil, level: "error", message: "bad"))
        #expect(ServeEvent.decode("{\"event\":\"model_removed\",\"model\":\"0.6b\",\"freed_bytes\":123}")
            == .modelRemoved(model: "0.6b", freedBytes: 123))
        #expect(ServeEvent.decode("{\"event\":\"unloaded\",\"model\":\"x\",\"reason\":\"idle\"}")
            == .unloaded(model: "x", reason: .idle))
        #expect(ServeEvent.decode("{\"event\":\"progress\",\"stage\":\"load\",\"progress\":2}")
            == .progress(id: nil, ProgressInfo(stage: .load, progress: 1)))
    }

    @Test func jobIDsAndTerminalEvents() {
        #expect(ServeEvent.fileDone(id: "a", FileResult()).isTerminal)
        #expect(ServeEvent.fileStopped(id: "a", stoppedAt: 0).isTerminal)
        #expect(!ServeEvent.segment(id: "a", LiveSegment(index: 1, totalChunks: 1, segment: .init(start: 0, end: 1, text: ""))).isTerminal)
        #expect(ServeEvent.idle.jobID == nil)
        #expect(ServeEvent.progress(id: "x", ProgressInfo(stage: .decode, progress: 0)).jobID == "x")
    }

    func object(_ op: ServeOp) throws -> [String: Any] {
        let data = op.encoded()
        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func opsEncodeOneLineEach() throws {
        #expect(try object(.models)["op"] as? String == "models")
        #expect(try object(.cancelAll)["op"] as? String == "cancel_all")
        #expect(try object(.shutdown).count == 1)
        #expect(try object(.cancel(id: "f1"))["id"] as? String == "f1")
        #expect(try object(.configure(idleUnloadSec: 600))["idle_unload_sec"] as? Double == 600)
        #expect(try object(.preload(model: nil)).keys.sorted() == ["op"])
        #expect(try object(.preload(model: "0.6b"))["model"] as? String == "0.6b")
        #expect(try object(.download(model: "0.6b"))["op"] as? String == "download")
        #expect(try object(.cancelDownload(model: "0.6b"))["op"] as? String == "cancel_download")
        #expect(try object(.removeModel(model: "aligner"))["model"] as? String == "aligner")
    }

    @Test func enqueueCarriesPerFileOptions() throws {
        let options = TranscribeOptions(formats: [.srt, .md], timestamps: true,
                                        outputDirectory: URL(fileURLWithPath: "/tmp/out"), language: "zh",
                                        model: .fast, contextTerms: [" Marlowe ", "", "LA"], overwrite: true)
        let job = ServeJob(id: "f-1", url: URL(fileURLWithPath: "/tmp/a b/clip.m4a"), options: options)
        let obj = try object(.enqueue(job))
        let j = obj["job"] as! [String: Any]
        #expect(j["id"] as? String == "f-1")
        #expect(j["input"] as? String == "/tmp/a b/clip.m4a")
        #expect(j["formats"] as? [String] == ["md", "srt"])  // display order
        #expect(j["output_dir"] as? String == "/tmp/out")
        #expect(j["timestamps"] as? Bool == true)
        #expect(j["language"] as? String == "zh")
        #expect(j["context"] as? String == "Marlowe LA")
        #expect(j["overwrite"] as? Bool == true)
        #expect(j["model"] as? String == "0.6b")

        let auto = ServeJob(id: "x", url: URL(fileURLWithPath: "/a.m4a"), options: TranscribeOptions(language: "auto"))
        let a = try object(.enqueue(auto))["job"] as! [String: Any]
        #expect(a["language"] == nil)
        #expect(a["output_dir"] == nil)
        #expect(a["model"] as? String == "1.7b")
    }
}
