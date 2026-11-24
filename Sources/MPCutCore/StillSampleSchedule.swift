import Foundation

public enum StillPictureTiming: String, Codable, CaseIterable, Sendable {
    case cadence, held
}

struct StillSampleSchedule: Encodable, Sendable {
    struct Run: Encodable, Equatable, Sendable {
        var count: Int
        let duration: RationalTime
    }

    let runs: [Run]
    let count: Int
    let duration: RationalTime
    let cadence: RationalTime

    init(hold duration: RationalTime, cadence: RationalTime) throws {
        guard duration > .zero, cadence >= Self.minimumCadence,
              cadence.numerator <= Int32.max, cadence.denominator <= Int32.max else { throw Self.unsupported }
        self.init(runs: [.init(count: 1, duration: duration)], duration: duration, cadence: cadence)
        _ = try exactTimescale()
    }

    static func matroskaBoundary(_ time: RationalTime, final: Bool) throws -> RationalTime {
        let rounded = try time.roundedToSamples(1_000)
        let point = RationalTime(numerator: rounded, denominator: 1_000)
        if final && point < time {
            return try point.adding(.init(numerator: 1, denominator: 1_000))
        }
        return point
    }

    static func pictureClock(_ denominators: [Int64]) throws -> Int64 {
        var scale: Int64 = 1
        for denominator in denominators {
            var a = scale
            var b = denominator
            while b != 0 { (a, b) = (b, a % b) }
            let reduced = scale / a
            guard reduced <= Int64(Int32.max) / denominator else { throw Self.unsupported }
            scale = reduced * denominator
        }
        return scale
    }

    init(duration: RationalTime, cadence: RationalTime, allowShortFinalSample: @autoclosure () throws -> Bool) throws {
        guard duration > .zero, cadence >= Self.minimumCadence,
              cadence.numerator <= Int32.max, cadence.denominator <= Int32.max else { throw Self.unsupported }
        let samples = try duration.multiplied(by: .init(numerator: cadence.denominator, denominator: cadence.numerator))
        let whole = samples.numerator / samples.denominator
        let hasShortSample = samples.denominator != 1
        guard whole < Int32.max || (whole == Int32.max && !hasShortSample) else { throw Self.unsupported }
        if hasShortSample, try !allowShortFinalSample() {
            throw CutError(code: "unsupported_still_timing",
                           message: "The insert duration must contain an integral number of samples on a constant-rate timeline.")
        }
        self.duration = duration
        self.cadence = cadence
        count = Int(whole) + (hasShortSample ? 1 : 0)
        var runs: [Run] = []
        if whole > 0 { runs.append(.init(count: Int(whole), duration: cadence)) }
        if hasShortSample {
            let short = try duration.subtracting(cadence.multiplied(by: .init(numerator: whole)))
            runs.append(.init(count: 1, duration: short))
        }
        self.runs = runs
    }

    init(frames: ArraySlice<FrameInfo>, duration: RationalTime, cancelled: (@Sendable () -> Bool)?) throws {
        guard let first = frames.first, frames.count <= Int32.max, duration > .zero else { throw Self.unsupported }
        var runs: [Run] = []
        for (index, sample) in frames.enumerated() {
            if index.isMultiple(of: 1_024), cancelled?() == true {
                throw CutError(code: "cancelled", message: "The operation was cancelled.")
            }
            guard sample.duration > .zero else { throw Self.unsupported }
            if let last = runs.indices.last, runs[last].duration == sample.duration {
                runs[last].count += 1
            } else {
                runs.append(.init(count: 1, duration: sample.duration))
            }
        }
        self.runs = runs
        count = frames.count
        self.duration = duration
        cadence = first.duration >= Self.minimumCadence && first.duration.numerator <= Int32.max &&
            first.duration.denominator <= Int32.max ? first.duration : .init(numerator: 1, denominator: 30)
    }

    func fits(timescale: Int64) -> Bool {
        guard timescale > 0, timescale <= Int32.max,
              timescale.isMultiple(of: duration.denominator),
              (try? duration.roundedToSamples(Int(timescale))) != nil else { return false }
        return runs.allSatisfy {
            guard timescale.isMultiple(of: $0.duration.denominator),
                  let ticks = try? $0.duration.roundedToSamples(Int(timescale)) else { return false }
            return ticks > 0 && ticks <= UInt32.max
        }
    }

    func exactTimescale() throws -> Int64 {
        let timescale = try Self.pictureClock(runs.map { $0.duration.denominator })
        guard fits(timescale: timescale) else { throw Self.unsupported }
        return timescale
    }

    func capabilityProbe(at stagingCadence: RationalTime) throws -> Self {
        guard requiresRetime(at: stagingCadence) else {
            return try Self(duration: stagingCadence, cadence: stagingCadence, allowShortFinalSample: false)
        }
        let probeRuns = runs.prefix(2).map { Run(count: 1, duration: $0.duration) }
        let duration = try probeRuns.reduce(RationalTime.zero) { try $0.adding($1.duration) }
        return Self(runs: probeRuns, duration: duration, cadence: cadence)
    }

    private init(runs: [Run], duration: RationalTime, cadence: RationalTime) {
        self.runs = runs
        count = runs.reduce(0) { $0 + $1.count }
        self.duration = duration
        self.cadence = cadence
    }

    func requiresRetime(at cadence: RationalTime) -> Bool {
        runs.count != 1 || runs.first?.duration != cadence
    }

    private static let minimumCadence = RationalTime(numerator: 1, denominator: 240)
    static var unsupported: CutError {
        CutError(code: "unsupported_still_timing", message: "The still sample schedule is outside the selected picture clock’s limits. Use cadence timing or a compatible frame clock.")
    }
}
