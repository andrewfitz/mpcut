import Foundation
import MPCutCore

enum SidecarContent: String, CaseIterable {
    case index, scenes, audio
}

struct SidecarInventory: Encodable {
    struct Silence: Encodable {
        let stream: Int
        let thresholdMode: SilenceThresholdMode
        let thresholdDB: Double?
        let minimumPause: Double
    }

    let hasIndex: Bool
    let hasScenes: Bool
    let waveformStreams: [Int]
    let envelopeStreams: [Int]?
    let thumbnailCount: Int
    let silence: [Silence]

    init(sections: [String]) {
        hasIndex = AnalysisSidecar.indexKeys.isSubset(of: Set(sections))
        hasScenes = sections.contains(AnalysisSidecar.sceneSectionKey)
        waveformStreams = sections.compactMap(AnalysisSidecar.savedWaveformStream(forKey:)).sorted()
        let envelopes = sections.compactMap(AnalysisSidecar.savedEnvelopeStream(forKey:)).sorted()
        envelopeStreams = envelopes.isEmpty ? nil : envelopes
        thumbnailCount = sections.lazy.filter { $0.hasPrefix("filmstrip.v1.") }.count
        silence = sections.compactMap { key -> Silence? in
            guard let settings = AnalysisSidecar.savedSilenceSettings(forKey: key) else { return nil }
            return Silence(stream: settings.stream, thresholdMode: settings.thresholdDB == nil ? .auto : .manual,
                           thresholdDB: settings.thresholdDB, minimumPause: settings.minimum)
        }.sorted {
            ($0.stream, $0.minimumPause, $0.thresholdDB ?? -.infinity) <
            ($1.stream, $1.minimumPause, $1.thresholdDB ?? -.infinity)
        }
    }
}

struct SidecarResult: Encodable {
    let ok = true
    let file: String
    let sidecar: String
    let status: String
    let sections: [String]
    let saved: [String]?
    let inventory: SidecarInventory

    init(file: String, sidecar: String, status: String, sections: [String], saved: [String]?) {
        self.file = file
        self.sidecar = sidecar
        self.status = status
        self.sections = sections
        self.saved = saved
        inventory = SidecarInventory(sections: sections)
    }
}

struct SidecarOptions {
    let file: String
    let statusOnly: Bool
    let contents: Set<SidecarContent>
    let explicitSections: Bool
    let minimum: Double
    let threshold: Double?
    let audioStream: Int?

