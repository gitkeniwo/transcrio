import Foundation
import Testing
@testable import TranscribeKit

@Suite struct ExportProtocolTests {
    @Test func exportOpEncodesTheWireFormat() throws {
        let op = ServeOp.export(ServeExport(id: "x1", transcript: "/lib/a (1)/transcript.json", formats: ["srt", "md"],
                                            outputDir: "/lib/a (1)", timestamps: true, title: "a"))
        let data = op.encoded()
        #expect(data.last == 0x0A)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["op"] as? String == "export")
        #expect(obj["id"] as? String == "x1")
        #expect(obj["transcript"] as? String == "/lib/a (1)/transcript.json")
        #expect(obj["formats"] as? [String] == ["srt", "md"])
        #expect(obj["output_dir"] as? String == "/lib/a (1)")
        #expect(obj["timestamps"] as? Bool == true)
        #expect(obj["title"] as? String == "a")

        let untitled = ServeOp.export(ServeExport(id: "x2", transcript: "/t.json", formats: ["md"], outputDir: "/o"))
        let o2 = try JSONSerialization.jsonObject(with: untitled.encoded()) as! [String: Any]
        #expect(o2["title"] == nil)
        #expect(o2["timestamps"] as? Bool == false)
    }

    @Test func exportRepliesDecodeWithoutAJob() {
        let ok = #"{"event":"exported","id":"x1","outputs":{"md":"/o/a.md","srt":"/o/a.srt"},"estimated_cues":true}"#
        #expect(ServeEvent.decode(ok) == .exported(id: "x1", outputs: ["md": "/o/a.md", "srt": "/o/a.srt"], estimatedCues: true))
        #expect(ServeEvent.decode(ok)?.jobID == nil)
        let bare = #"{"event":"exported","id":"x1","outputs":{}}"#
        #expect(ServeEvent.decode(bare) == .exported(id: "x1", outputs: [:], estimatedCues: false))
        let err = #"{"event":"export_error","id":"x3","message":"no such transcript"}"#
        #expect(ServeEvent.decode(err) == .exportError(id: "x3", message: "no such transcript"))
        #expect(ServeEvent.decode(err)?.jobID == nil)
    }

    @Test func emptyFormatsAreSentWhenATranscriptPathIsSet() throws {
        var o = TranscribeOptions()
        o.formats = []
        var job = ServeJob(id: "j", url: URL(fileURLWithPath: "/a.m4a"), options: o)
        job.transcriptPath = "/s/transcript.json"
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        #expect(obj["formats"] as? [String] == [])
        #expect(obj["transcript_path"] as? String == "/s/transcript.json")
    }
}

@Suite struct ExportNamingTests {
    @Test func fileNamesAreSanitized() {
        #expect(ExportNaming.fileName(title: "podcast-ep12", format: .srt) == "podcast-ep12.srt")
        #expect(!ExportNaming.fileName(title: "a/b", format: .md).contains("/"))
    }

    @Test func aNameInUseGetsTwoThenThree() {
        let dir = URL(fileURLWithPath: "/d")
        var existing: Set<String> = []
        let exists: (URL) -> Bool = { existing.contains($0.lastPathComponent) }
        #expect(ExportNaming.available("x.md", in: dir, exists: exists).lastPathComponent == "x.md")
        existing = ["x.md"]
        #expect(ExportNaming.available("x.md", in: dir, exists: exists).lastPathComponent == "x 2.md")
        existing = ["x.md", "x 2.md"]
        #expect(ExportNaming.available("x.md", in: dir, exists: exists).lastPathComponent == "x 3.md")
        #expect(ExportNaming.available("x.md", in: dir, taken: ["x 3.md"], exists: exists).lastPathComponent == "x 4.md")
        existing = ["README"]
        #expect(ExportNaming.available("README", in: dir, exists: exists).lastPathComponent == "README 2")
    }

