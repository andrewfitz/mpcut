import AppKit
import QuartzCore

enum PlaybackSpeed: Float, CaseIterable {
    case eighth = 0.125, quarter = 0.25, half = 0.5, threeQuarters = 0.75
    case normal = 1, oneAndQuarter = 1.25, oneAndHalf = 1.5, double = 2, quadruple = 4, octuple = 8

    var label: String { Self.label(for: rawValue) }

    static func label(for rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...3))) + "×"
    }
}

/// Drive picture selection from the preview display. Media time still comes from
/// the audio or host clock, so a late refresh selects the current source frame.
final class PreviewDisplayTicker {
    private let link: CADisplayLink?
    private let fallback: Task<Void, Never>?

    private final class Target: NSObject {
        let tick: @MainActor () -> Void
        init(_ tick: @escaping @MainActor () -> Void) { self.tick = tick }
        @MainActor @objc func refresh(_ sender: CADisplayLink) { tick() }
    }

    @MainActor
    init(screen: NSScreen?, tick: @escaping @MainActor () -> Void) {
        // Playback without a video surface (for example, the waveform viewer)
        // has no display refresh to wait for.
        if let screen {
            let link = screen.displayLink(target: Target(tick), selector: #selector(Target.refresh(_:)))
            let maximum = Float(max(1, screen.maximumFramesPerSecond))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            self.link = link
            fallback = nil
        } else {
            link = nil
            fallback = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
                    tick()
                }
            }
        }
    }

    func cancel() {
        link?.invalidate()
        fallback?.cancel()
    }

    deinit { cancel() }
}
