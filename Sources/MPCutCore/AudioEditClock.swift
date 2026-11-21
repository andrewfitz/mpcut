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
        let lower: RationalTime, upper: RationalTime
        let sampleAddressable = track.stream.isPCM || track.stream.codec == "aac"
            || (track.stream.codec == "mp3" && format == "mp3")
            || track.opusWindow?.complete == true
        if sampleAddressable, track.stream.sampleRate > 0 {
            let rate = Int64(track.stream.sampleRate)
            var value = (position - track.start.seconds) * Double(rate)
            guard abs(value) < Double(Int64.max) else { return duration }
            // A rational time converted to seconds can land one ULP off the grid.
            let tolerance = 4 * max(value.ulp, position.ulp * Double(rate))
            if abs(value - value.rounded()) <= tolerance { value = value.rounded() }
            if !strict && (rounding == .toNearestOrAwayFromZero || rounding == .toNearestOrEven) {
                // Preserve the requested half-sample rule through the seconds conversion.
                let halfway = value.rounded(.down) + 0.5
                if abs(value - halfway) <= tolerance { value = halfway }
                let nearest = track.start + RationalTime(numerator: Int64(value.rounded(rounding)), denominator: rate)
                return min(max(nearest, .zero), duration)
            }
            var floor = Int64(value.rounded(.down)), ceil = Int64(value.rounded(.up))
            if strict && floor == ceil { floor -= 1; ceil += 1 }
            lower = track.start + RationalTime(numerator: floor, denominator: rate)
            upper = track.start + RationalTime(numerator: ceil, denominator: rate)
        } else {
            // PCM grids stay implicit and compressed audio reuses the packet array.
            let packets = track.packets
            let before = packets.lowerBound { strict ? $0.time.seconds >= position : $0.time.seconds > position }
            let after = packets.lowerBound { strict ? $0.time.seconds > position : $0.time.seconds >= position }
            lower = before > 0 ? max(.zero, packets[before - 1].time) : .zero
            upper = after < packets.count ? min(duration, packets[after].time) : duration
        }
        let snapped: RationalTime
        switch rounding {
        case .down, .towardZero: snapped = lower
        case .up, .awayFromZero: snapped = upper
        default:
            snapped = position - lower.seconds <= upper.seconds - position ? lower : upper
        }
        return min(max(snapped, .zero), duration)
    }
}
