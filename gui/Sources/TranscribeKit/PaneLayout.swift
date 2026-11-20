import Foundation

/// Widths of the three window panes (queue, center, inspector) for a window width.
///
/// The rules: the inspector collapses first, then the center pane,
/// and the queue alone can go down to 280 pt. While all panes fit, the side panes shrink from
/// their preferred widths toward their minimums together with the center (in proportion to how
/// much each can give), so the 1280 / 1100 / 960 boards come out close to 340/580/360,
/// 320/450/330 and 280/380/300.
public struct PaneLayout: Equatable, Sendable {
    public var queue: Double
    /// `nil` when the center pane is hidden (by the user or because it doesn't fit).
    public var center: Double?
    /// `nil` when the inspector is hidden.
    public var inspector: Double?

    public static let queueRange = 280.0...420.0
    public static let queueIdeal = 340.0
    public static let centerMin = 380.0
    /// Center width at which the side panes reach their preferred widths (the 1280 board).
    public static let centerIdeal = 580.0
    public static let inspectorRange = 300.0...440.0
    public static let inspectorIdeal = 360.0
    /// Narrowest window: the queue alone.
    public static let windowMin = queueRange.lowerBound

    /// Narrowest window that shows the center pane.
    public static var centerThreshold: Double { queueRange.lowerBound + centerMin }

    /// Narrowest window that shows the inspector, given whether the center is shown.
    public static func inspectorThreshold(withCenter: Bool) -> Double {
        queueRange.lowerBound + (withCenter ? centerMin : 0) + inspectorRange.lowerBound
    }

    public init(queue: Double, center: Double?, inspector: Double?) {
        self.queue = queue
        self.center = center
        self.inspector = inspector
    }

    /// - Parameters:
    ///   - width: the window's content width.
    ///   - wantCenter / wantInspector: the user's toggles.
    ///   - queuePreferred / inspectorPreferred: widths the user dragged to (clamped to the ranges).
    public static func resolve(width: Double, wantCenter: Bool, wantInspector: Bool,
                               queuePreferred: Double = queueIdeal,
                               inspectorPreferred: Double = inspectorIdeal) -> PaneLayout {
        let w = max(width, windowMin)
        let qPref = min(max(queuePreferred, queueRange.lowerBound), queueRange.upperBound)
        let iPref = min(max(inspectorPreferred, inspectorRange.lowerBound), inspectorRange.upperBound)
        let showCenter = wantCenter && w >= centerThreshold
        // A center pane that is wanted but squeezed out still counts: the inspector goes first.
        let showInspector = wantInspector && w >= inspectorThreshold(withCenter: wantCenter)

        switch (showCenter, showInspector) {
        case (false, false):
            return PaneLayout(queue: w, center: nil, inspector: nil)
        case (false, true):
            // Queue fills the rest; the inspector keeps its width while the queue can.
            let i = min(iPref, w - queueRange.lowerBound)
            return PaneLayout(queue: w - i, center: nil, inspector: i)
        case (true, false):
            let q = shrink([qPref], mins: [queueRange.lowerBound], centerRoom: w)[0]
            return PaneLayout(queue: q, center: w - q, inspector: nil)
        case (true, true):
            let sides = shrink([qPref, iPref], mins: [queueRange.lowerBound, inspectorRange.lowerBound], centerRoom: w)
            return PaneLayout(queue: sides[0], center: w - sides[0] - sides[1], inspector: sides[1])
        }
    }

    /// Side widths for a window of width `total`: preferred while the center gets at least its
    /// ideal width; below that every pane gives up width in proportion to its slack, so they
    /// all reach their minimums together.
    private static func shrink(_ prefs: [Double], mins: [Double], centerRoom total: Double) -> [Double] {
        let full = prefs.reduce(0, +) + centerIdeal
        let floor = mins.reduce(0, +) + centerMin
        guard total < full else { return prefs }
        let t = full > floor ? max(0, min(1, (full - total) / (full - floor))) : 1
        return zip(prefs, mins).map { p, m in p - (p - m) * t }
    }
}
