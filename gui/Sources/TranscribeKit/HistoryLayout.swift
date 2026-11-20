import Foundation

// Pure pieces of the sidebar's History, kept here so they can be tested.

/// The History row's date: `Just now`, `14:02` today, `Oct 18` this year,
/// `2025-10-18` otherwise.
public enum HistoryDate {
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 120, now >= date.addingTimeInterval(-60) { return "Just now" }
        if calendar.isDate(date, inSameDayAs: now) {
            let d = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", d.hour ?? 0, d.minute ?? 0)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day())
        }
        var c = calendar
        c.locale = Locale(identifier: "en_US_POSIX")
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// `Oct 18` (or `2025-10-18` in another year), for notices and the Again sheet.
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let s = short(date, now: now, calendar: calendar, locale: locale)
        if s == "Just now" || calendar.isDate(date, inSameDayAs: now) { return "today" }
        return s
    }

    /// `Oct 18, 14:02`.
    public static func long(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let d = calendar.dateComponents([.hour, .minute], from: date)
        let day = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
            : date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day().year())
        return String(format: "%@, %02d:%02d", day, d.hour ?? 0, d.minute ?? 0)
    }
}

/// How the sidebar's height is shared between the queue and History.
public struct SidebarSplit: Equatable, Sendable {
    /// History header incl. its separator.
    public static let header: Double = 35
    public static let historyRow: Double = 54
    /// A row in Text scope, with the matching snippet as a third line.
    public static let historySnippetRow: Double = 72
    /// One section header + 4 queue rows.
    public static let queueMin: Double = 258
    /// History header + 3 rows.
    public static let historyMin: Double = 190
    /// The dashed "Drop files" row of an empty queue.
    public static let dropRow: Double = 40
    public static let defaultRatio: Double = 0.6

    public var queue: Double
    public var history: Double
    /// History shows its header only (the user collapsed it, or the window is too short).
    public var historyCollapsed: Bool
    /// Both lists are longer than their share: the divider can be dragged.
    public var resizable: Bool

    public init(queue: Double, history: Double, historyCollapsed: Bool, resizable: Bool) {
        self.queue = queue
        self.history = history
        self.historyCollapsed = historyCollapsed
        self.resizable = resizable
    }

    /// - Parameters:
    ///   - height: the space between the search field and the footer.
    ///   - queueContent: the queue list's natural height (0 = empty queue).
    ///   - historyContent: History's natural height, header included.
    ///   - ratio: the queue's share when both lists are long.
    public static func compute(height: Double, queueContent: Double, historyContent: Double,
                               collapsed: Bool, ratio: Double = defaultRatio) -> SidebarSplit {
        let h = max(height, 0)
        let headerOnly = SidebarSplit(queue: max(h - header, 0), history: header, historyCollapsed: true, resizable: false)
        if collapsed { return headerOnly }
        if queueContent <= 0 {
            return SidebarSplit(queue: dropRow, history: max(h - dropRow, header), historyCollapsed: false, resizable: false)
        }
        if queueContent + historyContent <= h {
            return SidebarSplit(queue: queueContent, history: h - queueContent, historyCollapsed: false, resizable: false)
        }
        let r = min(max(ratio, 0.05), 0.95)
        var queue = (h * r).rounded()
        if historyContent < h - queue {
            // History is short: the queue takes the rest.
            return SidebarSplit(queue: h - historyContent, history: historyContent, historyCollapsed: false, resizable: false)
        }
        if queueContent < queue {
            return SidebarSplit(queue: queueContent, history: h - queueContent, historyCollapsed: false, resizable: false)
        }
        // Both long.
        let qMin = min(queueMin, queueContent)
        let hMin = min(historyMin, historyContent)
        if h < qMin + hMin {
            // Too short: the queue keeps its 4 rows, History shrinks to header + 1 row, then collapses.
            let rest = h - qMin
            if rest < header + historyRow { return headerOnly }
            return SidebarSplit(queue: qMin, history: rest, historyCollapsed: false, resizable: false)
        }
        queue = min(max(queue, qMin), h - hMin)
        return SidebarSplit(queue: queue, history: h - queue, historyCollapsed: false, resizable: true)
    }

    /// The drop notice sits in History's flow: History keeps room for its header, the notice
    /// and one row (the ringed one), taken from the queue. A collapsed History grows too, as the
    /// notice opens it.
    public func reserving(_ notice: Double, height: Double) -> SidebarSplit {
        guard notice > 0 else { return self }
        let h = max(height, 0)
        let full = SidebarSplit.header + notice + SidebarSplit.historyRow
        let want = min(full, h)
        guard history < want || historyCollapsed && h >= full else { return self }
        return SidebarSplit(queue: max(h - max(want, history), 0), history: max(want, history),
                            historyCollapsed: h < full, resizable: false)
    }

