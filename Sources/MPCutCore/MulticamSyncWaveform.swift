import Foundation

extension MulticamSync {
    /// Reuse reference preprocessing across targets in one sync report.
    struct Matcher {
        let reference: [Float]
        fileprivate var referenceFeatures: [Double]?
        fileprivate var referenceMissing: [Int]?

        init(_ reference: [Float]) {
            self.reference = reference
        }

        mutating func match(_ target: [Float], referenceOffset: RationalTime,
                            baselines: [RationalTime], referenceRanges: [MulticamRange]? = nil, cancelled: () -> Bool) throws -> [Match] {
            try MulticamSync.match(&self, target, referenceOffset: referenceOffset, baselines: baselines, referenceRanges: referenceRanges,
                                   cancelled: cancelled)
        }
    }

    static func waveformWindow(referenceCount: Int, targetCount: Int, referenceRanges: [MulticamRange]?) -> Int {
        let rate = AudioWaveform.rate
        let minimum = 4 * rate
        let shortestUsed = bins(for: referenceRanges, count: referenceCount).map(\.count)
            .filter { $0 >= minimum }.min() ?? 0
        return min(10 * rate, max(minimum, min(shortestUsed, targetCount) / 2))
    }

    private static func bins(for ranges: [MulticamRange]?, count: Int) -> [Range<Int>] {
        guard let ranges else { return [0..<count] }
        let rate = Double(AudioWaveform.rate)
        return ranges.compactMap { range in
            let lower = Int(max(0, min(Double(count), (range.from.seconds * rate).rounded(.up))))
            let upper = Int(max(0, min(Double(count), (range.to.seconds * rate).rounded(.down))))
            return lower < upper ? lower..<upper : nil
        }
    }

    /// Correlate short windows of log-compressed amplitude. The waveform cache uses
    /// -1 for bins with no decoded samples, which cannot support a correlation.
    static func match(_ reference: [Float], _ target: [Float], referenceOffset: RationalTime,
                      baselines: [RationalTime], cancelled: () -> Bool = { false }) throws -> [Match] {
        var matcher = Matcher(reference)
        return try matcher.match(target, referenceOffset: referenceOffset, baselines: baselines, cancelled: cancelled)
    }

