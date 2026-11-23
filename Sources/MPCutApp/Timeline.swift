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
    var displaySize: CGSize = .zero
    var sourceOrigin: RationalTime = .zero
    var sequenceRange: Range<Double>? = nil
    var isIndexed = true
    var hasProvisionalFilmstrip = false
    fileprivate var usesOpeningFilmstrip: Bool { !isIndexed || hasProvisionalFilmstrip }
    var displayRange: AudioSpan? = nil
    var isAudioOnly = false
    var audioSampleRate = 0
    var replacementAudio: String?
    var isStill = false
    var isGap = false
    var mediaRevision = 0
    var mediaIssue: String?
    var stripLabel: String {
        if mediaIssue != nil { return "\(name) · Needs review" }
        return replacementAudio.map { "\(name) · Audio: \($0)" } ?? name
    }

    static let tileWidth: CGFloat = 92
    static let largeTileWidth: CGFloat = 243
    static let minimumThumbnailHeight: CGFloat = 48
    static let minimumLargeThumbnailHeight: CGFloat = 135

    var thumbnailHeight: CGFloat {
        thumbnailHeight(large: false)
    }

    func thumbnailHeight(large: Bool) -> CGFloat {
        if isAudioOnly { return large ? 172 : 86 }
        return TimelineFilmstrip.height(displaySize: displaySize, large: large)
    }

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

enum TimelineSnapTarget: String, CaseIterable {
    case off, keyframes, scenes, silence

    var label: String {
        switch self {
        case .off: "Off"
        case .keyframes: "Keyframes"
        case .scenes: "Scenes"
        case .silence: "Silence"
        }
    }
}

struct SnapTargetPicker: View {
    @Binding var selection: TimelineSnapTarget
    var audioOnly = false

    var body: some View {
        Picker("Snap to", selection: $selection) {
            ForEach(TimelineSnapTarget.allCases, id: \.self) { target in
                if !audioOnly || target == .off || target == .silence { Text(target.label).tag(target) }
            }
        }
        .help("Choose edit snapping targets")
    }
}

/// The snap choice in the timeline header: a quiet menu that names its own setting.
struct SnapTargetMenu: View {
    @Binding var selection: TimelineSnapTarget
    var audioOnly = false

    var body: some View {
        Menu {
            Picker("Snap to", selection: $selection) {
                ForEach(TimelineSnapTarget.allCases, id: \.self) { target in
                    if !audioOnly || target == .off || target == .silence { Text(target.label).tag(target) }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selection == .off ? "Snap Off" : "Snap to \(selection.label)")
        }
        .barMenu()
        .accessibilityLabel("Snap to")
        .accessibilityValue(selection.label)
        .help("Choose edit snapping targets")
    }
}

struct TimelineScene: Equatable {
    let start: Double
    let view: Int
}

struct TimelineSceneOverlay {
    let scenes: [TimelineScene]
    let from: Double
    let to: Double
    var leadingIsCut = true
    var names: [Int: String] = [:]
}

typealias TimelineHandleValidation = (UUID, TimelineEdge, Double, Bool, @escaping (Double?) -> Void) -> Void

@MainActor
struct SequenceTimeline: View {
    let clips: [TimelineClip]
    let playhead: Double
    let selection: UUID?
    var markIn: Double? = nil
    var markOut: Double? = nil
    var thumbnailHeight: CGFloat = TimelineClip.minimumThumbnailHeight
    var sequenceDuration: Double? = nil
    var scenesBySource: [UUID: [TimelineScene]] = [:]
    var sceneOverlaysByClip: [UUID: TimelineSceneOverlay] = [:]
    var viewNamesBySource: [UUID: [Int: String]] = [:]
    var sceneRevision = 0
    var audioOnly = false
    var showsWaveform = false
    var envelopeStore: AudioEnvelopeStore? = nil
    var waveforms: [UUID: AudioWaveform] = [:]
    var openingWaveform: OpeningWaveform? = nil
    var waveformPauses: [UUID: [AudioSpan]] = [:]
    var timelinePadding: [AudioSpan] = []
    var waveformRevision = 0
    static let maximumZoom = TimelineViewControls.maximumZoom
    fileprivate var waveformHeight: CGFloat { showsWaveform ? (largeThumbnails.wrappedValue ? 64 : 32) : 0 }
    var snapTarget: Binding<TimelineSnapTarget> = .constant(.off)
    var largeThumbnails: Binding<Bool> = .constant(false)
    var zoom: Binding<Double> = .constant(0)
    var timeEntryRequest = 0
    var allowsClipEdits = true
    var showsControls = true
    var allowsFileDrops = true
    var accessibilityTitle = "Sequence timeline"
    var assemblyAssets: [MulticamAssetSpan] = []
    fileprivate var assemblyAssetHeight: CGFloat { assemblyAssets.isEmpty ? 0 : 24 }
    let onSelect: (UUID) -> Void
    let onSeek: (Double) -> Void
    let onTrim: (UUID, TimelineEdge, Double, Bool) -> Double?
    let onMove: (UUID, Int) -> Void
    let onDrop: ([URL], Int) -> Void
    /// Opens the project files of a drop the way File → Open does and returns the media that is left.
    /// It runs before the timeline decides whether it can take media, so a project also opens while the editor is busy.
    var onDropStills: (([URL], Double, Bool) -> Void)? = nil
    var onDropProjects: (([URL]) -> [URL])? = nil
    var onPreviewJoin: ((UUID) -> Void)? = nil
    var onClipCSV: ((URL, UUID) -> Void)? = nil
    var pointerTarget: ((Double, Double) -> Double)? = nil
    var onPointerSeek: ((Double) -> Void)? = nil
    var onScrub: ((Double) -> Void)? = nil
    var onEndScrub: () -> Void = {}
    var onCancelTrim: () -> Void = {}
    var validateHandle: TimelineHandleValidation? = nil
    var thumbnail: ((UUID, Double, CGSize) async -> CGImage?)? = nil

    var audioTrackLabels: ((UUID) -> [String])?
    var onMonitorAudio: ((Int, UUID) -> Void)?
    var onReplaceAudio: ((UUID) -> Void)?
    var onRangeSelect: ((Double, Double) -> Void)? = nil

    @State private var revealTime: Double?
    @State private var revealRequest = 0

    var duration: Double { sequenceDuration ?? clips.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
                controls
                Divider()
            }
            TimelineScrollSurface(timeline: self, zoom: pow(2, zoom.wrappedValue),
                                  revealTime: revealTime, revealRequest: revealRequest)
                .frame(height: (showsControls ? 87 : 65) + thumbnailHeight + waveformHeight + assemblyAssetHeight)
        }
    }

    private var controls: some View {
        TimelineControlBar {
            TimelineTimeControl(playhead: playhead, duration: duration, durationLabel: "Sequence duration",
                                request: timeEntryRequest) { target in
                onSeek(target)
                revealTime = target
                revealRequest += 1
            }
            .layoutPriority(1)
        } options: {
            TimelineMarkReadouts(markIn: markIn, markOut: markOut)
            SnapTargetMenu(selection: snapTarget, audioOnly: audioOnly)
                .disabled(!allowsClipEdits)
                .layoutPriority(1)
            TimelineViewControls(zoom: zoom, largeThumbnails: largeThumbnails, audioOnly: audioOnly)
                .layoutPriority(1)
        }
    }

    static func parseTime(_ text: String, initialTime: Double) -> Double? {
        TimelineTimeControl.parseTime(text, initialTime: initialTime)
    }
}

func timelineTime(_ seconds: Double, milliseconds: Bool = false) -> String {
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
        view.surface.setAccessibilityLabel(timeline.accessibilityTitle)
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
        if zoomChanged {
            view.surface.updateTimelineOverlay()
            view.surface.needsDisplay = true
        }
    }
}

final class TimelineScrollView: NSScrollView {
    let surface = TimelineSurface()
    var revealRequest = 0
    private let playhead = TimelinePlayheadView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playhead.wantsLayer = true
        playhead.setAccessibilityElement(false)
        playhead.isHidden = true
        addSubview(playhead, positioned: .above, relativeTo: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updatePlayhead() {
        guard let rect = surface.playheadRect, rect.intersects(surface.visibleRect) else {
            playhead.isHidden = true
            return
        }
        let frame = convert(rect, from: surface)
        if playhead.frame != frame { playhead.frame = frame }
        playhead.isHidden = false
    }

    override func tile() {
        super.tile()
        resizeDocument()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updatePlayhead()
        surface.window?.invalidateCursorRects(for: surface)
        surface.updateTimelineOverlay()
        surface.needsDisplay = true
    }

    func resizeDocument() {
        guard documentView != nil else { return }
        let width = max(1, contentView.bounds.width)
        let widthChanged = surface.viewportWidth != width
        surface.viewportWidth = width
        let newSize = NSSize(
            width: max(width, surface.contentWidth),
            height: max(100, contentView.bounds.height)
        )
        let sizeChanged = surface.frame.size != newSize
        if sizeChanged { surface.setFrameSize(newSize) }
        if widthChanged || sizeChanged {
            surface.updateTimelineOverlay()
        }
        updatePlayhead()
    }

    func scrollHorizontally(to x: CGFloat) {
        let visible = contentView.bounds
        let origin = min(max(0, x), max(0, surface.bounds.width - visible.width))
        guard origin != visible.minX else { return }
        contentView.scroll(to: NSPoint(x: origin, y: visible.minY))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        switch TimelineWheelAction(event) {
        case .zoom(let amount):
            guard let zoom = surface.timeline?.zoom else { return }
            zoom.wrappedValue = TimelineViewControls.adjustedZoom(zoom.wrappedValue, by: amount)
        case .pan(let delta):
            scrollHorizontally(to: contentView.bounds.minX + delta)
        case nil:
            super.scrollWheel(with: event)
        }
    }
}

// Only this small layer moves during playback. The ruler, keyframe ticks, and
// filmstrip remain in the scroll view's document until an edit or scroll.
private final class TimelinePlayheadView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTimelinePlayhead(x: bounds.midX, top: 0, bottom: bounds.maxY, color: .systemRed)
    }
}

