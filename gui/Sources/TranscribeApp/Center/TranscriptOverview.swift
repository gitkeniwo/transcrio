import SwiftUI
import TranscribeKit

/// The 28 pt overview above the finished preview: the whole file's waveform, a
/// draggable box for the part shown in the text, a pointer with the time under it, estimated
/// spans in yellow, and the hovered paragraph as a blue band. Hidden when there are no times.
struct TranscriptOverview: View {
    var waveform: Waveform?
    var duration: Double
    var estimated: [ClosedRange<Double>]
    var controller: PreviewController

    @State private var hoverX: CGFloat?
    @State private var dragMode: DragMode?

    private enum DragMode { case box(start: Double), scrub }

    private static let height: CGFloat = 28
    private static let inset: CGFloat = 4

    var body: some View {
        let visible = controller.visible
        let band = controller.marked ?? controller.hovered
        HStack(alignment: .top, spacing: 0) {
            Text("Overview")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: Self.height, alignment: .leading)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    well(width: geo.size.width, visible: visible, band: band)
                }
                .frame(height: Self.height)
                ticks
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overview")
        .accessibilityValue(visible.map { "Showing \(Formatting.clock($0.lowerBound)) to \(Formatting.clock($0.upperBound))" } ?? "")
        .accessibilityAdjustableAction { direction in
            let step = duration / 10
            let t = (visible?.lowerBound ?? 0) + (direction == .increment ? step : -step)
            controller.seek(max(0, min(duration, t)))
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        Self.inset + CGFloat(max(0, min(1, t / duration))) * (w - 2 * Self.inset)
    }

    private func time(_ x: CGFloat, _ w: CGFloat) -> Double {
        max(0, min(duration, Double((x - Self.inset) / max(1, w - 2 * Self.inset)) * duration))
    }

    private func boxRect(_ v: ClosedRange<Double>, _ w: CGFloat) -> CGRect {
        let lo = x(v.lowerBound, w), hi = x(v.upperBound, w)
        let width = max(6, hi - lo)
        return CGRect(x: min(lo, w - Self.inset - width), y: 2, width: width, height: Self.height - 4)
    }

    private func well(width w: CGFloat, visible: ClosedRange<Double>?, band: ClosedRange<Double>?) -> some View {
        let count = max(10, Int((w - 2 * Self.inset) / 2))
        let levels = waveform?.levels(count: count) ?? []
        let box = visible.map { boxRect($0, w) }
        return Canvas { ctx, size in
            let h = size.height
            for r in estimated {
                let rect = CGRect(x: x(r.lowerBound, w), y: 2, width: max(2, x(r.upperBound, w) - x(r.lowerBound, w)), height: h - 4)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Palette.yellowT))
            }
            if let box {
                ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Palette.blueT))
            }
            if let band {
                let rect = CGRect(x: x(band.lowerBound, w), y: 2, width: max(2, x(band.upperBound, w) - x(band.lowerBound, w)), height: h - 4)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Palette.blue.opacity(0.35)))
            }
            let pitch = (w - 2 * Self.inset) / CGFloat(count)
            let maxBar = h - 8
            for i in 0..<count {
                let t = duration * (Double(i) + 0.5) / Double(count)
                let level = i < levels.count ? CGFloat(levels[i]) : 0.15
                let bh = max(2, level * maxBar)
                let rect = CGRect(x: Self.inset + CGFloat(i) * pitch, y: (h - bh) / 2, width: max(1, pitch - 1), height: bh)
                let color: Color
                if estimated.contains(where: { $0.contains(t) }) { color = Palette.yellow }
                else if let visible, visible.contains(t) { color = Palette.blue }
                else { color = Color(nsColor: .tertiaryLabelColor) }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(color))
            }
            if let box {
                ctx.stroke(Path(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4), with: .color(Palette.blue), lineWidth: 1.5)
            }
            if let hx = hoverX {
                ctx.fill(Path(CGRect(x: hx - 0.75, y: 1, width: 1.5, height: h - 2)), with: .color(Color.primary.opacity(0.7)))
            }
        }
        .background(Palette.panelFill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let hx = hoverX {
                let t = time(hx, w)
                let estimatedHere = estimated.contains { $0.contains(t) }
                Text(estimatedHere ? "\(Formatting.clock(t)) · estimated" : Formatting.clock(t))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Palette.cardFill, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in d.width / 2 - min(max(hx, d.width / 2), w - d.width / 2) }
                    .offset(y: Self.height + 2)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(1)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverX = min(max(p.x, Self.inset), w - Self.inset)
            case .ended: hoverX = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                hoverX = min(max(g.location.x, Self.inset), w - Self.inset)
                if dragMode == nil {
                    if let box, let v = controller.visible, box.insetBy(dx: -3, dy: -4).contains(g.startLocation) {
                        dragMode = .box(start: v.lowerBound)
                    } else {
                        dragMode = .scrub
                    }
                }
                switch dragMode {
                case .box(let start):
                    controller.scrollTop(to: max(0, start + Double(g.translation.width / max(1, w - 2 * Self.inset)) * duration))
                case .scrub where abs(g.translation.width) > 3:
                    let span = controller.visible.map { $0.upperBound - $0.lowerBound } ?? 0
                    controller.scrollTop(to: max(0, time(g.location.x, w) - span / 2))
                default: break
                }
            }
            .onEnded { g in
                if case .scrub = dragMode, abs(g.translation.width) <= 3 { controller.seek(time(g.location.x, w)) }
                dragMode = nil
            })
        .help("Drag the box or click to move the text")
    }

    private var ticks: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let labels = OverviewTicks.labels(duration: duration)
            ZStack(alignment: .topLeading) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                    let text = Text(Formatting.clock(t))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    if i == 0 {
                        text.frame(width: w, alignment: .leading)
                    } else if i == labels.count - 1 {
                        text.frame(width: w, alignment: .trailing)
                    } else {
                        text.position(x: x(t, w), y: 6)
                    }
                }
            }
        }
        .frame(height: 12)
    }
}
