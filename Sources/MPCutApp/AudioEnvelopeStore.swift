import Foundation
import MPCutCore

/// Reduce eight neighboring bins per level. A zoomed-out pixel touches only
/// the two partial ends and a handful of interior extrema at each level.
final class DisplayEnvelope: Sendable {
    let samples: AudioEnvelope
    private let levels: [(low: [Float], high: [Float])]
    let secondsPerBin: Double

    init(_ envelope: AudioEnvelope) {
        samples = envelope
        secondsPerBin = (envelope.to - envelope.from) / Double(max(1, envelope.low.count))
        var pyramid = [(low: envelope.low, high: envelope.high)]
        while let previous = pyramid.last, previous.low.count >= 8 {
            var low: [Float] = [], high: [Float] = []
            low.reserveCapacity((previous.low.count + 7) / 8)
            high.reserveCapacity(low.capacity)
            for i in stride(from: 0, to: previous.low.count, by: 8) {
                let end = min(i + 8, previous.low.count)
                low.append(previous.low[i..<end].min()!)
                high.append(previous.high[i..<end].max()!)
            }
            pyramid.append((low, high))
        }
        levels = pyramid
    }

    func range(from: Double, to: Double) -> (Float, Float)? {
        guard to > from, secondsPerBin > 0, to > samples.from, from < samples.to else { return nil }
        func bin(_ time: Double, rounding: FloatingPointRoundingRule) -> Int {
            let position = (time - samples.from) / secondsPerBin
            let nearest = position.rounded()
            // Subtracting a late window's origin can magnify timestamp rounding.
            let tolerance = max(position.ulp * 2, time.ulp / secondsPerBin)
            return Int(abs(position - nearest) <= tolerance ? nearest : position.rounded(rounding))
        }
        var i = bin(max(from, samples.from), rounding: .down)
        var end = min(samples.low.count, bin(min(to, samples.to), rounding: .up))
        guard i < end else { return nil }
        var low = Float.infinity, high = -Float.infinity
        for (lower, upper) in levels {
            while i < end && (i % 8 != 0 || end - i < 8) {
                low = min(low, lower[i])
                high = max(high, upper[i])
                i += 1
            }
            while end > i && end % 8 != 0 {
                end -= 1
                low = min(low, lower[end])
                high = max(high, upper[end])
            }
            if i == end { break }
            i /= 8
            end /= 8
        }
        return (low, high)
    }
}

enum WaveformSurface: Hashable { case viewer, timeline(UUID), cutPreview(Int) }

/// Least recently used order. Evicting a window that is still drawn would decode it again on every redraw.
struct RecentKeys<Key: Hashable> {
    let limit: Int
    private(set) var keys: [Key] = []

    init(limit: Int) { self.limit = limit }

    /// Returns the key that fell out, if any.
    mutating func use(_ key: Key) -> Key? {
        if keys.last == key { return nil }
        if let index = keys.lastIndex(of: key) { keys.remove(at: index) }
        keys.append(key)
        return keys.count > limit ? keys.removeFirst() : nil
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) { keys.removeAll(where: shouldRemove) }
}

@MainActor
final class AudioEnvelopeStore {
    private struct Input {
        let media: MediaInfo
        let stream: Int
        let readSidecars: Bool

        var key: AudioAnalysisCacheKey { AudioAnalysisCacheKey(media: media, stream: stream) }
    }
    private struct Overview {
        let key: AudioAnalysisCacheKey
        let envelope: DisplayEnvelope
    }
    private struct Request {
        let from: Double
        let to: Double
        let bin: Double

        func covers(_ start: Double, _ end: Double, _ resolution: Double) -> Bool {
            from <= start && to >= end && bin <= resolution * 1.15
        }
    }
    private struct Job {
        let request: Request
        let token: EditCancellation
    }
    private struct Key: Hashable {
        let id: UUID
        let surface: WaveformSurface
    }

    private var inputs: [UUID: Input] = [:]
    private var overviewJobs: [UUID: EditCancellation] = [:]
    private var overviews: [UUID: [Int: Overview]] = [:]
    private var windows: [Key: DisplayEnvelope] = [:]
    // Pause cuts can put far more than a screenful of short clips in view.
    private var recentWindows = RecentKeys<Key>(limit: 256)
    private var jobs: [Key: Job] = [:]
    private var failed: [Key: Request] = [:]
    var changed: (() -> Void)?

