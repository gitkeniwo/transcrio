import SwiftUI
import TranscribeKit

/// A 60 pt queue row: leading slot (chevron, grip or check), file icon, name and subtitle,
/// waveform (or hover buttons), retry, status pill. Swipes reveal action tiles.
struct QueueRow: View {
    typealias Output = (format: OutputFormat, path: String)
    @Environment(AppModel.self) private var model
    @Environment(SwipeController.self) private var swipe
    @Environment(\.paneWidth) private var paneWidth
    var item: FileItem
    var section: QueueSection?
    var selected: Bool
    var joinTop = false
    var joinBottom = false
    @State private var hovering = false
    @State private var width: CGFloat = 300

    var body: some View {
        let status = model.status(of: item)
        let outputs = item.result?.orderedOutputs ?? []
        let isExpanded = model.expanded.contains(item.id)
        let actions = swipeActions()
        let offset = swipe.offset(for: item.id)
        let full = swipe.isFull(item.id)

        VStack(spacing: 0) {
            HStack(spacing: SwipeController.gap) {
                if offset > 0 { tiles(actions.leading, full: full).frame(width: max(0, offset - SwipeController.gap)) }
                card(status: status, outputs: outputs, isExpanded: isExpanded, swiped: offset != 0)
                    .frame(width: full ? 64 : nil)
                    // minWidth 0: the frame keeps the row's share and the full-width card overflows away from
                // the tiles (without it the frame grew to the card and the HStack overflowed, centred).
                .frame(minWidth: 0, maxWidth: full ? 64 : .infinity, alignment: offset < 0 ? .trailing : .leading)
                .clipped()
                if offset < 0 { tiles(actions.trailing, full: full).frame(width: max(0, -offset - SwipeController.gap)) }
            }
            .frame(height: 60)
            .background {
                GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } }
            }

