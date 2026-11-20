import AppKit
import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

// MARK: - Drag to reorder

/// The rows being dragged and where they would land, for the insertion line, the 30% ghost
/// slot and the Ready header's "drop here to unqueue" note.
@MainActor @Observable
final class DragState {
    var ids: [FileItem.ID] = []
    var active = false
    var target: (section: QueueSection, index: Int?)?
    var hoveringReady = false
    @ObservationIgnored private var monitor: Any?

    func begin(_ ids: [FileItem.ID]) {
        self.ids = ids
        active = true
        // A cancelled drag (Esc, or dropped outside the list) tells no drop delegate, so the
        // next pointer event after the drag session clears the state.
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] e in
                self?.end()
                return e
            }
        }
    }

    func end() {
        active = false
        target = nil
        hoveringReady = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func isDraggingQueued(_ model: AppModel) -> Bool {
        active && ids.contains { model.queue[$0]?.state == .queued }
    }

    func isTarget(_ section: QueueSection, _ index: Int) -> Bool {
        guard active, let target, target.section == section else { return false }
        return target.index == index
    }
}

/// Makes Ready and Up next rows draggable and Up next rows drop targets.
struct RowDrag: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DragState.self) private var drag
    var item: FileItem
    var section: QueueSection?
    var index: Int

    func body(content: Content) -> some View {
        let draggable = !model.selectMode && (section == .upNext || section == .ready)
        content
            .opacity(drag.active && drag.ids.contains(item.id) ? 0.3 : 1)
            .overlay(alignment: .top) {
                if section == .upNext && drag.isTarget(.upNext, index) { InsertionLine().offset(y: -1) }
            }
            .modifier(OptionalDrag(enabled: draggable) {
                // Dragging a selected row drags the whole (draggable) selection.
                let ids = model.selection.contains(item.id)
                    ? model.selectedItems.filter { model.queue.section(of: $0) == .upNext || $0.state == .ready }.map(\.id)
                    : [item.id]
                drag.begin(ids)
                return NSItemProvider(object: ids.map(\.uuidString).joined(separator: ",") as NSString)
            })
            .onDrop(of: [.plainText], delegate: RowDropDelegate(model: model, drag: drag, section: section, index: index))
    }
}

private struct OptionalDrag: ViewModifier {
    var enabled: Bool
    var provider: () -> NSItemProvider

    func body(content: Content) -> some View {
        if enabled { content.onDrag(provider) } else { content }
    }
}

/// 2 pt blue line with a ring at its leading end, like the `List` insertion indicator.
struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Palette.blue, lineWidth: 2).frame(width: 8, height: 8)
            Rectangle().fill(Palette.blue).frame(height: 2)
        }
        .frame(height: 8)
        .offset(y: -4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct RowDropDelegate: DropDelegate {
    var model: AppModel
    var drag: DragState
    var section: QueueSection?
    var index: Int

    /// Up next rows take an insertion point; dropping on a Ready row unqueues.
    private func target(_ info: DropInfo) -> (QueueSection, Int?)? {
        switch section {
        case .upNext: (.upNext, info.location.y < 30 ? index : index + 1)
        case .ready: (.ready, nil)
        default: nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool { drag.active && target(info) != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let t = target(info) else { return DropProposal(operation: .forbidden) }
        drag.target = t
        drag.hoveringReady = t.0 == .ready
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        drag.target = nil
        drag.hoveringReady = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let t = target(info) else { return false }
        let ids = drag.ids
        withAnimation(.snappy(duration: 0.2)) { model.drop(ids, into: t.0, at: t.1) }
        drag.end()
        return true
    }
}

/// Drop target for a section header: Up next at its top, or Ready (unqueue).
struct SectionDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DragState.self) private var drag
    var section: QueueSection
    var index: Int?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if section == .upNext, let index, drag.isTarget(.upNext, index) { InsertionLine().offset(y: 2) }
            }
            .onDrop(of: [.plainText], delegate: SectionDropDelegate(model: model, drag: drag, section: section, index: index))
    }
}

