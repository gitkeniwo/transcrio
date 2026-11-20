import Foundation

// Full-text search across History entries: the sidebar's one
// search field gets a Titles / Text scope; in Text scope every entry's transcript text is matched
// and the row shows the best snippet.
//
// Matching is plain substring search, insensitive to case, diacritics and width (so Chinese and
// Japanese, which have no spaces, work as typed). Each entry's text is kept in memory twice: as a
// single line for snippets, and folded to UTF-8 bytes, which `memmem` scans fast enough for
// hundreds of hour-long transcripts on every keystroke.

/// The search field's scope. The queue always matches file names.
public enum SearchScope: String, Sendable, CaseIterable, Identifiable {
    case titles, text
    public var id: String { rawValue }
    public var label: String { self == .titles ? "Titles" : "Text" }
}

/// The second subtitle line of a History row in Text scope: the text around the first match.
public struct SearchSnippet: Equatable, Sendable {
    /// Text before the match, with a leading "…" when cut.
    public var before: String
    public var match: String
    /// Text after the match, with a trailing "…" when cut.
    public var after: String
    /// How many times the query occurs in the transcript (capped at `TranscriptSearchIndex.countCap`).
    public var count: Int

    public init(before: String, match: String, after: String, count: Int = 1) {
        self.before = before
        self.match = match
        self.after = after
        self.count = count
    }

    public var text: String { before + match + after }
}

/// The searchable text of every entry, loaded lazily and kept current by stamp.
public struct TranscriptSearchIndex: Sendable {
    public static let countCap = 999
    /// Characters kept before the match in a snippet (wide ones count twice); short, so the match stays visible in a
    /// one-line subtitle that truncates at its end.
    public static let leadContext = 14
    public static let trailContext = 90

    struct Doc: Sendable {
        var stamp: String
        /// The transcript as one line (whitespace collapsed).
        var text: String
        /// `text` folded, as UTF-8.
        var folded: [UInt8]
    }

    private var docs: [String: Doc] = [:]

    public init() {}

    public var count: Int { docs.count }
    public func contains(_ id: String) -> Bool { docs[id] != nil }

    /// The ids whose stamp differs from the indexed one (or that aren't indexed yet).
    public func stale(_ stamps: [String: String]) -> [String] {
        stamps.filter { docs[$0.key]?.stamp != $0.value }.map(\.key).sorted()
    }

    public mutating func set(_ id: String, stamp: String, text: String) {
        let line = Self.oneLine(text)
        docs[id] = Doc(stamp: stamp, text: line, folded: Array(Self.fold(line).utf8))
    }

    /// Drops entries that left the library.
    public mutating func prune(keeping ids: Set<String>) {
        for id in docs.keys where !ids.contains(id) { docs[id] = nil }
    }

    /// Indexed entries whose text contains `query`, each with its snippet. An empty query matches nothing.
    public func search(_ query: String) -> [String: SearchSnippet] {
        let needle = Array(Self.fold(Self.oneLine(query)).utf8)
        guard !needle.isEmpty else { return [:] }
        var out: [String: SearchSnippet] = [:]
        for (id, doc) in docs {
            let n = Self.occurrences(of: needle, in: doc.folded, cap: Self.countCap)
            guard n > 0 else { continue }
            var snippet = Self.snippet(in: doc.text, query: query) ?? SearchSnippet(before: "", match: "", after: String(doc.text.prefix(Self.trailContext)))
            snippet.count = n
            out[id] = snippet
        }
        return out
    }

    // MARK: Text

    static let compare: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Case-, diacritic- and width-folded, whitespace collapsed.
    public static func fold(_ s: String) -> String {
        oneLine(s.folding(options: compare, locale: nil))
    }

    /// Whitespace runs (newlines included) become one space; ends trimmed.
    public static func oneLine(_ s: String) -> String {
        // A regex is ~5× faster than splitting on Characters for hour-long transcripts.
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The text to index from a transcript.json: its segments (what the preview shows), else `text`.
    public static func searchableText(transcriptJSON data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let segments = obj["segments"] as? [[String: Any]] {
            let parts = segments.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return obj["text"] as? String
    }

    /// The first match of `query` in `text` with up to `leadContext` (narrow) characters before it
    /// (cut at a word start when the text has spaces) and the rest of the line after.
    public static func snippet(in text: String, query: String) -> SearchSnippet? {
        let line = oneLine(text)
        let q = oneLine(query)
        guard !q.isEmpty, let r = line.range(of: q, options: compare) else { return nil }
        // Wide (CJK) characters count twice, so the match lands at about the same place.
        var start = r.lowerBound
        var width = 0
        while start > line.startIndex {
            let prev = line.index(before: start)
            let w = (line[prev].unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 2 : 1
            guard width + w <= leadContext else { break }
            width += w
            start = prev
        }
        if start > line.startIndex, Self.isSpaced(line[line.index(before: start)]), Self.isSpaced(line[start]),
           let space = line[start..<r.lowerBound].firstIndex(of: " ") {
            // The cut fell inside a word of a spaced script: begin at the next word instead.
            start = line.index(after: space)
        }
        let end = line.index(r.upperBound, offsetBy: trailContext, limitedBy: line.endIndex) ?? line.endIndex
        let lead = start > line.startIndex ? "…" + line[start..<r.lowerBound].drop(while: \.isWhitespace) : String(line[start..<r.lowerBound])
        return SearchSnippet(before: lead,
                             match: String(line[r]),
                             after: line[r.upperBound..<end] + (end < line.endIndex ? "…" : ""))
    }

    /// A letter or digit of a script that separates words with spaces (CJK doesn't).
    static func isSpaced(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && (c.unicodeScalars.first?.value ?? 0) < 0x2E80
    }

    /// Every match of `query` in `text` (the preview's highlights). Whitespace in the query
    /// matches any whitespace run, so a phrase found across a paragraph break is found here too.
    public static func matches(of query: String, in text: String) -> [NSRange] {
        let q = oneLine(query)
        guard !q.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: q, options: compare, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            out.append(r)
            from = r.location + r.length
        }
        if out.isEmpty, q.contains(" ") {
            // Diacritic folding isn't available to regexes; case is.
            let pattern = q.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            }
        }
        return out
    }

    static func occurrences(of needle: [UInt8], in hay: [UInt8], cap: Int) -> Int {
        guard !needle.isEmpty, hay.count >= needle.count else { return 0 }
        return hay.withUnsafeBytes { (h: UnsafeRawBufferPointer) -> Int in
            needle.withUnsafeBytes { (n: UnsafeRawBufferPointer) -> Int in
                guard let hb = h.baseAddress, let nb = n.baseAddress else { return 0 }
                var count = 0
                var offset = 0
                while count < cap, offset <= h.count - n.count,
                      let found = memmem(hb + offset, h.count - offset, nb, n.count) {
                    count += 1
                    offset = hb.distance(to: UnsafeRawPointer(found)) + n.count
                }
                return count
            }
        }
    }
}

extension LibraryStore {
    /// Changes whenever transcript.json is rewritten (Transcribe Again, Align Subtitles).
    public func searchStamp(_ entry: LibraryEntry) -> String {
        let values = try? transcriptURL(entry).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(entry.updated.timeIntervalSince1970)-\(modified)-\(values?.fileSize ?? -1)"
    }
}
