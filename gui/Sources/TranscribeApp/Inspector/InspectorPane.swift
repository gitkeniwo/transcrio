import SwiftUI
import TranscribeKit

/// Right column: options with nothing selected, otherwise details for the selected file.
struct InspectorPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let entry = model.selectedEntry {
                        EntryInspector(entry: entry).id(entry.id)
                    } else if model.historySelection.count > 1 {
                        EntriesInspector(entries: model.selectedEntries)
                    } else if model.selection.count > 1 {
                        InspectorHeader(systemImage: "square.stack.3d.up", tint: Palette.purple,
                                        title: "\(model.selection.count) files",
                                        subtitle: Formatting.longClock(model.selectedItems.compactMap(\.duration).reduce(0, +)) + " of audio")
                        ScopeBand()
                        if model.optionsEditable { OptionsForm() } else { OptionsTags(options: model.shownOptions) }
                    } else if let item = model.selectedItem {
                        let status = model.status(of: item)
                        FileHeader(item: item, status: status)
                        switch item.state {
                        case .running:
                            RunningInspector(item: item, status: status)
                        case .done(let result):
                            FinishedInspector(item: item, result: result)
                            OptionsUsed(item: item)
                        case .failed(let message):
                            ProblemCard(item: item, message: message)
                            ScopeBand()
                            OptionsForm()
                        case .stopped:
                            ProblemCard(item: item, message: nil)
                            ScopeBand()
                            OptionsForm()
                        case .ready, .queued:
                            ScopeBand()
                            OptionsForm()
                        }
                    } else {
                        InspectorHeader(systemImage: "slider.horizontal.3", tint: Palette.blue,
                                        title: "Transcription Options", subtitle: "Remembered between launches")
                        ScopeBand()
                        OptionsForm()
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            .onChange(of: model.inspectorFocus) { _, focus in
                guard let focus else { return }
                withAnimation { proxy.scrollTo(focus, anchor: .top) }
                model.inspectorFocus = nil
            }
        }
        .background(Palette.panelFill)
    }
}

// MARK: - Headers

struct InspectorHeader<Icon: View>: View {
    @Environment(AppModel.self) private var model
    var title: String
    var subtitle: String
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .bold)).lineLimit(2).truncationMode(.middle)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !model.selection.isEmpty || !model.historySelection.isEmpty {
                // The way back to "Transcription Options" (defaults for new files).
                Button("Defaults…") { model.showDefaults() }
                    .buttonStyle(.link)
                    .font(.system(size: 12.5))
                    .help("Clear the selection and show the defaults for new files")
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 14)
        .accessibilityElement(children: .contain)
    }
}

extension InspectorHeader where Icon == AnyView {
    init(systemImage: String, tint: Color, title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.icon = AnyView(
            RoundedRectangle(cornerRadius: 12).fill(tint).frame(width: 48, height: 48)
                .overlay(Image(systemName: systemImage).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.onFill))
                .accessibilityHidden(true))
    }
}

private struct FileHeader: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    var status: RowStatus

    var body: some View {
        Ticking(active: item.finishedAt != nil, interval: 30) { now in
            InspectorHeader(title: item.name, subtitle: subtitle(now: now)) {
                FileTypeIcon(kind: item.kind, size: 48)
            }
        }
    }

    private func subtitle(now: Date) -> String {
        switch item.state {
        case .done:
            guard let finished = item.finishedAt else { return "Finished" }
            let ago = now.timeIntervalSince(finished)
            if ago < 60 { return "Finished just now" }
            return "Finished " + RelativeDateTimeFormatter().localizedString(for: finished, relativeTo: now)
        default:
            var parts = [item.kind == .video ? "Video" : "Audio", Formatting.clock(item.duration)]
            if let size = Self.fileSize(item.path) { parts.append(Formatting.size(size)) }
            return parts.joined(separator: " · ")
        }
    }

    static func fileSize(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }
}

// MARK: - Running

