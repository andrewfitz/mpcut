import AppKit
import SwiftUI
import MPCutCore

struct TimelineClip: Identifiable {
    let id: UUID
    let sourceID: UUID
    let name: String
    let sourceStart: Double
    let sourceEnd: Double
    let sourceDuration: Double
    let keyframes: [Double]
    let thumbnailSyncTimes: [Double]
    let frames: [RationalTime]

    var duration: Double { sourceEnd - sourceStart }

    func thumbnailTime(from start: Double, to end: Double) -> Double {
        let middle = start + (end - start) / 2
        let next = thumbnailSyncTimes.lowerBound { $0 >= middle }
        let previous = next > 0 ? thumbnailSyncTimes[next - 1] : -.infinity
        let following = next < thumbnailSyncTimes.count ? thumbnailSyncTimes[next] : .infinity
        if previous >= start, following < end {
            return middle - previous <= following - middle ? previous : following
        }
        if previous >= start { return previous }
        if following < end { return following }

        // An overview tile can span seconds of interdependent video. Its first
        // picture needs less decoder preroll and is still inside the tile.
        if end - start >= 0.5 {
            let first = frames.lowerBound { $0.seconds >= start }
            if first < frames.count, frames[first].seconds < end { return frames[first].seconds }
        }
        // At high zoom several tiles may show the very same held VFR picture.
        let after = frames.lowerBound { $0.seconds > middle }
        return after > 0 ? frames[after - 1].seconds : middle
    }
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
    var markIn: Double? = nil
    var markOut: Double? = nil
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
                if let markIn { markReadout("In", time: markIn) }
                if let markOut { markReadout("Out", time: markOut) }
                if markIn != nil || markOut != nil { Divider().frame(height: 16) }
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

