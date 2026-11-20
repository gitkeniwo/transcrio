import AppKit
import SwiftUI
import TranscribeKit

/// The Models window (⌘⇧M): every model the worker knows, with download, cancel,
/// resume and remove. Data comes from the serve ops `models`, `download`, `cancel_download`
/// and `remove_model`.
struct ModelsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String? = DevSupport.environment["TRANSCRIBE_MODELS_SELECT"]

    var body: some View {
        let models = model.catalog.models
        HStack(spacing: 0) {
            ModelList(selectedID: $selectedID)
                .frame(width: 290)
            Divider()
            Group {
                if let m = models.first(where: { $0.id == selectedID }) ?? models.first {
                    ModelCardView(info: m).id(m.id)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.workerState == .stopped ? "Starting the worker…" : "Loading models…")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    Text("\(Formatting.size(model.catalog.totalBytesOnDisk)) on disk · \((model.cacheRoot.path as NSString).abbreviatingWithTildeInPath)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 330, alignment: .trailing)
                    Button("Show Cache in Finder") { revealCache() }
                }
            }
        }
        .navigationTitle("Models")
        .onAppear {
            model.refreshModels()
            if selectedID == nil { selectedID = models.first?.id }
        }
        .onChange(of: models.map(\.id)) { _, ids in if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first } }
        .alert(removeTitle, isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
            Button("Remove", role: .destructive) { model.confirmRemove() }
        } message: {
            Text(removeMessage)
        }
    }

    private var removeTitle: String { "Remove \(model.pendingRemoval?.name ?? "model")?" }

    private var removeMessage: String {
        guard let m = model.pendingRemoval else { return "" }
        var parts = ["Frees \(Formatting.size(m.bytesOnDisk))."]
        if m.loaded { parts.append("It is in use, so it is unloaded first.") }
        if let c = m.modelChoice {
            parts.append("Files set to \(c == .accurate ? "1.7B" : "0.6B") will download it again when they start.")
        } else if m.kind == .aligner {
            parts.append("SRT and VTT outputs will download it again when they start.")
        }
        return parts.joined(separator: " ")
    }

    private func revealCache() {
        let hub = model.cacheRoot.appendingPathComponent("hub")
        let url = FileManager.default.fileExists(atPath: hub.path) ? hub : model.cacheRoot
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - List

private struct ModelList: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedID: String?

    var body: some View {
        let speech = model.catalog.models.filter(\.isSpeechModel)
        let other = model.catalog.models.filter { !$0.isSpeechModel }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !speech.isEmpty {
                        QueueSectionHeader(title: "Speech recognition", count: speech.count)
                        ForEach(speech) { row($0) }
                    }
                    if !other.isEmpty {
                        QueueSectionHeader(title: "Subtitle alignment", count: other.count)
                        ForEach(other) { row($0) }
                    }
                }
                .padding(.horizontal, 10)
            }
            StorageBar()
                .padding(12)
        }
        .background(.regularMaterial)
    }

    private func row(_ m: ModelInfo) -> some View {
        let selected = selectedID == m.id
        return HStack(spacing: 10) {
            ModelIcon(info: m, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text("\(Formatting.size(m.sizeBytes)) · \(ModelText.role(m))")
                    .font(.system(size: 11.5)).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ModelStatusCapsule(state: model.catalog.state(of: m.id), selected: selected)
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = m.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// In use (blue), ↓ 42% (aqua), Downloaded (green), Not downloaded (gray outline), Partial (gray).
struct ModelStatusCapsule: View {
    var state: ModelCatalog.DisplayState
    var selected = false

    var body: some View {
        let (text, tone, outline): (String, Tone, Bool) = switch state {
        case .loaded: ("In use", .blue, false)
        case .downloading(let f, _, _): (f.map { "↓ \(Formatting.percent($0))" } ?? "↓ …", .aqua, false)
        case .downloaded: ("Downloaded", .green, false)
        case .partial: ("Partial", .gray, false)
        case .notDownloaded: ("Not downloaded", .gray, true)
        }
        Text(text)
            .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(selected ? Palette.selection : tone.fg)
            .background(selected ? Color.white : (outline ? .clear : tone.bg), in: Capsule())
            .overlay { if outline && !selected { Capsule().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1) } }
    }
}

/// Stacked bar, one color per model, with "7.9 GB used".
private struct StorageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let models = model.catalog.models.filter { $0.bytesOnDisk > 0 }
        let total = model.catalog.totalBytesOnDisk
        let scale = max(total, model.catalog.models.reduce(0) { $0 + $1.sizeBytes }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(models) { m in
                        Rectangle().fill(ModelIcon.color(m))
                            .frame(width: max(2, geo.size.width * CGFloat(m.bytesOnDisk) / CGFloat(scale)))
                            .help("\(m.name) · \(Formatting.size(m.bytesOnDisk))")
                    }
                    Spacer(minLength: 0)
                }
                .background(Palette.trackFill)
                .clipShape(Capsule())
            }
            .frame(height: 8)
            Text(caption(models, total: total)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ models: [ModelInfo], total: Int64) -> String {
        var s = "\(Formatting.size(total)) used"
        for m in model.catalog.models where m.status == .partial && model.catalog.downloads[m.id] == nil {
            s += " · \(m.kind == .aligner ? "aligner" : m.params.isEmpty ? m.name : m.params) is \(StatusText.gigabytes(m.bytesOnDisk, of: m.sizeBytes)) so far"
        }
        return s
    }
}

