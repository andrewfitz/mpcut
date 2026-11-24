import Foundation

/// Quiet and covered runs begin and end on the peak grid, apart from an end clamped to
/// the clip's duration. Each endpoint is stored as its distance in bins from the one
/// before, and an endpoint off the grid as its exact rational. Pauses follow from the runs
/// and the minimum length, so they are listed only when a result's pauses differ from
/// that derivation. A change to what `SilenceRuns.pauses` returns for the default blip
/// needs a new section version, because sections saved before it omit their pauses.
enum SidecarSilencePacking {
    private static let layout: UInt8 = 1
    private static let listsPauses: UInt8 = 1

    /// The layout, whether pauses are listed, and the bins per second, then each list as
    /// its span count and two endpoints per span. An even endpoint is twice a bin distance.
    /// One is followed by a numerator and denominator and leaves the bin position alone.
    static func pack(pauses: [AudioSpan], runs: SilenceRuns, minimum: Double, cancelled: () -> Bool) throws -> Data? {
        let rate = Int64(AudioWaveform.rate)
        guard rate > 0 else { return nil }
        let derived = runs.pauses(minimum: minimum) == pauses
        var output = PackedWriter()
        output.bytes.append(layout)
        output.bytes.append(derived ? 0 : listsPauses)
        output.unsigned(UInt64(rate))
        for spans in derived ? [runs.quiet, runs.covered] : [runs.quiet, runs.covered, pauses] {
            output.unsigned(UInt64(spans.count))
            var cursor: Int64 = 0
            func endpoint(_ time: RationalTime) -> Bool {
                let (bin, overflow) = time.numerator.multipliedReportingOverflow(by: rate / time.denominator)
                guard rate.isMultiple(of: time.denominator), !overflow else {
                    output.bytes.append(1)
                    output.time(time)
                    return true
                }
                guard bin >= cursor else { return false }
                output.unsigned(UInt64(bin - cursor) << 1)
                cursor = bin
                return true
            }
            for (index, span) in spans.enumerated() {
                if index.isMultiple(of: 1024) { try checkSidecarCancellation(cancelled) }
                // Saved runs are ordered. Any other list keeps the property list layout.
                guard endpoint(span.from), endpoint(span.to) else { return nil }
            }
        }
        let packed = Data(output.bytes)
        guard let restored = try unpack(packed, minimum: minimum, cancelled: cancelled), restored.pauses == pauses,
              restored.runs.quiet == runs.quiet, restored.runs.covered == runs.covered else { return nil }
        return packed
    }

    static func unpack(_ data: Data, minimum: Double,
                       cancelled: () -> Bool) throws -> (pauses: [AudioSpan], runs: SilenceRuns)? {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            do {
                var input = PackedReader(bytes)
                guard try input.byte() == layout else { return nil }
                let flags = try input.byte()
                guard flags & ~listsPauses == 0, let rate = Int64(exactly: try input.unsigned()), rate > 0 else { return nil }
                func spans() throws -> [AudioSpan] {
                    let count = try input.count(minimumBytes: 2)
                    var result: [AudioSpan] = []
                    result.reserveCapacity(count)
                    var cursor: Int64 = 0
                    func endpoint() throws -> RationalTime {
                        let token = try input.unsigned()
                        if token & 1 == 1 {
                            guard token == 1 else { throw PackedCodingError.invalid }
                            return try input.time()
                        }
                        let (bin, overflow) = cursor.addingReportingOverflow(Int64(token >> 1))
                        guard !overflow else { throw PackedCodingError.invalid }
                        cursor = bin
                        return RationalTime(numerator: bin, denominator: rate)
                    }
                    for index in 0..<count {
                        if index.isMultiple(of: 1024) { try checkSidecarCancellation(cancelled) }
                        let from = try endpoint()
                        result.append(AudioSpan(from: from, to: try endpoint()))
                    }
                    return result
                }
                let runs = SilenceRuns(quiet: try spans(), covered: try spans())
                let pauses = try flags & listsPauses != 0 ? spans() : runs.pauses(minimum: minimum)
                guard input.remaining == 0 else { return nil }
                return (pauses, runs)
            } catch is PackedCodingError {
                return nil
            }
        }
    }
}