    private static func match(_ matcher: inout Matcher, _ target: [Float], referenceOffset: RationalTime,
                              baselines: [RationalTime], referenceRanges: [MulticamRange]? = nil, cancelled: () -> Bool) throws -> [Match] {
        let reference = matcher.reference
        let rate = AudioWaveform.rate
        let radius = 30 * rate
        let minimum = 4 * rate
        let referenceBins = bins(for: referenceRanges, count: reference.count)
        guard target.count >= minimum, referenceBins.contains(where: { $0.count >= minimum }) else { return [] }
        let window = waveformWindow(referenceCount: reference.count, targetCount: target.count, referenceRanges: referenceRanges)
        func features(_ values: [Float]) throws -> [Double] {
            try values.enumerated().map { index, peak in
                if index.isMultiple(of: 4096), cancelled() { throw CancellationError() }
                return peak < 0 ? -.infinity : log1p(Double(peak) * 100)
            }
        }
        func missingBins(_ values: [Double]) throws -> [Int] {
            var prefix = [0]
            prefix.reserveCapacity(values.count + 1)
            var missing = 0
            for (index, value) in values.enumerated() {
                if index.isMultiple(of: 4096), cancelled() { throw CancellationError() }
                if !value.isFinite { missing += 1 }
                prefix.append(missing)
            }
            return prefix
        }
        if cancelled() { throw CancellationError() }
        let referenceFeatures: [Double]
        if let cached = matcher.referenceFeatures {
            referenceFeatures = cached
        } else {
            referenceFeatures = try features(reference)
            matcher.referenceFeatures = referenceFeatures
        }
        let targetFeatures = try features(target)
        // Anchor on the shorter side of each retained range. A short incoming
        // take can be anywhere in a long retained range, while a short retained
        // range needs its own anchors even when the full camera take is long.
        var matches: [Match] = []
        for targetIsShorter in [false, true] {
            let selectedBins = referenceBins.filter { $0.count >= window && (target.count < $0.count) == targetIsShorter }
            guard !selectedBins.isEmpty else { continue }
            let left = targetIsShorter ? targetFeatures : referenceFeatures
            let right = targetIsShorter ? referenceFeatures : targetFeatures
            // Count missing bins in each candidate window with two prefix lookups.
            let rightMissing: [Int]
            if targetIsShorter, let cached = matcher.referenceMissing {
                rightMissing = cached
            } else {
                rightMissing = try missingBins(right)
                if targetIsShorter { matcher.referenceMissing = rightMissing }
            }
            let shifts = Set(baselines.compactMap { baseline -> Int? in
                let bins = (baseline.seconds * Double(rate)).rounded()
                guard abs(bins) <= Double(max(reference.count, target.count) + radius) else { return nil }
                return targetIsShorter ? -Int(bins) : Int(bins)
            }).sorted()

            var starts = Set<Int>()
            for shift in shifts {
                // Include overlap that a nearby correction could reveal.
                let availableStart = max(0, shift - radius)
                let availableEnd = min(left.count, right.count + shift + radius) - window
                for bounds in selectedBins {
                    let first = max(availableStart, targetIsShorter ? bounds.lowerBound + shift - radius : bounds.lowerBound)
                    let last = min(availableEnd, (targetIsShorter ? bounds.upperBound + shift + radius : bounds.upperBound) - window)
                    guard last >= first else { continue }
                    for step in 0...4 { starts.insert(first + (last - first) * step / 4) }
                    if referenceRanges != nil {
                        let nominalStart = max(first, shift, targetIsShorter ? bounds.lowerBound + shift : bounds.lowerBound)
                        let nominalEnd = min(last, right.count + shift - window,
                                             (targetIsShorter ? bounds.upperBound + shift : bounds.upperBound) - window)
                        if nominalStart <= nominalEnd {
                            starts.insert(nominalStart)
                            starts.insert(nominalEnd)
                        }
                    }
                }
            }
            for start in starts.sorted() {
                if cancelled() { throw CancellationError() }
                let slice = left[start..<(start + window)]
                // A repeating envelope can look like a unique match if the other
                // recording ends before a second peak fits into the search window.
                guard let anchor = score(slice, slice) else { continue }
                if try isPeriodic(slice, cancelled: cancelled) { continue }
                let candidates = candidateRanges(shifts: shifts, start: start, radius: radius,
                                                 lastPosition: right.count - window)
                var scored: [(position: Int, correlation: Double)] = []
                for range in candidates {
                    for position in range {
                        if position.isMultiple(of: 64), cancelled() { throw CancellationError() }
                        if targetIsShorter, referenceRanges != nil,
                           !selectedBins.contains(where: { position >= $0.lowerBound && position + window <= $0.upperBound }) {
                            continue
                        }
                        let end = position + window
                        let missing = rightMissing[end] - rightMissing[position]
                        guard Double(window - missing) >= Double(window) * 0.9 else { continue }
                        let rightSlice = right[position..<end]
                        let candidate = anchor.count == Double(window) && missing == 0
                            ? denseCorrelation(slice, rightSlice, anchor: anchor)
                            : score(slice, rightSlice)?.correlation
                        if let correlation = candidate, correlation >= 0.60 {
                            scored.append((position, correlation))
                        }
                    }
                }
                guard let best = scored.max(by: { $0.correlation < $1.correlation }),
                      best.correlation >= 0.75 else { continue }
                let runnerUp = scored.indices.lazy.filter { index in
                    let peak = scored[index]
                    guard peak.position != best.position else { return false }
                    let before = index > scored.startIndex ? scored[index - 1] : nil
                    let after = index + 1 < scored.endIndex ? scored[index + 1] : nil
                    return (before.map { $0.position != peak.position - 1 || $0.correlation <= peak.correlation } ?? true) &&
                        (after.map { $0.position != peak.position + 1 || $0.correlation <= peak.correlation } ?? true)
                }.map { scored[$0].correlation }.max() ?? 0
                guard best.correlation - runnerUp >= 0.08 else { continue }
                let referenceStart = targetIsShorter ? best.position : start
                let targetStart = targetIsShorter ? start : best.position
                let relative = RationalTime(numerator: Int64(referenceStart - targetStart), denominator: Int64(rate))
                let center = RationalTime(numerator: Int64(referenceStart + window / 2), denominator: Int64(rate))
                matches.append(Match(referenceTime: center, offset: try referenceOffset.adding(relative),
                                     correlation: best.correlation))
            }
        }
        return matches.sorted { $0.referenceTime < $1.referenceTime }
    }

