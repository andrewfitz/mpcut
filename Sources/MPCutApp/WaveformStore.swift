import Foundation
import MPCutCore

/// Display-only spot measurements. An unread interval stays unknown.
struct SparseWaveform: Sendable {
    let range: Range<Double>
    var peaks: [Float?]

    static func sample(media: MediaInfo, ordinal: Int, range: Range<Double>, token: EditCancellation,
                       publish: (SparseWaveform) -> Void) {
        let duration = range.upperBound - range.lowerBound
        guard duration > 0, duration.isFinite, !token.isCancelled else { return }
        let count = Int(min(24, ceil(duration / 0.04)))
        let step = duration / Double(count)
        var preview = SparseWaveform(range: range, peaks: Array(repeating: nil, count: count))
        let reader = FFPreviewReader(audioOnly: true)
        let deadline = ContinuousClock.now + .milliseconds(650)
        let stop = { token.isCancelled || ContinuousClock.now >= deadline }
        var lastUpdate = ContinuousClock.now
        var dirty = false
        // Sample across the recording first, then fill the intervening buckets if time permits.
        for pass in [0, 2, 1, 3] {
            for i in stride(from: pass, to: count, by: 4) {
                if stop() { break }
                let start = range.lowerBound + (i == 0 ? 0 : (Double(i) + 0.5) * step)
                let grainRange = start..<min(range.upperBound, start + 0.04)
                let grain = try? reader.perform(cancelled: stop) {
                    let samples = try reader.scrubSamples(url: media.url, range: grainRange,
                                                          audioOrigin: media.origin, audioTrack: ordinal)
                    return ScrubGrain(samples: samples, window: grainRange, reverse: false, fadeEdges: false)
                }
                if let grain {
                    preview.peaks[i] = grain.stereo.reduce(Float(0)) { max($0, abs($1)) }
                    dirty = true
                }
                if dirty, i == 0 || lastUpdate.duration(to: .now) >= .milliseconds(65) {
                    publish(preview)
                    lastUpdate = .now
                    dirty = false
                }
            }
        }
        if dirty && !token.isCancelled { publish(preview) }
    }
}

typealias OpeningWaveform = (source: UUID, waveform: SparseWaveform)

@MainActor
final class WaveformStore {
    private struct Completed {
        let key: AudioAnalysisCacheKey
        let waveform: AudioWaveform
    }

    let detail = AudioEnvelopeStore()

    private struct OpeningKey: Equatable {
        let source: UUID
        let identity: SourceIdentity
        let origin: RationalTime
        let duration: RationalTime
        let ordinal: Int
    }
    private var openingKey: OpeningKey?
    private var openingJob: EditCancellation?
    private(set) var openingWaveform: OpeningWaveform?

    private var visibleOnly = Set<UUID>()

    func refresh(_ id: UUID, media: MediaInfo?, preserving streams: Set<Int>) {
        visibleOnly.insert(id)
        forget(id)
        if openingKey?.source == id { clearOpeningPreview() }
        if let media {
            completedTracks[id] = Dictionary(uniqueKeysWithValues: (completedTracks[id] ?? [:]).compactMap { stream, item in
                guard streams.contains(stream) else { return nil }
                return (stream, Completed(key: AudioAnalysisCacheKey(media: media, stream: stream),
                                          waveform: item.waveform.forRefreshedMedia(media, stream: stream)))
            })
        } else { completedTracks[id] = nil }
        detail.refresh(id, media: media, preserving: streams, visibleOnly: true)
    }

    func allowOverviews(_ sources: Set<UUID>) {
        for id in visibleOnly.intersection(sources) where !finished.contains(id) { forget(id) }
        visibleOnly.subtract(sources)
    }

    private var usesSidecar = true
    private var exclusions: Set<URL> = []
    private var keys: [UUID: AudioAnalysisCacheKey] = [:]
    private var completedTracks: [UUID: [Int: Completed]] = [:]
    private var jobs: [UUID: EditCancellation] = [:]
    private(set) var waves: [UUID: AudioWaveform] = [:]
    private(set) var finished = Set<UUID>()
    private(set) var issues: [UUID: String] = [:]
    var changed: ((_ completed: Bool) -> Void)?

