import AppKit
import Combine
import MPCutCore
import SwiftUI

@MainActor
struct MulticamTimeline: View {
    let project: MulticamProject
    let media: [String: MediaInfo]
    let playhead: RationalTime
    var exclusiveEnd = false
    var clock: MulticamTimelineClock? = nil
    let seek: (RationalTime) -> Void
    let take: (String) -> Void
    let moveSwitch: (RationalTime, RationalTime) -> Void
    let deleteSwitch: (RationalTime) -> Void
    let selectSwitch: (RationalTime) -> Void
    var useAnalysisSidecars = true
    let thumbnailService: MulticamThumbnailService
    var selectedSwitch: RationalTime? = nil
    var scrubEnded: () -> Void = {}
    var zoom: Binding<Double> = .constant(0)
    var largeThumbnails: Binding<Bool> = .constant(false)
    var timeEntryRequest = 0
    var analysis: MulticamAnalysisStore? = nil
    var snapTarget: Binding<TimelineSnapTarget> = .constant(.off)
    var jump: ((RationalTime) -> Void)? = nil
    var markIn: RationalTime? = nil
    var markOut: RationalTime? = nil
    var assemblySelection: AudioSpan? = nil
    var selectRange: ((RationalTime, RationalTime) -> Void)? = nil
    var assembly: MulticamAssemblyTimeline? = nil

    @Environment(\.displayScale) private var displayScale
    static let trackWidthPreference = "multicamTimelineTrackWidth"
    @AppStorage(MulticamTimeline.trackWidthPreference) private var savedTrackWidth = 172.0
    @State private var scroll = MulticamScrollPosition()
    @GestureState private var trackResizeDelta: CGFloat = 0
    @State private var hoveringTrackDivider = false
    @State private var scrubbing = false
    @State private var scrollOrigin: CGFloat = 0
    @State private var verticalViewport: Range<CGFloat>?
    @State private var selection: RationalTime?
    @State private var pendingReveal: Double?
    @State private var activeInterval: MulticamInterval?
    @GestureState private var drag: MarkerDrag?

    private struct MarkerDrag {
        let original: RationalTime
        let translation: CGFloat
    }

    private static let rulerHeight: CGFloat = 40
    private static let rulerTickTop: CGFloat = 28
    private static let markerHeight: CGFloat = 26
    private static let audioHeight: CGFloat = 32
    private static let margin: CGFloat = 16
    private static let trackDividerWidth: CGFloat = 9
    private static let offAirShade = Color.black.opacity(0.75)

    private var extent: Double {
        let angleEnds = project.angles.compactMap { angle in
            media[angle.id].map { angle.offset.seconds + $0.duration.seconds }
        }
        return max(0.001, project.range.to.seconds, angleEnds.max() ?? 0)
    }

    private var cameraHeights: [CGFloat] {
        project.angles.map { angle in
            let video = media[angle.id]?.videoStream
            let size = CGSize(width: video?.displayWidth ?? 0, height: video?.displayHeight ?? 0)
            return TimelineFilmstrip.height(displaySize: size, large: largeThumbnails.wrappedValue)
        }
    }

    private var audioHeight: CGFloat { largeThumbnails.wrappedValue ? 64 : Self.audioHeight }

    private var currentPlayhead: RationalTime {
        guard let clock else { return playhead }
        return clock.groupTime(clock.preview.time)
    }

