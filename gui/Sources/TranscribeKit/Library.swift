import Foundation

// The library: every transcribed file is one entry with a folder
//
//   <root>/library.json                 index: the only thing the app trusts (D4: never scans)
//   <root>/<title> (<short id>)/
//       transcript.json                 the master copy (`Transcript.to_dict`)
//       <title>.md  <title>.srt …       prepared formats (a cache; P2 makes more on demand)
//       overview.json                   ~200 RMS bins for the preview when the source is gone
//   <root>/.staging/<uuid>/             where a running job writes; moved in on file_done

/// What a run asked for, kept so Transcribe Again… can prefill its sheet.
public struct EntryOptions: Codable, Sendable, Hashable {
    /// Catalog id (`1.7b`, `0.6b`).
    public var model: String
    /// Requested language; nil = detected.
    public var language: String?
    public var context: [String]

    public init(model: String, language: String? = nil, context: [String] = []) {
        self.model = model
        self.language = language
        self.context = context
    }

    public init(_ o: TranscribeOptions) {
        self.init(model: o.model.rawValue,
                  language: o.language.flatMap { $0.lowercased() == "auto" || $0.isEmpty ? nil : $0 },
                  context: o.contextTerms)
    }
}

/// One History entry: a source file transcribed into the library.
public struct LibraryEntry: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// Lower-case hex UUID without dashes.
    public var id: String
    /// The source's file name without extension, at the first transcription.
    public var title: String
    /// Folder name inside the library root.
    public var folder: String
    public var fingerprint: SourceFingerprint?
    /// Where the source was last seen (updated when a renamed copy is dropped).
    public var sourcePath: String
    public var kind: MediaKind
    public var created: Date
    /// When the current transcript was made (the History date).
    public var updated: Date
    public var duration: Double?
    /// The language of the transcript (detected or requested).
    public var language: String?
    /// The model repo the worker reported (`Qwen/Qwen3-ASR-1.7B`).
    public var model: String?
    public var options: EntryOptions
    /// How subtitle cues are timed; nil when the transcript has no cues.
    public var cueTiming: CueTiming?
    /// Prepared formats: format → file name inside the folder. json is never listed: it is
    /// `transcript.json` itself.
    public var formats: [String: String]
    /// md/txt: whether the cached file has timestamps (one variant per format is kept).
    public var variants: [String: Bool]
    /// Wall seconds the run took.
    public var elapsed: Double?
    public var noticeCount: Int
    /// When Align Subtitles last re-timed this transcript (nil: never; Transcribe Again clears it).
    public var aligned: Date?

    public init(id: String = LibraryEntry.newID(), title: String, folder: String, fingerprint: SourceFingerprint?,
                sourcePath: String, kind: MediaKind, created: Date, updated: Date, duration: Double? = nil,
                language: String? = nil, model: String? = nil, options: EntryOptions, cueTiming: CueTiming? = nil,
                formats: [String: String] = [:], variants: [String: Bool] = [:], elapsed: Double? = nil, noticeCount: Int = 0) {
        self.id = id
        self.title = title
        self.folder = folder
        self.fingerprint = fingerprint
        self.sourcePath = sourcePath
        self.kind = kind
        self.created = created
        self.updated = updated
        self.duration = duration
        self.language = language
        self.model = model
        self.options = options
        self.cueTiming = cueTiming
        self.formats = formats
        self.variants = variants
        self.elapsed = elapsed
        self.noticeCount = noticeCount
    }

    public static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// The 4 characters in the folder name.
    public var shortID: String { String(id.prefix(4)) }
    public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    public var sourceName: String { sourceURL.lastPathComponent }
    /// Prepared formats in display order.
    public var preparedFormats: [OutputFormat] { OutputFormat.allCases.filter { $0 != .json && formats[$0.rawValue] != nil } }

    enum CodingKeys: String, CodingKey {
        case id, title, folder, fingerprint, kind, created, updated, duration, language, model, options, formats, variants, elapsed, aligned
        case sourcePath = "source_path", cueTiming = "cue_timing", noticeCount = "notice_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        folder = try c.decode(String.self, forKey: .folder)
        fingerprint = try? c.decodeIfPresent(SourceFingerprint.self, forKey: .fingerprint)
        sourcePath = (try? c.decode(String.self, forKey: .sourcePath)) ?? ""
        kind = (try? c.decode(MediaKind.self, forKey: .kind)) ?? MediaKind(pathExtension: URL(fileURLWithPath: sourcePath).pathExtension)
        created = try c.decode(Date.self, forKey: .created)
        updated = (try? c.decode(Date.self, forKey: .updated)) ?? created
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        options = (try? c.decode(EntryOptions.self, forKey: .options)) ?? EntryOptions(model: "1.7b")
        cueTiming = (try? c.decodeIfPresent(String.self, forKey: .cueTiming)).flatMap(CueTiming.init(rawValue:))
        formats = (try? c.decode([String: String].self, forKey: .formats)) ?? [:]
        variants = (try? c.decode([String: Bool].self, forKey: .variants)) ?? [:]
        elapsed = try? c.decodeIfPresent(Double.self, forKey: .elapsed)
        noticeCount = (try? c.decode(Int.self, forKey: .noticeCount)) ?? 0
        aligned = try? c.decodeIfPresent(Date.self, forKey: .aligned)
    }

    /// Changes whenever the transcript is rewritten: views that read transcript.json key on it.
    public var revision: String { "\(updated.timeIntervalSince1970)-\(aligned?.timeIntervalSince1970 ?? 0)" }
}