private func drawTimelinePlayhead(x: CGFloat, top: CGFloat, bottom: CGFloat, color: NSColor) {
    color.setFill()
    NSRect(x: x - 0.5, y: top + 3, width: 1, height: bottom - top - 3).fill()
    let marker = TimelinePlayheadMarker().path(in: CGRect(x: x - 8, y: top, width: 16, height: 18))
    NSBezierPath(cgPath: marker.cgPath).fill()
}

// Keep marks and drag feedback in a layer sized to the viewport so pointer movement
// can redraw them independently of the filmstrip and waveform.
final class TimelineRangeOverlay: NSView {
    var drawRange: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(viewport: NSRect, showMarks: Bool) {
        let viewport = viewport.isEmpty ? .zero : viewport
        if frame != viewport { frame = viewport }
        let hidden = viewport.isEmpty || !showMarks
        if isHidden != hidden { isHidden = hidden }
        if !hidden { layer?.setNeedsDisplay() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let offset = frame.origin
        context.saveGState()
        context.translateBy(x: -offset.x, y: -offset.y)
        drawRange?(dirtyRect.offsetBy(dx: offset.x, dy: offset.y))
        context.restoreGState()
    }
}

/// Uses the same sorted, half-open spans as the shaded timeline overlay.
func timelineRulerDescription(at seconds: Double, padding: [AudioSpan]) -> String {
    let time = timelineTime(seconds, milliseconds: true)
    let index = padding.lowerBound { $0.to.seconds > seconds }
    guard index < padding.count, padding[index].from.seconds <= seconds else { return time }
    return "\(time), retained silence padding"
}

final class TimelineSurface: NSView, NSViewToolTipOwner {
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

        func updateValue(_ time: Double, duration: Double, padding: [AudioSpan]) {
            super.setAccessibilityValue(NSNumber(value: time))
            setAccessibilityMinValue(NSNumber(value: 0))
            setAccessibilityMaxValue(NSNumber(value: duration))
            setAccessibilityValueDescription(timelineRulerDescription(at: time, padding: padding))
        }
    }

    private struct KeptRun {
        let sequenceStart: Double
        var sequenceEnd: Double
        let stripStart: Double
        var stripEnd: Double
    }

    private struct PositionedClip {
        let clip: TimelineClip
        let stripStart: Double
        let sequenceStart: Double
        let sequenceEnd: Double
        let sourceStart: Double
        let sourceEnd: Double

        var displayFrom: Double { min(sourceStart, clip.sourceStart, clip.displayRange?.from.seconds ?? 0) }
        var displayTo: Double { max(sourceEnd, clip.sourceEnd, clip.displayRange?.to.seconds ?? clip.sourceDuration) }
        var sourceOrigin: Double { stripStart - displayFrom }
        var stripEnd: Double { stripStart + (displayTo - displayFrom) }
        var keptStart: Double { stripStart + (sourceStart - displayFrom) }
        var keptEnd: Double { stripStart + (sourceEnd - displayFrom) }
    }

    private enum Interaction {
        case range(anchor: Double, downX: CGFloat)
        case seek(grabOffset: CGFloat)
        case clip(UUID, NSPoint)
        case reorder(UUID)
        case trim(UUID, TimelineEdge, Double, CGFloat, CGFloat)
    }

    private struct TrimPosition {
        let edge: TimelineEdge
        let time: Double
    }

    private struct TrimGeometry {
        let index: Int
        let clip: PositionedClip
        let sequenceDelta: Double
        let stripDelta: Double
    }

    private struct OpeningClock: Hashable {
        let origin: RationalTime
        let duration: Double
    }

