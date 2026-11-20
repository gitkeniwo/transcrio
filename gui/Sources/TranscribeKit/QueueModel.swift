import Foundation

// MARK: - Clock

/// Time source for the queue. Injected so the "Preparing model" stall heuristic can be
/// tested deterministically without real sleeps.
public protocol QueueClock: Sendable {
    func now() -> Date
}

public struct SystemClock: QueueClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock that only moves when told to. For tests and previews.
public final class ManualClock: QueueClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    public func now() -> Date { lock.withLock { current } }
    public func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

// MARK: - File item

public enum MediaKind: String, Sendable, Codable, Hashable {
    case audio, video

    static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "m4v", "avi", "webm", "mpg", "mpeg", "wmv", "flv", "3gp", "ts", "mts"]

    public init(pathExtension: String) {
        self = Self.videoExtensions.contains(pathExtension.lowercased()) ? .video : .audio
    }
}

/// When a stage started and ended, measured from event arrival.
public struct StageSpan: Sendable, Equatable {
    public var start: Date
    public var end: Date?

    public func duration(now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }
}

/// A model download in progress, from `progress stage=download` events.
public struct DownloadProgress: Sendable, Equatable {
    public var info: DownloadInfo
    /// First event of this download, for the rate.
    public var startedAt: Date
    public var startBytes: Int64
    public var updatedAt: Date

    public init(info: DownloadInfo, startedAt: Date, startBytes: Int64, updatedAt: Date) {
        self.info = info
        self.startedAt = startedAt
        self.startBytes = startBytes
        self.updatedAt = updatedAt
    }

    /// Bytes per second since the first event, once there is something to measure.
    public var bytesPerSecond: Double? {
        let t = updatedAt.timeIntervalSince(startedAt), b = Double(info.downloadedBytes - startBytes)
        return t >= 1 && b > 0 ? b / t : nil
    }

    public var remaining: TimeInterval? {
        guard let rate = bytesPerSecond, info.totalBytes > 0 else { return nil }
        return Double(max(info.totalBytes - info.downloadedBytes, 0)) / rate
    }

    /// Folds a new event for the same download in, or starts a new one.
    public static func next(_ current: DownloadProgress?, _ info: DownloadInfo, now: Date) -> DownloadProgress {
        if var d = current, d.info.model == info.model {
            d.info = info
            d.updatedAt = now
            return d
        }
        return DownloadProgress(info: info, startedAt: now, startBytes: info.downloadedBytes, updatedAt: now)
    }
}

public enum FileState: Sendable, Equatable {
    /// Added, not scheduled.
    case ready
    /// In Up next, waiting for its turn.
    case queued
    /// Sent to the worker. `stage` is `.decode` until the first event says otherwise.
    case running(stage: Stage, progress: Double, chunk: Int?, totalChunks: Int?)
    case done(FileResult)
    case failed(String)
    /// Cancelled; `at` is the audio time reached (0 if it never started).
    case stopped(at: Double)

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .stopped: true
        case .ready, .queued, .running: false
        }
    }

    public var isRunning: Bool { if case .running = self { true } else { false } }
    public var isStopped: Bool { if case .stopped = self { true } else { false } }
}

/// Color role of the filled part of a row waveform.
public enum WaveformTone: Sendable, Equatable { case track, working, finished, failed }

/// What a queue row shows: the 11 row states, plus Load model from the cache.
public enum RowStatus: Sendable, Equatable {
    case ready
    /// 1-based position in Up next.
    case queued(ordinal: Int)
    case decoding
    /// `stage=load` while the model loads from the cache.
    case loadingModel
    /// The model is downloading. With `download` events the progress is real; without them
    /// (offline, HF listing failed) this is the fallback guess: `stage=load` or `align`, quiet
    /// for a while, and the model missing from the HF cache. Then `download` is nil.
    case preparingModel(CachedModel, DownloadProgress?)
    case transcribing(percent: Double, chunk: Int?, totalChunks: Int?)
    case aligning(percent: Double)
    /// `cancel` sent, `file_stopped` not back yet.
    case stopping(percent: Double)
    case done
    case doneWithNotices(Int)
    case failed(String)
    case stopped(at: Double)

