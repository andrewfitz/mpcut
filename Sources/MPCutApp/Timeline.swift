import AppKit
import SwiftUI

struct TimelineClip: Identifiable {
    let id: UUID
    let name: String
    let sourceStart: Double
    let sourceEnd: Double
    let sourceDuration: Double
    let keyframes: [Double]

    var duration: Double { sourceEnd - sourceStart }
}

enum TimelineEdge {
    case start
    case end
}

@MainActor
struct SequenceTimeline: View {
    let clips: [TimelineClip]
    let playhead: Double
    let selection: UUID?
    var markedRange: ClosedRange<Double>? = nil
    let onSelect: (UUID) -> Void
    let onSeek: (Double) -> Void
    let onTrim: (UUID, TimelineEdge, Double, Bool) -> Double?
    let onMove: (UUID, Int) -> Void
    let onDrop: ([URL], Int) -> Void
    var onCancelTrim: () -> Void = {}
    var thumbnail: ((UUID, Double, CGSize) async -> CGImage?)? = nil

    @State private var zoom = 0.0
    @State private var editingTime = false
    @State private var timeInput = ""
    @State private var revealTime: Double?
    @State private var revealRequest = 0
    @FocusState private var timeFocused: Bool

    fileprivate var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if editingTime {
                    TextField("Timeline position", text: $timeInput)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .frame(width: 105)
                        .focused($timeFocused)
                        .onSubmit {
                            if let seconds = parseTime(timeInput) {
                                let target = min(max(seconds, 0), duration)
                                onSeek(target)
                                revealTime = target
                                revealRequest += 1
                                editingTime = false
                            } else {
                                NSSound.beep()
                            }
                        }
                        .onExitCommand { editingTime = false }
                        .onChange(of: timeFocused) { _, focused in
                            if !focused { editingTime = false }
                        }
                        .onAppear {
                            DispatchQueue.main.async {
                                if editingTime { timeFocused = true }
                            }
                        }
                } else {
                    Button {
                        timeInput = timelineTime(playhead, milliseconds: true)
                        editingTime = true
                    } label: {
                        Text(timelineTime(playhead, milliseconds: true))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .help("Go to a timeline time")
                    .accessibilityLabel("Timeline position")
                    .accessibilityValue(timelineTime(playhead, milliseconds: true))
                }
                Text("/")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(timelineTime(duration, milliseconds: true))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Sequence duration")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "minus.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $zoom, in: 0...6) { Text("Timeline zoom") }
                        .labelsHidden()
                        .frame(width: 102)
                    Image(systemName: "plus.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .controlSize(.small)
                .help("Timeline zoom")
                Button("Fit") { zoom = 0 }
                    .controlSize(.small)
                    .disabled(zoom == 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider()
            TimelineScrollSurface(timeline: self, zoom: pow(2, zoom),
                                  revealTime: revealTime, revealRequest: revealRequest)
                .frame(height: 119)
        }
    }

    private func parseTime(_ text: String) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(input), seconds.isFinite, seconds >= 0 { return seconds }

        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              let last = parts.last, let seconds = Double(last), seconds.isFinite, (0..<60).contains(seconds),
              let minutes = Int(parts[parts.count - 2]), minutes >= 0 else { return nil }
        if parts.count == 2 { return Double(minutes) * 60 + seconds }
        guard let hours = Int(parts[0]), hours >= 0, minutes < 60 else { return nil }
        return Double(hours) * 3600 + Double(minutes) * 60 + seconds
    }
}

private func timelineTime(_ seconds: Double, milliseconds: Bool = false) -> String {
    let safe = seconds.isFinite ? min(max(0, seconds), Double(Int.max / 2000)) : 0
    let ticks = Int((safe * 1000).rounded())
    let whole = ticks / 1000
    let minutes = whole / 60
    let clock = minutes < 60
        ? String(format: "%02d:%02d", minutes, whole % 60)
        : "\(minutes / 60)" + String(format: ":%02d:%02d", minutes % 60, whole % 60)
    return milliseconds ? clock + String(format: ".%03d", ticks % 1000) : clock
}

private struct TimelineScrollSurface: NSViewRepresentable {
    let timeline: SequenceTimeline
    let zoom: Double
    let revealTime: Double?
    let revealRequest: Int

