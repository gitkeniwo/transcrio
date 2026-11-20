import SwiftUI

/// A3: drop target with the fanned file cards, format capsules and "how it works".
struct EmptyDropView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth

    var body: some View {
        VStack(spacing: 0) {
            CenterHeader(title: "Add Files", capsule: nil) {
                Text("⌘O to browse").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            DottedPanel(cornerRadius: 16, dashed: true) {
                VStack(spacing: 14) {
                    FannedCards().frame(height: 96)
                    Text("Drop audio or video files")
                        .font(.system(size: 20, weight: .bold))
                        .padding(.top, 4)
                    Text("Anything ffmpeg can read. Add as many as you like.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    FlowCapsules()
                        .frame(maxWidth: 400)
                        .padding(.vertical, 4)
                    Button("Choose Files…") { model.chooseFiles() }
                        .buttonStyle(FlatButtonStyle(prominent: true, height: 32))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)

            // Side by side, or stacked when the center pane is too narrow for three.
            (paneWidth >= 560 ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 6))) {
                HowCard(number: 1, tone: .orange, text: "Drop files to queue them")
                HowCard(number: 2, tone: .aqua, text: "Transcribed on this Mac")
                HowCard(number: 3, tone: .purple,
                        text: "Kept in your library")
            }
            .padding([.horizontal, .bottom], 16)
        }
    }
}

private struct FannedCards: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            card("waveform", "m4a", .orange).rotationEffect(.degrees(-10)).offset(x: 10)
            card("film", "mov", .purple).offset(y: -10).zIndex(1)
            card("doc.text", "md", .blue).rotationEffect(.degrees(10)).offset(x: -10)
        }
        .accessibilityHidden(true)
    }

    private func card(_ symbol: String, _ label: String, _ tone: Tone) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(tone.fg)
        .frame(width: 64, height: 80)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 7, y: 4)
    }
}

private struct FlowCapsules: View {
    let audio = ["mp3", "m4a", "wav", "flac", "ogg"]
    let video = ["mp4", "mov", "mkv"]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(audio, id: \.self) { FloatingCapsule(text: $0, dot: Palette.orange) }
            ForEach(video, id: \.self) { FloatingCapsule(text: $0, dot: Palette.purple) }
        }
    }
}

private struct HowCard: View {
    var number: Int
    var tone: Tone
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .foregroundStyle(tone.fg)
                .background(tone.bg, in: Circle())
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// Centered wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let r = rows.count - 1
            rows[r].width += rows[r].indices.isEmpty ? size.width : size.width + spacing
            rows[r].height = max(rows[r].height, size.height)
            rows[r].indices.append(i)
        }
        return rows
    }
}
