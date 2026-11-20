import AppKit
import SwiftUI
import TranscribeKit

/// What the finished view shows: a Done queue row, or a History entry.
struct FinishedSource {
    /// Restarts loading when it changes.
    var key: String
    var title: String
    var stem: String
    var result: FileResult
    var duration: Double?
    var requestedLanguage: String?
    var waveform: Waveform?
    var entry: LibraryEntry?
    /// The queue row (live transcript position), when there is one.
    var itemID: FileItem.ID?

    init(item: FileItem, waveform: Waveform?) {
        key = item.id.uuidString
        title = item.name
        stem = item.url.deletingPathExtension().lastPathComponent
        result = item.result ?? FileResult()
        duration = item.duration
        requestedLanguage = item.requestedLanguage
        self.waveform = waveform
        itemID = item.id
    }

    init(entry: LibraryEntry, result: FileResult, waveform: Waveform?) {
        key = "\(entry.id)-\(entry.revision)"
        title = entry.title
        stem = entry.title
        self.result = result
        duration = entry.duration
        requestedLanguage = entry.options.language
        self.waveform = waveform
        self.entry = entry
    }
}

/// A2: the finished file. Tabs for the formats the CLI wrote, a 28 pt overview bound to the
/// preview's scroll position, and the transcript itself (see `TranscriptPreviewView`).
struct FinishedView: View {
    @Environment(AppModel.self) private var model
    var source: FinishedSource

    init(item: FileItem, waveform: Waveform?) { source = FinishedSource(item: item, waveform: waveform) }
    init(source: FinishedSource) { self.source = source }

    enum Tab: String, Identifiable, CaseIterable {
        case markdown = "Markdown", plain = "Plain Text", subtitles = "SRT"
        var id: String { rawValue }
    }

    @State private var tab: Tab?
    @State private var loaded: [Tab: Loaded] = [:]
    @State private var preview = PreviewController()

    struct Loaded: Equatable {
        var format: OutputFormat
        var path: String
        var raw: String
        var document: TranscriptDocument
        var paragraphs: [PreviewParagraph]
        var timed: Bool { paragraphs.contains { $0.time != nil } }
    }

    private var result: FileResult? { source.result }

    /// Which file backs each tab: Markdown falls back to txt, SRT to vtt. A library entry with
    /// no prepared text format previews transcript.json's paragraphs (an empty path).
    private var sources: [(Tab, OutputFormat, String)] {
        guard let outputs = result?.outputs else { return [] }
        var out: [(Tab, OutputFormat, String)] = []
        if let p = outputs["md"] { out.append((.markdown, .md, p)) }
        if let p = outputs["txt"] { out.append((.plain, .txt, p)) }
        if let p = outputs["srt"] { out.append((.subtitles, .srt, p)) } else if let p = outputs["vtt"] { out.append((.subtitles, .vtt, p)) }
        if source.entry != nil, !out.contains(where: { $0.0 != .subtitles }), result?.segments.isEmpty == false {
            out.insert((.plain, .txt, ""), at: 0)
        }
        return out
    }

