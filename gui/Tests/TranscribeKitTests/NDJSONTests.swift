import Foundation
import Testing
@testable import TranscribeKit

@Suite struct LineSplitterTests {
    @Test func partialLineIsHeldUntilNewline() {
        var s = NDJSONLineSplitter()
        #expect(s.append(Data("{\"a\":".utf8)) == [])
        #expect(s.append(Data("1}\n".utf8)) == ["{\"a\":1}"])
    }

    @Test func multipleLinesInOneChunk() {
        var s = NDJSONLineSplitter()
        #expect(s.append(Data("one\ntwo\nthree\n".utf8)) == ["one", "two", "three"])
    }

    @Test func multiByteCharacterSplitAcrossReads() {
        var s = NDJSONLineSplitter()
        let bytes = Array("{\"m\":\"大家好\"}\n".utf8)
        // Cut inside the 3-byte encoding of 大.
        let cut = bytes.firstIndex(of: 0xE5)! + 1
        #expect(s.append(Data(bytes[..<cut])) == [])
        #expect(s.append(Data(bytes[cut...])) == ["{\"m\":\"大家好\"}"])
    }

    @Test func byteByByteFeedingYieldsSameLines() {
        var s = NDJSONLineSplitter()
        var out: [String] = []
        for b in Array("héllo\nwörld\n".utf8) { out += s.append(Data([b])) }
        #expect(out == ["héllo", "wörld"])
    }

    @Test func trailingLineWithoutNewlineIsFlushedOnFinish() {
        var s = NDJSONLineSplitter()
        #expect(s.append(Data("a\nb".utf8)) == ["a"])
        #expect(s.finish() == ["b"])
        #expect(s.finish() == [])
    }

    @Test func blankLinesAndCRLFAreHandled() {
        var s = NDJSONLineSplitter()
        #expect(s.append(Data("\n\n  \nx\r\n\r\n".utf8)) == ["x"])
    }
}

@Suite struct EventDecodingTests {
    @Test func decodesEveryRecordedFixtureLine() throws {
        for name in ["success", "mixed", "exists", "notices", "long", "stopped", "download"] {
            let lines = try Fixtures.lines(name)
            let events = lines.compactMap(CLIEvent.decode)
            #expect(events.count == lines.count, "\(name)")
            #expect(!events.contains { if case .unknown = $0 { true } else { false } }, "\(name)")
        }
    }

    @Test func progressWithNullChunk() throws {
        let e = CLIEvent.decode(#"{"file": "/a.mp3", "event": "progress", "stage": "transcribe", "progress": 0.0, "chunk": null, "total_chunks": 14}"#)
        #expect(e == .progress(file: "/a.mp3", ProgressInfo(stage: .transcribe, progress: 0, chunk: nil, totalChunks: 14)))
    }

    @Test func fileDoneFields() throws {
        let done = try Fixtures.events("notices").compactMap { e -> FileResult? in
            if case .fileDone(_, let r) = e { r } else { nil }
        }.first
        let r = try #require(done)
        #expect(r.cueTiming == .estimated)
        #expect(r.language == "Dutch")
        #expect(r.orderedOutputs.map(\.format) == [.md, .txt, .srt])
        #expect(r.warnings.count == 1)
        #expect(r.noticeCount == 1)
    }

    @Test func unknownEventsAndFieldsAreTolerated() {
        #expect(CLIEvent.decode(#"{"file": "/a", "event": "heartbeat", "x": 1}"#) == .unknown(file: "/a", event: "heartbeat"))
        let e = CLIEvent.decode(#"{"file": "/a", "event": "progress", "stage": "vad", "progress": 0.5, "new_field": [1]}"#)
        guard case .progress(_, let info) = e else { Issue.record("not progress"); return }
        #expect(info.stage == nil)
        #expect(info.stageName == "vad")
        let done = CLIEvent.decode(#"{"file": "/a", "event": "file_done", "outputs": {"md": "/a.md"}, "cue_timing": "magic", "extra": true}"#)
        guard case .fileDone(_, let r) = done else { Issue.record("not done"); return }
        #expect(r.cueTiming == nil)
        #expect(r.warnings == [])
    }

    @Test func nonJSONLinesAreNotEvents() {
        #expect(CLIEvent.decode("transcribe: ffmpeg not found on PATH (install with: brew install ffmpeg)") == nil)
        #expect(CLIEvent.decode(#"{"no_event": true}"#) == nil)
        #expect(CLIEvent.decode("[1, 2]") == nil)
    }

    @Test func progressIsClamped() {
        guard case .progress(_, let info) = CLIEvent.decode(#"{"file": "/a", "event": "progress", "stage": "align", "progress": 1.7}"#)
        else { Issue.record("not progress"); return }
        #expect(info.progress == 1)
    }

    @Test func summaryDecodes() throws {
        let s = try #require(CLISummary.decode(try Fixtures.data("mixed/stdout.json")))
        #expect(s.results.count == 3)
        #expect(s.results[0].error?.hasPrefix("no such file") == true)
        #expect(s.results[2].error == nil)
        #expect(s.results[2].result.outputs["md"] == "/tmp/fixture/out/en.md")
        #expect(s.results[2].backend == "qwen3-mlx")
    }

    @Test func doctorAndBackendsDecode() throws {
        let d = try JSONDecoder().decode(DoctorReport.self, from: try Fixtures.data("doctor.json"))
        #expect(d.ok)
        #expect(d.ffmpeg != nil)
        #expect(d.hfCache != nil)
        let b = try JSONDecoder().decode(BackendsReport.self, from: try Fixtures.data("backends.json"))
        #expect(b.defaultBackend?.name == "qwen3-mlx")
        #expect(b.defaultBackend?.alignedLanguages.contains("Chinese") == true)
        #expect(b.defaultBackend?.modelAliases["0.6b"] == "Qwen/Qwen3-ASR-0.6B")
    }

    @Test func doctorWithNullsAndProblems() throws {
        let d = try JSONDecoder().decode(DoctorReport.self, from: Data(#"{"ok": false, "ffmpeg": null, "ffprobe": null, "apple_silicon": true, "hf_cache": "/x", "mlx_device": null, "mlx_error": "boom"}"#.utf8))
        #expect(!d.ok)
        #expect(d.ffmpeg == nil)
        #expect(d.mlxError == "boom")
    }
}