    init(_ arguments: [String]) throws {
        var flags = Set<String>()
        var selected = Set(SidecarContent.allCases)
        var minimum = 1.5
        var threshold: Double?
        var stream: Int?
        var source: String?
        var positional = false
        var iterator = arguments.makeIterator()
        func invalid(_ reason: String) -> CLIError { CLIError("invalid_arguments", reason) }
        while let word = iterator.next() {
            if positional || !word.hasPrefix("-") {
                guard source == nil else { throw invalid("Sidecar accepts one source file.") }
                source = word
                continue
            }
            guard flags.insert(word).inserted else { throw invalid("Duplicate sidecar option \(word).") }
            func value() throws -> String {
                guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw invalid("Missing value for \(word).")
                }
                return value
            }
            switch word {
            case "--": positional = true
            case "--status", "--json": break
            case "--only", "--only-file":
                guard !flags.isSuperset(of: ["--only", "--only-file"]) else { throw invalid("Choose one section list.") }
                let raw = try value()
                let list = word == "--only-file" || ListFile.isListPath(raw) ? try ListFile.scalars(raw, header: "section") : raw.components(separatedBy: ",")
                selected.removeAll()
                for token in list {
                    guard let section = SidecarContent(rawValue: String(token)), selected.insert(section).inserted else {
                        throw invalid("--only accepts a comma-separated selection of index, scenes, and audio.")
                    }
                }
            case "--min-pause":
                guard let number = Double(try value()), number.isFinite, number > 0 else {
                    throw invalid("--min-pause requires a positive number of seconds.")
                }
                minimum = number
            case "--stream":
                guard let index = Int(try value()), index >= 0 else {
                    throw invalid("--stream requires a nonnegative audio stream index.")
                }
                stream = index
            case "--threshold-db":
                guard let number = Double(try value()), (-120.0...0.0).contains(number) else {
                    throw invalid("--threshold-db accepts −120 to 0 dBFS.")
                }
                threshold = number
            default:
                throw invalid("Unknown sidecar option '\(word)'.")
            }
        }
        guard let source else { throw invalid("Sidecar requires a source media file.") }
        if flags.contains("--status"), !flags.isDisjoint(with: ["--only", "--only-file", "--min-pause", "--threshold-db", "--stream"]) {
            throw invalid("Analysis settings apply when saving a sidecar.")
        }
        if !selected.contains(.audio), !flags.isDisjoint(with: ["--min-pause", "--threshold-db", "--stream"]) {
            throw invalid("Silence settings require the audio section.")
        }
        self.file = source
        self.statusOnly = flags.contains("--status")
        self.contents = selected
        self.explicitSections = (flags.contains("--only") || flags.contains("--only-file"))
        self.minimum = minimum
        self.threshold = threshold
        self.audioStream = stream
    }

    func run(source: URL, cancelled: @escaping @Sendable () -> Bool) async throws -> SidecarResult {
        let store = try AnalysisSidecar(source: source)
        if statusOnly {
            return SidecarResult(file: source.path, sidecar: store.url.path,
                                 status: store.status(), sections: store.keys().sorted(), saved: nil)
        }
        let sections: [String: Data]
        if contents == [.scenes] {
            sections = try AnalysisSidecar.sceneSections(for: SceneAnalysis.scan(source, cancelled: cancelled))
        } else {
            sections = try await indexedSections(source: source, cancelled: cancelled)
        }
        guard !sections.isEmpty else {
            throw CutError(code: "no_audio", message: "There are no audio streams to save in this source.")
        }
        try store.save(sections, cancelled: cancelled)
        let keys = AnalysisSidecar.$readsEnabled.withValue(true) { store.keys().sorted() }
        return SidecarResult(file: source.path, sidecar: store.url.path,
                             status: store.status(), sections: keys, saved: sections.keys.sorted())
    }

    private func indexedSections(source: URL, cancelled: @escaping @Sendable () -> Bool) async throws -> [String: Data] {
        let engine = CutEngine(cancelled: cancelled)
        let media = try contents.contains(.index) ? engine.inspect(source, keyframes: true) : engine.inspectForAudioAnalysis(source)
        let tracks = media.streams.filter { $0.kind == "audio" && (audioStream == nil || $0.index == audioStream) }
        if audioStream != nil, tracks.isEmpty {
            throw CutError(code: "no_audio", message: "The source has no matching audio stream.")
        }
        if explicitSections && contents.contains(.scenes) && !media.hasVideo {
            throw CutError(code: "no_video", message: "Scene analysis requires a video stream.")
        }
        @Sendable func sceneSections() throws -> [String: Data] {
            guard contents.contains(.scenes), media.hasVideo else { return [:] }
            let stop: @Sendable () -> Bool = { Task.isCancelled || cancelled() }
            let scenes = try SceneAnalysis.scan(media, cancelled: stop)
            return try AnalysisSidecar.sections(media: media, scenes: scenes, cancelled: stop)
        }
        async let sceneData = sceneSections()
        var sections: [String: Data] = [:]
        if contents.contains(.index) {
            sections = try AnalysisSidecar.indexSections(for: media, cancelled: cancelled)
        }
        if contents.contains(.audio) {
            @Sendable func audioSections(_ track: StreamInfo) throws -> [String: Data] {
                let stop: @Sendable () -> Bool = { Task.isCancelled || cancelled() }
                let wave = try AudioAnalysis.scan(media, stream: track.index, cancelled: stop)
                let silence = try AudioAnalysis.silence(media, stream: track.index, thresholdDB: threshold,
                                                        minimum: minimum, waveform: wave, cancelled: stop)
                var overviews: [Int: AudioEnvelope] = [:]
                if !media.hasVideo {
                    overviews[track.index] = try AnalysisSidecar(media: media).envelopeOverview(for: media, stream: track.index,
                                                                                               cancelled: stop)
                        ?? AudioAnalysis.envelope(media, stream: track.index, from: 0, to: media.duration.seconds,
                                                  columns: AudioEnvelope.maxColumns, cancelled: stop)
                }
                return try AnalysisSidecar.sections(media: media, waveforms: [track.index: wave],
                                                   envelopeOverviews: overviews, silence: [silence],
                                                   cancelled: stop)
            }
            // Independent tracks retain their own decoder history, thresholds and clocks.
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let threadedFLAC = media.duration.seconds >= 60 && tracks.contains { $0.codec == "flac" }
            let workers = min(4, tracks.count, max(1, cores / (threadedFLAC ? 8 : 1)))
            try await withThrowingTaskGroup(of: [String: Data].self) { group in
                var remaining = tracks.makeIterator()
                for _ in 0..<workers {
                    if let track = remaining.next() {
                        group.addTask { try audioSections(track) }
                    }
                }
                while let audio = try await group.next() {
                    sections.merge(audio) { _, new in new }
                    if let track = remaining.next() {
                        group.addTask { try audioSections(track) }
                    }
                }
            }
        }
        sections.merge(try await sceneData) { _, new in new }
        return sections
    }
}
