import AppKit
import SwiftUI
import TranscribeKit

/// The inspector options: the defaults, one file's own options, or several files'
/// with Mixed values. Changes apply straight away (defaults are saved, see `OptionsStore`).
struct OptionsForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    @State private var showModel = true
    @State private var showOutput = true
    @State private var showRecognition = true
    @State private var showEnvironment = true

    var body: some View {
        let o = model.shownOptions
        let mixed = model.mixedOptions
        let changed = model.changedFields
        let formatDiffs = model.optionsScope == .defaults || mixed != nil ? [] : o.formatDifferences(from: model.options)
        VStack(alignment: .leading, spacing: 0) {
            SectionBand("Model", trailing: changed.contains(.model) ? "Changed" : nil, trailingColor: Palette.blue, expanded: $showModel)
            if showModel {
                ModelSection(selected: mixed?.model.isMixed == true ? nil : o.model, changed: changed.contains(.model))
                    .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 11)
            }

            SectionBand("Output", trailing: changed.contains(.formats) || changed.contains(.copies) ? "Changed" : nil,
                        trailingColor: Palette.blue, expanded: $showOutput)
            if showOutput {
                OutputSection(o: o, mixed: mixed, changed: changed, formatDiffs: formatDiffs) { f in toggle(f, mixed: mixed) }
                    .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 11)
            }

            SectionBand("Recognition", expanded: $showRecognition)
            if showRecognition {
                VStack(alignment: .leading, spacing: 8) {
                    FormRow("Language", changed: changed.contains(.language), reset: { model.resetField(.language) }) {
                        LanguageMenu(language: o.language, mixed: mixed?.language.isMixed == true)
                    }
                    AlignedChips(languages: model.backends?.defaultBackend?.alignedLanguages ?? [], selected: o.language)
                    if !model.alwaysAlign {
                        Text("Subtitle alignment is off in Settings; srt/vtt timing will be estimated.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if changed.contains(.context) { ResetButton { model.resetField(.context) } }
                            (Text("Context ") + Text(mixed?.context.isMixed == true ? "mixed — typing replaces every file’s terms" : "names and terms to listen for")
                                .font(.system(size: 11.5)).foregroundColor(.secondary))
                                .font(.system(size: 13, weight: changed.contains(.context) ? .semibold : .regular))
                                .foregroundStyle(changed.contains(.context) ? Palette.blue : Color.primary)
                        }
                        TokenField(tokens: Binding(get: { mixed?.context.isMixed == true ? [] : o.contextTerms },
                                                   set: { v in model.editOptions { $0.contextTerms = v } }))
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 11)
            }

            if model.optionsScope == .defaults {
                SectionBand("Environment", trailing: environmentSummary.text, trailingColor: environmentSummary.color, expanded: $showEnvironment)
                if showEnvironment {
                    EnvironmentGrid()
                        .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 11)
                }
            }
        }
        .disabled(!model.optionsEditable)
    }

    /// Toggles a prepared format (none is allowed since P2: the library keeps transcript.json).
    /// For several files a click turns it on for all of them, and a second click off.
    private func toggle(_ f: OutputFormat, mixed: MixedOptions?) {
        let on = mixed?.toggledFormat(f) ?? !model.shownOptions.formats.contains(f)
        model.editOptions { o in
            var formats = o.formats
            if on {
                if !formats.contains(f) { formats.append(f) }
            } else {
                formats.removeAll { $0 == f }
            }
            let order: [OutputFormat] = [.md, .txt, .srt, .vtt, .json]
            o.formats = formats.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
        }
    }

    private var environmentSummary: (text: String, color: Color) {
        if model.checkingEnvironment { return ("Checking…", .secondary) }
        guard let doctor = model.doctor else { return model.command == nil ? ("Not found", Palette.yellow) : ("Unknown", .secondary) }
        return doctor.ok ? ("Ready", Palette.green) : ("Needs attention", Palette.red)
    }
}

// MARK: - Scope band