    public var isWorking: Bool {
        switch self {
        case .decoding, .loadingModel, .preparingModel, .transcribing, .aligning, .stopping: true
        default: false
        }
    }

    public var isIssue: Bool {
        switch self {
        case .failed, .doneWithNotices, .stopped: true
        default: false
        }
    }
}

public struct FileItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let path: String
    public var kind: MediaKind
    /// From AVFoundation when added; replaced by the worker's value on `file_done`.
    public var duration: Double?
    public var state: FileState = .ready
    /// This file's own options. New files copy the defaults.
    public var options: TranscribeOptions
    /// Options of the last run (what "Options used" shows for a Running or Done file).
    public var ranWith: TranscribeOptions?
    /// The worker job id of the current or last run.
    public var jobID: String?
    public var stages: [Stage: StageSpan] = [:]
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastEventAt: Date?
    /// When Stop was asked for; the row shows Stopping until `file_stopped`.
    public var stopRequestedAt: Date?
    /// Set by `download` events; cleared when the stage moves on.
    public var download: DownloadProgress?
    public var logs: [String] = []
    /// Paragraphs received as `segment` events during the run.
    public var liveSegments: [TranscriptSegment] = []
    /// Audio fraction (0–1) where each transcription chunk started, keyed by 1-based chunk.
    public var chunkStarts: [Int: Double] = [:]
    /// When each chunk's first event arrived.
    public var chunkStartedAt: [Int: Date] = [:]
    /// Chunks aligned so far, when alignment runs per chunk (serve).
    public var alignedChunks: Int = 0
    /// Audio fraction (0–1) transcribed so far. Kept when the file fails or stops.
    public var reachedFraction: Double = 0
    /// The model was already in memory when this run started (no `load` stage).
    public var modelWasWarm = false
    /// The source's content fingerprint, once computed (library lookups).
    public var fingerprint: SourceFingerprint?
    /// The fingerprint is still being computed after a drop: the row can't be started or edited.
    public var checking = false
    /// Transcribe Again: the History entry whose transcript this run replaces on success.
    public var replaces: String?

    public init(url: URL, id: UUID = UUID(), duration: Double? = nil, kind: MediaKind? = nil,
                options: TranscribeOptions = TranscribeOptions()) {
        self.id = id
        self.url = url.standardizedFileURL
        self.path = CommandBuilder.eventPath(for: url)
        self.kind = kind ?? MediaKind(pathExtension: url.pathExtension)
        self.duration = duration
        self.options = options
    }

    public var name: String { url.lastPathComponent }

    public var result: FileResult? { if case .done(let r) = state { r } else { nil } }

    public var error: String? { if case .failed(let e) = state { e } else { nil } }

    public var isStopping: Bool { state.isRunning && stopRequestedAt != nil }

    /// Options the inspector edits: Ready, Queued, Stopped and Failed files.
    public var optionsEditable: Bool {
        if checking { return false }
        return switch state {
        case .ready, .queued, .failed, .stopped: true
        case .running, .done: false
        }
    }

    /// The options to show: what the run used once it started, else the file's own.
    public var displayedOptions: TranscribeOptions {
        switch state {
        case .running, .done: ranWith ?? options
        default: options
        }
    }

    public var wantsCues: Bool { displayedOptions.wantsCues }
    public var model: ModelChoice { displayedOptions.model }
    /// `-l` of the run; nil means the language was detected.
    public var requestedLanguage: String? { displayedOptions.language }

    /// Whole-file progress 0–1 (audio transcribed). Alignment runs per chunk in serve mode, so
    /// it doesn't get a share of its own; in batch-style `align` it fills the last 10 %.
    public var overallProgress: Double {
        switch state {
        case .ready, .queued, .failed, .stopped: 0
        case .done: 1
        case .running(let stage, let p, _, _):
            switch stage {
            case .decode, .load: 0
            case .transcribe: reachedFraction
            case .align: alignedChunks > 0 ? reachedFraction : 0.9 + 0.1 * p
            }
        }
    }

    /// Wall time this file has been processing (or took, once finished).
    public func elapsed(now: Date) -> TimeInterval? {
        guard let start = startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(start)
    }

    /// Paragraphs with times: `file_done.segments` once finished, the live ones before.
    public var segments: [TranscriptSegment] {
        if let r = result, !r.segments.isEmpty { return r.segments }
        return liveSegments
    }
}

