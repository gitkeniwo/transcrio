import Foundation
import Testing
@testable import TranscribeKit

@Suite struct TranscriptTimingTests {
    func outputs(_ name: String, stem: String? = nil) -> [String: String] {
        let dir = Fixtures.directory.appendingPathComponent("\(name)/outputs")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { ($0 as NSString).deletingPathExtension == (stem ?? name) }
        return Dictionary(uniqueKeysWithValues: files.map { ((($0 as NSString).pathExtension), dir.appendingPathComponent($0).path) })
    }

    @Test func subtitlesWinOverMarkdown() {
        let segs = OutputFilesTimingSource(outputs: outputs("long"), duration: 246.9).segments()
        #expect(segs.first == TimedSegment(start: 0, end: 0.96, text: "Hello and welcome."))
        #expect(segs[1].start == 1.2)
        #expect(segs.count > 10)
    }

    @Test func timestampedMarkdownWhenNoSubtitles() {
        var files = outputs("long")
        files["srt"] = nil
        files["vtt"] = nil
        let segs = OutputFilesTimingSource(outputs: files, duration: 246.9).segments()
        #expect(segs.first?.start == 0)
        #expect(segs.first?.end == 20)
        #expect(segs.last?.end == 246.9)
    }

    @Test func noTimesAnywhere() {
        let files = ["md": outputs("success", stem: "en")["md"]!]
        #expect(OutputFilesTimingSource(outputs: files, duration: 8).segments().isEmpty)
        #expect(OutputFilesTimingSource(outputs: [:], duration: 8).segments().isEmpty)
    }

    @Test func untimedMarkdownTimedBySubtitles() throws {
        let files = outputs("success", stem: "en")
        let md = TranscriptParser.parse(try String(contentsOfFile: files["md"]!, encoding: .utf8), format: .md)
        let segs = OutputFilesTimingSource(outputs: files, duration: 8).segments()
        let times = ParagraphTiming.assign(paragraphs: md.paragraphs.map(\.text), segments: segs)
        #expect(times.count == 1)
        #expect(times[0]?.lowerBound == 0)
        #expect(times[0]?.upperBound == segs.last?.end)
    }

    @Test func paragraphsSplitAtCueBoundaries() {
        let segs = [
            TimedSegment(start: 0, end: 2, text: "One two."),
            TimedSegment(start: 2, end: 5, text: "Three four five."),
            TimedSegment(start: 6, end: 9, text: "Six seven."),
        ]
        let times = ParagraphTiming.assign(paragraphs: ["One two. Three four five.", "Six seven."], segments: segs)
        #expect(times == [0...5, 6...9])
    }

    @Test func paragraphInsideOneCueIsInterpolated() {
        let segs = [TimedSegment(start: 10, end: 20, text: "aaaaabbbbb")]
        let times = ParagraphTiming.assign(paragraphs: ["aaaaa", "bbbbb"], segments: segs)
        #expect(abs(times[0]!.lowerBound - 10) < 0.01)
        #expect(abs(times[0]!.upperBound - 15) < 0.01)
        #expect(abs(times[1]!.upperBound - 20) < 0.01)
    }

    @Test func emptyInputs() {
        #expect(ParagraphTiming.assign(paragraphs: [], segments: []).isEmpty)
        #expect(ParagraphTiming.assign(paragraphs: ["a"], segments: []) == [nil])
        #expect(ParagraphTiming.assign(paragraphs: ["—", "a"], segments: [TimedSegment(start: 0, end: 1, text: "a")])[0] == nil)
    }

    @Test(arguments: [8.0, 20.0, 75.0, 246.9, 2642.0, 5400.0, 10800.0] as [Double])
    func ticksAreFourToSixWithPinnedEnds(duration: Double) {
        let t = OverviewTicks.labels(duration: duration)
        #expect((4...6).contains(t.count), "\(duration): \(t)")
        #expect(t.first == 0)
        #expect(t.last == duration)
        #expect(t == t.sorted())
    }

    @Test func ticksAtRoundMinutes() {
        #expect(OverviewTicks.labels(duration: 2642) == [0, 600, 1200, 1800, 2642])
        #expect(OverviewTicks.labels(duration: 0).isEmpty)
    }
}