    func makeNSView(context: Context) -> TimelineScrollView {
        let view = TimelineScrollView()
        view.hasHorizontalScroller = true
        view.horizontalScrollElasticity = .none
        view.verticalScrollElasticity = .none
        view.drawsBackground = false
        view.documentView = view.surface
        return view
    }

    func updateNSView(_ view: TimelineScrollView, context: Context) {
        let zoomChanged = view.surface.zoom != zoom
        let anchor = zoomChanged ? view.surface.zoomAnchor(playhead: timeline.playhead) : nil
        let selectionChanged = view.surface.timeline?.selection != timeline.selection
        view.surface.timeline = timeline
        view.surface.isEditingEnabled = context.environment.isEnabled
        view.surface.zoom = zoom
        view.resizeDocument()
        if let anchor {
            view.scrollHorizontally(to: view.surface.x(at: anchor.time) - anchor.offset)
        }
        if view.revealRequest != revealRequest {
            view.revealRequest = revealRequest
            if let revealTime { view.surface.reveal(time: revealTime) }
        }
        if zoomChanged || selectionChanged {
            view.surface.window?.invalidateCursorRects(for: view.surface)
        }
        view.surface.needsDisplay = true
    }
}

private final class TimelineScrollView: NSScrollView {
    let surface = TimelineSurface()
    var revealRequest = 0

    override func tile() {
        super.tile()
        resizeDocument()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        surface.window?.invalidateCursorRects(for: surface)
        surface.needsDisplay = true
    }

    func resizeDocument() {
        guard documentView != nil else { return }
        let width = max(1, contentView.bounds.width)
        surface.viewportWidth = width
        let newSize = NSSize(
            width: max(width, surface.contentWidth),
            height: max(100, contentView.bounds.height)
        )
        if surface.frame.size != newSize { surface.setFrameSize(newSize) }
    }

