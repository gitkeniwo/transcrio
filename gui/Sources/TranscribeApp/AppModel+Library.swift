import AppKit
import SwiftUI
import TranscribeKit

/// Transcribe Again…: the entries the sheet is for.
struct AgainRequest: Identifiable, Equatable {
    let id = UUID()
    var entries: [LibraryEntry.ID]
}

/// Settings → Library → Change… while the library is copied.
struct LibraryMoveState: Equatable {
    var destination: URL
    var progress: LibraryStore.MoveProgress
    var cancelled = false
}

/// What the Change… sheet chose.
enum LibraryLocationChoice {
    case move, empty, switchTo
}

extension AppModel {
    // MARK: Location

    /// `TRANSCRIBE_LIBRARY`, then Settings, then ~/Transcrio Library (D1).
    static var libraryRoot: URL {
        if let path = DevSupport.environment["TRANSCRIBE_LIBRARY"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: SettingsKeys.libraryRoot), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return LibraryStore.defaultRoot
    }

    /// A store that is never written (the index at `root` couldn't be read).
    static func emptyStore(_ root: URL) -> LibraryStore {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("transcrio-unavailable-\(UUID().uuidString)")
        return (try? LibraryStore(root: scratch)) ?? { fatalError("empty library") }()
    }

    var alwaysAlign: Bool {
        if let dev = DevSupport.environment["TRANSCRIBE_ALWAYS_ALIGN"] { return dev != "0" }
        return UserDefaults.standard.object(forKey: SettingsKeys.alwaysAlign) as? Bool ?? true
    }

    // MARK: History

    /// History rows: sorted, searched, without entries still arriving.
    var historyEntries: [LibraryEntry] {
        let q = searchQuery
        let shown = library.sorted(by: historySort).filter { !pendingEntries.contains($0.id) }
        guard searchingText else { return shown.filter { $0.matches(q) } }
        let hits = searcher.hits(q)
        return shown.filter { hits[$0.id] != nil }
    }

    var historyTotal: Int { library.entries.count - pendingEntries.count }

    var selectedEntries: [LibraryEntry] { historyEntries.filter { historySelection.contains($0.id) } }
    var selectedEntry: LibraryEntry? { historySelection.count == 1 ? historySelection.first.flatMap { library[$0] } : nil }

    func sourceMissing(_ entry: LibraryEntry) -> Bool {
        entry.sourcePath.isEmpty || !FileManager.default.fileExists(atPath: entry.sourcePath)
    }

    /// The queue row a Transcribe Again run of this entry is waiting in.
    func againRow(for entry: LibraryEntry.ID) -> FileItem? {
        items.first { $0.replaces == entry && !$0.state.isTerminal }
    }