// MARK: - Queue

/// Which list section a row is in.
public enum QueueSection: String, Sendable, CaseIterable, Hashable {
    case now, upNext, ready, finished
}

/// Why the worker went away, for `workerExited`.
public enum WorkerLoss: Sendable, Equatable {
    /// The app shut it down (quit): the current file counts as stopped.
    case requested
    /// It died: the current file fails.
    case crashed(code: Int32)
}

/// The queue and its state machine. Pure value type: the app feeds it user actions and worker
/// events and reads rows back. The GUI owns the order and hands the worker one job at a time.
public struct QueueModel: Sendable {
    public private(set) var items: [FileItem] = []
    /// Up next, in run order.
    public private(set) var upNext: [FileItem.ID] = []
    /// The file the worker is running (sent and not finished).
    public private(set) var currentID: FileItem.ID?
    public var clock: any QueueClock
    /// Seconds without events, during `load`/`align`, before a missing model counts as downloading.
    public var stallThreshold: TimeInterval = 3
    private var jobCounter = 0

    public init(clock: any QueueClock = SystemClock()) {
        self.clock = clock
    }

    public var isRunning: Bool { currentID != nil }
    public var hasWork: Bool { currentID != nil || !upNext.isEmpty }

    public subscript(id: FileItem.ID) -> FileItem? {
        items.first { $0.id == id }
    }

    public var currentItem: FileItem? { currentID.flatMap { self[$0] } }

    // MARK: Editing

    /// Adds files with a copy of `options`, skipping paths already in the list unless they
    /// only exist as finished rows. Returns the new items' IDs. `queue` puts them in Up next.
    @discardableResult
    public mutating func add(_ urls: [URL], options: TranscribeOptions = TranscribeOptions(), queue: Bool = false)
        -> [FileItem.ID] {
        var added: [FileItem.ID] = []
        for url in urls {
            let item = FileItem(url: url, options: options)
            guard !items.contains(where: { $0.path == item.path && !$0.state.isTerminal }) else { continue }
            items.append(item)
            added.append(item.id)
        }
        if queue { self.queue(added) }
        return added
    }

