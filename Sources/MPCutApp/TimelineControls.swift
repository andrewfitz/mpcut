import AppKit
import MPCutCore
import SwiftUI

struct TimelineTimeControl: View {
    let playhead: Double
    let duration: Double
    let durationLabel: String
    let request: Int
    let seek: (Double) -> Void

    @State private var editing = false
    @State private var hovering = false
    @State private var input = ""
    @State private var initialTime = 0.0
    @FocusState private var focused: Bool

    private static let font = Font.system(size: 13, design: .monospaced)

    var body: some View {
        HStack(spacing: 0) {
            // The readout and its field share one footprint, so entering a time moves nothing.
            Text(timelineTime(max(playhead, duration), milliseconds: true))
                .font(Self.font.weight(.medium))
                .hidden()
                .accessibilityHidden(true)
                .overlay(alignment: .leading) {
                    if editing {
                        TextField("Timeline position", text: $input)
                            .font(Self.font.weight(.medium))
                            .textFieldStyle(.plain)
                            .focused($focused)
                            .onSubmit {
                                guard let time = Self.parseTime(input, initialTime: initialTime) else {
                                    NSSound.beep()
                                    return
                                }
                                seek(min(max(time, 0), duration))
                                editing = false
                            }
                            .onExitCommand { editing = false }
                            .onChange(of: focused) { _, active in
                                if !active { editing = false }
                            }
                            .onAppear {
                                DispatchQueue.main.async {
                                    if editing { focused = true }
                                }
                            }
                    } else {
                        Button(action: beginEditing) {
                            Text(timelineTime(playhead, milliseconds: true))
                                .font(Self.font.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .help("Go to a timeline time (click, then type a time)")
                        .accessibilityLabel("Timeline position")
                        .accessibilityValue(timelineTime(playhead, milliseconds: true))
                    }
                }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(editing ? 0.10 : hovering ? 0.07 : 0))
                if editing {
                    RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                }
            }
            .onHover { hovering = $0 }
            .padding(.leading, -6)
            Text("/")
                .foregroundStyle(.tertiary)
                .padding(.trailing, 6)
                .accessibilityHidden(true)
            Text(timelineTime(duration, milliseconds: true))
                .font(Self.font)
                .foregroundStyle(.secondary)
                .accessibilityLabel(durationLabel)
                .accessibilityValue(timelineTime(duration, milliseconds: true))
        }
        .onChange(of: request) { _, _ in beginEditing() }
    }

    private func beginEditing() {
        guard !editing else { return }
        initialTime = playhead
        input = timelineTime(playhead, milliseconds: true)
        editing = true
    }

    static func parseTime(_ text: String, initialTime: Double) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input == timelineTime(initialTime, milliseconds: true) { return initialTime }
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

struct TimelineViewControls: View {
    static let maximumZoom = 13.0

    @Binding var zoom: Double
    @Binding var largeThumbnails: Bool
    var audioOnly = false

    var body: some View {
        Button {
            largeThumbnails.toggle()
        } label: {
            Image(systemName: largeThumbnails ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(ToolButtonStyle())
        .accessibilityLabel(sizeLabel)
        .help(sizeLabel)

        HStack(spacing: 2) {
            zoomButton("Zoom Out", symbol: "minus.magnifyingglass", amount: -1)
            Slider(value: $zoom, in: 0...Self.maximumZoom) { Text("Timeline zoom") }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 96)
                .accessibilityValue(zoomDescription)
                .help("Timeline zoom · \(zoomDescription)")
            zoomButton("Zoom In", symbol: "plus.magnifyingglass", amount: 1)
        }

        Button { zoom = 0 } label: {
            Text("Fit")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 24)
        }
            .buttonStyle(ToolButtonStyle())
            .disabled(zoom == 0)
            .accessibilityLabel("Fit Timeline")
            .help("Fit the entire timeline in the window")
    }

    private var sizeLabel: String {
        if audioOnly { return largeThumbnails ? "Use Smaller Waveform" : "Use Larger Waveform" }
        return largeThumbnails ? "Use Small Thumbnails" : "Use Large Thumbnails"
    }

    private var zoomDescription: String {
        pow(2, zoom).formatted(.number.precision(.fractionLength(0...1))) + "×"
    }