private struct RunningInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    var item: FileItem
    var status: RowStatus
    @State private var showPipeline = true
    @State private var showChunks = true
    @State private var showOptions = false

    var body: some View {
        let progress = item.overallProgress
        VStack(alignment: .leading, spacing: 0) {
            Ticking(active: item.state.isRunning) { now in
            let elapsed = item.startedAt.map { now.timeIntervalSince($0) } ?? 0
            HStack(spacing: paneWidth < 330 ? 10 : 16) {
                ProgressRing(value: progress, indeterminate: !isMeasurable, size: paneWidth < 330 ? 64 : 76)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Elapsed").foregroundStyle(.secondary).fixedSize()
                        Text(Formatting.clock(elapsed)).bold().monospacedDigit()
                    }
                    GridRow {
                        Text("Remaining").foregroundStyle(.secondary).fixedSize()
                        Text(remainingText(elapsed: elapsed, progress: progress)).bold().monospacedDigit()
                    }
                    GridRow {
                        Text("Speed").foregroundStyle(.secondary).fixedSize()
                        // "≈ 265× realtime", or "≈ 265×" when that doesn't fit.
                        ViewThatFits(in: .horizontal) {
                            Text(speed(elapsed: elapsed, progress: progress)).bold().fixedSize()
                            Text(speed(elapsed: elapsed, progress: progress).replacingOccurrences(of: " realtime", with: "")).bold().fixedSize()
                        }
                    }
                }
                .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.blueT, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14).padding(.bottom, 14)
            .accessibilityElement(children: .combine)
            }

            SectionBand("Pipeline", expanded: $showPipeline)
            if showPipeline {
                Ticking(active: item.state.isRunning) { now in
                    Gantt(item: item, now: now, remaining: remaining(elapsed: item.startedAt.map { now.timeIntervalSince($0) } ?? 0, progress: progress))
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            if let total = totalChunks {
                SectionBand("Chunks", trailing: "\(min(currentChunk ?? 0, total)) of \(total)", expanded: $showChunks)
                if showChunks {
                    ChunkGrid(item: item, total: total, current: currentChunk, aligning: isAligning)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
            // Options used, collapsed to one line while the file runs (B3).
            SectionBand("Options used", trailing: showOptions ? "read-only" : item.displayedOptions.summary(duration: nil, defaultModel: model.options.model)
                .replacingOccurrences(of: "–:–– · ", with: ""), expanded: $showOptions)
            if showOptions { OptionsTags(options: item.displayedOptions, banded: false) }
        }
    }

    private var isMeasurable: Bool {
        switch status {
        case .transcribing, .aligning: true
        default: false
        }
    }

    private var isAligning: Bool { if case .running(.align, _, _, _) = item.state { true } else { false } }

    private var totalChunks: Int? {
        if case .running(_, _, _, let t) = item.state, let t, t > 0 { return t }
        return item.chunkStarts.isEmpty ? nil : item.chunkStarts.keys.max()
    }

    private var currentChunk: Int? {
        switch item.state {
        case .running(.transcribe, _, let c, _): c
        case .running(.align, _, _, let t): t.map { $0 + 1 }
        default: nil
        }
    }

    /// While a model downloads, its time left; otherwise the estimate from file progress.
    private func remainingText(elapsed: Double, progress: Double) -> String {
        if let d = item.download { return d.remaining.map { "≈ \(Formatting.clock($0))" } ?? "—" }
        return remaining(elapsed: elapsed, progress: progress).map { "≈ \(Formatting.clock($0))" } ?? "—"
    }

    /// Remaining ≈ elapsed / progress − elapsed, once there's enough to go on.
    private func remaining(elapsed: Double, progress: Double) -> Double? {
        guard progress > 0.03, elapsed > 1 else { return nil }
        return max(0, elapsed / progress - elapsed)
    }

    private func speed(elapsed: Double, progress: Double) -> String {
        if let dl = item.download { return dl.bytesPerSecond.map { "\(Formatting.size(Int64($0)))/s" } ?? "—" }
        guard let d = item.duration, progress > 0.03, elapsed > 1 else { return "—" }
        let x = d * progress / elapsed
        return x >= 10 ? "≈ \(Int(x.rounded()))× realtime" : String(format: "≈ %.1f× realtime", x)
    }
}

struct ProgressRing: View {
    var value: Double
    var indeterminate = false
    var size: CGFloat = 76
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.trackFill, lineWidth: 8)
            if indeterminate {
                Circle().inset(by: 4).trim(from: 0, to: 0.22)
                    .stroke(Palette.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true } }
            } else {
                Circle().inset(by: 4).trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(Palette.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: value)
            }
            Text(indeterminate ? "—" : Formatting.percent(value))
                .font(.system(size: size < 70 ? 16 : 20, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.blue)
        }
        .frame(width: size, height: size)
        .padding(4)
        .accessibilityLabel(indeterminate ? "Working" : "\(Formatting.percent(value)) done")
    }
}

