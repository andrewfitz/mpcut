import AppKit
import MPCutCore
import SwiftUI

@MainActor
enum WaveformDrawing {
    /// A connected outline of signed peaks. Sample once per visible backing pixel,
    /// or once per source bin when the display is finer than the available data.
    static func timelinePath(in area: CGRect, sourceStart: Double, pointsPerSecond: CGFloat,
                             displayScale: CGFloat, detail: DisplayEnvelope?, coarse: AudioWaveform?) -> CGPath {
        let path = CGMutablePath()
        guard area.width > 0, area.height > 0, detail != nil || coarse != nil else { return path }
        let pixel = 1 / displayScale
        let bin = detail?.secondsPerBin ?? 1 / Double(AudioWaveform.rate)
        let step = max(detail == nil ? 1 : pixel, bin * pointsPerSecond)
        let amplitude = max(0, area.height / 2 - 2)
        func y(_ value: Float) -> CGFloat {
            let level = sqrt(min(1, CGFloat(abs(value))))
            return area.midY - (value < 0 ? -level : level) * amplitude
        }
        var lower: [CGPoint] = []
        var lastTop = area.midY
        func close(at x: CGFloat) {
            guard let last = lower.last else { return }
            path.addLine(to: CGPoint(x: x, y: lastTop))
            path.addLine(to: CGPoint(x: x, y: last.y))
            for point in lower.reversed() { path.addLine(to: point) }
            path.closeSubpath()
            lower.removeAll(keepingCapacity: true)
        }
        var left = area.minX
        while left < area.maxX {
            let right = min(area.maxX, left + step)
            let from = sourceStart + (left - area.minX) / pointsPerSecond
            let to = sourceStart + (right - area.minX) / pointsPerSecond
            let levels = detail?.range(from: from, to: to) ?? coarse?.peak(from: from, to: to).map { (-$0, $0) }
            if let (low, high) = levels {
                let top = y(high) - pixel / 2, bottom = y(low) + pixel / 2
                if lower.isEmpty {
                    path.move(to: CGPoint(x: left, y: top))
                    lower.append(CGPoint(x: left, y: bottom))
                }
                let middle = (left + right) / 2
                path.addLine(to: CGPoint(x: middle, y: top))
                lower.append(CGPoint(x: middle, y: bottom))
                lastTop = top
            } else {
                close(at: left)
            }
            left = right
        }
        close(at: area.maxX)
        return path
    }

    static func sparsePath(_ waveform: SparseWaveform, in area: CGRect, sourceStart: Double,
                           pointsPerSecond: CGFloat) -> CGPath {
        let end = sourceStart + area.width / pointsPerSecond
        let step = (waveform.range.upperBound - waveform.range.lowerBound) / Double(waveform.peaks.count)
        let path = CGMutablePath()
        for (index, peak) in waveform.peaks.enumerated() {
            guard let peak else { continue }
            let start = waveform.range.lowerBound + Double(index) * step
            let left = max(sourceStart, start), right = min(end, start + step)
            guard left < right else { continue }
            let amplitude = max(0.5, sqrt(min(1, CGFloat(peak))) * (area.height / 2 - 2))
            path.addRect(CGRect(x: area.minX + (left - sourceStart) * pointsPerSecond,
                                y: area.midY - amplitude, width: (right - left) * pointsPerSecond,
                                height: amplitude * 2))
        }
        return path
    }

