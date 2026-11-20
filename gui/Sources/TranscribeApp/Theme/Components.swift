import SwiftUI
import TranscribeKit

// MARK: - Semantic surfaces

extension Palette {
    /// Cards sit slightly above the window background in dark mode, white in light mode.
    static let cardFill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor.blended(withFraction: 0.07, of: .white) ?? .windowBackgroundColor
            : NSColor.controlBackgroundColor
    })
    /// Flat control fill (bottom bar buttons, segmented backgrounds).
    static let controlFill = Color.primary.opacity(0.085)
    /// Gray section header bands in the inspector.
    static let bandFill = Color.primary.opacity(0.065)
    /// Unfilled bars and tracks.
    static let trackFill = Color.primary.opacity(0.12)
    /// Background of dotted "map" panels.
    static let panelFill = Color.primary.opacity(0.022)
}

// MARK: - Status pill

/// The 26 pt pill at the right of a queue row: at least `minWidth` wide, wider for longer labels.
struct StatusPill: View {
    var status: RowStatus
    var selected = false
    var minWidth: CGFloat = 54

    var body: some View {
        content
            .font(.system(size: status.isWorking && !isPercent ? 11.5 : 12, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(minWidth: minWidth, minHeight: 26, maxHeight: 26)
            .fixedSize()
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if let ring = ringColor {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(ring, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if case .doneWithNotices = status {
                    Circle().fill(Palette.yellow)
                        .frame(width: 10, height: 10)
                        .background(Circle().strokeBorder(selected ? Palette.selection : Color(nsColor: .windowBackgroundColor), lineWidth: 2).padding(-2))
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(StatusText.accessibility(status)))
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .ready: Text("Ready")
        case .queued(let n): Text(StatusText.ordinal(n))
        case .decoding: HStack(spacing: 4) { Spinner(size: 9, lineWidth: 1.8); Text("Decode").fixedSize() }
        case .preparingModel(_, let d?) where d.info.fraction != nil:
            HStack(spacing: 2) { Image(systemName: "arrow.down").font(.system(size: 10, weight: .heavy)); Text(Formatting.percent(d.info.fraction ?? 0)) }
        case .loadingModel, .preparingModel: HStack(spacing: 4) { Spinner(size: 9, lineWidth: 1.8); Text("Model").fixedSize() }
        case .transcribing(let p, _, _): Text(Formatting.percent(p))
        case .aligning: Text("Align")
        case .stopping: HStack(spacing: 4) { Spinner(size: 9, lineWidth: 1.8); Text("Stop").fixedSize() }
        case .done, .doneWithNotices: Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
        case .failed: Image(systemName: "xmark").font(.system(size: 12, weight: .heavy))
        case .stopped: Text("Stopped")
        }
    }

    private var isPercent: Bool {
        switch status {
        case .transcribing, .preparingModel: true
        default: false
        }
    }

    private var kind: Kind {
        switch status {
        case .queued: .tinted
        case .preparingModel(_, let d?) where d.info.fraction != nil: .tintedAqua
        case .decoding, .loadingModel, .preparingModel: .outlineAqua
        case .transcribing, .aligning, .done, .doneWithNotices, .failed: .solid
        case .ready, .stopping, .stopped: .outlineGray
        }
    }

    private enum Kind { case tinted, tintedAqua, solid, outlineAqua, outlineGray }

    private var accent: Color {
        switch status {
        case .queued: Palette.gray
        case .decoding, .loadingModel, .preparingModel: Palette.aqua
        case .transcribing, .aligning: Palette.blue
        case .done, .doneWithNotices: Palette.green
        case .failed: Palette.red
        case .ready, .stopping, .stopped: .secondary
        }
    }

    private var foreground: Color {
        if selected {
            switch status {
            case .ready, .stopped, .stopping: return Palette.selection.opacity(0.8)
            default: return Palette.selection
            }
        }
        switch kind {
        case .tinted, .tintedAqua, .outlineAqua, .outlineGray: return accent
        case .solid: return Palette.onFill
        }
    }

    private var background: Color {
        if selected { return .white }
        switch kind {
        case .tinted: return Palette.grayT
        case .tintedAqua: return Palette.aquaT
        case .solid: return accent
        case .outlineAqua, .outlineGray: return .clear
        }
    }

    private var ringColor: Color? {
        guard !selected else { return nil }
        switch kind {
        case .outlineAqua: return Palette.aqua
        case .outlineGray: return Color(nsColor: .tertiaryLabelColor)
        default: return nil
        }
    }
}

/// A three-quarter arc that spins, like the canvas spinner glyph.
struct Spinner: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 2
    @State private var spinning = false

    var body: some View {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.75)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Capsules and chips

/// Tinted capsule label: 24 pt high, accent text on its tint.
struct CapsuleLabel: View {
    var text: String
    var tone: Tone = .gray
    var systemImage: String?
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: height < 22 ? 11 : 12, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: height)
        .foregroundStyle(tone.fg)
        .background(tone.bg, in: Capsule())
    }
}

/// White (card-colored) capsule with a drop shadow and a colored dot, floating over dotted panels.
struct FloatingCapsule: View {
    var text: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Palette.cardFill, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.09), radius: 7, y: 4)
    }
}