    @Test func formatOrderAndTimestamps() {
        #expect(OutputFormat.ordered([.json, .srt, .md, .srt]) == [.md, .srt, .json])
        #expect(OutputFormat.preparable == [.md, .txt, .srt, .vtt])
        #expect(OutputFormat.md.takesTimestamps && OutputFormat.txt.takesTimestamps)
        #expect(!OutputFormat.srt.takesTimestamps && !OutputFormat.json.takesTimestamps)
    }
}

@Suite struct EstimatedTimingTests {
    let estimated = Notice(code: .timingEstimated, message: "subtitle timing is estimated for part of the audio (language without forced aligner)")
    let failed = Notice(code: .alignmentFailed, message: "alignment failed for 12:00–14:00")

    @Test func alignedHasNoReason() {
        #expect(EstimatedTiming.reason(cueTiming: .aligned, notices: [], language: "English") == nil)
    }

    @Test func noCuesMeansAlignWasOff() {
        let r = EstimatedTiming.reason(cueTiming: nil, notices: [], language: "English")
        #expect(r == .notAligned)
        #expect(r?.message.contains("Settings → Library") == true)
    }

    /// Regression: align was on, the language has no aligner.
    @Test func languageWithoutAlignerIsNotBlamedOnSettings() {
        let r = EstimatedTiming.reason(cueTiming: .estimated, notices: [estimated], language: "Klingon")
        #expect(r == .noAligner(language: "Klingon"))
        // English has an aligner: estimated cues there mean alignment was off.
        #expect(EstimatedTiming.reason(cueTiming: .estimated, notices: [estimated], language: "English",
                                       alignedLanguages: ["Chinese", "English"]) == .notAligned)
        #expect(EstimatedTiming.reason(cueTiming: .estimated, notices: [estimated], language: "Dutch",
                                       alignedLanguages: ["Chinese", "English"]) == .noAligner(language: "Dutch"))
        #expect(r?.message.contains("Settings") == false)
        #expect(r?.message.contains("no forced aligner") == true)
        #expect(EstimatedTiming.reason(cueTiming: .mixed, notices: [estimated], language: nil) == .partlyNoAligner)
    }

    @Test func alignmentFailureWins() {
        #expect(EstimatedTiming.reason(cueTiming: .mixed, notices: [estimated, failed], language: "English") == .alignmentFailed)
        #expect(EstimatedTiming.reason(cueTiming: .estimated, notices: [failed], language: "English") == .alignmentFailed)
    }

    @Test func cuesEstimatedCountsMissingCues() {
        var e = LibraryEntry(title: "t", folder: "t", fingerprint: SourceFingerprint(size: 1, hash: "a"), sourcePath: "/t.mp3",
                             kind: .audio, created: Date(), updated: Date(), options: EntryOptions(model: "1.7b"))
        #expect(e.cuesEstimated)
        e.cueTiming = .aligned
        #expect(!e.cuesEstimated)
        e.cueTiming = .mixed
        #expect(e.cuesEstimated)
    }
}

@Suite struct CopyPlanTests {
    let source = URL(fileURLWithPath: "/Users/me/Audio/podcast-ep12.mp3")

    @Test func offWritesNothing() {
        #expect(CopyPlan(options: TranscribeOptions(), source: source) == nil)
        #expect(CopyPlan.caption(options: TranscribeOptions(), sourceName: "podcast-ep12.mp3") == "")
    }

