import SwiftUI
import TranscribeKit

/// A1/B3: chunk map, stage stepper and the live transcript. Also used for Ready and Queued
/// files (not-started card), and (with `firstRun`) while the model downloads (B7 hero).
struct RunningView: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    var status: RowStatus
    var firstRun: CachedModel?
    var download: DownloadProgress?

    private var notStarted: Bool { item.state == .ready || item.state == .queued }

    var body: some View {
        VStack(spacing: 0) {
            CenterHeader(title: item.name, capsule: headerCapsule) {
                formatCapsules(item.displayedOptions.formats)
            }
            if notStarted {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Ticking(active: false) { now in
                            StageStepper(item: item, status: status, now: now, warm: false)
                        }
                        NotStartedTranscript(item: item)
                    }
                    .padding(16)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let firstRun {
                        FirstRunPanel(item: item, cachedModel: firstRun, download: download)
                    } else {
                        Ticking(active: status.isWorking) { now in
                            ChunkMap(item: item, waveform: model.waveforms[item.id], now: now)
                        }
                    }
                    Ticking(active: status.isWorking) { now in
                        StageStepper(item: item, status: status, now: now, warm: item.modelWasWarm)
                    }
                    LiveTranscript(item: item, status: status)
                        .frame(maxHeight: .infinity)
                }
                .padding(16)
            }
        }
    }

    private var headerCapsule: CapsuleLabel {
        switch status {
        case .ready:
            CapsuleLabel(text: "Ready", tone: .gray)
        case .queued(let n):
            CapsuleLabel(text: "Up next · \(StatusText.ordinal(n))", tone: .gray)
        case .decoding:
            CapsuleLabel(text: "Decoding", tone: .blue)
        case .loadingModel:
            CapsuleLabel(text: "Loading model", tone: .aqua)
        case .preparingModel(let m, let d):
            CapsuleLabel(text: d?.info.fraction.map { "\(m == .aligner ? "Preparing aligner" : "Preparing model") · \(Formatting.percent($0))" }
                ?? (m == .aligner ? "Preparing aligner" : "Preparing model"), tone: .aqua)
        case .transcribing(let p, _, _):
            CapsuleLabel(text: "Transcribing · \(Formatting.percent(p))", tone: .blue)
        case .aligning:
            CapsuleLabel(text: "Aligning", tone: .purple)
        case .stopping:
            CapsuleLabel(text: "Stopping…", tone: .gray)
        default:
            CapsuleLabel(text: StatusText.subtitle(status, item: item), tone: .gray)
        }
    }
}

// MARK: - Chunk map

/// Dotted panel with one block per chunk: done, active (ringed) and waiting.
struct ChunkMap: View {
    @Environment(\.paneWidth) private var paneWidth
    var item: FileItem
    var waveform: Waveform?
    var now: Date

    private var chunkInfo: (current: Int?, total: Int?, progress: Double) {
        switch item.state {
        case .running(.transcribe, let p, let c, let t): (c, t, p)
        case .running(.align, _, _, let t): (t.map { $0 + 1 }, t, 1)
        case .running(_, _, _, _): (nil, nil, 0)
        default: (nil, nil, 0)
        }
    }

    var body: some View {
        let info = chunkInfo
        let total = info.total ?? 0
        let ranges = total > 0 ? item.chunkRanges(total: total) : [0...1]
        DottedPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let c = info.current, total > 0 {
                        FloatingCapsule(text: c > total ? "All \(total) chunks" : "Chunk \(c) of \(total)", dot: Palette.blue)
                    } else {
                        FloatingCapsule(text: total > 0 ? "\(total) chunks" : "Whole file", dot: Palette.gray)
                    }
                    if let c = info.current, total > 0 {
                        FloatingCapsule(text: "\(min(c - 1, total)) done", dot: Palette.green)
                    }
                    Spacer(minLength: 0)
                    if paneWidth >= 500, let remaining = remaining(progress: info.progress) {
                        FloatingCapsule(text: "About \(Formatting.clock(remaining)) left", dot: nil)
                    }
                }
                ChunkCanvas(states: (0..<max(total, 1)).map { blockState(index: $0 + 1, current: info.current, total: total) },
                            ranges: ranges, waveform: waveform)
                    .frame(height: total > ChunkMapLayout.blockLimit ? 104 : 96)
                TimeAxis(duration: item.duration, labels: paneWidth >= 440 ? 5 : 3)
            }
            .padding(16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(info))
    }

    private func blockState(index: Int, current: Int?, total: Int) -> ChunkState {
        guard let current else { return item.state.isTerminal ? .done : .waiting }
        if index < current { return .done }
        if index == current { return .current }
        return .waiting
    }

    /// Remaining time from the measured transcription speed so far.
    private func remaining(progress: Double) -> Double? {
        guard progress > 0.05, let span = item.stages[.transcribe], let d = item.duration else { return nil }
        let elapsed = span.duration(now: now)
        let rate = progress / elapsed
        guard rate > 0 else { return nil }
        let left = (1 - progress) / rate
        return left.isFinite && d > 0 ? left : nil
    }

    private func accessibilityText(_ info: (current: Int?, total: Int?, progress: Double)) -> String {
        if let c = info.current, let t = info.total { return "Chunk \(min(c, t)) of \(t), \(Formatting.percent(info.progress)) transcribed" }
        return "Waiting to transcribe"
    }
}