/// One row per stage on a shared time axis: measured spans solid, the estimate hatched.
private struct Gantt: View {
    var item: FileItem
    var now: Date
    var remaining: Double?

    private let rows: [(Stage, String)] = [(.decode, "Decode"), (.load, "Load model"), (.transcribe, "Transcribe"), (.align, "Align")]

    var body: some View {
        let start = item.startedAt ?? now
        let elapsed = max(1, now.timeIntervalSince(start))
        let alignEstimate = item.wantsCues && item.stages[.align] == nil ? (remaining ?? 0) * 0.1 : 0
        let total = elapsed + (remaining ?? 0) + alignEstimate
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
            ForEach(rows, id: \.0) { stage, title in
                GridRow {
                    Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing).frame(width: 76, alignment: .trailing)
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.trackFill)
                            ForEach(Array(bars(stage, start: start, total: total, alignEstimate: alignEstimate).enumerated()), id: \.offset) { _, bar in
                                let x = CGFloat(bar.from / total) * w
                                let bw = max(4, CGFloat((bar.to - bar.from) / total) * w)
                                if bar.hatched {
                                    Stripes(color: bar.color.opacity(0.35), width: 4)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().strokeBorder(bar.color.opacity(0.8), lineWidth: 1))
                                        .frame(width: bw).offset(x: x)
                                } else {
                                    Capsule().fill(bar.color).frame(width: bw).offset(x: x)
                                }
                            }
                        }
                    }
                    .frame(height: 10)
                    Text(durationText(stage)).foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rows.map { "\($0.1) \(durationText($0.0))" }.joined(separator: ", "))
    }

    private struct Bar { var from: Double; var to: Double; var color: Color; var hatched: Bool }

    private func bars(_ stage: Stage, start: Date, total: Double, alignEstimate: Double) -> [Bar] {
        let elapsed = now.timeIntervalSince(start)
        if let span = item.stages[stage] {
            let from = span.start.timeIntervalSince(start)
            let to = (span.end ?? now).timeIntervalSince(start)
            let running = span.end == nil
            var out = [Bar(from: from, to: to, color: running ? Palette.blue : Palette.green, hatched: false)]
            if running, stage == .transcribe, let remaining {
                out.append(Bar(from: elapsed, to: elapsed + remaining, color: Palette.blue, hatched: true))
            }
            return out
        }
        if stage == .align, item.wantsCues {
            let from = elapsed + (remaining ?? 0)
            return [Bar(from: from, to: min(total, from + max(alignEstimate, total * 0.04)), color: Palette.gray, hatched: true)]
        }
        return []
    }

    private func durationText(_ stage: Stage) -> String {
        if stage == .align && !item.wantsCues { return "—" }
        guard let span = item.stages[stage] else { return "—" }
        return Formatting.took(span.duration(now: now))
    }
}