    func update(sources: [UUID: MediaInfo], track: Int, readSidecars: Bool) {
        var current = [UUID: Input]()
        for (id, media) in sources where !media.hasVideo {
            let streams = media.streams.filter { $0.kind == "audio" }
            guard streams.indices.contains(track) else { continue }
            current[id] = Input(media: media, stream: streams[track].index, readSidecars: readSidecars)
        }
        for id in Set(inputs.keys).union(current.keys).union(overviews.keys) {
            let before = inputs[id], after = current[id]
            if let media = sources[id], !media.hasVideo {
                overviews[id] = overviews[id]?.filter { stream, entry in
                    entry.key == AudioAnalysisCacheKey(media: media, stream: stream)
                }
            } else {
                overviews[id] = nil
            }
            if before?.key == after?.key && before?.readSidecars == after?.readSidecars { continue }
            overviewJobs.removeValue(forKey: id)?.cancel()
            for key in Set(jobs.keys).union(windows.keys).union(failed.keys) where key.id == id {
                jobs.removeValue(forKey: key)?.token.cancel()
                windows[key] = nil
                failed[key] = nil
            }
            recentWindows.removeAll { $0.id == id }
            inputs[id] = after
            if let after, !after.media.audio.isEmpty, overviews[id]?[after.stream] == nil { loadOverview(id, input: after) }
        }
    }

    private nonisolated static func overviewColumns(_ media: MediaInfo) -> Int {
        Int(max(1, min(Double(AudioEnvelope.maxColumns), ceil(media.duration.seconds * 1_000))))
    }

    private func loadOverview(_ id: UUID, input: Input) {
        let token = EditCancellation()
        overviewJobs[id] = token
        EditorAnalysisQueues.waveformDetail.addOperation { [weak self] in
            let media = input.media
            let columns = Self.overviewColumns(media)
            guard !token.isCancelled else { return }
            let data = try? AudioAnalysis.envelope(media, stream: input.stream, from: 0, to: media.duration.seconds,
                                                   columns: columns, useSidecar: input.readSidecars, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            let result = data.map(DisplayEnvelope.init)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.overviewJobs[id] === token else { return }
                self.overviewJobs[id] = nil
                if let result { self.overviews[id, default: [:]][input.stream] = Overview(key: input.key, envelope: result) }
                self.changed?()
            }
        }
    }

    func completed(for id: UUID, media: MediaInfo) -> [Int: AudioEnvelope] {
        (overviews[id] ?? [:]).filter { stream, entry in
            entry.key == AudioAnalysisCacheKey(media: media, stream: stream)
        }.mapValues { $0.envelope.samples }
    }

    /// Keep a margin around each request so small scrolls reuse the same result.
    func envelope(for id: UUID, surface: WaveformSurface, from: Double, to: Double, pixels: Int) -> DisplayEnvelope? {
        guard let input = inputs[id], pixels > 0, to.isFinite, from.isFinite else { return nil }
        let start = max(0, from), end = min(input.media.duration.seconds, to)
        guard start < end else { return nil }
        let overview = overviews[id]?[input.stream]?.envelope
        let bin = max(1.0 / Double(max(1, input.media.streams.first(where: { $0.index == input.stream })?.sampleRate ?? 48_000)),
                      (end - start) / Double(min(8_192, pixels)))
        let key = Key(id: id, surface: surface)
        let window = windows[key]
        if window != nil { _ = recentWindows.use(key) }
        let covers = window.map { $0.samples.from <= start && $0.samples.to >= end } ?? false
        if let window, covers, window.secondsPerBin <= bin * 1.15 { return window }
        if let overview, overview.secondsPerBin <= bin * 1.15 { return overview }
        let overviewBin = input.media.duration.seconds / Double(Self.overviewColumns(input.media))
        let waitingForOverview = overviewJobs[id] != nil && overviewBin <= bin * 1.15
        guard !input.media.audio.isEmpty, !waitingForOverview, jobs[key]?.request.covers(start, end, bin) != true,
              failed[key]?.covers(start, end, bin) != true else { return covers ? window : overview }
        let span = end - start
        // A 10 ms view needs a few hundred milliseconds of lookahead to follow playback.
        let padded = min(16_384 * bin, max(0.35, span * 2))
        let margin = max(0, (padded - span) / 2)
        let lower = max(0, start - margin), upper = min(input.media.duration.seconds, end + margin)
        let columns = max(1, min(16_384, Int(ceil((upper - lower) / bin))))
        let token = EditCancellation()
        let request = Request(from: lower, to: upper, bin: (upper - lower) / Double(columns))
        jobs[key]?.token.cancel()
        jobs[key] = Job(request: request, token: token)
        let operation = BlockOperation { [weak self] in
            guard !token.isCancelled else { return }
            let data = try? AudioAnalysis.envelope(input.media, stream: input.stream, from: lower, to: upper,
                                                   columns: columns, useSidecar: input.readSidecars, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            let result = data.map(DisplayEnvelope.init)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.jobs[key]?.token === token else { return }
                self.jobs[key] = nil
                self.windows[key] = result
                if let oldest = self.recentWindows.use(key) {
                    self.windows[oldest] = nil
                    self.failed[oldest] = nil
                }
                self.failed[key] = result == nil ? request : nil
                self.changed?()
            }
        }
        operation.queuePriority = .high
        EditorAnalysisQueues.waveformDetail.addOperation(operation)
        return covers ? window : overview
    }
}
