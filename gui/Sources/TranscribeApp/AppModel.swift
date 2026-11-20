import AppKit
import Observation
import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

/// App state: the queue, selection, options and the worker wiring. Main actor only; the
/// resident `transcribe serve` process lives in `WorkerClient` and reaches us through its
/// `AsyncStream`. The GUI owns the queue and sends one job at a time.
@MainActor
@Observable
final class AppModel {
    enum Banner: Equatable {
        case ffmpegMissing
        case cliNotFound(String)
        /// The installed CLI's version differs from the app's (non-blocking).
        case cliOutdated(installed: String, expected: String)
        case message(String)
    }

    /// `uv tool install` of the CLI, run from the not-found / outdated banners.
    enum CLIInstallState: Equatable {
        case idle
        case running(lastLine: String)
        case failed(message: String, tail: String)
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All", ready = "Ready", queued = "Queued", working = "Working", done = "Done", failed = "Failed", stopped = "Stopped"
        var id: String { rawValue }
    }

    /// What the worker process is doing, for the Environment card and the status label.
    enum WorkerState: Equatable { case stopped, starting, idle, busy }

    /// What the inspector's options edit.
    enum OptionsScope: Equatable {
        case defaults
        case file(FileItem.ID)
        case files([FileItem.ID])
        case readOnly(FileItem.ID)
    }

    // Queue
    var queue = QueueModel()
    /// Selected rows (⌘-click, ⇧-click, ⌘A; the checked rows in Select mode).
    var selection: Set<FileItem.ID> = [] { didSet { if selection != oldValue { selectionChanged(from: oldValue) } } }
    /// Selected History entries. One selection for the whole sidebar:
    /// selecting in one list clears the other.
    var historySelection: Set<LibraryEntry.ID> = [] {
        didSet { if !historySelection.isEmpty, !selection.isEmpty { selection = [] } }
    }
    /// The end of the last plain or ⌘ click, where ⇧-click ranges start.
    var selectionAnchor: FileItem.ID?
    var selectMode = false { didSet { if !selectMode && oldValue { selection = [] } } }
    var expanded: Set<FileItem.ID> = []
    var finishedExpanded = false
    var waveforms: [FileItem.ID: Waveform] = [:]
    /// The time at the top of a live transcript, so the finished preview opens at the same place.
    var liveTopTime: [FileItem.ID: Double] = [:]