/// 30 pt band under the inspector header saying what the options apply to, with the `…` menu.
struct ScopeBand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (title, detail, tone) = describe()
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .bold))
            if let detail { Text("· \(detail)").font(.system(size: 12.5)) }
            Spacer(minLength: 4)
            Menu { OptionsMenu() } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 22)
                    .background(tone.fg.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options actions")
        }
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private func describe() -> (String, String?, Tone) {
        switch model.optionsScope {
        case .defaults:
            return ("Defaults for new files", nil, .aqua)
        case .file:
            let n = model.changedFields.count
            return ("Options for this file", n == 0 ? "same as defaults" : "\(n) changed", .blue)
        case .files(let ids):
            let k = model.mixedOptions?.mixedCount ?? 0
            return ("Options for \(ids.count) files", k == 0 ? "all the same" : "\(k) mixed", .purple)
        case .readOnly:
            return ("Options used", "read-only", .gray)
        }
    }
}

/// The `…` menu of the scope band (also in the row context menu): copy, paste, apply, defaults.
struct OptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scope = model.optionsScope
        let editable = model.optionsEditable
        Button("Copy Options") { model.copyOptions() }
            .keyboardShortcut("c", modifiers: [.command, .option])
        Button("Paste Options") { model.pasteOptions() }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(!editable || model.clipboardOptions == nil)
        Divider()
        Button("Apply to Selected") { model.applyToSelected() }
            .disabled(model.applyToSelectedTargets.isEmpty)
        Button("Apply to All Ready & Queued (\(model.readyAndQueuedIDs.count))") { model.applyToAllReadyAndQueued() }
            .disabled(model.readyAndQueuedIDs.isEmpty)
        Divider()
        Button("Save as Defaults") { model.saveAsDefaults() }
            .disabled(scope == .defaults || model.shownOptions == model.options)
        Button("Reset to Defaults") { model.resetToDefaults() }
            .disabled(!editable || scope == .defaults)
    }
}

// MARK: - Model section

/// Downloaded models as cards; the rest behind "Other models (n)". A chosen model that isn't
/// downloaded shows as a dashed card with Download now.
private struct ModelSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// nil when several files disagree (no card selected).
    var selected: ModelChoice?
    var changed: Bool

    var body: some View {
        let downloaded = ModelChoice.allCases.filter(model.isDownloaded)
        let others = ModelChoice.allCases.filter { !model.isDownloaded($0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(downloaded) { c in
                    ModelCard(choice: c, selected: selected == c, size: size(c), dashed: false) { set(c) }
                }
                if let s = selected, !downloaded.contains(s) {
                    ModelCard(choice: s, selected: true, size: size(s), dashed: true) {}
                }
            }
            if let s = selected, !downloaded.contains(s) { downloadRow(s) }
            HStack(spacing: 8) {
                if changed { ResetButton { model.resetField(.model) } }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { c in
                            Button("\(name(c)) · \(Formatting.size(size(c)))") { set(c) }
                        }
                    } label: {
                        Text("Other models (\(others.count))").font(.system(size: 12))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(Palette.blue)
                    .fixedSize()
                }
                Spacer()
                Button("Manage Models…") { openWindow(id: "models") }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.blue)
                    .help("⌘⇧M")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model")
    }

    private func set(_ c: ModelChoice) { model.editOptions { $0.model = c } }

    private func name(_ c: ModelChoice) -> String { c == .accurate ? "1.7B Accurate" : "0.6B Fast" }

    private func size(_ c: ModelChoice) -> Int64 {
        model.catalog[c.rawValue]?.sizeBytes ?? (c == .accurate ? 4_400_000_000 : 1_800_000_000)
    }

    /// Aqua row under the dashed card: "Downloads 1.8 GB on first run" + Download now.
    @ViewBuilder private func downloadRow(_ c: ModelChoice) -> some View {
        let state = model.catalog.state(of: c.rawValue)
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
            switch state {
            case .downloading(let f, let done, let total):
                Text(total > 0 ? "Downloading · \(StatusText.gigabytes(done, of: total))" : "Downloading…")
                    .font(.system(size: 12)).monospacedDigit()
                if let f { ThinBar(value: f, tone: Palette.aqua).frame(width: 50) }
                Spacer(minLength: 4)
                Button("Cancel") { model.cancelDownload(c.rawValue) }.buttonStyle(FlatButtonStyle(height: 24))
            default:
                Text("Downloads \(Formatting.size(size(c))) on first run").font(.system(size: 12))
                Spacer(minLength: 4)
                Button("Download now") { model.download(c.rawValue) }
                    .buttonStyle(FlatButtonStyle(prominent: true, height: 24))
            }
        }
        .foregroundStyle(Palette.aqua)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.aquaT, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// `arrow.counterclockwise` before a changed control: back to the default value.
