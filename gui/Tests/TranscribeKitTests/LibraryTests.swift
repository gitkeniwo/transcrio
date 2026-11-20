import Foundation
import Testing
@testable import TranscribeKit

/// A scratch folder per test, with a fake Trash beside the library.
final class Scratch: @unchecked Sendable {
    let dir: URL
    var root: URL { dir.appendingPathComponent("Library", isDirectory: true) }
    var trashDir: URL { dir.appendingPathComponent("Trash", isDirectory: true) }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Trash"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var trash: @Sendable (URL) throws -> Void {
        let t = trashDir
        return { url in try FileManager.default.moveItem(at: url, to: t.appendingPathComponent(url.lastPathComponent)) }
    }

    func store() throws -> LibraryStore { try LibraryStore(root: root, trash: trash) }

    func file(_ name: String, bytes: Int = 1000, seed: UInt8 = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: url)
        return url
    }

    var trashed: [String] { (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? [] }

    /// A staging folder as the worker leaves it on file_done.
    func job(_ store: LibraryStore, source: URL, text: String = "Hello there.", formats: [String] = ["md", "srt"],
             writeTranscript: Bool = true) throws -> (URL, FileResult) {
        let staging = try store.makeStaging()
        let stem = source.deletingPathExtension().lastPathComponent
        var outputs: [String: String] = [:]
        for f in formats {
            let u = staging.appendingPathComponent("\(stem).\(f)")
            try "\(f): \(text)".write(to: u, atomically: true, encoding: .utf8)
            outputs[f] = u.path
        }
        let transcript = staging.appendingPathComponent("transcript.json")
        if writeTranscript {
            let obj: [String: Any] = ["text": text, "language": "English", "duration": 12.5, "model": "Qwen/Qwen3-ASR-0.6B",
                                      "segments": [["text": text, "start": 0.0, "end": 12.5, "speaker": NSNull()]],
                                      "cue_timing": "aligned", "warnings": [], "notices": []]
            try JSONSerialization.data(withJSONObject: obj).write(to: transcript)
        }
        let result = FileResult(outputs: outputs, elapsed: 3, language: "English", duration: 12.5, model: "Qwen/Qwen3-ASR-0.6B",
                                cueTiming: .aligned, segments: [TranscriptSegment(start: 0, end: 12.5, text: text)],
                                transcript: writeTranscript ? transcript.path : nil)
        return (staging, result)
    }
}

@Suite struct FingerprintTests {
    @Test func sameContentSameFingerprintAnywhere() throws {
        let s = try Scratch()
        let a = try s.file("a.m4a", bytes: 5000)
        let b = try s.file("renamed copy.m4a", bytes: 5000)
        let c = try s.file("other.m4a", bytes: 5000, seed: 2)
        #expect(try SourceFingerprint.read(a) == SourceFingerprint.read(b))
        #expect(try SourceFingerprint.read(a) != SourceFingerprint.read(c))
        #expect(try SourceFingerprint.read(a).size == 5000)
    }

    @Test func largeFilesHashOnlyTheEdges() throws {
        let s = try Scratch()
        let url = try s.file("big.wav", bytes: 300)
        let base = try SourceFingerprint.read(url, edge: 100)
        // Change a byte in the middle (not covered): same fingerprint.
        var data = try Data(contentsOf: url)
        data[150] ^= 0xFF
        try data.write(to: url)
        #expect(try SourceFingerprint.read(url, edge: 100) == base)
        // Change a byte in the tail: different.
        data[290] ^= 0xFF
        try data.write(to: url)
        #expect(try SourceFingerprint.read(url, edge: 100) != base)
    }

    @Test func stringFormRoundTrips() throws {
        let fp = SourceFingerprint(size: 42, hash: "abc")
        #expect(fp.description == "42:abc")
        #expect(SourceFingerprint("42:abc") == fp)
        #expect(SourceFingerprint("nope") == nil)
        let data = try JSONEncoder().encode([fp])
        #expect(String(decoding: data, as: UTF8.self) == "[\"42:abc\"]")
        #expect(try JSONDecoder().decode([SourceFingerprint].self, from: data) == [fp])
    }