    // Library. See AppModel+Library.swift.
    var library: LibraryStore { didSet { syncSearchIndex() } }
    /// The index couldn't be read: nothing is written to the library until it is fixed.
    var libraryUnavailable: String?
    var historyCollapsed = UserDefaults.standard.bool(forKey: SettingsKeys.historyCollapsed) {
        didSet { UserDefaults.standard.set(historyCollapsed, forKey: SettingsKeys.historyCollapsed) }
    }
    /// The queue's share of the sidebar when both lists are long (after a divider drag).
    var historyRatio = UserDefaults.standard.object(forKey: SettingsKeys.historyRatio) as? Double ?? SidebarSplit.defaultRatio {
        didSet { UserDefaults.standard.set(historyRatio, forKey: SettingsKeys.historyRatio) }
    }
    var historySort = HistorySort(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.historySort) ?? "") ?? .date {
        didSet { UserDefaults.standard.set(historySort.rawValue, forKey: SettingsKeys.historySort) }
    }
    /// Entries located by a drop: a 2 pt ring, two pulses.
    var ringing: Set<LibraryEntry.ID> = []
    /// Just finished: the `blueT` fill that fades.
    var freshEntries: Set<LibraryEntry.ID> = []
    /// Committed but not shown yet (the 0.85 s Done → History motion).
    var pendingEntries: Set<LibraryEntry.ID> = []
    /// Bumped when an entry arrives, so the History count pulses.
    var historyPulse = 0
    /// History scrolls here (a drop located it, or it just arrived).
    var historyScrollTarget: LibraryEntry.ID?
    var dropNotice: DropNotice?
    /// Transcribe Again… sheet.
    var againRequest: AgainRequest?
    /// Remove from History… confirmation.
    var removeRequest: [LibraryEntry.ID]?
    /// Files done this session (the "Done n / N" chip; done rows leave the queue).
    var sessionDone = 0
    var libraryMove: LibraryMoveState?
    /// Job id → its staging folder.
    var stagingFolders: [String: URL] = [:]
    @ObservationIgnored var historyAnchorStorage: LibraryEntry.ID?
    @ObservationIgnored var moveCancel: CancelFlag?

    /// The Settings tab (Output's "Settings…" opens Library).
    var settingsTab = DevSupport.environment["TRANSCRIBE_SETTINGS_TAB"] ?? "general"

    // Export. See AppModel+Export.swift.
    /// "Timestamps in md and txt" for exports (Settings → Library → Exports, menus, toolbar).
    var exportTimestamps = ExportSettings.timestamps() {
        didSet { UserDefaults.standard.set(exportTimestamps, forKey: ExportSettings.timestampsKey) }
    }
    /// The format a History row's Save uses: the last one saved.
    var lastExportFormat = ExportSettings.lastFormat() {
        didSet { UserDefaults.standard.set(lastExportFormat.rawValue, forKey: ExportSettings.lastFormatKey) }
    }
    /// "entryID/format" being made, shown once the 150 ms grace is over.
    var makingShown: Set<String> = []
    @ObservationIgnored var makingStarted: Set<String> = []
    /// "entryID/format" → why the last make failed (red chip).
    var exportFailures: [String: String] = [:]
    var toast: Toast?
    /// Locate…: the picked file isn't the same recording.
    var locateMismatch: LocateMismatch?
    @ObservationIgnored var exportWaiters: [String: CheckedContinuation<ExportReply, Never>] = [:]
    /// Align Subtitles runs by entry (see AppModel+Align.swift), and why the last one failed.
    var aligning: [LibraryEntry.ID: AlignProgress] = [:]
    var alignFailures: [LibraryEntry.ID: String] = [:]
    /// Align job id → entry.
    @ObservationIgnored var alignJobs: [String: LibraryEntry.ID] = [:]
    @ObservationIgnored var alignWaiters: [String: CheckedContinuation<AlignReply, Never>] = [:]

    // Filters
    var searchText = "" { didSet { if searchText != oldValue { syncSearchIndex() } } }
    /// Titles or Text; the queue always matches file names.
    var searchScope: SearchScope = .titles { didSet { syncSearchIndex() } }
    let searcher = TranscriptSearcher()
    var issuesOnly = false
    var statusFilter: StatusFilter = .all
    var isFiltering: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || issuesOnly || statusFilter != .all }

    // Panes. `showCenter` / `showInspector` are the user's toggles; whether a pane is visible
    // also depends on the window width (`paneLayout`).
    var showCenter = true
    var showInspector = true
    /// Content width of the main window, kept current by `ContentView`.
    var windowWidth = 1280.0
    /// Widths the user dragged the side panes to.
    var queueWidthPreference = PaneLayout.queueIdeal { didSet { UserDefaults.standard.set(queueWidthPreference, forKey: "pane.queueWidth") } }
    var inspectorWidthPreference = PaneLayout.inspectorIdeal { didSet { UserDefaults.standard.set(inspectorWidthPreference, forKey: "pane.inspectorWidth") } }
    var showQuitConfirmation = false
    /// A model to remove once the user confirms (Models window).
    var pendingRemoval: ModelInfo?
    /// Set when the user picks "Jump to notices" in the center toolbar.
    var inspectorFocus: String?
    /// Quick Look target: the selected file's first output, or the source when unfinished.
    var quickLookURL: URL?

    // Environment
    private(set) var command: CLICommand?
    private(set) var doctor: DoctorReport?
    private(set) var backends: BackendsReport?
    private(set) var cacheStatus: [CachedModel: Bool] = [:]
    private(set) var checkingEnvironment = false
    var banner: Banner?
    private(set) var cliInstall: CLIInstallState = .idle
    /// `uv` on the locator's PATH; nil shows the `brew install uv` command instead of Install.
    private(set) var uvPath: String?
    /// The outdated-CLI banner was dismissed for this version pair.
    private var dismissedOutdated: Banner?

    // Worker
    private(set) var catalog = ModelCatalog()
    private(set) var workerState: WorkerState = .stopped
    private(set) var history: RunHistory
    private let historyURL: URL
    private var worker: WorkerClient?
    private var workerLaunch: Task<WorkerClient?, Never>?
    private var workerPID: Int32?
    private var stderrTail: [String] = []
    private var pumping = false
    /// The model a `preload` op asked for; its `model_ready` means it is in memory.
    private var preloading: String?
    private var allowTerminate = false

    // Options. `options` are the defaults for new files, remembered between launches.
    var options: TranscribeOptions {
        didSet {
            guard options != oldValue else { return }
            OptionsStore.save(options)
            queue.defaultsChanged(from: oldValue, to: options)
        }
    }

    /// Bumped when a running file has been quiet for the stall threshold, so `status(of:)`
    /// re-evaluates the "Preparing model" guess. Time-displaying text uses TimelineView instead
    /// of a global ticker (which re-rendered every view twice a second).
    private(set) var stallRevision = 0
    private var stallCheck: DispatchWorkItem?
    /// Updates received this main-queue turn, applied together (see `WorkerEventCoalescer`).
    private var pendingUpdates: [WorkerUpdate] = []
    private var lastRunningID: FileItem.ID?

    init() {
        ExportSettings.migrate(.standard)
        options = OptionsStore.load()
        let d = UserDefaults.standard
        if d.double(forKey: "pane.queueWidth") > 0 { queueWidthPreference = d.double(forKey: "pane.queueWidth") }
        if d.double(forKey: "pane.inspectorWidth") > 0 { inspectorWidthPreference = d.double(forKey: "pane.inspectorWidth") }
        historyURL = DevSupport.environment["TRANSCRIBE_HISTORY"].map { URL(fileURLWithPath: $0) } ?? RunHistory.defaultURL
        history = RunHistory.load(from: historyURL)
        let root = Self.libraryRoot
        DevSupport.seedLibraryIfAsked(at: root)
        do {
            library = try LibraryStore(root: root)
            library.cleanStaging()
        } catch {
            library = Self.emptyStore(root)
            libraryUnavailable = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            banner = .message("\(libraryUnavailable!) Finished files aren’t saved until it is fixed or another location is chosen in Settings → Library.")
        }
    }

    // MARK: Derived

    var items: [FileItem] { queue.items }
    var isRunning: Bool { queue.isRunning }
    /// The one selected file; nil with none or several.
    var selectedItem: FileItem? { selection.count == 1 ? selection.first.flatMap { queue[$0] } : nil }
    /// Selected files in display order.
    var selectedItems: [FileItem] { selectedIDs.compactMap { queue[$0] } }
    var selectedIDs: [FileItem.ID] { queue.displayOrder.filter(selection.contains) }

    func status(of item: FileItem) -> RowStatus {
        _ = stallRevision
        return queue.status(of: item) { [catalog, cacheStatus] m in
            catalog[m.rawValue].map { $0.status == .downloaded } ?? cacheStatus[m] ?? true
        }
    }

    /// Search and the status filter flatten the list.
    var filteredItems: [FileItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return queue.displayOrder.compactMap { queue[$0] }.filter { item in
            let s = status(of: item)
            if !q.isEmpty, !item.name.lowercased().contains(q) { return false }
            if issuesOnly, !s.isIssue { return false }
            switch statusFilter {
            case .all: return true
            case .ready: return s == .ready
            case .queued: if case .queued = s { return true }; return false
            case .working: return s.isWorking
            case .done: if case .done = s { return true }; if case .doneWithNotices = s { return true }; return false
            case .failed: if case .failed = s { return true }; return false
            case .stopped: if case .stopped = s { return true }; return false
            }
        }
    }

    var readyIDs: [FileItem.ID] { queue.readyIDs }
    /// Selected files that Start / Queue would schedule (Ready, Failed, Stopped).
    var startableSelection: [FileItem.ID] { selectedItems.filter(queue.canQueue).map(\.id) }
    var failedIDs: [FileItem.ID] { items.filter { $0.error != nil }.map(\.id) }
    var hasFinished: Bool { items.contains { $0.state.isTerminal } }
    var hasWaiting: Bool { !queue.upNext.isEmpty }

    var statusLabel: String {
        if let current = queue.currentItem {
            switch status(of: current) {
            case .preparingModel(let m, let d):
                let what = m == .aligner ? "aligner" : m.shortName.replacingOccurrences(of: "Qwen3-ASR ", with: "")
                return d?.info.fraction.map { "Downloading \(what) · \(Formatting.percent($0))" } ?? "Preparing \(what)…"
            case .stopping: return "Stopping…"
            default:
                let waiting = queue.upNext.count
                return waiting == 0 ? "Transcribing" : "Transcribing · \(waiting) up next"
            }
        }
        if items.isEmpty { return "Ready" }
        let ready = readyIDs.count
        if ready > 0 { return ready == 1 ? "1 file ready" : "\(ready) files ready" }
        let done = queue.doneCount
        return done == items.count ? "All done" : "\(done) of \(items.count) done"
    }

    /// "Left ≈ 4 min" while something runs.
    func leftEstimate(now: Date) -> TimeInterval? {
        QueueEstimate.remaining(queue, history: history, now: now)
    }

    /// Model the next Start would use, and whether it still needs downloading.
    var selectedModelCached: Bool {
        catalog[options.model.rawValue].map { $0.status == .downloaded } ?? cacheStatus[options.model.cacheModel] ?? false
    }

    func isDownloaded(_ choice: ModelChoice) -> Bool {
        catalog[choice.rawValue].map { $0.status == .downloaded } ?? cacheStatus[choice.cacheModel] ?? false
    }

    /// The speech model the worker holds in memory.
    var loadedModel: ModelInfo? { catalog.models.first { $0.loaded && $0.isSpeechModel } }

    // MARK: Selection

    /// A row click: plain replaces, ⌘ toggles, ⇧ extends from the anchor in display order.
    /// In Select mode a plain click toggles.
    func click(_ id: FileItem.ID, command: Bool, shift: Bool, in order: [FileItem.ID]) {
        if shift, let anchor = selectionAnchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            let range = Set(order[min(a, b)...max(a, b)])
            selection = command ? selection.union(range) : range
            return
        }
        if command || selectMode {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        selectionAnchor = id
    }

    func selectAll(in order: [FileItem.ID]) { selection = Set(order) }

    private func selectionChanged(from old: Set<FileItem.ID>) {
        if !selection.isEmpty, !historySelection.isEmpty { historySelection = [] }
        // A selected finished row has to be visible.
        if selection.contains(where: { id in queue[id].map { queue.section(of: $0) == .finished } ?? false }),
           !selection.isSubset(of: old) {
            finishedExpanded = true
        }
    }

    // MARK: Adding and removing

    /// Dropped or chosen files. Each is fingerprinted first: files already in the library don't
    /// enter the queue. A check that takes over a second shows a Checking… row.
    func add(_ urls: [URL]) {
        let files = urls.flatMap(Self.expandMediaFiles)
        guard !files.isEmpty else { return }
        let placeholders = Task { @MainActor [weak self] () -> [FileItem.ID] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return [] }
            return self.addChecking(files)
        }
        Task {
            let fingerprints = await Self.fingerprints(files)
            placeholders.cancel()
            finishAdd(files, fingerprints: fingerprints, placeholders: await placeholders.value)
        }
    }

    /// The same, synchronously (dev hooks and snapshots).
    func addNow(_ urls: [URL]) {
        let files = urls.flatMap(Self.expandMediaFiles)
        var fps: [URL: SourceFingerprint] = [:]
        for f in files { fps[f] = try? SourceFingerprint.read(f) }
        finishAdd(files, fingerprints: fps, placeholders: [])
    }

    /// Adds files to Ready (Up next with auto start). Returns the new rows.
    @discardableResult
    func enqueueFiles(_ files: [URL], options: TranscribeOptions? = nil, fingerprints: [URL: SourceFingerprint] = [:]) -> [FileItem.ID] {
        let ids = queue.add(files, options: options ?? self.options, queue: autoStart)
        for id in ids {
            if let url = queue[id]?.url, let fp = fingerprints[url] ?? fingerprints.first(where: { $0.key.standardizedFileURL == url })?.value {
                queue.update(id) { $0.fingerprint = fp }
            }
            loadMedia(for: id)
        }
        if autoStart { pump() }
        return ids
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audiovisualContent, .audio, .movie]
        panel.message = "Choose audio or video files to transcribe"
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Removes rows from the list. Nothing on disk is touched; the running file stays.
    func remove(_ ids: some Sequence<FileItem.ID>) {
        let set = Set(ids)
        queue.remove(set)
        for id in set where queue[id] == nil { waveforms[id] = nil; liveTopTime[id] = nil }
        selection = selection.filter { queue[$0] != nil }
    }

    func removeSelected() { remove(selection) }

    func clearFinished() {
        queue.clearFinished()
        selection = selection.filter { queue[$0] != nil }
    }

    func loadMedia(for id: FileItem.ID) {
        guard let url = queue[id]?.url else { return }
        Task {
            let info = await MediaInfo.load(url)
            queue.update(id) { item in
                if item.duration == nil { item.duration = info.duration }
                item.kind = info.kind
            }
            if let wave = await MediaInfo.waveform(url) { waveforms[id] = wave }
        }
    }

    /// Files as given; folders contribute the media files directly inside them.
    nonisolated static func expandMediaFiles(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [url] }
        guard isDir.boolValue else { return [url] }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents.filter { u in
            guard let type = try? u.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .audiovisualContent)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Scheduling

    /// Queues files (Start, Queue, Retry) and starts the first when the worker is free.
    func start(_ ids: [FileItem.ID]) {
        guard !ids.isEmpty else { return }
        queue.queue(ids)
        pump()
    }

    /// ⌘R: the selected files.
    func startSelected() { start(startableSelection) }
    /// ⌥⌘R: every Ready file.
    func startAllReady() { start(readyIDs) }

    /// The idle primary button: "Start N Selected" when Ready files are selected, else "Start All (N)".
    func startPrimary() {
        if startableSelection.isEmpty { startAllReady() } else { startSelected() }
    }

    func runNext(_ ids: [FileItem.ID]) {
        queue.runNext(ids)
        pump()
    }

    func unqueue(_ ids: some Sequence<FileItem.ID>) { queue.unqueue(ids) }
    func unqueueWaiting() { queue.unqueueAll() }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.moveUpNext(fromOffsets: source, toOffset: destination)
    }

    /// A row drag ended over a section.
    func drop(_ ids: [FileItem.ID], into section: QueueSection, at index: Int?) {
        withAnimation(.snappy(duration: 0.2)) { queue.drop(ids, into: section, at: index) }
        if section == .upNext { pump() }
    }

    func retry(_ id: FileItem.ID) { start([id]) }
    func retryFailed() { start(failedIDs) }

    /// ⌘. Stops the running file; the next one in Up next then starts.
    func stopCurrent() {
        guard let id = queue.currentID else { return }
        stop(id)
    }

    /// Stop for one row: the running file is cancelled, a queued one unqueued.
    func stop(_ id: FileItem.ID) {
        if let job = queue.requestStop(id) { send(.cancel(id: job)) }
    }

    /// ⌥⌘. Unqueues the waiting files and stops the running one.
    func stopAll() {
        if let job = queue.requestStopAll() { send(.cancel(id: job)) }
    }

    /// "Run Again with Changes…": a Ready copy with the old options and Overwrite
    /// on, selected so its options show in the inspector.
    func runAgainWithChanges(_ id: FileItem.ID) {
        guard let copy = queue.duplicateForRerun(id) else { return }
        loadMedia(for: copy)
        selection = [copy]
        selectionAnchor = copy
        if !inspectorVisible { togglePane(.inspector) }
    }

    /// Sends the next job when the worker is free.
    func pump() {
        // An Align Subtitles run has the worker: the next file waits for it.
        guard queue.currentID == nil, !queue.upNext.isEmpty, !pumping, libraryMove == nil, aligning.isEmpty else { return }
        pumping = true
        Task {
            defer { pumping = false }
            guard let worker = await ensureWorker() else { return }  // the banner says why; files stay queued
            guard queue.currentID == nil, libraryMove == nil, aligning.isEmpty, let next = queue.startNext() else { return }
            followSelection(to: next.id)
            HangProbe.shared?.markStart()
            guard let job = libraryJob(next.job) else {
                queue.apply(.fileError(id: next.job.id, error: "Couldn’t create a folder in the library at \(library.root.path)."))
                finished(next.id, .fileError(id: next.job.id, error: ""))
                return
            }
            if await worker.send(.enqueue(job)) {
                scheduleStallCheck()
            } else {
                queue.workerExited(.crashed(code: -1))
            }
        }
    }

    /// If the previous running file is selected (or nothing is), follow the queue to the next file.
    private func followSelection(to id: FileItem.ID) {
        if selection.isEmpty || (lastRunningID.map { selection == [$0] } ?? false) { selection = [id] }
        lastRunningID = id
    }

    // MARK: Options

    var optionsScope: OptionsScope {
        let items = selectedItems
        guard let first = items.first else { return .defaults }
        if items.count == 1 { return first.optionsEditable ? .file(first.id) : .readOnly(first.id) }
        let editable = items.filter(\.optionsEditable).map(\.id)
        switch editable.count {
        case 0: return .readOnly(first.id)
        case 1: return .file(editable[0])
        default: return .files(editable)
        }
    }

    /// The options the inspector shows: the defaults, the file's own, or (for several files)
    /// the first file's, with `mixedOptions` saying where they differ.
    var shownOptions: TranscribeOptions {
        switch optionsScope {
        case .defaults: options
        case .file(let id): queue[id]?.options ?? options
        case .files(let ids): ids.first.flatMap { queue[$0]?.options } ?? options
        case .readOnly(let id): queue[id]?.displayedOptions ?? options
        }
    }

    /// The file the copies caption names (one file in scope), nil for the defaults or several.
    var optionsSourceName: String? {
        switch optionsScope {
        case .file(let id), .readOnly(let id): queue[id]?.url.lastPathComponent
        case .defaults, .files: nil
        }
    }

    var mixedOptions: MixedOptions? {
        guard case .files(let ids) = optionsScope else { return nil }
        return MixedOptions(ids.compactMap { queue[$0]?.options })
    }

    var optionsEditable: Bool {
        if case .readOnly = optionsScope { return false }
        return true
    }

    /// Edits what the inspector shows.
    func editOptions(_ change: (inout TranscribeOptions) -> Void) {
        switch optionsScope {
        case .defaults:
            var o = options
            change(&o)
            if o.copyFormats.isEmpty { o.copyFormats = [.md] }
            options = o
        case .file(let id): queue.setOptions([id], change)
        case .files(let ids): queue.setOptions(ids, change)
        case .readOnly: break
        }
    }

    /// Fields where the shown options differ from the defaults (empty for the defaults).
    var changedFields: Set<OptionField> {
        switch optionsScope {
        case .file, .readOnly: Set(shownOptions.differences(from: options))
        case .defaults, .files: []
        }
    }

    func resetField(_ field: OptionField) {
        let d = options
        editOptions { o in
            switch field {
            case .formats: o.formats = d.formats
            case .timestamps: o.timestamps = d.timestamps
            case .outputDirectory: o.outputDirectory = d.outputDirectory
            case .language: o.language = d.language
            case .model: o.model = d.model
            case .context: o.contextTerms = d.contextTerms
            case .overwrite: o.overwrite = d.overwrite
            case .copies: o.copyMode = d.copyMode; o.copyFormats = d.copyFormats
            }
        }
    }

    /// ⌥⌘C: the selected file's options (or the defaults).
    func copyOptions(of id: FileItem.ID? = nil) {
        let o = id.flatMap { queue[$0]?.displayedOptions } ?? shownOptions
        guard let data = OptionsClipboard.encode(o) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: NSPasteboard.PasteboardType(OptionsClipboard.pasteboardType))
        pb.setString(o.summary(duration: nil, defaultModel: options.model)
            .replacingOccurrences(of: "–:–– · ", with: ""), forType: .string)
    }

    var clipboardOptions: TranscribeOptions? {
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(OptionsClipboard.pasteboardType))
            .flatMap(OptionsClipboard.decode)
    }

    /// ⌥⌘V: onto the given files, or whatever the inspector edits.
    func pasteOptions(to ids: [FileItem.ID]? = nil) {
        guard let o = clipboardOptions else { NSSound.beep(); return }
        if let ids { queue.setOptions(ids) { $0 = o } } else { editOptions { $0 = o } }
    }

    /// Files "Apply to Selected" would change: the other selected, editable files.
    var applyToSelectedTargets: [FileItem.ID] {
        guard case .files(let ids) = optionsScope else { return [] }
        return Array(ids.dropFirst())
    }

    func applyToSelected() {
        let o = shownOptions
        queue.setOptions(applyToSelectedTargets) { $0 = o }
    }

    var readyAndQueuedIDs: [FileItem.ID] { items.filter { $0.state == .ready || $0.state == .queued }.map(\.id) }

    func applyToAllReadyAndQueued() {
        let o = shownOptions
        queue.setOptions(readyAndQueuedIDs) { $0 = o }
    }

    func saveAsDefaults() { options = shownOptions }

    func resetToDefaults(_ ids: [FileItem.ID]? = nil) {
        let d = options
        let targets: [FileItem.ID]
        if let ids { targets = ids } else {
            switch optionsScope {
            case .file(let id): targets = [id]
            case .files(let ids): targets = ids
            case .defaults, .readOnly: targets = []
            }
        }
        queue.setOptions(targets) { $0 = d }
    }

    // MARK: Settings

    var autoStart: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoStart) }
    var idleUnloadSeconds: Double {
        UserDefaults.standard.object(forKey: SettingsKeys.idleUnload) == nil ? 300 : UserDefaults.standard.double(forKey: SettingsKeys.idleUnload)
    }
    var preloadOnLaunch: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.preload) }

    /// The unload time changed in Settings: tell a running worker.
    func idleUnloadChanged() {
        guard worker != nil else { return }
        send(.configure(idleUnloadSec: idleUnloadSeconds))
    }

    /// At launch, with "Load model when the app opens" on.
    func preloadIfWanted() {
        guard preloadOnLaunch else { return }
        preload(options.model.rawValue)
    }

    func preload(_ model: String) {
        preloading = model
        send(.preload(model: model))
    }

    // MARK: Models

    /// Starts the worker if needed and asks it for the catalog.
    func refreshModels() { send(.models) }

    func download(_ id: String) {
        catalog.beginDownload(id)
        send(.download(model: id))
    }

    func cancelDownload(_ id: String) { send(.cancelDownload(model: id)) }

    func requestRemove(_ id: String) { pendingRemoval = catalog[id] }

    func confirmRemove() {
        guard let m = pendingRemoval else { return }
        pendingRemoval = nil
        send(.removeModel(model: m.id))
    }

    /// Whether the running file uses this model (removal is refused while it runs).
    func modelInUseByJob(_ id: String) -> Bool {
        guard let item = queue.currentItem else { return false }
        return item.model.rawValue == id || (id == "aligner" && item.wantsCues)
    }

    var cacheRoot: URL { ModelCache(doctorHFCache: doctor?.hfCache).root }

    // MARK: Worker

    /// The running worker, launching one if there is none (first Start, or after it died).
    @discardableResult
    func ensureWorker() async -> WorkerClient? {
        if let worker, await worker.isRunning { return worker }
        if let launch = workerLaunch { return await launch.value }
        let launch = Task<WorkerClient?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.workerLaunch = nil }
            let cmd: CLICommand
            do {
                cmd = try self.locateCLI()
            } catch {
                self.banner = .cliNotFound((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return nil
            }
            if case .cliNotFound = self.banner { self.banner = nil }
            self.workerState = .starting
            let client = WorkerClient(command: cmd)
            let stream: AsyncStream<WorkerUpdate>
            do {
                stream = try await client.launch()
            } catch {
                self.workerState = .stopped
                self.banner = .message((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return nil
            }
            self.worker = client
            self.workerPID = await client.processIdentifier
            self.stderrTail = []
            Task { [weak self] in
                for await update in stream { self?.enqueue(update) }
                self?.flushUpdates()
            }
            await client.send(.configure(idleUnloadSec: self.idleUnloadSeconds))
            await client.send(.models)
            self.workerState = .idle
            return client
        }
        workerLaunch = launch
        return await launch.value
    }

    /// Sends an op, starting the worker first if needed.
    private func send(_ op: ServeOp) {
        Task {
            guard let worker = await ensureWorker() else { return }
            await worker.send(op)
        }
    }

    /// Buffers an update and applies the buffer once the main queue has drained what's ready,
    /// so events that arrive together cost one view update.
    private func enqueue(_ update: WorkerUpdate) {
        pendingUpdates.append(update)
        guard pendingUpdates.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in self?.flushUpdates() }
    }

    private func flushUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        let batch = WorkerEventCoalescer.coalesce(pendingUpdates)
        pendingUpdates = []
        for update in batch {
            switch update {
            case .event(let e): apply(e)
            case .stderr(let line):
                stderrTail.append(line)
                if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
            case .exited(let x): workerExited(x)
            }
        }
    }

    private func apply(_ event: ServeEvent) {
        catalog.apply(event)
        switch event {
        case .idle: workerState = .idle
        case .accepted: workerState = .busy
        case .modelReady(let m):
            if preloading.map({ catalog.catalogID(for: $0) == catalog.catalogID(for: m) }) == true {
                catalog.markLoaded(m)
                preloading = nil
            }
            refreshCacheStatus()
        case .modelError(let m, let error, let cancelled):
            if preloading != nil, m == nil || catalog.catalogID(for: m ?? "") == preloading.flatMap(catalog.catalogID(for:)) {
                preloading = nil
            }
            if !cancelled, m == nil { banner = .message(error) }
        case .modelRemoved:
            refreshCacheStatus()
        case .exported(let id, let outputs, _):
            exportWaiters.removeValue(forKey: id)?.resume(returning: .done(outputs))
        case .exportError(let id, let message):
            exportWaiters.removeValue(forKey: id)?.resume(returning: .failed(message))
        default: break
        }
        if applyAlign(event) { return }
        guard event.jobID != nil else { return }
        if case .progress(_, let p) = event, p.stage == .transcribe, let item = queue.currentItem {
            catalog.markLoaded(item.model.rawValue)
        }
        guard let id = queue.apply(event) else { return }
        scheduleStallCheck()
        if event.isTerminal {
            // One job at a time, so the worker is free now; serve sends no `idle` after an
            // early file_error (output exists).
            workerState = .idle
            finished(id, event)
        }
    }

    private func finished(_ id: FileItem.ID, _ event: ServeEvent) {
        if case .fileDone(_, let result) = event, let item = queue[id] {
            let model = catalog.catalogID(for: result.model ?? "") ?? item.model.rawValue
            if let d = result.duration ?? item.duration, let e = result.elapsed {
                history.record(RunRecord(model: model, duration: d, elapsed: e, date: Date()))
                try? history.save(to: historyURL)
            }
            commitToLibrary(id, result: result)
        } else if let job = event.jobID {
            discardStaging(job)
        }
        if selection.contains(id) { finishedExpanded = true }
        stallCheck?.cancel()
        if worker != nil { send(.models) }
        refreshCacheStatus()
        pump()
    }

    private func workerExited(_ exit: WorkerExit) {
        for (_, w) in exportWaiters { w.resume(returning: .failed("The transcribe worker quit.")) }
        exportWaiters = [:]
        failAligns("The transcribe worker quit.")
        worker = nil
        workerPID = nil
        workerState = .stopped
        preloading = nil
        for m in catalog.models where m.loaded { catalog.apply(.unloaded(model: m.repo, reason: .shutdown)) }
        if exit.isCrash {
            let wasRunning = queue.isRunning
            queue.workerExited(.crashed(code: exit.code))
            let detail = stderrTail.suffix(2).joined(separator: " ")
            banner = .message("The transcribe worker quit unexpectedly (exit code \(exit.code)).\(wasRunning ? " The running file failed." : "") "
                              + "The next Start launches it again.\(detail.isEmpty ? "" : " \(detail)")")
        } else {
            queue.workerExited(.requested)
        }
        for job in Array(stagingFolders.keys) { discardStaging(job) }
        stallCheck?.cancel()
    }

    /// Arms a timer for the stall heuristic after each event of the running file.
    private func scheduleStallCheck() {
        stallCheck?.cancel()
        guard let id = queue.currentItem?.id else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.queue.currentItem?.id == id else { return }
                self.stallRevision += 1
            }
        }
        stallCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + queue.stallThreshold + 0.05, execute: work)
    }

    // MARK: Quit

    /// Called from the app delegate. While a file runs, cancels this quit and asks; otherwise
    /// shuts the worker down and quits once it has exited. (Returning `.terminateLater` would
    /// park the main run loop in a modal mode that never services the work that finishes it.)
    func shouldTerminate() -> NSApplication.TerminateReply {
        if allowTerminate || (worker == nil && workerLaunch == nil) { return .terminateNow }
        if isRunning {
            showQuitConfirmation = true
            return .terminateCancel
        }
        shutdownAndQuit()
        return .terminateCancel
    }

    func confirmQuit(_ quit: Bool) {
        showQuitConfirmation = false
        guard quit else { return }
        queue.unqueueAll()
        shutdownAndQuit()
    }

    private func shutdownAndQuit() {
        Task {
            if let worker { await worker.shutdown() }
            allowTerminate = true
            NSApp.terminate(nil)
        }
    }

    /// Last resort in `applicationWillTerminate`: never leave the worker behind.
    func killWorkerIfRunning() {
        guard let pid = workerPID, kill(pid, 0) == 0 else { return }
        WorkerClient.shutdownBlocking(pid: pid, stdin: nil, grace: 0.5)
    }

    /// The app itself got SIGTERM/SIGINT: shut the worker down so it isn't orphaned, then exit.
    func stopAndExit() {
        guard let worker else { exit(0) }
        Task {
            await worker.shutdown(grace: 1.5)
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    // MARK: Environment

    func locateCLI() throws -> CLICommand {
        let d = UserDefaults.standard
        let cmd = try CLILocator().locate(overridePath: d.string(forKey: SettingsKeys.cliPath),
                                          repoPath: d.string(forKey: SettingsKeys.repoPath))
        command = cmd
        return cmd
    }

    /// Finds the CLI, runs `doctor --json` and `backends --json`, and probes the model cache.
    func checkEnvironment() async {
        checkingEnvironment = true
        defer { checkingEnvironment = false }
        uvPath = CLILocator().findExecutable("uv")
        let cmd: CLICommand
        do {
            cmd = try locateCLI()
        } catch {
            command = nil
            banner = .cliNotFound((error as? LocalizedError)?.errorDescription ?? "\(error)")
            refreshCacheStatus()
            return
        }
        switch banner {
        case .cliNotFound, .cliOutdated: banner = nil
        default: break
        }
        let helper = CLIHelper(command: cmd)
        async let d = try? helper.doctor()
        async let b = try? helper.backends()
        async let v = CLIInstaller.checksVersion(of: cmd.source) ? try? helper.output(of: ["--version"], timeout: 20) : nil
        doctor = await d
        backends = await b
        let versionOutput = await v
        if let doctor {
            if doctor.ffmpeg == nil { banner = .ffmpegMissing } else if banner == .ffmpegMissing { banner = nil }
        }
        if banner == nil, Self.bundledWheel != nil, let versionOutput,
           let installed = CLIInstaller.mismatch(cliOutput: String(decoding: versionOutput, as: UTF8.self),
                                                 appVersion: Self.appVersion) {
            let outdated = Banner.cliOutdated(installed: installed.description, expected: Self.appVersion ?? "")
            if outdated != dismissedOutdated { banner = outdated }
        }
        refreshCacheStatus()
    }

    // MARK: CLI install

    /// The app's CFBundleShortVersionString (nil under `swift run`).
    nonisolated static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// The wheel release builds put in Contents/Resources; `TRANSCRIBE_WHEEL` overrides it
    /// for development.
    nonisolated static let bundledWheel: URL? = {
        if let path = DevSupport.environment["TRANSCRIBE_WHEEL"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return CLIInstaller.bundledWheel(in: Bundle.main.resourceURL)
    }()

    /// What Install installs: the bundled wheel, else (development bundles) the release
    /// download for the app's version. Nil under `swift run`, which hides the button.
    var cliInstallSource: CLIInstaller.Source? {
        CLIInstaller.source(bundledWheel: Self.bundledWheel, appVersion: Self.appVersion)
    }

    /// Runs `uv tool install --force --python 3.12 <wheel>`, streaming its last line into the
    /// banner, then checks the environment again.
    func installCLI() {
        if case .running = cliInstall { return }
        guard !isRunning, let source = cliInstallSource else { return }
        let locator = CLILocator()
        guard let uv = locator.findExecutable("uv") else {
            uvPath = nil
            return
        }
        uvPath = uv
        let cmd = CLIInstaller.command(uv: uv, source: source, locator: locator)
        cliInstall = .running(lastLine: "Starting uv…")
        Task {
            do {
                let result = try await StreamingProcess.run(cmd) { line in
                    Task { @MainActor [weak self] in
                        if case .running = self?.cliInstall { self?.cliInstall = .running(lastLine: line) }
                    }
                }
                if result.status == 0 {
                    cliInstall = .idle
                    // The worker (if any) runs the old CLI; the next Start relaunches it.
                    await stopWorkerForReinstall()
                    await checkEnvironment()
                } else {
                    cliInstall = .failed(message: "uv tool install exited with code \(result.status).",
                                         tail: result.tail.suffix(6).joined(separator: "\n"))
                }
            } catch {
                cliInstall = .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)", tail: "")
            }
        }
    }

    /// Stops an idle worker so the next Start runs the newly installed CLI.
    private func stopWorkerForReinstall() async {
        if let worker, !isRunning { await worker.shutdown() }
    }

    func dismissOutdatedBanner() {
        if case .cliOutdated = banner { dismissedOutdated = banner; banner = nil }
        cliInstall = .idle
    }

    func copyUvCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CLIInstaller.uvInstallCommand, forType: .string)
    }

    func refreshCacheStatus() {
        let cache = ModelCache(doctorHFCache: doctor?.hfCache)
        cacheStatus = cache.status()
    }

    func copyFFmpegCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
    }

    // MARK: Files

    /// Space in the queue: preview the selected file's output (or the media itself).
    @discardableResult
    func toggleQuickLook(_ id: FileItem.ID? = nil) -> Bool {
        if quickLookURL != nil { quickLookURL = nil; return true }
        guard let item = id.flatMap({ queue[$0] }) ?? selectedItems.first else { return false }
        let path = item.result?.orderedOutputs.first { FileManager.default.fileExists(atPath: $0.path) }?.path ?? item.path
        quickLookURL = URL(fileURLWithPath: path)
        return true
    }

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty, let first = paths.first {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (first as NSString).deletingLastPathComponent)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// ⇧⌘R: the outputs of the selected finished files.
    func revealOutputs(_ ids: [FileItem.ID]? = nil) {
        let paths = (ids ?? selectedIDs).compactMap { queue[$0]?.result }.flatMap { $0.orderedOutputs.map(\.path) }
        if !paths.isEmpty { reveal(paths) }
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Copy Transcript: the first text output of a finished file.
    func copyTranscript(_ id: FileItem.ID) {
        guard let r = queue[id]?.result,
              let path = r.outputs["md"] ?? r.outputs["txt"] ?? r.orderedOutputs.first?.path,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum SettingsKeys {
    static let cliPath = "cliPathOverride"
    static let repoPath = "uvProjectPath"
    static let autoStart = "queue.autoStart"
    static let idleUnload = "memory.idleUnloadSec"
    static let preload = "memory.preloadOnLaunch"
    /// Dock icon id (an SVG basename in gui/icons); empty is Default.
    static let appIcon = "appearance.appIcon"
    /// The library folder; unset = ~/Transcrio Library.
    static let libraryRoot = "library.root"
    /// D3: align subtitle cues for every file (default on).
    static let alwaysAlign = "library.alwaysAlign"
    static let historyCollapsed = "history.collapsed"
    static let historyRatio = "history.ratio"
    static let historySort = "history.sort"
}

/// Options persisted in user defaults, one key per option (the same keys `@AppStorage` would use).
enum OptionsStore {
    static let formats = "opt.formats", timestamps = "opt.timestamps", outputDir = "opt.outputDirectory",
               language = "opt.language", model = "opt.model", context = "opt.context", overwrite = "opt.overwrite",
               copyMode = "opt.copyMode", copyFormats = "opt.copyFormats"

    static func load(_ d: UserDefaults = .standard) -> TranscribeOptions {
        var o = TranscribeOptions()
        if let f = d.string(forKey: formats) {
            // "" is a choice since P2: nothing prepared, transcript.json only.
            o.formats = f.split(separator: ",").compactMap { OutputFormat(rawValue: String($0)) }
        }
        o.timestamps = d.bool(forKey: timestamps)
        if let dir = d.string(forKey: outputDir), !dir.isEmpty { o.outputDirectory = URL(fileURLWithPath: dir, isDirectory: true) }
        if let l = d.string(forKey: language), !l.isEmpty { o.language = l }
        if let m = d.string(forKey: model).flatMap(ModelChoice.init(rawValue:)) { o.model = m }
        if let c = d.stringArray(forKey: context) { o.contextTerms = c }
        o.overwrite = d.bool(forKey: overwrite)
        if let m = d.string(forKey: copyMode).flatMap(CopyMode.init(rawValue:)) { o.copyMode = m }
        if let f = d.string(forKey: copyFormats) {
            let parsed = f.split(separator: ",").compactMap { OutputFormat(rawValue: String($0)) }
            if !parsed.isEmpty { o.copyFormats = parsed }
        }
        return o
    }

    static func save(_ o: TranscribeOptions, _ d: UserDefaults = .standard) {
        d.set(o.formats.map(\.rawValue).joined(separator: ","), forKey: formats)
        d.set(o.timestamps, forKey: timestamps)
        d.set(o.outputDirectory?.path ?? "", forKey: outputDir)
        d.set(o.language ?? "", forKey: language)
        d.set(o.model.rawValue, forKey: model)
        d.set(o.contextTerms, forKey: context)
        d.set(o.overwrite, forKey: overwrite)
        d.set(o.copyMode.rawValue, forKey: copyMode)
        d.set(o.copyFormats.map(\.rawValue).joined(separator: ","), forKey: copyFormats)
    }
}