/// `library.json`.
public struct LibraryIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = LibraryIndex.currentVersion
    public var entries: [LibraryEntry] = []

    public init(entries: [LibraryEntry] = []) { self.entries = entries }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case unreadableIndex(String)
    case missingTranscript
    case cancelled
    case verifyFailed(String)
    case notEnoughSpace(needed: Int64, free: Int64)

    public var errorDescription: String? {
        switch self {
        case .unreadableIndex(let path): "The library index at \(path) can’t be read."
        case .missingTranscript: "The worker didn’t write a transcript."
        case .cancelled: "Cancelled."
        case .verifyFailed(let name): "“\(name)” didn’t copy correctly."
        case .notEnoughSpace(let needed, let free):
            "There isn’t enough free space (\(Formatting.size(needed)) needed, \(Formatting.size(free)) free)."
        }
    }
}

/// History sort orders (History header `…` menu).
public enum HistorySort: String, Sendable, CaseIterable, Identifiable {
    case date, title, duration
    public var id: String { rawValue }
}

/// The library on disk: the index plus entry folders. A value type; every mutating call that
/// changes the index writes `library.json` atomically before returning.
public struct LibraryStore: Sendable {
    public static let indexName = "library.json"
    public static let stagingName = ".staging"
    public static let transcriptName = "transcript.json"
    public static let overviewName = "overview.json"