    @Test func computeIsNilForMissingFiles() async {
        #expect(await SourceFingerprint.compute(URL(fileURLWithPath: "/nonexistent/x.m4a")) == nil)
    }
}

@Suite struct LibraryStoreTests {
    @Test func missingIndexIsAnEmptyLibraryAndNothingIsCreated() throws {
        let s = try Scratch()
        let store = try s.store()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.root.path))
    }

    @Test func unreadableIndexThrowsInsteadOfStartingOver() throws {
        let s = try Scratch()
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: s.root.appendingPathComponent("library.json"))
        #expect(throws: LibraryError.self) { try s.store() }
    }

    @Test func commitMovesStagingIntoAnEntryFolderAndPersists() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("podcast-ep12.mp3")
        let fp = try SourceFingerprint.read(source)
        let (staging, result) = try s.job(store, source: source)
        let entry = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: fp,
                                           options: EntryOptions(model: "0.6b", language: "en"), result: result,
                                           overview: [0.1, 0.5, 0.2]))
        #expect(entry.folder == "podcast-ep12 (\(entry.shortID))")
        #expect(entry.title == "podcast-ep12")
        #expect(entry.formats == ["md": "podcast-ep12.md", "srt": "podcast-ep12.srt"])
        #expect(entry.cueTiming == .aligned)
        #expect(entry.duration == 12.5)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let folder = store.folderURL(entry)
        for name in ["transcript.json", "overview.json", "podcast-ep12.md", "podcast-ep12.srt"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name)")
        }
        #expect(LibraryOverview.load(store.overviewURL(entry))?.rms.count == 3)

        // Reopened: same entries, found by fingerprint.
        let reopened = try s.store()
        #expect(reopened.entries == store.entries)
        #expect(reopened.entry(matching: fp)?.id == entry.id)
        #expect(reopened.outputs(entry)["json"] == store.transcriptURL(entry).path)
        let t = try #require(LibraryTranscript.load(reopened.transcriptURL(entry)))
        #expect(t.segments.count == 1)
        #expect(t.result(entry: entry, outputs: reopened.outputs(entry)).cueTiming == .aligned)
    }

    @Test func folderNamesStayUnique() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("talk.m4a")
        var folders: Set<String> = []
        for i in 0..<3 {
            let (staging, result) = try s.job(store, source: source, text: "\(i)")
            let e = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b"), result: result))
            folders.insert(e.folder)
        }
        #expect(folders.count == 3)
        #expect(LibraryStore.sanitize("a/b:c") == "a-b-c")
        #expect(LibraryStore.sanitize(".hidden") == "_hidden")
        #expect(LibraryStore.sanitize("  ") == "Untitled")
    }

    @Test func oldCLIWithoutTranscriptPathGetsASynthesizedTranscript() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("old.m4a")
        let (staging, result) = try s.job(store, source: source, text: "Old CLI.", formats: ["md"], writeTranscript: false)
        let entry = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b"), result: result))
        let t = try #require(LibraryTranscript.load(store.transcriptURL(entry)))
        #expect(t.text == "Old CLI.")
        #expect(t.segments == [TranscriptSegment(start: 0, end: 12.5, text: "Old CLI.")])
    }

    @Test func jsonOutputBecomesTheTranscript() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("j.m4a")
        let (staging, result) = try s.job(store, source: source, formats: ["md", "json"], writeTranscript: false)
        let entry = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b"), result: result))
        #expect(entry.formats == ["md": "j.md"])
        #expect(try String(contentsOf: store.transcriptURL(entry), encoding: .utf8) == "json: Hello there.")
        #expect(!FileManager.default.fileExists(atPath: store.folderURL(entry).appendingPathComponent("j.json").path))
    }

    @Test func transcribeAgainReplacesAndTrashesTheOldFiles() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("ep.m4a")
        let fp = try SourceFingerprint.read(source)
        let (st1, r1) = try s.job(store, source: source, text: "first", formats: ["md", "srt"])
        let first = try store.commit(.init(staging: st1, source: source, kind: .audio, fingerprint: fp,
                                           options: EntryOptions(model: "1.7b"), result: r1,
                                           date: Date(timeIntervalSince1970: 1_000_000)))
        let (st2, r2) = try s.job(store, source: source, text: "second", formats: ["txt"])
        let again = try store.commit(.init(staging: st2, source: source, kind: .audio, fingerprint: fp,
                                           options: EntryOptions(model: "0.6b"), result: r2, replacing: first.id))
        #expect(again.id == first.id)
        #expect(again.folder == first.folder)
        #expect(again.created == first.created)
        #expect(again.updated > first.updated)
        #expect(again.options.model == "0.6b")
        #expect(again.formats == ["txt": "ep.txt"])
        #expect(store.entries.count == 1)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: store.folderURL(again).path))
        #expect(names == ["transcript.json", "ep.txt"])
        #expect(LibraryTranscript.load(store.transcriptURL(again))?.text == "second")
        // The old files went to the Trash together.
        #expect(s.trashed.count == 1)
        let old = s.trashDir.appendingPathComponent(s.trashed[0])
        #expect(s.trashed[0].hasPrefix("\(first.folder) (replaced "))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: old.path)) == ["transcript.json", "ep.md", "ep.srt"])
        #expect(!FileManager.default.fileExists(atPath: st2.path))
        #expect(try s.store().entries == store.entries)
    }

    @Test func removeTrashesTheFolderAndDropsTheEntry() throws {
        let s = try Scratch()
        var store = try s.store()
        let a = try s.file("a.m4a"), b = try s.file("b.m4a", seed: 3)
        var ids: [String] = []
        for src in [a, b] {
            let (st, r) = try s.job(store, source: src)
            ids.append(try store.commit(.init(staging: st, source: src, kind: .audio, fingerprint: nil,
                                              options: EntryOptions(model: "1.7b"), result: r)).id)
        }
        let folder = store.folderURL(store[ids[0]]!)
        try store.remove([ids[0]])
        #expect(store.entries.map(\.id) == [ids[1]])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(s.trashed == [folder.lastPathComponent])
        #expect(try s.store().entries.map(\.id) == [ids[1]])
    }

    @Test func updateSourceRemembersTheNewPath() throws {
        let s = try Scratch()
        var store = try s.store()
        let src = try s.file("x.m4a")
        let (st, r) = try s.job(store, source: src)
        let e = try store.commit(.init(staging: st, source: src, kind: .audio, fingerprint: nil, options: EntryOptions(model: "1.7b"), result: r))
        try store.updateSource(e.id, path: "/elsewhere/x copy.m4a")
        #expect(try s.store()[e.id]?.sourcePath == "/elsewhere/x copy.m4a")
    }

    @Test func cleanStagingRemovesLeftovers() throws {
        let s = try Scratch()
        let store = try s.store()
        let st = try store.makeStaging()
        try Data("x".utf8).write(to: st.appendingPathComponent("partial.md"))
        store.cleanStaging()
        #expect(!FileManager.default.fileExists(atPath: store.stagingRoot.path))
    }

    @Test func sortedNewestFirstByDefault() throws {
        let opts = EntryOptions(model: "1.7b")
        func e(_ t: String, _ d: Double, _ dur: Double) -> LibraryEntry {
            LibraryEntry(title: t, folder: t, fingerprint: nil, sourcePath: "/\(t).m4a", kind: .audio,
                         created: Date(timeIntervalSince1970: d), updated: Date(timeIntervalSince1970: d), duration: dur, options: opts)
        }
        let s = try Scratch()
        var store = try s.store()
        let entries = [e("b", 1, 30), e("a", 3, 10), e("c", 2, 20)]
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        try LibraryIndex.encoder.encode(LibraryIndex(entries: entries)).write(to: store.indexURL)
        store = try s.store()
        #expect(store.sorted().map(\.title) == ["a", "c", "b"])
        #expect(store.sorted(by: .title).map(\.title) == ["a", "b", "c"])
        #expect(store.sorted(by: .duration).map(\.title) == ["b", "c", "a"])
    }

    @Test func moveCopiesEverythingThenDeletesTheOld() throws {
        let s = try Scratch()
        var store = try s.store()
        for name in ["one.m4a", "two.m4a"] {
            let src = try s.file(name)
            let (st, r) = try s.job(store, source: src)
            try store.commit(.init(staging: st, source: src, kind: .audio, fingerprint: nil, options: EntryOptions(model: "1.7b"), result: r))
        }
        let dest = s.dir.appendingPathComponent("Moved", isDirectory: true)
        var reports: [LibraryStore.MoveProgress] = []
        let moved = try store.move(to: dest) { reports.append($0); return true }
        #expect(moved.root == dest.standardizedFileURL)
        #expect(moved.entries == store.entries)
        #expect(reports.last?.entriesDone == 2)
        #expect(reports.last?.bytesDone == reports.last?.bytesTotal)
        for e in moved.entries {
            #expect(FileManager.default.fileExists(atPath: moved.transcriptURL(e).path))
            #expect(!FileManager.default.fileExists(atPath: store.folderURL(e).path))
        }
        #expect(!FileManager.default.fileExists(atPath: store.indexURL.path))
        #expect(try LibraryStore(root: dest).entries.count == 2)
        #expect(LibraryStore.existing(at: dest)?.count == 2)
        #expect(LibraryStore.existing(at: s.root) == nil)
    }

    @Test func cancelledMoveLeavesTheLibraryAsItWas() throws {
        let s = try Scratch()
        var store = try s.store()
        for name in ["one.m4a", "two.m4a"] {
            let src = try s.file(name)
            let (st, r) = try s.job(store, source: src)
            try store.commit(.init(staging: st, source: src, kind: .audio, fingerprint: nil, options: EntryOptions(model: "1.7b"), result: r))
        }
        let dest = s.dir.appendingPathComponent("Moved", isDirectory: true)
        #expect(throws: LibraryError.cancelled) { try store.move(to: dest) { $0.entriesDone < 1 } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
        #expect(try s.store().entries.count == 2)
        for e in store.entries { #expect(FileManager.default.fileExists(atPath: store.transcriptURL(e).path)) }
    }

    @Test func overviewRoundTrips() throws {
        let w = Waveform(rms: (0..<1024).map { Float($0 % 50) / 100 })
        let bins = LibraryOverview.bins(from: w)
        #expect(bins.count == LibraryOverview.bins)
        let back = try #require(LibraryOverview.decode(LibraryOverview.encode(bins)))
        #expect(back.rms.count == 200)
        #expect(abs(back.rms[7] - bins[7]) < 0.001)
    }
}

