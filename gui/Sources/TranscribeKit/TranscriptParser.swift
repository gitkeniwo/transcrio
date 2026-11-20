import Foundation

/// A paragraph (md/txt) or cue (srt/vtt) read back from an output file the CLI wrote.
public struct TranscriptParagraph: Sendable, Equatable, Identifiable {
    public var id: Int
    public var start: Double?
    public var end: Double?
    public var text: String

    public init(id: Int, start: Double?, end: Double? = nil, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptDocument: Sendable, Equatable {
    public var title: String?
    public var paragraphs: [TranscriptParagraph]

    /// False when the file was written without `-t`: show paragraphs without a gutter.
    public var hasTimestamps: Bool { paragraphs.contains { $0.start != nil } }

    /// The paragraph playing at `time`.
    public func paragraph(at time: Double) -> TranscriptParagraph? {
        paragraphs.last { ($0.start ?? .infinity) <= time }
    }

    /// Plain text for Copy All.
    public var plainText: String { paragraphs.map(\.text).joined(separator: "\n\n") }
}

/// Parses the md / txt / srt / vtt files written by `transcribe` (see `exporters.py`).
public enum TranscriptParser {
    public static func parse(_ text: String, format: OutputFormat, duration: Double? = nil) -> TranscriptDocument {
        switch format {
        case .md: markdown(text, duration: duration)
        case .txt: plain(text, duration: duration)
        case .srt, .vtt: cues(text)
        case .json: TranscriptDocument(title: nil, paragraphs: [])
        }
    }

    /// `# title`, a metadata list, `---`, then paragraphs, optionally `**[hh:mm:ss]** text`.
    public static func markdown(_ text: String, duration: Double? = nil) -> TranscriptDocument {
        var title: String?
        var body = text
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") { title = String(first.dropFirst(2)) }
        if let rule = lines.firstIndex(of: "---") {
            body = lines[(rule + 1)...].joined(separator: "\n")
        } else if title != nil {
            body = lines.dropFirst().joined(separator: "\n")
        }
        let paras = blocks(body).enumerated().map { i, block -> TranscriptParagraph in
            if let (t, rest) = leadingStamp(block, open: "**[", close: "]**") {
                return TranscriptParagraph(id: i, start: t, text: rest)
            }
            return TranscriptParagraph(id: i, start: nil, text: block)
        }
        return TranscriptDocument(title: title, paragraphs: withEnds(paras, duration: duration))
    }

    /// Paragraphs separated by blank lines, optionally `[hh:mm:ss] text`.
    public static func plain(_ text: String, duration: Double? = nil) -> TranscriptDocument {
        let paras = blocks(text).enumerated().map { i, block -> TranscriptParagraph in
            if let (t, rest) = leadingStamp(block, open: "[", close: "]") {
                return TranscriptParagraph(id: i, start: t, text: rest)
            }
            return TranscriptParagraph(id: i, start: nil, text: block)
        }
        return TranscriptDocument(title: nil, paragraphs: withEnds(paras, duration: duration))
    }

    /// SRT or WebVTT cues.
    public static func cues(_ text: String) -> TranscriptDocument {
        var paras: [TranscriptParagraph] = []
        for block in blocks(text) {
            var lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            lines = Array(lines[(timeIndex + 1)...])
            paras.append(TranscriptParagraph(id: paras.count, start: start, end: end, text: lines.joined(separator: "\n")))
        }
        return TranscriptDocument(title: nil, paragraphs: paras)
    }

    /// `00:30:40`, `00:30:40,120`, `00:30:40.120` or `30:40.120` → seconds.
    public static func seconds(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func blocks(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { block -> String? in
                guard !block.isEmpty else { return nil }
                // The WebVTT header may share a block with the first cue.
                guard block.hasPrefix("WEBVTT") else { return block }
                guard block.contains("-->"), let nl = block.firstIndex(of: "\n") else { return nil }
                return String(block[block.index(after: nl)...])
            }
    }

    private static func leadingStamp(_ block: String, open: String, close: String) -> (Double, String)? {
        guard block.hasPrefix(open), let closeRange = block.range(of: close) else { return nil }
        let stamp = block[block.index(block.startIndex, offsetBy: open.count)..<closeRange.lowerBound]
        guard let t = seconds(String(stamp)) else { return nil }
        return (t, block[closeRange.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    private static func withEnds(_ paras: [TranscriptParagraph], duration: Double?) -> [TranscriptParagraph] {
        var out = paras
        for i in out.indices where out[i].start != nil {
            out[i].end = out[(i + 1)...].first { $0.start != nil }?.start ?? duration
        }
        return out
    }
}
