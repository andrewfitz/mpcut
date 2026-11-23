import Combine
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

enum WaveformSurface: Hashable {
    case viewer, timeline(UUID), multicam(RationalTime, laneID: String? = nil), cutPreview(Int)
}

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

typealias AudioEnvelopeStore = WaveformEnvelopeStore<UUID>

@MainActor
final class WaveformEnvelopeStore<Source: Hashable & Sendable>: ObservableObject {
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
    @MainActor private final class Job {
        let request: Request
        let token = EditCancellation()
        var consumers: Set<Key>
        var sparse: SparseWaveform?

        init(_ request: Request, for key: Key) {
            self.request = request
            consumers = [key]
        }
    }
    private struct Key: Hashable {
        let id: Source
        let surface: WaveformSurface
    }

    private var inputs: [Source: Input] = [:]
    private var visibleOnly = Set<Source>()

    func isVisibleOnly(_ id: Source) -> Bool { visibleOnly.contains(id) }

    func refresh(_ id: Source, media: MediaInfo?, preserving streams: Set<Int>, visibleOnly: Bool) {
        if visibleOnly { self.visibleOnly.insert(id) }
        overviewJobs.removeValue(forKey: id)?.cancel()
        for key in Array(jobs.keys) where key.id == id { releaseJob(for: key) }
        if let before = inputs[id], let media, streams.contains(before.stream) {
            inputs[id] = Input(media: media, stream: before.stream, readSidecars: before.readSidecars)
        } else {
            inputs[id] = nil
            for key in Set(windows.keys).union(failed.keys) where key.id == id {
                windows[key] = nil
                failed[key] = nil
            }
            recentWindows.removeAll { $0.id == id }
        }
        overviews[id] = media.map { media in
            (overviews[id] ?? [:]).filter { streams.contains($0.key) }.map { stream, item in
                (stream, Overview(key: AudioAnalysisCacheKey(media: media, stream: stream), envelope: item.envelope))
            }.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        publishWindowChange()
    }
    private var overviewJobs: [Source: EditCancellation] = [:]
    private var overviews: [Source: [Int: Overview]] = [:]
    private var windows: [Key: DisplayEnvelope] = [:]
    // Keep the onscreen working set and a bounded history for scrolling back.
    private var visibleSurfaces = Set<WaveformSurface>()
    private var timelineSurfacesByLane: [String?: Set<WaveformSurface>] = [:]
    private var recentWindows = RecentKeys<Key>(limit: 256)
    private var jobs: [Key: Job] = [:]
    private var hasUnreportedTimelineJob = false
    private var failed: [Key: Request] = [:]
    var changed: (() -> Void)?
    private(set) var windowRevision = 0
    // A media refresh invalidates all lanes; a completed window only affects its consumers.
    private let changedMulticamLanes = PassthroughSubject<Set<String?>?, Never>()

    func multicamWindowChanges(for laneID: String?) -> AnyPublisher<Int, Never> {
        changedMulticamLanes
            .filter { $0?.contains(laneID) ?? true }
            .compactMap { [weak self] _ in self?.windowRevision }
            .eraseToAnyPublisher()
    }

    private func publishWindowChange(consumers: Set<Key>? = nil) {
        windowRevision &+= 1
        changedMulticamLanes.send(consumers.map { keys in
            keys.reduce(into: Set<String?>()) { lanes, key in
                if case .multicam(_, let laneID) = key.surface { lanes.insert(laneID) }
            }
        })
    }

    func update(sources: [Source: MediaInfo], track: Int, sourceTracks: [Source: Int] = [:], readSidecars: Bool, excludedSources: Set<URL> = []) {
        var selected: [Source: Int] = [:]
        for (id, media) in sources {
            let tracks = media.streams.filter { $0.kind == "audio" }
            let ordinal = sourceTracks[id] ?? track
            if tracks.indices.contains(ordinal) { selected[id] = tracks[ordinal].index }
        }
        update(sources: sources, streams: selected, readSidecars: readSidecars,
               excludedSources: excludedSources, preloadAudioOverviews: true)
    }

    func update(sources: [Source: MediaInfo], streams: [Source: Int], readSidecars: Bool,
                excludedSources: Set<URL>, preloadAudioOverviews: Bool) {
        var current = [Source: Input]()
        for (id, stream) in streams {
            guard let media = sources[id] else { continue }
            current[id] = Input(media: media, stream: stream, readSidecars: readSidecars && !AnalysisSidecar.isExcluded(media.url, in: excludedSources))
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
                releaseJob(for: key)
                windows[key] = nil
                failed[key] = nil
            }
            recentWindows.removeAll { $0.id == id }
            inputs[id] = after
            if preloadAudioOverviews, !visibleOnly.contains(id), let after, !after.media.hasVideo, !after.media.audio.isEmpty, overviews[id]?[after.stream] == nil { loadOverview(id, input: after) }
        }
    }

