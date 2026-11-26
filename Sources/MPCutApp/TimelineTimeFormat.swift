import Foundation
import MPCutCore

/// How one timeline writes its time read-outs: the Time display setting and the timeline's frame cadence.
/// Milliseconds, or Frames with no cadence, writes exactly what `timelineTime(_:milliseconds: true)` writes.
struct TimelineTimeFormat: Equatable {
    static let milliseconds = TimelineTimeFormat(display: .milliseconds, cadence: nil)

    var display: TimelineTimeDisplay
    var cadence: RationalTime?

    /// The cadence frames are counted at, or nil while the read-outs show milliseconds.
    var frameCadence: RationalTime? {
        guard display == .frames, let cadence, TimelineTimeDisplay.nominalRate(cadence) != nil else { return nil }
        return cadence
    }

    func string(_ seconds: Double) -> String {
        display.string(seconds, cadence: cadence)
    }

    /// The distance between labeled ruler ticks. Showing frames, a step under a second is a whole number of
    /// frames that divides a second, so every label lands on the start of the frame it names.
    func rulerStep(scale: CGFloat) -> Double {
        let step = timelineRulerStep(scale: scale)
        guard step < 1, let cadence = frameCadence, let rate = TimelineTimeDisplay.nominalRate(cadence) else { return step }
        let frames = 86 / Double(scale) / cadence.seconds
        guard let count = (1..<rate).first(where: { rate.isMultiple(of: $0) && Double($0) >= frames }) else { return 1 }
        return Double(count) * cadence.seconds
    }

    /// A ruler label: the precise time below a one-second step, whole minutes and seconds above it.
    func rulerLabel(_ seconds: Double, step: Double) -> String {
        step < 1 ? string(seconds) : timelineTime(seconds)
    }
}
