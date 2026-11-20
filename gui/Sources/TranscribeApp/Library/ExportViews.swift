import AppKit
import SwiftUI
import TranscribeKit

/// A 28 pt format chip: have / can make / making / failed,
/// the yellow estimated dot on srt and vtt, a picked ring, drag-out and its menu.
struct FormatChip: View {
    @Environment(AppModel.self) private var model
    var entry: LibraryEntry
    var format: OutputFormat
    var picked = false
    /// "md 2/2" with several entries selected.
    var count: String?
    var estimated: EstimatedTiming?
    var pane: Toast.Pane = .inspector
    var onPick: ((Bool) -> Void)?
    @State private var hovering = false

    var body: some View {
        let state = model.chipState(entry, format)
        let dot = (format == .srt || format == .vtt) && estimated != nil
        HStack(spacing: 5) {
            symbol(state)
            Text(count.map { "\(format.rawValue) \($0)" } ?? format.rawValue)
                .font(.system(size: 12.5, weight: .bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .foregroundStyle(foreground(state))
        .background { background(state) }
        .overlay {
            if picked { Capsule().strokeBorder(Palette.purple, lineWidth: 2) }
            if case .failed = state { Capsule().strokeBorder(Palette.red, lineWidth: 1.5) }
        }
        .overlay(alignment: .topTrailing) {
            if dot {
                Circle().fill(Palette.yellow).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Palette.cardFill, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            onPick?(flags.contains(.command))
        }
        .onDrag { model.dragProvider(entry.id, format) }
        .contextMenu { ChipMenu(entry: entry, format: format, estimated: estimated, pane: pane) }
        .help(help(state, estimated: dot ? estimated : nil))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(format.rawValue), \(accessibilityState(state))\(dot ? ", timing estimated" : "")")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private func symbol(_ state: FormatChipState) -> some View {
        switch state {
        case .making: Spinner(size: 11, lineWidth: 1.6)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
        case .have: Image(systemName: "doc").font(.system(size: 12, weight: .semibold))
        case .canMake: Image(systemName: "plus").font(.system(size: 11, weight: .bold))
        }
    }

    private func foreground(_ state: FormatChipState) -> Color {
        if hovering, state != .making { return Palette.onFill }
        switch state {
        case .have, .making: return Palette.purple
        case .canMake: return .secondary
        case .failed: return Palette.red
        }
    }

    @ViewBuilder private func background(_ state: FormatChipState) -> some View {
        if hovering, state != .making {
            Capsule().fill(Palette.purple)
        } else {
            switch state {
            case .have: Capsule().fill(Palette.purpleT)
            case .making: Capsule().fill(Palette.purpleT.opacity(0.75))
            case .canMake: Capsule().strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
            case .failed: Capsule().fill(Palette.redT)
            }
        }
    }

    private func help(_ state: FormatChipState, estimated: EstimatedTiming?) -> String {
        var lines: [String] = []
        switch state {
        case .have: lines.append("\(format.menuName) · in the library. Drag to Finder or another app.")
        case .canMake: lines.append("\(format.menuName) · made from transcript.json when you export it. No model needed.")
        case .making: lines.append("Making \(format.rawValue)…")
        case .failed(let m): lines.append("Couldn’t make \(format.rawValue): \(m)")
        }
        if let estimated { lines.append(estimated.short) }
        return lines.joined(separator: "\n")
    }

    private func accessibilityState(_ state: FormatChipState) -> String {
        switch state {
        case .have: "in library"
        case .canMake: "made on export"
        case .making: "making"
        case .failed: "failed"
        }
    }
}

/// The chip's menu.
struct ChipMenu: View {
    @Environment(AppModel.self) private var model
    var entry: LibraryEntry
    var format: OutputFormat
    var estimated: EstimatedTiming?
    var pane: Toast.Pane

    var body: some View {
        let name = ExportNaming.fileName(title: entry.title, format: format)
        Text(sizeLine(name))
        if let estimated, format == .srt || format == .vtt {
            Text("⚠︎ \(estimated.short)")
        }
        Divider()
        Button("Save to Downloads") { model.saveToDownloads([entry.id], formats: [format], pane: pane) }
        Button("Save As…") { model.saveAs([entry.id], formats: [format], pane: pane) }
        Button("Copy Text") { model.copyText(entry.id, format: format, pane: pane) }
            .disabled(format == .json)
        Button("Open") { model.openFormat(entry.id, format, pane: pane) }
        Button("Show in Finder") { model.revealFormat(entry.id, format, pane: pane) }
        Divider()
        Button("Make Again from Transcript") { model.makeAgain(entry.id, format, pane: pane) }
            .disabled(format == .json)
    }

    private func sizeLine(_ name: String) -> String {
        let url: URL? = format == .json ? model.library.transcriptURL(entry)
            : entry.formats[format.rawValue].map { model.library.folderURL(entry).appendingPathComponent($0) }
        guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return "\(name) · made when exported"
        }
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}

/// The toast capsule.
struct ToastView: View {
    @Environment(AppModel.self) private var model
    var toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.failed ? Palette.red : Palette.green)
            Text(toast.text)
                .font(.system(size: 12.5))
                .lineLimit(1).truncationMode(.middle)
            if !toast.reveal.isEmpty {
                Button("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting(toast.reveal)
                    model.toast = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.blue)
            }
            if let target = toast.saveAs {
                Button("Save As…") {
                    model.toast = nil
                    model.saveAs([target.entry], formats: [target.format], pane: toast.pane)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.blue)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Palette.cardFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .onAppear {
            NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: String(toast.text.characters), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
}

extension View {
    /// Shows the model's toast at the bottom center of this pane when it belongs here.
    func toastHost(_ pane: Toast.Pane) -> some View { modifier(ToastHost(pane: pane)) }
}

private struct ToastHost: ViewModifier {
    @Environment(AppModel.self) private var model
    var pane: Toast.Pane

    /// A hidden pane's toast shows in the sidebar.
    private func host(for p: Toast.Pane) -> Toast.Pane {
        switch p {
        case .center: model.centerVisible ? .center : .sidebar
        case .inspector: model.inspectorVisible ? .inspector : .sidebar
        case .sidebar: .sidebar
        }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = model.toast, host(for: t.pane) == pane {
                ToastView(toast: t)
                    .id(t.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// The yellow "Subtitle timing is estimated" note, worded from the transcript's notices.
struct EstimatedTimingNote: View {
    @Environment(AppModel.self) private var model
    var timing: EstimatedTiming
    /// The entry it's about: Align Subtitles is offered when alignment was off.
    var entry: LibraryEntry?

    var body: some View {
        let offer = entry.map { model.alignOffer($0, timing: timing) } ?? .none
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Palette.yellow)
                Text(offer == .none ? timing.message : "Subtitle timing is estimated: this file wasn’t aligned. srt and vtt can drift by a few seconds.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let entry, offer != .none {
                align(entry, offer: offer).padding(.leading, 24)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.yellowT, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func align(_ entry: LibraryEntry, offer: AlignOffer) -> some View {
        if let progress = model.aligning[entry.id] {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Spinner(size: 10, lineWidth: 1.5).foregroundStyle(Palette.yellow)
                    Text(progress.label).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Spacer(minLength: 4)
                    Button("Cancel") { model.cancelAlign(entry.id) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                if let f = progress.fraction { ThinBar(value: f, tone: Palette.yellow) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Aligning subtitles, \(progress.label)")
        } else if offer == .needsSource {
            HStack(spacing: 6) {
                Text("Align Subtitles needs the source file").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Button("Locate…") { model.locateSource(entry.id) }.buttonStyle(.link)
            }
            .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button("Align Subtitles") { model.alignSubtitles(entry.id) }
                    .buttonStyle(FlatButtonStyle(height: 24))
                    .disabled(model.libraryUnavailable != nil)
                    .help("Time srt and vtt from the source audio. Only the aligner runs; the text stays as it is.")
                if let why = model.alignFailures[entry.id] {
                    Text("Couldn’t align: \(why)")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The inspector's Export card: chips (click picks, ⌘-click picks several),
/// Timestamps, Save n Files to Downloads, Save As…, Copy Text, Show in Finder.
struct ExportCard: View {
    @Environment(AppModel.self) private var model
    var entries: [LibraryEntry]
    var estimated: EstimatedTiming?
    @State private var picked: Set<OutputFormat> = []

    var body: some View {
        @Bindable var model = model
        let several = entries.count > 1
        let formats = picked.isEmpty ? [model.lastExportFormat] : OutputFormat.ordered(picked)
        let fileCount = formats.count * entries.count
        VStack(alignment: .leading, spacing: 10) {
            if let first = entries.first {
                FlowLayoutLeading(spacing: 6) {
                    ForEach(OutputFormat.exportOrder, id: \.self) { f in
                        FormatChip(entry: first, format: f, picked: formats.contains(f),
                                   count: several ? "\(entries.filter { f == .json || $0.formats[f.rawValue] != nil }.count)/\(entries.count)" : nil,
                                   estimated: several ? nil : estimated) { additive in
                            pick(f, additive: additive)
                        }
                    }
                }
            }
            HStack {
                Text("Timestamps in md and txt").font(.system(size: 12.5))
                Spacer()
                Toggle("Timestamps in md and txt", isOn: $model.exportTimestamps)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            Button {
                model.saveToDownloads(entries.map(\.id), formats: formats, pane: .inspector)
            } label: {
                Label(fileCount == 1 ? "Save \(formats[0].rawValue) to Downloads" : "Save \(fileCount) Files to Downloads",
                      systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FlatButtonStyle(prominent: true, height: 30))
            HStack(spacing: 6) {
                Button("Save As…") { model.saveAs(entries.map(\.id), formats: formats, pane: .inspector) }
                    .buttonStyle(FlatButtonStyle())
                Button("Copy Text") {
                    if let e = entries.first { model.copyText(e.id, format: formats.first(where: { $0 != .json }), pane: .inspector) }
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(several)
                Spacer(minLength: 0)
                Button {
                    if entries.count == 1, let e = entries.first, formats.count == 1 {
                        model.revealFormat(e.id, formats[0], pane: .inspector)
                    } else {
                        model.revealEntries(entries.map(\.id))
                    }
                } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(FlatButtonStyle())
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            Text("Drag a format to Finder or another app.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .onChange(of: entries.map(\.id)) { picked = [] }
    }

    private func pick(_ f: OutputFormat, additive: Bool) {
        if additive {
            if picked.isEmpty { picked = [model.lastExportFormat] }
            if picked.contains(f), picked.count > 1 { picked.remove(f) } else { picked.insert(f) }
        } else {
            picked = [f]
            model.lastExportFormat = f
        }
    }
}