@Suite struct LibraryProtocolTests {
    @Test func jobCarriesAlignAndTranscriptPathOnlyWhenSet() throws {
        var job = ServeJob(id: "j", url: URL(fileURLWithPath: "/a.m4a"), options: TranscribeOptions())
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        #expect(obj["align"] == nil)
        #expect(obj["transcript_path"] == nil)
        job.align = true
        job.transcriptPath = "/lib/.staging/x/transcript.json"
        obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        #expect(obj["align"] as? Bool == true)
        #expect(obj["transcript_path"] as? String == "/lib/.staging/x/transcript.json")
    }

    @Test func fileDoneCarriesTheTranscriptPath() throws {
        let line = #"{"event":"file_done","id":"j","outputs":{"md":"/s/a.md"},"transcript":"/s/transcript.json"}"#
        guard case .fileDone(_, let r)? = ServeEvent.decode(line) else { Issue.record("not file_done"); return }
        #expect(r.transcript == "/s/transcript.json")
    }

    @Test func checkingRowsCanNotStart() {
        var q = QueueModel()
        let ids = q.add([URL(fileURLWithPath: "/a.m4a")])
        q.update(ids[0]) { $0.checking = true }
        q.queue(ids)
        #expect(q[ids[0]]?.state == .ready)
        #expect(q[ids[0]]?.optionsEditable == false)
        q.update(ids[0]) { $0.checking = false }
        q.queue(ids)
        #expect(q[ids[0]]?.state == .queued)
    }
}

