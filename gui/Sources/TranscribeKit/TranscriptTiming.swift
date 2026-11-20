import Foundation

/// One timed piece of the transcript: a subtitle cue, a timestamped paragraph, or (from P2) a
/// `file_done.segments` entry.
public struct TimedSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Where the preview gets its times: `file_done.segments` from the worker, or (fallback, for
/// results without segments) times parsed back from the output files.
public protocol TranscriptTimingSource: Sendable {
    /// Segments in time order; empty when the source has no times.
    func segments() -> [TimedSegment]
}

/// `file_done.segments`: one paragraph per chunk with exact audio times.
public struct ResultSegmentsTimingSource: TranscriptTimingSource {
    public var result: [TranscriptSegment]

    public init(_ segments: [TranscriptSegment]) { result = segments }

    public func segments() -> [TimedSegment] {
        result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
            .map { TimedSegment(start: $0.start, end: max($0.start, $0.end), text: $0.text) }
    }
}

/// The preferred source for a finished file: its segments when the worker sent them, else the
/// output files.
public func timingSource(for result: FileResult) -> any TranscriptTimingSource {
    if !result.segments.isEmpty { return ResultSegmentsTimingSource(result.segments) }
    return OutputFilesTimingSource(outputs: result.outputs, duration: result.duration)
}

/// Times read from the files the CLI wrote: subtitles first (cue-level), then a timestamped
/// Markdown or text file (paragraph-level).
public struct OutputFilesTimingSource: TranscriptTimingSource {
    public var outputs: [String: String]
    public var duration: Double?

    public init(outputs: [String: String], duration: Double?) {
        self.outputs = outputs
        self.duration = duration
    }

    static let preference: [OutputFormat] = [.srt, .vtt, .md, .txt]

    public func segments() -> [TimedSegment] {
        for format in Self.preference {
            guard let path = outputs[format.rawValue],
                  let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let segs = Self.segments(TranscriptParser.parse(raw, format: format, duration: duration))
            if !segs.isEmpty { return segs }
        }
        return []
    }

    /// The timed paragraphs of a parsed document; an open end runs to the next start.
    public static func segments(_ doc: TranscriptDocument) -> [TimedSegment] {
        let timed = doc.paragraphs.filter { $0.start != nil }
        return timed.enumerated().map { i, p in
            let start = p.start!
            let next = i + 1 < timed.count ? timed[i + 1].start! : start
            return TimedSegment(start: start, end: max(start, p.end ?? next), text: p.text)
        }
    }
}

/// Maps timed segments onto the paragraphs being shown, which may come from a different file
/// (an untimed Markdown file timed by its SRT). Both sides are reduced to letters and digits,
/// and each paragraph takes the times of the segments under its share of that text.
public enum ParagraphTiming {
    public static func assign(paragraphs: [String], segments: [TimedSegment]) -> [ClosedRange<Double>?] {
        guard !paragraphs.isEmpty else { return [] }
        guard !segments.isEmpty else { return paragraphs.map { _ in nil } }
        let pLens = paragraphs.map { normalizedLength($0) }
        let sLens = segments.map { max(1, normalizedLength($0.text)) }
        let pTotal = max(1, pLens.reduce(0, +)), sTotal = sLens.reduce(0, +)
        // Cumulative segment offsets in segment-text space.
        var sEnds: [Double] = []
        var acc = 0.0
        for l in sLens { acc += Double(l); sEnds.append(acc) }
        let scale = Double(sTotal) / Double(pTotal)

        /// Time at a text offset, interpolated inside the segment that covers it. At a boundary
        /// a start belongs to the next segment and an end to the previous one.
        func time(at offset: Double, start: Bool) -> Double {
            let i = sEnds.firstIndex { start ? $0 > offset : $0 >= offset } ?? (segments.count - 1)
            let lo = i == 0 ? 0 : sEnds[i - 1]
            let f = sEnds[i] > lo ? min(1, max(0, (offset - lo) / (sEnds[i] - lo))) : 0
            return segments[i].start + f * (segments[i].end - segments[i].start)
        }
        /// Snap to a segment boundary when one is within a few characters, so a paragraph
        /// that equals a run of cues gets the cues' exact times.
        func snapped(_ offset: Double) -> Double {
            guard let near = sEnds.min(by: { abs($0 - offset) < abs($1 - offset) }), abs(near - offset) <= 3 else { return offset }
            return near
        }

        var out: [ClosedRange<Double>?] = []
        var start = 0.0
        for l in pLens {
            let end = start + Double(l)
            if l == 0 {
                out.append(nil)
            } else {
                let a = snapped(start * scale), b = snapped(end * scale)
                let t0 = time(at: a, start: true), t1 = time(at: b, start: false)
                out.append(t0...max(t0, t1))
            }
            start = end
        }
        return out
    }

    static func normalizedLength(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (CharacterSet.alphanumerics.contains($1) ? 1 : 0) }
    }
}

/// Time labels under the overview: 4 to 6, at round steps, with the first and last pinned to
/// the ends of the file.
public enum OverviewTicks {
    static let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 10800]

    public static func labels(duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        for step in steps {
            let inner = interior(duration, step)
            if inner.count + 2 <= 6 { return [0] + inner + [duration] }
        }
        return [0, duration]
    }

    /// Multiples of `step` inside the file, dropping one that would crowd the end label.
    static func interior(_ duration: Double, _ step: Double) -> [Double] {
        var out: [Double] = []
        var t = step
        while t < duration - step / 2 {
            out.append(t)
            t += step
        }
        return out
    }
}
