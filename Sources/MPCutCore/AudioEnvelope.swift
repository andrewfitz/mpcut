import Foundation
import MediaProbe

/// Signed extrema across the selected track's channels, in equal-width source-time
/// columns. A sub-sample column holds the preceding sample. Gaps contain zero.
public struct AudioEnvelope: Codable, Sendable {
    public static let maxColumns = 65_536
    public let from: Double
    public let to: Double
    public let low: [Float]
    public let high: [Float]
    var analysisClock: AudioAnalysisClock?
    var sourceIdentity: SourceIdentity?

    /// Use after refresh has verified the result's audio stream and presentation clock.
    package func forRefreshedMedia(_ media: MediaInfo, stream: Int) -> AudioEnvelope {
        guard analysisClock == AudioAnalysisClock(media: media, stream: stream) else { return self }
        var result = self
        result.sourceIdentity = media.identity
        return result
    }

    enum CodingKeys: String, CodingKey { case from, to, low, high }

    public init(from: Double, to: Double, low: [Float], high: [Float]) {
        self.from = from
        self.to = to
        self.low = low
        self.high = high
    }

    /// Reusing an overview is exact when both ends and every requested column
    /// edge land on its grid. Finer zooms decode just the requested window.
    func coarsened(from start: Double, to end: Double, columns: Int, sampleRate: Int) -> AudioEnvelope? {
        guard columns > 0, !low.isEmpty, high.count == low.count,
              from.isFinite, to.isFinite, from <= start, start < end, end <= to else { return nil }
        if start == from, end == to, columns == low.count { return self }
        // Sub-sample display columns can hold the preceding value. Aggregating
        // them into larger bins could import a sample outside the requested bin.
        guard Double(low.count) <= (to - from) * Double(sampleRate) else { return nil }
        let binsPerSecond = Double(low.count) / (to - from)
        func aligned(_ time: Double) -> Int? {
            let point = (time - from) * binsPerSecond
            let nearest = point.rounded()
            guard abs(nearest - point) <= max(1e-10, point.ulp * 4) else { return nil }
            return Int(exactly: nearest)
        }
        guard let first = aligned(start), let last = aligned(end), first >= 0, last <= low.count,
              last - first >= columns, (last - first).isMultiple(of: columns) else { return nil }
        let stride = (last - first) / columns
        var minima = [Float](), maxima = [Float]()
        minima.reserveCapacity(columns)
        maxima.reserveCapacity(columns)
        for i in 0..<columns {
            let a = first + i * stride
            var minimum = low[a], maximum = high[a]
            for j in (a + 1)..<(a + stride) {
                minimum = min(minimum, low[j])
                maximum = max(maximum, high[j])
            }
            minima.append(minimum)
            maxima.append(maximum)
        }
        var reduced = AudioEnvelope(from: start, to: end, low: minima, high: maxima)
        reduced.analysisClock = analysisClock
        reduced.sourceIdentity = sourceIdentity
        return reduced
    }
}

private final class EnvelopeCancellation {
    let isCancelled: () -> Bool
    init(_ check: @escaping () -> Bool) { isCancelled = check }
}

extension AudioAnalysis {
    public static func envelope(_ media: MediaInfo, stream: Int, from: Double, to: Double, columns: Int,
                                useSidecar: Bool = true, cancelled: @escaping () -> Bool = { false }) throws -> AudioEnvelope {
        guard from.isFinite, to.isFinite, from >= 0, to > from, to <= media.duration.seconds,
              (1...AudioEnvelope.maxColumns).contains(columns) else {
            throw CutError(code: "invalid_range", message: "Choose a positive waveform interval inside the source and 1–65,536 columns.")
        }
        guard let track = media.streams.first(where: { $0.kind == "audio" && $0.index == stream }) else {
            throw CutError(code: "no_audio", message: "Select an available audio stream for the waveform.")
        }
        func checkSource() throws {
            if cancelled() { throw CutError(code: "cancelled", message: "Waveform analysis was cancelled.") }
            guard try SourceIdentity(media.url) == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
        }
        try checkSource()
        // Lossy codecs can synthesize noise from decoder state accumulated before
        // a seek. Full-recording overviews share that state. Zoomed requests on
        // such tracks follow the same bounded decode whether or not a cache exists.
        let whole = from == 0 && to == media.duration.seconds
        if useSidecar, whole || track.isPCM || track.codec == "flac" || track.codec == "alac",
           (to - from) / media.duration.seconds * Double(AudioEnvelope.maxColumns) + 1e-8 >= Double(columns),
           let saved = AnalysisSidecar(media: media).envelopeOverview(for: media, stream: stream, cancelled: cancelled),
           let result = saved.coarsened(from: from, to: to, columns: columns, sampleRate: track.sampleRate) {
            try checkSource()
            return result
        }
        var low = [Float](repeating: .infinity, count: columns)
        var high = [Float](repeating: -.infinity, count: columns)
        try low.withUnsafeMutableBufferPointer { minima in
            try high.withUnsafeMutableBufferPointer { maxima in
                var window = MPAudioEnvelope(from: from, to: to, through: from, columns: Int32(columns),
                                             low: minima.baseAddress, high: maxima.baseAddress)
                if let audio = media.audio.first(where: { $0.stream.index == stream && !$0.presentationEdits.isEmpty }) {
                    try visitPresentedAudio(audio, media: media, window: from..<to, cancelled: cancelled) { pcm, frames, channels, rate, start in
                        guard mp_float_pcm_envelope(pcm, frames, channels, rate, start, &window) == 0 else {
                            throw CutError(code: "audio_analysis_failed", message: "Could not measure signed PCM levels.")
                        }
                    } silence: { start, end in
                        mp_envelope_silence(&window, start, end)
                    }
                } else {
                    let token = EnvelopeCancellation(cancelled)
                    var error = [CChar](repeating: 0, count: 256)
                    let result = withExtendedLifetime(token) {
                        mp_audio_envelope(media.url.path, Int32(stream), media.origin.seconds, &window, {
                            Unmanaged<EnvelopeCancellation>.fromOpaque($0!).takeUnretainedValue().isCancelled() ? 1 : 0
                        }, Unmanaged.passUnretained(token).toOpaque(), &error, error.count)
                    }
                    if result < 0 {
                        try checkSource()
                        throw CutError(code: "audio_analysis_failed", message: String(cString: error), track: stream)
                    }
                }
                mp_envelope_silence(&window, window.through, to)
            }
        }
        for i in low.indices where low[i] > high[i] {
            low[i] = 0
            high[i] = 0
        }
        try checkSource()
        var envelope = AudioEnvelope(from: from, to: to, low: low, high: high)
        envelope.analysisClock = AudioAnalysisClock(media: media, stream: stream)
        envelope.sourceIdentity = media.identity
        if useSidecar, whole {
            AnalysisSidecar(media: media).saveOverviewAutomatically(envelope, for: media, stream: stream, cancelled: cancelled)
            try checkSource()
        }
        return envelope
    }
}