@Suite struct HistoryLayoutTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-20T15:00:00Z")!
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let en = Locale(identifier: "en_US")

    @Test func dates() {
        #expect(HistoryDate.short(now.addingTimeInterval(-30), now: now, calendar: cal, locale: en) == "Just now")
        #expect(HistoryDate.short(now.addingTimeInterval(-3600), now: now, calendar: cal, locale: en) == "14:00")
        #expect(HistoryDate.short(now.addingTimeInterval(-2 * 86400), now: now, calendar: cal, locale: en) == "Oct 18")
        #expect(HistoryDate.short(now.addingTimeInterval(-370 * 86400), now: now, calendar: cal, locale: en) == "2025-10-15")
    }

    @Test func collapsedAndEmptyQueue() {
        let c = SidebarSplit.compute(height: 570, queueContent: 300, historyContent: 900, collapsed: true)
        #expect(c == SidebarSplit(queue: 535, history: 35, historyCollapsed: true, resizable: false))
        let e = SidebarSplit.compute(height: 570, queueContent: 0, historyContent: 900, collapsed: false)
        #expect(e.queue == 40 && e.history == 530)
    }

    @Test func bothFitOrOneIsShort() {
        let fit = SidebarSplit.compute(height: 570, queueContent: 200, historyContent: 200, collapsed: false)
        #expect(fit.queue == 200 && fit.history == 370 && !fit.resizable)
        let shortHistory = SidebarSplit.compute(height: 570, queueContent: 900, historyContent: 120, collapsed: false)
        #expect(shortHistory.queue == 450 && shortHistory.history == 120)
        let shortQueue = SidebarSplit.compute(height: 570, queueContent: 150, historyContent: 900, collapsed: false)
        #expect(shortQueue.queue == 150 && shortQueue.history == 420)
    }

    @Test func bothLongUseTheRatioWithinMinimums() {
        let d = SidebarSplit.compute(height: 570, queueContent: 900, historyContent: 900, collapsed: false)
        #expect(d.queue == 342 && d.history == 228 && d.resizable)
        let low = SidebarSplit.compute(height: 570, queueContent: 900, historyContent: 900, collapsed: false, ratio: 0.1)
        #expect(low.queue == 258)
        let high = SidebarSplit.compute(height: 570, queueContent: 900, historyContent: 900, collapsed: false, ratio: 0.95)
        #expect(high.history == 190)
    }

    @Test func tooShortShrinksThenCollapsesHistory() {
        let a = SidebarSplit.compute(height: 400, queueContent: 900, historyContent: 900, collapsed: false)
        #expect(a.queue == 258 && a.history == 142 && !a.historyCollapsed)
        let b = SidebarSplit.compute(height: 320, queueContent: 900, historyContent: 900, collapsed: false)
        #expect(b.historyCollapsed && b.history == 35)
    }

    /// Regression: the drop notice covered History's header and the ringed row. It is in
    /// History's flow now, and History keeps room for header + notice + one row.
    @Test func dropNoticeReservesRoomInHistory() {
        let tight = SidebarSplit.compute(height: 400, queueContent: 600, historyContent: 600, collapsed: false)
        let r = tight.reserving(88, height: 400)
        #expect(r.history == SidebarSplit.header + 88 + SidebarSplit.historyRow)
        #expect(r.queue + r.history == 400)
        #expect(!r.historyCollapsed)
        let roomy = SidebarSplit.compute(height: 900, queueContent: 100, historyContent: 600, collapsed: false)
        #expect(roomy.reserving(88, height: 900) == roomy)
        #expect(roomy.reserving(0, height: 900) == roomy)
        let collapsed = SidebarSplit.compute(height: 300, queueContent: 600, historyContent: 600, collapsed: false)
        #expect(collapsed.historyCollapsed)
        #expect(!collapsed.reserving(88, height: 300).historyCollapsed)
        #expect(SidebarSplit.compute(height: 100, queueContent: 600, historyContent: 600, collapsed: false)
            .reserving(88, height: 100).historyCollapsed, "no room for a row: header and notice only")
    }

    @Test func dragRatioIsClamped() {
        #expect(SidebarSplit.ratio(forQueueHeight: 10, height: 570) == 258.0 / 570)
        #expect(SidebarSplit.ratio(forQueueHeight: 560, height: 570) == 380.0 / 570)
        #expect(SidebarSplit.ratio(forQueueHeight: 300, height: 570) == 300.0 / 570)
    }
}

