import AppKit
import SwiftUI

/// Centers the traffic lights in the panes' 52 pt top bar.
///
/// The hidden title bar keeps them in a 28 pt strip at the very top, above the middle of the bar.
/// AppKit lays that strip out again on resize, key changes and full screen, so this re-applies.
struct TrafficLightCentering: NSViewRepresentable {
    var barHeight: CGFloat = 52

    func makeNSView(context: Context) -> NSView { Probe(barHeight: barHeight) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let barHeight: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(barHeight: CGFloat) {
            self.barHeight = barHeight
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // After AppKit's own title bar layout for this change.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
                })
            }
            apply()
        }

        private func apply() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview
            else { return }
            let height = window.frame.height
            if container.frame.height != barHeight || container.frame.maxY != height {
                container.frame = NSRect(x: container.frame.minX, y: height - barHeight, width: container.frame.width, height: barHeight)
                titlebar.frame = container.bounds
            }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, kind) in kinds.enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                let y = ((barHeight - button.frame.height) / 2).rounded()
                button.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: titlebar.isFlipped ? y : barHeight - button.frame.height - y))
            }
        }
    }
}