    private func zoomButton(_ title: String, symbol: String, amount: Double) -> some View {
        Button {
            zoom = min(Self.maximumZoom, max(0, zoom + amount))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(ToolButtonStyle())
        .disabled(amount > 0 ? zoom >= Self.maximumZoom : zoom <= 0)
        .accessibilityLabel(title)
        .help(title)
    }
}

func timelineRulerStep(scale: CGFloat) -> Double {
    let desired = 86 / scale
    let power = pow(10, floor(log10(desired)))
    let multiple = [1.0, 2, 5, 10].first { $0 >= desired / power } ?? 10
    return max(0.001, multiple * power)
}

struct TimelineFilmstrip {
    let count: Int
    let tileWidth: CGFloat

    init(width: CGFloat, targetWidth: CGFloat) {
        count = max(1, Int((width / targetWidth).rounded()))
        tileWidth = width / CGFloat(count)
    }

    func visibleTiles(origin: CGFloat, visible: Range<CGFloat>) -> Range<Int> {
        let first = min(count, max(0, Int(floor((visible.lowerBound - origin) / tileWidth))))
        let last = min(count, max(first, Int(ceil((visible.upperBound - origin) / tileWidth))))
        return first..<last
    }

    static func height(displaySize: CGSize, large: Bool) -> CGFloat {
        let width = large ? TimelineClip.largeTileWidth : TimelineClip.tileWidth
        let minimum = large ? TimelineClip.minimumLargeThumbnailHeight : TimelineClip.minimumThumbnailHeight
        guard displaySize.width > 0, displaySize.height > 0 else { return minimum }
        return min(large ? 383 : 168, max(minimum, (width * displaySize.height / displaySize.width).rounded()))
    }
}

func timelineZoomAnchor(playheadX: CGFloat, visible: Range<CGFloat>) -> CGFloat {
    if (visible.lowerBound...visible.upperBound).contains(playheadX) { return playheadX }
    return (visible.lowerBound + visible.upperBound) / 2
}

struct TimelineMarkReadouts: View {
    let markIn: Double?
    let markOut: Double?

    var body: some View {
        if markIn != nil || markOut != nil {
            // The readouts yield to the time field and the view controls in a narrow window.
            ViewThatFits(in: .horizontal) {
                readouts(marks: true, duration: true)
                readouts(marks: true, duration: false)
                readouts(marks: false, duration: true)
                EmptyView()
            }
            .layoutPriority(0.5)
        }
    }

    @ViewBuilder private func readouts(marks: Bool, duration: Bool) -> some View {
        let length = markIn.flatMap { start in markOut.flatMap { $0 > start ? $0 - start : nil } }
        if marks || length != nil {
            HStack(spacing: 8) {
                if marks, let markIn { readout("In", time: markIn) }
                if marks, let markOut { readout("Out", time: markOut) }
                if duration, let length { readout("Duration", time: length, title: "Marked duration") }
                Divider().frame(height: 16)
            }
        }
    }

    private func readout(_ name: String, time: Double, title: String? = nil) -> some View {
        let timestamp = timelineTime(time, milliseconds: true)
        return HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(timestamp).font(.system(size: 12, design: .monospaced))
        }
            .font(.callout)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title ?? "Mark \(name) time")
            .accessibilityValue(timestamp)
    }
}

func timelineMarkRects(at edge: CGFloat, isIn: Bool, bottom: CGFloat, top: CGFloat = 23) -> [CGRect] {
    let stemX = isIn ? edge + 1 : edge - 3
    let tabX = isIn ? stemX : stemX - 7
    return [
        CGRect(x: stemX, y: top, width: 2, height: bottom - top),
        CGRect(x: tabX, y: top, width: 9, height: 4),
        CGRect(x: tabX, y: bottom - 3, width: 9, height: 3),
    ]
}

struct TimelinePlayheadMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var marker = Path()
        marker.move(to: CGPoint(x: rect.minX, y: rect.minY))
        marker.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        marker.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 10))
        marker.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        marker.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 10))
        marker.closeSubpath()
        return marker
    }
}


func timelineRationalTime(_ seconds: Double) -> RationalTime? {
    guard let ticks = Int64(exactly: (seconds * 1_000_000_000).rounded()) else { return nil }
    return RationalTime(numerator: ticks, denominator: 1_000_000_000)
}