    /// `~/Transcrio Library` (D1).
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcrio Library", isDirectory: true)
    }

    public let root: URL
    public private(set) var entries: [LibraryEntry]
    /// Moves a file or folder to the Trash. Tests pass a scratch folder instead.
    public var trash: @Sendable (URL) throws -> Void

    public static let systemTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Opens the library at `root`; a missing index is an empty library (nothing is created
    /// until the first entry). An unreadable index throws, so it is never overwritten.
    public init(root: URL, trash: @escaping @Sendable (URL) throws -> Void = LibraryStore.systemTrash) throws {
        self.root = root.standardizedFileURL
        self.trash = trash
        let url = self.root.appendingPathComponent(Self.indexName)
        if let data = try? Data(contentsOf: url) {
            guard let index = try? LibraryIndex.decoder.decode(LibraryIndex.self, from: data) else {
                throw LibraryError.unreadableIndex(url.path)
            }
            entries = index.entries
        } else {
            entries = []
        }
    }

    public var indexURL: URL { root.appendingPathComponent(Self.indexName) }
    public var stagingRoot: URL { root.appendingPathComponent(Self.stagingName, isDirectory: true) }

    // MARK: Reading

    public subscript(id: LibraryEntry.ID) -> LibraryEntry? { entries.first { $0.id == id } }

    public func entry(matching fingerprint: SourceFingerprint) -> LibraryEntry? {
        entries.first { $0.fingerprint == fingerprint }
    }

    public func folderURL(_ entry: LibraryEntry) -> URL { root.appendingPathComponent(entry.folder, isDirectory: true) }
    public func transcriptURL(_ entry: LibraryEntry) -> URL { folderURL(entry).appendingPathComponent(Self.transcriptName) }
    public func overviewURL(_ entry: LibraryEntry) -> URL { folderURL(entry).appendingPathComponent(Self.overviewName) }

    /// Prepared format files, json (transcript.json) included, by format.
    public func outputs(_ entry: LibraryEntry) -> [String: String] {
        var out = entry.formats.mapValues { folderURL(entry).appendingPathComponent($0).path }
        out["json"] = transcriptURL(entry).path
        return out
    }

    /// Newest first by default.
    public func sorted(by sort: HistorySort = .date) -> [LibraryEntry] {
        switch sort {
        case .date: entries.sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }
        case .title: entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .duration: entries.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }

    /// A library already in `folder`: its size and when it was last written.
    public static func existing(at folder: URL) -> (count: Int, lastUsed: Date?)? {
        let url = folder.appendingPathComponent(indexName)
        guard let data = try? Data(contentsOf: url),
              let index = try? LibraryIndex.decoder.decode(LibraryIndex.self, from: data) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (index.entries.count, modified)
    }

    /// Bytes in the entry folders and index (for Settings; walks the disk, so call it off the main thread).
    public func totalBytes() -> Int64 {
        entries.reduce(Self.size(of: indexURL)) { $0 + Self.size(of: folderURL($1)) }
    }

    // MARK: Writing

    public func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try LibraryIndex.encoder.encode(LibraryIndex(entries: entries))
        try data.write(to: indexURL, options: .atomic)
    }

    /// A fresh, empty folder for one job's output.
    public func makeStaging() throws -> URL {
        let url = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes what jobs left behind (launch; nothing can be running then).
    public func cleanStaging() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    /// What a finished job hands to `commit`.
    public struct Commit: Sendable {
        public var staging: URL
        public var source: URL
        public var kind: MediaKind
        public var fingerprint: SourceFingerprint?
        public var options: EntryOptions
        public var result: FileResult
        /// Linear RMS bins for overview.json (already pooled to `LibraryOverview.bins`).
        public var overview: [Float]?
        /// Transcribe Again: the entry whose transcript this replaces.
        public var replacing: LibraryEntry.ID?
        /// The job's Timestamps value (the variant of its md/txt).
        public var timestamps: Bool
        public var date: Date

        public init(staging: URL, source: URL, kind: MediaKind, fingerprint: SourceFingerprint?, options: EntryOptions,
                    result: FileResult, overview: [Float]? = nil, replacing: LibraryEntry.ID? = nil, timestamps: Bool = false,
                    date: Date = Date()) {
            self.staging = staging
            self.source = source
            self.kind = kind
            self.fingerprint = fingerprint
            self.options = options
            self.result = result
            self.overview = overview
            self.replacing = replacing
            self.timestamps = timestamps
            // library.json keeps whole seconds.
            self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
    }

    /// Moves a finished job's staging folder into the library: a new entry, or (Transcribe
    /// Again) the replacement of an entry's transcript and formats, whose old files go to the
    /// Trash. Returns the entry. On error the library is unchanged.
    @discardableResult
    public mutating func commit(_ c: Commit) throws -> LibraryEntry {
        let fm = FileManager.default
        let transcript = c.staging.appendingPathComponent(Self.transcriptName)
        if !fm.fileExists(atPath: transcript.path), let written = c.result.transcript, fm.fileExists(atPath: written) {
            try fm.copyItem(at: URL(fileURLWithPath: written), to: transcript)
        }
        if !fm.fileExists(atPath: transcript.path) {
            // An older CLI ignores transcript_path: use its json output, else what file_done carried.
            if let json = c.result.outputs["json"], fm.fileExists(atPath: json) {
                try fm.copyItem(at: URL(fileURLWithPath: json), to: transcript)
            } else {
                try LibraryTranscript.synthesize(from: c.result, source: c.source).write(to: transcript, options: .atomic)
            }
        }
        // Prepared formats are the files the job wrote into staging; json is transcript.json.
        var formats: [String: String] = [:]
        for (format, path) in c.result.outputs {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL == c.staging.standardizedFileURL,
                  fm.fileExists(atPath: path), url.lastPathComponent != Self.transcriptName else { continue }
            if format == OutputFormat.json.rawValue { try? fm.removeItem(at: url); continue }
            formats[format] = url.lastPathComponent
        }
        let variants = Dictionary(uniqueKeysWithValues: formats.keys.filter { OutputFormat(rawValue: $0)?.takesTimestamps == true }
            .map { ($0, c.timestamps) })
        if let bins = c.overview, !bins.isEmpty {
            try LibraryOverview.encode(bins).write(to: c.staging.appendingPathComponent(Self.overviewName), options: .atomic)
        }

        let r = c.result
        if let id = c.replacing, let i = entries.firstIndex(where: { $0.id == id }) {
            var entry = entries[i]
            try replaceContents(of: folderURL(entry), with: c.staging, label: entry.folder, date: c.date)
            entry.updated = c.date
            entry.fingerprint = c.fingerprint ?? entry.fingerprint
            entry.sourcePath = c.source.path
            entry.kind = c.kind
            entry.duration = r.duration ?? entry.duration
            entry.language = r.language
            entry.model = r.model
            entry.options = c.options
            entry.cueTiming = r.cueTiming
            entry.formats = formats
            entry.variants = variants
            entry.elapsed = r.elapsed
            entry.noticeCount = r.noticeCount
            entry.aligned = nil
            var updated = entries
            updated[i] = entry
            try commitIndex(updated)
            return entry
        }

        let id = LibraryEntry.newID()
        let title = c.source.deletingPathExtension().lastPathComponent
        let folder = uniqueFolderName(title: title, id: id)
        let target = root.appendingPathComponent(folder, isDirectory: true)
        try fm.moveItem(at: c.staging, to: target)
        let entry = LibraryEntry(id: id, title: title, folder: folder, fingerprint: c.fingerprint, sourcePath: c.source.path,
                                 kind: c.kind, created: c.date, updated: c.date, duration: r.duration, language: r.language,
                                 model: r.model, options: c.options, cueTiming: r.cueTiming, formats: formats,
                                 variants: variants, elapsed: r.elapsed, noticeCount: r.noticeCount)
        do {
            try commitIndex(entries + [entry])
        } catch {
            try? fm.moveItem(at: target, to: c.staging)
            throw error
        }
        return entry
    }

    /// Remove from History: the entry folder goes to the Trash and the entry leaves the index.
    public mutating func remove(_ ids: Set<LibraryEntry.ID>) throws {
        let gone = entries.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        try commitIndex(entries.filter { !ids.contains($0.id) })
        for e in gone where FileManager.default.fileExists(atPath: folderURL(e).path) {
            try? trash(folderURL(e))
        }
    }

    /// A renamed or moved copy was dropped: remember where the source is now.
    public mutating func updateSource(_ id: LibraryEntry.ID, path: String) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].sourcePath != path else { return }
        var updated = entries
        updated[i].sourcePath = path
        try commitIndex(updated)
    }

    /// Locate…: the source is at `url` now. A file that isn't the same recording (Use Anyway)
    /// also takes over the fingerprint, so dropping it again finds this entry.
    public mutating func relocate(_ id: LibraryEntry.ID, to url: URL, fingerprint: SourceFingerprint?) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[i].sourcePath = url.standardizedFileURL.path
        if let fingerprint { updated[i].fingerprint = fingerprint }
        try commitIndex(updated)
    }

    // MARK: Prepared formats (P2 export)

    /// The cached file for `format` as the `timestamps` variant, if it is in the folder.
    /// json is transcript.json.
    public func cachedURL(_ entry: LibraryEntry, _ format: OutputFormat, timestamps: Bool) -> URL? {
        if format == .json {
            let url = transcriptURL(entry)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard entry.has(format, timestamps: timestamps), let name = entry.formats[format.rawValue] else { return nil }
        let url = folderURL(entry).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Records files an export wrote into the entry folder (anything elsewhere is ignored).
    @discardableResult
    public mutating func recordFormats(_ id: LibraryEntry.ID, outputs: [String: String], timestamps: Bool) throws -> LibraryEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let folder = folderURL(entries[i]).standardizedFileURL
        var entry = entries[i]
        for (format, path) in outputs {
            guard let f = OutputFormat(rawValue: format), f != .json else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.deletingLastPathComponent() == folder else { continue }
            entry.formats[format] = url.lastPathComponent
            if f.takesTimestamps { entry.variants[format] = timestamps } else { entry.variants[format] = nil }
        }
        guard entry != entries[i] else { return entry }
        var updated = entries
        updated[i] = entry
        try commitIndex(updated)
        return entry
    }

    /// A cached file went missing from the folder: forget it (it is made again when needed).
    public mutating func forgetMissingFormats(_ id: LibraryEntry.ID) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let folder = folderURL(entries[i])
        var entry = entries[i]
        for (format, name) in entry.formats where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            entry.formats[format] = nil
            entry.variants[format] = nil
        }
        guard entry != entries[i] else { return }
        var updated = entries
        updated[i] = entry
        try commitIndex(updated)
    }

    // MARK: Align Subtitles (P3)

    /// Where the worker writes an aligned transcript before `commitAlignment` takes it in.
    public func makeAlignStaging() throws -> URL {
        try makeStaging().appendingPathComponent(Self.transcriptName)
    }

    /// An `align` op wrote `aligned` (a transcript.json in staging): it replaces the entry's
    /// master copy, cached formats that carry cue timing (srt, vtt) are deleted so they are made
    /// again from the new cues, and the entry's timing and notice count follow. md and txt only
    /// use paragraph times, which alignment doesn't change, so they stay. On error the library
    /// is unchanged.
    @discardableResult
    public mutating func commitAlignment(_ id: LibraryEntry.ID, aligned: URL, cueTiming: CueTiming?, noticeCount: Int,
                                         date: Date = Date()) throws -> LibraryEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let fm = FileManager.default
        var entry = entries[i]
        let folder = folderURL(entry)
        let master = transcriptURL(entry)
        guard fm.fileExists(atPath: aligned.path) else { throw LibraryError.missingTranscript }
        if fm.fileExists(atPath: master.path) {
            _ = try fm.replaceItemAt(master, withItemAt: aligned)
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.moveItem(at: aligned, to: master)
        }
        let staging = aligned.deletingLastPathComponent()
        if staging.deletingLastPathComponent().standardizedFileURL == stagingRoot.standardizedFileURL {
            try? fm.removeItem(at: staging)
        }
        for f in OutputFormat.allCases where f.isCueFormat {
            guard let name = entry.formats[f.rawValue] else { continue }
            try? fm.removeItem(at: folder.appendingPathComponent(name))
            entry.formats[f.rawValue] = nil
            entry.variants[f.rawValue] = nil
        }
        entry.cueTiming = cueTiming
        entry.noticeCount = noticeCount
        entry.aligned = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        var updated = entries
        updated[i] = entry
        try commitIndex(updated)
        return entry
    }

    // MARK: Moving the library (Settings → Library → Change…)

    public struct MoveProgress: Sendable, Equatable {
        public var entriesDone: Int
        public var entriesTotal: Int
        public var bytesDone: Int64
        public var bytesTotal: Int64

        public init(entriesDone: Int, entriesTotal: Int, bytesDone: Int64, bytesTotal: Int64) {
            self.entriesDone = entriesDone
            self.entriesTotal = entriesTotal
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
        }
    }

    /// Copies every entry folder and the index to `newRoot`, checks each copy, then deletes
    /// the old folders and index. `progress` returns false to cancel; cancelling or a failure
    /// removes what was copied and leaves the old library as it was.
    public func move(to newRoot: URL, progress: (MoveProgress) -> Bool = { _ in true }) throws -> LibraryStore {
        let fm = FileManager.default
        let dest = newRoot.standardizedFileURL
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let sizes = entries.map { Self.size(of: folderURL($0)) }
        let total = sizes.reduce(0, +)
        if let free = (try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free < total {
            throw LibraryError.notEnoughSpace(needed: total, free: free)
        }
        var copied: [URL] = []
        var done: Int64 = 0
        func rollback() { for u in copied { try? fm.removeItem(at: u) } }
        guard progress(MoveProgress(entriesDone: 0, entriesTotal: entries.count, bytesDone: 0, bytesTotal: total)) else {
            throw LibraryError.cancelled
        }
        do {
            for (i, e) in entries.enumerated() {
                let from = folderURL(e), to = dest.appendingPathComponent(e.folder, isDirectory: true)
                if fm.fileExists(atPath: from.path) {
                    guard !fm.fileExists(atPath: to.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path]) }
                    try fm.copyItem(at: from, to: to)
                    copied.append(to)
                    guard Self.size(of: to) == sizes[i] else { throw LibraryError.verifyFailed(e.folder) }
                }
                done += sizes[i]
                guard progress(MoveProgress(entriesDone: i + 1, entriesTotal: entries.count, bytesDone: done, bytesTotal: total)) else {
                    throw LibraryError.cancelled
                }
            }
            var moved = try LibraryStore(root: dest, trash: trash)
            moved.entries = entries
            try moved.save()
            copied.append(moved.indexURL)
            for e in entries { try? fm.removeItem(at: folderURL(e)) }
            try? fm.removeItem(at: indexURL)
            cleanStaging()
            return moved
        } catch {
            rollback()
            throw error
        }
    }

    // MARK: Helpers

    /// Writes the new index, and only then makes it current.
    private mutating func commitIndex(_ updated: [LibraryEntry]) throws {
        let old = entries
        entries = updated
        do { try save() } catch { entries = old; throw error }
    }

    /// Transcribe Again: the old files go into one "… (replaced <date>)" folder in the Trash,
    /// the staging files take their place.
    private func replaceContents(of folder: URL, with staging: URL, label: String, date: Date) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else {
            try fm.moveItem(at: staging, to: folder)
            return
        }
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        let holding = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("\(label) (replaced \(stamp))", isDirectory: true)
        try fm.createDirectory(at: holding, withIntermediateDirectories: true)
        let old = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var movedOld: [URL] = []
        var movedNew: [URL] = []
        do {
            for u in old {
                try fm.moveItem(at: u, to: holding.appendingPathComponent(u.lastPathComponent))
                movedOld.append(u)
            }
            for u in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let to = folder.appendingPathComponent(u.lastPathComponent)
                try fm.moveItem(at: u, to: to)
                movedNew.append(to)
            }
        } catch {
            for u in movedNew { try? fm.moveItem(at: u, to: staging.appendingPathComponent(u.lastPathComponent)) }
            for u in movedOld { try? fm.moveItem(at: holding.appendingPathComponent(u.lastPathComponent), to: u) }
            throw error
        }
        try? fm.removeItem(at: staging)
        do { try trash(holding) } catch { try? fm.removeItem(at: holding) }
        try? fm.removeItem(at: holding.deletingLastPathComponent())
    }

    /// `<title> (<4 hex>)`, longer id prefixes if that folder exists.
    func uniqueFolderName(title: String, id: String) -> String {
        let clean = Self.sanitize(title)
        for n in stride(from: 4, through: id.count, by: 2) {
            let name = "\(clean) (\(id.prefix(n)))"
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
               !entries.contains(where: { $0.folder == name }) { return name }
        }
        return "\(clean) (\(id))"
    }

    /// A Finder-safe folder title.
    public static func sanitize(_ title: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        if s.isEmpty { s = "Untitled" }
        return String(s.prefix(80))
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return total
    }
}