/// The chunk map drawing, in one Canvas so 136 chunks cost one view:
/// blocks for up to 48 chunks, otherwise a continuous strip of bars with a comb of chunk
/// boundaries underneath. Done chunks green, the current one blue with a ring, waiting ones
/// at 25 % gray.
struct ChunkCanvas: View {
    var states: [ChunkState]
    var ranges: [ClosedRange<Double>]
    var waveform: Waveform?

    static let wait = Palette.gray.opacity(0.25)

    var body: some View {
        Canvas { ctx, size in
            switch ChunkMapLayout.mode(chunks: states.count, width: size.width) {
            case .blocks: drawBlocks(ctx, size)
            case .strip: drawStrip(ctx, size)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawBlocks(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = 96.0
        for (i, frame) in ChunkMapLayout.blocks(width: size.width, count: states.count).enumerated() {
            let state = states[i]
            let rect = CGRect(x: frame.x, y: 0, width: frame.width, height: h)
            let shape = Path(roundedRect: rect, cornerRadius: min(9, frame.width / 2))
            switch state {
            case .done: ctx.fill(shape, with: .color(Palette.greenT))
            case .current: ctx.fill(shape, with: .color(Palette.blueT))
            case .waiting: ctx.fill(shape, with: .color(Palette.cardFill))
            }
            let r = ranges.indices.contains(i) ? ranges[i] : 0...1
            let bars = ChunkMapLayout.barsPerBlock(width: frame.width)
            let levels = waveform?.levels(count: bars, from: r.lowerBound, to: r.upperBound) ?? Array(repeating: 0.3, count: bars)
            let inner = max(0, frame.width - 10)
            let pitch = inner / Double(bars)
            let barW = max(1, min(3, pitch - 2))
            for (j, level) in levels.enumerated() {
                let bh = max(3, Double(level) * 64)
                let x = frame.x + 5 + pitch * (Double(j) + 0.5) - barW / 2
                ctx.fill(Path(roundedRect: CGRect(x: x, y: (h - bh) / 2, width: barW, height: bh), cornerRadius: barW / 2),
                         with: .color(color(state)))
            }
            switch state {
            case .current: ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: min(8.25, frame.width / 2)),
                                      with: .color(Palette.blue), lineWidth: 1.5)
            case .waiting: ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: min(8.5, frame.width / 2)),
                                      with: .color(Palette.hairline), lineWidth: 1)
            case .done: break
            }
        }
    }

    private func drawStrip(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = 96.0, w = size.width
        let current = states.firstIndex(of: .current)
        // The current chunk's ring sits behind its bars.
        var ringRect: CGRect?
        if let c = current, ranges.indices.contains(c) {
            let ring = ChunkMapLayout.ring(range: ranges[c], width: w)
            let rect = CGRect(x: ring.x, y: 0, width: ring.width, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Palette.blueT))
            ringRect = rect
        }
        let n = ChunkMapLayout.stripBars(width: w)
        let levels = waveform?.levels(count: n) ?? Array(repeating: 0.3, count: n)
        let pitch = w / Double(n)
        let barW = max(1, pitch - 1)
        var chunk = 0
        for (i, level) in levels.enumerated() {
            let t = (Double(i) + 0.5) / Double(n)
            while chunk < ranges.count - 1, t > ranges[chunk].upperBound { chunk += 1 }
            let state = states.indices.contains(chunk) ? states[chunk] : .waiting
            let bh = max(3, Double(level) * 80)
            ctx.fill(Path(roundedRect: CGRect(x: Double(i) * pitch + (pitch - barW) / 2, y: (h - bh) / 2, width: barW, height: bh),
                          cornerRadius: barW / 2), with: .color(color(state)))
        }
        if let ringRect {
            ctx.stroke(Path(roundedRect: ringRect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4.25), with: .color(Palette.blue), lineWidth: 1.5)
        }
        // Comb: a hairline per chunk boundary, 5 pt tall, under the strip.
        var comb = Path()
        for r in ranges.dropFirst() {
            let x = (r.lowerBound * w).rounded() + 0.5
            comb.move(to: CGPoint(x: x, y: h + 3))
            comb.addLine(to: CGPoint(x: x, y: h + 8))
        }
        ctx.stroke(comb, with: .color(Palette.hairline), lineWidth: 1)
    }

    private func color(_ state: ChunkState) -> Color {
        switch state {
        case .done: Palette.green
        case .current: Palette.blue
        case .waiting: Self.wait
        }
    }
}