    public mutating func update(_ id: FileItem.ID, _ change: (inout FileItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    /// Removes files from the list (never from disk). The running file stays.
    public mutating func remove(_ ids: Set<FileItem.ID>) {
        let keep = ids.subtracting(currentID.map { [$0] } ?? [])
        items.removeAll { keep.contains($0.id) }
        upNext.removeAll { keep.contains($0) }
    }

    /// Removes Done files.
    public mutating func clearFinished() {
        items.removeAll { $0.state.isTerminal }
    }

    /// Changes one file's options; ignored for files whose options are read-only.
    public mutating func setOptions(_ ids: some Sequence<FileItem.ID>, _ change: (inout TranscribeOptions) -> Void) {
        for id in ids {
            update(id) { item in
                guard item.optionsEditable else { return }
                change(&item.options)
                // P2: no prepared formats is allowed (transcript.json only); copies need one.
                if item.options.copyFormats.isEmpty { item.options.copyFormats = [.md] }
            }
        }
    }

    /// New defaults: files still on the old defaults follow them; customised files keep theirs.
    public mutating func defaultsChanged(from old: TranscribeOptions, to new: TranscribeOptions) {
        for i in items.indices where items[i].optionsEditable && items[i].options == old {
            items[i].options = new
        }
    }

    /// "Run Again with Changes…": a Ready copy with the old options and
    /// Overwrite on, listed right after the original. The original row and its outputs stay.
    @discardableResult
    public mutating func duplicateForRerun(_ id: FileItem.ID) -> FileItem.ID? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let original = items[i]
        var options = original.displayedOptions
        options.overwrite = true
        let copy = FileItem(url: original.url, duration: original.duration, kind: original.kind, options: options)
        items.insert(copy, at: i + 1)
        return copy.id
    }

    // MARK: Scheduling

    /// Appends files to Up next (Start / Queue). Ready files queue as they are; Stopped and
    /// Failed ones start over. Running, Done and already-queued files are skipped.
    public mutating func queue(_ ids: [FileItem.ID]) {
        for id in ordered(ids) {
            guard let item = self[id], canQueue(item) else { continue }
            update(id) { $0.resetRun(to: .queued) }
            upNext.append(id)
        }
    }

    /// Puts files at the front of Up next, keeping their relative order ("Run Next").
    public mutating func runNext(_ ids: [FileItem.ID]) {
        let wanted = ordered(ids).filter { id in
            guard let item = self[id] else { return false }
            return item.state == .queued || canQueue(item)
        }
        guard !wanted.isEmpty else { return }
        for id in wanted where self[id]?.state != .queued { update(id) { $0.resetRun(to: .queued) } }
        upNext.removeAll { wanted.contains($0) }
        upNext.insert(contentsOf: wanted, at: 0)
    }

    /// Queued → Ready.
    public mutating func unqueue(_ ids: some Sequence<FileItem.ID>) {
        let set = Set(ids)
        for id in upNext where set.contains(id) { update(id) { $0.state = .ready } }
        upNext.removeAll { set.contains($0) }
    }

    public mutating func unqueueAll() { unqueue(upNext) }

    /// Moves Up next rows (List `onMove` semantics: offsets into `upNext`, destination index
    /// before removal).
    public mutating func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter { $0 < upNext.count }.map { upNext[$0] }
        guard !moving.isEmpty else { return }
        let before = upNext.prefix(min(destination, upNext.count)).filter { !moving.contains($0) }.count
        upNext.removeAll { moving.contains($0) }
        upNext.insert(contentsOf: moving, at: min(before, upNext.count))
    }

    /// A drag dropped `ids` into a section. Into Up next at `index` (nil = the end): Ready,
    /// Stopped and Failed files are queued, queued ones move. Into Ready: queued files unqueue.
    public mutating func drop(_ ids: [FileItem.ID], into section: QueueSection, at index: Int? = nil) {
        switch section {
        case .upNext:
            let eligible = ids.filter { id in
                guard let item = self[id] else { return false }
                return item.state == .queued || canQueue(item)
            }
            guard !eligible.isEmpty else { return }
            let target = index ?? upNext.count
            let before = upNext.prefix(min(target, upNext.count)).filter { !eligible.contains($0) }.count
            for id in eligible where self[id]?.state != .queued { update(id) { $0.resetRun(to: .queued) } }
            upNext.removeAll { eligible.contains($0) }
            upNext.insert(contentsOf: eligible, at: min(before, upNext.count))
        case .ready:
            unqueue(ids)
        case .now, .finished:
            break
        }
    }

    public func canQueue(_ item: FileItem) -> Bool {
        if item.checking { return false }
        return switch item.state {
        case .ready, .failed, .stopped: true
        case .queued, .running, .done: false
        }
    }

    /// The next job to send, when the worker is free: pops the head of Up next and marks it
    /// running. The caller sends the returned job.
    public mutating func startNext() -> (id: FileItem.ID, job: ServeJob)? {
        guard currentID == nil, let id = upNext.first, let item = self[id] else { return nil }
        upNext.removeFirst()
        jobCounter += 1
        let jobID = "\(id.uuidString.prefix(8).lowercased())-\(jobCounter)"
        let now = clock.now()
        update(id) { item in
            item.resetRun(to: .running(stage: .decode, progress: 0, chunk: nil, totalChunks: nil))
            item.stages[.decode] = StageSpan(start: now)
            item.jobID = jobID
            item.ranWith = item.options
            item.startedAt = now
            item.lastEventAt = now
        }
        currentID = id
        return (id, ServeJob(id: jobID, url: item.url, options: item.options))
    }