/// Summary chip: label left, bold value right, on a tint.
struct TintChip: View {
    var title: String
    var value: String
    var tone: Tone

    var body: some View {
        // At narrow widths the value keeps its size and the title gives way, then stacks.
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).font(.system(size: 13)).fixedSize()
                Spacer(minLength: 4)
                Text(value).font(.system(size: 16, weight: .bold)).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 10.5)).fixedSize()
                Text(value).font(.system(size: 14, weight: .bold)).monospacedDigit().fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .foregroundStyle(tone.fg)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

/// Inspector metric tile.
struct MetricTile: View {
    var title: String
    var value: String
    var tone: Tone
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11.5)).opacity(0.85)
            Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let caption { Text(caption).font(.system(size: 10.5)).opacity(0.8).lineLimit(1) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(tone.fg)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Output format badge, as in output file cards and row disclosures.
struct FormatBadge: View {
    var format: OutputFormat
    var style: Style = .card

    enum Style { case card, inline }

    static func tone(_ f: OutputFormat) -> Tone {
        switch f {
        case .srt, .vtt: .orange
        case .md, .txt, .json: .purple
        }
    }

    var body: some View {
        let tone = Self.tone(format)
        switch style {
        case .inline:
            Text(format.rawValue.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tone.fg)
                .frame(width: 30, alignment: .leading)
        case .card:
            Text(format.rawValue.uppercased())
                .font(.system(size: 9.5, weight: .heavy))
                .kerning(0.3)
                .foregroundStyle(tone.fg)
                .frame(width: 30, height: 36, alignment: .bottom)
                .padding(.bottom, 4)
                .background(tone.bg, in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 30, height: 36)
        }
    }
}

// MARK: - Sections and panels

/// Gray header band that opens an inspector section.
struct SectionBand: View {
    var title: String
    var trailing: String?
    var trailingColor: Color = .secondary
    @Binding var expanded: Bool

    init(_ title: String, trailing: String? = nil, trailingColor: Color = .secondary, expanded: Binding<Bool> = .constant(true)) {
        self.title = title
        self.trailing = trailing
        self.trailingColor = trailingColor
        _expanded = expanded
    }

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                Text(title)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(trailingColor) }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.bandFill, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// The dotted "map" panel used across the center pane.
struct DottedPanel<Content: View>: View {
    var cornerRadius: CGFloat = 14
    var dashed = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(Palette.panelFill)
                    DotGrid().clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color(nsColor: .tertiaryLabelColor), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Palette.hairline.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

struct DotGrid: View {
    var spacing: CGFloat = 14
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += spacing
                }
                y += spacing
            }
            ctx.fill(path, with: .color(.primary.opacity(0.13)))
        }
        .accessibilityHidden(true)
    }
}

