import AppKit
import SwiftUI
import TranscribeKit

/// The History region under the queue: header band, the drop notice (in
/// the flow, so it never covers the header or the ringed rows), its own scroll view of
/// entries, and the empty state.
struct HistoryRegion: View {
    @Environment(AppModel.self) private var model
    @Environment(\.paneWidth) private var paneWidth
    /// History shows its header only (collapsed by the user or by the height split).
    var collapsed: Bool
    /// The divider can be dragged (both lists are long).
    var resizable: Bool
    /// The region's height and the space shared with the queue, for divider drags.
    var queueHeight: Double
    var totalHeight: Double
    @FocusState private var focused: Bool
    @State private var viewportHeight: Double = 0
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HistoryHeader(collapsed: collapsed)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .gesture(divider)
                .onHover { on in
                    guard resizable else { return }
                    if on { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
            if let notice = model.dropNotice {
                DropNoticeCard(notice: notice)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
            }
            if !collapsed {
                if model.library.entries.isEmpty || model.historyTotal == 0 {
                    HistoryEmpty()
                } else if model.historyEntries.isEmpty {
                    Text(model.searchingText && model.searcher.pending > 0 ? "Reading transcripts…" : "No matching transcripts")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.25), value: model.dropNotice?.id)
        .clipped()
    }

    private var divider: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                guard resizable else { return }
                let start = dragStart ?? queueHeight
                dragStart = start
                model.historyRatio = SidebarSplit.ratio(forQueueHeight: start + g.translation.height, height: totalHeight)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var list: some View {
        let entries = model.historyEntries
        let order = entries.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        let selected = model.historySelection.contains(entry.id)
                        HistoryRow(entry: entry, selected: selected, snippet: model.searchSnippet(entry.id),
                                   joinTop: selected && i > 0 && model.historySelection.contains(order[i - 1]),
                                   joinBottom: selected && i + 1 < order.count && model.historySelection.contains(order[i + 1]))
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                model.clickEntry(entry.id, command: flags.contains(.command), shift: flags.contains(.shift))
                                focused = true
                            }
                            .contextMenu { HistoryMenu(targets: menuTargets(entry.id)) }
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                // Clicking the empty space below the rows clears the selection.
                .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
                .background {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { model.historySelection = []; focused = true }
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.height } action: { viewportHeight = $0 }
            .scrollIndicators(.automatic)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22).allowsHitTesting(false)
                    .opacity(Double(entries.count) * Self.rowHeight(model) > max(totalHeight - queueHeight - SidebarSplit.header, 0) ? 1 : 0)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                move(press.key == .upArrow ? -1 : 1, in: order, proxy: proxy)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !model.historySelection.isEmpty else { return .ignored }
                model.historySelection = []
                return .handled
            }
            .onDeleteCommand { if !model.historySelection.isEmpty { model.removeRequest = Array(model.historySelection) } }
            .onCommand(#selector(NSResponder.selectAll(_:))) { model.historySelection = Set(order) }
            .onCommand(#selector(NSText.copy(_:))) {
                // ⌘C with History focused: Copy Text.
                if model.historySelection.count == 1, let id = model.historySelection.first { model.copyText(id, pane: .sidebar) }
            }
            .onChange(of: model.historyScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
                DispatchQueue.main.async { model.historyScrollTarget = nil }
            }
            .onAppear {
                if let target = model.historyScrollTarget { proxy.scrollTo(target, anchor: .center); model.historyScrollTarget = nil }
            }
            .onChange(of: model.dropNotice?.id) { _, id in
                // The notice pushed the list down: bring the ringed rows back to the middle.
                guard id != nil, let first = order.first(where: model.ringing.contains) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
    }

    private func menuTargets(_ id: LibraryEntry.ID) -> [LibraryEntry.ID] {
        model.historySelection.contains(id) ? model.selectedEntries.map(\.id) : [id]
    }

    private func move(_ delta: Int, in order: [LibraryEntry.ID], proxy: ScrollViewProxy) {
        guard !order.isEmpty else { return }
        let current = model.historyAnchor.flatMap { order.firstIndex(of: $0) } ?? order.lastIndex { model.historySelection.contains($0) }
        let i = min(max(current.map { $0 + delta } ?? 0, 0), order.count - 1)
        model.historySelection = [order[i]]
        model.historyAnchor = order[i]
        proxy.scrollTo(order[i])
    }

    /// The region's natural height (header + rows), for the height split.
    static func naturalHeight(rows: Int, empty: Bool, rowHeight: Double = SidebarSplit.historyRow) -> Double {
        SidebarSplit.header + (empty ? 190 : Double(rows) * rowHeight + 8)
    }

    /// Rows grow a snippet line while Text scope searches.
    static func rowHeight(_ model: AppModel) -> Double {
        model.searchingText ? SidebarSplit.historySnippetRow : SidebarSplit.historyRow
    }

    /// The drop notice's height in the flow (padding included); an estimate is enough for
    /// the split, the card itself sizes to its text.
    static func noticeHeight(_ notice: DropNotice?) -> Double {
        guard let notice else { return 0 }
        return notice.again.isEmpty ? 88 : 118
    }
}

