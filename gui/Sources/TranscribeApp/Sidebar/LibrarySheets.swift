import SwiftUI
import TranscribeKit

/// Transcribe Again…. The sheet is the replace confirmation: nothing is
/// replaced until the new run ends with file_done.
struct TranscribeAgainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var request: AgainRequest
    @State private var choice: ModelChoice = .accurate
    @State private var language: String?
    @State private var context: [String] = []
    @State private var loaded = false

    private var entries: [LibraryEntry] { request.entries.compactMap { model.library[$0] } }
    private var first: LibraryEntry? { entries.first }

    var body: some View {
        let entries = entries
        let missing = entries.filter(model.sourceMissing)
        let ready = entries.count - missing.count
        VStack(alignment: .leading, spacing: 14) {
            Text(entries.count == 1 ? "Transcribe “\(entries[0].title)” again?" : "Transcribe \(entries.count) files again?")
                .font(.system(size: 15, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(intro(entries))
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !missing.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.folder").foregroundStyle(Palette.gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entries.count == 1 ? "Can’t transcribe again — source not found"
                                                : "\(missing.count) of \(entries.count) can’t be transcribed again — source not found")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Last seen at \(HistoryRow.abbreviate(missing[0].sourcePath))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.grayT, in: RoundedRectangle(cornerRadius: 9))
            }

            if ready > 0 {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Model", changed: first.map { choice.rawValue != $0.options.model } ?? false)
                        Picker("Model", selection: $choice) {
                            Text("1.7B Accurate").tag(ModelChoice.accurate)
                            Text("0.6B Fast").tag(ModelChoice.fast)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    GridRow {
                        label("Language", changed: first.map { language != $0.options.language } ?? false)
                        Menu(Languages.name(for: language)) {
                            Button("Auto-detect") { language = nil }
                            Divider()
                            ForEach(Languages.all) { l in Button(l.name) { language = l.code } }
                        }
                        .fixedSize()
                        .accessibilityLabel("Language")
                    }
                    GridRow(alignment: .top) {
                        label("Context", changed: first.map { context != $0.options.context } ?? false).padding(.top, 4)
                        TokenField(tokens: $context)
                    }
                }
                Text("Formats in the library are made again from the new transcript. Copies you saved outside the library aren’t changed.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(ready > 1 ? "Add \(ready) to Queue" : "Add to Queue") {
                    model.transcribeAgain(request.entries, model: choice, language: language, context: context)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ready == 0)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            guard !loaded, let e = first else { return }
            loaded = true
            choice = ModelChoice(rawValue: e.options.model) ?? .accurate
            language = e.options.language
            context = e.options.context
        }
    }

    private func close() {
        model.againRequest = nil
        dismiss()
    }

    private func intro(_ entries: [LibraryEntry]) -> String {
        guard let e = entries.first else { return "" }
        let when = entries.count == 1
            ? "the one from \(HistoryDate.short(e.updated)) (\(e.modelLabel)\(e.language.map { " · \($0)" } ?? ""))"
            : "the current ones"
        return "Choose new options. When the new run finishes, its transcript replaces \(when). If the run fails or you stop it, the current transcript stays."
    }

    private func label(_ text: String, changed: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.blue).frame(width: 6, height: 6).opacity(changed ? 1 : 0)
            Text(text).font(.system(size: 13, weight: changed ? .semibold : .regular))
                .foregroundStyle(changed ? Palette.blue : Color.primary)
        }
        .gridColumnAlignment(.leading)
    }
}

/// The library sheets and confirmations, attached to the main window.
struct LibraryPresentations: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        let removing = (model.removeRequest ?? []).compactMap { model.library[$0] }
        content
            .sheet(item: $model.againRequest) { TranscribeAgainSheet(request: $0) }
            .alert(removing.count == 1 ? "Remove “\(removing[0].title)” from History?" : "Remove \(removing.count) transcripts from History?",
                   isPresented: Binding(get: { model.removeRequest != nil }, set: { if !$0 { model.removeRequest = nil } })) {
                Button("Cancel", role: .cancel) { model.removeRequest = nil }
                Button("Remove", role: .destructive) { model.confirmRemoveEntries() }
            } message: {
                Text((removing.count == 1 ? "It won’t appear in Transcrio any more, and its library folder moves to the Trash."
                                          : "They won’t appear in Transcrio any more, and their library folders move to the Trash.")
                     + " Copies you saved elsewhere aren’t touched.")
            }
            // Locate… picked a different recording.
            .alert("This isn’t the same recording",
                   isPresented: Binding(get: { model.locateMismatch != nil }, set: { if !$0 { model.locateMismatch = nil } }),
                   presenting: model.locateMismatch) { m in
                Button("Choose Another…") {
                    model.locateMismatch = nil
                    DispatchQueue.main.async { model.locateSource(m.entry) }
                }
                Button("Use Anyway") {
                    model.locateMismatch = nil
                    model.relocate(m.entry, to: m.url, fingerprint: m.fingerprint)
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { model.locateMismatch = nil }
            } message: { m in
                Text("“\(m.url.lastPathComponent)” has different audio than “\(model.library[m.entry]?.sourceName ?? "the original")”. Use it anyway? Transcribe Again would then transcribe this file.")
            }
            // Settings → Library → Change… → Move: on the main window, so the app shows why
            // the queue waits.
            .sheet(isPresented: Binding(get: { model.libraryMove != nil }, set: { _ in })) {
                LibraryMoveProgressSheet()
            }
    }
}

extension View {
    func libraryPresentations() -> some View { modifier(LibraryPresentations()) }
}
