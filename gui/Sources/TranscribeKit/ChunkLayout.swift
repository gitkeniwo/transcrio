import Foundation

/// State of one chunk (or merged grid cell) in the chunk map and inspector grid.
public enum ChunkState: Sendable, Equatable { case done, current, waiting }

/// Geometry of the center pane's chunk map: one block per chunk up to
/// `blockLimit`, above that a continuous bar strip with a comb of chunk ticks.
public enum ChunkMapLayout {
    public static let blockLimit = 48
    public static let blockGap = 5.0
    public static let maxBarsPerBlock = 7
    /// Strip mode: one bar per this many points.
    public static let stripBarPitch = 3.0
    /// The current chunk's ring is never narrower than this.
    public static let minRingWidth = 12.0

    public enum Mode: Equatable, Sendable { case blocks, strip }

    /// Blocks up to 48 chunks, as long as a block stays at least `minBlockWidth` wide (a narrow
    /// center pane switches to the strip earlier).
    public static func mode(chunks: Int, width: Double) -> Mode {
        guard chunks <= blockLimit else { return .strip }
        return blocks(width: width, count: chunks).first.map { $0.width >= minBlockWidth } ?? true ? .blocks : .strip
    }

    public static let minBlockWidth = 6.0

    /// Block frames (x, width) for chunks of equal width: (panel − gaps) ÷ count.
    public static func blocks(width: Double, count: Int) -> [(x: Double, width: Double)] {
        guard count > 0 else { return [] }
        let w = max(0, (width - blockGap * Double(count - 1)) / Double(count))
        return (0..<count).map { (Double($0) * (w + blockGap), w) }
    }

    /// Bars inside a block: about one per 5 pt, at most 7.
    public static func barsPerBlock(width: Double) -> Int {
        max(1, min(maxBarsPerBlock, Int((width - 6) / 5)))
    }

    public static func stripBars(width: Double) -> Int { max(1, Int(width / stripBarPitch)) }

    /// The current chunk's ring in strip mode: its time range, widened around its centre to
    /// `minRingWidth` and kept inside the strip.
    public static func ring(range: ClosedRange<Double>, width: Double) -> (x: Double, width: Double) {
        var x = range.lowerBound * width, w = (range.upperBound - range.lowerBound) * width
        if w < minRingWidth {
            x -= (minRingWidth - w) / 2
            w = minRingWidth
        }
        x = max(0, min(x, width - w))
        return (x, w)
    }
}

/// The inspector chunk grid: cells shrink as the count grows and wrap with
/// 2 pt gaps; above 174 chunks each cell covers ⌈chunks ÷ 174⌉ chunks.
public struct ChunkGridLayout: Equatable, Sendable {
    public var chunks: Int
    public var cell: Double
    public var numbered: Bool
    public var chunksPerCell: Int
    public var cells: Int
    public var perRow: Int

    public static let gap = 2.0
    public static let mergeAbove = 174

    public var rows: Int { perRow > 0 ? (cells + perRow - 1) / perRow : 0 }
    public var height: Double { rows > 0 ? Double(rows) * cell + Double(rows - 1) * Self.gap : 0 }

    public init(chunks: Int, width: Double) {
        self.chunks = max(chunks, 0)
        let n = self.chunks
        let maxPerRow: Int
        switch n {
        case ...16: (cell, numbered, maxPerRow) = (34, true, 8)
        case 17...60: (cell, numbered, maxPerRow) = (16, false, .max)
        default: (cell, numbered, maxPerRow) = (10, false, .max)
        }
        chunksPerCell = n > Self.mergeAbove ? Int((Double(n) / Double(Self.mergeAbove)).rounded(.up)) : 1
        cells = (n + chunksPerCell - 1) / chunksPerCell
        perRow = max(1, min(maxPerRow, Int((width + Self.gap) / (cell + Self.gap))))
    }

    /// 1-based chunks covered by a 0-based cell.
    public func chunkRange(cell i: Int) -> ClosedRange<Int> {
        let lo = i * chunksPerCell + 1
        return lo...min(chunks, lo + chunksPerCell - 1)
    }

    public func origin(cell i: Int) -> (x: Double, y: Double) {
        (Double(i % perRow) * (cell + Self.gap), Double(i / perRow) * (cell + Self.gap))
    }

    /// The cell under a point, if any.
    public func cell(at x: Double, _ y: Double) -> Int? {
        guard x >= 0, y >= 0 else { return nil }
        let col = Int(x / (cell + Self.gap)), row = Int(y / (cell + Self.gap))
        guard col < perRow, x - Double(col) * (cell + Self.gap) <= cell, y - Double(row) * (cell + Self.gap) <= cell else { return nil }
        let i = row * perRow + col
        return i < cells ? i : nil
    }

    /// A cell's state given the 1-based current chunk (`nil` before transcription; past the
    /// end once every chunk is done).
    public func state(cell i: Int, current: Int?) -> ChunkState {
        let r = chunkRange(cell: i)
        guard let current else { return .waiting }
        if r.contains(current) { return .current }
        return r.upperBound < current ? .done : .waiting
    }
}