/// `overview.json`: the source's loudness as ~200 linear RMS bins, so the preview keeps
/// its overview when the source is gone.
public enum LibraryOverview {
    public static let bins = 200

    /// Pools a waveform's fine bins to `bins`.
    public static func bins(from waveform: Waveform) -> [Float] {
        Waveform.pool(waveform.rms, count: bins)
    }

    public static func encode(_ rms: [Float]) -> Data {
        let rounded = rms.map { (Double($0) * 10000).rounded() / 10000 }
        return (try? JSONSerialization.data(withJSONObject: ["version": 1, "rms": rounded], options: [.sortedKeys])) ?? Data()
    }

    public static func decode(_ data: Data) -> Waveform? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = obj["rms"] as? [NSNumber], !values.isEmpty else { return nil }
        return Waveform(rms: values.map(\.floatValue))
    }

    public static func load(_ url: URL) -> Waveform? {
        (try? Data(contentsOf: url)).flatMap(decode)
    }
}

/// The parts of `transcript.json` the app reads (the CLI's `Transcript.to_dict`).
public struct LibraryTranscript: Sendable, Equatable, Decodable {
    public var text: String
    public var language: String?
    public var duration: Double?
    public var model: String?
    public var segments: [TranscriptSegment]
    public var cues: [TranscriptSegment]?
    public var cueTiming: CueTiming?
    public var warnings: [String]
    public var notices: [Notice]