struct ModelIcon: View {
    var info: ModelInfo
    var size: CGFloat

    static func color(_ m: ModelInfo) -> Color {
        if m.kind == .aligner { return Palette.orange }
        return m.id == "0.6b" ? Palette.aqua : Palette.blue
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Self.color(info))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: info.kind == .aligner ? "text.line.first.and.arrowtriangle.forward" : "waveform")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

enum ModelText {
    static func role(_ m: ModelInfo) -> String {
        switch m.kind {
        case .aligner: "for srt, vtt"
        case .asr: m.id == "0.6b" ? "fast" : "accurate"
        case .other: m.kind.rawValue
        }
    }

    static func goodFor(_ m: ModelInfo) -> [String] {
        switch (m.kind, m.id) {
        case (.aligner, _): ["Subtitles", "Word timing"]
        case (_, "0.6b"): ["Quick drafts", "Clear speech", "Long backlogs"]
        default: ["Interviews and lectures", "Noisy or far-field audio", "Accents"]
        }
    }
}

// MARK: - Card

private struct ModelCardView: View {
    @Environment(AppModel.self) private var model
    var info: ModelInfo
    @State private var rate = RateSampler()

    var body: some View {
        let state = model.catalog.state(of: info.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                StatusBand(info: info, state: state, rate: rate)
                if let notes = info.notes, !notes.isEmpty {
                    Text(notes).font(.system(size: 13)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                tiles
                languages
                if !ModelText.goodFor(info).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Good for").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        FlowLayoutLeading(spacing: 6) {
                            ForEach(ModelText.goodFor(info), id: \.self) { CapsuleLabel(text: $0, tone: .aqua) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: state) { _, s in
            if case .downloading(_, let done, _) = s { rate.sample(done) } else { rate = RateSampler() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ModelIcon(info: info, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name).font(.system(size: 22, weight: .bold))
                Text("\(info.repo) · MLX").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            CapsuleLabel(text: info.kind == .aligner ? "Subtitle alignment" : "Speech recognition", tone: .gray)
            if let license = info.license { CapsuleLabel(text: license, tone: .gray) }
        }
    }

    private var tiles: some View {
        let speeds = model.history.recentSpeeds(model: info.id)
        return HStack(spacing: 10) {
            MetricTile(title: "On disk", value: info.bytesOnDisk > 0 ? Formatting.size(info.bytesOnDisk) : "—", tone: .purple,
                       caption: "measured in the cache")
            MetricTile(title: "Memory while running", value: info.ramGB.map { String(format: "≈ %.0f GB", $0) } ?? "—", tone: .aqua,
                       caption: "of \(Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())) GB on this Mac")
            ZStack(alignment: .bottomTrailing) {
                MetricTile(title: "Speed on this Mac",
                           value: speeds.isEmpty ? "No runs yet" : String(format: "%.1f×", locale: .current, speeds.reduce(0, +) / Double(speeds.count)),
                           tone: .blue,
                           caption: speeds.isEmpty ? "measured after the first file" : "real time, average of \(speeds.count) run\(speeds.count == 1 ? "" : "s")")
                if !speeds.isEmpty {
                    HStack(alignment: .bottom, spacing: 2) {
                        let top = speeds.max() ?? 1
                        ForEach(Array(speeds.enumerated()), id: \.offset) { i, s in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Palette.blue.opacity(i == speeds.count - 1 ? 1 : 0.55))
                                .frame(width: 5, height: max(3, 16 * s / top))
                        }
                    }
                    .padding(10)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 76)
    }

    @ViewBuilder private var languages: some View {
        if !info.languages.isEmpty {
            let aligned = Set(info.alignedLanguages.map(Languages.code(for:)))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Languages").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(info.languages.count)").font(.system(size: 12)).foregroundStyle(.tertiary)
                    Spacer()
                    if !aligned.isEmpty {
                        HStack(spacing: 5) {
                            Circle().strokeBorder(Palette.yellow, lineWidth: 1.5).frame(width: 10, height: 10)
                            Text("Precise subtitle timing (\(aligned.count))")
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                FlowLayoutLeading(spacing: 5) {
                    ForEach(info.languages, id: \.self) { lang in
                        let ringed = aligned.contains(Languages.code(for: lang))
                        Text(Languages.name(for: Languages.code(for: lang)))
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(Palette.grayT, in: Capsule())
                            .overlay { if ringed { Capsule().strokeBorder(Palette.yellow, lineWidth: 1.5) } }
                    }
                }
            }
        }
    }
}

/// Download speed from successive byte counts (the worker reports bytes, not a rate).
private struct RateSampler {
    var samples: [(Date, Int64)] = []

    mutating func sample(_ bytes: Int64) {
        let now = Date()
        if let last = samples.last, bytes < last.1 { samples = [] }
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 8 }
    }

    var bytesPerSecond: Double? {
        guard let a = samples.first, let b = samples.last, b.0.timeIntervalSince(a.0) > 0.8 else { return nil }
        return Double(b.1 - a.1) / b.0.timeIntervalSince(a.0)
    }
}

/// The status band and its actions, one per state.
private struct StatusBand: View {
    @Environment(AppModel.self) private var model
    var info: ModelInfo
    var state: ModelCatalog.DisplayState
    var rate: RateSampler

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let error = model.catalog.errors[info.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) { actions }
                .buttonStyle(FlatButtonStyle(height: 28))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 12))
    }

    private var tone: Tone {
        switch state {
        case .notDownloaded, .partial: .gray
        case .downloading: .aqua
        case .downloaded: .green
        case .loaded: .blue
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .notDownloaded:
            Text("\(Formatting.size(info.sizeBytes)) to download.\(info.ramGB.map { String(format: " Needs about %.0f GB of memory to run.", $0) } ?? "")")
                .font(.system(size: 13))
        case .partial(let bytes):
            Text("\(StatusText.gigabytes(bytes, of: info.sizeBytes)) on disk. The download was cancelled.")
                .font(.system(size: 13))
            ThinBar(value: Double(bytes) / Double(max(info.sizeBytes, 1)), tone: Palette.gray, height: 6)
        case .downloading(let f, let done, let total):
            HStack {
                Text(f.map(Formatting.percent) ?? "Starting…").font(.system(size: 13, weight: .semibold))
                Spacer()
                if total > 0 { Text(StatusText.gigabytes(done, of: total)).font(.system(size: 13)).monospacedDigit() }
            }
            .foregroundStyle(Palette.aqua)
            ThinBar(value: f ?? 0, tone: Palette.aqua, height: 6)
            HStack {
                if let r = rate.bytesPerSecond, r > 0 {
                    Text("\(Formatting.size(Int64(r)))/s")
                    Spacer()
                    if total > done { Text("about \(Formatting.clock(Double(total - done) / r)) left") }
                } else {
                    Text("Measuring speed…")
                    Spacer()
                }
            }
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.aqua)
        case .downloaded:
            Text("On disk · \(Formatting.size(info.bytesOnDisk)). Not loaded.").font(.system(size: 13)).foregroundStyle(Palette.green)
        case .loaded:
            Label {
                Text("In use. ").bold() + Text(unloadText)
            } icon: { Image(systemName: "cpu") }
            .font(.system(size: 13)).foregroundStyle(Palette.blue)
        }
    }