    /// Stop for the running file: marks it Stopping and returns the job id to `cancel`.
    /// For a queued file, Stop simply unqueues it (nothing was sent).
    public mutating func requestStop(_ id: FileItem.ID) -> String? {
        if id == currentID, let item = self[id], item.state.isRunning {
            let now = clock.now()
            if item.stopRequestedAt == nil { update(id) { $0.stopRequestedAt = now } }
            return item.jobID
        }
        if self[id]?.state == .queued { unqueue([id]) }
        return nil
    }

    /// Stop All: unqueues the waiting files and stops the running one (returns its job id).
    public mutating func requestStopAll() -> String? {
        unqueueAll()
        return currentID.flatMap { requestStop($0) }
    }

    // MARK: Worker events

    /// Applies one worker event to the file whose job it belongs to. Returns that file's id.
    @discardableResult
    public mutating func apply(_ event: ServeEvent) -> FileItem.ID? {
        guard let jobID = event.jobID,
              let index = items.firstIndex(where: { $0.jobID == jobID && $0.state.isRunning })
        else { return nil }
        let now = clock.now()
        var item = items[index]
        item.lastEventAt = now

        switch event {
        case .accepted:
            break
        case .download(_, let info):
            item.download = DownloadProgress.next(item.download, info, now: now)
            // The aligner downloads inside the first job that wants subtitles.
            if info.cachedModel == .aligner, item.stages[.align] == nil {
                item.closeOpenStage(at: now)
                item.stages[.align] = StageSpan(start: now)
                item.state = .running(stage: .align, progress: 0, chunk: nil, totalChunks: nil)
            }
        case .progress(_, let info):
            guard let stage = info.stage else { break }
            if stage != .align || item.download?.info.cachedModel != .aligner || info.progress > 0 {
                item.download = nil
            }
            apply(progress: info, stage: stage, to: &item, now: now)
        case .segment(_, let live):
            item.liveSegments.append(live.segment)
            if let d = item.duration, d > 0 {
                item.reachedFraction = max(item.reachedFraction, min(live.segment.end / d, 1))
            }
            if case .running(let stage, let p, _, _) = item.state, stage == .transcribe || stage == .align {
                item.state = .running(stage: .transcribe, progress: p, chunk: live.index, totalChunks: live.totalChunks)
            }
        case .log(_, _, let message):
            item.logs.append(message)
        case .fileDone(_, let result):
            item.closeOpenStage(at: now)
            item.finishedAt = now
            item.download = nil
            item.stopRequestedAt = nil
            if let d = result.duration, d > 0 { item.duration = d }
            item.reachedFraction = 1
            item.state = .done(result)
        case .fileError(_, let message):
            item.closeOpenStage(at: now)
            item.finishedAt = now
            item.download = nil
            item.stopRequestedAt = nil
            item.state = .failed(message)
        case .fileStopped(_, let at):
            item.closeOpenStage(at: now)
            item.finishedAt = now
            item.download = nil
            item.stopRequestedAt = nil
            if let d = item.duration, d > 0, at > 0 { item.reachedFraction = min(at / d, 1) }
            item.state = .stopped(at: at)
        default:
            break
        }
        items[index] = item
        if item.state.isTerminal, currentID == item.id { currentID = nil }
        return item.id
    }

