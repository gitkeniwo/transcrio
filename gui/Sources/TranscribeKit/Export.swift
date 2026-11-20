import Foundation

// Export: formats are made from transcript.json by the worker's
// `export` op, cached in the entry folder, and copied out from there (Downloads, Save As…,
// drag-out, copies). The pure pieces live here so they can be tested.

extension OutputFormat {
    /// `Markdown .md` in menus.
    public var menuName: String {
        switch self {
        case .md: "Markdown"
        case .txt: "Plain Text"
        case .srt: "SubRip Subtitles"
        case .vtt: "WebVTT Subtitles"
        case .json: "JSON"
        }
    }

    /// md and txt take the Timestamps switch; srt, vtt and json ignore it.
    public var takesTimestamps: Bool { self == .md || self == .txt }

    /// The order chips and menus use.
    public static let exportOrder: [OutputFormat] = [.md, .txt, .srt, .vtt, .json]
    /// What "Prepare in library" and copies offer (json is the master copy itself).
    public static let preparable: [OutputFormat] = [.md, .txt, .srt, .vtt]

    /// Sorts formats into display order, without duplicates.
    public static func ordered(_ formats: some Sequence<OutputFormat>) -> [OutputFormat] {
        let set = Set(formats)
        return exportOrder.filter(set.contains)
    }
}

/// Finder-style names: a name in use gets " 2", " 3", … before the extension.
public enum ExportNaming {
    /// `<title>.<ext>` made safe for a file name.
    public static func fileName(title: String, format: OutputFormat) -> String {
        "\(LibraryStore.sanitize(title)).\(format.rawValue)"
    }

    /// The first free URL for `name` in `directory`: `name`, then `stem 2.ext`, `stem 3.ext`, …
    /// `taken` adds names already claimed in the same batch.
    public static func available(_ name: String, in directory: URL, taken: Set<String> = [],
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let url = directory.appendingPathComponent(candidate)
            if !taken.contains(candidate), !exists(url) { return url }
            n += 1
        }
    }
}

/// Why srt/vtt timing is estimated. The reason comes from the
/// transcript, not from the current Settings.
public enum EstimatedTiming: Equatable, Sendable {
    /// The transcript has no cues: alignment was off for this run (D3 off).
    case notAligned
    /// Cues exist but were estimated: no forced aligner for the language.
    case noAligner(language: String?)
    /// Some of the audio fell back to estimated timing because alignment failed there.
    case alignmentFailed
    /// Part of the audio is in a language without an aligner.
    case partlyNoAligner

    /// nil when the cues are aligned. `alignedLanguages` (from `backends --json`, names or codes):
    /// estimated cues for a language that has an aligner mean alignment was off, not "no aligner".
    public static func reason(cueTiming: CueTiming?, notices: [Notice], language: String?,
                              alignedLanguages: [String] = []) -> EstimatedTiming? {
        switch cueTiming {
        case .aligned?: return nil
        case nil: return .notAligned
        case .estimated?, .mixed?:
            if notices.contains(where: { $0.code == .alignmentFailed }) { return .alignmentFailed }
            if cueTiming == .mixed { return .partlyNoAligner }
            if let language, alignedLanguages.map(Languages.code(for:)).contains(Languages.code(for: language)) {
                return .notAligned
            }
            return .noAligner(language: language)
        }
    }

    /// The yellow notice under the inspector's Formats card.
    public var message: String {
        switch self {
        case .notAligned:
            "Subtitle timing is estimated: this file wasn’t aligned. srt and vtt can drift by a few seconds. Align subtitles in Settings → Library for future files."
        case .noAligner(let language):
            "Subtitle timing is estimated: there’s no forced aligner for \(language.map { Languages.name(for: Languages.code(for: $0)) } ?? "this language"), so srt and vtt are timed from the text and can drift by a few seconds."
        case .partlyNoAligner:
            "Subtitle timing is estimated for part of the audio: there’s no forced aligner for its language there, so srt and vtt can drift by a few seconds in those parts."
        case .alignmentFailed:
            "Subtitle timing is estimated in places: alignment failed for part of the audio, so srt and vtt can drift by a few seconds there."
        }
    }

    /// The chip menu's yellow line and the chip tooltip.
    public var short: String {
        switch self {
        case .notAligned: "Timing is estimated · not aligned"
        case .noAligner: "Timing is estimated · no aligner for this language"
        case .partlyNoAligner: "Timing is estimated in places · no aligner there"
        case .alignmentFailed: "Timing is estimated in places · alignment failed"
        }
    }
}

/// Whether Align Subtitles is offered for an entry with estimated timing (P3).
public enum AlignOffer: Equatable, Sendable {
    /// Alignment was off for this run, the language has an aligner and the source is there.
    case available
    /// As `available`, but the source file is gone: point to Locate….
    case needsSource
    /// Timing is aligned, or the language has no aligner: nothing to offer.
    case none

    /// `alignedLanguages` as in `EstimatedTiming.reason`; empty (not known yet) offers nothing.
    public static func make(timing: EstimatedTiming?, language: String?, alignedLanguages: [String],
                            sourceMissing: Bool) -> AlignOffer {
        guard timing == .notAligned, let language,
              alignedLanguages.map(Languages.code(for:)).contains(Languages.code(for: language)) else { return .none }
        return sourceMissing ? .needsSource : .available
    }
}