    private nonisolated static func overviewColumns(_ media: MediaInfo) -> Int {
        Int(max(1, min(Double(AudioEnvelope.maxColumns), ceil(media.duration.seconds * 1_000))))
    }

    private func loadOverview(_ id: Source, input: Input) {
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

    func completed(for id: Source, media: MediaInfo) -> [Int: AudioEnvelope] {
        (overviews[id] ?? [:]).filter { stream, entry in
            entry.key == AudioAnalysisCacheKey(media: media, stream: stream)
        }.mapValues { $0.envelope.samples }
    }

    /// Request detail when a 20 ms peak spans more than one backing pixel.
    static func needsTimelineDetail(secondsPerPixel: Double) -> Bool {
        secondsPerPixel > 0 && secondsPerPixel < 1 / Double(AudioWaveform.rate)
    }

    func setVisibleTimelineSurfaces(_ surfaces: Set<WaveformSurface>, laneID: String? = nil) {
        let before = timelineSurfacesByLane[laneID]
        let changed = before.map { $0 != surfaces } ?? !surfaces.isEmpty
        if changed {
            timelineSurfacesByLane[laneID] = surfaces.isEmpty ? nil : surfaces
            let visible = Set(timelineSurfacesByLane.values.joined())
            if visible != visibleSurfaces {
                let hidden = visibleSurfaces.subtracting(visible)
                visibleSurfaces = visible
                recentWindows.removeAll { visible.contains($0.surface) }
                if !hidden.isEmpty {
                    for key in Set(windows.keys).union(failed.keys) where hidden.contains(key.surface) {
                        touchWindow(key)
                    }
                }
            }
        }
        guard changed || hasUnreportedTimelineJob else { return }
        hasUnreportedTimelineJob = false
        for key in jobs.keys where !visibleSurfaces.contains(key.surface) {
            switch key.surface {
            case .timeline, .multicam:
                releaseJob(for: key)
            case .viewer, .cutPreview: break
            }
        }
    }

    private func registerJob(_ job: Job, for key: Key) {
        jobs[key] = job
        switch key.surface {
        case .timeline, .multicam:
            // Drawing can request a window before it reports the visible surfaces.
            if !visibleSurfaces.contains(key.surface) { hasUnreportedTimelineJob = true }
        case .viewer, .cutPreview: break
        }
    }

    private func releaseJob(for key: Key) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        job.consumers.remove(key)
        if job.consumers.isEmpty { job.token.cancel() }
    }

    func sparseWaveform(for id: Source, surface: WaveformSurface) -> SparseWaveform? {
        jobs[Key(id: id, surface: surface)]?.sparse
    }