/// A card with the standard fill and hairline border.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.hairline.opacity(0.8), lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 10) -> some View { modifier(CardBackground(radius: radius)) }
}

// MARK: - Icons and bars

/// Rounded-square file-type icon with a white glyph.
struct FileTypeIcon: View {
    var kind: MediaKind
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(kind == .video ? Palette.videoIcon : Palette.audioIcon)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind == .video ? "film" : "waveform")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(kind == .video ? "Video file" : "Audio file")
    }
}

/// The row waveform: RMS bars, 2 pt wide with 1.5 pt gaps and up to 26 pt tall,
/// that double as the progress bar. Bars before `fraction` take the tone's color (yellow inside
/// estimated-timing spans), the rest the track color. A flat line until the levels are loaded.
struct RowWaveform: View {
    var levels: [Float]?
    var fraction: Double
    var tone: WaveformTone
    var estimated: [ClosedRange<Double>] = []
    var selected = false
    var count = 16

    static let barWidth: CGFloat = 2, gap: CGFloat = 1.5, height: CGFloat = 26

    var body: some View {
        let width = CGFloat(count) * Self.barWidth + CGFloat(count - 1) * Self.gap
        Canvas { ctx, size in
            for i in 0..<count {
                let mid = (Double(i) + 0.5) / Double(count)
                let level = levels.map { CGFloat($0.indices.contains(i) ? $0[i] : 0) } ?? 0
                let h = max(2, level * size.height)
                let rect = CGRect(x: CGFloat(i) * (Self.barWidth + Self.gap), y: (size.height - h) / 2, width: Self.barWidth, height: h)
                let filled = mid < fraction
                let inEstimate = estimated.contains { $0.contains(mid) }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color(filled: filled, estimated: inEstimate)))
            }
        }
        .frame(width: width, height: Self.height)
        .accessibilityHidden(true)
    }

    private func color(filled: Bool, estimated: Bool) -> Color {
        if selected { return filled ? .white : .white.opacity(0.32) }
        guard filled else { return Palette.trackFill }
        if estimated { return Palette.yellow }
        switch tone {
        case .track: return Palette.trackFill
        case .working: return Palette.blue
        case .finished: return Color(nsColor: .tertiaryLabelColor)
        case .failed: return Palette.red
        }
    }
}

/// Thin progress bar.
struct ThinBar: View {
    var value: Double
    var tone: Color = Palette.blue
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.trackFill)
                Capsule().fill(tone).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Diagonal stripes, for indeterminate bars and "remaining" hatching.
struct Stripes: View {
    var color: Color
    var background: Color = .clear
    var width: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            var x: CGFloat = -size.height
            var path = Path()
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + width, y: 0))
                path.addLine(to: CGPoint(x: x + width, y: size.height))
                path.closeSubpath()
                x += width * 2
            }
            ctx.fill(path, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// Flat gray button, as in the sidebar bottom bar and center toolbar.
struct FlatButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(minWidth: 32)
            .frame(height: height)
            .foregroundStyle(prominent || destructive ? Palette.onFill : Color.primary)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private var fill: Color {
        if destructive { return Palette.red }
        if prominent { return Palette.blue }
        return Palette.controlFill
    }
}

// MARK: - Status text