    private func apply(progress info: ProgressInfo, stage: Stage, to item: inout FileItem, now: Date) {
        if stage == .transcribe {
            // Serve reports finished audio as the fraction.
            item.reachedFraction = max(item.reachedFraction, info.progress)
            if let c = info.chunk, item.chunkStarts[c] == nil {
                item.chunkStarts[c] = info.progress
                item.chunkStartedAt[c] = now
            }
        }
        // Per-chunk alignment (serve): counted, but the row stays in Transcribing.
        if stage == .align, info.chunk != nil, item.stages[.transcribe] != nil {
            if item.stages[.align] == nil { item.stages[.align] = StageSpan(start: now) }
            item.alignedChunks = max(item.alignedChunks, Int((info.progress * Double(info.totalChunks ?? 0)).rounded()))
            if info.progress >= 1, let total = info.totalChunks { item.alignedChunks = total }
            if case .running(let current, _, let chunk, let total) = item.state, current == .transcribe {
                item.state = .running(stage: .transcribe, progress: item.reachedFraction, chunk: chunk, totalChunks: total)
                return
            }
        }
        if case .running(let current, _, let chunk, let total) = item.state, current == stage {
            item.state = .running(stage: stage, progress: info.progress,
                                  chunk: info.chunk ?? chunk, totalChunks: info.totalChunks ?? total)
        } else {
            if stage == .transcribe, item.stages[.load] == nil { item.modelWasWarm = true }
            // Close every other open stage, except align which runs alongside transcription.
            for (s, span) in item.stages where span.end == nil && s != stage { item.stages[s]?.end = now }
            if item.stages[stage] == nil { item.stages[stage] = StageSpan(start: now) }
            item.state = .running(stage: stage, progress: info.progress, chunk: info.chunk, totalChunks: info.totalChunks)
        }
    }

    /// The worker went away. The running file fails after a crash and counts as stopped when
    /// the app shut the worker down. Up next is kept, so the next Start relaunches and goes on.
    public mutating func workerExited(_ loss: WorkerLoss) {
        guard let id = currentID else { return }
        let now = clock.now()
        update(id) { item in
            guard item.state.isRunning else { return }
            item.closeOpenStage(at: now)
            item.finishedAt = now
            item.download = nil
            switch loss {
            case .requested:
                item.state = .stopped(at: item.reachedFraction * (item.duration ?? 0))
            case .crashed(let code):
                item.state = .failed("The transcribe worker quit unexpectedly (exit code \(code)). "
                                     + "Retry starts it again.")
            }
            item.stopRequestedAt = nil
        }
        currentID = nil
    }

    // MARK: Reading

    public var readyIDs: [FileItem.ID] { items.filter { $0.state == .ready }.map(\.id) }

    /// Finished rows, newest first.
    public var finishedIDs: [FileItem.ID] {
        items.filter(\.state.isTerminal)
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .map(\.id)
    }

    public func section(of item: FileItem) -> QueueSection {
        switch item.state {
        case .running: .now
        case .queued: .upNext
        case .ready: .ready
        case .done, .failed, .stopped: .finished
        }
    }

    /// Rows per section, in display order.
    public func sections() -> [(section: QueueSection, ids: [FileItem.ID])] {
        [(.now, currentID.map { [$0] } ?? []), (.upNext, upNext), (.ready, readyIDs), (.finished, finishedIDs)]
    }

    /// All rows in grouped display order (for ⇧-click ranges and keyboard navigation).
    public var displayOrder: [FileItem.ID] { sections().flatMap(\.ids) }

    /// The row status, including the stall heuristic for downloads without byte progress.
    /// - Parameter isCached: whether a model is present in the HF cache.
    public func status(of item: FileItem, isCached: (CachedModel) -> Bool) -> RowStatus {
        switch item.state {
        case .ready: return .ready
        case .queued: return .queued(ordinal: (upNext.firstIndex(of: item.id) ?? 0) + 1)
        case .stopped(let at): return .stopped(at: at)
        case .failed(let e): return .failed(e)
        case .done(let r): return r.noticeCount > 0 ? .doneWithNotices(r.noticeCount) : .done
        case .running(let stage, let p, let chunk, let total):
            if item.stopRequestedAt != nil { return .stopping(percent: item.overallProgress) }
            if let d = item.download {
                let fallback: CachedModel = stage == .align ? .aligner : item.model.cacheModel
                return .preparingModel(d.info.cachedModel ?? fallback, d)
            }
            switch stage {
            case .decode:
                return .decoding
            case .load:
                return isStalled(item) && !isCached(item.model.cacheModel)
                    ? .preparingModel(item.model.cacheModel, nil) : .loadingModel
            case .transcribe:
                return .transcribing(percent: item.overallProgress, chunk: chunk, totalChunks: total)
            case .align:
                if p == 0, isStalled(item), !isCached(.aligner) { return .preparingModel(.aligner, nil) }
                return .aligning(percent: item.overallProgress)
            }
        }
    }