    var body: some View {
        let available = sources
        let current = tab ?? available.first?.0
        let doc = current.flatMap { loaded[$0] }
        VStack(spacing: 0) {
            if let entry = source.entry {
                CenterHeader(title: entry.title, capsule: CapsuleLabel(text: "In library", tone: .gray, systemImage: "books.vertical")) {
                    Text("Transcribed \(HistoryDate.short(entry.updated))" + (entry.elapsed.map { " · took \(Formatting.took($0))" } ?? ""))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                CenterHeader(title: source.title, capsule: CapsuleLabel(text: "Done", tone: .green, systemImage: "checkmark")) {
                    if let r = result, let e = r.elapsed {
                        Text("Took \(Formatting.took(e)) · \(Formatting.speed(duration: r.duration ?? source.duration, elapsed: e))")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            toolbar(available: available, current: current, doc: doc)
            if let doc {
                if doc.timed, duration > 0 {
                    TranscriptOverview(waveform: source.waveform, duration: duration,
                                       estimated: estimatedRegions, controller: preview)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                }
                TranscriptPreviewView(paragraphs: doc.paragraphs, isCues: doc.format.isCueFormat, controller: preview) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(doc.document.title ?? source.stem)
                            .font(.system(size: 24, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) { ForEach(Array(capsules.enumerated()), id: \.offset) { $0.element } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if available.isEmpty {
                ContentUnavailableView("Nothing to preview",
                                       systemImage: "doc",
                                       description: Text("Only JSON was written. Open it from the inspector."))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(source.key)|\(current?.rawValue ?? "")") {
            guard let current, loaded[current] == nil, let src = available.first(where: { $0.0 == current }) else { return }
            let d = duration, timing = timingSource, spans = estimatedRegions
            let inline = src.2.isEmpty ? (result?.segments ?? []).map(\.text).joined(separator: "\n\n") : nil
            let parsed = await Task.detached { () -> Loaded? in
                guard let raw = inline ?? (try? String(contentsOfFile: src.2, encoding: .utf8)) else { return nil }
                let doc = TranscriptParser.parse(raw, format: src.1, duration: d)
                return Loaded(format: src.1, path: src.2, raw: raw, document: doc,
                              paragraphs: Self.paragraphs(doc, timing: timing, estimated: spans))
            }.value
            if let parsed { loaded[current] = parsed }
            // Coming from the live transcript: open where the reader was.
            if let id = source.itemID, let top = model.liveTopTime[id] {
                try? await Task.sleep(for: .milliseconds(80))
                preview.scrollTop(to: top)
                model.liveTopTime[id] = nil
            }
        }
    }

    private var duration: Double { result?.duration ?? source.duration ?? 0 }

    /// Where paragraph times come from: `file_done.segments`, else the output files.
    private var timingSource: any TranscriptTimingSource {
        guard let result else { return OutputFilesTimingSource(outputs: [:], duration: nil) }
        return TranscribeKit.timingSource(for: result)
    }

    /// Times from the shown file itself when it has them, otherwise from the timing source
    /// mapped onto its paragraphs.
    nonisolated static func paragraphs(_ doc: TranscriptDocument, timing: any TranscriptTimingSource,
                                       estimated: [ClosedRange<Double>]) -> [PreviewParagraph] {
        let times: [ClosedRange<Double>?]
        if doc.hasTimestamps {
            times = doc.paragraphs.map { p in p.start.map { $0...max($0, p.end ?? $0) } }
        } else {
            times = ParagraphTiming.assign(paragraphs: doc.paragraphs.map(\.text), segments: timing.segments())
        }
        return zip(doc.paragraphs, times).map { p, t in
            PreviewParagraph(text: p.text, time: t,
                             estimated: t.map { t in estimated.contains { $0.lowerBound < t.upperBound && $0.upperBound > t.lowerBound } } ?? false)
        }
    }

    @ViewBuilder
    private func toolbar(available: [(Tab, OutputFormat, String)], current: Tab?, doc: Loaded?) -> some View {
        HStack(spacing: 10) {
            if available.count > 1 {
                Picker("Format", selection: Binding(get: { current ?? .markdown }, set: { tab = $0 })) {
                    ForEach(available, id: \.0) { t, f, _ in
                        Text(t == .subtitles ? f.rawValue.uppercased() : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if let only = available.first {
                CapsuleLabel(text: only.0 == .subtitles ? only.1.rawValue.uppercased() : only.0.rawValue, tone: .gray)
            }
            if let n = result?.noticeCount, n > 0 {
                Button {
                    if !model.inspectorVisible { model.togglePane(.inspector) }
                    model.inspectorFocus = "notices"
                } label: {
                    CapsuleLabel(text: n == 1 ? "1 notice" : "\(n) notices", tone: .yellow, systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .help("Show notices in the inspector")
            }
            Spacer()
            Button {
                guard let doc else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc.raw, forType: .string)
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(doc == nil)
            Button {
                if let entry = source.entry {
                    model.revealEntries([entry.id])
                } else {
                    model.reveal(doc.map { [$0.path] } ?? result?.orderedOutputs.map(\.path) ?? [])
                }
            } label: {
                Image(systemName: "folder").frame(width: 16)
            }
            .buttonStyle(FlatButtonStyle())
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var capsules: [CapsuleLabel] {
        var caps: [CapsuleLabel] = []
        if let lang = result?.language {
            caps.append(CapsuleLabel(text: source.requestedLanguage == nil ? "\(lang) · detected" : lang, tone: .aqua))
        }
        if duration > 0 { caps.append(CapsuleLabel(text: Formatting.clock(duration), tone: .gray)) }
        if let m = result?.model { caps.append(CapsuleLabel(text: m.split(separator: "/").last.map(String.init) ?? m, tone: .gray)) }
        return caps
    }

    private var estimatedRegions: [ClosedRange<Double>] {
        guard let result, duration > 0 else { return [] }
        return result.estimatedSpans(duration: duration)
    }
}

