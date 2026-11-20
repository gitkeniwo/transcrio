import AppKit
import SwiftUI
import TranscribeKit

/// Left pane: toolbar icons, search with filter segments, the grouped queue, summary chips
/// and the bottom bar.
struct QueueSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    @FocusState private var listFocused: Bool
    @State private var drag = DragState()
    @State private var swipe = SwipeController()
    /// The queue list's natural height, for the queue / History split.
    @State private var queueContentHeight: Double = 0
    @State private var queueViewportHeight: Double = 0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            SearchField(text: $model.searchText, scope: $model.searchScope, issuesOnly: $model.issuesOnly, filter: $model.statusFilter,
                        compact: paneWidth < 320)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
            regions
            footer
        }
        .background(.regularMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .environment(drag)
        .environment(swipe)
        .onAppear { swipe.install(model: model) }
        .onDisappear { swipe.uninstall() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            Spacer()
            ToolbarIcon(systemImage: "plus", label: "Add files") { model.chooseFiles() }
            ToolbarIcon(systemImage: "checkmark.circle", label: model.selectMode ? "Leave Select mode" : "Select files",
                        on: model.selectMode, tint: Palette.blue) {
                withAnimation(.snappy(duration: 0.2)) { model.selectMode.toggle() }
            }
            ToolbarIcon(systemImage: "rectangle.split.3x1", label: "Toggle center pane", on: model.centerVisible) {
                model.togglePane(.center)
            }
            ToolbarIcon(systemImage: "sidebar.right", label: "Toggle inspector", on: model.inspectorVisible) {
                model.togglePane(.inspector)
            }
        }
        .padding(.leading, 84) // traffic lights
        .padding(.trailing, 12)
        .frame(height: 52)
    }

    // MARK: Queue + History

    private var regions: some View {
        GeometryReader { geo in
            let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            let rows = model.historyEntries.count
            let notice = HistoryRegion.noticeHeight(model.dropNotice)
            let split = SidebarSplit.compute(
                height: geo.size.height,
                queueContent: model.items.isEmpty ? 0 : max(queueContentHeight, 60),
                historyContent: HistoryRegion.naturalHeight(rows: rows, empty: model.historyTotal == 0 || (rows == 0 && !searching),
                                                            rowHeight: HistoryRegion.rowHeight(model)) + notice,
                collapsed: model.historyCollapsed && !searching,
                ratio: model.historyRatio)
                .reserving(notice, height: geo.size.height)
            VStack(spacing: 0) {
                Group {
                    if model.items.isEmpty && split.queue < 120 {
                        DropFilesRow().padding(.horizontal, 10)
                    } else {
                        list
                    }
                }
                .frame(height: split.queue, alignment: .top)
                HistoryRegion(collapsed: split.historyCollapsed, resizable: split.resizable,
                              queueHeight: split.queue, totalHeight: geo.size.height)
                    .frame(height: split.history)
            }
            .animation(.snappy(duration: 0.2), value: split)
        }
    }

    // MARK: List

    /// Rows as they appear, for ⇧-click ranges and arrow keys.
    private var visibleOrder: [FileItem.ID] {
        if model.isFiltering { return model.filteredItems.map(\.id) }
        return model.queue.sections().flatMap { s in s.section == .finished && !model.finishedExpanded ? [] : s.ids }
    }

    @ViewBuilder private var list: some View {
        if model.items.isEmpty {
            VStack(spacing: 8) {
                Text("No files yet").font(.system(size: 14, weight: .semibold))
                Text("Drop files anywhere in this window").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isFiltering && model.filteredItems.isEmpty {
            VStack(spacing: 8) {
                Text("No matching files").font(.system(size: 14, weight: .semibold))
                Button("Clear Filters") {
                    model.searchText = ""
                    model.issuesOnly = false
                    model.statusFilter = .all
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let order = visibleOrder
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // One flat ForEach: rows that move between sections keep a single identity,
                        // so they re-render (nested per-section ForEach left moved rows stale).
                        ForEach(entries) { entry in
                            switch entry {
                            case .header(let section, let ids): header(section, ids: ids)
                            case .row(let id, let section, let index, let ids): row(id, section: section, index: index, in: ids, order: order)
                            case .upNextTail: UpNextTailDrop()
                            case .upNextPlaceholder: UpNextTailDrop(placeholder: true)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .animation(.snappy(duration: 0.2), value: model.queue.displayOrder)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { queueContentHeight = $0 }
                    // Clicking the empty space below the rows clears the selection.
                    .frame(maxWidth: .infinity, minHeight: queueViewportHeight, alignment: .top)
                    .background {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { model.selection = []; listFocused = true }
                    }
                }
                .onGeometryChange(for: Double.self) { $0.size.height } action: { queueViewportHeight = $0 }
                .scrollIndicators(.never)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    moveSelection(press.key == .upArrow ? -1 : 1, extend: press.modifiers.contains(.shift), in: order, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.space) { model.toggleQuickLook() ? .handled : .ignored }
                .onKeyPress(.rightArrow) { setExpanded(true) }
                .onKeyPress(.leftArrow) { setExpanded(false) }
                .onKeyPress(.escape) {
                    if model.selectMode { model.selectMode = false; return .handled }
                    if !model.selection.isEmpty { model.selection = []; return .handled }
                    return .ignored
                }
                .onDeleteCommand { model.removeSelected() }
                .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll(in: order) }
                .onChange(of: model.selection) { old, new in
                    if let id = new.subtracting(old).first { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private enum Entry: Identifiable {
        case header(QueueSection, [FileItem.ID])
        case row(FileItem.ID, QueueSection?, Int, [FileItem.ID])
        case upNextTail, upNextPlaceholder

        var id: AnyHashable {
            switch self {
            case .header(let s, _): "header-\(s.rawValue)"
            case .row(let id, _, _, _): id
            case .upNextTail: "tail"
            case .upNextPlaceholder: "placeholder"
            }
        }
    }

    private var entries: [Entry] {
        if model.isFiltering {
            let ids = model.filteredItems.map(\.id)
            return ids.enumerated().map { .row($1, nil, $0, ids) }
        }
        var out: [Entry] = []
        for s in model.queue.sections() where !s.ids.isEmpty {
            out.append(.header(s.section, s.ids))
            if s.section != .finished || model.finishedExpanded {
                out += s.ids.enumerated().map { .row($1, s.section, $0, s.ids) }
            }
            if s.section == .upNext { out.append(.upNextTail) }
            if s.section == .ready && model.queue.upNext.isEmpty && drag.active { out.append(.upNextPlaceholder) }
        }
        return out
    }

    @ViewBuilder private func row(_ id: FileItem.ID, section: QueueSection?, index: Int, in ids: [FileItem.ID], order: [FileItem.ID]) -> some View {
        if let item = model.queue[id] {
            let selected = model.selection.contains(id)
            // Adjacent selected rows merge into one block.
            let joinTop = selected && index > 0 && model.selection.contains(ids[index - 1])
            let joinBottom = selected && index + 1 < ids.count && model.selection.contains(ids[index + 1])
            QueueRow(item: item, section: section, selected: selected, joinTop: joinTop, joinBottom: joinBottom)
                .id(id)
                .contentShape(Rectangle())
                .onTapGesture {
                    let flags = NSEvent.modifierFlags
                    model.click(id, command: flags.contains(.command), shift: flags.contains(.shift), in: order)
                    listFocused = true
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if !model.selectMode { model.toggleQuickLook(id) }
                })
                .contextMenu { RowMenu(targets: menuTargets(for: id), clicked: item) }
                .modifier(RowDrag(item: item, section: section, index: index))
        }
    }

    /// A right-click on a selected row acts on the whole selection.
    private func menuTargets(for id: FileItem.ID) -> [FileItem] {
        model.selection.contains(id) ? model.selectedItems : [model.queue[id]].compactMap { $0 }
    }

    @ViewBuilder private func header(_ section: QueueSection, ids: [FileItem.ID]) -> some View {
        switch section {
        case .now:
            QueueSectionHeader(title: "Now", count: ids.count)
        case .upNext:
            Ticking(interval: 10) { _ in
                QueueSectionHeader(title: "Up next", count: ids.count,
                                   note: QueueEstimate.upNext(model.queue, history: model.history).map(QueueEstimate.format))
            }
            .modifier(SectionDrop(section: .upNext, index: 0))
        case .ready:
            QueueSectionHeader(title: "Ready", count: ids.count,
                               note: drag.hoveringReady && drag.isDraggingQueued(model) ? "drop here to unqueue" : "not scheduled",
                               noteColor: drag.hoveringReady && drag.isDraggingQueued(model) ? Palette.blue : .secondary)
                .modifier(SectionDrop(section: .ready, index: nil))
        case .finished:
            // Decision 1: Done files move to History, so this holds Failed and Stopped files.
            let failed = ids.compactMap { model.queue[$0] }.filter { $0.error != nil }.count
            QueueSectionHeader(title: "Needs Attention", count: ids.count,
                               note: failed > 0 ? "\(failed) failed" : nil, noteColor: Palette.red,
                               expanded: Binding(get: { model.finishedExpanded }, set: { model.finishedExpanded = $0 }),
                               action: ("Clear All", { withAnimation(.snappy(duration: 0.2)) { model.clearFinished() } }))
        }
    }

    private func moveSelection(_ delta: Int, extend: Bool, in order: [FileItem.ID], proxy: ScrollViewProxy) {
        guard !order.isEmpty else { return }
        let current = model.selectionAnchor.flatMap { order.firstIndex(of: $0) }
            ?? order.lastIndex { model.selection.contains($0) }
        let index = min(max(current.map { $0 + delta } ?? (delta > 0 ? 0 : order.count - 1), 0), order.count - 1)
        let id = order[index]
        if extend {
            model.selection.insert(id)
        } else {
            model.selection = [id]
        }
        model.selectionAnchor = id
        proxy.scrollTo(id)
    }

    /// → / ← show and hide the selected row's output files (the only way when the chevron is hidden).
    private func setExpanded(_ on: Bool) -> KeyPress.Result {
        guard let item = model.selectedItem, item.result?.orderedOutputs.isEmpty == false else { return .ignored }
        withAnimation(.snappy(duration: 0.2)) {
            if on { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) }
        }
        return .handled
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Group {
                if model.selectMode {
                    selectChips
                } else {
                    HStack(spacing: 8) {
                        let done = model.queue.doneCount + model.sessionDone, total = model.items.count + model.sessionDone
                        TintChip(title: "Done", value: total == 0 ? "—" : "\(done) / \(total)", tone: .purple)
                        if model.isRunning {
                            Ticking(interval: 5) { now in
                                TintChip(title: "Left", value: model.leftEstimate(now: now).map(QueueEstimate.format) ?? "—", tone: .blue)
                            }
                        } else {
                            TintChip(title: "Total audio", value: model.items.isEmpty ? "—" : Formatting.longClock(model.queue.totalDuration), tone: .blue)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Group {
                if model.selectMode { selectBar } else { bottomBar }
            }
            .buttonStyle(FlatButtonStyle(height: 30))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var selectChips: some View {
        HStack(spacing: 10) {
            CapsuleLabel(text: "\(model.selection.count) selected", tone: .blue, height: 26)
            Button("Select All") { model.selectAll(in: visibleOrder) }.buttonStyle(.link)
            Text("·").foregroundStyle(.tertiary)
            Button("Deselect") { model.selection = [] }.buttonStyle(.link).disabled(model.selection.isEmpty)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 34)
    }

    private var selectBar: some View {
        HStack(spacing: 6) {
            Button { model.startSelected() } label: { Label("Start", systemImage: "play.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(FlatButtonStyle(prominent: true, height: 30))
                .disabled(model.startableSelection.isEmpty)
            Button("Options…") {
                if !model.inspectorVisible { model.togglePane(.inspector) }
            }
            .disabled(model.selection.isEmpty)
            Button { model.removeSelected() } label: { Text("Remove").foregroundStyle(Palette.red) }
                .disabled(model.selection.isEmpty)
            Spacer(minLength: 0)
            Button("Done") { withAnimation(.snappy(duration: 0.2)) { model.selectMode = false } }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button { model.chooseFiles() } label: { Image(systemName: "plus") }
                .help("Add files (⌘O)").accessibilityLabel("Add files")
            if !model.isRunning {
                Button { model.clearFinished() } label: { Image(systemName: "trash") }
                    .disabled(!model.hasFinished)
                    .help("Clear Needs Attention").accessibilityLabel("Clear Needs Attention")
            }
            if paneWidth >= 340 {
                Text(model.statusLabel)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Status: \(model.statusLabel)")
            } else {
                Spacer(minLength: 0)
                    .accessibilityElement()
                    .accessibilityLabel("Status: \(model.statusLabel)")
            }
            if model.isRunning {
                if !model.startableSelection.isEmpty {
                    SplitButton(title: "Queue \(model.startableSelection.count)", systemImage: "play.fill",
                                help: "Add the selected files to Up next (⌘R)") {
                        model.startSelected()
                    } menu: { StartMenu() }
                }
                SplitButton(title: "Stop", systemImage: "stop.fill", help: "Stop the current file (⌘.)") {
                    model.stopCurrent()
                } menu: { StopMenu() }
            } else {
                let selected = model.startableSelection.count
                SplitButton(title: selected > 0 ? "Start \(selected) Selected" : "Start All (\(model.readyIDs.count))",
                            systemImage: "play.fill", prominent: true,
                            help: selected > 0 ? "Transcribe the selected files (⌘R)" : "Transcribe every Ready file (⌥⌘R)",
                            disabled: selected == 0 && model.readyIDs.isEmpty) {
                    model.startPrimary()
                } menu: { StartMenu() }
            }
        }
    }
}

// MARK: - Menus

/// The Start ▴ menu (idle), also the Queue ▴ menu while running.
struct StartMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.startableSelection.count
        Button("Start All Ready (\(model.readyIDs.count))") { model.startAllReady() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model.readyIDs.isEmpty)
        Button("Start Selected (\(selected))") { model.startSelected() }
            .keyboardShortcut("r")
            .disabled(selected == 0)
        Button("Run Selected Next") { model.runNext(model.selectedIDs) }
            .disabled(selected == 0 && !model.selectedItems.contains { $0.state == .queued })
        Divider()
        Button("Select Files to Start…") { model.selectMode = true }
    }
}

struct StopMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Stop Current File") { model.stopCurrent() }
            .keyboardShortcut(".")
            .disabled(!model.isRunning)
        Button("Stop All") { model.stopAll() }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(!model.isRunning && !model.hasWaiting)
        Divider()
        Button("Unqueue Waiting Files") { model.unqueueWaiting() }
            .disabled(!model.hasWaiting)
        Button("Queue All Ready (\(model.readyIDs.count))") { model.startAllReady() }
            .disabled(model.readyIDs.isEmpty)
    }
}

/// The row context menu, also behind the hover `…` button.
struct RowMenu: View {
    @Environment(AppModel.self) private var model
    var targets: [FileItem]
    var clicked: FileItem

    private func label(_ verb: String, _ n: Int, _ noun: String = "File") -> String {
        targets.count > 1 ? "\(verb) \(n) \(noun)\(n == 1 ? "" : "s")" : verb
    }

    var body: some View {
        let ids = targets.map(\.id)
        let startable = targets.filter(model.queue.canQueue)
        let queued = targets.filter { $0.state == .queued }
        let running = targets.filter(\.state.isRunning)
        let done = targets.filter { $0.result != nil }
        let editable = targets.filter(\.optionsEditable)
        let single = targets.count == 1 ? targets.first : nil

        if case .done = clicked.state {
            Button("Quick Look") { model.toggleQuickLook(clicked.id) }
            Button("Show Output in Finder") { model.revealOutputs(done.map(\.id)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open Source File") { model.open(clicked.path) }
            Button("Copy Transcript") { model.copyTranscript(clicked.id) }.disabled(single == nil)
            Divider()
            Button("Run Again with Changes…") { model.runAgainWithChanges(clicked.id) }.disabled(single == nil)
            Button("Copy Options") { model.copyOptions(of: clicked.id) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Paste Options") { model.pasteOptions(to: editable.map(\.id)) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(editable.isEmpty)
        } else {
            if !running.isEmpty && startable.isEmpty && queued.isEmpty {
                Button("Stop") { for r in running { model.stop(r.id) } }.keyboardShortcut(".")
            } else {
                Button(label(clicked.state == .failed(clicked.error ?? "") || clicked.state.isStopped ? "Retry" : "Start", startable.count)) {
                    model.start(startable.map(\.id))
                }
                .keyboardShortcut("r")
                .disabled(startable.isEmpty)
                Button(label("Run Next", startable.count + queued.count)) { model.runNext(ids) }
                    .disabled(startable.isEmpty && queued.isEmpty)
                if !queued.isEmpty { Button(label("Unqueue", queued.count)) { model.unqueue(queued.map(\.id)) } }
            }
            Divider()
            Button("Show Options") {
                model.selection = Set(ids)
                if !model.inspectorVisible { model.togglePane(.inspector) }
            }
            .keyboardShortcut("i")
            Button("Copy Options") { model.copyOptions(of: clicked.id) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Paste Options") { model.pasteOptions(to: editable.map(\.id)) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(editable.isEmpty)
            Divider()
            Button("Open Source File") { model.open(clicked.path) }
            Button("Show Source in Finder") { model.reveal(targets.map(\.path)) }
        }
        Divider()
        Button(label("Remove from List", targets.count - running.count)) { model.remove(ids) }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(targets.count == running.count)
    }
}

// MARK: - Section header

/// The gray section band: 26 pt, title, count and an optional right-aligned note.
struct QueueSectionHeader: View {
    var title: String
    var count: Int
    var note: String?
    var noteColor: Color = .secondary
    var expanded: Binding<Bool>?
    /// A link at the right ("Clear All").
    var action: (String, () -> Void)?

    var body: some View {
        let content = HStack(spacing: 6) {
            if let expanded {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
            }
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(noteColor).lineLimit(1) }
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Palette.bandFill, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .padding(.top, 8)
        .padding(.bottom, 4)

        if let expanded {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        } else {
            content.accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - Toolbar

/// Icon-only toolbar button in the sidebar's top row.
struct ToolbarIcon: View {
    var systemImage: String
    var label: String
    var on = false
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on && tint != nil ? systemImage + ".fill" : systemImage)
                .font(.system(size: 15))
                .frame(width: 34, height: 30)
                .background(on ? (tint.map { $0.opacity(0.16) } ?? Palette.controlFill) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(on ? (tint ?? Color.primary) : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Search field with trailing segments: "issues only" toggle and the status filter.
struct SearchField: View {
    @Binding var text: String
    /// What History matches; shown while there is text.
    @Binding var scope: SearchScope
    @Binding var issuesOnly: Bool
    @Binding var filter: AppModel.StatusFilter
    /// Below 320 pt the filter shows only its chevron.
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
                TextField("Search", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                if !text.isEmpty {
                    ScopeSegments(scope: $scope)
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)

            Divider()
            Button { issuesOnly.toggle() } label: {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: issuesOnly ? .semibold : .regular))
                    .foregroundStyle(issuesOnly ? Palette.yellow : Color.primary)
                    .frame(width: 36, height: 34)
                    .background(issuesOnly ? Palette.yellowT : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Only show files with issues")
            .accessibilityLabel("Only show files with issues")
            .accessibilityAddTraits(issuesOnly ? .isSelected : [])

            Divider()
            Menu {
                Picker("Status", selection: $filter) {
                    ForEach(AppModel.StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    if !compact { Text(filter.rawValue).font(.system(size: 13)) }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, compact ? 9 : 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Status filter: \(filter.rawValue)")
        }
        .frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Titles / Text: what History matches. Small segments in the look of the preview's format bar.
private struct ScopeSegments: View {
    @Binding var scope: SearchScope

    var body: some View {
        HStack(spacing: 1) {
            ForEach(SearchScope.allCases) { s in
                let on = s == scope
                Button { scope = s } label: {
                    Text(s.label)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(on ? Palette.cardFill : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s == .titles ? "Match History titles and file names" : "Match the text of every transcript in History")
                .accessibilityLabel("Search \(s.label)")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

/// The empty queue's 40 pt dashed row.
struct DropFilesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.chooseFiles() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Drop files to transcribe · ⌘O")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add files to transcribe")
    }
}