struct ResetButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.blue)
        .help("Reset to the default")
        .accessibilityLabel("Reset to default")
    }
}

/// A switch, or for mixed values a centred knob over the track; a click turns it on for all.
struct MixedSwitch: View {
    var label: String
    var value: Bool?
    var set: (Bool) -> Void

    var body: some View {
        if let value {
            Toggle(label, isOn: Binding(get: { value }, set: set)).labelsHidden().toggleStyle(.switch).controlSize(.small)
        } else {
            Button { set(true) } label: {
                Capsule().fill(Palette.trackFill)
                    .frame(width: 32, height: 18)
                    .overlay(Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).frame(width: 15, height: 15))
            }
            .buttonStyle(.plain)
            .help("Mixed: click to turn on for every file")
            .accessibilityLabel("\(label), mixed")
        }
    }
}

private struct LanguageMenu: View {
    @Environment(AppModel.self) private var model
    var language: String?
    var mixed: Bool

    var body: some View {
        Menu {
            Button("Auto-detect") { model.editOptions { $0.language = nil } }
            Divider()
            ForEach(Languages.all) { l in Button(l.name) { model.editOptions { $0.language = l.code } } }
        } label: {
            if mixed { Text("Mixed").italic().foregroundStyle(.secondary) } else { Text(Languages.name(for: language)) }
        }
        .fixedSize()
        .accessibilityLabel("Language")
    }
}

/// Label on the left, control on the right, 30 pt tall. A changed field gets a blue dot, a blue
/// semibold label and a reset arrow before the control.
struct FormRow<Control: View>: View {
    var title: String
    var changed: Bool
    var reset: (() -> Void)?
    @ViewBuilder var control: Control

    init(_ title: String, changed: Bool = false, reset: (() -> Void)? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.changed = changed
        self.reset = reset
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 6) {
            if changed { Circle().fill(Palette.blue).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(title)
                .font(.system(size: 13, weight: changed ? .semibold : .regular))
                .foregroundStyle(changed ? Palette.blue : Color.primary)
            Spacer()
            if changed, let reset { ResetButton(action: reset) }
            control
        }
        .frame(minHeight: 30)
        .accessibilityValue(changed ? "Changed from defaults" : "")
    }
}