struct SectionDropDelegate: DropDelegate {
    var model: AppModel
    var drag: DragState
    var section: QueueSection
    var index: Int?

    func validateDrop(info: DropInfo) -> Bool { drag.active }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.target = (section, index)
        drag.hoveringReady = section == .ready
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        drag.target = nil
        drag.hoveringReady = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let ids = drag.ids
        withAnimation(.snappy(duration: 0.2)) { model.drop(ids, into: section, at: index) }
        drag.end()
        return true
    }
}

/// The strip below the last Up next row (append), or, while a Ready row is dragged and Up next
/// is empty, a dashed "Drop here to queue" zone standing in for the hidden section.
struct UpNextTailDrop: View {
    @Environment(AppModel.self) private var model
    @Environment(DragState.self) private var drag
    var placeholder = false

    var body: some View {
        let index = model.queue.upNext.count
        Group {
            if placeholder {
                Text("Drop here to queue")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(drag.isTarget(.upNext, index) ? Palette.blue : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(drag.isTarget(.upNext, index) ? Palette.blueT : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(drag.isTarget(.upNext, index) ? Palette.blue : Color(nsColor: .tertiaryLabelColor),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .padding(.vertical, 6)
            } else {
                Color.clear
                    .frame(height: 10)
                    .overlay(alignment: .top) { if drag.isTarget(.upNext, index) { InsertionLine() } }
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], delegate: SectionDropDelegate(model: model, drag: drag, section: .upNext, index: index))
    }
}

// MARK: - Swipes

/// A swipe action tile.
struct SwipeAction: Identifiable {
    var id: String { title }
    var title: String
    var systemImage: String
    var color: Color
    /// Runs on a full swipe.
    var bold = false
    var run: () -> Void
}

/// Two-finger horizontal swipes on the row under the pointer, from scroll-wheel events
/// (a SwiftUI ScrollView has no swipe actions on macOS). One row is open at a time.
@MainActor @Observable
final class SwipeController {
    static let tileWidth: CGFloat = 78, gap: CGFloat = 5

    /// Queue rows (FileItem.ID) and History rows (LibraryEntry.ID) share one controller.
    var hoveredID: AnyHashable?
    private(set) var openID: AnyHashable?
    /// > 0 reveals the leading actions, < 0 the trailing ones.
    private(set) var offset: CGFloat = 0
    private(set) var tracking = false
    /// Set by each row while it is hovered or open: its widths and its actions.
    @ObservationIgnored var rows: [AnyHashable: (width: CGFloat, leading: [SwipeAction], trailing: [SwipeAction])] = [:]
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var horizontal: Bool?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] e in
            // Local monitors run on the main thread.
            let box = EventBox(event: e)
            return MainActor.assumeIsolated { EventBox(event: self?.handle(box.event!) ?? box.event) }.event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func revealWidth(_ n: Int) -> CGFloat { n == 0 ? 0 : CGFloat(n) * tileWidth + CGFloat(n) * gap }

    func offset(for id: AnyHashable) -> CGFloat { openID == id ? offset : 0 }

    /// Past this the bold action fills the row and runs on release.
    func isFull(_ id: AnyHashable) -> Bool {
        guard openID == id, let row = rows[id] else { return false }
        let actions = offset > 0 ? row.leading : row.trailing
        guard actions.contains(where: \.bold) else { return false }
        return abs(offset) > Self.revealWidth(actions.count) + 60
    }

    /// Opens a row as a swipe would (dev hook `TRANSCRIBE_HISTORY_SWIPE`, for snapshots).
    func open(_ id: AnyHashable, offset: CGFloat) {
        openID = id
        self.offset = offset
    }

    func close() {
        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
        openID = nil
        tracking = false
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.type == .leftMouseDown {
            if openID != nil && !tracking { close() }
            return e
        }
        // Momentum after the fingers lift: swallow it while a row is being swiped.
        if !e.momentumPhase.isEmpty { return tracking || openID != nil && horizontal == true ? nil : e }
        if e.phase.contains(.began) {
            horizontal = nil
            if openID != nil && openID != hoveredID { close() }
            guard let id = hoveredID, rows[id] != nil else { return e }
            if openID != id { offset = 0 }
            openID = id
            tracking = true
            return e
        }
        guard tracking, let id = openID, let row = rows[id] else { return e }
        if horizontal == nil, abs(e.scrollingDeltaX) + abs(e.scrollingDeltaY) > 0.5 {
            horizontal = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY)
        }
        if horizontal == false {
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { tracking = false; if offset == 0 { openID = nil } }
            return e
        }
        if e.phase.contains(.changed) {
            var next = offset + e.scrollingDeltaX
            if row.leading.isEmpty { next = min(next, 0) }
            if row.trailing.isEmpty { next = max(next, 0) }
            offset = max(min(next, row.width - 64), -(row.width - 64))
            return nil
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            tracking = false
            settle(id, row)
            return nil
        }
        return e
    }

    private func settle(_ id: AnyHashable, _ row: (width: CGFloat, leading: [SwipeAction], trailing: [SwipeAction])) {
        let actions = offset > 0 ? row.leading : row.trailing
        let reveal = Self.revealWidth(actions.count)
        if isFull(id), let bold = actions.first(where: \.bold) {
            close()
            bold.run()
            return
        }
        withAnimation(.snappy(duration: 0.22)) {
            if abs(offset) > reveal / 2 && reveal > 0 {
                offset = offset > 0 ? reveal : -reveal
            } else {
                offset = 0
            }
        }
        if offset == 0 { openID = nil }
    }
}

private struct EventBox: @unchecked Sendable { let event: NSEvent? }

/// A 78 pt swipe tile: symbol above a label, on the action color.
struct SwipeTile: View {
    var action: SwipeAction
    var onRun: () -> Void