@Suite struct DropPlanTests {
    func entry(_ title: String, _ fp: SourceFingerprint, updated: Date) -> LibraryEntry {
        LibraryEntry(title: title, folder: title, fingerprint: fp, sourcePath: "/old/\(title).mp3", kind: .audio,
                     created: updated, updated: updated, options: EntryOptions(model: "1.7b"))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fpA = SourceFingerprint(size: 1, hash: "a"), fpB = SourceFingerprint(size: 2, hash: "b"), fpC = SourceFingerprint(size: 3, hash: "c")

    @Test func classifiesNewKnownAndQueued() {
        var q = QueueModel()
        let queued = q.add([URL(fileURLWithPath: "/q/c.mp3")])
        q.update(queued[0]) { $0.fingerprint = self.fpC }
        let lib = [entry("a", fpA, updated: now)]
        let urls = ["/new/a renamed.mp3", "/new/b.mp3", "/other/c copy.mp3", "/new/b.mp3"].map(URL.init(fileURLWithPath:))
        let fps = [urls[0]: fpA, urls[1]: fpB, urls[2]: fpC]
        let plan = DropPlan.make(urls: urls, fingerprints: fps, queue: q.items, library: lib)
        #expect(plan.new == [urls[1]])
        #expect(plan.known.map(\.entry.title) == ["a"])
        #expect(plan.known.first?.url == urls[0])
        #expect(plan.queued == queued)
    }

    @Test func unreadableFilesAreNew() {
        let url = URL(fileURLWithPath: "/x.mp3")
        let plan = DropPlan.make(urls: [url], fingerprints: [:], queue: [], library: [entry("a", fpA, updated: now)])
        #expect(plan.new == [url])
        #expect(plan.notice() == nil)
    }

    @Test func noticeTexts() {
        let cal = Calendar.current
        let earlier = cal.date(byAdding: .day, value: -2, to: now)!
        let one = DropPlan(known: [.init(url: URL(fileURLWithPath: "/p/podcast-ep12.mp3"), entry: entry("podcast-ep12", fpA, updated: earlier))])
        let n1 = one.notice(now: now)
        #expect(n1?.title == "Already transcribed · \(HistoryDate.short(earlier, now: now))")
        #expect(n1?.message == "podcast-ep12.mp3 is in History. Nothing was added to the queue.")
        #expect(n1?.againLabel == "Transcribe Again…")

        let two = DropPlan(known: one.known + [.init(url: URL(fileURLWithPath: "/b.mp3"), entry: entry("b", fpB, updated: earlier))])
        #expect(two.notice(now: now)?.title == "2 files already transcribed")
        #expect(two.notice(now: now)?.message == "Both are selected in History. Nothing was added to the queue.")
        #expect(two.notice(now: now)?.againLabel == "Transcribe 2 Again…")

        var mixed = two
        mixed.new = [URL(fileURLWithPath: "/1"), URL(fileURLWithPath: "/2"), URL(fileURLWithPath: "/3")]
        #expect(mixed.notice(now: now)?.title == "3 added to Ready · 2 already transcribed")
        #expect(mixed.notice(now: now)?.message == "The 2 known files are marked in History.")

        let q = DropPlan(queued: [UUID()])
        #expect(q.notice(now: now)?.title == "Already in the queue")
        #expect(q.notice(now: now)?.again == [])
    }

    @Test func searchAndModelLabel() {
        var e = entry("Weekly Sync", fpA, updated: now)
        e.sourcePath = "/x/meeting-0412.m4a"
        #expect(e.matches("weekly"))
        #expect(e.matches("0412"))
        #expect(!e.matches("zzz"))
        #expect(e.matches(" "))
        #expect(e.modelLabel == "1.7B")
    }
}
