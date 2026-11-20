import SwiftUI
import TranscribeKit

/// Center pane: banner on top, then a view for the selection's state.
struct CenterPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding([.horizontal, .top], 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.25), value: model.banner)
    }

    @ViewBuilder private var content: some View {
        if let entry = model.selectedEntry {
            EntryPreview(entry: entry).id(entry.id).transition(.opacity)
        } else if model.historySelection.count > 1 {
            MultiEntryView(entries: model.selectedEntries)
        } else if model.selection.count > 1 {
            MultiFileView(items: model.selectedItems)
        } else if let item = model.selectedItem {
            let status = model.status(of: item)
            // A file that finishes cross-fades from the live transcript into the preview.
            Group {
                switch status {
                case .done, .doneWithNotices:
                    FinishedView(item: item, waveform: model.waveforms[item.id]).transition(.opacity)
                case .preparingModel(let m, let d):
                    RunningView(item: item, status: status, firstRun: m, download: d)
                case .failed, .stopped:
                    ProblemView(item: item, status: status).transition(.opacity)
                default:
                    RunningView(item: item, status: status).transition(.opacity)
                }
            }
            .id(item.id)
            .animation(.easeInOut(duration: 0.35), value: item.state.isTerminal)
        } else {
            EmptyDropView()
        }
    }
}

/// The 52 pt header row of the center pane.
struct CenterHeader<Trailing: View>: View {
    var title: String
    var capsule: CapsuleLabel?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .layoutPriority(-1)
            if let capsule { capsule.fixedSize() }
            Spacer(minLength: 8)
            trailing.lineLimit(1).truncationMode(.tail).layoutPriority(-2)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline.opacity(0.7)).frame(height: 1) }
    }
}

/// Failed or Stopped file: what happened and how to run it again.
struct ProblemView: View {
    @Environment(AppModel.self) private var model
    var item: FileItem
    var status: RowStatus

    private var stoppedAt: Double {
        if case .stopped(let t) = item.state { return t }
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            CenterHeader(title: item.name, capsule: item.state.isStopped
                         ? CapsuleLabel(text: "Stopped", tone: .gray)
                         : CapsuleLabel(text: "Failed", tone: .red, systemImage: "xmark")) {
                formatCapsules(item.options.formats)
            }
            VStack(spacing: 12) {
                WaveformOverviewStatic(waveform: model.waveforms[item.id], duration: item.duration)
                if let error = item.error {
                    BannerCard(tone: .red, systemImage: "xmark", title: "This file failed", message: error) {
                        Button("Retry") { model.retry(item.id) }
                            .buttonStyle(FlatButtonStyle(prominent: true))
                        Button("Show in Finder") { model.reveal([item.path]) }.buttonStyle(FlatButtonStyle())
                    }
                } else {
                    BannerCard(tone: .gray, systemImage: "stop.fill", title: "Stopped at \(Formatting.clock(stoppedAt))",
                               message: "This file was stopped before it finished. Unfinished output was removed; Retry starts over from the beginning.") {
                        Button("Retry") { model.retry(item.id) }
                            .buttonStyle(FlatButtonStyle(prominent: true))
                        Button("Run Next") { model.runNext([item.id]) }.buttonStyle(FlatButtonStyle())
                    }
                }
                Spacer()
            }
            .padding(16)
        }
    }
}

func formatCapsules(_ formats: [OutputFormat]) -> some View {
    FormatCapsules(formats: formats)
}

/// Format capsules in the center header; hidden below 440 pt (they are in the inspector too).
struct FormatCapsules: View {
    @Environment(\.paneWidth) private var paneWidth
    var formats: [OutputFormat]

    var body: some View {
        if paneWidth >= 440 {
            HStack(spacing: 6) {
                ForEach(formats) { f in CapsuleLabel(text: f.rawValue.uppercased(), tone: .gray) }
            }
        }
    }
}

/// A waveform strip inside a dotted panel, for files that aren't running.
struct WaveformOverviewStatic: View {
    var waveform: Waveform?
    var duration: Double?

    var body: some View {
        DottedPanel {
            VStack(spacing: 8) {
                HStack {
                    Text("Audio · \(Formatting.clock(duration))")
                    Spacer()
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                WaveformBars(waveform: waveform, count: 72, maxHeight: 54) { _ in Color(nsColor: .tertiaryLabelColor) }
                    .frame(height: 54)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

/// Vertical bars from a file's waveform (RMS, p95-normalised, log scale) over a time range
/// (fractions of the file). Flat bars when there is no waveform.
struct WaveformBars: View {
    var waveform: Waveform?
    var from: Double = 0
    var to: Double = 1
    var count: Int
    var maxHeight: CGFloat
    var minHeight: CGFloat = 4
    var spacing: CGFloat = 2
    var barWidth: CGFloat?
    var color: (Int) -> Color

    var body: some View {
        let values = waveform.map { $0.levels(count: count, from: from, to: to) } ?? Array(repeating: 0.3, count: max(count, 0))
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(i))
                    .frame(width: barWidth, height: max(minHeight, CGFloat(values[i]) * maxHeight))
                    .frame(maxWidth: barWidth == nil ? .infinity : barWidth)
            }
        }
        .accessibilityHidden(true)
    }
}