    private var unloadText: String {
        let s = model.idleUnloadSeconds
        if s <= 0 { return "Loaded in the worker; stays loaded while the app is open." }
        let m = Int(s / 60)
        return "Loaded in the worker; unloads after \(m) min idle."
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .notDownloaded:
            Button { model.download(info.id) } label: { Label("Download", systemImage: "arrow.down.to.line") }
                .buttonStyle(FlatButtonStyle(prominent: true, height: 28))
            pageButton
        case .partial:
            Button("Resume") { model.download(info.id) }
                .buttonStyle(FlatButtonStyle(prominent: true, height: 28))
            removeButton
        case .downloading:
            Button("Cancel") { model.cancelDownload(info.id) }
        case .downloaded, .loaded:
            Button("Show in Finder") { revealModel() }
            pageButton
            removeButton
        }
    }

    private var pageButton: some View {
        Button { if let url = info.url ?? URL(string: "https://huggingface.co/\(info.repo)") { NSWorkspace.shared.open(url) } } label: {
            Label("Model Page", systemImage: "arrow.up.right.square").labelStyle(TitleThenIcon())
        }
    }

    private var removeButton: some View {
        Button { model.requestRemove(info.id) } label: { Text("Remove…").foregroundStyle(Palette.red) }
            .disabled(model.modelInUseByJob(info.id))
            .help(model.modelInUseByJob(info.id) ? "The running file uses this model" : "Delete it from the cache")
    }

    private func revealModel() {
        let dir = model.cacheRoot.appendingPathComponent("hub").appendingPathComponent("models--" + info.repo.replacingOccurrences(of: "/", with: "--"))
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: dir.path) ? dir : model.cacheRoot])
    }
}

private struct TitleThenIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.font(.system(size: 10)) }
    }
}
