import Foundation

extension AudioAnalysis {
    /// Align the removable interval inward to the audio timeline’s cut points.
    /// This keeps the requested room on either side without materializing sample timestamps.
    public static func audioRemoval(in pause: AudioSpan, leave: Double, media: MediaInfo,
                                    stream: Int? = nil, clip: AudioSpan, container: String? = nil) -> AudioSpan? {
        let linkedTracks = media.audio.filter { stream == nil || $0.stream.index == stream }
        let sampleRate = commonAudioSampleRate(linkedTracks.map { $0.stream.sampleRate })
        let usesSharedGrid = linkedTracks.count > 1 && sampleRate > 0 && linkedTracks.allSatisfy { track in
            track.stream.isPCM || track.stream.codec == "aac" &&
                ["m4a", "mov", "mp4", "m4v"].contains(container ?? "mov")
        }
        func boundary(_ time: Double, rounding: FloatingPointRoundingRule) -> RationalTime {
            if usesSharedGrid {
                // The joined export clock must represent every selected sample rate.
                var value = time * Double(sampleRate)
                let nearest = value.rounded()
                if abs(value - nearest) <= 4 * max(value.ulp, time.ulp * Double(sampleRate)) { value = nearest }
                if let samples = Int64(exactly: value.rounded(rounding)) {
                    return RationalTime(numerator: samples, denominator: Int64(sampleRate))
                }
                return time < 0 ? .zero : media.duration
            }
            return media.audioEditBoundary(near: time, rounding: rounding, stream: stream)
        }
        let from = leave == 0 && pause.from == clip.from ? clip.from :
            boundary(pause.from.seconds + leave / 2, rounding: .up)
        let to = leave == 0 && pause.to == clip.to ? clip.to :
            boundary(pause.to.seconds - leave / 2, rounding: .down)
        guard from < to, from >= pause.from, to <= pause.to else { return nil }
        return AudioSpan(from: from, to: to)
    }
}