    /// The ratio a divider drag to `queueHeight` means, kept inside both minimums.
    public static func ratio(forQueueHeight queueHeight: Double, height: Double) -> Double {
        guard height > 0 else { return defaultRatio }
        let lo = min(queueMin, height) / height
        let hi = max(height - historyMin, 0) / height
        return min(max(queueHeight / height, lo), max(hi, lo))
    }
}

/// What a drop of files means once their fingerprints are known.
public struct DropPlan: Equatable, Sendable {
    public struct Known: Equatable, Sendable {
        public var url: URL
        public var entry: LibraryEntry
    }

    /// Not in the library and not in the queue: go to Ready.
    public var new: [URL] = []
    /// In the library: not added; History rings them.
    public var known: [Known] = []
    /// Already a live queue row: that row is selected.
    public var queued: [FileItem.ID] = []

    public init(new: [URL] = [], known: [Known] = [], queued: [FileItem.ID] = []) {
        self.new = new
        self.known = known
        self.queued = queued
    }

    /// Classifies dropped files. `fingerprints` is nil for a file that couldn't be read (it is
    /// treated as new; the worker reports the error). Duplicates within the drop count once.
    public static func make(urls: [URL], fingerprints: [URL: SourceFingerprint], queue: [FileItem],
                            library: [LibraryEntry]) -> DropPlan {
        var plan = DropPlan()
        var seen: Set<String> = []
        for url in urls {
            let path = url.standardizedFileURL.path
            let fp = fingerprints[url]
            guard seen.insert(fp?.description ?? path).inserted else { continue }
            let live = queue.filter { !$0.state.isTerminal }
            if let row = live.first(where: { $0.url.standardizedFileURL.path == path || (fp != nil && $0.fingerprint == fp) }) {
                if !plan.queued.contains(row.id) { plan.queued.append(row.id) }
            } else if let fp, let entry = library.first(where: { $0.fingerprint == fp }) {
                if !plan.known.contains(where: { $0.entry.id == entry.id }) { plan.known.append(Known(url: url, entry: entry)) }
            } else {
                plan.new.append(url)
            }
        }
        return plan
    }

    /// The drop notice, or nil when every file was simply added.
    public func notice(now: Date = Date()) -> DropNotice? {
        let k = known.count, n = new.count
        if k == 0 {
            guard !queued.isEmpty else { return nil }
            let message = n > 0 ? "\(n) added to Ready. The rest are selected in the queue."
                : queued.count == 1 ? "It is selected in the queue." : "They are selected in the queue."
            return DropNotice(title: "Already in the queue", message: message, again: [])
        }
        let ids = known.map(\.entry.id)
        let title: String
        let message: String
        if n == 0 {
            if k == 1 {
                title = "Already transcribed · \(HistoryDate.day(known[0].entry.updated, now: now))"
                message = "\(known[0].url.lastPathComponent) is in History. Nothing was added to the queue."
            } else {
                title = "\(k) files already transcribed"
                message = (k == 2 ? "Both are" : "All \(k) are") + " selected in History. Nothing was added to the queue."
            }
        } else {
            title = "\(n) added to Ready · \(k) already transcribed"
            message = k == 1 ? "\(known[0].url.lastPathComponent) is marked in History."
                : "The \(k) known files are marked in History."
        }
        return DropNotice(title: title, message: message, again: ids)
    }
}

/// The floating card over History after a drop.
public struct DropNotice: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String
    /// Entries Transcribe Again… would open; empty = no button.
    public var again: [String]

    public init(title: String, message: String, again: [String]) {
        self.title = title
        self.message = message
        self.again = again
    }

    public var againLabel: String { again.count > 1 ? "Transcribe \(again.count) Again…" : "Transcribe Again…" }

    public static func == (a: DropNotice, b: DropNotice) -> Bool {
        a.title == b.title && a.message == b.message && a.again == b.again
    }
}

extension LibraryEntry {
    /// One search field filters both lists: History matches title and source file name.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q) || sourceName.localizedCaseInsensitiveContains(q)
    }

    /// `1.7B`, `0.6B` from the catalog id or repo.
    public var modelLabel: String {
        if let m = ModelChoice(rawValue: options.model) { return m.rawValue.uppercased() }
        if let repo = model, let tail = repo.split(separator: "-").last { return String(tail) }
        return options.model.uppercased()
    }
}