    var body: some View {
        Button {
            onRun()
            action.run()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.systemImage).font(.system(size: 15, weight: .semibold))
                Text(action.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Palette.onFill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(action.color, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }
}

// MARK: - Split button

/// `[▶ Title | ▴]`: a flat button with a menu half (bottom bar).
struct SplitButton<MenuContent: View>: View {
    var title: String
    var systemImage: String?
    var prominent = false
    var help: String
    var disabled = false
    /// `chevron.up` in the bottom bar, `chevron.down` in toolbars.
    var chevron = "chevron.up"
    var action: () -> Void
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 1) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                    Text(title).lineLimit(1)
                }
            }
            .buttonStyle(SplitHalfStyle(prominent: prominent, corners: .leading))
            .disabled(disabled)
            .help(help)

            Menu(content: menu) {
                Image(systemName: chevron).font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 30)
                    .foregroundStyle(prominent ? Palette.onFill : Color.primary)
                    .background(prominent ? Palette.blue : Palette.controlFill,
                                in: UnevenRoundedRectangle(bottomTrailingRadius: 7, topTrailingRadius: 7))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(title) options")
        }
        .fixedSize()
    }
}

private struct SplitHalfStyle: ButtonStyle {
    enum Corners { case leading, trailing }
    @Environment(\.isEnabled) private var enabled
    var prominent: Bool
    var corners: Corners
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        let r: CGFloat = 7
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: corners == .leading ? r : 0, bottomLeadingRadius: corners == .leading ? r : 0,
            bottomTrailingRadius: corners == .trailing ? r : 0, topTrailingRadius: corners == .trailing ? r : 0)
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .padding(.horizontal, width == nil ? 10 : 0)
            .frame(width: width, height: 30)
            .foregroundStyle(prominent ? Palette.onFill : Color.primary)
            .background(prominent ? Palette.blue : Palette.controlFill, in: shape)
            .opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.5)
            .contentShape(shape)
    }
}
