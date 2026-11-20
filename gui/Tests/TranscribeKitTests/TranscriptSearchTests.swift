import Foundation
import Testing
@testable import TranscribeKit

@Suite struct TranscriptSearchTests {
    static let english = """
    Welcome back to the show. Today we talk about Kubernetes operators.

    The café on the corner serves a naïve espresso, and RÉSUMÉ writing is hard.
    """
    static let chinese = "大家好，欢迎收听本期节目。今天我们聊一聊机器学习在医疗领域的应用。\n\n下一个话题是自然语言处理。"

    func index() -> TranscriptSearchIndex {
        var i = TranscriptSearchIndex()
        i.set("en", stamp: "1", text: Self.english)
        i.set("zh", stamp: "1", text: Self.chinese)
        return i
    }

    @Test func caseInsensitiveSubstring() {
        let hits = index().search("KUBERNETES oper")
        #expect(Set(hits.keys) == ["en"])
        #expect(hits["en"]?.match == "Kubernetes oper")
    }

    @Test func diacriticInsensitiveBothWays() {
        let i = index()
        #expect(i.search("cafe")["en"]?.match == "café")
        #expect(i.search("naive")["en"]?.match == "naïve")
        #expect(i.search("resume")["en"]?.match == "RÉSUMÉ")
        #expect(i.search("Résumé")["en"]?.match == "RÉSUMÉ")
    }

    @Test func chineseWithoutSpaces() {
        let i = index()
        #expect(Set(i.search("机器学习").keys) == ["zh"])
        #expect(i.search("机器学习")["zh"]?.match == "机器学习")
        #expect(i.search("学").count == 1)
        #expect(i.search("机器 学习").isEmpty)  // a space the text doesn't have
        #expect(i.search("深度学习").isEmpty)
    }

    @Test func fullWidthMatchesHalfWidth() {
        var i = TranscriptSearchIndex()
        i.set("a", stamp: "1", text: "会议在ＡＢＣ大厦，编号１２３。")
        #expect(i.search("abc")["a"]?.match == "ＡＢＣ")
        #expect(i.search("123").keys.contains("a"))
    }

    @Test func whitespaceRunsAndParagraphBreaksMatchOneSpace() {
        let i = index()
        // "operators.\n\nThe café" in the transcript.
        #expect(i.search("operators.  the   CAFE")["en"] != nil)
        #expect(i.search("   ").isEmpty)
        #expect(i.search("").isEmpty)
    }

    @Test func snippetKeepsShortLeadAndCutsAtAWord() throws {
        let s = try #require(index().search("espresso")["en"])
        #expect(s.match == "espresso")
        #expect(s.before.hasPrefix("…"))
        #expect(s.before == "…a naïve ")  // 14 characters back would land mid-word
        #expect(s.after.hasPrefix(", and RÉSUMÉ"))
        #expect(!s.text.contains("\n"))
    }

    @Test func snippetForCJKHasLeadByCharacters() throws {
        let s = try #require(index().search("自然语言")["zh"])
        #expect(s.before == "…下一个话题是")  // " 下一个话题是" is 13 columns; "。" would make 15
        #expect(s.match == "自然语言")
        #expect(s.after == "处理。")
        let start = try #require(index().search("大家好")["zh"])
        #expect(start.before == "")
    }

    @Test func countsOccurrences() {
        var i = TranscriptSearchIndex()
        i.set("a", stamp: "1", text: "the cat and the hat and THE bat")
        #expect(i.search("the")["a"]?.count == 3)
        i.set("b", stamp: "1", text: String(repeating: "ab", count: 2000))
        #expect(i.search("ab")["b"]?.count == TranscriptSearchIndex.countCap)
    }

    @Test func staleAndPrune() {
        var i = index()
        #expect(i.stale(["en": "1", "zh": "2", "new": "1"]) == ["new", "zh"])
        i.set("zh", stamp: "2", text: "替换后的文本")
        #expect(i.search("机器").isEmpty)
        #expect(i.search("替换").keys.contains("zh"))
        i.prune(keeping: ["zh"])
        #expect(!i.contains("en") && i.count == 1)
    }