    var body: some View {
        let intervals = analysis?.groupIntervals ?? (try? project.groupIntervals()) ?? []
        let heights = cameraHeights
        let contentHeight = Self.rulerHeight + Self.markerHeight + heights.reduce(0, +) + audioHeight
        let scrollBarHeight = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let viewportHeight = contentHeight + scrollBarHeight
        let idealHeight = Self.rulerHeight + Self.markerHeight + heights.prefix(4).reduce(0, +)
            + (heights.count <= 4 ? audioHeight : 0) + scrollBarHeight + (assembly == nil ? 0 : 70)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MulticamPlayheadReader(clock: clock, fallback: playhead) { head in
                    TimelineTimeControl(playhead: head.seconds, duration: project.range.to.seconds,
                                        durationLabel: "Group duration", request: timeEntryRequest) { time in
                        let target = time == head.seconds ? head : groupTime(at: time)
                        if let target {
                            if let jump {
                                jump(target)
                            } else {
                                seek(target)
                                scrubEnded()
                            }
                            reveal(target.seconds)
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                TimelineMarkReadouts(markIn: assemblySelection?.from.seconds ?? markIn?.seconds,
                                     markOut: assemblySelection?.to.seconds ?? markOut?.seconds)
                SnapTargetPicker(selection: snapTarget)
                    .pickerStyle(.menu)
                    .fixedSize()
                    .controlSize(.small)
                    .help("Snap switch edits to keyframes, scene changes, or the edges of detected silence.")
                    .layoutPriority(1)
                TimelineViewControls(zoom: zoom, largeThumbnails: largeThumbnails)
                    .layoutPriority(1)
            }
            .padding(.horizontal, EditorMetrics.barInset)
            .frame(height: 38)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Divider()

            GeometryReader { panel in
                let storedWidth = Self.trackWidth(savedTrackWidth, available: panel.size.width)
                let labelWidth = Self.trackWidth(storedWidth + trackResizeDelta, available: panel.size.width)
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if let assembly {
                            HStack(spacing: 0) {
                                laneTitle("Assembly", height: 69)
                                    .frame(width: labelWidth + Self.trackDividerWidth)
                                assembly
                            }
                            Divider()
                        }
                        HStack(alignment: .top, spacing: 0) {
                            labels(heights: heights)
                                .frame(width: labelWidth)
                            Color.clear.frame(width: Self.trackDividerWidth)
                            GeometryReader { proxy in
                                let viewport = max(1, proxy.size.width)
                                let width = documentWidth(viewport, zoom: zoom.wrappedValue)
                                let scale = (width - 2 * Self.margin) / extent
                                let visible = visiblePixels(viewport: viewport, width: width)
                                ScrollView(.horizontal) {
                                    lanes(width: width, scale: scale, visible: visible, heights: heights,
                                          panelHeight: panel.size.height, viewport: viewport, intervals: intervals)
                                        .background {
                                            MulticamScrollViewLocator(position: scroll, zoom: zoom, revealTime: { time in
                                                guard (0...extent).contains(time) else { return false }
                                                reveal(time)
                                                return true
                                            }) { origin in
                                                if scrollOrigin != origin { scrollOrigin = origin }
                                                if let pendingReveal { reveal(pendingReveal) }
                                            }
                                        }
                                }
                                .onChange(of: zoom.wrappedValue) { previous, next in
                                    let previousWidth = documentWidth(viewport, zoom: previous)
                                    let previousScale = (previousWidth - 2 * Self.margin) / extent
                                    let origin = scroll.origin ?? scrollOrigin
                                    let head = x(currentPlayhead.seconds, scale: previousScale)
                                    let anchor = timelineZoomAnchor(playheadX: head, visible: origin..<(origin + viewport))
                                    let offset = anchor - origin
                                    let target = x(seconds(at: anchor, scale: previousScale), scale: scale) - offset
                                    scroll.move(to: next == 0 ? 0 : target, viewport: viewport, width: width)
                                }
                            }
                            .frame(height: viewportHeight)
                        }
                        .background {
                            MulticamScrollViewLocator { viewport in
                                let vertical = viewport.minY..<viewport.maxY
                                if verticalViewport != vertical { verticalViewport = vertical }
                            }
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    trackWidthDivider(width: labelWidth, available: panel.size.width)
                        .offset(x: labelWidth)
                }
            }
            .frame(minHeight: 0, idealHeight: idealHeight, maxHeight: .infinity)
            .clipped()
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
        }
        .onReceive(activeIntervals(in: intervals)) { current in
            if activeInterval != current { activeInterval = current }
        }
        .onChange(of: selectedSwitch, initial: true) { _, time in
            selection = time
            if let time { reveal(time.seconds) }
        }
    }

    static func trackWidth(_ desired: CGFloat, available: CGFloat) -> CGFloat {
        let minimum: CGFloat = 106
        let maximum = max(minimum, min(360, available * 0.48, available - 150 - trackDividerWidth))
        return min(maximum, max(minimum, desired.isFinite ? desired : 172))
    }

    private func trackWidthDivider(width: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.trackDividerWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(hoveringTrackDivider || trackResizeDelta != 0 ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveringTrackDivider = hovering
                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($trackResizeDelta) { value, delta, _ in delta = value.translation.width }
                .onEnded { value in
                    let start = Self.trackWidth(savedTrackWidth, available: available)
                    savedTrackWidth = Self.trackWidth(start + value.translation.width, available: available)
                })
            .help("Drag to resize the track name column")
            .accessibilityLabel("Track name column width")
            .accessibilityValue("\(Int(width.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: savedTrackWidth = Self.trackWidth(width + 16, available: available)
                case .decrement: savedTrackWidth = Self.trackWidth(width - 16, available: available)
                @unknown default: break
                }
            }
    }

    private func documentWidth(_ viewport: CGFloat, zoom: Double) -> CGFloat {
        max(2 * Self.margin + 1, viewport * pow(2, zoom))
    }

    private func reveal(_ time: Double) {
        guard let viewport = scroll.viewport, viewport > 0 else {
            pendingReveal = time
            return
        }
        pendingReveal = nil
        let width = documentWidth(viewport, zoom: zoom.wrappedValue)
        scroll.reveal(x(time, scale: (width - 2 * Self.margin) / extent), viewport: viewport, width: width)
    }

