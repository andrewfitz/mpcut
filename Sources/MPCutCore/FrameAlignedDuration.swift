import Foundation

/// Turns a preferred duration into a whole number of frames at the timeline's cadence.
public enum FrameAlignedDuration {
    /// The cadence still and gap insertion uses when the timeline has none.
    public static let fallbackCadence = RationalTime(numerator: 1, denominator: 30)
    public static let frameLimit: ClosedRange<Int64> = 1...1_000

    /// Rounds `seconds / cadence` half away from zero in `Double`, as the still and gap
    /// insertion paths do, then clamps the frame count to `frames`. A missing or nonpositive
    /// cadence uses `fallbackCadence`. A nonfinite duration yields one frame.
    public static func duration(seconds: Double, cadence: RationalTime?,
                                frames limit: ClosedRange<Int64> = frameLimit) -> (duration: RationalTime, cadence: RationalTime) {
        let interval = cadence.flatMap { $0 > .zero ? $0 : nil } ?? fallbackCadence
        let count = frameCount(seconds: seconds, cadence: interval, frames: limit)
        let duration = (try? interval.multiplied(by: RationalTime(numerator: count))) ?? interval
        return (duration, interval)
    }

    public static func frameCount(seconds: Double, cadence: RationalTime,
                                  frames limit: ClosedRange<Int64> = frameLimit) -> Int64 {
        let ratio = seconds / cadence.seconds
        guard ratio.isFinite else { return limit.lowerBound }
        return Int64(max(Double(limit.lowerBound), min(Double(limit.upperBound), ratio.rounded())))
    }
}