    /// Draw one column per backing pixel. The signed envelope preserves transients and DC offset.
    static func draw(in rect: CGRect, visible: CGRect, seconds: Range<Double>, scale: CGFloat,
                     detail: DisplayEnvelope?, coarse: AudioWaveform?, pauses: [AudioSpan], color: NSColor) {
        let area = rect.intersection(visible)
        guard area.width > 0, area.height > 0, seconds.upperBound > seconds.lowerBound else { return }
        let units = (seconds.upperBound - seconds.lowerBound) / rect.width
        func time(_ x: CGFloat) -> Double { seconds.lowerBound + (x - rect.minX) * units }
        func x(_ t: Double) -> CGFloat { rect.minX + (t - seconds.lowerBound) / units }
        for pause in pauses[pauses.lowerBound { $0.to.seconds > time(area.minX) }...] {
            if pause.from.seconds >= time(area.maxX) { break }
            let l = max(area.minX, x(pause.from.seconds)), r = min(area.maxX, x(pause.to.seconds))
            NSColor.systemTeal.withAlphaComponent(0.15).setFill()
            CGRect(x: l, y: rect.minY, width: max(0, r - l), height: rect.height).fill()
        }
        let pixel = 1 / max(scale, 1)
        let amp = rect.height * 0.465
        let line = CGMutablePath()
        var left = area.minX
        var previous: (bottom: CGFloat, top: CGFloat)?
        while left < area.maxX {
            let right = min(left + pixel, area.maxX)
            let from = time(left), to = time(right)
            let levels = detail?.range(from: from, to: to) ?? coarse?.peak(from: from, to: to).map { (-$0, $0) }
            if let (low, high) = levels {
                let top = rect.midY - CGFloat(min(1, max(-1, high))) * amp
                let bottom = rect.midY - CGFloat(min(1, max(-1, low))) * amp
                let center = (left + right) / 2
                line.move(to: CGPoint(x: center, y: min(top, previous?.bottom ?? top)))
                line.addLine(to: CGPoint(x: center, y: max(top + pixel, bottom, previous?.top ?? bottom)))
                previous = (bottom, top)
            } else { previous = nil }
            left = right
        }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.clip(to: area)
        cg.setShouldAntialias(false)
        cg.setLineWidth(pixel)
        cg.setStrokeColor(color.cgColor)
        cg.addPath(line)
        cg.strokePath()
        cg.restoreGState()
    }
}

enum AudioViewerSpan: String, CaseIterable {
    case timeline = "Timeline zoom", whole = "Whole clip", seconds10 = "10 s", second = "1 s"
    case ms100 = "100 ms", ms10 = "10 ms"

    func range(from: Double, to: Double, at time: Double, zoom: Double) -> Range<Double> {
        let start = min(from, time), end = max(to, time)
        let duration = end - start
        guard duration > 0 else { return start..<start }
        let requested: Double
        switch self {
        case .timeline: requested = duration / pow(2, zoom)
        case .whole: requested = duration
        case .seconds10: requested = 10
        case .second: requested = 1
        case .ms100: requested = 0.1
        case .ms10: requested = 0.01
        }
        let span = min(duration, requested)
        let page = floor((time - start) / span)
        let left = max(start, min(end - span, start + page * span))
        return left..<min(end, left + span)
    }
}

struct AudioWaveformViewer: NSViewRepresentable {
    let clip: TimelineClip
    let offset: Double
    var sourceTime: Double
    let zoom: Double
    var span: AudioViewerSpan = .timeline
    var revision: Int
    let store: AudioEnvelopeStore
    let coarse: AudioWaveform?
    let pauses: [AudioSpan]
    let markIn: Double?
    let markOut: Double?
    let enabled: Bool
    var pointerTarget: ((Double, Double) -> Double)? = nil
    var onPointerSeek: ((Double) -> Void)? = nil
    let seek: (Double) -> Void
    let scrub: (Double) -> Void
    let endScrub: () -> Void

    func makeNSView(context: Context) -> AudioWaveformCanvas {
        let canvas = AudioWaveformCanvas()
        canvas.toolTip = "Scrub the waveform"
        return canvas
    }
    func updateNSView(_ view: AudioWaveformCanvas, context: Context) { view.set(self) }
}