/// Inspector chunk grid: cell size adapts to the count (see `ChunkGridLayout`).
/// Small grids are numbered views; larger ones draw in one Canvas. Hovering a cell names its
/// chunk(s), audio range and state.
private struct ChunkGrid: View {
    var item: FileItem
    var total: Int
    var current: Int?
    var aligning: Bool
    @State private var hovered: Int?
    @State private var width: CGFloat = 300

    var body: some View {
        let layout = ChunkGridLayout(chunks: total, width: width)
        let cur = aligning ? total + 1 : current
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if layout.numbered {
                    numbered(layout, current: cur)
                } else {
                    Canvas { ctx, _ in
                        for i in 0..<layout.cells {
                            let o = layout.origin(cell: i)
                            let rect = CGRect(x: o.x, y: o.y, width: layout.cell, height: layout.cell)
                            let state = layout.state(cell: i, current: cur)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(fill(state)))
                            if state == .current {
                                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.25, dy: -1.25), cornerRadius: 3.5),
                                           with: .color(Palette.blue), lineWidth: 1.5)
                            }
                        }
                    }
                    .frame(height: layout.height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2) // room for the current cell's ring
            .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width - 4 }.onChange(of: g.size.width) { _, w in width = w - 4 } })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hovered = layout.cell(at: p.x - 2, p.y - 2) } else { hovered = nil }
            }
            .overlay(alignment: .topLeading) {
                if let h = hovered {
                    let o = layout.origin(cell: h)
                    FloatingCapsule(text: tooltip(layout, cell: h, current: cur), dot: nil)
                        .fixedSize()
                        .offset(x: min(o.x, max(0, width - 220)), y: o.y + layout.cell + 6)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(1)
            HStack(spacing: 14) {
                let done = max(0, min(total, (cur ?? 1) - 1))
                legend(Palette.green, "Done \(done)")
                legend(Palette.blue, "Working")
                legend(Self.wait, "Waiting \(max(0, total - done - (cur.map { $0 <= total ? 1 : 0 } ?? 0)))")
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(max(0, (current ?? 1) - 1)) of \(total) chunks done")
    }

    static let wait = Palette.gray.opacity(0.25)

    private func numbered(_ layout: ChunkGridLayout, current: Int?) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.cell), spacing: ChunkGridLayout.gap), count: layout.perRow)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: ChunkGridLayout.gap) {
            ForEach(0..<layout.cells, id: \.self) { i in
                let state = layout.state(cell: i, current: current)
                Text("\(i + 1)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(state == .current ? Palette.onFill : state == .done ? Palette.green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: layout.cell, height: layout.cell)
                    .background(state == .current ? Palette.blue : state == .done ? Palette.greenT : Palette.grayT,
                                in: RoundedRectangle(cornerRadius: 7))
                    .background(state == .current ? RoundedRectangle(cornerRadius: 8.5).strokeBorder(Palette.blue, lineWidth: 1.5).padding(-2) : nil)
            }
        }
    }

    private func fill(_ state: ChunkState) -> Color {
        switch state {
        case .done: Palette.green
        case .current: Palette.blue
        case .waiting: Self.wait
        }
    }

    /// "Chunk 47 · 22:31–23:01 · in progress", or "Chunks 46–48 · …" for a merged cell.
    private func tooltip(_ layout: ChunkGridLayout, cell: Int, current: Int?) -> String {
        let r = layout.chunkRange(cell: cell)
        var parts = [r.count == 1 ? "Chunk \(r.lowerBound)" : "Chunks \(r.lowerBound)–\(r.upperBound)"]
        let ranges = item.chunkRanges(total: total)
        if let d = item.duration, ranges.indices.contains(r.lowerBound - 1), ranges.indices.contains(r.upperBound - 1) {
            parts.append("\(Formatting.clock(ranges[r.lowerBound - 1].lowerBound * d))–\(Formatting.clock(ranges[r.upperBound - 1].upperBound * d))")
        }
        switch layout.state(cell: cell, current: current) {
        case .done: parts.append("done")
        case .current: parts.append("in progress")
        case .waiting: parts.append("waiting")
        }
        return parts.joined(separator: " · ")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// "Options used" at the bottom of a Done file: what it ran with, and Run Again with Changes….
private struct OptionsUsed: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionBand("Options used", trailing: "read-only", expanded: $expanded)
            if expanded {
                OptionsTags(options: item.displayedOptions, banded: false)
                Button("Run Again with Changes…") { model.runAgainWithChanges(item.id) }
                    .buttonStyle(FlatButtonStyle())
                    .padding(.horizontal, 18).padding(.bottom, 12)
                    .help("Adds a copy of this file to Ready with these options and Overwrite on")
            }
        }
    }
}