/// 28 pt band: chevron · History · count · note · `…`.
struct HistoryHeader: View {
    @Environment(AppModel.self) private var model
    var collapsed: Bool
    @State private var pulse = false

    var body: some View {
        let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 6) {
            Button { model.toggleHistory() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text("History").font(.system(size: 12, weight: .semibold))
                    Text(searching ? "\(model.historyEntries.count) of \(model.historyTotal)" : "\(model.historyTotal)")
                        .font(.system(size: 12)).monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(pulse ? Palette.green : Color(nsColor: .tertiaryLabelColor))
                        .padding(.horizontal, pulse ? 6 : 0)
                        .background(pulse ? Palette.greenT : .clear, in: Capsule())
                    if model.searchingText && model.searcher.pending > 0 {
                        Spinner(size: 9, lineWidth: 1.4)
                        Text("Reading transcripts…").font(.system(size: 11.5)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History, \(model.historyTotal) transcripts")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)

            Menu {
                Picker("Sort History By", selection: Binding(get: { model.historySort }, set: { model.historySort = $0 })) {
                    Text("Date Transcribed").tag(HistorySort.date)
                    Text("Title").tag(HistorySort.title)
                    Text("Duration").tag(HistorySort.duration)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Show Library in Finder") { model.revealLibrary() }
                Divider()
                Button(model.historyCollapsed ? "Expand History" : "Collapse History") { model.toggleHistory() }
                    .keyboardShortcut("h", modifiers: [.control, .command])
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("History options")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Palette.bandFill, in: RoundedRectangle(cornerRadius: 7))
        .onTapGesture(count: 2) { model.toggleHistory() }
        .onChange(of: model.historyPulse) {
            withAnimation(.easeOut(duration: 0.2)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(.easeIn(duration: 0.3)) { pulse = false } }
        }
    }
}

/// "No transcripts yet".
struct HistoryEmpty: View {
    var body: some View {
        VStack(spacing: 8) {
            Circle().fill(Palette.grayT).frame(width: 36, height: 36)
                .overlay(Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.gray))
            Text("No transcripts yet").font(.system(size: 13, weight: .semibold))
            Text("Finished files are kept here. Export any format later without running the model again.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A 54 pt History row. Hover shows ⬇ Save and `…`; swipe right
/// saves the last format to Downloads, swipe left shows Again… and Remove.
struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(SwipeController.self) private var swipe
    @Environment(\.paneWidth) private var paneWidth
    var entry: LibraryEntry
    var selected: Bool
    /// Text scope: the matching text, a third line with the match highlighted.
    var snippet: SearchSnippet?
    var joinTop = false
    var joinBottom = false
    @State private var hovering = false
    @State private var ringOn = false
    @State private var width: CGFloat = 300

    var body: some View {
        let actions = swipeActions()
        let key = AnyHashable(entry.id)
        let offset = swipe.offset(for: key)
        let full = swipe.isFull(key)
        HStack(spacing: SwipeController.gap) {
            if offset > 0 { tiles(actions.leading, full: full).frame(width: max(0, offset - SwipeController.gap)) }
            card(swiped: offset != 0)
                .frame(width: full ? 64 : nil)
                // minWidth 0: the frame keeps the row's share and the full-width card overflows away from
                // the tiles (without it the frame grew to the card and the HStack overflowed, centred).
                .frame(minWidth: 0, maxWidth: full ? 64 : .infinity, alignment: offset < 0 ? .trailing : .leading)
                .clipped()
            if offset < 0 { tiles(actions.trailing, full: full).frame(width: max(0, -offset - SwipeController.gap)) }
        }
        .frame(height: rowHeight)
        .background {
            GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } }
        }
        .onHover { on in
            hovering = on
            if on {
                swipe.hoveredID = key
                swipe.rows[key] = (width, actions.leading, actions.trailing)
            } else if swipe.hoveredID == key {
                swipe.hoveredID = nil
            }
        }
        .onChange(of: width) { swipe.rows[key] = (width, actions.leading, actions.trailing) }
        .onAppear {
            if model.ringing.contains(entry.id) { ring() }
            applyDevState(key: key, actions: actions)
        }
        .onChange(of: model.ringing.contains(entry.id)) { _, on in if on { ring() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), transcribed \(HistoryDate.short(entry.updated))\(model.sourceMissing(entry) ? ", source not found" : "")"
                            + (snippet.map { ", \(Self.matchCount($0)): \($0.text)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions {
            ForEach(actions.leading + actions.trailing) { a in Button(a.title, action: a.run) }
        }
    }

    private func card(swiped: Bool) -> some View {
        let missing = model.sourceMissing(entry)
        let narrow = paneWidth < 320
        let fresh = model.freshEntries.contains(entry.id)
        let showHover = hovering && !swiped
        return HStack(spacing: 10) {
            FileTypeIcon(kind: entry.kind, size: 30)
                .opacity(missing ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if missing {
                        Circle().fill(Palette.gray).frame(width: 16, height: 16)
                            .overlay(Image(systemName: "questionmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white))
                            .background(Circle().strokeBorder(selected ? Palette.selection : Color(nsColor: .windowBackgroundColor), lineWidth: 2).padding(-2))
                            .offset(x: 5, y: 5)
                    }
                }
                .help(missing ? "Source file not found · last seen \(Self.abbreviate(entry.sourcePath))" : entry.sourcePath)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(0)
                    Spacer(minLength: 4)
                    if !showHover {
                        Text(HistoryDate.short(entry.updated))
                            .font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                            .fixedSize()
                            .layoutPriority(2)
                    }
                }
                HStack(spacing: 4) {
                    Text(line2(narrow: narrow))
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.white.opacity(0.88) : .secondary)
                        .lineLimit(1)
                        .layoutPriority(0)
                    Spacer(minLength: 2)
                    if !showHover { chips(narrow: narrow).layoutPriority(1) }
                }
                if let snippet {
                    Text(snippetText(snippet))
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.white.opacity(0.88) : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(Self.matchCount(snippet))
                }
            }
            if showHover { hoverButtons }
        }
        .padding(.horizontal, 10)
        .frame(width: swiped ? width : nil, height: rowHeight)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background { background(fresh: fresh, swiped: swiped) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(swiped ? 0.14 : 0), radius: 6, y: 2)
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.blue, lineWidth: 2)
                .opacity(ringOn ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            if !selected && !hovering && !fresh && !swiped {
                Rectangle().fill(Palette.hairline.opacity(0.7)).frame(height: 1).padding(.horizontal, 4)
            }
        }
    }

    /// ⬇ Save (the last format to Downloads) and `…` (the row menu).
    private var hoverButtons: some View {
        let f = model.lastExportFormat
        return HStack(spacing: 4) {
            Button { model.saveToDownloads([entry.id], formats: [f], pane: .sidebar) } label: {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(selected ? Color.white.opacity(0.2) : Palette.controlFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Save \(f.rawValue) to Downloads")
            .accessibilityLabel("Save \(f.rawValue) to Downloads")
            Menu { HistoryMenu(targets: [entry.id]) } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(selected ? Color.white.opacity(0.2) : Palette.controlFill, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(entry.title)")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private func ring() {
        withAnimation(.easeInOut(duration: 0.3).repeatCount(4, autoreverses: true)) { ringOn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(.easeOut(duration: 0.2)) { ringOn = false } }
    }

    @ViewBuilder private func background(fresh: Bool, swiped: Bool) -> some View {
        let r: CGFloat = 10
        if selected {
            UnevenRoundedRectangle(topLeadingRadius: joinTop && !swiped ? 0 : r, bottomLeadingRadius: joinBottom && !swiped ? 0 : r,
                                   bottomTrailingRadius: joinBottom && !swiped ? 0 : r, topTrailingRadius: joinTop && !swiped ? 0 : r)
                .fill(Palette.selection)
        } else if fresh {
            RoundedRectangle(cornerRadius: r).fill(Palette.blueT)
        } else if swiped {
            RoundedRectangle(cornerRadius: r).fill(Palette.cardFill)
        } else if hovering {
            RoundedRectangle(cornerRadius: r).fill(Palette.controlFill)
        }
    }

    /// `TRANSCRIBE_HISTORY_HOVER=<n>` and `TRANSCRIBE_HISTORY_SWIPE=<n>:<offset>` show those
    /// transient states for snapshots.
    private func applyDevState(key: AnyHashable, actions: (leading: [SwipeAction], trailing: [SwipeAction])) {
        let env = DevSupport.environment
        func isRow(_ n: Substring?) -> Bool {
            guard let n, let i = Int(n), model.historyEntries.indices.contains(i) else { return false }
            return model.historyEntries[i].id == entry.id
        }
        if isRow(env["TRANSCRIBE_HISTORY_HOVER"]?[...]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hovering = true }
        }
        if let spec = env["TRANSCRIBE_HISTORY_SWIPE"]?.split(separator: ":"), spec.count == 2, isRow(spec[0]),
           let x = Double(spec[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                swipe.rows[key] = (width, actions.leading, actions.trailing)
                swipe.open(key, offset: x)
            }
        }
    }

    private var rowHeight: CGFloat { snippet == nil ? SidebarSplit.historyRow : SidebarSplit.historySnippetRow }

    /// The snippet with its match in the system find highlight (black text, as in the Find bar).
    private func snippetText(_ s: SearchSnippet) -> AttributedString {
        var match = AttributedString(s.match)
        match.backgroundColor = Color(nsColor: .findHighlightColor)
        match.foregroundColor = .black
        return AttributedString(s.before) + match + AttributedString(s.after)
    }

    static func matchCount(_ s: SearchSnippet) -> String {
        s.count >= TranscriptSearchIndex.countCap ? "\(s.count)+ matches" : s.count == 1 ? "1 match" : "\(s.count) matches"
    }

    /// `duration · lang · model`; below 320 pt without the model.
    private func line2(narrow: Bool) -> String {
        var parts = [Formatting.clock(entry.duration)]
        if let lang = entry.language { parts.append(Languages.code(for: lang)) }
        if !narrow { parts.append(entry.modelLabel) }
        return parts.joined(separator: " · ")
    }

    /// Prepared formats, plus any being made or failed.
    @ViewBuilder private func chips(narrow: Bool) -> some View {
        let formats = OutputFormat.preparable.filter { f in
            entry.formats[f.rawValue] != nil || model.chipState(entry, f) != .canMake
        }
        let shown = narrow ? Array(formats.prefix(2)) : formats
        HStack(spacing: 3) {
            if model.againRow(for: entry.id) != nil {
                MiniChip(text: "in queue", tone: .gray, selected: selected)
            }
            if model.aligning[entry.id] != nil {
                MiniChip(text: "aligning", tone: .gray, selected: selected, making: true)
            }
            ForEach(shown, id: \.self) { f in
                let state = model.chipState(entry, f)
                MiniChip(text: f.rawValue, tone: state.isFailed ? .red : .purple, selected: selected,
                         dot: (f == .srt || f == .vtt) && entry.cuesEstimated,
                         making: state == .making)
                    .onDrag { model.dragProvider(entry.id, f) }
                    .help(state.isFailed ? "Couldn’t make \(f.rawValue)" : "Drag \(f.rawValue) to Finder or another app")
            }
            if formats.count > shown.count {
                Text("+\(formats.count - shown.count)").font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Palette.gray)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func tiles(_ actions: [SwipeAction], full: Bool) -> some View {
        HStack(spacing: SwipeController.gap) {
            if full, let bold = actions.first(where: \.bold) {
                SwipeTile(action: bold) { swipe.close() }
            } else {
                ForEach(actions) { a in SwipeTile(action: a) { swipe.close() } }
            }
        }
        .clipped()
    }

    /// Right: Save (the last format to Downloads). Left: Again… and Remove.
    private func swipeActions() -> (leading: [SwipeAction], trailing: [SwipeAction]) {
        let id = entry.id
        let m = model
        let f = model.lastExportFormat
        let missing = model.sourceMissing(entry)
        var trailing: [SwipeAction] = []
        if !missing {
            trailing.append(SwipeAction(title: "Again…", systemImage: "arrow.clockwise", color: Palette.gray) { m.requestAgain([id]) })
        }
        trailing.append(SwipeAction(title: "Remove", systemImage: "trash", color: Palette.red, bold: true) { m.removeRequest = [id] })
        return ([SwipeAction(title: "Save \(f.rawValue)", systemImage: "arrow.down.circle", color: Palette.blue, bold: true) {
                    m.saveToDownloads([id], formats: [f], pane: .sidebar)
                }],
                trailing)
    }

    static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

extension FormatChipState {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// 16 pt format chip (purpleT + purple), with the yellow "estimated" dot for srt/vtt and a
/// spinner while the format is being made.
struct MiniChip: View {
    var text: String
    var tone: Tone
    var selected = false
    var dot = false
    var making = false

    var body: some View {
        HStack(spacing: 3) {
            if making { Spinner(size: 8, lineWidth: 1.3) }
            if dot { Circle().fill(Palette.yellow).frame(width: 5, height: 5) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .bold))
        .padding(.horizontal, 5)
        .frame(height: 16)
        .foregroundStyle(selected ? Color.white : tone.fg)
        .background(selected ? Color.white.opacity(0.2) : tone.bg.opacity(making ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The History row context menu.
struct HistoryMenu: View {
    @Environment(AppModel.self) private var model
    var targets: [LibraryEntry.ID]

    var body: some View {
        let n = targets.count
        let entries = targets.compactMap { model.library[$0] }
        let withSource = entries.filter { !model.sourceMissing($0) }
        let last = model.lastExportFormat
        Button("Save \(last.rawValue) to Downloads") { model.saveToDownloads(targets, formats: [last], pane: .sidebar) }
        Menu("Export") { ExportSubmenu(targets: targets, pane: .sidebar) }
        Button("Save As…") { model.saveAs(targets, formats: [last], pane: .sidebar) }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        Button("Copy Text") { if let id = targets.first { model.copyText(id, pane: .sidebar) } }
            .keyboardShortcut("c")
            .disabled(n != 1)
        Divider()
        Button("Show in Finder") { model.revealEntries(targets) }
        if n == 1, withSource.isEmpty, let id = targets.first {
            Button("Locate…") { model.locateSource(id) }
        } else {
            Button("Show Source in Finder") { model.revealSources(targets) }
                .disabled(withSource.isEmpty)
        }
        Divider()
        Button(n > 1 ? "Transcribe \(withSource.count) Again…" : "Transcribe Again…") { model.requestAgain(withSource.map(\.id)) }
            .disabled(withSource.isEmpty)
        if n == 1, let entry = entries.first {
            // Notices aren't loaded here; the inspector's note reads them (an alignment that failed
            // is offered here too, which only retries it).
            let offer = model.alignOffer(entry, timing: model.estimatedTiming(entry, notices: []))
            if model.aligning[entry.id] != nil {
                Button("Aligning Subtitles…") {}.disabled(true)
            } else if offer != .none {
                // Without the source this stays disabled; Locate… is just above.
                Button("Align Subtitles") { model.alignSubtitles(entry.id) }
                    .disabled(offer == .needsSource)
            }
        }
        Divider()
        Button(n > 1 ? "Remove \(n) from History…" : "Remove from History…") { model.removeRequest = targets }
            .keyboardShortcut(.delete, modifiers: [])
    }
}

/// Export ▸: each format to Downloads, then all prepared ones.
struct ExportSubmenu: View {
    @Environment(AppModel.self) private var model
    var targets: [LibraryEntry.ID]
    var pane: Toast.Pane

    var body: some View {
        let entries = targets.compactMap { model.library[$0] }
        Section("Save to Downloads") {
            ForEach(OutputFormat.exportOrder, id: \.self) { f in
                Button("\(f.menuName) (.\(f.rawValue))") { model.saveToDownloads(targets, formats: [f], pane: pane) }
            }
        }
        let prepared = OutputFormat.ordered(entries.flatMap(\.preparedFormats))
        if prepared.count > 1 {
            Divider()
            Button("Save All Prepared Formats (\(prepared.count))") { model.saveToDownloads(targets, formats: prepared, pane: pane) }
        }
        Divider()
        Toggle("Include Timestamps in md and txt", isOn: Binding(get: { model.exportTimestamps }, set: { model.exportTimestamps = $0 }))
    }
}

/// The card over History after a drop. Stays 8 s, longer while hovered.
struct DropNoticeCard: View {
    @Environment(AppModel.self) private var model
    var notice: DropNotice
    @State private var hovering = false
    @State private var shownAt = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Palette.blueT).frame(width: 24, height: 24)
                .overlay(Image(systemName: "info").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.blue))
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.system(size: 12.5, weight: .semibold))
                Text(notice.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !notice.again.isEmpty {
                    Button(notice.againLabel) {
                        model.requestAgain(notice.again)
                        dismiss()
                    }
                    .buttonStyle(FlatButtonStyle(height: 24))
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(12)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .onAppear {
            NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(notice.title). \(notice.message)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        .task(id: notice.id) {
            // 8 s, paused while hovered.
            var left = 8.0
            while left > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                if !hovering { left -= 0.25 }
            }
            dismiss()
        }
    }

    private func dismiss() {
        guard model.dropNotice?.id == notice.id else { return }
        withAnimation(.snappy(duration: 0.2)) { model.dropNotice = nil }
    }
}