            if isExpanded && !outputs.isEmpty { outputList(outputs) }
        }
        .contentShape(Rectangle())
        .onHover { on in
            hovering = on
            if on {
                swipe.hoveredID = item.id
                register(actions)
            } else if swipe.hoveredID == AnyHashable(item.id) {
                swipe.hoveredID = nil
            }
        }
        .onChange(of: width) { register(actions) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(StatusText.accessibility(status))")
        .accessibilityActions {
            ForEach(actions.leading + actions.trailing) { a in Button(a.title, action: a.run) }
        }
    }

    private func register(_ actions: (leading: [SwipeAction], trailing: [SwipeAction])) {
        if model.selectMode {
            swipe.rows[item.id] = nil
        } else {
            swipe.rows[item.id] = (width, actions.leading, actions.trailing)
        }
    }

    // MARK: Card

    private func card(status: RowStatus, outputs: [Output], isExpanded: Bool, swiped: Bool) -> some View {
        // Below 340 the retry button shows on hover only; below 320 the chevron
        // goes (→/← still expand), the waveform has 10 bars and the pill shrinks to 46 pt.
        let narrow = paneWidth < 320
        let showRetry = paneWidth >= 340 || hovering || selected
        let showHoverButtons = hovering && !model.selectMode && !swiped

        return HStack(spacing: narrow ? 8 : 10) {
            leadingSlot(outputs: outputs, isExpanded: isExpanded, narrow: narrow)

            FileTypeIcon(kind: item.kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    if let diff = differs {
                        Circle().fill(selected ? Color.white : Palette.blue).frame(width: 6, height: 6)
                            .help(diff)
                            .accessibilityLabel(diff)
                    }
                    Text(model.rowSubtitle(status, item: item))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(subtitleColor(status))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showHoverButtons {
                hoverButtons(status)
            } else {
                let progress = item.waveformProgress(status)
                RowWaveform(levels: model.waveforms[item.id]?.levels(count: narrow ? 10 : 16),
                            fraction: progress.fraction, tone: progress.tone, estimated: progress.estimated,
                            selected: selected, count: narrow ? 10 : 16)
            }

            if case .failed = status, showRetry, !showHoverButtons {
                Button { model.retry(item.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary)
                .help("Retry this file")
                .accessibilityLabel("Retry \(item.name)")
            }

            if item.checking {
                Spinner(size: 14).foregroundStyle(selected ? Color.white : Color.secondary)
                    .frame(width: narrow ? 46 : 54, height: 26)
                    .accessibilityLabel("Checking")
            } else {
                StatusPill(status: status, selected: selected, minWidth: narrow ? 46 : 54)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: swiped ? width : nil, height: 60)
        .frame(maxWidth: .infinity)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background { rowBackground(swiped: swiped) }
        .clipShape(RoundedRectangle(cornerRadius: swiped ? 10 : 0))
        .shadow(color: .black.opacity(swiped ? 0.14 : 0), radius: 6, y: 2)
        .overlay(alignment: .bottom) {
            if !selected && !isExpanded && !swiped && !hovering {
                Rectangle().fill(Palette.hairline.opacity(0.7)).frame(height: 1).padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder private func rowBackground(swiped: Bool) -> some View {
        let r: CGFloat = 10
        if selected {
            UnevenRoundedRectangle(topLeadingRadius: joinTop ? 0 : r, bottomLeadingRadius: joinBottom ? 0 : r,
                                   bottomTrailingRadius: joinBottom ? 0 : r, topTrailingRadius: joinTop ? 0 : r)
                .fill(Palette.selection)
        } else if swiped {
            RoundedRectangle(cornerRadius: r).fill(Palette.cardFill)
        } else if hovering {
            RoundedRectangle(cornerRadius: r).fill(Palette.controlFill)
        }
    }

    /// Chevron in Ready and Finished, grip in Up next, check circle in Select mode.
    @ViewBuilder private func leadingSlot(outputs: [Output], isExpanded: Bool, narrow: Bool) -> some View {
        if model.selectMode {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? Color.white : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 20)
                .accessibilityLabel(selected ? "Selected" : "Not selected")
        } else if section == .upNext {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 12, height: 24)
                .help("Drag to reorder")
                .accessibilityHidden(true)
        } else if !narrow {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isExpanded { model.expanded.remove(item.id) } else { model.expanded.insert(item.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.white : Color(nsColor: .tertiaryLabelColor))
            .opacity(outputs.isEmpty ? 0.35 : 1)
            .disabled(outputs.isEmpty)
            .accessibilityLabel(isExpanded ? "Hide output files" : "Show output files")
        }
    }

    /// Two 24 pt round buttons that replace the waveform on hover: the first leading action and `…`.
    private func hoverButtons(_ status: RowStatus) -> some View {
        let primary = swipeActions().leading.first ?? swipeActions().trailing.first { $0.bold && item.state.isRunning }
        let filled = item.state == .ready
        return HStack(spacing: 6) {
            if let primary {
                Button(action: primary.run) {
                    Image(systemName: primary.systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(filled ? Palette.onFill : (selected ? Color.white : Color.primary))
                        .background(filled ? Palette.blue : .clear, in: Circle())
                        .overlay { if !filled { Circle().strokeBorder(selected ? Color.white.opacity(0.7) : Palette.hairline, lineWidth: 1) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(primary.title)
                .accessibilityLabel("\(primary.title) \(item.name)")
            }
            Menu {
                RowMenu(targets: model.selection.contains(item.id) ? model.selectedItems : [item], clicked: item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .overlay(Circle().strokeBorder(selected ? Color.white.opacity(0.7) : Palette.hairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(item.name)")
        }
        .frame(width: 54, alignment: .trailing)
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

    private func outputList(_ outputs: [Output]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(outputs, id: \.path) { output in
                HStack(spacing: 8) {
                    FormatBadge(format: output.format, style: .inline)
                    Text((output.path as NSString).lastPathComponent)
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.open(output.path) }
                .contextMenu {
                    Button("Open") { model.open(output.path) }
                    Button("Show in Finder") { model.reveal([output.path]) }
                }
                .help(output.path)
            }
        }
        .padding(.leading, 64)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline.opacity(0.7)).frame(height: 1).padding(.horizontal, 4) }
    }

    // MARK: Helpers

    /// The blue-dot tooltip, for Ready and Queued rows whose options differ from the defaults.
    private var differs: String? {
        guard item.state == .ready || item.state == .queued else { return nil }
        return item.options.differenceDescription(from: model.options)
    }

    private func subtitleColor(_ s: RowStatus) -> Color {
        if selected { return .white.opacity(0.88) }
        if case .failed = s { return Palette.red }
        return .secondary
    }

    /// Swipe actions: leading and trailing tiles per row state.
    private func swipeActions() -> (leading: [SwipeAction], trailing: [SwipeAction]) {
        let id = item.id
        let m = model
        let options = SwipeAction(title: "Options", systemImage: "slider.horizontal.3", color: Palette.gray) {
            m.selection = [id]
            if !m.inspectorVisible { m.togglePane(.inspector) }
        }
        func remove(bold: Bool) -> SwipeAction {
            SwipeAction(title: "Remove", systemImage: "trash", color: Palette.red, bold: bold) { withAnimation { m.remove([id]) } }
        }
        switch item.state {
        case .ready:
            return ([SwipeAction(title: "Start", systemImage: "play.fill", color: Palette.blue, bold: true) { m.start([id]) }],
                    [options, remove(bold: true)])
        case .queued:
            return ([SwipeAction(title: "Run Next", systemImage: "arrow.up.to.line", color: Palette.blue, bold: true) { m.runNext([id]) }],
                    [SwipeAction(title: "Unqueue", systemImage: "arrow.uturn.down", color: Palette.gray) { m.unqueue([id]) }, remove(bold: false)])
        case .running:
            return ([], [SwipeAction(title: "Stop", systemImage: "stop.fill", color: Palette.red, bold: true) { m.stop(id) }])
        case .done:
            return ([SwipeAction(title: "Quick Look", systemImage: "eye", color: Palette.blue, bold: true) { m.toggleQuickLook(id) },
                     SwipeAction(title: "Reveal", systemImage: "folder", color: Palette.gray) { m.revealOutputs([id]) }],
                    [remove(bold: true)])
        case .failed, .stopped:
            return ([SwipeAction(title: "Retry", systemImage: "arrow.clockwise", color: Palette.blue, bold: true) { m.retry(id) }],
                    [options, remove(bold: false)])
        }
    }
}
