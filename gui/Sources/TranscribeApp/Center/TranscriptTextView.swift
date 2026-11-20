import AppKit
import SwiftUI
import TranscribeKit

/// One paragraph (or cue) of the finished preview with the times it covers.
struct PreviewParagraph: Equatable {
    var text: String
    var time: ClosedRange<Double>?
    var estimated = false
}

/// Shared state between the preview's text view and the overview above it.
@MainActor @Observable
final class PreviewController {
    /// Time span shown in the text view.
    var visible: ClosedRange<Double>?
    /// Time span of the paragraph under the pointer.
    var hovered: ClosedRange<Double>?
    /// Span marked by Show in Overview, cleared after a moment.
    var marked: ClosedRange<Double>?

    @ObservationIgnored weak var textView: TranscriptTextView?
    @ObservationIgnored private var markTask: Task<Void, Never>?

    /// Click on the overview: the paragraph at `time` moves to the top.
    func seek(_ time: Double) { textView?.scroll(toParagraphAt: time) }

    /// Drag of the visible box: the top of the text follows `time` continuously.
    func scrollTop(to time: Double) { textView?.scroll(topTime: time) }

    /// History's Text search: highlight every match of `query` and bring the first into view.
    /// An empty query clears the highlights.
    func reveal(_ query: String) { textView?.reveal(query) }

    func mark(_ span: ClosedRange<Double>) {
        marked = span
        markTask?.cancel()
        markTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.marked = nil
        }
    }
}

/// The finished transcript: a single read-only `NSTextView` (selection across paragraphs, the
/// native find bar, overlay scrollers) with time capsules drawn in a 70 pt gutter and a hover
/// highlight per paragraph. The header (title and capsules) sits in the top inset.
struct TranscriptPreviewView<Header: View>: NSViewRepresentable {
    var paragraphs: [PreviewParagraph]
    var isCues: Bool
    var controller: PreviewController
    @ViewBuilder var header: () -> Header

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PreviewScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = TranscriptTextView.make()
        tv.headerView = NSHostingView(rootView: AnyView(header()))
        tv.controller = controller
        controller.textView = tv
        scroll.documentView = tv
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(tv, selector: #selector(TranscriptTextView.clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        tv.set(paragraphs: paragraphs, isCues: isCues)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? TranscriptTextView else { return }
        (tv.headerView as? NSHostingView<AnyView>)?.rootView = AnyView(header())
        tv.controller = controller
        controller.textView = tv
        if tv.paragraphs != paragraphs || tv.isCues != isCues {
            tv.set(paragraphs: paragraphs, isCues: isCues)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        tv.needsLayout = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        if let tv = scroll.documentView { NotificationCenter.default.removeObserver(tv) }
    }
}

/// Keeps the text view exactly as wide as the visible area.
final class PreviewScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let doc = documentView, doc.frame.width != contentSize.width else { return }
        doc.setFrameSize(NSSize(width: contentSize.width, height: doc.frame.height))
    }
}

final class TranscriptTextView: NSTextView {
    /// The preview that last had focus, for the Find… and Copy with Timestamps menu items.
    @MainActor static weak var active: TranscriptTextView?

    weak var controller: PreviewController?
    private(set) var paragraphs: [PreviewParagraph] = []
    private(set) var isCues = false
    private var ranges: [NSRange] = []
    private var timed = false

