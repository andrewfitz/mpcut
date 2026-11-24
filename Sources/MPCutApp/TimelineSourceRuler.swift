import AppKit
import CoreText

/// Coordinates refer to the source clock at the left edge of this occurrence.
struct TimelineSourceRuler {
    static let height: CGFloat = 16
    let source: ClosedRange<Double>
    let pixels: Range<CGFloat>
    let scale: CGFloat

    func time(at x: CGFloat) -> Double {
        if x == pixels.upperBound { return source.upperBound }
        return source.lowerBound + (x - pixels.lowerBound) / scale
    }

    static func edgeLabel(_ time: Double) -> String {
        let text = timelineTime(abs(time), milliseconds: true)
        let clock = text.hasSuffix(".000") ? String(text.dropLast(4)) : text
        return time < 0 && clock != "00:00" ? "−" + clock : clock
    }

    // Enumerate only the part of the source clock that the viewport can display.
    func ticks(in visible: Range<CGFloat>, draw: (_ x: CGFloat, _ time: Double, _ major: Bool) -> Void) {
        let area = pixels.clamped(to: visible)
        guard !area.isEmpty, scale > 0 else { return }
        let minor = timelineRulerStep(scale: scale) / 5
        let first = ceil(time(at: area.lowerBound) / minor)
        let last = floor(time(at: area.upperBound) / minor)
        guard let lower = Int(exactly: first), let upper = Int(exactly: last), lower <= upper else { return }
        for index in lower...upper {
            let time = Double(index) * minor
            draw(pixels.lowerBound + (time - source.lowerBound) * scale, time, index.isMultiple(of: 5))
        }
    }

    func draw(in context: CGContext, top: CGFloat, visible: Range<CGFloat>) {
        let area = pixels.clamped(to: visible)
        guard !area.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let band = CGRect(x: area.lowerBound, y: top, width: area.upperBound - area.lowerBound, height: Self.height)
        context.clip(to: band)
        context.setFillColor(CGColor(gray: 0.1, alpha: 0.90))
        context.fill(band)
        context.setFillColor(CGColor(gray: 0.94, alpha: 1))
        context.textMatrix = .identity
        var left = area.lowerBound + 2
        var right = area.upperBound - 2
        func label(_ text: String, at x: CGFloat, alignedRight: Bool = false) {
            guard right - left >= 20 else { return }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]))
            let width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
            let origin = alignedRight ? x - width : x
            guard origin >= left, origin + width <= right else { return }
            context.saveGState()
            context.translateBy(x: origin, y: top + 11)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            if alignedRight { right = origin - 5 } else { left = origin + width + 5 }
        }

        // Give the exact trim edges first claim on the space for labels.
        if area.lowerBound == pixels.lowerBound {
            label(Self.edgeLabel(source.lowerBound), at: left)
        }
        if area.upperBound == pixels.upperBound {
            label(Self.edgeLabel(source.upperBound), at: right, alignedRight: true)
        }
        let fractional = timelineRulerStep(scale: scale) < 1
        ticks(in: area) { x, time, major in
            let h: CGFloat = major ? 5 : 3
            context.fill(CGRect(x: x, y: top + Self.height - h, width: 1, height: h))
            if major { label((time < 0 ? "−" : "") + timelineTime(abs(time), milliseconds: fractional), at: x + 3) }
        }
    }
}
