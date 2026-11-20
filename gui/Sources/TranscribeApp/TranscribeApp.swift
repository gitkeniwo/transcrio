import AppKit
import QuickLook
import SwiftUI
import TranscribeKit

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Transcrio", id: "main") {
            Group {
                if DevSupport.environment["TRANSCRIBE_GALLERY"] != nil {
                    ComponentGallery()
                } else {
                    ContentView()
                }
            }
            .environment(appDelegate.model)
            .frame(minWidth: PaneLayout.windowMin, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(model: appDelegate.model) }

        Window("Models", id: "models") {
            ModelsWindow()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1000, height: 680)
        .keyboardShortcut("m", modifiers: [.command, .shift])

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable (`swift run`) starts as a background process; make it a
        // regular app with a Dock icon and bring it forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        HangProbe.startIfRequested()
        // The Dock icon set at runtime doesn't outlive the process.
        AppIcon.apply(AppIcon.stored)
        DevSupport.applyLaunchOptions(model: model)
        model.preloadIfWanted()
        // Killed from outside (logout, `kill`, Ctrl-C under `swift run`): don't leave the CLI running.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [model] in MainActor.assumeIsolated { model.stopAndExit() } }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.killWorkerIfRunning()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let layout = model.paneLayout
            HStack(spacing: 0) {
                QueueSidebar()
                    .toastHost(.sidebar)
                    .frame(width: layout.queue)
                    .environment(\.paneWidth, layout.queue)
                if let center = layout.center {
                    PaneDivider { model.queueWidthPreference = min(max($0, PaneLayout.queueRange.lowerBound), PaneLayout.queueRange.upperBound) } start: { layout.queue }
                    CenterPane()
                        .toastHost(.center)
                        .frame(width: center)
                        .background(Color(nsColor: .textBackgroundColor))
                        .environment(\.paneWidth, center)
                        .transition(.opacity)
                }
                if let inspector = layout.inspector {
                    PaneDivider(sign: -1) { model.inspectorWidthPreference = min(max($0, PaneLayout.inspectorRange.lowerBound), PaneLayout.inspectorRange.upperBound) } start: { inspector }
                    InspectorPane()
                        .toastHost(.inspector)
                        .frame(width: inspector)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.paneWidth, inspector)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            .onAppear { model.windowWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in model.windowWidth = w }
        }
        // The panes' 52 pt top bars sit beside the traffic lights; without this the hidden title
        // bar still reserves an empty strip above them.
        .ignoresSafeArea(.container, edges: .top)
        .background(TrafficLightCentering())
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.blue, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Palette.blueT.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .stopConfirmation()
        .libraryPresentations()
        .quickLookPreview($model.quickLookURL)
        .task { await model.checkEnvironment() }
        .onReceive(NotificationCenter.default.publisher(for: DevSupport.openSettingsNotification)) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: DevSupport.openModelsNotification)) { _ in openWindow(id: "models") }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { model.chooseFiles() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy with Timestamps") { TranscriptTextView.active?.copyWithTimestamps(nil) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled((model.selectedItem?.result?.outputs.isEmpty ?? true) && model.selectedEntry == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { TranscriptTextView.active?.showFind(nil) }
                .keyboardShortcut("f")
                .disabled((model.selectedItem?.result?.outputs.isEmpty ?? true) && model.selectedEntry == nil)
        }
        CommandMenu("Queue") {
            Button("Start Selected") { model.startSelected() }
                .keyboardShortcut("r")
                .disabled(model.startableSelection.isEmpty)
            Button("Start All Ready") { model.startAllReady() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.readyIDs.isEmpty)
            Button("Run Selected Next") { model.runNext(model.selectedIDs) }
                .disabled(model.startableSelection.isEmpty && !model.selectedItems.contains { $0.state == .queued })
            Divider()
            Button("Stop Current File") { model.stopCurrent() }
                .keyboardShortcut(".")
                .disabled(!model.isRunning)
            Button("Stop All") { model.stopAll() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!model.isRunning && !model.hasWaiting)
            Button("Unqueue Waiting Files") { model.unqueueWaiting() }
                .disabled(!model.hasWaiting)
            Divider()
            Button("Retry Failed") { model.retryFailed() }
                .disabled(model.failedIDs.isEmpty)
            Button("Clear Needs Attention") { model.clearFinished() }
                .disabled(!model.hasFinished)
            Divider()
            Button("Show Options") {
                if !model.inspectorVisible { model.togglePane(.inspector) }
            }
            .keyboardShortcut("i")
            Button("Copy Options") { model.copyOptions(of: model.selectedIDs.first) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Paste Options") { model.pasteOptions(to: model.selection.isEmpty ? nil : model.selectedItems.filter(\.optionsEditable).map(\.id)) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model.clipboardOptions == nil)
            Button("Show in Finder") {
                if model.historySelection.isEmpty { model.revealOutputs() } else { model.revealEntries(Array(model.historySelection)) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.selectedItems.contains { $0.result != nil } && model.historySelection.isEmpty)
            Divider()
            Button("Quick Look") { model.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(model.selection.isEmpty)
            Button("Remove from List") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedItems.allSatisfy(\.state.isRunning))
        }
        CommandMenu("History") {
            let ids = model.selectedEntries.map(\.id)
            Button("Save \(model.lastExportFormat.rawValue) to Downloads") {
                model.saveToDownloads(ids, formats: [model.lastExportFormat], pane: .sidebar)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(ids.isEmpty)
            Button("Save As…") { model.saveAs(ids, formats: [model.lastExportFormat], pane: .sidebar) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(ids.isEmpty)
            Menu("Export") { ExportSubmenu(targets: ids, pane: .sidebar).environment(model) }
                .disabled(ids.isEmpty)
            Toggle("Include Timestamps in md and txt", isOn: Binding(get: { model.exportTimestamps }, set: { model.exportTimestamps = $0 }))
            Divider()
            Button("Transcribe Again…") { model.requestAgain(Array(model.historySelection)) }
                .disabled(model.selectedEntries.allSatisfy(model.sourceMissing))
            Button("Show Source in Finder") { model.revealSources(Array(model.historySelection)) }
                .disabled(model.selectedEntries.allSatisfy(model.sourceMissing))
            Divider()
            Button("Remove from History…") { model.removeRequest = Array(model.historySelection) }
                .disabled(model.historySelection.isEmpty)
            Divider()
            Button("Show Library in Finder") { model.revealLibrary() }
        }
        CommandGroup(after: .sidebar) {
            Button(model.historyCollapsed ? "Expand History" : "Collapse History") { model.toggleHistory() }
                .keyboardShortcut("h", modifiers: [.control, .command])
            Button(model.centerVisible ? "Hide Center Pane" : "Show Center Pane") { model.togglePane(.center) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button(model.inspectorVisible ? "Hide Inspector" : "Show Inspector") { model.togglePane(.inspector) }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

/// A 1 pt hairline between panes with a wider invisible handle; dragging it resizes the pane
/// on its left (`sign` 1) or right (`sign` -1).
struct PaneDivider: View {
    var sign: Double = 1
    var onDrag: (Double) -> Void
    var start: () -> Double
    @State private var origin: Double?

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let o = origin ?? start()
                            origin = o
                            onDrag(o + sign * g.translation.width)
                        }
                        .onEnded { _ in origin = nil })
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}
