import AppKit
import SwiftUI
import TranscribeKit

/// Settings with toolbar tabs: General, Library, Appearance (the Dock icon) and Models,
/// which opens the Models window.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag("library")
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag("appearance")
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag("models")
        }
        .frame(width: 560)
    }
}

/// The Dock icon: Default (the bundle's icon) or one of the alternates in gui/icons.
/// A click applies it straight away.
private struct AppearanceSettings: View {
    @AppStorage(SettingsKeys.appIcon) private var appIcon = ""

    private var current: String { AppIconCatalog.resolve(appIcon)?.id ?? "" }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 10) {
                    AppIconTile(name: "Default", image: AppIcon.bundleImage, selected: current.isEmpty) { choose("") }
                    ForEach(AppIconCatalog.all) { entry in
                        AppIconTile(name: entry.name, image: AppIcon.image(entry.id), selected: current == entry.id) {
                            choose(entry.id)
                        }
                    }
                }
                .padding(.vertical, 4)
                Text("Changes the Dock icon only. The icon in Finder stays the default.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("App Icon")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose(_ id: String) {
        appIcon = id
        AppIcon.choose(id)
    }
}

private struct AppIconTile: View {
    let name: String
    let image: NSImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 64, height: 64)
                .padding(3)
                .overlay {
                    // The squircle body is 824/1024 of the icon, corner 185/1024.
                    RoundedRectangle(cornerRadius: 64 * 185 / 1024 + 3, style: .continuous)
                        .inset(by: 64 * 100 / 1024 - 1)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .opacity(selected ? 1 : 0)
                }
                Text(name)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Models tab only points at the Models window, which has the full list.
private struct ModelsSettingsTab: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Download, remove and inspect models in the Models window.")
                .foregroundStyle(.secondary)
            Button("Open Models Window") { openWindow(id: "models") }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .onAppear { openWindow(id: "models") }
    }
}

/// Queue, memory and where to find the `transcribe` CLI. CLI search order: the override,
/// ~/.local/bin/transcribe, then `uv run --project <repo> transcribe`.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.autoStart) private var autoStart = false
    @AppStorage(SettingsKeys.idleUnload) private var idleUnload = 300.0
    @AppStorage(SettingsKeys.preload) private var preload = false
    @AppStorage(SettingsKeys.cliPath) private var cliPath = ""
    @AppStorage(SettingsKeys.repoPath) private var repoPath = CLILocator.defaultRepoPath
    @State private var testing = false
    @State private var result: TestResult?

    enum TestResult: Equatable {
        case ok(command: String, doctor: DoctorReport)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Start new files automatically", isOn: $autoStart)
                Text("Off: new files wait in Ready. On: they join Up next.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Queue")
            }

            Section {
                Picker("Unload model when idle", selection: $idleUnload) {
                    Text("Never").tag(0.0)
                    Text("After 1 minute").tag(60.0)
                    Text("After 5 minutes").tag(300.0)
                    Text("After 10 minutes").tag(600.0)
                    Text("After 30 minutes").tag(1800.0)
                }
                .onChange(of: idleUnload) { model.idleUnloadChanged() }
                Toggle("Load model when the app opens", isOn: $preload)
                Text("Loading takes about 10 s and keeps about 6 GB of memory in use, so the first file starts right away.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Memory")
            }

            Section {
                LabeledContent("CLI path") {
                    HStack {
                        TextField("CLI path", text: $cliPath, prompt: Text("~/.local/bin/transcribe"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { choose(directory: false) { cliPath = $0 } }
                    }
                }
                Text("Leave empty to use ~/.local/bin/transcribe, then uv run in the project below.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Command-line tool")
            }

            Section {
                LabeledContent("Project folder") {
                    HStack {
                        TextField("Project folder", text: $repoPath, prompt: Text(CLILocator.defaultRepoPath))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { choose(directory: true) { repoPath = $0 } }
                    }
                }
                Text("Used with uv run --project when the command isn’t installed.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("uv fallback")
            }

            Section {
                HStack(alignment: .top, spacing: 10) {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }
                        .disabled(testing)
                        .keyboardShortcut(.defaultAction)
                    resultView
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: cliPath) { result = nil }
        .onChange(of: repoPath) { result = nil }
    }

    @ViewBuilder private var resultView: some View {
        switch result {
        case nil:
            Text("Runs transcribe doctor --json with these settings.")
                .font(.callout).foregroundStyle(.secondary)
        case .ok(let command, let doctor):
            VStack(alignment: .leading, spacing: 3) {
                Label(doctor.ok ? "Works" : "Found, but something is missing", systemImage: doctor.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(doctor.ok ? Palette.green : Palette.yellow)
                    .font(.callout.weight(.semibold))
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("ffmpeg: \(doctor.ffmpeg ?? "missing") · MLX: \(doctor.mlxDevice ?? doctor.mlxError ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Palette.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let command = try CLILocator().locate(overridePath: cliPath, repoPath: repoPath)
            let doctor = try await CLIHelper(command: command).doctor()
            result = .ok(command: command.displayString, doctor: doctor)
        } catch {
            result = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        // Make the main window use the same settings straight away.
        await model.checkEnvironment()
    }

    private func choose(directory: Bool, _ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.showsHiddenFiles = true
        panel.directoryURL = directory ? URL(fileURLWithPath: repoPath) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            done((url.path as NSString).abbreviatingWithTildeInPath)
        }
    }
}
