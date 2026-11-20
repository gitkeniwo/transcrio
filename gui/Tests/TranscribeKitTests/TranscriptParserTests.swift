import Foundation
import Testing
@testable import TranscribeKit

@Suite struct TranscriptParserTests {
    func fixture(_ path: String) throws -> String {
        try String(contentsOf: Fixtures.directory.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func markdownWithTimestamps() throws {
        let doc = TranscriptParser.parse(try fixture("long/outputs/long.md"), format: .md, duration: 246.9)
        #expect(doc.title == "long")
        #expect(doc.hasTimestamps)
        #expect(doc.paragraphs.first?.start == 0)
        #expect(doc.paragraphs[1].start == 20)
        #expect(doc.paragraphs[0].end == 20)
        #expect(doc.paragraphs.last?.end == 246.9)
        #expect(doc.paragraphs[0].text.hasPrefix("Hello and welcome."))
        #expect(!doc.plainText.contains("**["))
        #expect(doc.paragraph(at: 25)?.id == 1)
    }

    @Test func markdownWithoutTimestamps() throws {
        let doc = TranscriptParser.parse(try fixture("success/outputs/en.md"), format: .md)
        #expect(doc.title == "en")
        #expect(!doc.hasTimestamps)
        #expect(doc.paragraphs.count == 1)
        #expect(!doc.paragraphs[0].text.contains("Source:"))
    }

    @Test func plainText() throws {
        let doc = TranscriptParser.parse(try fixture("notices/outputs/nl.txt"), format: .txt)
        #expect(doc.paragraphs.count == 1)
        #expect(doc.paragraphs[0].start == 0)
        #expect(doc.paragraphs[0].text.hasPrefix("Goede middag"))
        let bare = TranscriptParser.plain("One.\n\nTwo.\n")
        #expect(bare.paragraphs.map(\.text) == ["One.", "Two."])
        #expect(!bare.hasTimestamps)
    }

    @Test func srtAndVtt() throws {
        let srt = TranscriptParser.parse(try fixture("long/outputs/long.srt"), format: .srt)
        #expect(srt.paragraphs[0].text == "Hello and welcome.")
        #expect(srt.paragraphs[0].start == 0)
        #expect(srt.paragraphs[0].end == 0.96)
        #expect(srt.paragraphs[1].start == 1.2)
        let vtt = TranscriptParser.parse(try fixture("long/outputs/long.vtt"), format: .vtt)
        #expect(vtt.paragraphs.count == srt.paragraphs.count)
        #expect(vtt.paragraphs[1].end == 3.04)
        let zh = TranscriptParser.parse(try fixture("success/outputs/zh.srt"), format: .srt)
        #expect(zh.paragraphs.count == 4)
    }

    @Test func clockParsing() {
        #expect(TranscriptParser.seconds("00:30:40") == 1840)
        #expect(TranscriptParser.seconds("01:02:03,500") == 3723.5)
        #expect(TranscriptParser.seconds("30:40.250") == 1840.25)
        #expect(TranscriptParser.seconds("nope") == nil)
    }

    @Test func estimatedSpansComeFromTimingNotices() throws {
        #expect(FileResult(cueTiming: .estimated).estimatedSpans(duration: 120) == [0...120])
        #expect(FileResult(cueTiming: .aligned).estimatedSpans(duration: 120).isEmpty)
        let line = #"{"file": "/a.m4a", "event": "file_done", "outputs": {}, "cue_timing": "mixed", "warnings": ["alignment failed at 30.0s: boom", "subtitle timing is estimated for part of the audio"], "notices": [{"code": "alignment_failed", "message": "alignment failed at 30.0s: boom", "spans": [[30.0, 60.0]]}, {"code": "timing_estimated", "message": "subtitle timing is estimated for part of the audio", "spans": [[90.5, 120.0], [30.0, 60.0]]}, {"code": "future_thing", "message": "x", "spans": null}]}"#
        guard case .fileDone(_, let r) = CLIEvent.decode(line) else { Issue.record("no file_done"); return }
        #expect(r.notices.map(\.code) == [.alignmentFailed, .timingEstimated, nil])
        #expect(r.notices[2].rawCode == "future_thing")
        #expect(r.notices[2].spans == nil)
        #expect(r.noticeCount == 3)
        // Only timing_estimated spans count, sorted; the regex on messages is gone.
        #expect(r.estimatedSpans(duration: 120) == [30...60, 90.5...120])
        // Estimated with explicit spans uses them rather than the whole file.
        let partial = FileResult(cueTiming: .estimated, notices: [Notice(code: .timingEstimated, message: "m", spans: [0...10])])
        #expect(partial.estimatedSpans(duration: 120) == [0...10])
    }

    @Test func olderCLIWithoutNoticesFallsBackToWarnings() {
        let r = FileResult(cueTiming: .mixed, warnings: ["a", "b"])
        #expect(r.effectiveNotices.map(\.message) == ["a", "b"])
        #expect(FileResult(cueTiming: .estimated).noticeCount == 1)
        #expect(FileResult(cueTiming: .aligned).noticeCount == 0)
    }
}