    private struct ThumbnailKey: Hashable {
        let source: UUID
        let sourceTime: Double
        let size: CGSize
        var openingClock: OpeningClock? = nil
        var mediaRevision = 0

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source == rhs.source && lhs.sourceTime == rhs.sourceTime && lhs.size == rhs.size && lhs.openingClock == rhs.openingClock && lhs.mediaRevision == rhs.mediaRevision
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(source)
            hasher.combine(sourceTime)
            hasher.combine(size.width)
            hasher.combine(size.height)
            hasher.combine(openingClock)
            hasher.combine(mediaRevision)
        }
    }

    private struct FilmstripViewport: Equatable {
        let visible: Range<CGFloat>
        let scale: CGFloat
        let tileSize: CGSize
        let backingScale: CGFloat
        let enabled: Bool
    }

    private struct VisibleFilmstripTile {
        let rect: NSRect
        let key: ThumbnailKey
        let fallbacks: [ThumbnailKey]
    }

    var timeline: SequenceTimeline? {
        didSet {
            let previousDuration = sequenceDuration
            // Editor snapshots retain this native array across playhead updates.
            // A new edit supplies new storage with the current source geometry.
            let sharedClips = oldValue?.clips.withUnsafeBufferPointer { previous in
                timeline?.clips.withUnsafeBufferPointer { current in
                    previous.count == current.count && previous.baseAddress == current.baseAddress
                } ?? false
            } ?? false
            if !sharedClips || oldValue?.selection != timeline?.selection {
                selectedPositionIndex = timeline?.selection.flatMap { id in timeline?.clips.firstIndex { $0.id == id } }
            }
            if !sharedClips {
                // Undo can bring back a source whose tiles failed while it was being removed.
                if oldValue?.clips.contains(where: \.usesOpeningFilmstrip) == true ||
                    Set(oldValue?.clips.map(\.sourceID) ?? []) != Set(timeline?.clips.map(\.sourceID) ?? []) {
                    unavailableThumbnails.removeAll(keepingCapacity: true)
                }
                rebuildPositions()
                window?.invalidateCursorRects(for: self)
            } else if zoom > 1, interaction == nil, !isExternalDrag, let previous = oldValue?.playhead,
                      let current = timeline?.playhead, current != previous {
                // Continue following a visible playhead. A manual scroll away
                // from playback keeps the user's chosen portion of the ruler.
                if (visibleRect.minX...visibleRect.maxX).contains(x(at: previous)) {
                    reveal(time: current)
                }
            }
            if (oldValue?.onRangeSelect == nil) != (timeline?.onRangeSelect == nil) {
                if case .range = interaction { clearInteraction() }
                window?.invalidateCursorRects(for: self)
            }
            if oldValue?.allowsClipEdits != timeline?.allowsClipEdits {
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
            let paddingChanged = oldValue?.timelinePadding != timeline?.timelinePadding
            if previousDuration != sequenceDuration || oldValue?.playhead != timeline?.playhead || paddingChanged {
                accessibleRuler.updateValue(timeline?.playhead ?? 0, duration: sequenceDuration, padding: timeline?.timelinePadding ?? [])
            }
            let laneHeightChanged = oldValue?.thumbnailHeight != timeline?.thumbnailHeight ||
                oldValue?.waveformHeight != timeline?.waveformHeight
            if laneHeightChanged || oldValue?.markIn != timeline?.markIn || oldValue?.markOut != timeline?.markOut {
                updateTimelineOverlay()
            }
            if !sharedClips || oldValue?.sceneRevision != timeline?.sceneRevision ||
                oldValue?.showsWaveform != timeline?.showsWaveform || oldValue?.selection != timeline?.selection ||
                laneHeightChanged || paddingChanged || oldValue?.assemblyAssets != timeline?.assemblyAssets
                || (oldValue?.thumbnail == nil) != (timeline?.thumbnail == nil) {
                needsDisplay = true
            } else if oldValue?.waveformRevision != timeline?.waveformRevision {
                if timeline?.envelopeStore != nil && hasAudioOnlyClips {
                    setNeedsDisplay(NSRect(x: visibleRect.minX, y: laneTop, width: visibleRect.width, height: laneHeight))
                } else if waveformHeight > 0 {
                    setNeedsDisplay(NSRect(x: visibleRect.minX, y: waveformTop, width: visibleRect.width, height: waveformHeight))
                }
            }
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
    private var timelineToolTipTag: NSView.ToolTipTag?
    var zoom = 1.0
    var viewportWidth: CGFloat = 1
    private var interaction: Interaction?
    private var previewRange: ClosedRange<Double>?
    private let rangeOverlay = TimelineRangeOverlay()
    private var keptRuns: [KeptRun] = []
    private var trimPosition: TrimPosition?
    private var lastTrimTarget: Double?
    private var lastSeekTarget: Double?
    private var csvDrag = false
    private var stillDrag = false
    private var classifiedDropFiles: (all: [URL], media: [URL])?
    private var stillDropTime: Double?
    private var csvTarget: Int?
    private var insertionIndex: Int?
    private var dragLocation: NSPoint?
    private var isExternalDrag = false
    private var edgeScrollTimer: Timer?
    private var positions: [PositionedClip] = []
    private var hasAudioOnlyClips = false
    private var selectedPositionIndex: Int?
    private var trimClipIndex: Int?
    private var trimGeometry: TrimGeometry?
    private var sequenceDuration: Double { (positions.last?.sequenceEnd ?? 0) + (trimGeometry?.sequenceDelta ?? 0) }
    private var stripDuration: Double { (positions.last?.stripEnd ?? 0) + (trimGeometry?.stripDelta ?? 0) }
    private var filmstripViewport: FilmstripViewport?
    private var filmstripTilesByPosition: [Int: [VisibleFilmstripTile]] = [:]
    private var visibleThumbnailTiles: [ThumbnailKey: [NSRect]] = [:]
    private var thumbnails: [ThumbnailKey: NSImage] = [:]
    private var thumbnailOrder: [ThumbnailKey] = []
    private var unavailableThumbnails: Set<ThumbnailKey> = []
    private var thumbnailRequests: ArraySlice<ThumbnailKey> = []
    private var thumbnailTask: Task<Void, Never>?
    private var activeThumbnail: ThumbnailKey?
    private var accessibleClips: [UUID: AccessibleClip] = [:]
    private let accessibleRuler = AccessibleRuler()

    private let margin: CGFloat = 16
    private let laneTop: CGFloat = 31
    private var thumbnailHeight: CGFloat { timeline?.thumbnailHeight ?? TimelineClip.minimumThumbnailHeight }
    private var waveformHeight: CGFloat { timeline?.waveformHeight ?? 0 }
    private var waveformTop: CGFloat { laneTop + 21 + thumbnailHeight }
    private var laneHeight: CGFloat { thumbnailHeight + 29 + waveformHeight }
    private var thumbnailWidth: CGFloat {
        timeline?.largeThumbnails.wrappedValue == true ? TimelineClip.largeTileWidth : TimelineClip.tileWidth
    }

    fileprivate var playheadRect: NSRect? {
        guard let timeline, !positions.isEmpty, trimPosition == nil else { return nil }
        return NSRect(x: x(at: timeline.playhead) - 10, y: 16, width: 20, height: laneTop + laneHeight - 10)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEditingEnabled }

    private var scale: CGFloat {
        let available = max(1, viewportWidth - 2 * margin)
        let sourceDuration = stripDuration
        return sourceDuration > 0 ? available * zoom / sourceDuration : available
    }

    var contentWidth: CGFloat {
        let duration = stripDuration
        return margin * 2 + duration * scale
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sequence timeline")
        rangeOverlay.drawRange = { [weak self] visible in
            self?.drawDragMarkers()
            self?.drawRange(visible)
        }
        addSubview(rangeOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let timelineToolTipTag { removeToolTip(timelineToolTipTag) }
        timelineToolTipTag = bounds.isEmpty ? nil : addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData: UnsafeMutableRawPointer?) -> String {
        guard isEditingEnabled, let timeline else { return "View timeline" }
        if positions.isEmpty { return timeline.allowsFileDrops ? "Drop media here" : "View timeline" }
        switch pointerTarget(at: point, in: timeline) {
        case .range: return "Drag to select range"
        case .playhead: return "Drag playhead"
        case .seek: return "Scrub timeline"
        case .clip: return "Select or drag to reorder"
        case .trim(_, let edge): return edge == .start ? "Trim start" : "Trim end"
        }
    }

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
            accessibilityParentRect(NSRect(x: visibleRect.minX, y: 0, width: visibleRect.width, height: laneTop))
        )
        accessibleRuler.seek = { [weak self] direction in
            guard let self, self.isEditingEnabled, let timeline = self.timeline else { return false }
            self.seekAccessibly(to: timeline.playhead + direction * timelineRulerStep(scale: self.scale) / 5)
            return true
        }
        accessibleRuler.setPosition = { [weak self] in self?.seekAccessibly(to: $0) }
        let ids = Set(positions.map { $0.clip.id })
        accessibleClips = accessibleClips.filter { ids.contains($0.key) }
        let children: [AccessibleClip] = positions.indices.map { index in
            let position = position(at: index)
            let id = position.clip.id
            let element = accessibleClips[id] ?? AccessibleClip()
            accessibleClips[id] = element
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(position.clip.stripLabel)
            element.setAccessibilityValue(
                "\(timelineTime(position.sequenceStart, milliseconds: true))–\(timelineTime(position.sequenceEnd, milliseconds: true))"
            )
            element.setAccessibilitySelected(id == timeline?.selection)
            element.setAccessibilityEnabled(isEditingEnabled)
            element.setAccessibilityFrameInParentSpace(accessibilityParentRect(clipRect(position)))
            element.select = { [weak self] in self?.focusAccessibleClip(id) ?? false }
            var actions: [NSAccessibilityCustomAction] = []
            if let playhead = timeline?.playhead, playhead > position.sequenceStart, playhead < position.sequenceEnd {
                actions.append(accessibleTrim(id, edge: .start, restore: false, name: "Trim start to playhead"))
                actions.append(accessibleTrim(id, edge: .end, restore: false, name: "Trim end to playhead"))
            }
            if position.sourceStart > 0 {
                actions.append(accessibleTrim(id, edge: .start, restore: true, name: "Restore original start"))
            }
            if position.sourceEnd < position.clip.sourceDuration {
                actions.append(accessibleTrim(id, edge: .end, restore: true, name: "Restore original end"))
            }
            if index > 0 {
                actions.append(accessibleMove(id, by: -1, name: "Move clip earlier"))
            }
            if index + 1 < positions.count {
                actions.append(accessibleMove(id, by: 1, name: "Move clip later"))
            }
            element.setAccessibilityCustomActions(timeline?.allowsClipEdits == true && !position.clip.isGap ? actions : [])
            return element
        }
        return [accessibleRuler] + children.map { $0 as NSAccessibilityElement }
    }

    /// NSAccessibilityElement reads parent-space frames as unflipped view coordinates.
    private func accessibilityParentRect(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: bounds.minY + bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    // AppKit declares this informal accessibility method without actor isolation, but only calls it on the main thread.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        MainActor.assumeIsolated {
            guard let window, !positions.isEmpty else { return super.accessibilityHitTest(point) }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            guard visibleRect.contains(local) else { return super.accessibilityHitTest(point) }
            let children = accessibilityChildren()
            if local.y < laneTop { return children?.first }
            let index = firstClipIndex { stripX(at: $0.stripEnd) > local.x }
            if positions.indices.contains(index), clipRect(position(at: index)).contains(local) {
                return children?[index + 1]
            }
            return super.accessibilityHitTest(point)
        }
    }

    private func seekAccessibly(to time: Double) {
        guard isEditingEnabled, let timeline else { return }
        let target = min(sequenceDuration, max(0, time))
        timeline.onSeek(target)
        reveal(time: target)
    }

    private func focusAccessibleClip(_ id: UUID) -> Bool {
        guard isEditingEnabled, let timeline,
              let index = positions.firstIndex(where: { $0.clip.id == id }) else { return false }
        let clip = position(at: index)
        timeline.onSelect(id)
        timeline.onSeek(clip.sequenceStart)
        reveal(time: clip.sequenceStart)
        return true
    }

    private func accessibleTrim(_ id: UUID, edge: TimelineEdge, restore: Bool, name: String) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self, self.isEditingEnabled, let timeline = self.timeline, timeline.allowsClipEdits,
                  let index = self.positions.firstIndex(where: { $0.clip.id == id }) else { return false }
            let position = self.position(at: index)
            let sourceTime: Double
            if restore {
                sourceTime = edge == .start ? 0 : position.clip.sourceDuration
            } else {
                guard timeline.playhead > position.sequenceStart, timeline.playhead < position.sequenceEnd else { return false }
                sourceTime = position.sourceStart + (timeline.playhead - position.sequenceStart)
            }
            if let validate = timeline.validateHandle {
                validate(id, edge, sourceTime, true) { _ in }
                return true
            }
            return timeline.onTrim(id, edge, sourceTime, true) != nil
        }
    }

    private func accessibleMove(_ id: UUID, by offset: Int, name: String) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self, self.isEditingEnabled, let timeline = self.timeline, timeline.allowsClipEdits,
                  let index = self.positions.firstIndex(where: { $0.clip.id == id }),
                  self.positions.indices.contains(index + offset) else { return false }
            timeline.onMove(id, index + (offset < 0 ? -1 : 2))
            return true
        }
    }

    private func rebuildPositions() {
        var stripStart = 0.0
        var nextSequenceTime = 0.0
        keptRuns.removeAll(keepingCapacity: true)
        hasAudioOnlyClips = false
        positions = (timeline?.clips ?? []).map { clip in
            if clip.isAudioOnly { hasAudioOnlyClips = true }
            let sequenceStart = clip.sequenceRange?.lowerBound ?? nextSequenceTime
            let sequenceEnd = clip.sequenceRange?.upperBound ?? (sequenceStart + clip.duration)
            let position = PositionedClip(clip: clip, stripStart: stripStart, sequenceStart: sequenceStart, sequenceEnd: sequenceEnd,
                                          sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd)
            stripStart = position.stripEnd
            nextSequenceTime = position.sequenceEnd
            if let last = keptRuns.last, last.stripEnd == position.keptStart,
               last.sequenceEnd == position.sequenceStart {
                keptRuns[keptRuns.count - 1].sequenceEnd = position.sequenceEnd
                keptRuns[keptRuns.count - 1].stripEnd = position.keptEnd
            } else {
                keptRuns.append(KeptRun(sequenceStart: position.sequenceStart, sequenceEnd: position.sequenceEnd,
                                        stripStart: position.keptStart, stripEnd: position.keptEnd))
            }
            return position
        }
        if case let .trim(id, _, _, _, _) = interaction {
            trimClipIndex = positions.firstIndex { $0.clip.id == id }
        }
        updateTrimGeometry()
        updateTimelineOverlay()
    }

    private func updateTrimGeometry() {
        filmstripViewport = nil
        guard let trimPosition, let index = trimClipIndex else {
            trimGeometry = nil
            return
        }
        let original = positions[index]
        let sourceStart = trimPosition.edge == .start ? trimPosition.time : original.sourceStart
        let sourceEnd = trimPosition.edge == .end ? trimPosition.time : original.sourceEnd
        let sequenceDelta = (sourceEnd - sourceStart) - original.clip.duration
        let clip = PositionedClip(clip: original.clip, stripStart: original.stripStart,
                                  sequenceStart: original.sequenceStart, sequenceEnd: original.sequenceEnd + sequenceDelta,
                                  sourceStart: sourceStart, sourceEnd: sourceEnd)
        trimGeometry = TrimGeometry(index: index, clip: clip, sequenceDelta: sequenceDelta,
                                    stripDelta: clip.stripEnd - original.stripEnd)
    }

    // A preview changes one clip and translates all clips that follow it.
    private func position(at index: Int) -> PositionedClip {
        let original = positions[index]
        guard let trimGeometry, index >= trimGeometry.index else { return original }
        if index == trimGeometry.index { return trimGeometry.clip }
        return PositionedClip(clip: original.clip, stripStart: original.stripStart + trimGeometry.stripDelta,
                              sequenceStart: original.sequenceStart + trimGeometry.sequenceDelta,
                              sequenceEnd: original.sequenceEnd + trimGeometry.sequenceDelta,
                              sourceStart: original.sourceStart, sourceEnd: original.sourceEnd)
    }

    fileprivate func stripX(at time: Double) -> CGFloat { margin + time * scale }
    private func stripTime(at x: CGFloat) -> Double { Double((x - margin) / scale) }

    private func x(at sequenceTime: Double, preceding: Bool = false) -> CGFloat {
        guard !positions.isEmpty else { return margin }
        let index = min(positions.count - 1, firstClipIndex { preceding ? $0.sequenceEnd >= sequenceTime : $0.sequenceEnd > sequenceTime })
        let clip = position(at: index)
        let local = min(clip.sequenceEnd, max(clip.sequenceStart, sequenceTime)) - clip.sequenceStart
        return stripX(at: clip.keptStart + local)
    }

    private func sequenceTime(at x: CGFloat) -> Double {
        guard !positions.isEmpty else { return 0 }
        let time = stripTime(at: x)
        let index = min(positions.count - 1, firstClipIndex { $0.stripEnd > time })
        let clip = position(at: index)
        if time <= clip.keptStart { return clip.sequenceStart }
        if time >= clip.keptEnd { return clip.sequenceEnd }
        return clip.sequenceStart + (time - clip.keptStart)
    }

    func reveal(time: Double) {
        guard let scrollView = enclosingScrollView as? TimelineScrollView else { return }
        let visible = visibleRect
        let point = x(at: time)
        if point < visible.minX + margin || point > visible.maxX - margin {
            scrollView.scrollHorizontally(to: point - visible.width / 2)
        }
    }

    fileprivate func zoomAnchor(playhead: Double) -> (time: Double, offset: CGFloat) {
        let visible = visibleRect
        let anchor = timelineZoomAnchor(playheadX: x(at: playhead), visible: visible.minX..<visible.maxX)
        return (stripTime(at: anchor), anchor - visible.minX)
    }

    private func clipRect(_ position: PositionedClip) -> NSRect {
        NSRect(x: stripX(at: position.keptStart), y: laneTop,
               width: CGFloat(position.sourceEnd - position.sourceStart) * scale, height: laneHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let timeline else { return }

        fill(dirtyRect, NSColor.controlBackgroundColor)
        if !timeline.assemblyAssets.isEmpty {
            let top = laneTop + laneHeight + 5
            fill(NSRect(x: 0, y: top, width: bounds.width, height: 1), .separatorColor)
            for asset in timeline.assemblyAssets {
                let left = x(at: asset.interval.from.seconds)
                let right = x(at: asset.interval.to.seconds, preceding: true)
                let rect = NSRect(x: left, y: top + 3, width: max(1, right - left), height: 18)
                guard rect.intersects(dirtyRect) else { continue }
                fill(rect, NSColor.systemPurple.withAlphaComponent(0.25))
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                label(asset.title, at: NSPoint(x: left + 4, y: top + 4),
                      font: .systemFont(ofSize: 11, weight: .medium), color: .labelColor)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        fill(NSRect(x: 0, y: laneTop - 2, width: bounds.width, height: laneHeight + 4),
             NSColor.labelColor.withAlphaComponent(0.055))
        fill(NSRect(x: 0, y: laneTop - 3, width: bounds.width, height: 1), .separatorColor)

        let waveformOnly = waveformHeight > 0 && dirtyRect.minY >= waveformTop && dirtyRect.maxY <= waveformTop + waveformHeight
        if !waveformOnly { updateVisibleFilmstrip(visibleRect) }
        var visibleWaveforms = Set<WaveformSurface>()
        defer { timeline.envelopeStore?.setVisibleTimelineSurfaces(visibleWaveforms) }
        if positions.isEmpty {
            let hint = timeline.onDropStills == nil ? "Drop audio or video files here" : "Drop video, audio, or still images here"
            label(hint, at: NSPoint(x: margin + 10, y: laneTop + 20),
                  font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
        } else {
            let visible = visibleRect
            let visibleStart = stripTime(at: visible.minX)
            let visibleEnd = stripTime(at: visible.maxX)
            var lastLabelEnd = -CGFloat.infinity
            let first = firstClipIndex { $0.stripEnd > visibleStart }
            let wantsDetail = timeline.showsWaveform && AudioEnvelopeStore.needsTimelineDetail(
                secondsPerPixel: 1 / (scale * (window?.backingScaleFactor ?? 2)))
            for index in first..<positions.count {
                let position = position(at: index)
                if position.stripStart >= visibleEnd { break }
                let refreshDetail = timeline.showsWaveform && timeline.envelopeStore?.isVisibleOnly(position.clip.sourceID) == true
                if position.clip.isAudioOnly || wantsDetail || refreshDetail { visibleWaveforms.insert(.timeline(position.clip.id)) }
                if dirtyRect.minY < laneTop {
                    drawRuler(visible, position: position, lastLabelEnd: &lastLabelEnd)
                }
                if position.clip.isGap { continue }
                drawClip(position, index: index, selected: position.clip.id == timeline.selection,
                         visible: visible, dirty: dirtyRect, waveformOnly: waveformOnly)
            }

            if let trimPosition, let trimClipIndex {
                let position = position(at: trimClipIndex)
                let edge = trimPosition.edge == .start ? position.keptStart : position.keptEnd
                drawTimelinePlayhead(x: stripX(at: edge), top: 16, bottom: laneTop + laneHeight + 6, color: .controlAccentColor)
                drawTrimTime(trimPosition.time, edgeX: stripX(at: edge))
            } else if !(enclosingScrollView is TimelineScrollView) {
                drawTimelinePlayhead(x: x(at: timeline.playhead), top: 16, bottom: laneTop + laneHeight + 6, color: .systemRed)
            }
        }
    }

    private func drawDragMarkers() {
        if let csvTarget, positions.indices.contains(csvTarget) {
            let rect = clipRect(position(at: csvTarget)).insetBy(dx: 1, dy: 1)
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
        let marker: CGFloat?
        if let stillDropTime {
            marker = x(at: stillDropTime)
        } else if let insertionIndex {
            let time = positions.indices.contains(insertionIndex)
                ? position(at: insertionIndex).stripStart : stripDuration
            marker = stripX(at: time)
        } else {
            marker = nil
        }
        if let marker {
            fill(NSRect(x: marker - 1.5, y: laneTop - 5, width: 3, height: laneHeight + 10),
                 .controlAccentColor)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: marker - 4, y: laneTop - 8, width: 8, height: 8)).fill()
        }
    }

    private func drawRuler(_ visible: NSRect, position: PositionedClip, lastLabelEnd: inout CGFloat) {
        let step = timelineRulerStep(scale: scale)
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
            guard major else { continue }
            let text = timelineTime(time, milliseconds: step < 1)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let right = tickX + 4
            let left = right + width <= visible.maxX - 4 ? right : tickX - width - 4
            guard left >= max(visible.minX, lastLabelEnd + 8) else { continue }
            label(text, at: NSPoint(x: left, y: 5), font: font, color: .secondaryLabelColor)
            lastLabelEnd = left + width
        }
    }

    private func drawWaveform(clip: TimelineClip, lane: NSRect, sourceStart: Double, visible: NSRect, dirty: NSRect) {
        let area = lane.intersection(visible)
        let repaint = area.intersection(dirty)
        guard !repaint.isEmpty, needsToDraw(repaint) else { return }
        fill(area, .controlBackgroundColor)
        let scale = self.scale
        let from = sourceStart + (area.minX - lane.minX) / scale
        let to = sourceStart + (area.maxX - lane.minX) / scale
        let pauses = timeline?.waveformPauses[clip.sourceID] ?? []
        for pause in pauses[pauses.lowerBound { $0.to.seconds > from }...] {
            if pause.from.seconds >= to { break }
            let left = max(area.minX, lane.minX + (pause.from.seconds - sourceStart) * scale)
            let right = min(area.maxX, lane.minX + (pause.to.seconds - sourceStart) * scale)
            fill(NSRect(x: left, y: lane.minY, width: right - left, height: lane.height),
                 NSColor.systemTeal.withAlphaComponent(0.20))
        }
        let backing = window?.backingScaleFactor ?? 2
        let surface = WaveformSurface.timeline(clip.id)
        let store = timeline?.envelopeStore
        let wave = timeline?.waveforms[clip.sourceID]
        let detail = area.width * backing >= 2 && (store?.isVisibleOnly(clip.sourceID) == true || AudioEnvelopeStore.needsTimelineDetail(secondsPerPixel: 1 / (scale * backing)))
            ? store?.envelope(for: clip.sourceID, surface: surface, from: from, to: to,
                              pixels: Int(ceil(area.width * backing)), showSparseWhileLoading: wave == nil)
            : nil
        if detail == nil {
            let opening = timeline?.openingWaveform
            let sampled = store?.sparseWaveform(for: clip.sourceID, surface: surface)
                ?? (opening?.source == clip.sourceID ? opening?.waveform : nil)
            let sampledStart = max(from, Double(wave?.count ?? 0) / Double(AudioWaveform.rate))
            if let sampled, sampledStart < to {
                let left = area.minX + (sampledStart - from) * scale
                let sampledArea = CGRect(x: left, y: area.minY, width: area.maxX - left, height: area.height)
                let path = WaveformDrawing.sparsePath(sampled, in: sampledArea, sourceStart: sampledStart, pointsPerSecond: scale)
                NSColor.systemTeal.withAlphaComponent(0.45).setFill()
                NSBezierPath(cgPath: path).fill()
                if !path.isEmpty, area.maxX - path.boundingBox.minX > 95 {
                    label("Sampled audio", at: CGPoint(x: path.boundingBox.minX + 4, y: lane.minY + 1),
                          font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
                }
            }
        }
        let path = WaveformDrawing.timelinePath(in: CGRect(x: area.minX, y: lane.minY, width: area.width, height: lane.height),
            sourceStart: from, pointsPerSecond: scale, displayScale: backing, detail: detail,
            coarse: wave, dirtyX: repaint.minX..<repaint.maxX)
        NSColor.systemTeal.withAlphaComponent(0.9).setFill()
        NSBezierPath(cgPath: path).fill()
    }

    private func drawClip(_ position: PositionedClip, index: Int, selected: Bool, visible: NSRect, dirty: NSRect,
                          waveformOnly: Bool) {
        let rect = clipRect(position)
        let strip = NSRect(x: stripX(at: position.stripStart), y: laneTop,
                          width: (position.displayTo - position.displayFrom) * scale, height: laneHeight)
        guard strip.intersects(visible) else { return }
        let filmstrip = NSRect(x: strip.minX, y: strip.minY + 21, width: strip.width, height: thumbnailHeight)
        if position.clip.isAudioOnly {
            let lane = NSRect(x: filmstrip.minX, y: filmstrip.minY, width: filmstrip.width,
                              height: filmstrip.height + waveformHeight)
            let area = lane.intersection(visible)
            if !area.isEmpty, needsToDraw(area) {
                fill(area, .controlBackgroundColor)
                let sourceStart = position.displayFrom
                let backing = window?.backingScaleFactor ?? 2
                let detail = timeline?.envelopeStore?.envelope(for: position.clip.sourceID, surface: .timeline(position.clip.id),
                    from: sourceStart + (area.minX - lane.minX) / scale, to: sourceStart + (area.maxX - lane.minX) / scale,
                    pixels: Int(ceil(area.width * backing)))
                WaveformDrawing.draw(in: lane, visible: area, seconds: sourceStart..<position.displayTo, scale: backing,
                                     detail: detail, coarse: timeline?.waveforms[position.clip.sourceID],
                                     pauses: timeline?.waveformPauses[position.clip.sourceID] ?? [], color: .systemTeal,
                                     dirty: dirty)
            }
        } else {
            if !waveformOnly, filmstrip.intersects(dirty) {
                drawThumbnails(at: index, displaySize: position.clip.displaySize, dirty: dirty)
            }
            if timeline?.showsWaveform == true {
                let lane = NSRect(x: strip.minX, y: filmstrip.maxY, width: strip.width, height: waveformHeight)
                drawWaveform(clip: position.clip, lane: lane, sourceStart: position.displayFrom, visible: visible, dirty: dirty)
            }
        }
        for excluded in [NSRect(x: strip.minX, y: laneTop, width: max(0, rect.minX - strip.minX), height: laneHeight),
                         NSRect(x: rect.maxX, y: laneTop, width: max(0, strip.maxX - rect.maxX), height: laneHeight)]
            where excluded.width > 0 {
            fill(excluded, NSColor.controlBackgroundColor.withAlphaComponent(0.74))
            fill(excluded, NSColor.secondaryLabelColor.withAlphaComponent(0.09))
        }
        guard rect.intersects(visible), needsToDraw(rect.insetBy(dx: -6, dy: -1)) else { return }
        let border = selected ? NSColor.controlAccentColor : NSColor.separatorColor
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: min(0.5, rect.width / 4), dy: 0.5),
                                 xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // Tint the title strip and the footer. The pictures and the waveform keep their own colors.
        let chrome = selected ? NSColor.controlAccentColor.withAlphaComponent(0.30)
                              : NSColor.labelColor.withAlphaComponent(0.09)
        let body = NSRect(x: rect.minX, y: rect.minY + 21, width: rect.width, height: rect.height - 29)
        fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 21), position.clip.replacementAudio == nil ? chrome : NSColor.systemTeal.withAlphaComponent(0.35))
        fill(NSRect(x: rect.minX, y: body.maxY, width: rect.width, height: rect.maxY - body.maxY), chrome)
        // A lane without pictures (the assembly) is too short for bands, so it takes one even tint.
        fill(body, body.height < 12 ? chrome : selected ? NSColor.controlAccentColor.withAlphaComponent(0.06) : .clear)
        // Project the retained edges from the edit plan onto this occurrence only.
        let padding = timeline?.timelinePadding ?? []
        let area = body.intersection(visible)
        if !area.isEmpty {
            let start = position.sequenceStart + (area.minX - rect.minX) / scale
            let end = position.sequenceStart + (area.maxX - rect.minX) / scale
            for span in padding[padding.lowerBound { $0.to.seconds > start }...] {
                if span.from.seconds >= end { break }
                let left = max(area.minX, rect.minX + (span.from.seconds - position.sequenceStart) * scale)
                let right = min(area.maxX, rect.minX + (span.to.seconds - position.sequenceStart) * scale)
                if right > left {
                    fill(NSRect(x: left, y: area.minY, width: right - left, height: area.height),
                         NSColor.systemIndigo.withAlphaComponent(0.22))
                }
            }
        }
        let nameX = max(rect.minX + 8, visible.minX + 6)
        let nameWidth = max(0, min(rect.maxX - 8, visible.maxX - 6) - nameX)
        let nameRect = NSRect(x: nameX, y: rect.minY + 4, width: nameWidth, height: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (position.clip.stripLabel as NSString).draw(in: nameRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])

        let sourceLeft = max(position.sourceStart, stripTime(at: visible.minX) - position.sourceOrigin)
        let sourceRight = min(position.sourceEnd, stripTime(at: visible.maxX) - position.sourceOrigin)
        let keyframes = position.clip.keyframes
        var index = keyframes.lowerBound { $0 >= sourceLeft }
        var lastX = -CGFloat.infinity
        while index < keyframes.count, keyframes[index] < sourceRight {
            let tickX = stripX(at: position.sourceOrigin + keyframes[index])
            if tickX - lastX >= 3 {
                fill(NSRect(x: tickX, y: rect.maxY - 7, width: 1, height: 5), .secondaryLabelColor)
                lastX = tickX
            }
            let nextTime = keyframes[index] + Double(3 / scale)
            index = max(index + 1, keyframes.lowerBound { $0 >= nextTime })
        }
        drawScenes(position, from: sourceLeft, to: sourceRight, bottom: rect.maxY - waveformHeight)

        NSGraphicsContext.restoreGraphicsState()
        border.setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
        if selected, timeline?.allowsClipEdits == true {
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

    private static let viewColors: [NSColor] = [.systemTeal, .systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemPink]

    private func drawScenes(_ position: PositionedClip, from left: Double, to right: Double, bottom: CGFloat) {
        guard let timeline else { return }
        let overlay = timeline.sceneOverlaysByClip[position.clip.id]
        let left = max(left, overlay?.from ?? left)
        let right = min(right, overlay?.to ?? right)
        guard right > left, let scenes = overlay?.scenes ?? timeline.scenesBySource[position.clip.sourceID],
              !scenes.isEmpty else { return }
        let names = overlay?.names ?? timeline.viewNamesBySource[position.clip.sourceID] ?? [:]
        let first = max(0, scenes.lowerBound { $0.start > left } - 1)
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var lastMarkerX = -CGFloat.infinity
        for index in first..<scenes.count {
            let scene = scenes[index]
            guard scene.start < right else { break }
            let end = index + 1 < scenes.count ? scenes[index + 1].start : (overlay?.to ?? position.clip.sourceDuration)
            let x = stripX(at: position.sourceOrigin + max(left, scene.start))
            let width = stripX(at: position.sourceOrigin + min(right, end)) - x
            let color = Self.viewColors[(scene.view - 1) % Self.viewColors.count]
            if scene.start >= left, overlay.map({ $0.leadingIsCut || scene.start > $0.from }) ?? true, x - lastMarkerX >= 3 {
                fill(NSRect(x: x, y: bottom - 13, width: 2, height: 10), color)
                lastMarkerX = x
            }
            guard width >= 46 else { continue }
            let name = (names[scene.view] ?? "View \(SceneView.label(for: scene.view))") as NSString
            let badgeWidth = min(width - 8, ceil(name.size(withAttributes: [.font: font]).width) + 18)
            let badge = NSRect(x: x + 4, y: bottom - 27, width: badgeWidth, height: 15)
            NSColor.black.withAlphaComponent(0.84).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: badge.minX + 4, y: badge.midY - 2, width: 4, height: 4)).fill()
            name.draw(in: NSRect(x: badge.minX + 11, y: badge.minY + 1, width: badgeWidth - 15, height: 13),
                      withAttributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        }
    }

    private func updateVisibleFilmstrip(_ visible: NSRect) {
        let viewport = FilmstripViewport(visible: visible.minX..<visible.maxX, scale: scale,
                                         tileSize: CGSize(width: thumbnailWidth, height: thumbnailHeight),
                                         backingScale: window?.backingScaleFactor ?? 2,
                                         enabled: timeline?.thumbnail != nil)
        guard filmstripViewport != viewport else { return }
        filmstripViewport = viewport
        visibleThumbnailTiles.removeAll(keepingCapacity: true)
        filmstripTilesByPosition.removeAll(keepingCapacity: true)
        var keys: [ThumbnailKey] = []
        if viewport.enabled {
            let start = stripTime(at: visible.minX)
            let end = stripTime(at: visible.maxX)
            let first = firstClipIndex { $0.stripEnd > start }
            for index in first..<positions.count {
                let position = position(at: index)
                if position.stripStart >= end { break }
                guard !position.clip.isGap, !position.clip.isAudioOnly, position.clip.mediaIssue == nil else { continue }
                let rect = NSRect(x: stripX(at: position.stripStart), y: laneTop + 21,
                                  width: (position.displayTo - position.displayFrom) * viewport.scale,
                                  height: viewport.tileSize.height)
                guard rect.width > 0 else { continue }
                filmstripTilesByPosition[index] = planFilmstripTiles(position, rect: rect, viewport: viewport, keys: &keys)
            }
        }
        thumbnailRequests = keys.filter { thumbnails[$0] == nil && !unavailableThumbnails.contains($0) }[...]
        loadThumbnails()
    }

    private func planFilmstripTiles(_ position: PositionedClip, rect: NSRect, viewport: FilmstripViewport,
                                    keys: inout [ThumbnailKey]) -> [VisibleFilmstripTile] {
        // Distribute the clip width evenly, including the final picture.
        let layout = TimelineFilmstrip(width: rect.width, targetWidth: viewport.tileSize.width)
        let tileWidth = layout.tileWidth
        let tiles = layout.visibleTiles(origin: rect.minX, visible: viewport.visible)
        guard !tiles.isEmpty else { return [] }

        let size = CGSize(width: viewport.tileSize.width * viewport.backingScale,
                          height: viewport.tileSize.height * viewport.backingScale)
        let groups = min(tiles.count, TimelineFilmstrip.openingFrameLimit)
        let middle = groups / 2
        let last = groups - 1
        let openingClock = OpeningClock(origin: position.clip.sourceOrigin, duration: position.clip.sourceDuration)

        let openingKeys = (0..<groups).map { group in
            // Round up both boundaries so every group gets at least one tile.
            let from = tiles.lowerBound + (group * tiles.count + groups - 1) / groups
            let to = tiles.lowerBound + ((group + 1) * tiles.count + groups - 1) / groups
            let sample = group == 0 ? CGFloat(from) : CGFloat(from + to) / 2
            return ThumbnailKey(source: position.clip.sourceID,
                                sourceTime: position.displayFrom + Double(sample * tileWidth / viewport.scale),
                                size: size, openingClock: openingClock, mediaRevision: position.clip.mediaRevision)
        }

        let usesOpening = position.clip.usesOpeningFilmstrip
        if usesOpening {
            // Cover the start, middle and end first. Each is also one of the final ten.
            keys.append(openingKeys[0])
            if middle > 0 { keys.append(openingKeys[middle]) }
            if last > middle { keys.append(openingKeys[last]) }
            for group in 1..<groups where group != middle && group != last {
                keys.append(openingKeys[group])
            }
        }

        return tiles.map { tile in
            let group = (tile - tiles.lowerBound) * groups / tiles.count
            let key: ThumbnailKey
            if usesOpening {
                key = openingKeys[group]
            } else {
                let start = position.displayFrom + Double(CGFloat(tile) * tileWidth / viewport.scale)
                let end = min(position.displayTo, position.displayFrom + Double(CGFloat(tile + 1) * tileWidth / viewport.scale))
                key = ThumbnailKey(source: position.clip.sourceID, sourceTime: position.clip.thumbnailTime(from: start, to: end), size: size, mediaRevision: position.clip.mediaRevision)
                if keys.last != key { keys.append(key) }
            }
            let range = layout.tileRange(tile, origin: rect.minX, displayScale: viewport.backingScale)
            let tileRect = NSRect(x: range.lowerBound, y: rect.minY, width: range.upperBound - range.lowerBound,
                                  height: rect.height)
            visibleThumbnailTiles[key, default: []].append(tileRect)
            var fallbacks = [ThumbnailKey]()
            if !usesOpening { fallbacks.append(openingKeys[group]) }
            // Unfilled groups share the closest of the three early pictures.
            let anchor: Int
            if group * 2 <= middle { anchor = 0 }
            else if group * 2 <= middle + last { anchor = middle }
            else { anchor = last }
            if anchor != group { fallbacks.append(openingKeys[anchor]) }
            if anchor != 0 && group != 0 { fallbacks.append(openingKeys[0]) }
            if usesOpening {
                for fallback in fallbacks { visibleThumbnailTiles[fallback, default: []].append(tileRect) }
            }
            return VisibleFilmstripTile(rect: tileRect, key: key, fallbacks: fallbacks)
        }
    }

    private func drawThumbnails(at index: Int, displaySize: CGSize, dirty: NSRect) {
        guard let tiles = filmstripTilesByPosition[index] else { return }
        let first = tiles.lowerBound { $0.rect.maxX > dirty.minX }
        for tile in tiles.dropFirst(first) {
            guard tile.rect.minX < dirty.maxX else { break }
            guard needsToDraw(tile.rect) else { continue }
            guard let image = thumbnails[tile.key] ?? tile.fallbacks.lazy.compactMap({ self.thumbnails[$0] }).first else { continue }
            let aspectSize = displaySize.width > 0 && displaySize.height > 0 ? displaySize : image.size
            let scale = max(tile.rect.width / aspectSize.width, tile.rect.height / aspectSize.height)
            let width = aspectSize.width * scale
            let height = aspectSize.height * scale
            let target = NSRect(x: tile.rect.midX - width / 2, y: tile.rect.midY - height / 2,
                                width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: tile.rect).addClip()
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func loadThumbnails() {
        if let activeThumbnail, visibleThumbnailTiles[activeThumbnail] == nil {
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
                    if self.thumbnails.count >= max(256, self.visibleThumbnailTiles.count),
                       let obsolete = self.thumbnailOrder.firstIndex(where: { self.visibleThumbnailTiles[$0] == nil }) {
                        self.thumbnails.removeValue(forKey: self.thumbnailOrder.remove(at: obsolete))
                    }
                    self.thumbnails[key] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.thumbnailOrder.append(key)
                    for tile in self.visibleThumbnailTiles[key] ?? [] { self.setNeedsDisplay(tile) }
                } else if self.timeline?.clips.contains(where: { $0.sourceID == key.source }) == true {
                    if self.unavailableThumbnails.count >= 1024 { self.unavailableThumbnails.removeAll() }
                    self.unavailableThumbnails.insert(key)
                }
            }
            self?.activeThumbnail = nil
            self?.thumbnailTask = nil
            self?.loadThumbnails()
        }
    }

    fileprivate func updateTimelineOverlay() {
        let hasMarks = previewRange != nil || timeline?.markIn != nil || timeline?.markOut != nil
        let hasDragMarker = csvTarget != nil || insertionIndex != nil || stillDropTime != nil
        rangeOverlay.update(viewport: visibleRect.intersection(bounds),
                            showMarks: hasDragMarker || (!positions.isEmpty && hasMarks))
    }

    private func setDragMarkers(csvTarget: Int? = nil, insertionIndex: Int? = nil, stillDropTime: Double? = nil) {
        guard self.csvTarget != csvTarget || self.insertionIndex != insertionIndex
                || self.stillDropTime != stillDropTime else { return }
        self.csvTarget = csvTarget
        self.insertionIndex = insertionIndex
        self.stillDropTime = stillDropTime
        updateTimelineOverlay()
    }

    private func drawRange(_ visible: NSRect) {
        let markIn = previewRange?.lowerBound ?? timeline?.markIn
        let markOut = previewRange?.upperBound ?? timeline?.markOut
        if let markIn, let markOut {
            let start = min(markIn, markOut)
            let end = max(markIn, markOut)
            let visibleStart = stripTime(at: visible.minX)
            let visibleEnd = stripTime(at: visible.maxX)
            let shade = NSBezierPath()
            func appendShade(_ run: KeptRun) {
                let lower = max(run.sequenceStart, start)
                let upper = min(run.sequenceEnd, end)
                if upper > lower {
                    let left = stripX(at: run.stripStart + (lower - run.sequenceStart))
                    let right = stripX(at: run.stripEnd + (upper - run.sequenceEnd))
                    shade.appendRect(NSRect(x: left, y: 24, width: right - left, height: laneTop + laneHeight - 22)
                        .intersection(visible))
                }
            }
            if trimGeometry != nil {
                // Use the adjusted clips in view while the cached runs still describe the committed edit.
                let first = firstClipIndex { $0.keptEnd > visibleStart && $0.sequenceEnd > start }
                var run: KeptRun?
                for index in first..<positions.count {
                    let clip = position(at: index)
                    if clip.keptStart >= visibleEnd || clip.sequenceStart >= end { break }
                    if run?.stripEnd == clip.keptStart, run?.sequenceEnd == clip.sequenceStart {
                        run?.sequenceEnd = clip.sequenceEnd
                        run?.stripEnd = clip.keptEnd
                    } else {
                        if let run { appendShade(run) }
                        run = KeptRun(sequenceStart: clip.sequenceStart, sequenceEnd: clip.sequenceEnd,
                                      stripStart: clip.keptStart, stripEnd: clip.keptEnd)
                    }
                }
                if let run { appendShade(run) }
            } else {
                let first = keptRuns.lowerBound { $0.stripEnd > visibleStart && $0.sequenceEnd > start }
                for index in first..<keptRuns.count {
                    let run = keptRuns[index]
                    if run.stripStart >= visibleEnd || run.sequenceStart >= end { break }
                    appendShade(run)
                }
            }
            NSColor.controlAccentColor.withAlphaComponent(0.19).setFill()
            shade.fill()
        }
        if let markIn { drawMark(markIn, isIn: true, otherMark: markOut) }
        if let markOut { drawMark(markOut, isIn: false, otherMark: markIn) }
    }

    private func drawMark(_ time: Double, isIn: Bool, otherMark: Double?) {
        // Put the bracket on its own side of the playhead so it is visible immediately.
        let edge = x(at: time, preceding: otherMark.map { time > $0 } ?? !isIn)
        for rect in timelineMarkRects(at: edge, isIn: isIn, bottom: laneTop + laneHeight + 2) {
            fill(rect, .controlAccentColor)
        }
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
        guard isEditingEnabled else { return }
        if timeline?.onRangeSelect != nil, !positions.isEmpty {
            addCursorRect(visibleRect, cursor: .iBeam)
            return
        }
        guard timeline?.allowsClipEdits == true,
              let selectedPositionIndex else { return }
        let selected = position(at: selectedPositionIndex)
        guard !selected.clip.isStill, !selected.clip.isGap else { return }
        let rect = clipRect(selected)
        for edge in [TimelineEdge.start, .end] {
            let grip = gripRect(rect, edge: edge, position: selected)
            let visibleGrip = grip.intersection(visibleRect)
            if !visibleGrip.isEmpty { addCursorRect(visibleGrip, cursor: .resizeLeftRight) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard isEditingEnabled, let timeline, timeline.allowsClipEdits,
              let index = clipIndex(at: point) else { return super.menu(for: event) }
        let clip = position(at: index)
        let menu = NSMenu()
        if index > 0, timeline.onPreviewJoin != nil {
            let item = menu.addItem(withTitle: "Preview Join Before Clip", action: #selector(previewJoin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = clip.clip.id
        }
        let labels = timeline.audioTrackLabels?(clip.clip.sourceID) ?? []
        guard !labels.isEmpty else { return menu.items.isEmpty ? super.menu(for: event) : menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for (ordinal, label) in labels.enumerated() {
            let item = menu.addItem(withTitle: "Monitor " + label, action: #selector(monitorTrack(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ordinal
            item.toolTip = "Monitor this audio track"
            item.representedObject = clip.clip.id
        }
        menu.addItem(.separator())
        let replace = menu.addItem(withTitle: "Replace Source Audio…", action: #selector(replaceTrack(_:)), keyEquivalent: "")
        replace.target = self
        replace.toolTip = "Replace selected clip audio"
        replace.representedObject = clip.clip.id
        return menu
    }

    @objc private func previewJoin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        timeline?.onPreviewJoin?(id)
    }

    @objc private func monitorTrack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        timeline?.onMonitorAudio?(sender.tag, id)
    }

    @objc private func replaceTrack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        timeline?.onReplaceAudio?(id)
    }

    private enum PointerTarget {
        case range
        case playhead
        case seek(selecting: UUID?)
        case clip(UUID)
        case trim(Int, TimelineEdge)
    }

    private func pointerTarget(at point: NSPoint, in timeline: SequenceTimeline) -> PointerTarget {
        if timeline.onRangeSelect != nil { return .range }
        let hitsPlayhead = abs(point.x - x(at: timeline.playhead)) <= 10 && (14...36).contains(point.y)

        let inWaveform = waveformHeight > 0 && (waveformTop..<(waveformTop + waveformHeight)).contains(point.y)
        guard timeline.allowsClipEdits, !inWaveform, (laneTop..<(laneTop + laneHeight)).contains(point.y) else {
            return hitsPlayhead ? .playhead : .seek(selecting: nil)
        }

        // Let the first and last handles be grabbed from the empty timeline margin.
        let index = min(positions.count - 1, firstClipIndex { stripX(at: $0.stripEnd) > point.x })
        if let selectedPositionIndex {
            let selected = position(at: selectedPositionIndex)
            if let edge = trimEdge(at: point, for: selected) { return .trim(selectedPositionIndex, edge) }
        }
        let position = position(at: index)
        if let edge = trimEdge(at: point, for: position) { return .trim(index, edge) }
        if hitsPlayhead { return .playhead }
        guard !position.clip.isGap, clipRect(position).contains(point) else { return .seek(selecting: nil) }
        let id = position.clip.id
        if position.clip.isAudioOnly && point.y >= laneTop + 21 { return .seek(selecting: id) }
        return .clip(id)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditingEnabled, let timeline, !positions.isEmpty else { return }
        if interaction != nil || isExternalDrag { clearInteraction() }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        switch pointerTarget(at: point, in: timeline) {
        case .range:
            interaction = .range(anchor: rangeTime(at: point.x), downX: point.x)
        case .playhead:
            interaction = .seek(grabOffset: point.x - x(at: timeline.playhead))
            lastSeekTarget = timeline.playhead
            (timeline.onPointerSeek ?? timeline.onSeek)(timeline.playhead)
        case .seek(let id):
            if let id { timeline.onSelect(id) }
            interaction = .seek(grabOffset: 0)
            seek(to: point.x)
        case .clip(let id):
            timeline.onSelect(id)
            interaction = .clip(id, event.locationInWindow)
        case .trim(let index, let edge):
            let position = position(at: index)
            let sourceTime = edge == .start ? position.sourceStart : position.sourceEnd
            interaction = .trim(position.clip.id, edge, sourceTime, point.x, scale)
            trimClipIndex = index
            timeline.onSelect(position.clip.id)
        }
    }

    private func trimEdge(at point: NSPoint, for position: PositionedClip) -> TimelineEdge? {
        guard !position.clip.isStill, !position.clip.isGap else { return nil }
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
        let trimmed = edge == .start ? position.sourceStart - position.displayFrom : position.displayTo - position.sourceEnd
        let outside: CGFloat = isOuter || (rect.width < 18 && position.clip.id == timeline?.selection)
            ? 8 : min(8, max(0, trimmed) * scale)
        return NSRect(x: edge == .start ? rect.minX - outside : rect.maxX - inside,
                      y: rect.minY, width: inside + outside, height: waveformHeight > 0 ? waveformTop - rect.minY : rect.height)
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
        case let .range(anchor, downX):
            guard previewRange != nil || abs(point.x - downX) > 3 else { return }
            let endpoint = rangeTime(at: point.x)
            let range = min(anchor, endpoint)...max(anchor, endpoint)
            guard range != previewRange else { return }
            previewRange = range
            updateTimelineOverlay()
            return
        case let .seek(grabOffset):
            seek(to: point.x - grabOffset, scrubbing: true)
            if !(enclosingScrollView is TimelineScrollView) { needsDisplay = true }
        case .clip:
            break
        case .reorder:
            setDragMarkers(insertionIndex: insertionSlot(at: point.x))
        case let .trim(id, edge, initialTime, downX, initialScale):
            // A click near an edge must not trim. One point can span seconds of a long clip.
            guard lastTrimTarget != nil || abs(point.x - downX) > 3 else { return }
            guard let trimClipIndex else { return }
            let clip = positions[trimClipIndex].clip
            let sourceTime = min(clip.sourceDuration, max(0, initialTime + Double((point.x - downX) / initialScale)))
            guard sourceTime != lastTrimTarget else { return }
            lastTrimTarget = sourceTime
            if let validate = timeline.validateHandle {
                validate(id, edge, sourceTime, false) { [weak self] effective in
                    guard let self, case .trim(id, edge, _, _, _) = self.interaction,
                          self.lastTrimTarget == sourceTime else { return }
                    self.showHandle(edge: edge, at: effective)
                }
            } else {
                showHandle(edge: edge, at: timeline.onTrim(id, edge, sourceTime, false))
            }
        }
    }

    private func showHandle(edge: TimelineEdge, at time: Double?) {
        guard time != trimPosition?.time else { return }
        trimPosition = time.map { TrimPosition(edge: edge, time: $0) }
        if time == nil { timeline?.onCancelTrim() }
        updateTrimGeometry()
        updateTimelineOverlay()
        (enclosingScrollView as? TimelineScrollView)?.resizeDocument()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let timeline, let interaction else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isEditingEnabled, dragLocation != nil {
            switch interaction {
            case .range, .seek, .reorder, .trim:
                updateInternalDrag(at: event.locationInWindow)
            case .clip:
                break
            }
        }
        let wasTrimming = trimPosition != nil
        let selectedRange = previewRange
        let trimTarget = lastTrimTarget
        clearInteraction()
        guard isEditingEnabled else {
            if wasTrimming { timeline.onCancelTrim() }
            return
        }
        switch interaction {
        case let .range(anchor, _):
            if let selectedRange, selectedRange.lowerBound < selectedRange.upperBound {
                timeline.onRangeSelect?(selectedRange.lowerBound, selectedRange.upperBound)
            } else {
                timeline.onRangeSelect?(anchor, anchor)
                (timeline.onPointerSeek ?? timeline.onSeek)(anchor)
            }
        case .seek:
            break
        case .clip:
            seek(to: point.x)
        case let .reorder(id):
            timeline.onMove(id, insertionSlot(at: point.x))
        case let .trim(id, edge, _, _, _):
            if let trimTarget {
                if let validate = timeline.validateHandle {
                    validate(id, edge, trimTarget, true) { if $0 == nil { timeline.onCancelTrim() } }
                } else if timeline.onTrim(id, edge, trimTarget, true) == nil {
                    timeline.onCancelTrim()
                }
            } else {
                seek(to: point.x)
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
        let wasSelectingRange: Bool
        if case .range = interaction { wasSelectingRange = true }
        else { wasSelectingRange = false }
        if case .seek = interaction { timeline?.onEndScrub() }
        interaction = nil
        previewRange = nil
        lastTrimTarget = nil
        lastSeekTarget = nil
        let wasTrimming = trimPosition != nil
        trimPosition = nil
        trimClipIndex = nil
        if wasTrimming { updateTrimGeometry() }
        csvDrag = false
        stillDrag = false
        classifiedDropFiles = nil
        setDragMarkers()
        endEdgeScroll()
        if wasTrimming {
            updateTimelineOverlay()
            (enclosingScrollView as? TimelineScrollView)?.resizeDocument()
        }
        if wasSelectingRange { updateTimelineOverlay() }
        if wasTrimming || !(enclosingScrollView is TimelineScrollView) { needsDisplay = true }
    }

    private func pointerTime(at x: CGFloat, seeking: Bool = false) -> Double {
        let raw = sequenceTime(at: x)
        guard let timeline else { return raw }
        let tolerance = seeking && timeline.snapTarget.wrappedValue == .keyframes ? .infinity : 8 / scale
        return timeline.pointerTarget?(raw, tolerance) ?? raw
    }

    private func rangeTime(at x: CGFloat) -> Double {
        min(sequenceDuration, max(0, pointerTime(at: x)))
    }

    private func seek(to x: CGFloat, scrubbing: Bool = false) {
        guard let timeline else { return }
        let target = pointerTime(at: x, seeking: true)
        guard target != lastSeekTarget else { return }
        lastSeekTarget = target
        if scrubbing, let onScrub = timeline.onScrub { onScrub(target) }
        else { (timeline.onPointerSeek ?? timeline.onSeek)(target) }
    }

    private func insertionSlot(at x: CGFloat) -> Int {
        let time = stripTime(at: x)
        return firstClipIndex { ($0.stripStart + $0.stripEnd) / 2 > time }
    }

    private func firstClipIndex(where pastTarget: (PositionedClip) -> Bool) -> Int {
        var low = 0
        var high = positions.count
        while low < high {
            let middle = (low + high) / 2
            if pastTarget(position(at: middle)) {
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

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.pasteboardItems?.compactMap { item in
            item.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        } ?? []
    }

    private func clipIndex(at point: NSPoint) -> Int? {
        let index = firstClipIndex { stripX(at: $0.stripEnd) > point.x }
        guard positions.indices.contains(index), !positions[index].clip.isGap,
              clipRect(position(at: index)).contains(point) else { return nil }
        return index
    }

    private func updateDropMarker(at point: NSPoint) {
        if csvDrag {
            setDragMarkers(csvTarget: clipIndex(at: point))
        } else if stillDrag {
            setDragMarkers(stillDropTime: NSEvent.modifierFlags.contains(.option) ? nil : sequenceTime(at: point.x))
        } else {
            setDragMarkers(insertionIndex: insertionSlot(at: point.x))
        }
    }

    /// True when the timeline can take media now. Project files are routed whether or not it can.
    private var acceptsMedia: Bool { isEditingEnabled && timeline?.allowsClipEdits == true && interaction == nil }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard timeline?.allowsFileDrops == true, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) else {
            endExternalDrop()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let urls = droppedFiles(sender)
        guard acceptsMedia else {
            // A busy editor still opens a dropped project, as the viewer does. It shows no insertion point.
            endExternalDrop()
            return timeline?.onDropProjects != nil && urls.contains(where: ProjectSessions.isDroppedProject) ? .copy : []
        }
        if classifiedDropFiles?.all != urls {
            let media = timeline?.onDropProjects == nil ? urls : urls.filter { !ProjectSessions.isDroppedProject($0) }
            classifiedDropFiles = (urls, media)
            stillDrag = timeline?.onDropStills != nil && !media.isEmpty && media.allSatisfy(StillPanels.isSupportedImage)
        }
        let media = classifiedDropFiles?.media ?? []
        let routesProjects = media.count < urls.count
        let containsCSV = media.contains { $0.pathExtension.lowercased() == "csv" }
        guard !media.isEmpty, !containsCSV || (media.count == 1 && timeline?.onClipCSV != nil) else {
            endExternalDrop()
            return routesProjects ? .copy : []
        }
        startEdgeScroll(at: sender.draggingLocation, external: true)
        csvDrag = containsCSV
        updateDropMarker(at: point)
        return csvDrag && csvTarget == nil && !routesProjects ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        let point = convert(sender.draggingLocation, from: nil)
        let isCopy = sender.draggingSourceOperationMask.contains(.copy)
        endExternalDrop()
        guard isCopy else { return false }
        return dropFiles(urls, at: point, replacingMarkedRange: NSEvent.modifierFlags.contains(.option))
    }

    func dropFiles(_ dropped: [URL], at point: NSPoint, replacingMarkedRange: Bool = false) -> Bool {
        guard let timeline, timeline.allowsFileDrops, !dropped.isEmpty else { return false }
        // Projects are routed first, as the viewer's drop does, so a busy editor does not refuse them.
        var urls = dropped
        if let route = timeline.onDropProjects, dropped.contains(where: ProjectSessions.isDroppedProject) {
            urls = route(dropped)
        }
        let routed = urls.count < dropped.count
        guard acceptsMedia, !urls.isEmpty else { return routed }
        if let csv = urls.first(where: { $0.pathExtension.lowercased() == "csv" }) {
            guard urls.count == 1, let onClipCSV = timeline.onClipCSV, let index = clipIndex(at: point) else { return routed }
            onClipCSV(csv, positions[index].clip.id)
            return true
        }
        if urls.allSatisfy(StillPanels.isSupportedImage), let onDropStills = timeline.onDropStills {
            onDropStills(urls, sequenceTime(at: point.x), replacingMarkedRange)
        } else {
            timeline.onDrop(urls, insertionSlot(at: point.x))
        }
        return true
    }

    private func endExternalDrop() {
        classifiedDropFiles = nil
        guard isExternalDrag else { return }
        endEdgeScroll()
        csvDrag = false
        stillDrag = false
        setDragMarkers()
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
            updateDropMarker(at: convert(dragLocation, from: nil))
        } else {
            updateInternalDrag(at: dragLocation)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            timeline?.envelopeStore?.setVisibleTimelineSurfaces([])
            if trimPosition != nil { timeline?.onCancelTrim() }
            clearInteraction()
            filmstripViewport = nil
            thumbnailRequests = []
            thumbnailTask?.cancel()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
