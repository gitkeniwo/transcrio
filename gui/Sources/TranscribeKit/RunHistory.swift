import Foundation

/// One finished file, for "Speed on this Mac" and time estimates.
public struct RunRecord: Codable, Sendable, Equatable {
    /// Catalog id: `1.7b`, `0.6b`.
    public var model: String
    /// Audio seconds.
    public var duration: Double
    /// Wall seconds the job took.
    public var elapsed: Double
    public var date: Date

    public init(model: String, duration: Double, elapsed: Double, date: Date) {
        self.model = model
        self.duration = duration
        self.elapsed = elapsed
        self.date = date
    }

    /// × real time.
    public var speed: Double { elapsed > 0 ? duration / elapsed : 0 }
}

/// `~/Library/Application Support/Transcribe/history.json`: the last 50 runs per model.
public struct RunHistory: Codable, Sendable, Equatable {
    public static let perModel = 50
    /// Runs used for the average speed.
    public static let window = 10

    public var runs: [String: [RunRecord]] = [:]

    public init(runs: [String: [RunRecord]] = [:]) { self.runs = runs }

    public mutating func record(_ r: RunRecord) {
        // Tiny files are dominated by fixed costs and would skew the speed.
        guard r.duration >= 5, r.elapsed > 0, r.duration.isFinite, r.elapsed.isFinite else { return }
        var list = runs[r.model, default: []]
        list.append(r)
        if list.count > Self.perModel { list.removeFirst(list.count - Self.perModel) }
        runs[r.model] = list
    }

    /// Audio seconds per wall second over the recent runs (total audio ÷ total time, so long
    /// files weigh more). nil with no history.
    public func speed(model: String) -> Double? {
        let recent = (runs[model] ?? []).suffix(Self.window)
        let audio = recent.reduce(0) { $0 + $1.duration }, time = recent.reduce(0) { $0 + $1.elapsed }
        return time > 0 && audio > 0 ? audio / time : nil
    }

    /// The last `n` runs' speeds, oldest first, for the Models card's mini chart.
    public func recentSpeeds(model: String, count n: Int = 6) -> [Double] {
        (runs[model] ?? []).suffix(n).map(\.speed)
    }

    /// Estimated wall time for `duration` seconds of audio on `model`.
    public func estimate(duration: Double, model: String) -> TimeInterval? {
        speed(model: model).map { duration / $0 }
    }

    // MARK: Storage

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Transcribe/history.json")
    }

    public static func load(from url: URL = defaultURL) -> RunHistory {
        guard let data = try? Data(contentsOf: url) else { return RunHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RunHistory.self, from: data)) ?? RunHistory()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// "Left ≈ x min": remaining audio of Now + Up next ÷ measured speed. Ready
/// files don't count.
public enum QueueEstimate {
    /// Seconds left, or nil when there is nothing to measure with.
    public static func remaining(_ queue: QueueModel, history: RunHistory, now: Date) -> TimeInterval? {
        var total: TimeInterval = 0
        var known = false
        let live = liveSpeed(queue, now: now)
        if let item = queue.currentItem {
            let left = (item.duration ?? 0) * (1 - min(max(item.reachedFraction, 0), 1))
            if let s = live ?? history.speed(model: item.model.rawValue) {
                total += left / s
                known = true
            }
        }
        for id in queue.upNext {
            guard let item = queue[id], let d = item.duration else { continue }
            let model = item.options.model.rawValue
            // The running file's live speed only stands in for its own model.
            let speed = history.speed(model: model) ?? (queue.currentItem?.model.rawValue == model ? live : nil)
            if let s = speed {
                total += d / s
                known = true
            }
        }
        return known ? total : nil
    }

    /// The running file's own speed: audio transcribed ÷ time in the transcribe stage, once
    /// at least a tenth of it is done.
    public static func liveSpeed(_ queue: QueueModel, now: Date) -> Double? {
        guard let item = queue.currentItem, let d = item.duration, d > 0, item.reachedFraction >= 0.1,
              let span = item.stages[.transcribe]
        else { return nil }
        let t = span.duration(now: now)
        return t > 1 ? item.reachedFraction * d / t : nil
    }

    /// "≈ 3 min" for the Up next header: just the queued files.
    public static func upNext(_ queue: QueueModel, history: RunHistory) -> TimeInterval? {
        var total: TimeInterval = 0, known = false
        for id in queue.upNext {
            guard let item = queue[id], let d = item.duration,
                  let s = history.speed(model: item.options.model.rawValue) else { continue }
            total += d / s
            known = true
        }
        return known ? total : nil
    }

    /// `≈ 3 min`, `< 1 min`, `≈ 1 h 20 min`.
    public static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "< 1 min" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "≈ \(m) min" }
        return "≈ \(m / 60) h \(m % 60) min"
    }
}
