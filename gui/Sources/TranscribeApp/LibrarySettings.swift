import AppKit
import SwiftUI
import TranscribeKit

/// Settings → Library: where the library lives, how transcripts are made,
/// what new transcripts prepare and copy, and the Timestamps export setting.
struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.alwaysAlign) private var alwaysAlign = true
    @State private var pending: PendingChange?
    @State private var failure: String?
    @State private var size: Int64?

    /// A folder chosen with Change…, waiting for Move / Start empty / Switch.
    struct PendingChange: Identifiable {
        let id = UUID()
        var folder: URL
        var existing: (count: Int, lastUsed: Date?)?
    }

    var body: some View {
        let library = model.library
        Form {
            Section {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Palette.blue)
                        Text(HistoryRow.abbreviate(library.root.path))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Change…") { choose() }
                            .disabled(!model.canChangeLibrary)
                    }
                }
                HStack {
                    Text(summary(count: library.entries.count))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { model.revealLibrary() }
                }
                if !model.canChangeLibrary && model.libraryMove == nil {
                    Text("You can change the location when nothing is transcribing or waiting.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let message = model.libraryUnavailable {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Palette.yellow)
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Every transcript is kept here with its formats. Transcrio only lists what it saved itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Always align subtitles", isOn: $alwaysAlign)
                Text("Each cue gets exact start and end times, so srt and vtt stay in sync. Adds about 10–20% to each run. Off: subtitle times are estimated from the text and can drift by a few seconds.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Transcripts")
            }

            Section {
                LabeledContent("Prepare in library") {
                    HStack(spacing: 4) {
                        ForEach(OutputFormat.preparable) { f in
                            let on = model.options.formats.contains(f)
                            Button(f.rawValue) {
                                var o = model.options
                                if on { o.formats.removeAll { $0 == f } } else { o.formats = OutputFormat.ordered(o.formats + [f]) }
                                model.options = o
                            }
                            .buttonStyle(MiniTileStyle(on: on))
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                Picker("Also save copies", selection: Binding(get: { model.options.copyMode }, set: { m in
                    var o = model.options
                    if m == .folder, o.outputDirectory == nil {
                        guard let dir = chooseCopiesFolder() else { return }
                        o.outputDirectory = dir
                    }
                    o.copyMode = m
                    model.options = o
                })) {
                    Text("Off").tag(CopyMode.off)
                    Text("Next to source").tag(CopyMode.nextToSource)
                    Text(model.options.outputDirectory.map { "Folder: \($0.lastPathComponent)" } ?? "Folder…").tag(CopyMode.folder)
                }
                Text(model.options.copyMode == .off
                     ? "Formats are made the moment a file finishes. Copies outside the library are off; change them per file in the inspector."
                     : CopyPlan.caption(options: model.options, sourceName: nil))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("New transcripts")
            }

            Section {
                Toggle("Timestamps in md and txt", isOn: Binding(get: { model.exportTimestamps }, set: { model.exportTimestamps = $0 }))
                Text("Also in the export menus. Save to Downloads never replaces a file: a name in use gets “ 2”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Exports")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: "\(library.root.path)-\(library.entries.count)") {
            let store = library
            size = await Task.detached(priority: .utility) { store.totalBytes() }.value
        }
        .sheet(item: $pending) { change in
            LibraryChangeSheet(change: change) { choice in
                pending = nil
                if let choice { apply(choice, folder: change.folder) }
            }
        }
        .alert("Couldn’t move the library", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text((failure ?? "") + "\n\nYour library is still at its old location.")
        }
    }

    private func summary(count: Int) -> String {
        let n = count == 1 ? "1 transcript" : "\(count) transcripts"
        guard let size else { return n }
        return "\(n) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private func chooseCopiesFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where copies of transcripts are saved"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Transcrio keeps your library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != model.library.root.standardizedFileURL else { return }
        pending = PendingChange(folder: url, existing: LibraryStore.existing(at: url))
    }

    private func apply(_ choice: LibraryLocationChoice, folder: URL) {
        switch choice {
        case .move:
            Task { if let message = await model.moveLibrary(to: folder) { failure = message } }
        case .empty, .switchTo:
            model.useLibrary(at: folder)
        }
    }
}

/// After Change…: move what's here, start empty, or switch to a library already there.
struct LibraryChangeSheet: View {
    @Environment(AppModel.self) private var model
    var change: LibrarySettings.PendingChange
    var done: (LibraryLocationChoice?) -> Void

    var body: some View {
        let count = model.library.entries.count
        let name = change.folder.lastPathComponent
        VStack(alignment: .leading, spacing: 12) {
            if let existing = change.existing {
                Text("“\(name)” already has a library").font(.system(size: 15, weight: .bold))
                Text("It holds \(existing.count == 1 ? "1 transcript" : "\(existing.count) transcripts")\(existing.lastUsed.map { ", last used \(HistoryDate.short($0))" } ?? ""). Switch to it? Your current library stays where it is, and you can switch back any time.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                    Button("Switch") { done(.switchTo) }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Use “\(name)” for your library?").font(.system(size: 15, weight: .bold))
                Text(count == 0
                     ? "New transcripts will be saved there."
                     : "Move copies your \(count == 1 ? "transcript" : "\(count) transcripts") there, then removes them from the old location. Start Empty leaves them where they are; switch back any time to see them again.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if count > 0 {
                        Button("Start Empty") { done(.empty) }
                        Button("Move \(count == 1 ? "Transcript" : "\(count) Transcripts")") { done(.move) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Use Folder") { done(.empty) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Modal while the library is copied. The queue doesn't start meanwhile.
struct LibraryMoveProgressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.libraryMove
        let p = state?.progress
        VStack(alignment: .leading, spacing: 12) {
            Text("Moving your library…").font(.system(size: 15, weight: .bold))
            Text("To \(HistoryRow.abbreviate(state?.destination.path ?? ""))")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ProgressView(value: fraction(p))
            HStack {
                Text(p.map { "\($0.entriesDone) of \($0.entriesTotal) transcripts" } ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(state?.cancelled == true ? "Cancelling…" : "Cancel") { model.cancelLibraryMove() }
                    .disabled(state?.cancelled == true)
                    .keyboardShortcut(.cancelAction)
            }
            Text("If you cancel, nothing changes: the library stays where it was.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled()
    }

    private func fraction(_ p: LibraryStore.MoveProgress?) -> Double {
        guard let p else { return 0 }
        if p.bytesTotal > 0 { return min(1, Double(p.bytesDone) / Double(p.bytesTotal)) }
        return p.entriesTotal > 0 ? Double(p.entriesDone) / Double(p.entriesTotal) : 0
    }
}

/// The mini format tiles in Settings → Library → Prepare in library.
private struct MiniTileStyle: ButtonStyle {
    var on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 40, height: 24)
            .foregroundStyle(on ? Palette.purple : .secondary)
            .background(on ? Palette.purpleT : Palette.cardFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Palette.purple : Palette.hairline, lineWidth: on ? 1.2 : 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