/// How a format chip looks.
public enum FormatChipState: Equatable, Sendable {
    case have
    case canMake
    /// Shown only after 150 ms.
    case making
    case failed(String)
}

extension LibraryEntry {
    /// srt/vtt of this entry are (or would be) estimated.
    public var cuesEstimated: Bool { cueTiming != .aligned }

    /// Whether `format` is in the folder as the `timestamps` variant (md/txt keep one variant).
    public func has(_ format: OutputFormat, timestamps: Bool) -> Bool {
        if format == .json { return true }
        guard formats[format.rawValue] != nil else { return false }
        guard format.takesTimestamps else { return true }
        return (variants[format.rawValue] ?? false) == timestamps
    }
}

/// D2: where "Also save copies" writes.
public enum CopyMode: String, Codable, Sendable, CaseIterable, Hashable {
    case off
    case nextToSource
    case folder

    public var label: String {
        switch self {
        case .off: "Off"
        case .nextToSource: "Next to source"
        case .folder: "Folder…"
        }
    }
}

/// What the copies of one finished file write.
public struct CopyPlan: Equatable, Sendable {
    public var directory: URL
    public var formats: [OutputFormat]
    public var timestamps: Bool
    public var replace: Bool

    /// nil when copies are off (or a folder copy has no folder).
    public init?(options o: TranscribeOptions, source: URL) {
        switch o.copyMode {
        case .off: return nil
        case .nextToSource: directory = source.deletingLastPathComponent()
        case .folder:
            guard let dir = o.outputDirectory else { return nil }
            directory = dir
        }
        formats = OutputFormat.ordered(o.copyFormats.isEmpty ? [.md] : o.copyFormats)
        timestamps = o.timestamps
        replace = o.overwrite
    }

    /// `<stem>.<ext>` for each format.
    public func names(source: URL) -> [String] {
        let stem = source.deletingPathExtension().lastPathComponent
        return formats.map { ExportNaming.fileName(title: stem, format: $0) }
    }

    /// Where each file goes: replaced in place, or kept beside with " 2".
    public func destinations(source: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [(format: OutputFormat, url: URL)] {
        var taken: Set<String> = []
        return zip(formats, names(source: source)).map { f, name in
            let url = replace ? directory.appendingPathComponent(name) : ExportNaming.available(name, in: directory, taken: taken, exists: exists)
            taken.insert(url.lastPathComponent)
            return (f, url)
        }
    }

    /// The Output section's caption: "Writes podcast-ep12.md and podcast-ep12.srt next to the source."
    /// Without a source (the defaults): "Writes .md and .srt copies next to each source."
    public static func caption(options o: TranscribeOptions, sourceName: String?) -> String {
        let stem = sourceName.map { ($0 as NSString).deletingPathExtension } ?? ""
        let names = OutputFormat.ordered(o.copyFormats.isEmpty ? [.md] : o.copyFormats).map { "\(stem).\($0.rawValue)" }
        let list: String
        switch names.count {
        case 0, 1: list = names.first ?? ""
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        let place: String
        switch o.copyMode {
        case .off: return ""
        case .nextToSource: place = sourceName == nil ? "next to each source" : "next to the source"
        case .folder: place = "to \(o.outputDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "the folder")"
        }
        return "Writes \(list)\(sourceName == nil ? " copies" : "") \(place). " + (o.overwrite ? "A file with the same name is replaced." : "Off: a name in use gets “ 2”.")
    }
}

/// Export settings.
public enum ExportSettings {
    public static let timestampsKey = "export.timestamps"
    /// The format the History row's hover Save uses: the last one saved.
    public static let lastFormatKey = "export.lastFormat"
    static let migratedKey = "export.timestampsMigrated"
    /// The former "Timestamps in Markdown" transcription option.
    public static let legacyTimestampsKey = "opt.timestamps"

    /// The old option becomes the export setting, once. The old key stays: it is now the
    /// copies' own Timestamps switch.
    public static func migrate(_ d: UserDefaults) {
        guard !d.bool(forKey: migratedKey) else { return }
        if d.object(forKey: timestampsKey) == nil, d.object(forKey: legacyTimestampsKey) != nil {
            d.set(d.bool(forKey: legacyTimestampsKey), forKey: timestampsKey)
        }
        d.set(true, forKey: migratedKey)
    }

    public static func timestamps(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: timestampsKey) }

    public static func lastFormat(_ d: UserDefaults = .standard) -> OutputFormat {
        d.string(forKey: lastFormatKey).flatMap(OutputFormat.init(rawValue:)) ?? .md
    }
}

/// Copy Text's toast: "Copied 6,412 words".
public enum WordCount {
    public static func count(_ text: String) -> Int {
        var n = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    public static func copiedMessage(_ text: String) -> String {
        let n = count(text)
        return n == 1 ? "Copied 1 word" : "Copied \(n.formatted(.number.locale(Locale(identifier: "en_US")))) words"
    }
}