    /// Keep a margin around each request so small scrolls reuse the same result.
    func envelope(for id: Source, surface: WaveformSurface, from: Double, to: Double, pixels: Int,
                  showSparseWhileLoading: Bool = false) -> DisplayEnvelope? {
        guard let input = inputs[id], pixels > 0, to.isFinite, from.isFinite else { return nil }
        let start = max(0, from), end = min(input.media.duration.seconds, to)
        guard start < end else { return nil }
        let overview = overviews[id]?[input.stream]?.envelope
        let bin = max(1.0 / Double(max(1, input.media.streams.first(where: { $0.index == input.stream })?.sampleRate ?? 48_000)),
                      (end - start) / Double(min(8_192, pixels)))
        let key = Key(id: id, surface: surface)
        let window = windows[key]
        if window != nil { touchWindow(key) }
        let covers = window.map { $0.samples.from <= start && $0.samples.to >= end } ?? false
        if let window, covers, window.secondsPerBin <= bin * 1.15 {
            releaseJob(for: key)
            return window
        }
        if let overview, overview.secondsPerBin <= bin * 1.15 {
            releaseJob(for: key)
            return overview
        }
        let overviewBin = input.media.duration.seconds / Double(Self.overviewColumns(input.media))
        let waitingForOverview = overviewJobs[id] != nil && overviewBin <= bin * 1.15
        guard !input.media.audio.isEmpty, !waitingForOverview, jobs[key]?.request.covers(start, end, bin) != true,
              failed[key]?.covers(start, end, bin) != true else { return covers ? window : overview }
        // Splits, repeated clips, and the viewer can share the same source window.
        // Check other consumers only on a miss in this surface's own cache.
        releaseJob(for: key)
        if let shared = windows.first(where: { other, value in
            other.id == id && value.samples.from <= start && value.samples.to >= end && value.secondsPerBin <= bin * 1.15
        }) {
            remember(shared.value, for: key)
            return shared.value
        }
        if let shared = jobs.first(where: { $0.key.id == id && $0.value.request.covers(start, end, bin) })?.value {
            shared.consumers.insert(key)
            registerJob(shared, for: key)
            return covers ? window : overview
        }
        let span = end - start
        // A 10 ms view needs a few hundred milliseconds of lookahead to follow playback.
        let padded: Double
        switch surface {
        case .timeline, .multicam:
            padded = min(16_384 * bin, span + min(span, 2))
        case .viewer, .cutPreview:
            padded = min(16_384 * bin, max(0.35, span * 2))
        }
        let margin = max(0, (padded - span) / 2)
        let lower = max(0, start - margin), upper = min(input.media.duration.seconds, end + margin)
        let columns = max(1, min(16_384, Int(ceil((upper - lower) / bin))))
        let request = Request(from: lower, to: upper, bin: (upper - lower) / Double(columns))
        let job = Job(request, for: key)
        let token = job.token
        registerJob(job, for: key)
        let operation = BlockOperation { [weak self] in
            guard !token.isCancelled else { return }
            let data = try? AudioAnalysis.envelope(input.media, stream: input.stream, from: lower, to: upper,
                                                   columns: columns, useSidecar: input.readSidecars, cancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            let result = data.map(DisplayEnvelope.init)
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { return }
                token.cancel() // Stop spot sampling as soon as exact measurements are ready.
                for consumer in job.consumers {
                    self.jobs[consumer] = nil
                    self.remember(result, for: consumer)
                    self.failed[consumer] = result == nil ? request : nil
                }
                self.publishWindowChange(consumers: job.consumers)
                self.changed?()
            }
        }
        operation.queuePriority = .high
        switch surface {
        case .timeline, .multicam:
            // Brief zoom/scroll gestures often replace this request before a decoder needs to open.
            // Short windows decode quickly. Sample only when a refreshed wide view has no usable waveform.
            let wantsSparse = showSparseWhileLoading && visibleOnly.contains(id) && !covers && overview == nil && span >= 60
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(45)) {
                guard !token.isCancelled else { return }
                if wantsSparse, let ordinal = input.media.streams.filter({ $0.kind == "audio" }).firstIndex(where: { $0.index == input.stream }) {
                    EditorAnalysisQueues.openingAudio.addOperation { [weak self] in
                        SparseWaveform.sample(media: input.media, ordinal: ordinal, range: lower..<upper, token: token) { sparse in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !token.isCancelled else { return }
                                job.sparse = sparse
                                self.publishWindowChange(consumers: job.consumers)
                                self.changed?()
                            }
                        }
                    }
                }
                EditorAnalysisQueues.waveformDetail.addOperation(operation)
            }
        case .viewer, .cutPreview:
            EditorAnalysisQueues.waveformDetail.addOperation(operation)
        }
        return covers ? window : overview
    }

    private func remember(_ window: DisplayEnvelope?, for key: Key) {
        windows[key] = window
        touchWindow(key)
    }

    private func touchWindow(_ key: Key) {
        guard !visibleSurfaces.contains(key.surface) else { return }
        if let oldest = recentWindows.use(key) {
            windows[oldest] = nil
            failed[oldest] = nil
        }
    }
}