    @Test func searchableTextFromTranscriptJSON() throws {
        let obj: [String: Any] = ["text": "joined text", "segments": [["text": "First part.", "start": 0, "end": 30],
                                                                      ["text": "Second part.", "start": 30, "end": 40]],
                                  "words": [["text": "First", "start": 0.1, "end": 0.4]]]
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(TranscriptSearchIndex.searchableText(transcriptJSON: data) == "First part.\nSecond part.")
        let bare = try JSONSerialization.data(withJSONObject: ["text": "only text", "segments": []])
        #expect(TranscriptSearchIndex.searchableText(transcriptJSON: bare) == "only text")
        #expect(TranscriptSearchIndex.searchableText(transcriptJSON: Data("nope".utf8)) == nil)
    }

    @Test func previewMatchesFindEveryOccurrenceAndCrossParagraphs() {
        let text = "Café one.\n\nCafe two, and the end.\n\nThe END"
        let ns = text as NSString
        #expect(TranscriptSearchIndex.matches(of: "cafe", in: text).map { ns.substring(with: $0) } == ["Café", "Cafe"])
        #expect(TranscriptSearchIndex.matches(of: "end", in: text).count == 2)
        #expect(TranscriptSearchIndex.matches(of: "one. cafe", in: text).map { ns.substring(with: $0) } == ["one.\n\nCafe"])
        #expect(TranscriptSearchIndex.matches(of: "  ", in: text).isEmpty)
        let zh = "机器学习在医疗。\n\n机器学习"
        #expect(TranscriptSearchIndex.matches(of: "机器学习", in: zh).map(\.location) == [0, 10])
    }

    /// Hundreds of hour-long transcripts: building is linear and a keystroke's search stays fast.
    @Test func staysFastWithHundredsOfLongEntries() {
        let paragraph = "This is a fairly ordinary sentence about the weather and the news of the day, repeated for length. "
        let long = String(repeating: paragraph, count: 600) // ~60 KB, about an hour of speech
        var i = TranscriptSearchIndex()
        let build = ContinuousClock().measure {
            for n in 0..<300 { i.set("e\(n)", stamp: "1", text: n == 150 ? long + " needle phrase here" : long) }
        }
        var hits: [String: SearchSnippet] = [:]
        let search = ContinuousClock().measure { hits = i.search("needle phrase") }
        #expect(Set(hits.keys) == ["e150"])
        #expect(search < .milliseconds(250), "search took \(search)")
        #expect(build < .seconds(20), "build took \(build)")
    }
}

@Suite struct AlignOfferTests {
    @Test func offeredOnlyWhenAlignmentWasOffAndTheLanguageHasAnAligner() {
        let aligned = ["Chinese", "English"]
        #expect(AlignOffer.make(timing: .notAligned, language: "English", alignedLanguages: aligned, sourceMissing: false) == .available)
        #expect(AlignOffer.make(timing: .notAligned, language: "zh", alignedLanguages: aligned, sourceMissing: false) == .available)
        #expect(AlignOffer.make(timing: .notAligned, language: "English", alignedLanguages: aligned, sourceMissing: true) == .needsSource)
        // Alignment was off, but Dutch has no aligner: aligning wouldn't help.
        #expect(AlignOffer.make(timing: .notAligned, language: "Dutch", alignedLanguages: aligned, sourceMissing: false) == .none)
        #expect(AlignOffer.make(timing: .noAligner(language: "Dutch"), language: "Dutch", alignedLanguages: aligned, sourceMissing: false) == .none)
        #expect(AlignOffer.make(timing: nil, language: "English", alignedLanguages: aligned, sourceMissing: false) == .none)
        #expect(AlignOffer.make(timing: .alignmentFailed, language: "English", alignedLanguages: aligned, sourceMissing: false) == .none)
        // The backend's languages aren't known yet.
        #expect(AlignOffer.make(timing: .notAligned, language: "English", alignedLanguages: [], sourceMissing: false) == .none)
        #expect(AlignOffer.make(timing: .notAligned, language: nil, alignedLanguages: aligned, sourceMissing: false) == .none)
    }
}

@Suite struct AlignProtocolTests {
    @Test func encodesTheAlignOp() throws {
        let line = ServeOp.align(ServeAlign(id: "a1", transcript: "/l/t.json", source: "/s/a.m4a", output: "/l/.staging/x/transcript.json")).encoded()
        let obj = try #require(try JSONSerialization.jsonObject(with: line) as? [String: String])
        #expect(obj == ["op": "align", "id": "a1", "transcript": "/l/t.json", "source": "/s/a.m4a", "output": "/l/.staging/x/transcript.json"])
        let bare = try #require(try JSONSerialization.jsonObject(with: ServeOp.align(ServeAlign(id: "a2", transcript: "/t", source: "/s")).encoded()) as? [String: String])
        #expect(bare["output"] == nil)
    }

