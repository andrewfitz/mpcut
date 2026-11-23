import Foundation

extension MediaInfo {
    /// Resolve an editor position in source-relative seconds onto the selected
    /// audio track’s editable sample grid or its indexed compressed packet edges.
    public func audioEditBoundary(near time: Double,
                                  rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero,
                                  stream: Int? = nil) -> RationalTime {
        audioBoundary(at: time, rounding: rounding, stream: stream, strict: false)
    }

    public func steppingAudioBoundary(from time: Double, direction: Int, stream: Int? = nil) -> RationalTime {
        if direction == 0 { return audioEditBoundary(near: time, stream: stream) }
        return audioBoundary(at: time, rounding: direction > 0 ? .up : .down, stream: stream, strict: true)
    }

    private func audioBoundary(at time: Double, rounding: FloatingPointRoundingRule,
                               stream: Int?, strict: Bool) -> RationalTime {
        guard time.isFinite, let track = audio.first(where: { stream == nil || $0.stream.index == stream }) else { return .zero }
        let position = min(max(time, 0), duration.seconds)
        if position == 0 && (!strict || rounding == .down) { return .zero }
        if position == duration.seconds && (!strict || rounding == .up) { return duration }
        let sampleAddressable = track.stream.isPCM || track.stream.codec == "aac"
            || (track.stream.codec == "mp3" && format == "mp3")
            || track.opusWindow?.complete == true
        if sampleAddressable, let sample = sampleBoundary(at: position, track: track, rounding: rounding, strict: strict) {
            return min(max(sample, .zero), duration)
        }

        // Use indexed edges when a sample position has no representable rational timestamp.
        let packets = track.packets
        let before = packets.lowerBound { strict ? $0.time.seconds >= position : $0.time.seconds > position }
        let after = packets.lowerBound { strict ? $0.time.seconds > position : $0.time.seconds >= position }
        let lower = before > 0 ? max(.zero, packets[before - 1].time) : .zero
        let upper = after < packets.count ? min(duration, packets[after].time) : duration
        let snapped: RationalTime
        switch rounding {
        case .down, .towardZero: snapped = lower
        case .up, .awayFromZero: snapped = upper
        default:
            snapped = position - lower.seconds <= upper.seconds - position ? lower : upper
        }
        return min(max(snapped, .zero), duration)
    }

    private func sampleBoundary(at position: Double, track: AudioIndex,
                                rounding: FloatingPointRoundingRule, strict: Bool) -> RationalTime? {
        let rate = Int64(track.stream.sampleRate)
        guard rate > 0 else { return nil }
        var value = (position - track.start.seconds) * Double(rate)
        guard value.isFinite else { return nil }

        // A rational time converted to seconds can land one ULP off the grid.
        let tolerance = 4 * max(value.ulp, position.ulp * Double(rate))
        if abs(value - value.rounded()) <= tolerance { value = value.rounded() }
        let rounded: Double
        switch rounding {
        case .down, .towardZero: rounded = value.rounded(.down)
        case .up, .awayFromZero: rounded = value.rounded(.up)
        default:
            // Preserve the requested half-sample rule through the seconds conversion.
            let halfway = value.rounded(.down) + 0.5
            if abs(value - halfway) <= tolerance { value = halfway }
            rounded = value.rounded(rounding)
        }

        guard var sample = Int64(exactly: rounded) else { return nil }
        if strict, rounded == value {
            let (next, overflow) = sample.addingReportingOverflow(rounding == .up ? 1 : -1)
            guard !overflow else { return nil }
            sample = next
        }
        return try? track.start.adding(RationalTime(numerator: sample, denominator: rate))
    }
}