private struct ModelCard: View {
    var choice: ModelChoice
    var selected: Bool
    var size: Int64
    /// Chosen but not downloaded.
    var dashed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(choice == .accurate ? "1.7B" : "0.6B").font(.system(size: 16, weight: .bold))
                    Spacer()
                    Circle()
                        .strokeBorder(selected ? Palette.blue : Color(nsColor: .tertiaryLabelColor), lineWidth: selected ? 4 : 1.5)
                        .frame(width: 14, height: 14)
                }
                Text(choice == .accurate ? "Accurate" : "Fast")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Palette.blue : .secondary)
                Group {
                    if dashed {
                        Label("Not downloaded", systemImage: "arrow.down.to.line")
                            .labelStyle(TintedIconLabel(tint: Palette.aqua))
                    } else {
                        Label("Downloaded · \(Formatting.size(size))", systemImage: "checkmark")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected && !dashed ? Palette.blueT : Palette.cardFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                } else {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Palette.blue : Palette.hairline, lineWidth: selected ? 2 : 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice == .accurate ? "1.7B Accurate" : "0.6B Fast")\(dashed ? ", not downloaded" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct TintedIconLabel: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

struct FormatTile: View {
    var format: OutputFormat
    var state: MixedOptions.FormatState
    var changed = false
    var compact = false
    var action: () -> Void

    private var symbol: String {
        switch format {
        case .md: "doc.text"
        case .txt: "text.alignleft"
        case .srt: "captions.bubble"
        case .vtt: "text.bubble"
        case .json: "curlybraces"
        }
    }

    var body: some View {
        let on = state == .on
        let mixedCaption: String? = if case .mixed(let n, let of) = state { "\(n) of \(of)" } else { nil }
        Button(action: action) {
            let layout = compact ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 3))
            layout {
                Image(systemName: symbol).font(.system(size: 15))
                Text(format.rawValue).font(.system(size: 12, weight: .semibold))
                if let mixedCaption { Text(mixedCaption).font(.system(size: 9.5, weight: .semibold)) }
            }
            .frame(maxWidth: .infinity).frame(height: compact ? 40 : 50)
            .foregroundStyle(on || mixedCaption != nil ? Palette.purple : .secondary)
            .background {
                if mixedCaption != nil {
                    Stripes(color: Palette.purple.opacity(0.14), background: Palette.cardFill, width: 5)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    RoundedRectangle(cornerRadius: 9).fill(on ? Palette.purpleT : Palette.cardFill)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(on || mixedCaption != nil ? Palette.purple : Palette.hairline, lineWidth: on ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if changed { Circle().fill(Palette.blue).frame(width: 7, height: 7).padding(5).accessibilityHidden(true) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(format.rawValue.uppercased())
        .accessibilityValue(mixedCaption.map { "Mixed, \($0)" } ?? (changed ? "Changed from defaults" : ""))
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityHint("Toggles this output format")
    }
}

/// Output: the library line, "Prepare in library" tiles (none
/// allowed), and "Also save copies" with its own formats, Timestamps and Replace.
private struct OutputSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    @Environment(\.openSettings) private var openSettings
    var o: TranscribeOptions
    var mixed: MixedOptions?
    var changed: Set<OptionField>
    var formatDiffs: Set<OutputFormat>
    var toggle: (OutputFormat) -> Void

    var body: some View {
        // 4 across, or 2 × 2 with icon and label side by side below 330 pt.
        let compact = paneWidth < 330
        VStack(alignment: .leading, spacing: 8) {
            libraryLine
            HStack(spacing: 6) {
                if changed.contains(.formats) { ResetButton { model.resetField(.formats) } }
                Text("Prepare in library").font(.system(size: 13, weight: changed.contains(.formats) ? .semibold : .regular))
                    .foregroundStyle(changed.contains(.formats) ? Palette.blue : Color.primary)
                Spacer()
                if mixed == nil, o.formats.isEmpty {
                    Text("transcript only").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: compact ? 2 : 4), spacing: 6) {
                ForEach(OutputFormat.preparable) { f in
                    let state: MixedOptions.FormatState = mixed?.format(f) ?? (o.formats.contains(f) ? .on : .off)
                    FormatTile(format: f, state: state, changed: formatDiffs.contains(f), compact: compact) { toggle(f) }
                }
            }
            Text("Made the moment a file finishes, so they are in the library folder. Other formats are made when you export them.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FormRow("Also save copies", changed: changed.contains(.copies), reset: { model.resetField(.copies) }) {
                CopyModeMenu(mode: mixed.map { $0.copyMode.value } ?? o.copyMode, directory: o.outputDirectory)
            }
            .padding(.top, 2)
            if let mixed, mixed.copyMode.isMixed || mixed.copyFormats.isMixed {
                Text("Copy options show once every selected file saves copies the same way.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if o.copyMode != .off {
                copies
            }
        }
    }

    /// `blueT` card: Saved to your library · Every format can be exported later · Settings…
    private var libraryLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical.fill").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved to your library").font(.system(size: 12.5, weight: .semibold))
                Text("Every format can be exported later").font(.system(size: 11.5)).opacity(0.85)
            }
            Spacer(minLength: 4)
            Button("Settings…") {
                model.settingsTab = "library"
                openSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Palette.blue)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Palette.blueT, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    /// The copies sub-block: formats (at least one), Timestamps in md and txt, Replace.
    private var copies: some View {
        let formats = mixed.flatMap { $0.copyFormats.value.map(Array.init) } ?? o.copyFormats
        let name = model.optionsSourceName
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(OutputFormat.exportOrder, id: \.self) { f in
                    let on = formats.contains(f)
                    Button {
                        model.editOptions { o in
                            if on {
                                guard o.copyFormats.count > 1 else { NSSound.beep(); return }
                                o.copyFormats.removeAll { $0 == f }
                            } else {
                                o.copyFormats = OutputFormat.ordered(o.copyFormats + [f])
                            }
                        }
                    } label: {
                        Text(f.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).frame(height: 24)
                            .foregroundStyle(on ? Palette.purple : .secondary)
                            .background(on ? Palette.purpleT : Palette.cardFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Palette.purple : Palette.hairline, lineWidth: on ? 1.2 : 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy \(f.rawValue)")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            FormRow("Timestamps in md and txt", changed: changed.contains(.timestamps), reset: { model.resetField(.timestamps) }) {
                MixedSwitch(label: "Timestamps in md and txt", value: mixed.map { $0.timestamps.value } ?? o.timestamps) { v in
                    model.editOptions { $0.timestamps = v }
                }
            }
            FormRow("Replace existing files", changed: changed.contains(.overwrite), reset: { model.resetField(.overwrite) }) {
                MixedSwitch(label: "Replace existing files", value: mixed.map { $0.overwrite.value } ?? o.overwrite) { v in
                    model.editOptions { $0.overwrite = v }
                }
            }
            Text(CopyPlan.caption(options: o, sourceName: name))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Palette.panelFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.hairline))
    }
}

/// Off / Next to source / Folder…
private struct CopyModeMenu: View {
    @Environment(AppModel.self) private var model
    /// nil: mixed.
    var mode: CopyMode?
    var directory: URL?

    var body: some View {
        Menu {
            Button("Off") { model.editOptions { $0.copyMode = .off } }
            Button("Next to source") { model.editOptions { $0.copyMode = .nextToSource } }
            Divider()
            if let directory {
                Button(directory.lastPathComponent) { model.editOptions { $0.copyMode = .folder } }
            }
            Button("Folder…") { choose() }
        } label: {
            if let mode {
                Text(mode == .folder ? (directory?.lastPathComponent ?? "Folder…") : mode.label)
            } else {
                Text("Mixed").italic().foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help(mode == .folder ? (directory?.path ?? "") : "Copies of each transcript outside the library")
        .accessibilityLabel("Also save copies")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where copies of transcripts are saved"
        if panel.runModal() == .OK, let url = panel.url {
            model.editOptions { $0.outputDirectory = url; $0.copyMode = .folder }
        }
    }
}

/// Languages with word-level alignment, from `backends --json`.
private struct AlignedChips: View {
    var languages: [String]
    var selected: String?
    @State private var showAll = false

    var body: some View {
        let codes = languages.map(Languages.code(for:))
        let shown = showAll ? codes : Array(codes.prefix(8))
        FlowLayoutLeading(spacing: 4) {
            Text("Precise subtitle timing:").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 18)
            if codes.isEmpty {
                Text("unknown until the CLI is found").font(.system(size: 11)).foregroundStyle(.tertiary).frame(height: 18)
            }
            ForEach(shown, id: \.self) { code in
                Text(code)
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 6).frame(height: 18)
                    .foregroundStyle(Palette.green)
                    .background(Palette.greenT, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.green, lineWidth: code == selected ? 1.5 : 0))
                    .help(Languages.name(for: code))
            }
            if codes.count > shown.count {
                Button("+\(codes.count - shown.count)") { showAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 6).frame(height: 18)
                    .foregroundStyle(Palette.green)
                    .background(Palette.greenT, in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Precise subtitle timing for \(languages.joined(separator: ", "))")
    }
}

/// Capsule tokens plus a text field; Return or comma adds a term.
struct TokenField: View {
    @Binding var tokens: [String]
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayoutLeading(spacing: 5) {
            ForEach(tokens, id: \.self) { t in
                HStack(spacing: 4) {
                    Text(t)
                    Button { tokens.removeAll { $0 == t } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(t)")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.leading, 9).padding(.trailing, 6).frame(height: 22)
                .foregroundStyle(Palette.aqua)
                .background(Palette.aquaT, in: Capsule())
            }
            TextField("Add a term…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(minWidth: 90, maxWidth: 200)
                .frame(height: 22)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: draft) { _, v in if v.contains(",") { commit() } }
                .onKeyPress(.delete) {
                    guard draft.isEmpty, !tokens.isEmpty else { return .ignored }
                    tokens.removeLast()
                    return .handled
                }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.blue : Palette.hairline, lineWidth: focused ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context terms")
    }

    private func commit() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for p in parts where !tokens.contains(p) { tokens.append(p) }
        draft = ""
    }
}

/// ffmpeg, MLX, CLI and Model status from `doctor --json` and the HF cache check.
private struct EnvironmentGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth

    var body: some View {
        let doctor = model.doctor
        // 2 × 2, or a single column below 330 pt.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: paneWidth < 330 ? 1 : 2), spacing: 6) {
            if let ffmpeg = doctor?.ffmpeg {
                EnvCard(state: .ok, title: "ffmpeg", detail: abbreviate(URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().path))
            } else {
                EnvCard(state: doctor == nil ? .unknown : .bad, title: "ffmpeg", detail: doctor == nil ? "Not checked" : "Missing")
            }
            if let error = doctor?.mlxError {
                EnvCard(state: .bad, title: "MLX", detail: error)
            } else if let device = doctor?.mlxDevice {
                EnvCard(state: .ok, title: "MLX", detail: device.lowercased().contains("gpu") ? "Apple Silicon GPU" : device)
            } else {
                EnvCard(state: doctor?.appleSilicon == false ? .bad : .unknown, title: "MLX",
                        detail: doctor?.appleSilicon == false ? "Needs Apple Silicon" : "Not checked")
            }
            if let command = model.command {
                EnvCard(state: .ok, title: "CLI", detail: abbreviate(command.displayString))
            } else {
                EnvCard(state: .warn, title: "CLI", detail: "Not found")
            }
            EnvCard(state: workerCardState, title: "Worker", detail: workerDetail)
        }
    }

    private func abbreviate(_ s: String) -> String { (s as NSString).abbreviatingWithTildeInPath }

    /// "Idle · 1.7B in memory", "Working · 0.6B in memory", "Not running".
    private var workerDetail: String {
        let loaded = model.loadedModel.map { "\($0.params.isEmpty ? $0.name : $0.params) in memory" }
        switch model.workerState {
        case .stopped: return model.isDownloaded(model.options.model) ? "Starts with the first file" : "Model downloads on first run"
        case .starting: return "Starting…"
        case .idle: return ["Idle", loaded ?? "no model loaded"].joined(separator: " · ")
        case .busy: return ["Working", loaded].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var workerCardState: EnvCard.State {
        switch model.workerState {
        case .stopped: model.isDownloaded(model.options.model) ? .unknown : .download
        case .starting, .idle, .busy: .ok
        }
    }
}

struct EnvCard: View {
    enum State { case ok, bad, warn, download, unknown }
    var state: State
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(tone.fg)
                .frame(width: 20, height: 20)
                .background(tone.bg, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .bold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(title == "CLI" ? .middle : .tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .card(radius: 9)
        .help(detail)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .ok: "checkmark"
        case .bad: "xmark"
        case .warn: "exclamationmark"
        case .download: "arrow.down"
        case .unknown: "questionmark"
        }
    }

    private var tone: Tone {
        switch state {
        case .ok: .green
        case .bad: .red
        case .warn, .download: .yellow
        case .unknown: .gray
        }
    }
}
