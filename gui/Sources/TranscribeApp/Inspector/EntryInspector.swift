import SwiftUI
import TranscribeKit

/// The inspector for a History entry: the Export card, timing, source
/// (with Locate… when it's gone), details, notices.
struct EntryInspector: View {
    @Environment(AppModel.self) private var model
    var entry: LibraryEntry
    @State private var notices: [Notice] = []
    /// The transcript's own notices: why timing is estimated.
    @State private var rawNotices: [Notice] = []
    @State private var loadedTranscript = false
    @State private var showFormats = true
    @State private var showTiming = true
    @State private var showSource = true
    @State private var showDetails = true
    @State private var showNotices = false

    var body: some View {
        let missing = model.sourceMissing(entry)
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(title: entry.title,
                            subtitle: "Transcribed \(HistoryDate.long(entry.updated)) · \(Formatting.clock(entry.duration))") {
                FileTypeIcon(kind: entry.kind, size: 48)
                    .opacity(missing ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if missing {
                            Circle().fill(Palette.gray).frame(width: 20, height: 20)
                                .overlay(Image(systemName: "questionmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white))
                                .offset(x: 5, y: 5)
                        }
                    }
            }

            band

            HStack(spacing: 8) {
                MetricTile(title: "Duration", value: Formatting.clock(entry.duration), tone: .purple)
                MetricTile(title: "Took", value: Formatting.clock(entry.elapsed), tone: .blue)
                MetricTile(title: "Speed", value: Formatting.speed(duration: entry.duration, elapsed: entry.elapsed), tone: .green)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)

            let estimated = loadedTranscript ? model.estimatedTiming(entry, notices: rawNotices) : nil
            SectionBand("Export", trailing: "from transcript.json", expanded: $showFormats)
            if showFormats {
                VStack(alignment: .leading, spacing: 10) {
                    ExportCard(entries: [entry], estimated: estimated)
                    if let estimated { EstimatedTimingNote(timing: estimated, entry: entry) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            if let timing = entry.cueTiming {
                SectionBand("Subtitle timing", expanded: $showTiming)
                if showTiming {
                    TimingIndicator(timing: timing).padding(.horizontal, 14).padding(.vertical, 10)
                }
            }

            SectionBand("Source", expanded: $showSource)
            if showSource { sourceCard(missing: missing).padding(.horizontal, 14).padding(.vertical, 10) }

            SectionBand("Details", expanded: $showDetails)
            if showDetails { details.padding(.horizontal, 18).padding(.vertical, 12) }

            if entry.noticeCount > 0 || !notices.isEmpty {
                SectionBand("Notices", trailing: "\(max(entry.noticeCount, notices.count))", expanded: $showNotices)
                    .id("notices")
                if showNotices {
                    VStack(spacing: 6) { ForEach(notices, id: \.self) { NoticeCard(notice: $0) } }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Transcribe Again…") { model.requestAgain([entry.id]) }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(missing || model.againRow(for: entry.id) != nil)
                    .help(missing ? "Transcribe Again needs the source file" : "Choose new options and replace this transcript")
                Button("Remove from History…") { model.removeRequest = [entry.id] }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.red)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 18).padding(.top, 14)
        }
        .task(id: "\(entry.id)-\(entry.revision)") {
            let url = model.library.transcriptURL(entry)
            let loaded = await Task.detached { LibraryTranscript.load(url) }.value
            if let loaded {
                notices = FileResult(cueTiming: loaded.cueTiming, warnings: loaded.warnings, notices: loaded.notices).effectiveNotices
                rawNotices = loaded.notices
            } else {
                rawNotices = []
            }
            loadedTranscript = true
        }
        .onChange(of: model.inspectorFocus) { _, f in if f == "notices" { showNotices = true } }
    }

    /// The gray scope band: In your library · folder, with the row's menu.
    private var band: some View {
        HStack(spacing: 6) {
            Text("In your library").font(.system(size: 12.5, weight: .bold))
            Text("· \(entry.folder)").font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Menu { HistoryMenu(targets: [entry.id]) } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 22)
                    .background(Palette.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Entry actions")
        }
        .foregroundStyle(Palette.gray)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.grayT, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func sourceCard(missing: Bool) -> some View {
        if missing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.folder").foregroundStyle(Palette.gray)
                    Text("Source not found").font(.system(size: 12.5, weight: .semibold))
                }
                Text("Last seen \(HistoryRow.abbreviate(entry.sourcePath)) · \(HistoryDate.short(entry.updated))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                Text("The transcript and every format still work. Transcribe Again needs the source.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Locate…") { model.locateSource(entry.id) }
                    .buttonStyle(FlatButtonStyle(height: 24))
                    .padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.grayT, in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(spacing: 10) {
                FileTypeIcon(kind: entry.kind, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.sourceName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(HistoryRow.abbreviate(entry.sourceURL.deletingLastPathComponent().path))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
                Button { model.revealSources([entry.id]) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26).background(Palette.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show Source in Finder")
                .accessibilityLabel("Show source in Finder")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .card(radius: 10)
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                Text("Model").foregroundStyle(.secondary)
                CapsuleLabel(text: entry.modelLabel == "1.7B" ? "1.7B Accurate" : entry.modelLabel == "0.6B" ? "0.6B Fast" : entry.modelLabel,
                             tone: .aqua, height: 22)
            }
            GridRow {
                Text("Language").foregroundStyle(.secondary)
                Text((entry.language ?? "—") + (entry.options.language == nil && entry.language != nil ? " · detected" : ""))
            }
            if !entry.options.context.isEmpty {
                GridRow {
                    Text("Context").foregroundStyle(.secondary)
                    Text(entry.options.context.joined(separator: ", ")).lineLimit(2)
                }
            }
            GridRow {
                Text("Library folder").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(entry.folder).lineLimit(1).truncationMode(.middle)
                    Button { model.revealEntries([entry.id]) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Show in Finder").accessibilityLabel("Show library folder in Finder")
                }
            }
        }
        .font(.system(size: 12.5))
    }
}

/// Several History entries selected.
struct EntriesInspector: View {
    @Environment(AppModel.self) private var model
    var entries: [LibraryEntry]
    @State private var showExport = true

    var body: some View {
        let withSource = entries.filter { !model.sourceMissing($0) }
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(systemImage: "books.vertical", tint: Palette.purple, title: "\(entries.count) entries",
                            subtitle: Formatting.longClock(entries.compactMap(\.duration).reduce(0, +)) + " of audio")
            HStack {
                Text("\(entries.count) entries selected").font(.system(size: 12.5, weight: .bold))
                Spacer()
            }
            .foregroundStyle(Palette.purple)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Palette.purpleT, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12).padding(.bottom, 14)
            SectionBand("Export", trailing: "\(entries.count) entries", expanded: $showExport)
            if showExport {
                ExportCard(entries: entries).padding(.horizontal, 14).padding(.vertical, 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Transcribe \(withSource.count) Again…") { model.requestAgain(withSource.map(\.id)) }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(withSource.isEmpty)
                Button("Remove \(entries.count) from History…") { model.removeRequest = entries.map(\.id) }
                    .buttonStyle(.plain).foregroundStyle(Palette.red).font(.system(size: 13))
            }
            .padding(.horizontal, 18).padding(.top, 14)
        }
    }
}
