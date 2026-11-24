import AppKit
import QuartzCore
import SwiftUI

/// Tracks a single drag over the Source picture independently of the video
/// presenter and SwiftUI's tile controls.
struct ParticipantBoxDrawing: NSViewRepresentable {
    let completed: (CGRect) -> Void

    func makeNSView(context: Context) -> DrawingView {
        let view = DrawingView(frame: .zero)
        view.completed = completed
        return view
    }

    func updateNSView(_ view: DrawingView, context: Context) {
        view.completed = completed
    }

    final class DrawingView: NSView {
        private let outline = CAShapeLayer()
        private var start: CGPoint?
        var completed: ((CGRect) -> Void)?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            outline.isGeometryFlipped = true
            outline.fillColor = nil
            outline.strokeColor = NSColor.controlAccentColor.cgColor
            outline.lineWidth = 2
            outline.lineDashPattern = [4, 3]
            layer?.addSublayer(outline)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            outline.frame = bounds
        }

        override func mouseDown(with event: NSEvent) {
            start = localPoint(event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let rect = ParticipantMonitorOverlay.normalizedRect(from: start, to: localPoint(event), size: bounds.size)
            let path = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                              width: rect.width * bounds.width, height: rect.height * bounds.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outline.path = CGPath(rect: path, transform: nil)
            CATransaction.commit()
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            self.start = nil
            outline.path = nil
            let rect = ParticipantMonitorOverlay.normalizedRect(from: start, to: localPoint(event), size: bounds.size)
            guard rect.width >= 0.005, rect.height >= 0.005 else { return }
            completed?(rect)
        }

        private func localPoint(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }
    }
}
