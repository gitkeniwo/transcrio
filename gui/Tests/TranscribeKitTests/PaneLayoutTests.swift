import Testing
@testable import TranscribeKit

@Suite struct PaneLayoutTests {
    func resolve(_ w: Double, center: Bool = true, inspector: Bool = true) -> PaneLayout {
        PaneLayout.resolve(width: w, wantCenter: center, wantInspector: inspector)
    }

    @Test func boardWidths() {
        // 1280: preferred side widths, the rest to the center.
        #expect(resolve(1280) == PaneLayout(queue: 340, center: 580, inspector: 360))
        #expect(resolve(1600) == PaneLayout(queue: 340, center: 900, inspector: 360))
        // 960: everything at its minimum.
        #expect(resolve(960) == PaneLayout(queue: 280, center: 380, inspector: 300))
        // 1100: in between, the sides shrink with the center.
        let l = resolve(1100)
        #expect(l.queue > 280 && l.queue < 340)
        #expect(l.inspector! > 300 && l.inspector! < 360)
        #expect(abs(l.queue + l.center! + l.inspector! - 1100) < 0.001)
    }

    @Test func inspectorCollapsesFirstThenCenter() {
        let a = resolve(959)
        #expect(a.inspector == nil && a.center != nil)
        #expect(a.queue >= 280 && a.queue <= 340)
        #expect(abs(a.queue + a.center! - 959) < 0.001)
        #expect(resolve(660).center == 380)
        let b = resolve(659)
        #expect(b == PaneLayout(queue: 659, center: nil, inspector: nil))
        #expect(resolve(100) == PaneLayout(queue: 280, center: nil, inspector: nil))
    }

    @Test func centerNeverBelowMinimum() {
        for w in stride(from: 280.0, through: 2000, by: 7) {
            let l = resolve(w)
            if let c = l.center { #expect(c >= PaneLayout.centerMin - 0.001) }
            if let i = l.inspector { #expect(PaneLayout.inspectorRange.contains(i)) }
            #expect(l.queue >= 280)
            #expect(abs(l.queue + (l.center ?? 0) + (l.inspector ?? 0) - max(w, 280)) < 0.001)
        }
    }

    @Test func userToggles() {
        #expect(resolve(1280, center: false) == PaneLayout(queue: 920, center: nil, inspector: 360))
        // Center hidden by the user: the inspector fits from 580.
        #expect(resolve(600, center: false) == PaneLayout(queue: 280, center: nil, inspector: 320))
        #expect(resolve(579, center: false).inspector == nil)
        #expect(resolve(1280, inspector: false) == PaneLayout(queue: 340, center: 940, inspector: nil))
    }

    @Test func draggedWidthsAreClamped() {
        let l = PaneLayout.resolve(width: 1400, wantCenter: true, wantInspector: true, queuePreferred: 900, inspectorPreferred: 10)
        #expect(l.queue == 420 && l.inspector == 300)
    }
}