/// Evenly spaced time labels under the chunk map (5, or 3 in a narrow center pane).
struct TimeAxis: View {
    var duration: Double?
    var labels = 5

    var body: some View {
        HStack {
            ForEach(0..<labels, id: \.self) { i in
                if i > 0 { Spacer() }
                Text(duration.map { Formatting.clock($0 * Double(i) / Double(labels - 1)) } ?? "")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

// MARK: - First run

/// Shown instead of the chunk map while the model downloads. No percentages: the CLI
/// doesn't report download progress.
struct FirstRunPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var item: FileItem
    var cachedModel: CachedModel
    /// Real progress from `download` events; nil when the CLI couldn't report it (the guess).
    var download: DownloadProgress?
    @State private var phase: CGFloat = 0

    var body: some View {
        let waitingSince = download?.startedAt ?? item.lastEventAt ?? item.startedAt ?? Date()
        DottedPanel {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    CapsuleLabel(text: "First run", tone: .aqua)
                    CapsuleLabel(text: cachedModel.shortName, tone: .gray)
                    Spacer()
                    Ticking { now in
                        Text("\(download == nil ? "Waiting" : "Downloading") \(Formatting.clock(now.timeIntervalSince(waitingSince)))")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Circle().fill(Palette.aquaT).frame(width: 52, height: 52)
                    .overlay(Image(systemName: "arrow.down").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.aqua))
                    .padding(.top, 6)
                Text(cachedModel == .aligner ? "Preparing the aligner" : "Preparing the model").font(.system(size: 17, weight: .bold))
                Text(explanation)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if let fraction = download?.info.fraction {
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.aquaT)
                                Capsule().fill(Palette.aqua).frame(width: max(6, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 6)
                        Text(byteLine)
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 360)
                } else {
                    GeometryReader { geo in
                        Stripes(color: Palette.aqua.opacity(0.55), background: Palette.aquaT, width: 6)
                            .frame(width: geo.size.width + 24)
                            .offset(x: -24 + phase * 24)
                            .frame(width: geo.size.width, alignment: .leading)
                            .clipShape(Capsule())
                    }
                    .frame(height: 6)
                    .frame(maxWidth: 360)
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
                HStack(spacing: 8) {
                    Button("Open Models…") { openWindow(id: "models") }
                        .buttonStyle(FlatButtonStyle())
                    Button { model.stop(item.id) } label: { Label("Stop This File", systemImage: "stop.fill") }
                        .buttonStyle(FlatButtonStyle())
                        .disabled(item.isStopping)
                }
                .padding(.top, 6)
            }
            .padding(16)
            .padding(.bottom, 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var size: String {
        if let d = download, d.info.totalBytes > 0 { return Formatting.size(d.info.totalBytes) }
        return cachedModel.approximateDownload.replacingOccurrences(of: "≈", with: "about ")
    }

    private var explanation: String {
        let base = "The first run downloads \(size). After that everything works offline."
        return download?.info.fraction == nil ? base + " There’s no exact progress while it downloads." : base
    }

    /// `812 MB of 1.8 GB · 14 MB/s · about 1:12 left`
    private var byteLine: String {
        guard let d = download else { return "" }
        var parts = [StatusText.gigabytes(d.info.downloadedBytes, of: d.info.totalBytes)]
        if let rate = d.bytesPerSecond { parts.append("\(Formatting.size(Int64(rate)))/s") }
        if let left = d.remaining { parts.append("about \(Formatting.clock(left)) left") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        if let f = download?.info.fraction {
            return "Preparing the model. Downloading \(size), \(Formatting.percent(f)) done."
        }
        return "Preparing the model. The first run downloads \(cachedModel.approximateDownload). No exact progress is available."
    }
}

// MARK: - Stages

/// Four stage cards: Decode, Load model, Transcribe, Align, with measured durations.
struct StageStepper: View {
    @Environment(\.paneWidth) private var paneWidth
    var item: FileItem
    var status: RowStatus
    var now: Date
    /// The worker already had the model in memory, so Load model was skipped.
    var warm = false

    private var stages: [(Stage, String, String)] {
        [(.decode, "Decode", "waveform"), (.load, "Load model", "cpu"),
         (.transcribe, "Transcribe", "text.bubble"), (.align, "Align", "text.line.first.and.arrowtriangle.forward")]
    }

    private let order: [Stage] = [.decode, .load, .transcribe, .align]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: paneWidth >= 440 ? 4 : 2), spacing: 8) {
            ForEach(stages, id: \.0) { stage, title, icon in
                StageCard(title: title, icon: icon, state: state(of: stage), detail: detail(of: stage))
            }
        }
    }

    /// The stage shown as active. A model download belongs to Load model (or Align for the
    /// aligner), whatever stage the worker last reported.
    private var currentStage: Stage? {
        if case .preparingModel(let m, _) = status { return m == .aligner ? .align : .load }
        if case .running(let s, _, _, _) = item.state { return s }
        return nil
    }

    private func state(of stage: Stage) -> StageCard.State {
        if stage == .align && !item.wantsCues { return .skipped }
        if currentStage == stage { return .active }
        // Serve aligns each chunk right after transcribing it.
        if stage == .align, currentStage == .transcribe, item.stages[.align] != nil { return .active }
        // Stages before the active one are over, even when the worker skipped reporting them.
        if let current = currentStage, let i = order.firstIndex(of: stage), let c = order.firstIndex(of: current),
           i < c, stage != .align { return .done }
        if let span = item.stages[stage], span.end != nil { return .done }
        // The CLI loads the model once per batch, so later files skip the load stage.
        if stage == .load, item.stages[.transcribe] != nil || item.stages[.align] != nil { return .done }
        if case .done = item.state { return .done }
        return .waiting
    }

    private func detail(of stage: Stage) -> String {
        switch state(of: stage) {
        case .skipped: return "Not needed"
        case .waiting: return "Waiting"
        case .done:
            guard let span = item.stages[stage] else {
                if stage == .load { return warm ? "Already in memory" : "Already loaded" }
                if stage == .align { return "With each chunk" }
                return "Done"
            }
            return Formatting.took(span.duration(now: now))
        case .active:
            let elapsed = item.stages[stage].map { Formatting.clock($0.duration(now: now)) } ?? ""
            if stage == .align, currentStage == .transcribe { return "With each chunk" }
            switch status {
            case .preparingModel: return "Downloading"
            case .transcribing(_, let c?, let t?): return "Chunk \(c) of \(t)"
            case .stopping: return "Stopping…"
            default: return "Running · \(elapsed)"
            }
        }
    }
}

struct StageCard: View {
    enum State { case done, active, waiting, skipped }
    var title: String
    var icon: String
    var state: State
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle().fill(circleFill)
                switch state {
                case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.onFill)
                case .active: Spinner(size: 12, lineWidth: 2).foregroundStyle(Palette.blue)
                case .waiting, .skipped: Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .bold))
                Text(detail).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(state == .active ? Palette.blue : .secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(state == .active ? Palette.blueT : Palette.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state == .active ? Palette.blue.opacity(0.5) : Palette.hairline, lineWidth: 1))
        .opacity(state == .skipped ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var circleFill: Color {
        switch state {
        case .done: Palette.green
        case .active: Palette.cardFill
        case .waiting, .skipped: Palette.trackFill
        }
    }
}

// MARK: - Not started

/// The transcript card of a file that hasn't started: no skeleton bars, which
/// would read as content that failed to load, but what the file will write and how to start it.
struct NotStartedTranscript: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    var item: FileItem

    private var formats: [OutputFormat] { item.options.formats }
    private var narrow: Bool { paneWidth < 500 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Palette.grayT)
                Image(systemName: "text.bubble").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.gray)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
            Text("Not started yet")
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 12)
            Text(narrow ? "Paragraphs appear here one at a time once this file starts."
                        : "Paragraphs appear here one at a time as soon as this file starts, so you can read along while it runs.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.top, 4)
            // Design L5 "Will save": the library line, then a dashed card per copy.
            VStack(alignment: .leading, spacing: 8) {
                Text("Will save").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                FlowCards(minWidth: 180) {
                    libraryCard
                    ForEach(copies, id: \.url) { c in copyCard(c.url, place: c.place) }
                }
            }
            .padding(.top, 18)
            HStack(spacing: 8) {
                Button { model.start([item.id]) } label: { Label("Start This File", systemImage: "play.fill") }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .disabled(item.state == .queued)
                    .help(model.isRunning ? "Add this file to Up next" : "Transcribe this file")
                if item.state == .queued {
                    Button("Unqueue") { model.unqueue([item.id]) }.buttonStyle(FlatButtonStyle())
                } else {
                    Button("Run Next") { model.runNext([item.id]) }.buttonStyle(FlatButtonStyle())
                }
            }
            .padding(.top, 18)
            if let d = item.duration, let est = model.history.estimate(duration: d, model: item.options.model.rawValue) {
                Text("≈ \(QueueEstimate.format(est)) on this Mac")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .card(radius: 12)
    }

    /// "To your library · md prepared" (or "transcript only").
    private var libraryCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical.fill").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.blue)
                .frame(width: 26, height: 26)
                .background(Palette.blueT, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("To your library").font(.system(size: 12.5, weight: .semibold))
                Text(formats.isEmpty ? "transcript only" : "\(OutputFormat.ordered(formats).map(\.rawValue).joined(separator: ", ")) prepared")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.blueT.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Copies this file would write: "podcast-ep12.srt · copy, next to the source".
    private var copies: [(url: URL, place: String)] {
        guard let plan = CopyPlan(options: item.options, source: item.url) else { return [] }
        let place = item.options.copyMode == .nextToSource ? "next to the source" : "in \(plan.directory.lastPathComponent)"
        return plan.destinations(source: item.url).map { ($0.url, place) }
    }

    private func copyCard(_ url: URL, place: String) -> some View {
        HStack(spacing: 10) {
            FormatBadge(format: OutputFormat(rawValue: url.pathExtension) ?? .md)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text("copy, \(place)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .help(url.path)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// Equal-width cards in as many columns as fit (at least `minWidth` each), wrapping.
private struct FlowCards<Content: View>: View {
    var minWidth: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 8)], alignment: .leading, spacing: 8) {
            content
        }
    }
}

// MARK: - Live transcript

/// One paragraph per `segment` event while the file runs.
/// Follows the bottom until scrolled up; then "Jump to live · n new" brings it back.
struct LiveTranscript: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    var status: RowStatus
    @State private var following = true
    @State private var seenCount = 0
    @State private var visible: Set<Int> = []

    var body: some View {
        let segments = item.liveSegments
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                CapsuleLabel(text: "Live preview", tone: .blue, height: 20)
                Spacer()
                Text("final formatting when done").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if segments.isEmpty {
                            Text(status.isWorking ? "The first paragraph appears when the first chunk is done." : "No text yet.")
                                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                            LiveParagraph(segment: seg, fresh: i == segments.count - 1)
                                .id(i)
                                .transition(.modifier(active: FadeIn(opacity: 0.45), identity: FadeIn(opacity: 1)))
                                .onAppear { visible.insert(i); reportTop(segments) }
                                .onDisappear { visible.remove(i); reportTop(segments) }
                        }
                        if status.isWorking { typingHint }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear {
                                following = true
                                seenCount = segments.count
                            }
                            .onDisappear {
                                following = false
                                seenCount = segments.count
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .animation(.easeOut(duration: 0.25), value: segments.count)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !following && segments.count > seenCount {
                        Button {
                            withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Text("Jump to live · \(segments.count - seenCount) new")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .foregroundStyle(Palette.onFill)
                                .background(Palette.blue, in: Capsule())
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                        .transition(.opacity)
                    }
                }
                .onChange(of: segments.count) {
                    if following { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .card(radius: 12)
    }

    private var typingHint: some View {
        let chunk: Int? = if case .transcribing(_, let c, _) = status { c } else { nil }
        return HStack(spacing: 8) {
            Text("• • •").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.blue.opacity(0.7))
            if let chunk { Text("Chunk \(chunk)").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 82)
        .accessibilityLabel("More text is coming")
    }

    /// The topmost visible paragraph's start, so the finished preview opens at the same place.
    private func reportTop(_ segments: [TranscriptSegment]) {
        guard !following, let top = visible.min(), segments.indices.contains(top) else {
            if following { model.liveTopTime[item.id] = nil }
            return
        }
        model.liveTopTime[item.id] = segments[top].start
    }
}

private struct FadeIn: ViewModifier {
    var opacity: Double
    func body(content: Content) -> some View { content.opacity(opacity) }
}

private struct LiveParagraph: View {
    var segment: TranscriptSegment
    var fresh: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Formatting.stamp(segment.start))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(fresh ? Palette.blue : .secondary)
                .frame(width: 70, height: 20)
                .background(fresh ? Palette.blueT : Palette.grayT, in: Capsule())
            Text(segment.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
