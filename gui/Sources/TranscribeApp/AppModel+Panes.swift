import AppKit
import SwiftUI
import TranscribeKit

/// Pane visibility for the custom three-pane layout.
extension AppModel {
    enum Pane { case center, inspector }

    var paneLayout: PaneLayout {
        PaneLayout.resolve(width: windowWidth, wantCenter: showCenter, wantInspector: showInspector,
                           queuePreferred: queueWidthPreference, inspectorPreferred: inspectorWidthPreference)
    }

    var centerVisible: Bool { paneLayout.center != nil }
    var inspectorVisible: Bool { paneLayout.inspector != nil }

    /// Toolbar and menu toggle. Showing a pane the window is too narrow for grows the window
    /// when the screen has room; otherwise the other pane collapses, as in Mail.
    /// Clears every selection, so the inspector shows the defaults for new files.
    func showDefaults() {
        selectMode = false
        selection = []
        historySelection = []
        if !inspectorVisible { togglePane(.inspector) }
    }

    func togglePane(_ pane: Pane) {
        let visible = pane == .center ? centerVisible : inspectorVisible
        if visible {
            set(pane, false)
            return
        }
        set(pane, true)
        if pane == .center ? centerVisible : inspectorVisible { return }
        let needed: Double
        switch pane {
        case .center:
            needed = PaneLayout.centerThreshold + (inspectorVisible ? PaneLayout.inspectorRange.lowerBound : 0)
        case .inspector:
            needed = PaneLayout.inspectorThreshold(withCenter: showCenter)
        }
        let ideal = pane == .center ? PaneLayout.centerIdeal : PaneLayout.inspectorIdeal
        if growWindow(by: max(needed - windowWidth, ideal)) { return }
        // No room: give the window to this pane.
        set(pane == .center ? .inspector : .center, false)
    }

    private func set(_ pane: Pane, _ on: Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            if pane == .center { showCenter = on } else { showInspector = on }
        }
    }

    /// Widens the main window by `delta`, moving it left if needed. False when the screen is too narrow.
    private func growWindow(by delta: Double) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let screen = window.screen else { return false }
        let visible = screen.visibleFrame
        var frame = window.frame
        guard frame.width + delta <= visible.width else { return false }
        frame.size.width += delta
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        frame.origin.x = max(frame.origin.x, visible.minX)
        window.setFrame(frame, display: true, animate: true)
        return true
    }
}

extension EnvironmentValues {
    /// Width of the pane a view sits in, for the narrow-width content rules.
    @Entry var paneWidth: Double = 400
}