    /// History row click: plain replaces, ⌘ toggles, ⇧ extends.
    func clickEntry(_ id: LibraryEntry.ID, command: Bool, shift: Bool) {
        let order = historyEntries.map(\.id)
        if shift, let anchor = historyAnchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            let range = Set(order[min(a, b)...max(a, b)])
            historySelection = command ? historySelection.union(range) : range
            return
        }
        if command {
            if historySelection.contains(id) { historySelection.remove(id) } else { historySelection.insert(id) }
        } else {
            historySelection = [id]
        }
        historyAnchor = id
    }

    var historyAnchor: LibraryEntry.ID? {
        get { historyAnchorStorage }
        set { historyAnchorStorage = newValue }
    }

    func toggleHistory() {
        withAnimation(.snappy(duration: 0.2)) { historyCollapsed.toggle() }
    }

    // MARK: Adding

    /// Fingerprints off the main thread, a few at a time.
    nonisolated static func fingerprints(_ files: [URL]) async -> [URL: SourceFingerprint] {
        await withTaskGroup(of: (URL, SourceFingerprint?).self) { group in
            for f in files { group.addTask { (f, await SourceFingerprint.compute(f)) } }
            var out: [URL: SourceFingerprint] = [:]
            for await (url, fp) in group { if let fp { out[url] = fp } }
            return out
        }
    }

    /// Slow check: the files show as Checking… rows meanwhile.
    func addChecking(_ files: [URL]) -> [FileItem.ID] {
        let ids = queue.add(files, options: options)
        for id in ids {
            queue.update(id) { $0.checking = true }
            loadMedia(for: id)
        }
        return ids
    }

    /// Fingerprints are in: new files go to Ready, known ones are located in History.
    func finishAdd(_ files: [URL], fingerprints: [URL: SourceFingerprint], placeholders: [FileItem.ID]) {
        let ph = Set(placeholders)
        let others = items.filter { !ph.contains($0.id) }
        let plan = DropPlan.make(urls: files, fingerprints: fingerprints, queue: others, library: library.entries)
        let newPaths = Set(plan.new.map { $0.standardizedFileURL.path })

        var newIDs: [FileItem.ID] = []
        var placed: Set<String> = []
        for id in placeholders {
            guard let item = queue[id] else { continue }
            if newPaths.contains(item.url.path) {
                let fp = fingerprints.first { $0.key.standardizedFileURL.path == item.url.path }?.value
                queue.update(id) { $0.checking = false; $0.fingerprint = fp }
                if autoStart { queue.queue([id]) }
                newIDs.append(id)
                placed.insert(item.url.path)
            } else {
                withAnimation(.snappy(duration: 0.2)) { queue.remove([id]) }
                waveforms[id] = nil
            }
        }
        let rest = plan.new.filter { !placed.contains($0.standardizedFileURL.path) }
        let wasEmpty = items.isEmpty
        newIDs += enqueueFiles(rest, fingerprints: fingerprints)
        if autoStart { pump() }

        // Known files: remember where the source is now, ring them.
        for k in plan.known where k.url.standardizedFileURL.path != k.entry.sourcePath {
            try? library.updateSource(k.entry.id, path: k.url.standardizedFileURL.path)
        }
        let known = plan.known.map(\.entry.id)
        if !known.isEmpty { locate(known, select: newIDs.isEmpty && plan.queued.isEmpty) }

        // Selection: the new rows; with none, the queued rows; with neither, History.
        if !newIDs.isEmpty {
            if !known.isEmpty || !plan.queued.isEmpty || selection.isEmpty && historySelection.isEmpty || wasEmpty {
                selection = known.isEmpty && plan.queued.isEmpty ? [newIDs[0]] : Set(newIDs)
            }
        } else if !plan.queued.isEmpty, known.isEmpty {
            selection = Set(plan.queued)
        }
        if let notice = plan.notice() { dropNotice = notice }
    }

    /// Expands History, scrolls to the entries and rings them; `select` also selects them.
    func locate(_ ids: [LibraryEntry.ID], select: Bool) {
        if historyCollapsed { withAnimation(.snappy(duration: 0.2)) { historyCollapsed = false } }
        if select { historySelection = Set(ids) }
        historyScrollTarget = historyEntries.first { ids.contains($0.id) }?.id ?? ids.first
        ringing = Set(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.ringing == Set(ids) else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.ringing = [] }
        }
    }

    // MARK: The write path

    /// The job as sent: written to a fresh staging folder in the library.
    func libraryJob(_ job: ServeJob) -> ServeJob? {
        guard let staging = try? library.makeStaging() else { return nil }
        var job = job
        job.outputDir = staging.path
        job.transcriptPath = staging.appendingPathComponent(LibraryStore.transcriptName).path
        job.align = alwaysAlign
        job.overwrite = true
        // Prepared md/txt follow the export setting; the job's own Timestamps is the copies'.
        job.timestamps = exportTimestamps
        stagingFolders[job.id] = staging
        return job
    }

    func discardStaging(_ job: String) {
        guard let url = stagingFolders.removeValue(forKey: job) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// file_done: the staging folder becomes the entry (or replaces its transcript), then the
    /// row moves to History.
    func commitToLibrary(_ id: FileItem.ID, result: FileResult) {
        guard let item = queue[id], let job = item.jobID, let staging = stagingFolders.removeValue(forKey: job) else { return }
        guard libraryUnavailable == nil else {
            try? FileManager.default.removeItem(at: staging)
            queue.update(id) { $0.state = .failed("Not saved: \(self.libraryUnavailable ?? "the library can’t be read.")") }
            return
        }
        let overview = waveforms[id].map(LibraryOverview.bins(from:))
        let fp = item.fingerprint ?? (try? SourceFingerprint.read(item.url))
        let replacing = item.replaces.flatMap { library[$0] != nil ? $0 : nil }
        let entry: LibraryEntry
        do {
            entry = try library.commit(.init(staging: staging, source: item.url, kind: item.kind, fingerprint: fp,
                                             options: EntryOptions(item.ranWith ?? item.options), result: result,
                                             overview: overview, replacing: replacing, timestamps: exportTimestamps))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            queue.update(id) { $0.state = .failed("Couldn’t save to the library: \(error.localizedDescription)") }
            return
        }
        let replaced = replacing != nil
        writeCopies(entry: entry.id, options: item.ranWith ?? item.options, source: item.url)
        if !replaced { pendingEntries.insert(entry.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let wasSelected = self.selection.contains(id)
            withAnimation(.easeInOut(duration: 0.25)) {
                self.queue.remove([id])
                self.selection.remove(id)
            }
            self.waveforms[id] = nil
            self.liveTopTime[id] = nil
            self.sessionDone += 1
            self.historyPulse += 1
            if wasSelected, self.selection.isEmpty { self.historySelection = [entry.id] }
            DispatchQueue.main.asyncAfter(deadline: .now() + (replaced ? 0 : 0.25)) { [weak self] in
                guard let self else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    self.pendingEntries.remove(entry.id)
                    self.freshEntries.insert(entry.id)
                }
                if !self.historyCollapsed { self.historyScrollTarget = entry.id }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    withAnimation(.easeOut(duration: 1.5)) { _ = self?.freshEntries.remove(entry.id) }
                }
            }
        }
    }

    /// Queue row subtitles for Checking… and Transcribe Again rows.
    func rowSubtitle(_ status: RowStatus, item: FileItem) -> String {
        if item.checking { return "Checking…" }
        if let r = item.replaces, status == .ready || item.state == .queued, let e = library[r] {
            return "↻ Again · \(item.options.model.rawValue.uppercased()) · replaces \(HistoryDate.short(e.updated))"
        }
        return StatusText.subtitle(status, item: item, defaults: options)
    }

    // MARK: Transcribe Again…

    func requestAgain(_ ids: [LibraryEntry.ID]) {
        let ids = ids.filter { library[$0] != nil }
        guard !ids.isEmpty else { return }
        againRequest = AgainRequest(entries: ids)
    }

    /// Add to Queue: one row per entry whose source is there, with the sheet's options.
    func transcribeAgain(_ ids: [LibraryEntry.ID], model: ModelChoice, language: String?, context: [String]) {
        var rows: [FileItem.ID] = []
        for id in ids {
            guard let entry = library[id], !sourceMissing(entry) else { continue }
            if let row = againRow(for: id) { rows.append(row.id); continue }
            var o = options
            o.model = model
            o.language = language
            o.contextTerms = context
            let prepared = entry.preparedFormats
            if !prepared.isEmpty { o.formats = prepared }
            let url = entry.sourceURL
            guard let row = queue.add([url], options: o, queue: autoStart).first else {
                if let live = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.state.isTerminal }) {
                    rows.append(live.id)
                }
                continue
            }
            queue.update(row) { $0.replaces = id; $0.fingerprint = entry.fingerprint }
            loadMedia(for: row)
            rows.append(row)
        }
        againRequest = nil
        if !rows.isEmpty { selection = Set(rows) }
        if autoStart { pump() }
    }

    // MARK: Remove from History…

    func confirmRemoveEntries() {
        guard let ids = removeRequest else { return }
        removeRequest = nil
        do {
            try withAnimation(.snappy(duration: 0.2)) { try library.remove(Set(ids)) }
        } catch {
            banner = .message("Couldn’t update the library: \(error.localizedDescription)")
        }
        historySelection.subtract(ids)
    }

    // MARK: Finder

    func revealEntries(_ ids: [LibraryEntry.ID]) {
        let urls = ids.compactMap { library[$0] }.map { library.folderURL($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func revealSources(_ ids: [LibraryEntry.ID]) {
        let urls = ids.compactMap { library[$0] }.filter { !sourceMissing($0) }.map(\.sourceURL)
        if urls.isEmpty { NSSound.beep() } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func revealLibrary() {
        try? FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    // MARK: Settings → Library → Change…

    /// Nothing running or waiting: the location can change.
    var canChangeLibrary: Bool { !isRunning && !hasWaiting && libraryMove == nil }

    /// Start empty / switch: just point at the folder.
    func useLibrary(at folder: URL) {
        do {
            let store = try LibraryStore(root: folder)
            setLibrary(store)
        } catch {
            banner = .message((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func setLibrary(_ store: LibraryStore) {
        library = store
        libraryUnavailable = nil
        historySelection = []
        pendingEntries = []
        if DevSupport.environment["TRANSCRIBE_LIBRARY"] == nil {
            UserDefaults.standard.set(store.root == LibraryStore.defaultRoot.standardizedFileURL ? "" : store.root.path,
                                      forKey: SettingsKeys.libraryRoot)
        }
    }

    /// Move: copies on a background thread with the progress sheet up. Returns an error message.
    func moveLibrary(to folder: URL) async -> String? {
        guard canChangeLibrary else { return "Can’t change the location while a file is transcribing." }
        let source = library
        libraryMove = LibraryMoveState(destination: folder, progress: .init(entriesDone: 0, entriesTotal: source.entries.count,
                                                                              bytesDone: 0, bytesTotal: 0))
        let flag = CancelFlag()
        moveCancel = flag
        defer { libraryMove = nil; moveCancel = nil; pump() }
        let result: Result<LibraryStore, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try source.move(to: folder) { p in
                    Task { @MainActor [weak self] in self?.libraryMove?.progress = p }
                    return !flag.isSet
                }
            }
        }.value
        switch result {
        case .success(let store):
            setLibrary(store)
            return nil
        case .failure(let error):
            if case LibraryError.cancelled = error { return nil }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelLibraryMove() {
        moveCancel?.set()
        libraryMove?.cancelled = true
    }
}

/// Set from the main thread, read by the copy loop.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