@MainActor
final class AudioWaveformCanvas: NSView {
    private var model: AudioWaveformViewer?
    private var displayed = 0.0..<1.0
    private struct ScrubGesture {
        let clip: TimelineClip
        let offset: Double
        let range: Range<Double>
        let end: () -> Void
    }
    private var gesture: ScrubGesture?
    /// The clip that became active while a drag still belongs to the previous one.
    private var deferred: AudioWaveformViewer?
    private let cursor = CALayer()
    private let sampleLabel = CATextLayer()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cursor.backgroundColor = NSColor.systemRed.cgColor
        cursor.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(cursor)
        sampleLabel.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "string": NSNull()]
        sampleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sampleLabel.fontSize = 11
        sampleLabel.alignmentMode = .right
        sampleLabel.foregroundColor = NSColor(white: 0.76, alpha: 1).cgColor
        layer?.addSublayer(sampleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Audio waveform preview")
    }
    required init?(coder: NSCoder) { nil }

    private var plot: NSRect {
        NSRect(x: 44, y: 40, width: max(1, bounds.width - 64), height: max(1, bounds.height - 75))
    }

    func set(_ data: AudioWaveformViewer) {
        var data = data
        deferred = nil
        if let gesture, gesture.clip.id != data.clip.id, var held = model, held.clip.id == gesture.clip.id {
            // Reaching the join activates the next clip. The drag keeps its own page until release.
            deferred = data
            held.sourceTime = gesture.clip.sourceEnd
            held.revision = data.revision
            data = held
        }
        let old = model, oldRange = displayed
        model = data
        updateDisplayedRange(data)
        guard !displayed.isEmpty else { return }
        if old?.clip.id != data.clip.id || old?.clip.sourceID != data.clip.sourceID || old?.revision != data.revision ||
            oldRange != displayed || old?.offset != data.offset || old?.markIn != data.markIn || old?.markOut != data.markOut {
            needsDisplay = true
        }
        updateCursor()
        if data.clip.audioSampleRate > 0 {
            let sample = Int64((data.sourceTime * Double(data.clip.audioSampleRate)).rounded())
            sampleLabel.string = "Sample " + sample.formatted() + "  ·  " + data.clip.audioSampleRate.formatted() + " Hz"
        } else { sampleLabel.string = nil }
        setAccessibilityValue(timelineTime(data.sourceTime, milliseconds: true))
        setAccessibilityHelp("Seek or drag to scrub \(data.clip.name)")
    }

    private func updateDisplayedRange(_ data: AudioWaveformViewer) {
        if let gesture, gesture.clip.id == data.clip.id {
            displayed = gesture.range
        } else {
            displayed = data.span.range(from: data.clip.sourceStart, to: data.clip.sourceEnd,
                                        at: data.sourceTime, zoom: data.zoom)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = frame.size != newSize
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        sampleLabel.contentsScale = window?.backingScaleFactor ?? 2
        sampleLabel.frame = NSRect(x: plot.maxX - 250, y: 15, width: 250, height: 16)
        updateCursor()
    }
    private func updateCursor() {
        guard let data = model, displayed.upperBound > displayed.lowerBound else { return }
        let fraction = min(1, max(0, (data.sourceTime - displayed.lowerBound) / (displayed.upperBound - displayed.lowerBound)))
        cursor.frame = NSRect(x: plot.minX + plot.width * fraction, y: plot.minY, width: 1.5, height: plot.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.065, alpha: 1).setFill()
        dirtyRect.fill()
        guard let data = model else { return }
        let area = plot, backing = window?.backingScaleFactor ?? 2
        let span = displayed.upperBound - displayed.lowerBound
        guard span > 0 else { return }
        let textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        let type = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func text(_ value: String, x: CGFloat, y: CGFloat) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: type, .foregroundColor: textColor])
        }
        (data.clip.name as NSString).draw(in: NSRect(x: area.minX, y: 15, width: max(40, area.width - (data.clip.audioSampleRate > 0 ? 258 : 0)), height: 20),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                          .foregroundColor: NSColor.white])
        for (level, label) in [(1.0, "+1"), (0.0, "0"), (-1.0, "−1")] {
            let y = area.midY - area.height * 0.465 * level
            text(label, x: 15, y: y - 7)
            NSColor.white.withAlphaComponent(level == 0 ? 0.24 : 0.10).setFill()
            NSRect(x: area.minX, y: y, width: area.width, height: 1 / backing).fill()
        }
        func x(_ source: Double) -> CGFloat { area.minX + (source - displayed.lowerBound) * area.width / span }
        let detail = data.store.envelope(for: data.clip.sourceID, surface: .viewer,
                                         from: displayed.lowerBound, to: displayed.upperBound,
                                         pixels: Int(ceil(area.width * backing)))
        WaveformDrawing.draw(in: area, visible: dirtyRect, seconds: displayed, scale: backing,
                             detail: detail, coarse: data.coarse, pauses: data.pauses, color: .systemTeal)
        func sourceTime(_ sequence: Double) -> Double { data.clip.sourceStart + (sequence - data.offset) }
        if let a = data.markIn, let b = data.markOut {
            let l = max(area.minX, x(sourceTime(min(a, b)))), r = min(area.maxX, x(sourceTime(max(a, b))))
            if r > l {
                NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
                NSRect(x: l, y: area.minY, width: r - l, height: area.height).fill()
            }
        }
        for (mark, label) in [(data.markIn, "I"), (data.markOut, "O")] {
            if let mark {
                let at = x(sourceTime(mark))
                if (area.minX...area.maxX).contains(at) {
                    NSColor.controlAccentColor.setFill()
                    NSRect(x: at, y: area.minY, width: 1, height: area.height).fill()
                    text(label, x: min(area.maxX - 9, at + 3), y: area.minY)
                }
            }
        }
        let start = timelineTime(displayed.lowerBound, milliseconds: true)
        let end = timelineTime(displayed.upperBound, milliseconds: true)
        text(start, x: area.minX, y: area.maxY + 7)
        text(end, x: area.maxX - (end as NSString).size(withAttributes: [.font: type]).width, y: area.maxY + 7)
    }

    private func target(_ event: NSEvent, in gesture: ScrubGesture) -> Double {
        let fraction = min(1, max(0, (convert(event.locationInWindow, from: nil).x - plot.minX) / plot.width))
        let range = gesture.range
        let source = min(gesture.clip.sourceEnd, max(gesture.clip.sourceStart,
                         range.lowerBound + fraction * (range.upperBound - range.lowerBound)))
        let end = gesture.clip.sequenceRange?.upperBound ?? (gesture.offset + gesture.clip.duration)
        let raw = source == gesture.clip.sourceEnd ? end : gesture.offset + (source - gesture.clip.sourceStart)
        let snapped = model?.pointerTarget?(raw, 8 * (range.upperBound - range.lowerBound) / max(1, plot.width)) ?? raw
        // At the join the timeline's snap lookup can see the next clip.
        // This gesture stays on the clip whose waveform is shown.
        return (gesture.offset...end).contains(snapped) ? snapped : raw
    }

    override func mouseDown(with event: NSEvent) {
        guard let data = model, data.enabled, !displayed.isEmpty else { return }
        window?.makeFirstResponder(self)
        let gesture = ScrubGesture(clip: data.clip, offset: data.offset, range: displayed, end: data.endScrub)
        self.gesture = gesture
        (data.onPointerSeek ?? data.seek)(target(event, in: gesture))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let data = model, data.enabled, let gesture else { return }
        data.scrub(target(event, in: gesture))
    }
    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        self.gesture = nil
        gesture.end()
        if let deferred {
            set(deferred)
            needsDisplay = true
        } else if let data = model {
            updateDisplayedRange(data)
            updateCursor()
            needsDisplay = true
        }
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1) }
    private func adjust(_ direction: Double) -> Bool {
        guard let data = model, data.enabled else { return false }
        let amount = (displayed.upperBound - displayed.lowerBound) / 100
        let point = min(data.clip.sourceEnd, max(data.clip.sourceStart, data.sourceTime + direction * amount))
        data.seek(data.offset + (point - data.clip.sourceStart))
        return true
    }
}