    func scrollHorizontally(to x: CGFloat) {
        let visible = contentView.bounds
        let origin = min(max(0, x), max(0, surface.bounds.width - visible.width))
        guard origin != visible.minX else { return }
        contentView.scroll(to: NSPoint(x: origin, y: visible.minY))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        // A conventional vertical wheel can also navigate the timeline at higher zoom.
        if !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0,
           surface.bounds.width > contentView.bounds.width {
            scrollHorizontally(to: contentView.bounds.minX - event.scrollingDeltaY * 12)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class TimelineSurface: NSView {
    private final class AccessibleClip: NSAccessibilityElement {
        var select: (() -> Bool)?

        override func accessibilityPerformPress() -> Bool { select?() ?? false }
    }

    private final class AccessibleRuler: NSAccessibilityElement {
        var seek: ((Double) -> Bool)?
        var setPosition: ((Double) -> Void)?

        override func accessibilityPerformIncrement() -> Bool { seek?(1) ?? false }
        override func accessibilityPerformDecrement() -> Bool { seek?(-1) ?? false }

        override func setAccessibilityValue(_ accessibilityValue: Any?) {
            guard let value = accessibilityValue as? NSNumber, value.doubleValue.isFinite else { return }
            setPosition?(value.doubleValue)
        }

        func updateValue(_ time: Double, duration: Double) {
            super.setAccessibilityValue(NSNumber(value: time))
            setAccessibilityMinValue(NSNumber(value: 0))
            setAccessibilityMaxValue(NSNumber(value: duration))
            setAccessibilityValueDescription(timelineTime(time, milliseconds: true))
        }
    }

    private struct PositionedClip {
        let clip: TimelineClip
        let start: Double
        let sourceStart: Double
        let sourceEnd: Double

        var end: Double { start + (sourceEnd - sourceStart) }
    }

    private enum Interaction {
        case seek
        case clip(UUID, NSPoint)
        case reorder(UUID)
        case trim(UUID, TimelineEdge, Double, CGFloat, CGFloat)
    }

    private struct TrimPosition {
        let id: UUID
        let edge: TimelineEdge
        let time: Double
    }

    private struct ThumbnailKey: Hashable {
        let clip: UUID
        let sourceTime: Double
        let size: CGSize

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.clip == rhs.clip && lhs.sourceTime == rhs.sourceTime && lhs.size == rhs.size
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(clip)
            hasher.combine(sourceTime)
            hasher.combine(size.width)
            hasher.combine(size.height)
        }
    }

    var timeline: SequenceTimeline? {
        didSet {
            if let timeline, !hasSameLayout(as: timeline.clips) {
                rebuildPositions()
                window?.invalidateCursorRects(for: self)
            }
            accessibleRuler.updateValue(timeline?.playhead ?? 0, duration: sequenceDuration)
        }
    }
    var isEditingEnabled = true {
        didSet {
            guard oldValue != isEditingEnabled else { return }
            if !isEditingEnabled {
                let cancelTrim = trimPosition == nil ? nil : timeline?.onCancelTrim
                clearInteraction()
                if let cancelTrim { Task { @MainActor in cancelTrim() } }
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var zoom = 1.0
    var viewportWidth: CGFloat = 1
    private var interaction: Interaction?
    private var trimPosition: TrimPosition?
    private var lastTrimTarget: Double?
    private var lastSeekTarget: Double?
    private var insertionIndex: Int?
    private var dragLocation: NSPoint?
    private var isExternalDrag = false
    private var edgeScrollTimer: Timer?
    private var positions: [PositionedClip] = []
    private var sequenceDuration = 0.0
    private var trimClipIndex: Int?
    private var thumbnailKeys: Set<ThumbnailKey> = []
    private var thumbnails: [ThumbnailKey: CGImage] = [:]
    private var thumbnailOrder: [ThumbnailKey] = []
    private var unavailableThumbnails: Set<ThumbnailKey> = []
    private var thumbnailRequests: [ThumbnailKey] = []
    private var thumbnailTask: Task<Void, Never>?
    private var accessibleClips: [UUID: AccessibleClip] = [:]
    private let accessibleRuler = AccessibleRuler()

    private let margin: CGFloat = 16
    private let laneTop: CGFloat = 31
    private let laneHeight: CGFloat = 61
    private let thumbnailWidth: CGFloat = 61
    private let thumbnailHeight: CGFloat = 32

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEditingEnabled }

    private var scale: CGFloat {
        let available = max(1, viewportWidth - 2 * margin)
        return sequenceDuration > 0 ? available * zoom / sequenceDuration : available
    }

    var contentWidth: CGFloat {
        let duration = max(sequenceDuration, positions.last?.end ?? 0)
        return margin * 2 + duration * scale
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sequence timeline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityChildren() -> [Any]? {
        guard !positions.isEmpty else {
            accessibleClips.removeAll()
            return []
        }
        accessibleRuler.setAccessibilityElement(true)
        accessibleRuler.setAccessibilityRole(.slider)
        accessibleRuler.setAccessibilityLabel("Timeline ruler")
        accessibleRuler.setAccessibilityParent(self)
        accessibleRuler.setAccessibilityEnabled(isEditingEnabled)
        accessibleRuler.setAccessibilityFrameInParentSpace(
            NSRect(x: visibleRect.minX, y: 0, width: visibleRect.width, height: laneTop)
        )
        accessibleRuler.seek = { [weak self] direction in
            guard let self, self.isEditingEnabled, let timeline = self.timeline else { return false }
            self.seekAccessibly(to: timeline.playhead + direction * self.rulerStep / 5)
            return true
        }
        accessibleRuler.setPosition = { [weak self] in self?.seekAccessibly(to: $0) }
        let ids = Set(positions.map { $0.clip.id })
        accessibleClips = accessibleClips.filter { ids.contains($0.key) }
        let children = positions.enumerated().map { index, position in
            let id = position.clip.id
            let element = accessibleClips[id] ?? AccessibleClip()
            accessibleClips[id] = element
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(position.clip.name)
            element.setAccessibilityValue(
                "\(timelineTime(position.start, milliseconds: true))–\(timelineTime(position.end, milliseconds: true))"
            )
            element.setAccessibilitySelected(id == timeline?.selection)
            element.setAccessibilityEnabled(isEditingEnabled)
            element.setAccessibilityFrameInParentSpace(clipRect(position))
            element.select = { [weak self] in self?.focusAccessibleClip(id) ?? false }
            var actions: [NSAccessibilityCustomAction] = []
            if index > 0 {
                actions.append(accessibleMove(id, by: -1, name: "Move clip earlier"))
            }
            if index + 1 < positions.count {
                actions.append(accessibleMove(id, by: 1, name: "Move clip later"))
            }
            element.setAccessibilityCustomActions(actions)
            return element
        }
        return [accessibleRuler] + children.map { $0 as NSAccessibilityElement }
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window, !positions.isEmpty else { return super.accessibilityHitTest(point) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard visibleRect.contains(local) else { return super.accessibilityHitTest(point) }
        let children = accessibilityChildren()
        if local.y < laneTop { return children?.first }
        let index = firstClipIndex { x(at: $0.end) > local.x }
        if positions.indices.contains(index), clipRect(positions[index]).contains(local) {
            return children?[index + 1]
        }
        return super.accessibilityHitTest(point)
    }

    private func seekAccessibly(to time: Double) {
        guard isEditingEnabled, let timeline else { return }
        let target = min(sequenceDuration, max(0, time))
        timeline.onSeek(target)
        reveal(time: target)
    }

    private func focusAccessibleClip(_ id: UUID) -> Bool {
        guard isEditingEnabled, let timeline,
              let clip = positions.first(where: { $0.clip.id == id }) else { return false }
        timeline.onSelect(id)
        timeline.onSeek(clip.start)
        reveal(time: clip.start)
        return true
    }

    private func accessibleMove(_ id: UUID, by offset: Int, name: String) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self, self.isEditingEnabled, let timeline = self.timeline,
                  let index = self.positions.firstIndex(where: { $0.clip.id == id }),
                  self.positions.indices.contains(index + offset) else { return false }
            timeline.onMove(id, index + (offset < 0 ? -1 : 2))
            return true
        }
    }

    private func hasSameLayout(as clips: [TimelineClip]) -> Bool {
        guard clips.count == positions.count else { return false }
        return zip(clips, positions).allSatisfy { clip, position in
            let previous = position.clip
            return clip.id == previous.id && clip.sourceStart == previous.sourceStart
                && clip.sourceEnd == previous.sourceEnd
        }
    }

    private func rebuildPositions() {
        var start = 0.0
        trimClipIndex = nil
        positions = (timeline?.clips ?? []).enumerated().map { index, clip in
            var displayStart = start
            var sourceStart = clip.sourceStart
            var sourceEnd = clip.sourceEnd
            if let trimPosition, trimPosition.id == clip.id {
                trimClipIndex = index
                switch trimPosition.edge {
                case .start:
                    sourceStart = trimPosition.time
                    displayStart += sourceStart - clip.sourceStart
                case .end:
                    sourceEnd = trimPosition.time
                }
            }
            let positioned = PositionedClip(
                clip: clip, start: displayStart, sourceStart: sourceStart, sourceEnd: sourceEnd
            )
            start = positioned.end
            return positioned
        }
        sequenceDuration = timeline?.duration ?? 0
    }

    fileprivate func x(at time: Double) -> CGFloat { margin + time * scale }
    private func time(at x: CGFloat) -> Double { Double((x - margin) / scale) }

    fileprivate func reveal(time: Double) {
        guard let scrollView = enclosingScrollView as? TimelineScrollView else { return }
        let visible = visibleRect
        let point = x(at: time)
        if point < visible.minX + margin || point > visible.maxX - margin {
            scrollView.scrollHorizontally(to: point - visible.width / 2)
        }
    }

    fileprivate func zoomAnchor(playhead: Double) -> (time: Double, offset: CGFloat) {
        let visible = visibleRect
        let playheadX = x(at: playhead)
        if (visible.minX...visible.maxX).contains(playheadX) {
            return (playhead, playheadX - visible.minX)
        }
        return (time(at: visible.midX), visible.width / 2)
    }

    private func clipRect(_ position: PositionedClip) -> NSRect {
        NSRect(x: x(at: position.start), y: laneTop,
               width: max(0, x(at: position.end) - x(at: position.start)), height: laneHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let timeline else { return }

        fill(dirtyRect, NSColor.controlBackgroundColor)
        fill(NSRect(x: 0, y: laneTop - 2, width: bounds.width, height: laneHeight + 4),
             NSColor.labelColor.withAlphaComponent(0.055))
        fill(NSRect(x: 0, y: laneTop - 3, width: bounds.width, height: 1), .separatorColor)

        if positions.isEmpty {
            label("Drop video files here", at: NSPoint(x: margin + 10, y: laneTop + 20),
                  font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
            thumbnailRequests = []
            thumbnailKeys = []
        } else {
            let visible = visibleRect
            drawRuler(visible, duration: max(sequenceDuration, positions.last?.end ?? 0))
            var keys: [ThumbnailKey] = []
            let visibleStart = time(at: visible.minX)
            let visibleEnd = time(at: visible.maxX)
            let first = firstClipIndex { $0.end > visibleStart }
            for index in first..<positions.count {
                let position = positions[index]
                if index == trimClipIndex { continue }
                // A head trim preview can temporarily extend left of its preceding neighbor.
                if position.start >= visibleEnd { break }
                drawClip(position, selected: position.clip.id == timeline.selection,
                         visible: visible, keys: &keys)
            }
            if let trimClipIndex, clipRect(positions[trimClipIndex]).intersects(visible) {
                drawClip(positions[trimClipIndex], selected: true, visible: visible, keys: &keys)
            }
            thumbnailKeys = Set(keys)
            thumbnailRequests = trimPosition == nil
                ? keys.filter { thumbnails[$0] == nil && !unavailableThumbnails.contains($0) }
                : []
            loadThumbnails()

            if let range = timeline.markedRange {
                let left = x(at: range.lowerBound)
                fill(NSRect(x: left, y: 24, width: max(1, x(at: range.upperBound) - left),
                            height: laneTop + laneHeight - 22), .controlAccentColor.withAlphaComponent(0.19))
                fill(NSRect(x: left, y: 24, width: 1, height: laneTop + laneHeight - 22), .controlAccentColor)
                fill(NSRect(x: x(at: range.upperBound), y: 24, width: 1, height: laneTop + laneHeight - 22),
                     .controlAccentColor)
            }

            if let trimPosition, let trimClipIndex {
                let position = positions[trimClipIndex]
                let edge = trimPosition.edge == .start ? position.start : position.end
                drawPlayhead(edge, color: .controlAccentColor)
                drawTrimTime(trimPosition.time, edgeX: x(at: edge))
            } else {
                drawPlayhead(timeline.playhead, color: .systemRed)
            }
        }

        if let insertionIndex {
            let time = positions.indices.contains(insertionIndex)
                ? positions[insertionIndex].start : positions.last?.end ?? 0
            let marker = x(at: time)
            fill(NSRect(x: marker - 1.5, y: laneTop - 5, width: 3, height: laneHeight + 10),
                 .controlAccentColor)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: marker - 4, y: laneTop - 8, width: 8, height: 8)).fill()
        }
    }

    private var rulerStep: Double {
        let desired = 86 / scale
        let power = pow(10, floor(log10(desired)))
        let magnitude = desired / power
        let multiple = [1.0, 2, 5, 10].first(where: { $0 >= magnitude }) ?? 10
        return max(0.001, multiple * power)
    }

    private func drawRuler(_ visible: NSRect, duration: Double) {
        let step = rulerStep
        let minorStep = step / 5
        let first = max(0, floor(time(at: visible.minX) / minorStep))
        let last = min(floor(duration / minorStep), ceil(time(at: visible.maxX) / minorStep))
        guard first <= last else { return }

        for index in Int(first)...Int(last) {
            let time = Double(index) * minorStep
            let tickX = x(at: time)
            let major = index.isMultiple(of: 5)
            fill(NSRect(x: tickX, y: major ? 20 : 24, width: 1, height: major ? 8 : 4), .separatorColor)
            if major {
                label(timelineTime(time, milliseconds: step < 1), at: NSPoint(x: tickX + 4, y: 5),
                      font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor)
            }
        }
    }

    private func drawClip(_ position: PositionedClip, selected: Bool, visible: NSRect,
                          keys: inout [ThumbnailKey]) {
        let rect = clipRect(position)
        guard rect.width > 0 else { return }

        let border = selected ? NSColor.controlAccentColor : NSColor.separatorColor
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: min(0.5, rect.width / 4), dy: 0.5),
                                 xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        fill(rect, selected ? NSColor.controlAccentColor.withAlphaComponent(0.20)
                            : NSColor.labelColor.withAlphaComponent(0.08))
        let thumbnailY = rect.minY + 21
        let thumbnailsRect = NSRect(x: rect.minX, y: thumbnailY, width: rect.width, height: thumbnailHeight)
        fill(thumbnailsRect, NSColor.labelColor.withAlphaComponent(0.08))

        if timeline?.thumbnail != nil, rect.width > 14 {
            drawThumbnails(position, rect: thumbnailsRect, visible: visible, keys: &keys)
        }

        let nameX = max(rect.minX + 8, visible.minX + 6)
        let nameWidth = max(0, min(rect.maxX - 8, visible.maxX - 6) - nameX)
        let nameRect = NSRect(x: nameX, y: rect.minY + 4, width: nameWidth, height: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (position.clip.name as NSString).draw(in: nameRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])

        let sourceLeft = position.sourceStart + max(0, time(at: visible.minX) - position.start)
        let sourceRight = min(position.sourceEnd, position.sourceStart + time(at: visible.maxX) - position.start)
        let keyframes = position.clip.keyframes
        var index = lowerBound(keyframes, sourceLeft)
        var lastX = -CGFloat.infinity
        while index < keyframes.count, keyframes[index] < sourceRight {
            let tickX = x(at: position.start + keyframes[index] - position.sourceStart)
            if tickX - lastX >= 3 {
                fill(NSRect(x: tickX, y: rect.maxY - 7, width: 1, height: 5), .secondaryLabelColor)
                lastX = tickX
            }
            let nextTime = keyframes[index] + Double(3 / scale)
            index = max(index + 1, lowerBound(keyframes, nextTime))
        }

        if selected, rect.width >= 18 {
            for x in [rect.minX + 1, rect.maxX - 6] {
                NSColor.black.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - 10, width: 5, height: 20),
                             xRadius: 2, yRadius: 2).fill()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 1.5, y: rect.midY - 6, width: 2, height: 12),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        border.setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
    }

    private func lowerBound(_ values: [Double], _ target: Double) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < target { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func drawThumbnails(_ position: PositionedClip, rect: NSRect, visible: NSRect,
                                keys: inout [ThumbnailKey]) {
        let first = max(0, Int(floor((visible.minX - rect.minX) / thumbnailWidth)))
        let last = min(Int(ceil(rect.width / thumbnailWidth)),
                       Int(ceil((visible.maxX - rect.minX) / thumbnailWidth)))
        guard first < last else { return }

        let backingScale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: thumbnailWidth * backingScale, height: thumbnailHeight * backingScale)
        for tile in first..<last {
            let offset = CGFloat(tile) * thumbnailWidth
            let available = min(thumbnailWidth, rect.width - offset)
            let sourceTime = position.sourceStart + Double((offset + available / 2) / scale)
            let key = ThumbnailKey(clip: position.clip.id, sourceTime: (sourceTime * 1000).rounded() / 1000,
                                   size: size)
            keys.append(key)
            let tileRect = NSRect(x: rect.minX + offset, y: rect.minY, width: available, height: rect.height)
            if let image = thumbnails[key] {
                let imageNS = NSImage(cgImage: image, size: .zero)
                let factor = max(tileRect.width / CGFloat(image.width), tileRect.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: tileRect).addClip()
                imageNS.draw(in: NSRect(x: tileRect.midX - size.width / 2, y: tileRect.midY - size.height / 2,
                                        width: size.width, height: size.height),
                             from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func loadThumbnails() {
        guard thumbnailTask == nil, !thumbnailRequests.isEmpty, let callback = timeline?.thumbnail else { return }
        thumbnailTask = Task { [weak self] in
            while let self, let key = self.thumbnailRequests.first {
                self.thumbnailRequests.removeFirst()
                if self.thumbnails[key] != nil || self.unavailableThumbnails.contains(key) { continue }
                let image = await callback(key.clip, key.sourceTime, key.size)
                guard !Task.isCancelled else { break }
                if let image {
                    if self.thumbnails.count >= max(256, self.thumbnailKeys.count),
                       let obsolete = self.thumbnailOrder.firstIndex(where: { !self.thumbnailKeys.contains($0) }) {
                        self.thumbnails.removeValue(forKey: self.thumbnailOrder.remove(at: obsolete))
                    }
                    self.thumbnails[key] = image
                    self.thumbnailOrder.append(key)
                } else {
                    if self.unavailableThumbnails.count >= 1024 { self.unavailableThumbnails.removeAll() }
                    self.unavailableThumbnails.insert(key)
                }
                if self.thumbnailKeys.contains(key) { self.needsDisplay = true }
            }
            self?.thumbnailTask = nil
        }
    }

    private func drawPlayhead(_ time: Double, color: NSColor) {
        let head = x(at: time)
        fill(NSRect(x: head - 0.5, y: 19, width: 1, height: laneTop + laneHeight - 13), color)
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: head - 4, y: 16))
        marker.line(to: NSPoint(x: head + 4, y: 16))
        marker.line(to: NSPoint(x: head + 4, y: 21))
        marker.line(to: NSPoint(x: head, y: 25))
        marker.line(to: NSPoint(x: head - 4, y: 21))
        marker.close()
        color.setFill()
        marker.fill()
    }

    private func drawTrimTime(_ time: Double, edgeX: CGFloat) {
        let timeLabel = timelineTime(time, milliseconds: true)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let width = (timeLabel as NSString).size(withAttributes: [.font: font]).width + 12
        let left = min(max(visibleRect.minX + 3, edgeX - width / 2), visibleRect.maxX - width - 3)
        let box = NSRect(x: left, y: laneTop - 24, width: width, height: 19)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label(timeLabel, at: NSPoint(x: box.minX + 6, y: box.minY + 2), font: font, color: .white)
    }

    private func fill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private func label(_ value: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (value as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEditingEnabled,
              let selected = positions.first(where: { $0.clip.id == timeline?.selection }) else { return }
        let rect = clipRect(selected)
        let width = trimGripWidth(for: rect)
        for left in [rect.minX, rect.maxX - width] {
            let grip = NSRect(x: left, y: rect.minY, width: width, height: rect.height)
            let visibleGrip = grip.intersection(visibleRect)
            if !visibleGrip.isEmpty { addCursorRect(visibleGrip, cursor: .resizeLeftRight) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditingEnabled, let timeline, !positions.isEmpty else { return }
        clearInteraction()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard (laneTop..<(laneTop + laneHeight)).contains(point.y) else {
            interaction = .seek
            seek(to: point.x)
            return
        }

        let index = firstClipIndex { x(at: $0.end) > point.x }
        if positions.indices.contains(index), clipRect(positions[index]).contains(point) {
            let position = positions[index]
            timeline.onSelect(position.clip.id)
            if let edge = trimEdge(at: point, for: position) {
                let sourceTime = edge == .start ? position.sourceStart : position.sourceEnd
                interaction = .trim(position.clip.id, edge, sourceTime, point.x, scale)
            } else {
                interaction = .clip(position.clip.id, event.locationInWindow)
            }
        } else {
            interaction = .seek
            seek(to: point.x)
        }
    }

    private func trimEdge(at point: NSPoint, for position: PositionedClip) -> TimelineEdge? {
        let rect = clipRect(position)
        let leading = abs(point.x - rect.minX)
        let trailing = abs(point.x - rect.maxX)
        let grip = trimGripWidth(for: rect)
        guard min(leading, trailing) <= grip else { return nil }
        return leading <= trailing ? .start : .end
    }

    private func trimGripWidth(for rect: NSRect) -> CGFloat { min(7, rect.width / 3) }

    override func mouseDragged(with event: NSEvent) {
        guard isEditingEnabled, let interaction else { return }
        if case let .clip(id, down) = interaction {
            let point = event.locationInWindow
            guard abs(point.x - down.x) > 4 || abs(point.y - down.y) > 5 else { return }
            self.interaction = .reorder(id)
        }
        startEdgeScroll(at: event.locationInWindow, external: false)
        updateInternalDrag(at: event.locationInWindow)
    }

    private func updateInternalDrag(at location: NSPoint) {
        guard let timeline, let interaction else { return }
        let point = convert(location, from: nil)
        switch interaction {
        case .seek:
            seek(to: point.x)
        case .clip:
            break
        case .reorder:
            insertionIndex = insertionSlot(at: point.x)
        case let .trim(id, edge, initialTime, downX, initialScale):
            guard let clip = timeline.clips.first(where: { $0.id == id }) else { return }
            let sourceTime = min(clip.sourceDuration, max(0, initialTime + Double((point.x - downX) / initialScale)))
            guard sourceTime != lastTrimTarget else { return }
            lastTrimTarget = sourceTime
            if let effective = timeline.onTrim(id, edge, sourceTime, false), effective != trimPosition?.time {
                trimPosition = TrimPosition(id: id, edge: edge, time: effective)
                rebuildPositions()
                (enclosingScrollView as? TimelineScrollView)?.resizeDocument()
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let timeline, let interaction else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isEditingEnabled, dragLocation != nil {
            switch interaction {
            case .seek, .reorder, .trim:
                updateInternalDrag(at: event.locationInWindow)
            case .clip:
                break
            }
        }
        let completedTrim = trimPosition
        let moved = dragLocation != nil
        clearInteraction()
        guard isEditingEnabled else {
            if completedTrim != nil { timeline.onCancelTrim() }
            return
        }
        switch interaction {
        case .seek:
            break
        case .clip:
            seek(to: point.x)
        case let .reorder(id):
            timeline.onMove(id, insertionSlot(at: point.x))
        case let .trim(id, edge, _, _, _):
            if let completedTrim {
                if timeline.onTrim(id, edge, completedTrim.time, true) == nil {
                    timeline.onCancelTrim()
                }
            } else if !moved {
                seek(to: point.x)
            } else {
                timeline.onCancelTrim()
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if case .trim = interaction { timeline?.onCancelTrim() }
        if interaction != nil { clearInteraction() } else { super.cancelOperation(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, interaction != nil, window?.firstResponder === self {
            cancelOperation(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func clearInteraction() {
        interaction = nil
        lastTrimTarget = nil
        lastSeekTarget = nil
        let wasTrimming = trimPosition != nil
        trimPosition = nil
        insertionIndex = nil
        endEdgeScroll()
        if wasTrimming {
            rebuildPositions()
            (enclosingScrollView as? TimelineScrollView)?.resizeDocument()
        }
        needsDisplay = true
    }

    private func seek(to x: CGFloat) {
        guard let timeline else { return }
        let target = min(sequenceDuration, max(0, time(at: x)))
        guard target != lastSeekTarget else { return }
        lastSeekTarget = target
        timeline.onSeek(target)
    }

    private func insertionSlot(at x: CGFloat) -> Int {
        let time = time(at: x)
        return firstClipIndex { $0.start + ($0.sourceEnd - $0.sourceStart) / 2 > time }
    }

    private func firstClipIndex(where pastTarget: (PositionedClip) -> Bool) -> Int {
        var low = 0
        var high = positions.count
        while low < high {
            let middle = (low + high) / 2
            if pastTarget(positions[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endExternalDrop()
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditingEnabled, interaction == nil, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) else {
            endExternalDrop()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        startEdgeScroll(at: sender.draggingLocation, external: true)
        insertionIndex = insertionSlot(at: point.x)
        needsDisplay = true
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.pasteboardItems?.compactMap { item in
            item.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        } ?? []
        let index = insertionSlot(at: convert(sender.draggingLocation, from: nil).x)
        let isCopy = sender.draggingSourceOperationMask.contains(.copy)
        endExternalDrop()
        guard isEditingEnabled, interaction == nil, isCopy, !urls.isEmpty, let timeline else { return false }
        timeline.onDrop(urls, index)
        return true
    }

    private func endExternalDrop() {
        guard isExternalDrag else { return }
        endEdgeScroll()
        insertionIndex = nil
        needsDisplay = true
    }

    private func startEdgeScroll(at location: NSPoint, external: Bool) {
        dragLocation = location
        isExternalDrag = external
        guard edgeScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, target: self, selector: #selector(scrollDragEdge),
                          userInfo: nil, repeats: true)
        edgeScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endEdgeScroll() {
        dragLocation = nil
        isExternalDrag = false
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
    }

    @objc private func scrollDragEdge() {
        guard let dragLocation, let scrollView = enclosingScrollView as? TimelineScrollView else { return }
        let point = convert(dragLocation, from: nil)
        let visible = scrollView.contentView.bounds
        let zone = min(24, visible.width / 4)
        let delta: CGFloat
        if point.x < visible.minX + zone {
            delta = -12
        } else if point.x > visible.maxX - zone {
            delta = 12
        } else {
            return
        }
        scrollView.scrollHorizontally(to: visible.minX + delta)
        guard visible.minX != scrollView.contentView.bounds.minX else { return }
        if isExternalDrag {
            insertionIndex = insertionSlot(at: convert(dragLocation, from: nil).x)
            needsDisplay = true
        } else {
            updateInternalDrag(at: dragLocation)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if trimPosition != nil { timeline?.onCancelTrim() }
            clearInteraction()
            thumbnailRequests = []
            thumbnailTask?.cancel()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