    @Test func decodesAlignReplies() {
        let done = ServeEvent.decode(#"{"event":"aligned","id":"a1","transcript":"/o.json","cue_timing":"aligned","notices":[{"code":"truncated","message":"m","spans":null}]}"#)
        guard case .aligned(let id, let path, let timing, let notices)? = done else { Issue.record("\(String(describing: done))"); return }
        #expect(id == "a1" && path == "/o.json" && timing == .aligned && notices.map(\.code) == [.truncated])
        #expect(ServeEvent.decode(#"{"event":"align_error","id":"a1","message":"no forced aligner for Dutch"}"#)
            == .alignError(id: "a1", message: "no forced aligner for Dutch", cancelled: false))
        #expect(ServeEvent.decode(#"{"event":"align_error","id":"a1","message":"cancelled","cancelled":true}"#)
            == .alignError(id: "a1", message: "cancelled", cancelled: true))
        #expect(ServeEvent.decode(#"{"event":"aligned"}"#) == .unknown(event: "aligned"))
    }
}

@Suite struct CommitAlignmentTests {
    @Test func replacesTheMasterAndDropsTimedCaches() throws {
        let s = try Scratch()
        var store = try s.store()
        let src = try s.file("talk.m4a")
        let (staging, result) = try s.job(store, source: src, formats: ["md", "srt", "vtt"])
        var r = result
        r.cueTiming = nil
        let entry = try store.commit(.init(staging: staging, source: src, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b"), result: r))
        #expect(entry.cueTiming == nil && Set(entry.formats.keys) == ["md", "srt", "vtt"])
        let folder = store.folderURL(entry)

        let out = try store.makeAlignStaging()
        try Data(#"{"text":"Hello there.","cue_timing":"aligned"}"#.utf8).write(to: out)
        let updated = try #require(try store.commitAlignment(entry.id, aligned: out, cueTiming: .aligned, noticeCount: 0,
                                                             date: Date(timeIntervalSince1970: 1_800_000_000.7)))
        #expect(updated.cueTiming == .aligned && updated.noticeCount == 0)
        #expect(updated.aligned == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(updated.revision != entry.revision && updated.updated == entry.updated)
        #expect(Set(updated.formats.keys) == ["md"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["talk.md", "transcript.json"])
        #expect(try String(contentsOf: store.transcriptURL(updated), encoding: .utf8).contains("\"aligned\""))
        // Staging is cleaned up and the index on disk agrees.
        #expect(!FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path))
        #expect(try s.store()[entry.id] == updated)
        #expect(s.trashed.isEmpty)
    }

    @Test func missingOutputLeavesTheEntryAlone() throws {
        let s = try Scratch()
        var store = try s.store()
        let src = try s.file("a.wav")
        let (staging, result) = try s.job(store, source: src)
        let entry = try store.commit(.init(staging: staging, source: src, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b"), result: result))
        let ghost = store.stagingRoot.appendingPathComponent("nope/transcript.json")
        #expect(throws: LibraryError.missingTranscript) {
            try store.commitAlignment(entry.id, aligned: ghost, cueTiming: .aligned, noticeCount: 0)
        }
        #expect(store[entry.id] == entry)
        #expect(try store.commitAlignment("unknown", aligned: ghost, cueTiming: .aligned, noticeCount: 0) == nil)
    }

    @Test func transcribeAgainClearsAligned() throws {
        let s = try Scratch()
        var store = try s.store()
        let src = try s.file("a.wav")
        let (st1, r1) = try s.job(store, source: src)
        let entry = try store.commit(.init(staging: st1, source: src, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b"), result: r1))
        let out = try store.makeAlignStaging()
        try Data("{}".utf8).write(to: out)
        _ = try store.commitAlignment(entry.id, aligned: out, cueTiming: .aligned, noticeCount: 0)
        #expect(store[entry.id]?.aligned != nil)
        let (st2, r2) = try s.job(store, source: src)
        let again = try store.commit(.init(staging: st2, source: src, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "0.6b"), result: r2, replacing: entry.id))
        #expect(again.aligned == nil)
    }
}
