import Foundation
import MPCutCore

/// Formats the timeline time read-out in milliseconds or in whole frames.
enum TimelineTimeDisplay: String, CaseIterable, Sendable {
    case milliseconds, frames

    /// Milliseconds is `MM:SS.mmm`, as `timelineTime(_:milliseconds: true)` writes it. Frames is
    /// non-drop `MM:SS:FF`, or `H:MM:SS:FF` from an hour, counting whole frames at `cadence`, the
    /// timeline's frame duration. With no cadence, as on an audio-only timeline, frames falls back
    /// to milliseconds. At a fractional rate such as 29.97 the frames clock counts 30 frames to a
    /// second, so it runs behind the milliseconds clock by 3.6 seconds an hour.
    func string(_ seconds: Double, cadence: RationalTime?) -> String {
        guard self == .frames, let cadence, let rate = Self.nominalRate(cadence) else {
            return timelineTime(seconds, milliseconds: true)
        }
        let frames = Self.frameIndex(seconds, cadence: cadence)
        let whole = frames / rate
        let minutes = whole / 60
        let width = rate > 100 ? 3 : 2
        let count = String(format: ":%0\(width)ld", frames % rate)
        return minutes < 60
            ? String(format: "%02ld:%02ld", minutes, whole % 60) + count
            : "\(minutes / 60)" + String(format: ":%02ld:%02ld", minutes % 60, whole % 60) + count
    }

    /// Reads `[H:]MM:SS:FF` written by `string` back as seconds at the start of that frame.
    static func parseFrames(_ text: String, cadence: RationalTime) -> Double? {
        guard let rate = nominalRate(cadence) else { return nil }
        let fields = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (3...4).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let values = fields.compactMap { Int($0) }
        guard values.count == fields.count else { return nil }
        let frame = values[values.count - 1], second = values[values.count - 2], minute = values[values.count - 3]
        let hour = values.count == 4 ? values[0] : 0
        guard frame < rate, second < 60, values.count == 3 || minute < 60 else { return nil }
        let (total, overflow) = (((hour * 60 + minute) * 60 + second)).multipliedReportingOverflow(by: rate)
        guard !overflow else { return nil }
        return Double(total + frame) * cadence.seconds
    }

    /// Frames per second, rounded: 30 at 29.97, 24 at 23.976.
    static func nominalRate(_ cadence: RationalTime) -> Int? {
        guard cadence > .zero else { return nil }
        let rate = (1 / cadence.seconds).rounded()
        guard rate.isFinite, rate >= 1, rate <= 10_000 else { return nil }
        return Int(rate)
    }

    /// Whole frames elapsed. A time at a frame boundary counts that frame even when the
    /// division lands a hair below it.
    static func frameIndex(_ seconds: Double, cadence: RationalTime) -> Int {
        let safe = seconds.isFinite ? min(max(0, seconds), Double(Int.max / 2000)) : 0
        let exact = safe * Double(cadence.denominator) / Double(cadence.numerator)
        return Int(min((exact + 1e-6).rounded(.down), Double(Int.max / 2)))
    }
}
