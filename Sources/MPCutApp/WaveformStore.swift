import Foundation
import MPCutCore

@MainActor
final class WaveformStore {
    private struct Completed {
        let key: AudioAnalysisCacheKey
        let waveform: AudioWaveform
    }

    let detail = AudioEnvelopeStore()


    private var usesSidecar = true
    private var keys: [UUID: AudioAnalysisCacheKey] = [:]
    private var completedTracks: [UUID: [Int: Completed]] = [:]
    private var jobs: [UUID: EditCancellation] = [:]
    private(set) var waves: [UUID: AudioWaveform] = [:]
    private(set) var finished = Set<UUID>()
    private(set) var issues: [UUID: String] = [:]
    var changed: ((_ completed: Bool) -> Void)?

    func update(sources: [UUID: MediaInfo], track: Int, useSidecar: Bool = true) {
        if usesSidecar != useSidecar {
            for id in Array(jobs.keys) { forget(id) }
            usesSidecar = useSidecar
        }
        detail.changed = { [weak self] in self?.changed?(false) }
        detail.update(sources: sources, track: track, readSidecars: useSidecar)
        completedTracks = completedTracks.filter { sources[$0.key] != nil }
        for id in Array(keys.keys) where sources[id] == nil { forget(id) }
        for (id, media) in sources {
            let tracks = media.streams.filter { $0.kind == "audio" }
            guard tracks.indices.contains(track) else { forget(id); continue }
            let stream = tracks[track].index
            let key = AudioAnalysisCacheKey(media: media, stream: stream)
            guard keys[id] != key else { continue }
            forget(id)
            keys[id] = key
            if let previous = completedTracks[id]?[stream], previous.key == key {
                waves[id] = previous.waveform
                finished.insert(id)
                continue
            }
            let token = EditCancellation()
            jobs[id] = token
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
        detail.update(sources: [:], track: 0, readSidecars: false)
        for id in Array(keys.keys) { forget(id) }
        completedTracks.removeAll()
    }
}