    private func markReadout(_ name: String, time: Double) -> some View {
        let timestamp = timelineTime(time, milliseconds: true)
        return Text("\(name) \(timestamp)")
            .font(.callout.monospacedDigit())
            .fixedSize()
            .accessibilityLabel("Mark \(name) time")
            .accessibilityValue(timestamp)
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
            view.scrollHorizontally(to: view.surface.stripX(at: anchor.time) - anchor.offset)
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

final class TimelineSurface: NSView {
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
        let stripStart: Double
        let sequenceStart: Double
        let sourceStart: Double
        let sourceEnd: Double

        var stripEnd: Double { stripStart + clip.sourceDuration }
        var keptStart: Double { stripStart + sourceStart }
        var keptEnd: Double { stripStart + sourceEnd }
        var sequenceEnd: Double { sequenceStart + (sourceEnd - sourceStart) }
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
        let source: UUID
        let sourceTime: Double
        let size: CGSize

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source == rhs.source && lhs.sourceTime == rhs.sourceTime && lhs.size == rhs.size
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(source)
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
    private var activeThumbnail: ThumbnailKey?
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
        let sourceDuration = positions.last?.stripEnd ?? 0
        return sourceDuration > 0 ? available * zoom / sourceDuration : available
    }

    var contentWidth: CGFloat {
        let duration = positions.last?.stripEnd ?? 0
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
                "\(timelineTime(position.sequenceStart, milliseconds: true))–\(timelineTime(position.sequenceEnd, milliseconds: true))"
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
        let index = firstClipIndex { stripX(at: $0.stripEnd) > local.x }
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
        timeline.onSeek(clip.sequenceStart)
        reveal(time: clip.sequenceStart)
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
        var stripStart = 0.0
        var sequenceStart = 0.0
        trimClipIndex = nil
        positions = (timeline?.clips ?? []).enumerated().map { index, clip in
            var sourceStart = clip.sourceStart
            var sourceEnd = clip.sourceEnd
            if let trimPosition, trimPosition.id == clip.id {
                trimClipIndex = index
                if trimPosition.edge == .start { sourceStart = trimPosition.time }
                else { sourceEnd = trimPosition.time }
            }
            let position = PositionedClip(clip: clip, stripStart: stripStart, sequenceStart: sequenceStart,
                                          sourceStart: sourceStart, sourceEnd: sourceEnd)
            stripStart = position.stripEnd
            sequenceStart = position.sequenceEnd
            return position
        }
        sequenceDuration = sequenceStart
    }

    fileprivate func stripX(at time: Double) -> CGFloat { margin + time * scale }
    private func stripTime(at x: CGFloat) -> Double { Double((x - margin) / scale) }

    private func x(at sequenceTime: Double, preceding: Bool = false) -> CGFloat {
        guard !positions.isEmpty else { return margin }
        let index = min(positions.count - 1, firstClipIndex { preceding ? $0.sequenceEnd >= sequenceTime : $0.sequenceEnd > sequenceTime })
        let clip = positions[index]
        let local = min(clip.sequenceEnd, max(clip.sequenceStart, sequenceTime)) - clip.sequenceStart
        return stripX(at: clip.keptStart + local)
    }

    private func sequenceTime(at x: CGFloat) -> Double {
        guard !positions.isEmpty else { return 0 }
        let time = stripTime(at: x)
        let index = min(positions.count - 1, firstClipIndex { $0.stripEnd > time })
        let clip = positions[index]
        let local = min(clip.keptEnd, max(clip.keptStart, time)) - clip.keptStart
        return clip.sequenceStart + local
    }

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
            return (stripTime(at: playheadX), playheadX - visible.minX)
        }
        return (stripTime(at: visible.midX), visible.width / 2)
    }

    private func clipRect(_ position: PositionedClip) -> NSRect {
        NSRect(x: stripX(at: position.keptStart), y: laneTop,
               width: CGFloat(position.sourceEnd - position.sourceStart) * scale, height: laneHeight)
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
            thumbnailTask?.cancel()
        } else {
            let visible = visibleRect
            var keys: [ThumbnailKey] = []
            let visibleStart = stripTime(at: visible.minX)
            let visibleEnd = stripTime(at: visible.maxX)
            var lastRulerLabelX = -CGFloat.infinity
            let first = firstClipIndex { $0.stripEnd > visibleStart }
            for index in first..<positions.count {
                let position = positions[index]
                if position.stripStart >= visibleEnd { break }
                drawRuler(visible, position: position, lastLabelX: &lastRulerLabelX)
                drawClip(position, selected: position.clip.id == timeline.selection,
                         visible: visible, keys: &keys)
                if let markIn = timeline.markIn, let markOut = timeline.markOut {
                    let lower = max(position.sequenceStart, min(markIn, markOut))
                    let upper = min(position.sequenceEnd, max(markIn, markOut))
                    if upper > lower {
                        fill(NSRect(x: stripX(at: position.keptStart + lower - position.sequenceStart),
                                    y: 24, width: (upper - lower) * scale, height: laneTop + laneHeight - 22),
                             .controlAccentColor.withAlphaComponent(0.19))
                    }
                }
            }
            thumbnailKeys = Set(keys)
            thumbnailRequests = keys.filter { thumbnails[$0] == nil && !unavailableThumbnails.contains($0) }
            loadThumbnails()

            if let time = timeline.markIn { drawMark(time, isIn: true) }
            if let time = timeline.markOut { drawMark(time, isIn: false) }

            if let trimPosition, let trimClipIndex {
                let position = positions[trimClipIndex]
                let edge = trimPosition.edge == .start ? position.keptStart : position.keptEnd
                drawPlayhead(atX: stripX(at: edge), color: .controlAccentColor)
                drawTrimTime(trimPosition.time, edgeX: stripX(at: edge))
            } else {
                drawPlayhead(atX: x(at: timeline.playhead), color: .systemRed)
            }
        }

        if let insertionIndex {
            let time = positions.indices.contains(insertionIndex)
                ? positions[insertionIndex].stripStart : positions.last?.stripEnd ?? 0
            let marker = stripX(at: time)
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

    private func drawRuler(_ visible: NSRect, position: PositionedClip, lastLabelX: inout CGFloat) {
        let step = rulerStep
        let minorStep = step / 5
        let offset = position.keptStart - position.sequenceStart
        let first = ceil(max(position.sequenceStart, stripTime(at: visible.minX) - offset) / minorStep)
        let last = floor(min(position.sequenceEnd, stripTime(at: visible.maxX) - offset) / minorStep)
        guard first <= last else { return }

        for index in Int(first)...Int(last) {
            let time = Double(index) * minorStep
            let tickX = stripX(at: time + offset)
            let major = index.isMultiple(of: 5)
            fill(NSRect(x: tickX, y: major ? 20 : 24, width: 1, height: major ? 8 : 4), .separatorColor)
            if major, tickX >= lastLabelX + 60 {
                lastLabelX = tickX
                label(timelineTime(time, milliseconds: step < 1), at: NSPoint(x: tickX + 4, y: 5),
                      font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor)
            }
        }
    }

    private func drawClip(_ position: PositionedClip, selected: Bool, visible: NSRect,
                          keys: inout [ThumbnailKey]) {
        let rect = clipRect(position)
        let strip = NSRect(x: stripX(at: position.stripStart), y: laneTop,
                          width: position.clip.sourceDuration * scale, height: laneHeight)
        guard strip.intersects(visible) else { return }
        let filmstrip = NSRect(x: strip.minX, y: strip.minY + 21, width: strip.width, height: thumbnailHeight)
        if timeline?.thumbnail != nil, strip.width > 14 {
            drawThumbnails(position, rect: filmstrip, visible: visible, keys: &keys)
        }
        for excluded in [NSRect(x: strip.minX, y: laneTop, width: max(0, rect.minX - strip.minX), height: laneHeight),
                         NSRect(x: rect.maxX, y: laneTop, width: max(0, strip.maxX - rect.maxX), height: laneHeight)]
            where excluded.width > 0 {
            fill(excluded, NSColor.controlBackgroundColor.withAlphaComponent(0.74))
            fill(excluded, NSColor.secondaryLabelColor.withAlphaComponent(0.09))
        }
        guard rect.intersects(visible) else { return }
        let border = selected ? NSColor.controlAccentColor : NSColor.separatorColor
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: min(0.5, rect.width / 4), dy: 0.5),
                                 xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        fill(rect, selected ? NSColor.controlAccentColor.withAlphaComponent(0.20)
                            : NSColor.labelColor.withAlphaComponent(0.08))
        let nameX = max(rect.minX + 8, visible.minX + 6)
        let nameWidth = max(0, min(rect.maxX - 8, visible.maxX - 6) - nameX)
        let nameRect = NSRect(x: nameX, y: rect.minY + 4, width: nameWidth, height: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (position.clip.name as NSString).draw(in: nameRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])

        let sourceLeft = max(position.sourceStart, stripTime(at: visible.minX) - position.stripStart)
        let sourceRight = min(position.sourceEnd, stripTime(at: visible.maxX) - position.stripStart)
        let keyframes = position.clip.keyframes
        var index = keyframes.lowerBound { $0 >= sourceLeft }
        var lastX = -CGFloat.infinity
        while index < keyframes.count, keyframes[index] < sourceRight {
            let tickX = stripX(at: position.stripStart + keyframes[index])
            if tickX - lastX >= 3 {
                fill(NSRect(x: tickX, y: rect.maxY - 7, width: 1, height: 5), .secondaryLabelColor)
                lastX = tickX
            }
            let nextTime = keyframes[index] + Double(3 / scale)
            index = max(index + 1, keyframes.lowerBound { $0 >= nextTime })
        }

        NSGraphicsContext.restoreGraphicsState()
        border.setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
        if selected {
            let left = rect.width >= 18 ? rect.minX + 1 : rect.minX - 5
            let right = rect.width >= 18 ? rect.maxX - 6 : rect.maxX
            for x in [left, right] {
                NSColor.black.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - 10, width: 5, height: 20),
                             xRadius: 2, yRadius: 2).fill()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 1.5, y: rect.midY - 6, width: 2, height: 12),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
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
            let start = Double(offset / scale)
            let end = min(position.clip.sourceDuration, Double((offset + available) / scale))
            let sourceTime = position.clip.thumbnailTime(from: start, to: end)
            let key = ThumbnailKey(source: position.clip.sourceID, sourceTime: sourceTime, size: size)
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
        if let activeThumbnail, !thumbnailKeys.contains(activeThumbnail) {
            thumbnailTask?.cancel()
        }
        guard thumbnailTask == nil, !thumbnailRequests.isEmpty, let callback = timeline?.thumbnail else { return }
        thumbnailTask = Task { [weak self] in
            while !Task.isCancelled, let self, let key = self.thumbnailRequests.first {
                self.thumbnailRequests.removeFirst()
                if self.thumbnails[key] != nil || self.unavailableThumbnails.contains(key) { continue }
                self.activeThumbnail = key
                let image = await callback(key.source, key.sourceTime, key.size)
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
            self?.activeThumbnail = nil
            self?.thumbnailTask = nil
            self?.loadThumbnails()
        }
    }

    private func drawMark(_ time: Double, isIn: Bool) {
        // Put the bracket on its own side of the playhead so it is visible immediately.
        let otherMark = isIn ? timeline?.markOut : timeline?.markIn
        let edge = x(at: time, preceding: otherMark.map { time > $0 } ?? !isIn)
        let stemX = isIn ? edge + 1 : edge - 3
        let tabX = isIn ? stemX : stemX - 7
        let bottom = laneTop + laneHeight + 2
        fill(NSRect(x: stemX, y: 23, width: 2, height: bottom - 23), .controlAccentColor)
        fill(NSRect(x: tabX, y: 23, width: 9, height: 4), .controlAccentColor)
        fill(NSRect(x: tabX, y: bottom - 3, width: 9, height: 3), .controlAccentColor)
    }

    private func drawPlayhead(atX head: CGFloat, color: NSColor) {
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
        for edge in [TimelineEdge.start, .end] {
            let grip = gripRect(rect, edge: edge, position: selected)
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

        // Let the first and last handles be grabbed from the empty timeline margin.
        let index = min(positions.count - 1, firstClipIndex { stripX(at: $0.stripEnd) > point.x })
        var position = positions[index]
        if let selected = positions.first(where: { $0.clip.id == timeline.selection }),
           trimEdge(at: point, for: selected) != nil {
            position = selected
        }
        let edge = trimEdge(at: point, for: position)
        if edge != nil || clipRect(position).contains(point) {
            timeline.onSelect(position.clip.id)
            if let edge {
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
        for edge in [TimelineEdge.start, .end] {
            if gripRect(rect, edge: edge, position: position).contains(point) { return edge }
        }
        return nil
    }

    private func gripRect(_ rect: NSRect, edge: TimelineEdge, position: PositionedClip) -> NSRect {
        let inside = min(12, rect.width / 3)
        let isOuter = edge == .start ? position.clip.id == positions.first?.clip.id
                                    : position.clip.id == positions.last?.clip.id
        let trimmed = edge == .start ? position.sourceStart : position.clip.sourceDuration - position.sourceEnd
        let outside: CGFloat = isOuter || (rect.width < 18 && position.clip.id == timeline?.selection)
            ? 8 : min(8, max(0, trimmed) * scale)
        return NSRect(x: edge == .start ? rect.minX - outside : rect.maxX - inside,
                      y: rect.minY, width: inside + outside, height: rect.height)
    }

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
        let target = sequenceTime(at: x)
        guard target != lastSeekTarget else { return }
        lastSeekTarget = target
        timeline.onSeek(target)
    }

    private func insertionSlot(at x: CGFloat) -> Int {
        let time = stripTime(at: x)
        return firstClipIndex { $0.stripStart + $0.clip.sourceDuration / 2 > time }
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
