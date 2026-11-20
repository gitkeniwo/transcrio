import Foundation
import Testing
@testable import TranscribeKit

/// Per-file options: differences from the defaults, the row summary, and Mixed values.
struct OptionsComparisonTests {
    let defaults = TranscribeOptions(formats: [.md], language: nil, model: .accurate)

    @Test func noDifferencesForTheDefaults() {
        #expect(defaults.differences(from: defaults).isEmpty)
        #expect(defaults.differenceDescription(from: defaults) == nil)
        // Order of formats and "auto" vs nil don't count as changes.
        let same = TranscribeOptions(formats: [.md], language: "auto", contextTerms: ["  "])
        #expect(same.differences(from: defaults).isEmpty)
        let a = TranscribeOptions(formats: [.srt, .md]), b = TranscribeOptions(formats: [.md, .srt])
        #expect(a.differences(from: b).isEmpty)
    }

    @Test func differencesAreListedInInspectorOrder() {
        let o = TranscribeOptions(formats: [.md, .srt], timestamps: true, language: "en", model: .fast,
                                  contextTerms: ["Marlowe"], overwrite: true)
        #expect(o.differences(from: defaults) == [.formats, .timestamps, .language, .model, .context, .overwrite])
        #expect(o.formatDifferences(from: defaults) == [.srt])
        #expect(TranscribeOptions(outputDirectory: URL(fileURLWithPath: "/out")).differences(from: defaults)
            == [.outputDirectory])
    }

    @Test func tooltipNamesTheDifferences() {
        let o = TranscribeOptions(formats: [.md, .srt], language: "en")
        #expect(o.differenceDescription(from: defaults) == "Differs from defaults: srt, Language (English)")
        let dropped = TranscribeOptions(formats: [.txt])
        #expect(dropped.differenceDescription(from: defaults) == "Differs from defaults: txt, no md")
    }

    @Test func rowSummary() {
        let o = TranscribeOptions(formats: [.srt, .md], language: "zh")
        #expect(o.summary(duration: 44 * 60 + 2) == "44:02 · md srt · zh")
        #expect(TranscribeOptions().summary(duration: 65) == "1:05 · md · auto")
        #expect(TranscribeOptions(model: .fast).summary(duration: 65) == "1:05 · md · auto · 0.6B")
        #expect(TranscribeOptions().summary(duration: nil) == "–:–– · md · auto")
    }

    @Test func mixedAcrossThreeFiles() {
        let files = [
            TranscribeOptions(formats: [.md, .srt], language: "zh", model: .accurate),
            TranscribeOptions(formats: [.md], language: "zh", model: .fast),
            TranscribeOptions(formats: [.md], timestamps: true, language: "zh", model: .accurate),
        ]
        let m = MixedOptions(files)
        #expect(m.count == 3)
        #expect(m.format(.md) == .on)
        #expect(m.format(.srt) == .mixed(count: 1, of: 3))
        #expect(m.format(.txt) == .off)
        #expect(m.language == .same("zh"))
        #expect(m.model == .mixed)
        #expect(m.timestamps == .mixed)
        #expect(m.overwrite == .same(false))
        #expect(m.isMixed(.formats) && m.isMixed(.model) && m.isMixed(.timestamps))
        #expect(!m.isMixed(.language))
        #expect(m.mixedCount == 3)
        // One click on a mixed tile turns it on for all; on an all-on tile, off.
        #expect(m.toggledFormat(.srt) == true)
        #expect(m.toggledFormat(.md) == false)
        #expect(m.toggledFormat(.txt) == true)
    }

    @Test func mixedOfIdenticalFilesHasNoMixedFields() {
        let m = MixedOptions([defaults, defaults])
        #expect(m.mixedCount == 0)
        #expect(m.model == .same(.accurate))
    }

    @Test func clipboardRoundTrip() throws {
        let o = TranscribeOptions(formats: [.vtt, .json], timestamps: true, outputDirectory: URL(fileURLWithPath: "/o"),
                                  language: "ja", model: .fast, contextTerms: ["a", "b"], overwrite: true)
        let data = try #require(OptionsClipboard.encode(o))
        #expect(OptionsClipboard.decode(data) == o)
        #expect(OptionsClipboard.decode(Data("junk".utf8)) == nil)
    }
}
