import SwiftUI
import TranscribeKit

/// A History entry in the center: the finished view, read from the entry
/// folder. The overview comes from `overview.json`, so it works when the source is gone.
struct EntryPreview: View {
    @Environment(AppModel.self) private var model
    var entry: LibraryEntry
    @State private var loaded: (key: String, result: FileResult, waveform: Waveform?)?
    @State private var failed = false

    private var key: String { "\(entry.id)-\(entry.revision)" }

    var body: some View {
        Group {
            if let loaded, loaded.key == key {
                EntryFinishedView(entry: entry, result: loaded.result, waveform: loaded.waveform)
            } else if failed {
                VStack(spacing: 0) {
                    CenterHeader(title: entry.title, capsule: CapsuleLabel(text: "In library", tone: .gray, systemImage: "books.vertical")) {}
                    ContentUnavailableView("Transcript not found", systemImage: "doc.questionmark",
                                           description: Text("transcript.json is missing from “\(entry.folder)” in the library folder."))
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            failed = false
            let store = model.library
            let e = entry
            let missing = model.sourceMissing(e)
            let value = await Task.detached { () -> (FileResult, Waveform?)? in
                guard let t = LibraryTranscript.load(store.transcriptURL(e)) else { return nil }
                return (t.result(entry: e, outputs: store.outputs(e)), LibraryOverview.load(store.overviewURL(e)))
            }.value
            guard let (result, overview) = value else { failed = true; return }
            loaded = (key, result, overview)
            if overview == nil, !missing, let wave = await MediaInfo.waveform(e.sourceURL) {
                loaded = (key, result, wave)
            }
        }
    }
}

/// Several History entries selected.
struct MultiEntryView: View {
    @Environment(AppModel.self) private var model
    var entries: [LibraryEntry]

    var body: some View {
        let withSource = entries.filter { !model.sourceMissing($0) }
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("\(entries.count) transcripts selected").font(.system(size: 17, weight: .semibold))
            Text(Formatting.longClock(entries.compactMap(\.duration).reduce(0, +)) + " of audio")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Show in Finder") { model.revealEntries(entries.map(\.id)) }
                Button("Transcribe \(withSource.count) Again…") { model.requestAgain(withSource.map(\.id)) }
                    .disabled(withSource.isEmpty)
                Button { model.removeRequest = entries.map(\.id) } label: { Text("Remove \(entries.count)…").foregroundStyle(Palette.red) }
            }
            .buttonStyle(FlatButtonStyle())
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