/// The audition displays the retained sound on both sides of the proposed join.
struct CutWaveformPreview: View {
    let editor: EditorModel
    let ranges: [PreviewRange]
    let playhead: Double

    var body: some View {
        let layout = previewOffsets(ranges)
        GeometryReader { geometry in
            let scale = geometry.size.width / max(layout.duration, 0.000_001)
            ZStack(alignment: .leading) {
                CutEnvelopeSegments(editor: editor, ranges: ranges, revision: editor.waveformRevision)
                    .equatable()
                Rectangle().fill(.red)
                    .frame(width: 1.5)
                    .offset(x: min(geometry.size.width, max(0, playhead * scale)))
            }
        }
    }
}

private struct CutEnvelopeSegments: View, Equatable {
    let editor: EditorModel
    let ranges: [PreviewRange]
    let revision: Int
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.editor === rhs.editor && lhs.ranges == rhs.ranges && lhs.revision == rhs.revision
    }

    var body: some View {
        let layout = previewOffsets(ranges)
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.065)))
            let scale = size.width / max(layout.duration, 0.000_001)
            context.withCGContext { cg in
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                for (index, range) in ranges.enumerated() {
                    guard let id = editor.sourceID(for: range.url) else { continue }
                    let area = CGRect(x: layout.offsets[index] * scale, y: 4,
                                      width: (range.end - range.start) * scale, height: size.height - 8)
                    let detail = editor.audioStore.detail.envelope(for: id, surface: .cutPreview(index),
                                                                   from: range.start, to: range.end,
                                                                   pixels: Int(ceil(area.width * 2)))
                    WaveformDrawing.draw(in: area, visible: area, seconds: range.start..<range.end, scale: 2,
                                         detail: detail, coarse: editor.audioStore.waves[id], pauses: [], color: .systemTeal)
                    if index > 0 {
                        NSColor.white.withAlphaComponent(0.7).setFill()
                        CGRect(x: area.minX, y: 0, width: 1, height: size.height).fill()
                    }
                }
            }
        }
    }
}