    enum CodingKeys: String, CodingKey {
        case text, language, duration, model, segments, cues, warnings, notices
        case cueTiming = "cue_timing"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        segments = (try? c.decode([TranscriptSegment].self, forKey: .segments)) ?? []
        cues = try? c.decodeIfPresent([TranscriptSegment].self, forKey: .cues)
        cueTiming = (try? c.decodeIfPresent(String.self, forKey: .cueTiming)).flatMap(CueTiming.init(rawValue:))
        warnings = (try? c.decode([String].self, forKey: .warnings)) ?? []
        notices = (try? c.decode([Notice].self, forKey: .notices)) ?? []
    }

    public static func load(_ url: URL) -> LibraryTranscript? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LibraryTranscript.self, from: $0) }
    }

    /// The finished-file view of an entry: its transcript as a `FileResult` with the library's
    /// files as outputs.
    public func result(entry: LibraryEntry, outputs: [String: String]) -> FileResult {
        FileResult(outputs: outputs, elapsed: entry.elapsed, language: language ?? entry.language,
                   duration: duration ?? entry.duration, model: model ?? entry.model,
                   cueTiming: cueTiming ?? entry.cueTiming, warnings: warnings, notices: notices, segments: segments)
    }

    /// A minimal transcript.json from `file_done`, for a CLI that doesn't write one.
    public static func synthesize(from r: FileResult, source: URL) throws -> Data {
        let segs: [[String: Any]] = r.segments.map { ["text": $0.text, "start": $0.start, "end": $0.end, "speaker": NSNull()] }
        let notices: [[String: Any]] = r.notices.map { n in
            var d: [String: Any] = ["code": n.rawCode, "message": n.message]
            d["spans"] = n.spans.map { $0.map { [$0.lowerBound, $0.upperBound] } } ?? NSNull()
            return d
        }
        let obj: [String: Any] = [
            "text": r.segments.map(\.text).joined(separator: "\n\n"),
            "language": r.language ?? NSNull(), "duration": r.duration ?? NSNull(), "model": r.model ?? NSNull(),
            "backend": NSNull(), "segments": segs, "cues": NSNull(), "cue_timing": NSNull(), "words": NSNull(),
            "warnings": r.warnings, "notices": notices, "source": source.path,
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