    var headerView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let headerView { addSubview(headerView) }
        }
    }

    private let sidePad: CGFloat = 26
    private let gutter: CGFloat = 70
    private let topPad: CGFloat = 20
    private let bottomPad: CGFloat = 28
    private var headerHeight: CGFloat = 0
    private var textTop: CGFloat { topPad + headerHeight + (headerHeight > 0 ? 18 : 0) }
    private var textLeft: CGFloat { sidePad + (timed ? gutter : 0) }
    private let bodyFont = NSFont.systemFont(ofSize: 14)

    static func make() -> TranscriptTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let tv = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.allowsUndo = false
        tv.setAccessibilityLabel("Transcript")
        return tv
    }

    func set(paragraphs: [PreviewParagraph], isCues: Bool) {
        self.paragraphs = paragraphs
        self.isCues = isCues
        timed = paragraphs.contains { $0.time != nil }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = isCues ? 3 : 8
        style.paragraphSpacing = isCues ? 14 : 20
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let text = NSMutableAttributedString()
        ranges = []
        for (i, p) in paragraphs.enumerated() {
            let s = i + 1 < paragraphs.count ? p.text + "\n" : p.text
            ranges.append(NSRange(location: text.length, length: (p.text as NSString).length))
            text.append(NSAttributedString(string: s, attributes: attrs))
        }
        textStorage?.setAttributedString(text)
        reveal("")
        hover = nil
        rowsCache = nil
        updateInsets()
        reportVisible()
    }

    // MARK: Geometry

    override var textContainerOrigin: NSPoint { NSPoint(x: textLeft, y: textTop) }

    private func updateInsets() {
        // The text view sizes itself to the used height plus twice this inset.
        textContainerInset = NSSize(width: 0, height: (textTop + bottomPad) / 2)
        textContainer?.containerSize = NSSize(width: max(40, bounds.width - textLeft - sidePad), height: .greatestFiniteMagnitude)
        invalidateTextContainerOrigin()
        rowsCache = nil
        needsDisplay = true
    }

    /// The document view always starts at the clip view's origin (resizing could leave it offset).
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(.zero) }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            layoutHeader()
            updateInsets()
            sizeToFit()
        }
    }

    override func layout() {
        super.layout()
        layoutHeader()
    }

    private func layoutHeader() {
        guard let headerView else { return }
        let w = max(40, bounds.width - 2 * sidePad)
        headerView.frame.size.width = w
        let h = ceil(headerView.fittingSize.height)
        headerView.frame = NSRect(x: sidePad, y: topPad, width: w, height: h)
        if h != headerHeight {
            headerHeight = h
            updateInsets()
            sizeToFit()
        }
    }

    private struct Row { var rect: NSRect; var firstLine: NSRect }
    private var rowsCache: [Row]?

    /// Each paragraph's line fragments in view coordinates.
    private var rows: [Row] {
        if let rowsCache { return rowsCache }
        guard let lm = layoutManager, let tc = textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let o = textContainerOrigin
        let out = ranges.map { r -> Row in
            let glyphs = lm.glyphRange(forCharacterRange: r.length > 0 ? r : NSRange(location: r.location, length: 0), actualCharacterRange: nil)
            var used = NSRect.null, first = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: glyphs.length > 0 ? glyphs : NSRange(location: glyphs.location, length: 1)) { _, usedRect, _, _, _ in
                if first.isNull { first = usedRect }
                used = used.union(usedRect)
            }
            if used.isNull { used = NSRect(x: 0, y: 0, width: 0, height: self.bodyFont.pointSize) }
            if first.isNull { first = used }
            return Row(rect: used.offsetBy(dx: o.x, dy: o.y), firstLine: first.offsetBy(dx: o.x, dy: o.y))
        }
        rowsCache = out
        return out
    }

    /// The highlight behind a paragraph: gutter and text, with some air.
    private func rowBox(_ i: Int) -> NSRect {
        let r = rows[i].rect
        let style = isCues ? 3.0 : 8.0
        return NSRect(x: sidePad - 10, y: r.minY - 7, width: bounds.width - 2 * sidePad + 20, height: r.height - style + 6)
    }

    private func paragraph(atY y: CGFloat) -> Int? {
        rows.indices.first { rowBox($0).minY <= y && y <= rowBox($0).maxY }
    }

    /// Piecewise-linear map between scroll offset and time through each timed paragraph's
    /// top and bottom, so the overview box moves smoothly.
    private var anchors: [(y: CGFloat, t: Double)] {
        zip(rows, paragraphs).flatMap { row, p -> [(y: CGFloat, t: Double)] in
            guard let t = p.time else { return [] }
            return [(rowTop(row), t.lowerBound), (rowTop(row) + row.rect.height, t.upperBound)]
        }
    }

    private func rowTop(_ row: Row) -> CGFloat { row.rect.minY }

    private func time(atY y: CGFloat) -> Double? {
        let a = anchors
        guard let first = a.first, let last = a.last else { return nil }
        if y <= first.y { return first.t }
        if y >= last.y { return last.t }
        let i = a.firstIndex { $0.y >= y } ?? a.count - 1
        let lo = a[i - 1], hi = a[i]
        let f = hi.y > lo.y ? Double((y - lo.y) / (hi.y - lo.y)) : 0
        return lo.t + f * (hi.t - lo.t)
    }

    private func y(atTime t: Double) -> CGFloat? {
        let a = anchors
        guard let first = a.first, let last = a.last else { return nil }
        if t <= first.t { return first.y }
        if t >= last.t { return last.y }
        let i = a.firstIndex { $0.t >= t } ?? a.count - 1
        let lo = a[i - 1], hi = a[i]
        let f = hi.t > lo.t ? CGFloat((t - lo.t) / (hi.t - lo.t)) : 0
        return lo.y + f * (hi.y - lo.y)
    }

    // MARK: Scrolling and the overview

    @objc func clipBoundsChanged(_ note: Notification) { reportVisible() }

    private func reportVisible() {
        guard let controller else { return }
        let v = visibleRect
        guard timed, v.height > 0, let a = time(atY: max(v.minY, textTop)), let b = time(atY: v.maxY) else {
            if controller.visible != nil { controller.visible = nil }
            return
        }
        let span = a...max(a, b)
        if controller.visible != span { controller.visible = span }
    }

    private func scroll(toY y: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func scroll(toParagraphAt time: Double) {
        guard let i = paragraphs.lastIndex(where: { ($0.time?.lowerBound ?? .infinity) <= time }) ?? paragraphs.firstIndex(where: { $0.time != nil }) else { return }
        scroll(toY: rowBox(i).minY - 6)
    }

    func scroll(topTime time: Double) {
        guard let y = y(atTime: time) else { return }
        scroll(toY: y)
    }

    // MARK: Search matches

    func reveal(_ query: String) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let all = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        let found = TranscriptSearchIndex.matches(of: query, in: string)
        guard let first = found.first else { return }
        // The system find highlight, with dark text as in the Find bar (both appearances).
        for r in found {
            lm.addTemporaryAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], forCharacterRange: r)
        }
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: first, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let clip = enclosingScrollView?.contentView.bounds.height ?? 400
        // A third of the way down, so the lines before it give context.
        scroll(toY: rect.minY - clip / 3)
        DispatchQueue.main.async { [weak self] in self?.showFindIndicator(for: first) }
    }

    // MARK: Hover

    private var hover: Int? {
        didSet { if hover != oldValue { hoverChanged(from: oldValue) } }
    }
    private var hoverAlpha: CGFloat = 1
    private var fadeTimer: Timer?
    private var toolbar: NSHostingView<HoverToolbar>?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        hover = p.y >= textTop - 8 ? paragraph(atY: p.y) : nil
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover = nil
    }

    override func mouseDown(with event: NSEvent) {
        // No hover while a drag selection is in progress.
        hover = nil
        Self.active = self
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        Self.active = self
        return super.becomeFirstResponder()
    }

    private func hoverChanged(from old: Int?) {
        if let old, old < rows.count { setNeedsDisplay(rowBox(old).insetBy(dx: -2, dy: -2)) }
        controller?.hovered = hover.flatMap { paragraphs[$0].time }
        guard let hover else {
            fadeTimer?.invalidate()
            toolbar?.isHidden = true
            return
        }
        hoverAlpha = 0
        fadeTimer?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeStep(since: start) }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        showToolbar(for: hover)
    }

    private func fadeStep(since start: Date) {
        guard let i = hover else { fadeTimer?.invalidate(); return }
        hoverAlpha = min(1, CGFloat(Date().timeIntervalSince(start) / 0.12))
        setNeedsDisplay(rowBox(i).insetBy(dx: -2, dy: -2))
        if hoverAlpha >= 1 { fadeTimer?.invalidate() }
    }

    private func showToolbar(for i: Int) {
        let p = paragraphs[i]
        let view = HoverToolbar(
            copy: { [weak self] in self?.copyParagraph(i) },
            show: p.time.map { span in { [weak self] in self?.controller?.mark(span) } })
        if let toolbar {
            toolbar.rootView = view
        } else {
            let t = NSHostingView(rootView: view)
            addSubview(t)
            toolbar = t
        }
        guard let toolbar else { return }
        let size = toolbar.fittingSize
        let box = rowBox(i)
        toolbar.frame = NSRect(x: box.maxX - size.width - 6, y: box.minY + 4, width: size.width, height: size.height)
        toolbar.isHidden = false
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !rows.isEmpty else { return }
        if let i = hover, i < rows.count {
            let box = rowBox(i)
            if box.intersects(rect) {
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                NSColor.labelColor.withAlphaComponent(0.035 * hoverAlpha).setFill()
                path.fill()
                NSColor.separatorColor.withAlphaComponent(NSColor.separatorColor.alphaComponent * hoverAlpha).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        guard timed else { return }
        let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        for (i, row) in rows.enumerated() {
            guard let t = paragraphs[i].time, row.rect.maxY >= rect.minY - 30, row.rect.minY <= rect.maxY + 30 else { continue }
            let state: CapsuleState
            if i == hover { state = .hovered } else if paragraphs[i].estimated { state = .estimated }
            else if selected.contains(where: { NSIntersectionRange($0, ranges[i]).length > 0 }) { state = .selected } else { state = .plain }
            drawCapsule(Formatting.clock(t.lowerBound), state: state, firstLine: row.firstLine)
        }
    }

    private enum CapsuleState { case plain, selected, hovered, estimated }

    private func drawCapsule(_ text: String, state: CapsuleState, firstLine: NSRect) {
        let capFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let (fg, bg): (NSColor, NSColor) = switch state {
        case .plain: (NSColor(Palette.gray), NSColor(Palette.grayT))
        case .selected: (NSColor(Palette.blue), NSColor(Palette.blueT))
        case .hovered: (NSColor(Palette.onFill), NSColor(Palette.blue))
        case .estimated: (NSColor(Palette.yellow), NSColor(Palette.yellowT))
        }
        let str = NSAttributedString(string: text, attributes: [.font: capFont, .foregroundColor: fg])
        let size = str.size()
        let lineHeight = layoutManager?.defaultLineHeight(for: bodyFont) ?? 17
        let rect = NSRect(x: sidePad, y: firstLine.minY + lineHeight / 2 - 11, width: ceil(size.width) + 16, height: 22)
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        str.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - size.height / 2))
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if timed { setNeedsDisplay(NSRect(x: 0, y: 0, width: textLeft, height: bounds.height)) }
    }

    // MARK: Copy, menu, find

    private func selectedText() -> String {
        let s = string as NSString
        return selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { s.substring(with: $0) }.joined(separator: "\n")
    }

    override func copy(_ sender: Any?) {
        let text = selectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The selection (or the whole transcript) with each paragraph's start time.
    @objc func copyWithTimestamps(_ sender: Any?) {
        let s = string as NSString
        let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        var parts: [String] = []
        for (i, r) in ranges.enumerated() {
            let piece: String
            if selected.isEmpty {
                piece = s.substring(with: r)
            } else {
                let hits = selected.map { NSIntersectionRange($0, r) }.filter { $0.length > 0 }
                guard !hits.isEmpty else { continue }
                piece = hits.map { s.substring(with: $0) }.joined(separator: " ")
            }
            if let t = paragraphs[i].time { parts.append("[\(Formatting.clock(t.lowerBound))] \(piece)") } else { parts.append(piece) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)
    }

    private func copyParagraph(_ i: Int) {
        guard i < paragraphs.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paragraphs[i].text, forType: .string)
    }

    @objc func showFind(_ sender: Any?) {
        window?.makeFirstResponder(self)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }

    @objc private func jumpInOverview(_ sender: NSMenuItem) {
        guard sender.tag < paragraphs.count, let span = paragraphs[sender.tag].time else { return }
        controller?.mark(span)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        let stamped = menu.addItem(withTitle: "Copy with Timestamps", action: #selector(copyWithTimestamps(_:)), keyEquivalent: "C")
        stamped.keyEquivalentModifierMask = [.command, .shift]
        stamped.isHidden = !timed
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: "Find…", action: #selector(showFind(_:)), keyEquivalent: "f")
        let p = convert(event.locationInWindow, from: nil)
        if let i = paragraph(atY: p.y), let t = paragraphs[i].time {
            menu.addItem(.separator())
            let jump = menu.addItem(withTitle: "Jump to \(Formatting.clock(t.lowerBound)) in Overview",
                                    action: #selector(jumpInOverview(_:)), keyEquivalent: "")
            jump.tag = i
        }
        for item in menu.items { item.target = self }
        return menu
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRanges.contains { $0.rangeValue.length > 0 } }
        if item.action == #selector(showFind(_:)) || item.action == #selector(copyWithTimestamps(_:)) || item.action == #selector(jumpInOverview(_:)) { return true }
        return super.validateMenuItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Self.active = self
        reportVisible()
        runDevScript()
    }

    // MARK: Dev hook

    /// The find bar's search field (the hook types into it).
    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let f = view as? NSSearchField { return f }
        for sub in view.subviews {
            if let f = searchField(in: sub) { return f }
        }
        return nil
    }

    private var devScriptStarted = false

    /// `TRANSCRIBE_PREVIEW_SCRIPT="1:hover=2,2:select=1-2,3:copy=stamped,4:find=welcome"`: steps at
    /// seconds after the preview appears, for snapshot checks of hover, selection, copy and find.
    /// `TRANSCRIBE_PREVIEW_LOG` collects the clipboard, the overview spans and the Edit menu.
    private func runDevScript() {
        let env = ProcessInfo.processInfo.environment
        guard !devScriptStarted, let spec = env["TRANSCRIBE_PREVIEW_SCRIPT"] else { return }
        devScriptStarted = true
        let logPath = env["TRANSCRIBE_PREVIEW_LOG"]
        func log(_ line: String) {
            guard let logPath else { return }
            let old = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            try? (old + line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        for step in spec.split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]) else { continue }
            let kv = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
            let arg = kv.count > 1 ? kv[1] : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self else { return }
                switch kv[0] {
                case "hover":
                    self.hover = Int(arg)
                    log("hover \(arg): overview band \(String(describing: self.controller?.hovered))")
                case "select":
                    let ab = arg.split(separator: "-").compactMap { Int($0) }
                    guard ab.count == 2, ab[1] < self.ranges.count else { return }
                    let lo = self.ranges[ab[0]].location + min(10, self.ranges[ab[0]].length)
                    self.window?.makeFirstResponder(self)
                    self.setSelectedRange(NSRange(location: lo, length: NSMaxRange(self.ranges[ab[1]]) - 15 - lo))
                case "copy":
                    if arg == "stamped" { self.copyWithTimestamps(nil) } else { self.copy(nil) }
                    log("copy \(arg):\n" + (NSPasteboard.general.string(forType: .string) ?? "<nil>"))
                case "find":
                    // ⌘F, then type into the find bar's field as a person would, then ↩︎.
                    self.showFind(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard let f = Self.searchField(in: self.enclosingScrollView?.findBarView), let window = self.window else { return }
                        window.makeFirstResponder(f)
                        (window.fieldEditor(false, for: f) as? NSTextView)?.insertText(arg, replacementRange: NSRange(location: NSNotFound, length: 0))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let next = NSMenuItem()
                            next.tag = NSTextFinder.Action.nextMatch.rawValue
                            self.performTextFinderAction(next)
                            log("find \(arg): selection \(self.selectedRange())")
                        }
                    }
                case "scroll":
                    self.controller?.scrollTop(to: Double(arg) ?? 0)
                    log("scroll \(arg): visible \(String(describing: self.controller?.visible))")
                case "seek":
                    self.controller?.seek(Double(arg) ?? 0)
                    log("seek \(arg): visible \(String(describing: self.controller?.visible))")
                case "menu":
                    let edit = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu
                    log("Edit menu: " + (edit?.items.map { $0.isSeparatorItem ? "—" : "\($0.title) \($0.keyEquivalent)" }.joined(separator: " | ") ?? "<none>"))
                    let p = self.rowBox(min(2, self.rows.count - 1))
                    let e = NSEvent.mouseEvent(with: .rightMouseDown, location: self.convert(NSPoint(x: p.midX, y: p.midY), to: nil),
                                               modifierFlags: [], timestamp: 0, windowNumber: self.window?.windowNumber ?? 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    if let e, let m = self.menu(for: e) {
                        log("Context menu: " + m.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
                    }
                default: break
                }
            }
        }
    }
}

/// Copy Paragraph and Show in Overview, floating at the hovered paragraph's top-right corner.
struct HoverToolbar: View {
    var copy: () -> Void
    var show: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            button("doc.on.doc", "Copy Paragraph", copy)
            if let show { button("waveform", "Show in Overview", show) }
        }
        .padding(3)
        .background(Palette.cardFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .padding(6)
    }

    private func button(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