    func update(sources: [UUID: MediaInfo], track: Int, sourceTracks: [UUID: Int] = [:], useSidecar: Bool = true,
                excludedSources: Set<URL> = [], opening: (id: UUID, media: MediaInfo, ordinal: Int)? = nil) {
        if let opening {
            startOpeningPreview(id: opening.id, media: opening.media, ordinal: opening.ordinal)
        } else if let key = openingKey {
            let media = sources[key.source]
            if media?.identity != key.identity || media?.origin != key.origin || media?.duration != key.duration ||
                (sourceTracks[key.source] ?? track) != key.ordinal { clearOpeningPreview() }
        }
        if usesSidecar != useSidecar {
            for id in Array(jobs.keys) { forget(id) }
            usesSidecar = useSidecar
        }
        if exclusions != excludedSources {
            for (id, media) in sources where AnalysisSidecar.isExcluded(media.url, in: exclusions) != AnalysisSidecar.isExcluded(media.url, in: excludedSources) {
                forget(id)
            }
            exclusions = excludedSources
        }
        detail.changed = { [weak self] in self?.changed?(false) }
        detail.update(sources: sources, track: track, sourceTracks: sourceTracks, readSidecars: useSidecar, excludedSources: excludedSources)
        completedTracks = completedTracks.filter { sources[$0.key] != nil }
        for id in Array(keys.keys) where sources[id] == nil { forget(id) }
        for (id, media) in sources {
            let tracks = media.streams.filter { $0.kind == "audio" }
            let track = sourceTracks[id] ?? track
            guard tracks.indices.contains(track) else { forget(id); continue }
            let stream = tracks[track].index
            let key = AudioAnalysisCacheKey(media: media, stream: stream)
            guard keys[id] != key else { continue }
            forget(id)
            keys[id] = key
            if let previous = completedTracks[id]?[stream], previous.key == key {
                if openingKey?.source == id { clearOpeningPreview() }
                waves[id] = previous.waveform
                finished.insert(id)
                continue
            }
            guard !visibleOnly.contains(id) else { continue }
            let useSidecar = useSidecar && !AnalysisSidecar.isExcluded(media.url, in: excludedSources)
            let token = EditCancellation()
            jobs[id] = token
            let media = useSidecar ? media.pinningSidecarWrites() : media
            EditorAnalysisQueues.scans.addOperation { [weak self] in
                guard !token.isCancelled else { return }
                do {
                    let wave = try AudioAnalysis.scan(media, stream: stream, useSidecar: useSidecar, cancelled: { token.isCancelled }) { partial in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.jobs[id] === token else { return }
                            self.waves[id] = partial
                            self.changed?(false)
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.jobs[id] === token else { return }
                        self.jobs[id] = nil
                        if self.openingKey?.source == id { self.clearOpeningPreview() }
                        self.waves[id] = wave
                        self.completedTracks[id, default: [:]][stream] = Completed(key: key, waveform: wave)
                        self.finished.insert(id)
                        self.changed?(true)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.jobs[id] === token else { return }
                        self.jobs[id] = nil
                        self.waves[id] = nil
                        self.issues[id] = error.localizedDescription
                        self.changed?(true)
                    }
                }
            }
        }
    }

    private func startOpeningPreview(id: UUID, media: MediaInfo, ordinal: Int) {
        let key = OpeningKey(source: id, identity: media.identity, origin: media.origin, duration: media.duration, ordinal: ordinal)
        guard key != openingKey, media.duration > .zero else { return }
        clearOpeningPreview()
        openingKey = key
        let token = EditCancellation()
        openingJob = token
        EditorAnalysisQueues.openingAudio.addOperation { [weak self] in
            SparseWaveform.sample(media: media, ordinal: ordinal, range: 0..<media.duration.seconds, token: token) { preview in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.openingJob === token else { return }
                    self.openingWaveform = (id, preview)
                    self.changed?(false)
                }
            }
        }
    }

    private func clearOpeningPreview() {
        openingJob?.cancel()
        openingJob = nil
        openingKey = nil
        openingWaveform = nil
    }

    func completedWaveforms(for id: UUID, media: MediaInfo) -> [Int: AudioWaveform] {
        (completedTracks[id] ?? [:]).filter { stream, entry in
            entry.key == AudioAnalysisCacheKey(media: media, stream: stream)
        }.mapValues(\.waveform)
    }

    func completedEnvelope(for id: UUID, media: MediaInfo) -> [Int: AudioEnvelope] {
        detail.completed(for: id, media: media)
    }

    func retryFailures() {
        for id in Array(issues.keys) { forget(id) }
    }

    private func forget(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel()
        keys[id] = nil
        waves[id] = nil
        finished.remove(id)
        issues[id] = nil
    }

    func clear() {
        clearOpeningPreview()
        detail.update(sources: [:], track: 0, readSidecars: false)
        for id in Array(keys.keys) { forget(id) }
        completedTracks.removeAll()
        visibleOnly.removeAll()
    }
}