enum StatusText {
    /// Row subtitle, from the state table. `defaults` decides whether the option summary names the model.
    static func subtitle(_ status: RowStatus, item: FileItem, defaults: TranscribeOptions? = nil) -> String {
        switch status {
        case .ready, .queued:
            return item.options.summary(duration: item.duration, defaultModel: defaults?.model ?? .accurate)
        case .decoding: return "Decoding audio…"
        case .loadingModel: return "Loading model…"
        case .preparingModel(let m, let d):
            if let d, d.info.totalBytes > 0 {
                return "Downloading \(modelLabel(m)) · \(gigabytes(d.info.downloadedBytes, of: d.info.totalBytes))"
            }
            return "Preparing \(m == .aligner ? "aligner" : "model") · first run \(m.approximateDownload)"
        case .transcribing(_, let chunk, let total):
            if let chunk, let total { return "Transcribing · chunk \(chunk) of \(total)" }
            return "Transcribing…"
        case .aligning: return "Aligning subtitles"
        case .stopping: return "Stopping after this chunk…"
        case .done, .doneWithNotices:
            let r = item.result
            var parts = [Formatting.clock(r?.duration ?? item.duration)]
            if let lang = r?.language { parts.append(lang) }
            if case .doneWithNotices(let n) = status {
                parts.append(n == 1 ? "1 notice" : "\(n) notices")
            } else {
                parts.append("took \(Formatting.took(r?.elapsed))")
            }
            return parts.joined(separator: " · ")
        case .failed(let e): return friendlyError(e)
        case .stopped(let at): return "Stopped at \(Formatting.clock(at)) · Retry starts over"
        }
    }

    static func accessibility(_ status: RowStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .queued(let n): "Queued, \(ordinal(n)) in line"
        case .decoding: "Decoding"
        case .loadingModel: "Loading model"
        case .preparingModel(_, let d):
            d?.info.fraction.map { "Downloading model, \(Formatting.percent($0))" } ?? "Preparing model"
        case .transcribing(let p, _, _): "Transcribing, \(Formatting.percent(p))"
        case .aligning: "Aligning"
        case .stopping: "Stopping"
        case .done: "Done"
        case .doneWithNotices(let n): "Done with \(n) notice\(n == 1 ? "" : "s")"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    /// 1st, 2nd, 3rd, 4th, … 11th, 12th, 13th, … 21st.
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// "1.7B", "0.6B" or "aligner".
    static func modelLabel(_ m: CachedModel) -> String {
        switch m {
        case .asr1_7b: "1.7B"
        case .asr0_6b: "0.6B"
        case .aligner: "aligner"
        }
    }

    /// "1.9 of 4.4 GB" (MB below 1 GB total).
    static func gigabytes(_ done: Int64, of total: Int64) -> String {
        let gb = Double(total) >= 1e9
        let unit = gb ? 1e9 : 1e6
        let f = { (b: Int64) in String(format: gb ? "%.1f" : "%.0f", locale: .current, Double(b) / unit) }
        return "\(f(done)) of \(f(total)) \(gb ? "GB" : "MB")"
    }

    /// Shortens the CLI's error text for the one-line subtitle.
    static func friendlyError(_ e: String) -> String {
        if e.hasPrefix("output exists") { return "Output exists. Turn on Overwrite to replace." }
        if e.hasPrefix("no such file") { return "File not found" }
        if e.contains("no audio stream") { return "No audio stream in this file" }
        if e.hasPrefix("ffmpeg failed to decode") { return "Couldn’t decode audio" }
        return e
    }
}

/// Re-renders `content` every `interval` seconds while `active`, for text that shows elapsed
/// or remaining time. Replaces the app-wide ticker: only these views redraw.
struct Ticking<Content: View>: View {
    var active = true
    var interval: TimeInterval = 1
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        TimelineView(TickSchedule(interval: interval, active: active)) { ctx in content(ctx.date) }
    }
}

struct TickSchedule: TimelineSchedule {
    var interval: TimeInterval
    var active: Bool

    /// Ticks fall on whole multiples of `interval`, so every ticking view updates in the same
    /// frame (one commit) instead of each on its own phase.
    func entries(from start: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard active else { return AnySequence([start]) }
        return AnySequence(sequence(first: start) { d in
            Date(timeIntervalSinceReferenceDate: (floor(d.timeIntervalSinceReferenceDate / interval) + 1) * interval)
        })
    }
}