    @Test func nextToSource() {
        var o = TranscribeOptions(copyMode: .nextToSource, copyFormats: [.srt, .md])
        let plan = try! #require(CopyPlan(options: o, source: source))
        #expect(plan.directory.path == "/Users/me/Audio")
        #expect(plan.names(source: source) == ["podcast-ep12.md", "podcast-ep12.srt"])
        #expect(CopyPlan.caption(options: o, sourceName: "podcast-ep12.mp3")
            == "Writes podcast-ep12.md and podcast-ep12.srt next to the source. Off: a name in use gets “ 2”.")
        o.overwrite = true
        #expect(CopyPlan.caption(options: o, sourceName: "podcast-ep12.mp3").hasSuffix("A file with the same name is replaced."))
    }

    @Test func folderNeedsAFolder() {
        var o = TranscribeOptions(copyMode: .folder)
        #expect(CopyPlan(options: o, source: source) == nil)
        o.outputDirectory = URL(fileURLWithPath: "/tmp/out")
        #expect(CopyPlan(options: o, source: source)?.directory.path == "/tmp/out")
    }

    @Test func destinationsKeepBothUnlessReplacing() {
        let o = TranscribeOptions(copyMode: .nextToSource, copyFormats: [.md, .txt, .srt])
        let plan = CopyPlan(options: o, source: source)!
        let exists: (URL) -> Bool = { $0.lastPathComponent == "podcast-ep12.md" }
        let d = plan.destinations(source: source, exists: exists).map(\.url.lastPathComponent)
        #expect(d == ["podcast-ep12 2.md", "podcast-ep12.txt", "podcast-ep12.srt"])
        var r = o
        r.overwrite = true
        #expect(CopyPlan(options: r, source: source)!.destinations(source: source, exists: exists).first?.url.lastPathComponent
            == "podcast-ep12.md")
    }

    @Test func captionListsThreeOrMore() {
        let o = TranscribeOptions(copyMode: .nextToSource, copyFormats: [.vtt, .txt, .md])
        #expect(CopyPlan.caption(options: o, sourceName: "a.wav").hasPrefix("Writes a.md, a.txt and a.vtt next to the source."))
        #expect(CopyPlan.caption(options: o, sourceName: nil).hasPrefix("Writes .md, .txt and .vtt copies next to each source."))
    }
}

@Suite struct ExportOptionsTests {
    @Test func legacyOptionsDecodeWithCopiesOff() throws {
        let old = #"{"formats":["md"],"timestamps":true,"model":"1.7b","contextTerms":[],"overwrite":false}"#
        let o = try JSONDecoder().decode(TranscribeOptions.self, from: Data(old.utf8))
        #expect(o.copyMode == .off)
        #expect(o.copyFormats == [.md])
        #expect(o.timestamps)
        let round = try JSONDecoder().decode(TranscribeOptions.self, from: JSONEncoder().encode(
            TranscribeOptions(copyMode: .folder, copyFormats: [.srt])))
        #expect(round.copyMode == .folder && round.copyFormats == [.srt])
    }

    @Test func noFormatsIsAllowedButCopiesNeedOne() {
        var q = QueueModel()
        let id = q.add([URL(fileURLWithPath: "/a.m4a")], options: TranscribeOptions())[0]
        q.setOptions([id]) { $0.formats = []; $0.copyFormats = [] }
        #expect(q[id]?.options.formats == [])
        #expect(q[id]?.options.copyFormats == [.md])
    }

    @Test func copiesAreOneOptionField() {
        let d = TranscribeOptions()
        var o = d
        o.copyFormats = [.srt]
        #expect(o.differences(from: d).isEmpty, "formats don't matter while copies are off")
        o.copyMode = .nextToSource
        #expect(o.differences(from: d) == [.copies])
        let m = MixedOptions([d, o])
        #expect(m.isMixed(.copies))
        #expect(!MixedOptions([o, o]).isMixed(.copies))
    }

    @Test func timestampsMigrateOnce() throws {
        let name = "export-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: ExportSettings.legacyTimestampsKey)
        ExportSettings.migrate(d)
        #expect(ExportSettings.timestamps(d))
        #expect(d.bool(forKey: ExportSettings.legacyTimestampsKey), "the old key stays for copies")
        d.set(false, forKey: ExportSettings.timestampsKey)
        ExportSettings.migrate(d)
        #expect(!ExportSettings.timestamps(d), "a second launch doesn't copy again")
    }