    private func labels(heights: [CGFloat]) -> some View {
        VStack(spacing: 0) {
            laneTitle("Group time", height: Self.rulerHeight)
            laneTitle("Switches", height: Self.markerHeight)
            ForEach(Array(project.angles.enumerated()), id: \.element.id) { index, angle in
                HStack(spacing: 5) {
                    Text(sourceName(angle))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(sourceName(angle))
                    Spacer(minLength: 2)
                    Button { take(angle.id) } label: {
                        Text(index < 9 ? "Take \(index + 1)" : "Take")
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .accessibilityLabel("Take \(sourceName(angle))")
                    .help("Switch to \(sourceName(angle)) at the playhead")
                }
                .padding(.horizontal, 7)
                .frame(height: heights[index])
                .overlay(alignment: .bottom) { Divider() }
            }
            laneTitle("Program audio", height: audioHeight)
        }
        .font(.caption)
    }

    private func laneTitle(_ title: String, height: CGFloat) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .frame(height: height)
            .foregroundStyle(.secondary)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func activeIntervals(in intervals: [MulticamInterval]) -> AnyPublisher<MulticamInterval?, Never> {
        guard let clock else { return Empty().eraseToAnyPublisher() }
        return clock.preview.$time.combineLatest(clock.preview.$duration)
            .map { time, duration in
                Self.interval(at: clock.groupTime(time), exclusiveEnd: time == duration, in: intervals)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func interval(at time: RationalTime, exclusiveEnd: Bool,
                                 in intervals: [MulticamInterval]) -> MulticamInterval? {
        let index = intervals.lowerBound { exclusiveEnd ? $0.group.to >= time : $0.group.to > time }
        return intervals.indices.contains(index) ? intervals[index] : nil
    }

    private func lanes(width: CGFloat, scale: CGFloat, visible: Range<CGFloat>, heights: [CGFloat],
                       panelHeight: CGFloat, viewport: CGFloat, intervals: [MulticamInterval]) -> some View {
        let current = clock == nil ? Self.interval(at: playhead, exclusiveEnd: exclusiveEnd, in: intervals) : activeInterval
        let first = intervals.lowerBound { x($0.group.to.seconds, scale: scale) > visible.lowerBound }
        let end = intervals.lowerBound { x($0.group.from.seconds, scale: scale) >= visible.upperBound }
        let visibleIntervals = intervals[first..<end]
        return VStack(spacing: 0) {
            ruler(scale: scale, visible: visible)
                .frame(height: Self.rulerHeight)
                .overlay(alignment: .bottom) { Divider() }
                .contentShape(Rectangle())
                .gesture(scrubGesture(scale: scale))
                .accessibilityRepresentation {
                    MulticamPlayheadReader(clock: clock, fallback: playhead) { head in
                        Text("Group time ruler")
                            .accessibilityValue(timelineTime(head.seconds, milliseconds: true))
                            .accessibilityAdjustableAction { direction in
                                let step = timelineRulerStep(scale: scale) / 5
                                switch direction {
                                case .increment: seekAccessibly(head.seconds + step)
                                case .decrement: seekAccessibly(head.seconds - step)
                                @unknown default: break
                                }
                            }
                    }
                }
            markers(width: width, scale: scale, visible: visible)
                .frame(height: Self.markerHeight)
                .overlay(alignment: .bottom) { Divider() }
            ForEach(Array(project.angles.enumerated()), id: \.element.id) { index, angle in
                Group {
                    if cameraRowVisible(index, heights: heights, panelHeight: panelHeight) {
                        cameraLane(angle, height: heights[index], intervals: visibleIntervals, scale: scale, visible: visible)
                            .overlay(alignment: .bottom) { Divider() }
                            .contentShape(Rectangle())
                            .gesture(scrubGesture(scale: scale))
                            .accessibilityLabel("\(sourceName(angle)) filmstrip")
                            .accessibilityValue(cameraStatus(angle, active: current?.angle == angle.id))
                    } else {
                        Color.clear
                    }
                }
                .frame(height: heights[index])
            }
            audioLane(intervals: visibleIntervals, scale: scale, visible: visible)
                .frame(height: audioHeight)
                .contentShape(Rectangle())
                .gesture(scrubGesture(scale: scale))
                .accessibilityLabel("Program audio lane")
                .accessibilityValue(audioStatus(current))
        }
        .frame(width: width)
        .overlay {
            if let selectRange {
                MulticamGroupRangeSurface(markIn: markIn, markOut: markOut, markTop: Self.rulerTickTop,
                                          timeAt: { pointerTime(at: $0, scale: scale) },
                                          positionAt: { x($0.seconds, scale: scale) }, commit: selectRange)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if selectRange == nil, let markIn, let markOut {
                    Rectangle().fill(Color.accentColor.opacity(0.18))
                        .frame(width: abs(markOut.seconds - markIn.seconds) * scale)
                        .offset(x: x(min(markIn, markOut).seconds, scale: scale))
                }
                if selectRange == nil, let markIn {
                    mark(at: x(markIn.seconds, scale: scale), isIn: true, height: geometry.size.height)
                }
                if selectRange == nil, let markOut {
                    mark(at: x(markOut.seconds, scale: scale), isIn: false, height: geometry.size.height)
                }
                MulticamPlayheadReader(clock: clock, fallback: playhead) { head in
                    let position = x(head.seconds, scale: scale)
                    let red = Color(nsColor: .systemRed)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(red)
                            .frame(width: 1, height: max(0, geometry.size.height - Self.rulerTickTop))
                            .offset(x: position - 0.5, y: Self.rulerTickTop)
                        TimelinePlayheadMarker()
                            .fill(red)
                            .frame(width: 16, height: 18)
                            .scaleEffect(x: 1, y: 0.72, anchor: .top)
                            .offset(x: position - 8)
                    }
                    .onChange(of: head) { previous, current in
                        guard zoom.wrappedValue > 0, !scrubbing, drag == nil, let origin = scroll.origin,
                              (origin...(origin + viewport)).contains(x(previous.seconds, scale: scale)) else { return }
                        scroll.reveal(x(current.seconds, scale: scale), viewport: viewport, width: width)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func mark(at edge: CGFloat, isIn: Bool, height: CGFloat) -> some View {
        let rects = timelineMarkRects(at: edge, isIn: isIn, bottom: height, top: Self.rulerTickTop)
        return ForEach(rects.indices, id: \.self) { index in
            let rect = rects[index]
            Rectangle()
                .fill(.tint)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private func ruler(scale: CGFloat, visible: Range<CGFloat>) -> some View {
        let keys = analysis?.markers(.keyframes, project: project, media: media) ?? []
        return ZStack(alignment: .topLeading) {
            Color.clear
            visibleCanvas(visible) { context, _ in
                let step = timelineRulerStep(scale: scale)
                let minorStep = step / 5
                let first = Int(ceil(max(0, seconds(at: visible.lowerBound, scale: scale)) / minorStep))
                let last = Int(floor(min(extent, seconds(at: visible.upperBound, scale: scale)) / minorStep))
                guard first <= last else { return }

                let keyTicks = boundaryTicks(keys, scale: scale, visible: visible, top: Self.rulerTickTop, bottom: 31)
                context.stroke(keyTicks, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
                var lastLabelEnd = visible.lowerBound - 8
                var ticks = Path()
                for index in first...last {
                    let time = Double(index) * minorStep
                    let position = x(time, scale: scale)
                    let major = index.isMultiple(of: 5)
                    ticks.move(to: CGPoint(x: position, y: major ? 32 : 35))
                    ticks.addLine(to: CGPoint(x: position, y: 38))
                    guard major else { continue }
                    let text = context.resolve(Text(timelineTime(time, milliseconds: step < 1))
                        .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary))
                    let size = text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20))
                    let right = position + 4
                    let left = right + size.width <= visible.upperBound - 4 ? right : position - size.width - 4
                    guard left >= lastLabelEnd + 8, left >= visible.lowerBound + 4 else { continue }
                    context.draw(text, at: CGPoint(x: left, y: 14), anchor: .topLeading)
                    lastLabelEnd = left + size.width
                }
                context.stroke(ticks, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1)
            }
        }
    }

    private func visibleSwitches(scale: CGFloat, visible: Range<CGFloat>) -> [MulticamSwitch] {
        let switches = project.switches
        let first = switches.lowerBound { x($0.at.seconds, scale: scale) >= visible.lowerBound - 12 }
        let end = switches.lowerBound { x($0.at.seconds, scale: scale) > visible.upperBound + 12 }
        var result = Array(switches[first..<end])
        if let dragged = drag?.original {
            let index = switches.lowerBound { $0.at >= dragged }
            if index < switches.count, switches[index].at == dragged, !(first..<end).contains(index) {
                result.append(switches[index])
            }
        }
        return result
    }

    private func markers(width: CGFloat, scale: CGFloat, visible: Range<CGFloat>) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(scrubGesture(scale: scale))
            ForEach(visibleSwitches(scale: scale, visible: visible), id: \.at) { marker in
                let opening = marker.at == project.range.from
                let markerX = x(marker.at.seconds, scale: scale)
                let translation = drag?.original == marker.at ? drag?.translation ?? 0 : 0
                let position = min(width - Self.margin, max(Self.margin, markerX + translation))
                Image(systemName: selection == marker.at ? "diamond.fill" : "diamond")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: Self.markerHeight)
                    .contentShape(Rectangle())
                    .help("\(name(for: marker.angle)) at \(timelineTime(marker.at.seconds, milliseconds: true))")
                    .accessibilityLabel("\(name(for: marker.angle)) switch at \(timelineTime(marker.at.seconds, milliseconds: true))")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { choose(marker.at) }
                    .contextMenu {
                        Button("Select Switch") { choose(marker.at) }
                        if !opening {
                            Button("Delete Switch") { remove(marker.at) }
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($drag) { value, drag, _ in
                            guard !opening, abs(value.translation.width) >= 3 else { return }
                            drag = MarkerDrag(original: marker.at, translation: value.translation.width)
                        }
                        .onEnded { value in
                            guard !opening, abs(value.translation.width) >= 3,
                                  let time = pointerTime(at: markerX + value.translation.width, scale: scale),
                                  time != marker.at else {
                                choose(marker.at)
                                return
                            }
                            choose(marker.at)
                            moveSwitch(marker.at, time)
                        })
                    .offset(x: position - 11)
            }
        }
    }

    private func cameraLane(_ angle: MulticamSource, height: CGFloat, intervals: ArraySlice<MulticamInterval>,
                            scale: CGFloat, visible: Range<CGFloat>) -> some View {
        let mediaInfo = media[angle.id]
        let coverage = mediaInfo.flatMap { videoCoverage(angle, media: $0) }
        let coveragePixels = coverage.map { pixelRange($0.group, scale: scale) }
        let covered = coveragePixels.flatMap { intersection($0, visible) }
        let gaps = covered == nil ? [] : mediaInfo.map { thumbnailService.pictureGaps(in: $0) } ?? []
        let scenes = analysis?.sourceScenes(angle.id) ?? []
        return ZStack(alignment: .topLeading) {
            Color.clear
            if let mediaInfo, let coverage, let coveragePixels, let covered {
                let targetWidth = largeThumbnails.wrappedValue ? TimelineClip.largeTileWidth : TimelineClip.tileWidth
                let layout = TimelineFilmstrip(width: coveragePixels.upperBound - coveragePixels.lowerBound,
                                               targetWidth: targetWidth)
                let tiles = layout.visibleTiles(origin: coveragePixels.lowerBound, visible: covered)
                ForEach(tiles, id: \.self) { index in
                    let tileStart = coveragePixels.lowerBound + CGFloat(index) * layout.tileWidth
                    let times = MulticamFilmstrip.tileTimeRange(index, count: layout.count, coverage: coverage.source)
                    if let sourceTime = MulticamFilmstrip.thumbnailTime(in: mediaInfo, from: times.lowerBound, to: times.upperBound) {
                        let size = CGSize(width: targetWidth * displayScale, height: height * displayScale)
                        MulticamThumbnail(service: thumbnailService, media: mediaInfo, time: sourceTime, size: size,
                                          useAnalysisSidecars: useAnalysisSidecars)
                            .frame(width: layout.tileWidth, height: height)
                            .offset(x: tileStart)
                    }
                }
            }

            visibleCanvas(visible) { context, size in
                let height = size.height
                if let covered {
                    hatch(context, range: visible.lowerBound..<covered.lowerBound, height: height)
                    hatch(context, range: covered.upperBound..<visible.upperBound, height: height)
                } else {
                    hatch(context, range: visible, height: height)
                }

                var dimStart = covered?.lowerBound ?? visible.lowerBound
                for interval in intervals where interval.angle == angle.id {
                    let range = pixelRange(interval.group.from.seconds..<interval.group.to.seconds, scale: scale)
                    guard let selected = intersection(range, visible) else { continue }
                    if let active = covered.flatMap({ intersection(selected, $0) }) {
                        shade(context, range: dimStart..<active.lowerBound, height: height, color: Self.offAirShade)
                        dimStart = active.upperBound
                        line(context, range: active, y: height - 2, color: .accentColor)
                        label(context, "On air", range: active, y: 11, background: .black.opacity(0.8))
                        unavailable(context, range: selected.lowerBound..<active.lowerBound, height: height, text: "No picture")
                        unavailable(context, range: active.upperBound..<selected.upperBound, height: height, text: "No picture")
                    } else {
                        unavailable(context, range: selected, height: height, text: "No picture")
                    }
                }
                if let covered {
                    shade(context, range: dimStart..<covered.upperBound, height: height, color: Self.offAirShade)
                    let offset = angle.offset.seconds
                    let firstGap = gaps.lowerBound { x($0.upperBound + offset, scale: scale) > covered.lowerBound }
                    for gap in gaps.dropFirst(firstGap) {
                        let pixels = pixelRange((gap.lowerBound + offset)..<(gap.upperBound + offset), scale: scale)
                        guard pixels.lowerBound < covered.upperBound else { break }
                        guard let visibleGap = intersection(pixels, covered) else { continue }
                        shade(context, range: visibleGap, height: height, color: .black)
                        hatch(context, range: visibleGap, height: height)
                        let firstInterval = intervals.lowerBound { x($0.group.to.seconds, scale: scale) > visibleGap.lowerBound }
                        for interval in intervals[firstInterval...] {
                            let selected = pixelRange(interval.group.from.seconds..<interval.group.to.seconds, scale: scale)
                            guard selected.lowerBound < visibleGap.upperBound else { break }
                            if interval.angle == angle.id, let overlap = intersection(selected, visibleGap) {
                                unavailable(context, range: overlap, height: height, text: "No picture")
                            }
                        }
                    }
                }
                if let covered {
                    let cuts = boundaryTicks(scenes, offset: angle.offset.seconds, scale: scale,
                                             visible: covered, top: 0, bottom: height - 2)
                    context.stroke(cuts, with: .color(.yellow), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func audioLane(intervals: ArraySlice<MulticamInterval>, scale: CGFloat, visible: Range<CGFloat>) -> some View {
        let tracks: [MulticamAnalysisAudioSpan]
        if let first = intervals.first, let last = intervals.last, let analysis {
            tracks = analysis.soundtrack(in: .init(from: first.group.from, to: last.group.to))
        } else {
            tracks = []
        }
        let pauses = analysis?.routedPauses(project: project, media: media) ?? []
        return ZStack(alignment: .topLeading) {
            Color.clear
            visibleCanvas(visible) { context, size in
                var spans: [(range: Range<Double>, audio: MulticamAudioSelection?)] = []
                for interval in intervals {
                    let range = interval.group.from.seconds..<interval.group.to.seconds
                    if let last = spans.last, last.range.upperBound == range.lowerBound, last.audio == interval.audio {
                        spans[spans.count - 1].range = last.range.lowerBound..<range.upperBound
                    } else {
                        spans.append((range, interval.audio))
                    }
                }
                for span in spans {
                    guard let selected = intersection(pixelRange(span.range, scale: scale), visible) else { continue }
                    guard let audio = span.audio else {
                        let videoOnly = project.audio == .none
                        if !videoOnly { hatch(context, range: selected, height: size.height, warning: true) }
                        label(context, videoOnly ? "Video only" : "Missing audio",
                              range: selected, y: size.height / 2, background: .black.opacity(0.8))
                        continue
                    }
                    let audioRange = audioCoverage(audio).flatMap { intersection(pixelRange($0, scale: scale), selected) }
                    if let audioRange {
                        shade(context, range: audioRange, height: size.height, color: .teal.opacity(0.23))
                        line(context, range: audioRange, y: size.height - 2, color: .teal)
                        let firstPause = pauses.lowerBound { x($0.to.seconds, scale: scale) > audioRange.lowerBound }
                        for pause in pauses.dropFirst(firstPause) {
                            let range = pixelRange(pause.from.seconds..<pause.to.seconds, scale: scale)
                            guard range.lowerBound < audioRange.upperBound else { break }
                            if let overlap = intersection(range, audioRange) {
                                shade(context, range: overlap, height: size.height, color: .teal.opacity(0.35))
                            }
                        }
                        let firstTrack = tracks.lowerBound { x($0.group.to.seconds, scale: scale) > audioRange.lowerBound }
                        for track in tracks.dropFirst(firstTrack) {
                            guard x(track.group.from.seconds, scale: scale) < audioRange.upperBound else { break }
                            drawWaveform(track, context: context, visible: audioRange, scale: scale, height: size.height)
                        }
                        unavailable(context, range: selected.lowerBound..<audioRange.lowerBound, height: size.height, text: "Missing audio")
                        unavailable(context, range: audioRange.upperBound..<selected.upperBound, height: size.height, text: "Missing audio")
                        label(context, "\(name(for: audio.source)) · Stream \(audio.stream)", range: audioRange,
                              y: size.height / 2, background: .black.opacity(0.8))
                    } else {
                        hatch(context, range: selected, height: size.height, warning: true)
                        label(context, "\(name(for: audio.source)) · Unavailable", range: selected,
                              y: size.height / 2, background: .black.opacity(0.8))
                    }
                }
            }
        }
    }

    private func boundaryTicks(_ times: [RationalTime], offset: Double = 0, scale: CGFloat,
                               visible: Range<CGFloat>, top: CGFloat, bottom: CGFloat) -> Path {
        var path = Path()
        var index = times.lowerBound { x($0.seconds + offset, scale: scale) >= visible.lowerBound }
        while index < times.count {
            let position = x(times[index].seconds + offset, scale: scale)
            guard position < visible.upperBound else { break }
            path.move(to: CGPoint(x: position, y: top))
            path.addLine(to: CGPoint(x: position, y: bottom))
            index = max(index + 1, times.lowerBound { x($0.seconds + offset, scale: scale) >= position + 3 })
        }
        return path
    }

    private func drawWaveform(_ track: MulticamAnalysisAudioSpan, context: GraphicsContext, visible: Range<CGFloat>,
                              scale: CGFloat, height: CGFloat) {
        let bounds = pixelRange(track.group.from.seconds..<track.group.to.seconds, scale: scale)
        guard let area = intersection(visible, bounds) else { return }
        let sourceStart = track.input.from.seconds
        let sourceEnd = track.input.to.seconds
        let middle = height / 2
        var peaks = Path()
        var position = area.lowerBound
        while position < area.upperBound {
            let next = min(position + 1.5, area.upperBound)
            let start = sourceStart + (position - bounds.lowerBound) / scale
            let end = min(sourceEnd, sourceStart + (next - bounds.lowerBound) / scale)
            if let peak = track.waveform.peak(from: start, to: end) {
                let halfHeight = max(0.5, min(1, CGFloat(sqrt(peak))) * (middle - 2))
                peaks.move(to: CGPoint(x: position, y: middle - halfHeight))
                peaks.addLine(to: CGPoint(x: position, y: middle + halfHeight))
            }
            position = next
        }
        context.stroke(peaks, with: .color(.teal.opacity(0.9)), lineWidth: 1)
    }

    private func visibleCanvas(_ visible: Range<CGFloat>,
                               renderer: @escaping (GraphicsContext, CGSize) -> Void) -> some View {
        Canvas { context, size in
            var translated = context
            translated.translateBy(x: -visible.lowerBound, y: 0)
            renderer(translated, size)
        }
        .frame(width: visible.upperBound - visible.lowerBound)
        .offset(x: visible.lowerBound)
        .allowsHitTesting(false)
    }

    private func scrubGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let time = pointerTime(at: value.location.x, scale: scale) else { return }
                scrubbing = true
                selection = nil
                seek(time)
            }
            .onEnded { _ in
                scrubbing = false
                scrubEnded()
            }
    }

    private func choose(_ time: RationalTime) {
        selection = time
        selectSwitch(time)
    }

    private func remove(_ time: RationalTime) {
        guard time != project.range.from else { return }
        deleteSwitch(time)
        if selection == time { selection = nil }
    }

    private func seekAccessibly(_ time: Double) {
        guard let target = groupTime(at: time) else { return }
        selection = nil
        seek(target)
        scrubEnded()
        reveal(target.seconds)
    }

    private func pointerTime(at position: CGFloat, scale: CGFloat) -> RationalTime? {
        groupTime(at: seconds(at: position, scale: scale))
    }

    private func groupTime(at seconds: Double) -> RationalTime? {
        if seconds <= project.range.from.seconds { return project.range.from }
        if seconds >= project.range.to.seconds { return project.range.to }
        return timelineRationalTime(seconds)
    }

    private func x(_ time: Double, scale: CGFloat) -> CGFloat { Self.margin + time * scale }

    private func seconds(at position: CGFloat, scale: CGFloat) -> Double {
        (position - Self.margin) / scale
    }

    private func pixelRange(_ range: Range<Double>, scale: CGFloat) -> Range<CGFloat> {
        x(range.lowerBound, scale: scale)..<x(range.upperBound, scale: scale)
    }

    private func cameraRowVisible(_ index: Int, heights: [CGFloat], panelHeight: CGFloat) -> Bool {
        let top = Self.rulerHeight + Self.markerHeight + heights.prefix(index).reduce(0, +)
        let visible = verticalViewport ?? 0..<max(0, panelHeight)
        return top < visible.upperBound && top + heights[index] > visible.lowerBound
    }

    private func visiblePixels(viewport: CGFloat, width: CGFloat) -> Range<CGFloat> {
        let start = max(0, min(width - min(width, viewport), scrollOrigin))
        return start..<min(width, start + viewport)
    }

    private func intersection(_ first: Range<CGFloat>, _ second: Range<CGFloat>) -> Range<CGFloat>? {
        let lower = max(first.lowerBound, second.lowerBound)
        let upper = min(first.upperBound, second.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    private func sourceName(_ source: MulticamSource) -> String {
        source.displayName
    }

    private func name(for id: String) -> String {
        project.sources.first { $0.id == id }.map(sourceName) ?? id
    }

    private func videoCoverage(_ angle: MulticamSource, media: MediaInfo) -> (source: Range<Double>, group: Range<Double>)? {
        guard let coverage = MulticamFilmstrip.pictureCoverage(in: media) else { return nil }
        let offset = angle.offset.seconds
        let sourceStart = max(coverage.lowerBound, -offset)
        let sourceEnd = min(coverage.upperBound, extent - offset)
        let groupStart = max(0, offset + coverage.lowerBound)
        let groupEnd = min(extent, offset + coverage.upperBound)
        guard sourceStart < sourceEnd, groupStart < groupEnd else { return nil }
        return (sourceStart..<sourceEnd, groupStart..<groupEnd)
    }

    private func audioCoverage(_ selection: MulticamAudioSelection) -> Range<Double>? {
        guard let source = project.sources.first(where: { $0.id == selection.source }),
              let track = media[source.id]?.audio.first(where: { $0.stream.index == selection.stream }) else { return nil }
        let start = max(0, source.offset.seconds + max(0, track.start.seconds))
        let end = min(extent, source.offset.seconds + track.end.seconds)
        return start < end ? start..<end : nil
    }

    private func cameraStatus(_ angle: MulticamSource, active: Bool) -> String {
        guard let info = media[angle.id], let local = try? playhead.subtracting(angle.offset),
              MulticamPicturePosition.at(local, source: angle.id, media: info, spanIndex: -1, exclusiveEnd: exclusiveEnd) != nil else {
            return active ? "Selected, no picture" : "No picture"
        }
        return active ? "On air" : "Off air"
    }

    private func audioStatus(_ interval: MulticamInterval?) -> String {
        guard let interval else { return "Outside the group" }
        guard let selection = interval.audio else { return project.audio == .none ? "Video only" : "Missing audio" }
        let label = "\(name(for: selection.source)), stream \(selection.stream)"
        let covered = audioCoverage(selection).map {
            exclusiveEnd ? $0.lowerBound < playhead.seconds && playhead.seconds <= $0.upperBound : $0.contains(playhead.seconds)
        } ?? false
        return covered ? label : "\(label), unavailable"
    }

    private func shade(_ context: GraphicsContext, range: Range<CGFloat>, height: CGFloat, color: Color) {
        context.fill(Path(CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: height)),
                     with: .color(color))
    }

    private func unavailable(_ context: GraphicsContext, range: Range<CGFloat>, height: CGFloat, text: String) {
        hatch(context, range: range, height: height, warning: true)
        label(context, text, range: range, y: height / 2, background: .black.opacity(0.8))
    }

    private func hatch(_ context: GraphicsContext, range: Range<CGFloat>, height: CGFloat, warning: Bool = false) {
        guard !range.isEmpty else { return }
        let bounds = CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: height)
        var clipped = context
        clipped.clip(to: Path(bounds))
        shade(clipped, range: range, height: height, color: warning ? .orange.opacity(0.18) : .secondary.opacity(0.1))
        var marks = Path()
        for start in stride(from: (range.lowerBound / 7).rounded(.down) * 7 - height, to: range.upperBound, by: 7) {
            marks.move(to: CGPoint(x: start, y: height))
            marks.addLine(to: CGPoint(x: start + height, y: 0))
        }
        clipped.stroke(marks, with: .color(warning ? .orange.opacity(0.62) : .secondary.opacity(0.38)), lineWidth: 1)
    }

    private func line(_ context: GraphicsContext, range: Range<CGFloat>, y: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: range.lowerBound, y: y))
        path.addLine(to: CGPoint(x: range.upperBound, y: y))
        context.stroke(path, with: .color(color), lineWidth: 2)
    }

    private func label(_ context: GraphicsContext, _ text: String, range: Range<CGFloat>, y: CGFloat,
                       background: Color) {
        let available = range.upperBound - range.lowerBound - 6
        guard available >= 23 else { return }
        let resolved = context.resolve(Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
        let size = resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 15))
        let rect = CGRect(x: range.lowerBound + 3, y: y - 8, width: min(size.width + 6, available), height: 16)
        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(background))
        context.draw(resolved, in: rect.insetBy(dx: 3, dy: 1))
    }
}

@MainActor
struct MulticamTimelineClock {
    let preview: MulticamPreview
    let groupTime: (RationalTime) -> RationalTime
}

@MainActor
private struct MulticamPlayheadReader<Content: View>: View {
    let clock: MulticamTimelineClock?
    let fallback: RationalTime
    @ViewBuilder let content: (RationalTime) -> Content
    @State private var outputTime: RationalTime?

    var body: some View {
        if let clock {
            content(clock.groupTime(outputTime ?? clock.preview.time))
                .onReceive(clock.preview.$time) { time in
                    if outputTime != time { outputTime = time }
                }
        } else {
            content(fallback)
        }
    }
}

@MainActor
private final class MulticamScrollPosition {
    weak var view: NSScrollView?
    private var request = 0

    var origin: CGFloat? { view?.contentView.bounds.minX }
    var viewport: CGFloat? { view?.contentView.bounds.width }

    func move(to offset: CGFloat, viewport: CGFloat, width: CGFloat) {
        let target = min(max(0, offset), max(0, width - viewport))
        request += 1
        let current = request
        // SwiftUI applies the new document width in the layout pass following a zoom.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.request == current, let view = self.view else { return }
            view.layoutSubtreeIfNeeded()
            let clip = view.contentView
            let point = NSPoint(x: target, y: clip.bounds.minY)
            clip.scroll(to: point)
            view.reflectScrolledClipView(clip)
        }
    }

    func reveal(_ position: CGFloat, viewport: CGFloat, width: CGFloat) {
        guard let origin, position < origin || position > origin + viewport else { return }
        move(to: position - viewport / 2, viewport: viewport, width: width)
    }
}

struct MulticamScrollViewLocator: NSViewRepresentable {
    private let position: MulticamScrollPosition?
    private var zoom: Binding<Double>?
    private let didScroll: (CGRect) -> Void
    private var revealTime: ((Double) -> Bool)?

    fileprivate init(position: MulticamScrollPosition, zoom: Binding<Double>, revealTime: @escaping (Double) -> Bool,
                     didScroll: @escaping (CGFloat) -> Void) {
        self.position = position
        self.zoom = zoom
        self.revealTime = revealTime
        self.didScroll = { didScroll($0.minX) }
    }

    init(didScroll: @escaping (CGRect) -> Void) {
        position = nil
        self.didScroll = didScroll
    }

    func makeNSView(context: Context) -> Locator {
        Locator(position: position, didScroll: didScroll)
    }

    func updateNSView(_ view: Locator, context: Context) {
        view.zoom = zoom
        view.didScroll = didScroll
        view.revealTime = revealTime
    }

    final class Locator: NSView {
        private let position: MulticamScrollPosition?
        var zoom: Binding<Double>?
        var revealTime: ((Double) -> Bool)?
        private var wheelMonitor: Any?
        var didScroll: (CGRect) -> Void
        override var isFlipped: Bool { true }

        fileprivate init(position: MulticamScrollPosition?, didScroll: @escaping (CGRect) -> Void) {
            self.position = position
            self.didScroll = didScroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
            guard window != nil, let scroll = enclosingScrollView else { return }
            scroll.identifier = NSUserInterfaceItemIdentifier(position == nil ? "MPCutGroupTrackScroll" : "MPCutGroupTimeScroll")
            position?.view = scroll
            if position != nil {
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scroll] event in
                    guard let self, let scroll, let zoom = self.zoom,
                          event.window === scroll.window, scroll.window?.attachedSheet == nil,
                          scroll.contentView.visibleRect.contains(scroll.contentView.convert(event.locationInWindow, from: nil))
                    else { return event }
                    switch TimelineWheelAction(event) {
                    case .zoom(let amount):
                        zoom.wrappedValue = TimelineViewControls.adjustedZoom(zoom.wrappedValue, by: amount)
                    case .pan(let delta):
                        let clip = scroll.contentView
                        var bounds = clip.bounds
                        bounds.origin.x += delta
                        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                        scroll.reflectScrolledClipView(clip)
                    case nil: return event
                    }
                    return nil
                }
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification,
                               object: scroll.contentView)
            clipBoundsChanged()
        }

        override func layout() {
            super.layout()
            if position == nil { clipBoundsChanged() }
        }

        @objc private func clipBoundsChanged() {
            // Clip changes can occur while SwiftUI is laying out the document.
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.enclosingScrollView?.contentView else { return }
                let viewport = self.position == nil ? self.convert(clip.bounds, from: clip) : clip.bounds
                self.didScroll(viewport)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct MulticamGroupRangeSurface: NSViewRepresentable {
    let markIn: RationalTime?
    let markOut: RationalTime?
    let markTop: CGFloat
    let timeAt: (CGFloat) -> RationalTime?
    let positionAt: (RationalTime) -> CGFloat
    let commit: (RationalTime, RationalTime) -> Void

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.configuration = self
    }

    final class Surface: NSView {
        var configuration: MulticamGroupRangeSurface? {
            didSet { updateRangeOverlay() }
        }
        private let rangeOverlay = TimelineRangeOverlay()
        private var anchor: RationalTime?
        private var downX: CGFloat = 0
        private var endpoint: RationalTime?
        private var dragLocation: NSPoint?
        private var edgeScrollTimer: Timer?
        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            rangeOverlay.drawRange = { [weak self] visible in self?.drawRange(visible) }
            addSubview(rangeOverlay)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            updateRangeOverlay()
        }

        private func updateRangeOverlay() {
            let hasMarks = endpoint != nil || configuration?.markIn != nil || configuration?.markOut != nil
            rangeOverlay.update(viewport: visibleRect.intersection(bounds), showMarks: hasMarks)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(visibleRect, cursor: .iBeam)
        }

        private func drawRange(_ dirtyRect: NSRect) {
            guard let configuration else { return }
            let markIn: RationalTime?
            let markOut: RationalTime?
            if let anchor, let endpoint {
                markIn = min(anchor, endpoint)
                markOut = max(anchor, endpoint)
            } else {
                markIn = configuration.markIn
                markOut = configuration.markOut
            }
            if let markIn, let markOut {
                let left = configuration.positionAt(min(markIn, markOut))
                let right = configuration.positionAt(max(markIn, markOut))
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSRect(x: left, y: 0, width: right - left, height: bounds.height).intersection(dirtyRect).fill()
            }
            NSColor.controlAccentColor.setFill()
            for (mark, isIn) in [(markIn, true), (markOut, false)] {
                guard let mark else { continue }
                for rect in timelineMarkRects(at: configuration.positionAt(mark), isIn: isIn,
                                              bottom: bounds.height, top: configuration.markTop) {
                    rect.intersection(dirtyRect).fill()
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            endInteraction()
            window?.makeFirstResponder(self)
            downX = convert(event.locationInWindow, from: nil).x
            anchor = configuration?.timeAt(downX)
        }

        override func mouseDragged(with event: NSEvent) {
            guard anchor != nil else { return }
            let location = event.locationInWindow
            updateEndpoint(at: location)
            dragLocation = location
            guard edgeScrollTimer == nil else { return }
            let timer = Timer(timeInterval: 1 / 30, target: self, selector: #selector(scrollDragEdge),
                              userInfo: nil, repeats: true)
            edgeScrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func updateEndpoint(at location: NSPoint) {
            let x = convert(location, from: nil).x
            guard endpoint != nil || abs(x - downX) > 3,
                  let target = configuration?.timeAt(x), target != endpoint else { return }
            endpoint = target
            updateRangeOverlay()
        }

        @objc private func scrollDragEdge() {
            guard let dragLocation, let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            let visible = clip.bounds
            let x = clip.convert(dragLocation, from: nil).x
            let zone = min(24, visible.width / 4)
            var bounds = visible
            if x < visible.minX + zone {
                bounds.origin.x -= 12
            } else if x > visible.maxX - zone {
                bounds.origin.x += 12
            } else {
                return
            }
            let target = clip.constrainBoundsRect(bounds).origin
            guard target.x != visible.minX else { return }
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            updateEndpoint(at: dragLocation)
            updateRangeOverlay()
        }

        override func mouseUp(with event: NSEvent) {
            guard let anchor else { return }
            if dragLocation != nil { updateEndpoint(at: event.locationInWindow) }
            let endpoint = endpoint ?? anchor
            endInteraction()
            configuration?.commit(min(anchor, endpoint), max(anchor, endpoint))
        }

        private func endInteraction() {
            anchor = nil
            let wasDragging = endpoint != nil
            endpoint = nil
            if wasDragging { updateRangeOverlay() }
            dragLocation = nil
            edgeScrollTimer?.invalidate()
            edgeScrollTimer = nil
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endInteraction() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cancelOperation(_ sender: Any?) {
            if anchor != nil { endInteraction() }
            else { super.cancelOperation(sender) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 53, anchor != nil, window?.firstResponder === self {
                endInteraction()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53, anchor != nil { endInteraction() }
            else { super.keyDown(with: event) }
        }
    }
}
