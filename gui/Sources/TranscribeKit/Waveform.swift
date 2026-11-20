import Foundation

/// Loudness of a file over time, for every waveform drawing in the app.
///
/// `MediaInfo` stores fine linear RMS bins. Drawings pool them to however many bars they need
/// (RMS of RMS, so a bar is the loudness of its whole slice, not its loudest click), divide by the
/// 95th percentile of the file so one loud moment doesn't flatten the rest, and map that to a
/// log (dB) scale so quiet speech still shows.
public struct Waveform: Sendable, Equatable {
    /// Linear RMS per fine bin, 0…1 of full scale.
    public let rms: [Float]
    /// The 95th percentile of `rms`: drawn at full height.
    public let reference: Float
    /// Levels this far below the reference draw at zero height.
    public static let dynamicRange: Float = 30

    public init(rms: [Float]) {
        self.rms = rms
        self.reference = Self.percentile(rms, 0.95)
    }

    public var isEmpty: Bool { rms.isEmpty }

    /// `count` bar heights in 0…1 for the time range `from…to` (fractions of the file).
    public func levels(count: Int, from: Double = 0, to: Double = 1) -> [Float] {
        Self.pool(rms, count: count, from: from, to: to).map { Self.level($0, reference: reference) }
    }

    /// One bar height: dB below `reference`, mapped so the reference is 1 and `dynamicRange` below it is 0.
    public static func level(_ value: Float, reference: Float, range: Float = dynamicRange) -> Float {
        guard value > 0, reference > 0 else { return 0 }
        let db = 20 * log10(value / reference)
        return min(1, max(0, (db + range) / range))
    }

    /// RMS-pools `values` over `from…to` into `count` slices. A slice narrower than a bin takes
    /// the bin it falls in, so zooming in repeats bins instead of leaving gaps.
    public static func pool(_ values: [Float], count: Int, from: Double = 0, to: Double = 1) -> [Float] {
        guard count > 0 else { return [] }
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        let n = Double(values.count)
        let a = max(0, min(1, from)), b = max(a, min(1, to))
        return (0..<count).map { i in
            let lo = (a + (b - a) * Double(i) / Double(count)) * n
            let hi = (a + (b - a) * Double(i + 1) / Double(count)) * n
            var start = min(Int(lo), values.count - 1)
            var end = min(max(Int(hi.rounded(.up)), start + 1), values.count)
            if end <= start { start = max(0, end - 1); end = start + 1 }
            var sum: Float = 0
            for j in start..<end { sum += values[j] * values[j] }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    /// The `p` quantile (0…1) by nearest rank; 0 for an empty array.
    public static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }
}
