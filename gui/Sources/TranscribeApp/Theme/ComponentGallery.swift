import SwiftUI
import TranscribeKit

/// Every shared component in every state, light and dark side by side.
/// Shown with `TRANSCRIBE_GALLERY=1`, and as an Xcode preview.
struct ComponentGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GallerySheet().environment(\.colorScheme, .light)
                GallerySheet().environment(\.colorScheme, .dark)
            }
        }
    }
}

private struct GallerySheet: View {
    @Environment(\.colorScheme) private var scheme

    static let statuses: [(String, RowStatus)] = [
        ("added", .ready),
        ("queued 1st", .queued(ordinal: 1)),
        ("queued 2nd", .queued(ordinal: 2)),
        ("decode 0.0", .decoding),
        ("load", .loadingModel),
        ("load, quiet, not cached", .preparingModel(.asr1_7b, nil)),
        ("download 45%", .preparingModel(.asr0_6b, DownloadProgress(
            info: DownloadInfo(model: CachedModel.asr0_6b.rawValue, downloadedBytes: 810_000_000, totalBytes: 1_800_000_000),
            startedAt: Date(timeIntervalSince1970: 0), startBytes: 0, updatedAt: Date(timeIntervalSince1970: 60)))),
        ("transcribe 5/8", .transcribing(percent: 0.62, chunk: 5, totalChunks: 8)),
        ("align", .aligning(percent: 0.9)),
        ("file_done", .done),
        ("file_done + warnings", .doneWithNotices(2)),
        ("file_error", .failed("output exists (use --overwrite): x.md")),
        ("cancel sent", .stopping(percent: 0.4)),
        ("file_stopped", .stopped(at: 790)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scheme == .dark ? "Dark" : "Light").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.statuses.indices, id: \.self) { i in
                        let (label, status) = Self.statuses[i]
                        HStack(spacing: 10) {
                            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .trailing)
                            let progress = progress(status)
                            RowWaveform(levels: Self.levels, fraction: progress.fraction, tone: progress.tone)
                            StatusPill(status: status)
                            StatusPill(status: status, selected: true)
                                .padding(4)
                                .background(Palette.selection, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { FileTypeIcon(kind: .audio); FileTypeIcon(kind: .video); FileTypeIcon(kind: .video, size: 48) }
                    HStack {
                        CapsuleLabel(text: "Transcribing", tone: .blue, systemImage: "arrow.trianglehead.2.clockwise")
                        CapsuleLabel(text: "MD")
                        CapsuleLabel(text: "2 notices", tone: .yellow, systemImage: "exclamationmark.triangle")
                    }
                    HStack {
                        CapsuleLabel(text: "English · detected", tone: .aqua)
                        CapsuleLabel(text: "00:31", tone: .blue, height: 20)
                    }
                    HStack { FormatBadge(format: .md); FormatBadge(format: .srt); FormatBadge(format: .txt, style: .inline) }
                    HStack { TintChip(title: "Done", value: "2 / 6", tone: .purple); TintChip(title: "Total audio", value: "3:52:04", tone: .blue) }
                        .frame(width: 340)
                    HStack {
                        MetricTile(title: "Duration", value: "58:41", tone: .purple)
                        MetricTile(title: "Took", value: "3:16", tone: .blue)
                        MetricTile(title: "Speed", value: "18×", tone: .green)
                    }
                    .frame(width: 340)
                    SectionBand("Pipeline").frame(width: 360)
                    SectionBand("Environment", trailing: "Ready", trailingColor: Palette.green).frame(width: 360)
                    DottedPanel {
                        HStack { FloatingCapsule(text: "Chunk 5 of 8", dot: Palette.blue); FloatingCapsule(text: "4 done", dot: Palette.green) }
                            .padding(18)
                    }
                    ThinBar(value: 0.62).frame(width: 200)
                    Stripes(color: Palette.aqua, background: Palette.aquaT).frame(width: 300, height: 6).clipShape(Capsule())
                    HStack {
                        Button("Keep Going") {}.buttonStyle(FlatButtonStyle())
                        Button("Check Again") {}.buttonStyle(FlatButtonStyle(prominent: true))
                        Button("Stop") {}.buttonStyle(FlatButtonStyle(destructive: true))
                    }
                }
            }
            HStack(spacing: 6) {
                CapsuleLabel(text: "Queued", tone: .gray)
                CapsuleLabel(text: "Preparing", tone: .aqua)
                CapsuleLabel(text: "Working", tone: .blue)
                CapsuleLabel(text: "Done", tone: .green)
                CapsuleLabel(text: "Notice", tone: .yellow)
                CapsuleLabel(text: "Failed", tone: .red)
                CapsuleLabel(text: "Output", tone: .purple)
                CapsuleLabel(text: "SRT", tone: .orange)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
    }

    static let levels: [Float] = [0.3, 0.55, 0.8, 0.45, 0.65, 0.35, 0.6, 0.85, 0.4, 0.2, 0.5, 0.75, 0.6, 0.3, 0.45, 0.25]

    /// Gallery rows have no real file; fake how far each state got.
    private func progress(_ s: RowStatus) -> (fraction: Double, tone: WaveformTone) {
        switch s {
        case .transcribing(let p, _, _): (p, .working)
        case .aligning: (1, .working)
        case .done, .doneWithNotices: (1, .finished)
        case .failed: (0.4, .failed)
        case .stopping(let p): (p, .working)
        case .stopped: (0.3, .finished)
        default: (0, .track)
        }
    }
}

#Preview("Components") {
    ComponentGallery().frame(width: 1500, height: 640)
}