/// Tag capsules for the options a file ran with.
struct OptionsTags: View {
    var options: TranscribeOptions
    var banded = true
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if banded { SectionBand("Output & options", expanded: $expanded) }
            if expanded || !banded {
                VStack(alignment: .leading, spacing: 10) {
                    // Design L5 running summary: 1.7B | zh | library: md | copies: srt next to source.
                    FlowLayoutLeading(spacing: 6) {
                        CapsuleLabel(text: options.model == .accurate ? "1.7B" : "0.6B", tone: .aqua)
                        CapsuleLabel(text: options.languageCode ?? "auto", tone: .aqua)
                        CapsuleLabel(text: "library: " + (options.formats.isEmpty ? "transcript only"
                                                          : OutputFormat.ordered(options.formats).map(\.rawValue).joined(separator: " ")),
                                     tone: .blue, systemImage: "books.vertical")
                        if options.copyMode != .off {
                            CapsuleLabel(text: "copies: " + OutputFormat.ordered(options.copyFormats).map(\.rawValue).joined(separator: " ")
                                         + (options.copyMode == .nextToSource ? " next to source" : " in \(options.outputDirectory?.lastPathComponent ?? "folder")"),
                                         tone: .purple)
                        }
                        if options.copyMode != .off, options.overwrite { CapsuleLabel(text: "Replace", tone: .yellow) }
                    }
                    if !options.contextTerms.isEmpty {
                        FlowLayoutLeading(spacing: 6) {
                            Text("Context").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 24)
                            ForEach(options.contextTerms, id: \.self) { t in
                                Text(t).font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(Palette.cardFill, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Palette.hairline))
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
    }
}

/// Left-aligned wrapping layout.
struct FlowLayoutLeading: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Finished

private struct FinishedInspector: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    var result: FileResult
    @State private var showOutputs = true
    @State private var showTiming = true
    @State private var showNotices = true

    var body: some View {
        let duration = result.duration ?? item.duration
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MetricTile(title: "Duration", value: Formatting.clock(duration), tone: .purple)
                MetricTile(title: "Took", value: Formatting.clock(result.elapsed), tone: .blue)
                MetricTile(title: "Speed", value: Formatting.speed(duration: duration, elapsed: result.elapsed), tone: .green)
            }
            .padding(.horizontal, 14).padding(.bottom, 10)

            if let d = duration, d > 0, let e = result.elapsed {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    compareRow("Audio", fraction: 1, color: Palette.purple, value: d)
                    compareRow("Processing", fraction: e / max(d, e), color: Palette.blue, value: e)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .card(radius: 10)
                .padding(.horizontal, 14).padding(.bottom, 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Processing took \(Formatting.took(e)) for \(Formatting.clock(d)) of audio")
            }

            SectionBand("Outputs", expanded: $showOutputs)
            if showOutputs {
                VStack(spacing: 6) {
                    ForEach(result.orderedOutputs, id: \.path) { output in
                        OutputCard(format: output.format, path: output.path)
                    }
                    if result.orderedOutputs.isEmpty {
                        Text("No files were written.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            if result.orderedOutputs.contains(where: { $0.format.isCueFormat }), let timing = result.cueTiming {
                SectionBand("Subtitle timing", expanded: $showTiming)
                if showTiming {
                    TimingIndicator(timing: timing)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }

            if result.noticeCount > 0 {
                SectionBand("Notices", trailing: "\(result.noticeCount)", expanded: $showNotices)
                    .id("notices")
                if showNotices {
                    VStack(spacing: 6) {
                        ForEach(result.effectiveNotices, id: \.self) { NoticeCard(notice: $0) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }

    @ViewBuilder private func compareRow(_ title: String, fraction: Double, color: Color, value: Double) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.trackFill)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(min(1, fraction))))
                }
            }
            .frame(height: 8)
            Text(Formatting.clock(value)).foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

struct OutputCard: View {
    @Environment(AppModel.self) private var model
    var format: OutputFormat
    var path: String

    var body: some View {
        let url = URL(fileURLWithPath: path)
        HStack(spacing: 10) {
            FormatBadge(format: format)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(detail(url)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            Button { model.reveal([path]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Palette.controlFill, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .accessibilityLabel("Show \(url.lastPathComponent) in Finder")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .card(radius: 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(path) }
        .contextMenu {
            Button("Open") { model.open(path) }
            Button("Show in Finder") { model.reveal([path]) }
        }
    }

    private func detail(_ url: URL) -> String {
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return "Missing · \(folder)"
        }
        return "\(Formatting.size(size)) · \(folder)"
    }
}

struct TimingIndicator: View {
    var timing: CueTiming

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                segment(.aligned, "Aligned", Palette.green)
                segment(.mixed, "Mixed", Palette.yellow)
                segment(.estimated, "Estimated", Palette.orange)
            }
            .padding(2)
            .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 8))
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle timing: \(timing.rawValue). \(explanation)")
    }

    private func segment(_ t: CueTiming, _ title: String, _ dot: Color) -> some View {
        let on = t == timing
        return HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(title)
        }
        .font(.system(size: 12, weight: on ? .semibold : .regular))
        .foregroundStyle(on ? Color.primary : .secondary)
        .frame(maxWidth: .infinity).frame(height: 26)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 6).fill(Palette.cardFill)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
        }
    }

    private var explanation: String {
        switch timing {
        case .aligned: "Every cue follows word timing."
        case .mixed: "Most cues follow word timing. Some cues are approximate."
        case .estimated: "Cues are spread evenly over each chunk. Word timing isn’t available."
        }
    }
}

struct NoticeCard: View {
    var notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.yellow).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.sentence(notice.message)).font(.system(size: 12.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if let spans = notice.spans, !spans.isEmpty {
                    Text(spans.prefix(4).map { "\(Formatting.clock($0.lowerBound))–\(Formatting.clock($0.upperBound))" }.joined(separator: ", ")
                         + (spans.count > 4 ? " +\(spans.count - 4)" : ""))
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.yellowT, in: RoundedRectangle(cornerRadius: 9))
        .textSelection(.enabled)
    }

    private var icon: String {
        switch notice.code {
        case .timingEstimated: "clock.badge.exclamationmark"
        case .alignmentFailed: "waveform.badge.exclamationmark"
        case .truncated: "scissors"
        case nil: "exclamationmark.triangle"
        }
    }

    /// The CLI writes lower-case fragments ("subtitle timing is estimated …").
    static func sentence(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

// MARK: - Failed / Stopped

private struct ProblemCard: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: message == nil ? "stop.circle" : "xmark.octagon.fill")
                Text(message == nil ? "Stopped" : "Failed").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(message == nil ? Palette.gray : Palette.red)
            Text(message.map(StatusText.friendlyError) ?? "Stopped before it finished. Retry starts over.")
                .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let message, StatusText.friendlyError(message) != message {
                Text(message).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(6)
            }
            HStack(spacing: 8) {
                Button("Retry") { model.retry(item.id) }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                Button("Run Next") { model.runNext([item.id]) }.buttonStyle(FlatButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message == nil ? Palette.grayT : Palette.redT, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14).padding(.bottom, 14)
    }
}
