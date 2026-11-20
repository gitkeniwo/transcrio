import AppKit
import SwiftUI
import TranscribeKit

/// A History entry in the center: md·txt·srt·vtt·json from the
/// library folder (a format not made yet shows italic and is made when picked), the Timestamps
/// toggle, notices, Copy, Save ▾ and Show in Finder.
struct EntryFinishedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    var entry: LibraryEntry
    var result: FileResult
    var waveform: Waveform?

    /// nil: the default (first prepared format, else txt from the transcript).
    @State private var picked: OutputFormat? = DevSupport.previewFormat
    @State private var loaded: [String: FinishedView.Loaded] = [:]
    @State private var json: (key: String, lines: [String])?
    @State private var failure: String?
    @State private var preview = PreviewController()

    private var current: OutputFormat {
        picked ?? entry.preparedFormats.first { $0.takesTimestamps } ?? entry.preparedFormats.first ?? .txt
    }

    private var loadKey: String {
        "\(entry.id)-\(entry.revision)-\(current.rawValue)-\(current.takesTimestamps && model.exportTimestamps)"
    }

    private var duration: Double { result.duration ?? entry.duration ?? 0 }

    var body: some View {
        let doc = loaded[loadKey]
        VStack(spacing: 0) {
            CenterHeader(title: entry.title, capsule: CapsuleLabel(text: "In library", tone: .gray, systemImage: "books.vertical")) {
                Text("Transcribed \(HistoryDate.short(entry.updated))" + (entry.elapsed.map { " · took \(Formatting.took($0))" } ?? ""))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            toolbar(doc: doc)
            content(doc: doc)
        }
        .task(id: loadKey) { await load() }
        .task(id: "\(loadKey)-\(doc != nil)-\(model.searchingText ? model.searchQuery : "")") {
            // History's Text search: open at the first match, highlighted.
            guard doc != nil else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            preview.reveal(model.searchingText ? model.searchQuery : "")
        }
        .onChange(of: entry.id) { picked = nil; loaded = [:]; json = nil }
    }

    // MARK: Content

    @ViewBuilder private func content(doc: FinishedView.Loaded?) -> some View {
        let making = model.makingShown.contains(AppModel.makingKey(entry.id, current))
        if current == .json {
            if let json, json.key == loadKey {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(json.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let doc {
            if doc.timed, duration > 0 {
                TranscriptOverview(waveform: waveform, duration: duration, estimated: result.estimatedSpans(duration: duration),
                                   controller: preview)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                if waveform == nil, model.sourceMissing(entry) {
                    HStack(spacing: 6) {
                        Text("Overview needs the source file")
                        Text("·")
                        Button("Locate…") { model.locateSource(entry.id) }.buttonStyle(.link)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                }
            }
            TranscriptPreviewView(paragraphs: doc.paragraphs, isCues: doc.format.isCueFormat, controller: preview) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(doc.document.title ?? entry.title)
                        .font(.system(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) { ForEach(Array(capsules.enumerated()), id: \.offset) { $0.element } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let failure {
            ContentUnavailableView("Couldn’t make \(current.rawValue)", systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if making {
            MakingCard(format: current).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "Making vtt… From transcript.json. No model needed."
    struct MakingCard: View {
        var format: OutputFormat

        var body: some View {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Spinner(size: 13).foregroundStyle(Palette.purple)
                    Text("Making \(format.rawValue)…").font(.system(size: 14, weight: .semibold))
                }
                Text("From transcript.json. No model needed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(Palette.purpleT.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var capsules: [CapsuleLabel] {
        var caps: [CapsuleLabel] = []
        if let lang = result.language {
            caps.append(CapsuleLabel(text: entry.options.language == nil ? "\(lang) · detected" : lang, tone: .aqua))
        }
        if duration > 0 { caps.append(CapsuleLabel(text: Formatting.clock(duration), tone: .gray)) }
        caps.append(CapsuleLabel(text: entry.modelLabel, tone: .gray))
        return caps
    }

    // MARK: Loading

    private func load() async {
        failure = nil
        let key = loadKey
        let f = current
        let ts = f.takesTimestamps && model.exportTimestamps
        if f == .json {
            let url = model.library.transcriptURL(entry)
            let lines = await Task.detached { () -> [String] in
                guard let data = try? Data(contentsOf: url) else { return ["transcript.json is missing."] }
                let pretty = (try? JSONSerialization.jsonObject(with: data))
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
                return String(decoding: pretty ?? data, as: UTF8.self).components(separatedBy: "\n")
            }.value
            json = (key, lines)
            return
        }
        guard loaded[key] == nil else { return }
        let path: String
        if let url = model.library.cachedURL(entry, f, timestamps: ts) {
            path = url.path
        } else if picked == nil, f.takesTimestamps {
            // Nothing prepared: the transcript's own text, without making a file.
            path = ""
        } else {
            switch await model.ensureFormats(entry.id, [f], timestamps: ts) {
            case .failure(let e): failure = e.message; return
            case .success(let files):
                guard let url = files[f] else { failure = "The worker didn’t write \(f.rawValue)."; return }
                path = url.path
            }
        }
        let d = duration
        let timing = TranscribeKit.timingSource(for: result)
        let spans = result.estimatedSpans(duration: d)
        let inline = path.isEmpty ? result.segments.map(\.text).joined(separator: "\n\n") : nil
        let parsed = await Task.detached { () -> FinishedView.Loaded? in
            guard let raw = inline ?? (try? String(contentsOfFile: path, encoding: .utf8)) else { return nil }
            let doc = TranscriptParser.parse(raw, format: f, duration: d)
            return FinishedView.Loaded(format: f, path: path, raw: raw, document: doc,
                                       paragraphs: FinishedView.paragraphs(doc, timing: timing, estimated: spans))
        }.value
        if let parsed { loaded[key] = parsed } else { failure = "The file couldn’t be read." }
    }

    // MARK: Toolbar

    @ViewBuilder private func toolbar(doc: FinishedView.Loaded?) -> some View {
        let f = current
        let prepared = entry.preparedFormats
        // Narrow panes: the folder button goes first (Show in Finder stays in the Save menu),
        // then the segments become a menu.
        let roomy = paneWidth >= (result.noticeCount > 0 ? 770 : 700)
        HStack(spacing: 8) {
            if paneWidth >= 560 {
                FormatSegments(entry: entry, current: f) { picked = $0 }
            } else {
                Picker("Format", selection: Binding(get: { f }, set: { picked = $0 })) {
                    ForEach(OutputFormat.exportOrder, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            Button { model.exportTimestamps.toggle() } label: {
                Image(systemName: "clock").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.exportTimestamps ? Palette.onFill : Color.primary)
                    .frame(width: 30, height: 28)
                    .background(model.exportTimestamps ? Palette.blue : Palette.controlFill, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(!f.takesTimestamps)
            .help(model.exportTimestamps ? "Timestamps in md and txt: on" : "Timestamps in md and txt: off")
            .accessibilityLabel("Timestamps in md and txt")
            .accessibilityValue(model.exportTimestamps ? "On" : "Off")
            if result.noticeCount > 0 {
                Button {
                    if !model.inspectorVisible { model.togglePane(.inspector) }
                    model.inspectorFocus = "notices"
                } label: {
                    CapsuleLabel(text: "\(result.noticeCount)", tone: .yellow, systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .help(result.noticeCount == 1 ? "1 notice · show in the inspector" : "\(result.noticeCount) notices · show in the inspector")
            }
            Spacer(minLength: 4)
            Button {
                guard let doc else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc.raw, forType: .string)
                model.show(Toast(pane: .center, text: Toast.styled(WordCount.copiedMessage(doc.raw))))
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(doc == nil && f != .json)
            SplitButton(title: "Save", systemImage: "arrow.down.circle", help: "Save \(f.rawValue) to Downloads",
                        chevron: "chevron.down", action: { model.saveToDownloads([entry.id], formats: [f], pane: .center) }) {
                Button("Save \(f.rawValue) to Downloads") { model.saveToDownloads([entry.id], formats: [f], pane: .center) }
                Button("Save As…") { model.saveAs([entry.id], formats: [f], pane: .center) }
                Button("Save All Prepared Formats (\(prepared.count))") { model.saveToDownloads([entry.id], formats: prepared, pane: .center) }
                    .disabled(prepared.isEmpty)
                Divider()
                Button("Copy Text") { model.copyText(entry.id, format: f == .json ? nil : f, pane: .center) }
                Button("Show in Finder") { model.revealFormat(entry.id, f, pane: .center) }
                Divider()
                Toggle("Include Timestamps", isOn: Binding(get: { model.exportTimestamps }, set: { model.exportTimestamps = $0 }))
            }
            if roomy {
                Button { model.revealFormat(entry.id, f, pane: .center) } label: {
                    Image(systemName: "folder").frame(width: 16)
                }
                .buttonStyle(FlatButtonStyle())
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// md · txt · srt · vtt · json: a format not made yet is italic.
private struct FormatSegments: View {
    @Environment(AppModel.self) private var model
    var entry: LibraryEntry
    var current: OutputFormat
    var pick: (OutputFormat) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OutputFormat.exportOrder, id: \.self) { f in
                let made = f == .json || entry.formats[f.rawValue] != nil
                let on = f == current
                Button { pick(f) } label: {
                    HStack(spacing: 4) {
                        if model.makingShown.contains(AppModel.makingKey(entry.id, f)) { Spinner(size: 9, lineWidth: 1.4) }
                        Text(f.rawValue).italic(!made)
                    }
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : made ? Color.primary.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(on ? Palette.cardFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(made ? f.menuName : "\(f.menuName) · made from transcript.json when picked")
                .accessibilityLabel(f.rawValue)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}
