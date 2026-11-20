import SwiftUI
import TranscribeKit

/// Two or more files selected: their waveforms side by side, an
/// option comparison table and the batch actions.
struct MultiFileView: View {
    @Environment(AppModel.self) private var model
    var items: [FileItem]

    private var total: Double { items.compactMap(\.duration).reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            CenterHeader(title: "\(items.count) files selected", capsule: CapsuleLabel(text: Formatting.longClock(total), tone: .gray)) {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    strips
                    comparison
                    actions
                }
                .padding(16)
            }
        }
    }

    // MARK: Waveform strips

    private var strips: some View {
        let shown = Array(items.prefix(4))
        let more = items.count - shown.count
        return DottedPanel {
            GeometryReader { geo in
                let gaps = CGFloat(shown.count - 1) * 10 + (more > 0 ? 70 : 0)
                let durations = shown.map { max($0.duration ?? 60, 1) }
                let sum = durations.reduce(0, +)
                HStack(spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                        let w = max(40, (geo.size.width - gaps) * durations[i] / sum)
                        VStack(alignment: .leading, spacing: 6) {
                            StretchWaveform(levels: model.waveforms[item.id]?.levels(count: max(4, Int(w / 4))))
                                .frame(height: 56)
                            Text(item.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(Formatting.clock(item.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(width: w)
                    }
                    if more > 0 {
                        Text("+ \(more) more").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 60)
                    }
                }
            }
            .frame(height: 96)
            .padding(14)
        }
    }

    // MARK: Comparison

    private var comparison: some View {
        let columns = Array(items.prefix(3))
        let rows: [(OptionField, (TranscribeOptions) -> String)] = [
            (.model, { $0.model == .accurate ? "Accurate · 1.7B" : "Fast · 0.6B" }),
            (.formats, { $0.formats.map(\.rawValue).joined(separator: " ") }),
            (.timestamps, { $0.timestamps ? "On" : "Off" }),
            (.language, { $0.language ?? "Auto-detect" }),
            (.outputDirectory, { $0.outputDirectory?.lastPathComponent ?? "Next to source" }),
            (.context, { $0.contextTerms.isEmpty ? "None" : $0.contextTerms.joined(separator: ", ") }),
            (.overwrite, { $0.overwrite ? "On" : "Off" }),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("Option").foregroundStyle(.secondary)
                ForEach(columns) { item in
                    Text(item.name).lineLimit(1).truncationMode(.middle).fontWeight(.semibold)
                }
            }
            .font(.system(size: 12))
            .padding(.vertical, 8)
            ForEach(rows, id: \.0) { field, value in
                Divider().gridCellUnsizedAxes(.horizontal)
                let values = columns.map { value($0.displayedOptions) }
                let differs = Set(items.map { value($0.displayedOptions) }).count > 1
                GridRow {
                    Text(field.label).foregroundStyle(.secondary)
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        HStack(spacing: 5) {
                            if differs { Circle().fill(Palette.blue).frame(width: 6, height: 6).accessibilityLabel("Differs") }
                            Text(v).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.system(size: 12.5))
                .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .card(radius: 12)
    }

    // MARK: Actions

    private var actions: some View {
        let startable = items.filter(model.queue.canQueue).map(\.id)
        let queued = items.filter { $0.state == .queued }.map(\.id)
        let removable = items.filter { !$0.state.isRunning }.map(\.id)
        return HStack(spacing: 8) {
            Button { model.start(startable) } label: {
                Label(startable.count == 1 ? "Queue 1 File" : "Queue \(startable.count) Files", systemImage: "play.fill")
            }
            .buttonStyle(FlatButtonStyle(prominent: true))
            .disabled(startable.isEmpty)
            Button("Run Next") { model.runNext(startable + queued) }
                .buttonStyle(FlatButtonStyle())
                .disabled(startable.isEmpty && queued.isEmpty)
            Button { model.remove(removable) } label: { Text("Remove from List").foregroundStyle(Palette.red) }
                .buttonStyle(FlatButtonStyle())
                .disabled(removable.isEmpty)
            Spacer()
        }
    }
}

/// Waveform bars stretched to fill their frame.
struct StretchWaveform: View {
    var levels: [Float]?

    var body: some View {
        Canvas { ctx, size in
            guard let levels, !levels.isEmpty else {
                ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)), with: .color(Palette.trackFill))
                return
            }
            let step = size.width / CGFloat(levels.count)
            let bar = max(1, step * 0.6)
            for (i, l) in levels.enumerated() {
                let h = max(2, CGFloat(l) * size.height)
                let r = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: bar / 2), with: .color(Palette.blue.opacity(0.75)))
            }
        }
        .accessibilityHidden(true)
    }
}