    /// No event for `stallThreshold` seconds.
    public func isStalled(_ item: FileItem) -> Bool {
        guard let last = item.lastEventAt else { return false }
        return clock.now().timeIntervalSince(last) >= stallThreshold
    }

    public var doneCount: Int { items.filter { $0.result != nil }.count }

    public var totalDuration: Double { items.compactMap(\.duration).reduce(0, +) }

    /// `ids` in list order, de-duplicated.
    private func ordered(_ ids: [FileItem.ID]) -> [FileItem.ID] {
        var seen = Set<FileItem.ID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

extension FileItem {
    mutating func resetRun(to state: FileState) {
        self.state = state
        jobID = nil
        stages = [:]
        startedAt = nil
        finishedAt = nil
        lastEventAt = nil
        stopRequestedAt = nil
        download = nil
        logs = []
        liveSegments = []
        chunkStarts = [:]
        chunkStartedAt = [:]
        alignedChunks = 0
        reachedFraction = 0
        modelWasWarm = false
        if !state.isRunning { ranWith = nil }
    }

    /// How the row waveform doubles as a progress bar: bars before `fraction`
    /// take `tone`, the rest the track color; `estimated` spans (fractions) draw yellow.
    public func waveformProgress(_ status: RowStatus) -> (fraction: Double, tone: WaveformTone, estimated: [ClosedRange<Double>]) {
        switch status {
        case .ready, .queued, .decoding, .loadingModel, .preparingModel: return (0, .track, [])
        case .transcribing, .stopping: return (reachedFraction, .working, [])
        case .aligning: return (1, .working, [])
        case .done, .doneWithNotices:
            let d = result?.duration ?? duration ?? 0
            let spans = d > 0 ? (result?.estimatedSpans(duration: d) ?? []).map { max(0, $0.lowerBound / d)...min(1, $0.upperBound / d) } : []
            return (1, .finished, spans)
        case .failed: return (reachedFraction, .failed, [])
        case .stopped: return (reachedFraction, .finished, [])
        }
    }

    /// Audio range (fractions 0–1) of each chunk for the chunk map. Measured where known
    /// (live segments first, then progress events); chunks not reached yet share the
    /// remaining audio evenly.
    public func chunkRanges(total: Int) -> [ClosedRange<Double>] {
        guard total > 0 else { return [] }
        var starts = [Double](repeating: .nan, count: total + 1)
        starts[0] = 0
        starts[total] = 1
        for (c, p) in chunkStarts where c >= 1 && c <= total { starts[c - 1] = p }
        if let d = duration, d > 0 {
            for (i, s) in liveSegments.enumerated() where i < total {
                starts[i] = min(s.start / d, 1)
                if i + 1 < total { starts[i + 1] = min(s.end / d, 1) }
            }
        }
        starts[0] = 0
        var lastKnown = 0
        for i in 1...total where !starts[i].isNaN {
            let gap = i - lastKnown
            if gap > 1 {
                for j in 1..<gap {
                    starts[lastKnown + j] = starts[lastKnown] + (starts[i] - starts[lastKnown]) * Double(j) / Double(gap)
                }
            }
            lastKnown = i
        }
        return (0..<total).map { i in
            let lo = min(starts[i], 1), hi = max(lo, min(starts[i + 1], 1))
            return lo...hi
        }
    }

    mutating func closeOpenStage(at now: Date) {
        for (stage, span) in stages where span.end == nil {
            stages[stage]?.end = now
        }
    }
}
