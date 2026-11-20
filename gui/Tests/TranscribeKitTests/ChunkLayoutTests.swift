import Testing
@testable import TranscribeKit

@Suite struct ChunkLayoutTests {
    @Test func gridTiersAt348() {
        let a = ChunkGridLayout(chunks: 8, width: 348)
        #expect(a.cell == 34 && a.numbered && a.perRow == 8 && a.rows == 1)
        let b = ChunkGridLayout(chunks: 16, width: 348)
        #expect(b.cell == 34 && b.rows == 2)
        let c = ChunkGridLayout(chunks: 40, width: 348)
        #expect(c.cell == 16 && !c.numbered && c.perRow == 19 && c.rows == 3)
        let d = ChunkGridLayout(chunks: 60, width: 348)
        #expect(d.cell == 16 && d.rows == 4)
        let e = ChunkGridLayout(chunks: 136, width: 348)
        #expect(e.cell == 10 && e.perRow == 29 && e.rows == 5 && e.height == 58)
        let f = ChunkGridLayout(chunks: 174, width: 348)
        #expect(f.chunksPerCell == 1 && f.rows == 6)
    }

    @Test func gridMergesAbove174() {
        let g = ChunkGridLayout(chunks: 400, width: 348)
        #expect(g.chunksPerCell == 3 && g.cells == 134 && g.rows == 5)
        #expect(g.chunkRange(cell: 0) == 1...3)
        #expect(g.chunkRange(cell: 133) == 400...400)
        #expect(g.state(cell: 15, current: 47) == .current)  // 46–48
        #expect(g.state(cell: 14, current: 47) == .done)
        #expect(g.state(cell: 16, current: 47) == .waiting)
        #expect(g.state(cell: 0, current: nil) == .waiting)
        #expect(g.state(cell: 133, current: 401) == .done)
    }

    @Test func gridHitTesting() {
        let g = ChunkGridLayout(chunks: 136, width: 348)
        #expect(g.cell(at: 0, 0) == 0)
        #expect(g.cell(at: 11, 0) == nil) // in the gap
        #expect(g.cell(at: 12, 12) == 30)
        #expect(g.cell(at: 12 * 20, 12 * 4) == nil) // past the last cell
        #expect(g.cell(at: 500, 0) == nil)
    }

    @Test func mapModes() {
        #expect(ChunkMapLayout.mode(chunks: 8, width: 600) == .blocks)
        #expect(ChunkMapLayout.mode(chunks: 48, width: 600) == .blocks)
        #expect(ChunkMapLayout.mode(chunks: 49, width: 600) == .strip)
        // A narrow pane can't fit 48 blocks of 6 pt: strip.
        #expect(ChunkMapLayout.mode(chunks: 48, width: 316) == .strip)
        let blocks = ChunkMapLayout.blocks(width: 600, count: 8)
        #expect(blocks[1].x == blocks[0].width + 5)
        #expect(abs(blocks[7].x + blocks[7].width - 600) < 0.001)
        #expect(ChunkMapLayout.stripBars(width: 600) == 200)
    }

    @Test func ringIsAtLeast12() {
        let r = ChunkMapLayout.ring(range: 0.5...0.505, width: 600)
        #expect(r.width == 12 && abs(r.x - (301.5 - 6)) < 0.001)
        #expect(ChunkMapLayout.ring(range: 0...0.001, width: 600).x == 0)
        #expect(ChunkMapLayout.ring(range: 0.999...1, width: 600).x == 588)
        #expect(abs(ChunkMapLayout.ring(range: 0.1...0.3, width: 600).width - 120) < 0.001)
    }
}