    @Test func freshInstallHasTimestampsOffAndMdLast() throws {
        let name = "export-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        ExportSettings.migrate(d)
        #expect(!ExportSettings.timestamps(d))
        #expect(ExportSettings.lastFormat(d) == .md)
        d.set("srt", forKey: ExportSettings.lastFormatKey)
        #expect(ExportSettings.lastFormat(d) == .srt)
    }

    @Test func wordCounts() {
        #expect(WordCount.count("Hello there, world.") == 3)
        #expect(WordCount.copiedMessage("one") == "Copied 1 word")
        #expect(WordCount.copiedMessage(Array(repeating: "w", count: 6412).joined(separator: " ")) == "Copied 6,412 words")
    }
}

@Suite struct LibraryFormatCacheTests {
    @Test func commitRecordsTheTimestampsVariant() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("talk.mp3")
        let (staging, result) = try s.job(store, source: source, formats: ["md", "srt"])
        let entry = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b", language: nil), result: result,
                                           timestamps: true))
        #expect(entry.variants == ["md": true])
        #expect(entry.has(.md, timestamps: true))
        #expect(!entry.has(.md, timestamps: false))
        #expect(entry.has(.srt, timestamps: false) && entry.has(.srt, timestamps: true))
        #expect(!entry.has(.vtt, timestamps: false))
        #expect(entry.has(.json, timestamps: false))
        #expect(store.cachedURL(entry, .md, timestamps: true)?.lastPathComponent == "talk.md")
        #expect(store.cachedURL(entry, .md, timestamps: false) == nil)
        #expect(store.cachedURL(entry, .json, timestamps: false)?.lastPathComponent == "transcript.json")
        #expect(try s.store()[entry.id]?.variants == ["md": true])
    }

    @Test func recordFormatsKeepsOnlyFilesInTheEntryFolder() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("talk.mp3")
        let (staging, result) = try s.job(store, source: source, formats: ["md"])
        let entry = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: nil,
                                           options: EntryOptions(model: "1.7b", language: nil), result: result))
        let folder = store.folderURL(entry)
        let updated = try #require(try store.recordFormats(entry.id, outputs: [
            "vtt": folder.appendingPathComponent("talk.vtt").path,
            "md": folder.appendingPathComponent("talk.md").path,
            "txt": "/elsewhere/talk.txt",
            "json": folder.appendingPathComponent("talk.json").path,
        ], timestamps: true))
        #expect(updated.formats == ["md": "talk.md", "vtt": "talk.vtt"])
        #expect(updated.variants == ["md": true])
        #expect(try s.store()[entry.id]?.formats["vtt"] == "talk.vtt")

        // The vtt file was never written: forgotten.
        try store.forgetMissingFormats(entry.id)
        #expect(store[entry.id]?.formats == ["md": "talk.md"])
    }

    @Test func relocateTakesTheFingerprintWhenGiven() throws {
        let s = try Scratch()
        var store = try s.store()
        let source = try s.file("talk.mp3")
        let fp = try SourceFingerprint.read(source)
        let (staging, result) = try s.job(store, source: source)
        let entry = try store.commit(.init(staging: staging, source: source, kind: .audio, fingerprint: fp,
                                           options: EntryOptions(model: "1.7b", language: nil), result: result))
        let moved = try s.file("renamed.mp3")
        try store.relocate(entry.id, to: moved, fingerprint: nil)
        #expect(store[entry.id]?.sourcePath == moved.standardizedFileURL.path)
        #expect(store[entry.id]?.fingerprint == fp)
        let other = try s.file("other.mp3", seed: 9)
        let otherFP = try SourceFingerprint.read(other)
        try store.relocate(entry.id, to: other, fingerprint: otherFP)
        #expect(store.entry(matching: otherFP)?.id == entry.id)
        #expect(try s.store()[entry.id]?.sourcePath == other.standardizedFileURL.path)
    }
}