    private static func candidateRanges(shifts: [Int], start: Int, radius: Int,
                                        lastPosition: Int) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        // Descending shifts produce ascending positions. Merge overlaps so each
        // position is scored once, in the same order used for peak selection.
        for shift in shifts.reversed() {
            let lower = max(0, start - shift - radius)
            let upper = min(lastPosition, start - shift + radius)
            guard lower <= upper else { continue }
            if let previous = ranges.last, lower <= previous.upperBound {
                ranges[ranges.count - 1] = previous.lowerBound...max(previous.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }
        return ranges
    }

    private static func isPeriodic(_ window: ArraySlice<Double>, cancelled: () -> Bool) throws -> Bool {
        for lag in 1...window.count / 2 {
            if lag.isMultiple(of: 64), cancelled() { throw CancellationError() }
            if let result = score(window.dropLast(lag), window.dropFirst(lag)), result.correlation >= 0.98 {
                return true
            }
        }
        return false
    }

    private struct Score {
        let count: Double
        let sum: Double
        let variance: Double
        let correlation: Double
    }

    private static func score(_ left: ArraySlice<Double>, _ right: ArraySlice<Double>) -> Score? {
        var count = 0.0
        var sumX = 0.0, sumY = 0.0, squaresX = 0.0, squaresY = 0.0, product = 0.0
        left.withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { right in
                for index in left.indices {
                    let x = left[index], y = right[index]
                    guard x.isFinite, y.isFinite else { continue }
                    count += 1
                    sumX += x
                    sumY += y
                    squaresX += x * x
                    squaresY += y * y
                    product += x * y
                }
            }
        }
        guard count >= Double(left.count) * 0.9 else { return nil }
        let varianceX = squaresX - sumX * sumX / count
        let varianceY = squaresY - sumY * sumY / count
        guard min(varianceX, varianceY) / count >= 0.01 else { return nil }
        let correlation = (product - sumX * sumY / count) / (varianceX * varianceY).squareRoot()
        return Score(count: count, sum: sumX, variance: varianceX, correlation: correlation)
    }

    /// Reuse the anchor's moments when all bins contribute. As in `score`, each
    /// sum accumulates in window order to preserve the correlation at thresholds.
    private static func denseCorrelation(_ left: ArraySlice<Double>, _ right: ArraySlice<Double>,
                                         anchor: Score) -> Double? {
        var sum = 0.0, squares = 0.0, product = 0.0
        left.withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { right in
                for index in left.indices {
                    let y = right[index]
                    sum += y
                    squares += y * y
                    product += left[index] * y
                }
            }
        }
        let variance = squares - sum * sum / anchor.count
        guard min(anchor.variance, variance) / anchor.count >= 0.01 else { return nil }
        return (product - anchor.sum * sum / anchor.count) / (anchor.variance * variance).squareRoot()
    }
}
