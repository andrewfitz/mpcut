import Foundation

/// The exact presentation clock used when measuring this track. Preview timing
/// and a fully indexed MOV with audio edits can differ for the same source.
struct AudioAnalysisClock: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case stream, duration, origin, indexed
        case usesPresentationEdits = "uses_presentation_edits"
    }

    let stream: Int
    let duration: RationalTime
    let origin: RationalTime
    let indexed: Bool
    let usesPresentationEdits: Bool

    init(media: MediaInfo, stream: Int) {
        self.stream = stream
        duration = media.duration
        origin = media.origin
        indexed = media.audio.contains { $0.stream.index == stream }
        usesPresentationEdits = media.requiresPresentationAudioAnalysis(stream: stream)
    }
}

/// Identifies an in-memory result independently of a clip's editor UUID.
package struct AudioAnalysisCacheKey: Equatable, Sendable {
    private let identity: SourceIdentity
    private let changeTime: SourceIdentity.ChangeTime?
    private let clock: AudioAnalysisClock

    package init(media: MediaInfo, stream: Int) {
        identity = media.identity
        changeTime = media.identity.changeTime
        clock = AudioAnalysisClock(media: media, stream: stream)
    }
}

public struct SilenceAnalysisResult: Codable, Sendable {
    public let stream: Int
    public let requestedThresholdDB: Double?
    public let minimum: Double
    public let automaticThresholdDB: Double
    public let pauses: [AudioSpan]
    let runs: SilenceRuns
    package func pauses(maxBlip: Double) -> [AudioSpan] {
        if maxBlip == AudioWaveform.defaultMaxBlip { return pauses }
        return runs.pauses(minimum: minimum, maxBlip: maxBlip)
    }

    public var thresholdDB: Double { requestedThresholdDB ?? automaticThresholdDB }
    fileprivate var sourceIdentity: SourceIdentity?
    fileprivate var sourceClock: AudioAnalysisClock?
    fileprivate var hasSourceCalibration = true

    /// Use after refresh has verified the result's audio stream and presentation clock.
    package func forRefreshedMedia(_ media: MediaInfo) -> SilenceAnalysisResult {
        let clock = AudioAnalysisClock(media: media, stream: stream)
        guard sourceClock == clock else { return self }
        var result = self
        result.sourceIdentity = media.identity
        result.sourceClock = clock
        return result
    }

    enum CodingKeys: String, CodingKey {
        case stream = "audio_stream_index"
        case requestedThresholdDB = "silence_threshold_db"
        case minimum = "silence_min_pause_seconds"
        case automaticThresholdDB = "silence_automatic_threshold_db"
        case pauses, runs
    }

    init(media: MediaInfo, stream: Int, requestedThresholdDB: Double?, minimum: Double,
                     automaticThresholdDB: Double, pauses: [AudioSpan], runs: SilenceRuns) {
        self.stream = stream
        self.requestedThresholdDB = requestedThresholdDB
        self.minimum = minimum
        self.automaticThresholdDB = automaticThresholdDB
        self.pauses = pauses
        self.runs = runs
        sourceIdentity = media.identity
        sourceClock = AudioAnalysisClock(media: media, stream: stream)
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_sidecar_analysis")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stream = try values.decode(Int.self, forKey: .stream)
        requestedThresholdDB = try values.decodeIfPresent(Double.self, forKey: .requestedThresholdDB)
        minimum = try values.decode(Double.self, forKey: .minimum)
        automaticThresholdDB = try values.decode(Double.self, forKey: .automaticThresholdDB)
        let cancelled = decoder.userInfo[silenceCancellationKey] as? () -> Bool
        var saved = try values.nestedUnkeyedContainer(forKey: .pauses)
        var spans: [AudioSpan] = []
        while !saved.isAtEnd {
            if saved.currentIndex.isMultiple(of: 256), cancelled?() == true { throw CancellationError() }
            spans.append(try saved.decode(AudioSpan.self))
        }
        pauses = spans
        runs = try values.decode(SilenceRuns.self, forKey: .runs)
    }
}

private let silenceCancellationKey = CodingUserInfoKey(rawValue: "mpcut.silence.cancelled")!

private struct CachedAudio<Value: Codable>: Codable {
    let clock: AudioAnalysisClock
    let value: Value
}

// The display overview has a fixed upper bound. Store planar float bytes so a
// minute-long and a day-long overview cost the same at the same display resolution.
private struct CachedEnvelope: Codable {
    let low: Data
    let high: Data

    init(_ overview: AudioEnvelope) {
        low = overview.low.withUnsafeBytes { Data($0) }
        high = overview.high.withUnsafeBytes { Data($0) }
    }

    func overview(duration: Double) -> AudioEnvelope? {
        let stride = MemoryLayout<Float>.stride
        guard low.count == high.count, low.count.isMultiple(of: stride),
              (1...AudioEnvelope.maxColumns).contains(low.count / stride) else { return nil }
        func floats(_ data: Data) -> [Float] {
            var values = [Float](repeating: 0, count: data.count / stride)
            _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return values
        }
        let minima = floats(low), maxima = floats(high)
        guard zip(minima, maxima).allSatisfy({ $0.isFinite && $1.isFinite && $0 <= $1 }) else { return nil }
        return AudioEnvelope(from: 0, to: duration, low: minima, high: maxima)
    }
}

private struct CachedScenes: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case origin, duration, markers
        case timeBase = "time_base"
    }

    struct Marker: Codable, Equatable {
        let pts: Int64
        let view: Int
    }

    let origin: RationalTime
    let duration: RationalTime
    let timeBase: RationalTime
    let markers: [Marker]

    init(_ report: SceneReport) {
        origin = report.origin
        duration = report.duration
        timeBase = report.timeBase
        markers = report.scenes.map { Marker(pts: $0.startPTS, view: $0.view) }
    }

    func report(source: URL, identity: SourceIdentity, names: [Int: String], cancelled: () -> Bool) throws -> SceneReport? {
        guard timeBase > .zero, duration > .zero, !markers.isEmpty else { return nil }
        var groups: [[Int]] = []
        var labels: [String] = []
        var scenes: [DetectedScene] = []
        scenes.reserveCapacity(markers.count)
        func relativeTime(_ pts: Int64) throws -> RationalTime {
            try RationalTime(numerator: pts).multiplied(by: timeBase).subtracting(origin)
        }
        var start = RationalTime.zero
        for (index, marker) in markers.enumerated() {
            if index.isMultiple(of: 1024), cancelled() { return nil }
            let end = index + 1 < markers.count ? try relativeTime(markers[index + 1].pts) : duration
            guard marker.pts != .min, start < end, end <= duration,
                  marker.view > 0, marker.view <= groups.count + 1 else { return nil }
            if marker.view > groups.count {
                groups.append([])
                labels.append(SceneView.label(for: marker.view))
            }
            groups[marker.view - 1].append(index + 1)
            scenes.append(DetectedScene(number: index + 1, startPTS: marker.pts, start: start,
                                        startSeconds: start.seconds, end: end, view: marker.view,
                                        viewLabel: labels[marker.view - 1]))
            start = end
        }
        let views = groups.indices.map { index in
            let id = index + 1
            let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SceneView(view: id, label: labels[index], sceneNumbers: groups[index],
                             name: name?.isEmpty == false ? name : nil)
        }
        return SceneReport(file: source.path, sourceStamp: SceneSourceStamp(identity: identity),
                           timeBase: timeBase, origin: origin, duration: duration, scenes: scenes,
                           viewCount: views.count, views: views)
    }
}

private func silenceKey(stream: Int, thresholdDB: Double?, minimum: Double) -> String {
    // Exact floating-point settings, independent of locale or display precision.
    let threshold = thresholdDB.map { String(($0 == 0 ? 0.0 : $0).bitPattern, radix: 16) } ?? "auto"
    return "silence_pauses.v1.\(stream).\(threshold).\(String(minimum.bitPattern, radix: 16))"
}

private func valid(_ result: SilenceAnalysisResult, for media: MediaInfo, cancelled: () -> Bool) -> Bool {
    guard media.streams.contains(where: { $0.index == result.stream && $0.kind == "audio" }),
          result.minimum.isFinite, result.minimum > 0, (-120...0).contains(result.thresholdDB),
          (-120...0).contains(result.automaticThresholdDB) else { return false }
    func validSpans(_ spans: [AudioSpan], minimum: Double) -> Bool {
        var previous = RationalTime.zero
        for (index, span) in spans.enumerated() {
            if index.isMultiple(of: 256), cancelled() { return false }
            guard span.from >= previous, span.to > span.from, span.to <= media.duration,
                  let duration = try? span.to.subtracting(span.from), duration.seconds >= minimum else { return false }
            previous = span.to
        }
        return true
    }
    guard validSpans(result.pauses, minimum: result.minimum) else { return false }
    let runs = result.runs
    return validSpans(runs.quiet, minimum: 0) && validSpans(runs.covered, minimum: 0)
}

extension AnalysisSidecar {
    // Revise these together when detection can change marker timing or view IDs.
    public static let sceneSectionKey = "scenes_boundaries.v1"
    public static let viewNameSectionKey = "scenes_view_names.v1"

    public static func savedSilenceSettings(forKey key: String) -> (stream: Int, thresholdDB: Double?, minimum: Double)? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "silence_pauses", parts[1] == "v1", let stream = Int(parts[2]), stream >= 0,
              let bits = UInt64(parts[4], radix: 16) else { return nil }
        let minimum = Double(bitPattern: bits)
        guard minimum.isFinite, minimum > 0 else { return nil }
        let threshold: Double?
        if parts[3] == "auto" {
            threshold = nil
        } else {
            guard let bits = UInt64(parts[3], radix: 16), (-120...0).contains(Double(bitPattern: bits)) else { return nil }
            threshold = Double(bitPattern: bits)
        }
        guard silenceKey(stream: stream, thresholdDB: threshold, minimum: minimum) == key else { return nil }
        return (stream, threshold, minimum)
    }

    public static func savedWaveformStream(forKey key: String) -> Int? {
        guard key.hasPrefix("waveform_peaks.v1."), let stream = Int(key.dropFirst("waveform_peaks.v1.".count)), stream >= 0,
              key == "waveform_peaks.v1.\(stream)" else { return nil }
        return stream
    }

    public static func savedEnvelopeStream(forKey key: String) -> Int? {
        guard key.hasPrefix("waveform_envelope.v1."), let stream = Int(key.dropFirst("waveform_envelope.v1.".count)),
              stream >= 0, key == "waveform_envelope.v1.\(stream)" else { return nil }
        return stream
    }

    public static func sceneSections(for report: SceneReport) throws -> [String: Data] {
        guard report.scenes.first?.start == .zero, report.scenes.last?.end == report.duration else {
            throw CutError(code: "invalid_sidecar_analysis", message: "Full-source scene boundaries require a report covering the entire recording.")
        }
        return [sceneSectionKey: try JSONEncoder().encode(CachedScenes(report))]
    }

    /// Names use source-local view IDs. Saving an empty map also clears
    /// earlier names when the user has restored all defaults.
    public static func viewNameSections(_ names: [Int: String], for report: SceneReport) throws -> [String: Data] {
        [viewNameSectionKey: try viewNameData(names, for: report)]
    }

    public static func viewNameData(_ names: [Int: String], for report: SceneReport) throws -> Data {
        guard names.keys.allSatisfy({ $0 > 0 && $0 <= report.viewCount }) else {
            throw CutError(code: "invalid_sidecar_analysis", message: "The view names refer to a different scene report.")
        }
        let cleaned = names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                           .filter { !$0.value.isEmpty }
        return try JSONEncoder().encode(cleaned)
    }

    private func viewNames(read: (String) -> Data?) -> [Int: String]? {
        guard let data = read(Self.viewNameSectionKey) else { return nil }
        return try? JSONDecoder().decode([Int: String].self, from: data)
    }

    func restoringViewNames(to report: SceneReport, cancelled: () -> Bool) -> SceneReport {
        guard report.sourceStamp == SceneSourceStamp(identity: identity) else { return report }
        return (try? withReadSnapshot(cancelled: cancelled) { read in
            guard let names = viewNames(read: read) else { return report }
            var updated = report
            updated.restoreViewNames(names)
            return updated
        }) ?? report
    }

    /// A scene-only lookup reads the marker section and constructs the same report
    /// as a decode, without loading the source index, audio, or unrelated tracks.
    public func sceneReport(cancelled: () -> Bool = { Task.isCancelled }) -> SceneReport? {
        try? withReadSnapshot(cancelled: cancelled) { read in
            try decodeSceneReport(read: read, cancelled: cancelled)
        }
    }

    func sceneSectionMatches(_ data: Data, replacement: Data, cancelled: () -> Bool) -> Bool {
        let decoder = JSONDecoder()
        guard let cached = try? decoder.decode(CachedScenes.self, from: data),
              let rebuilt = try? decoder.decode(CachedScenes.self, from: replacement),
              cached.timeBase == rebuilt.timeBase, cached.duration == rebuilt.duration,
              cached.origin == rebuilt.origin else { return false }
        return (try? cached.report(source: source, identity: identity, names: [:], cancelled: cancelled)) != nil
    }

    private func decodeSceneReport(read: (String) -> Data?, cancelled: () -> Bool) throws -> SceneReport? {
        guard let data = read(Self.sceneSectionKey),
              let cached = try? JSONDecoder().decode(CachedScenes.self, from: data)
        else { return nil }
        let names = viewNames(read: read)
        return try cached.report(source: source, identity: identity, names: names ?? [:], cancelled: cancelled)
    }

    public func sceneReport(for media: MediaInfo, cancelled: () -> Bool = { Task.isCancelled }) -> SceneReport? {
        guard media.hasVideo, identity.matchesSnapshot(media.identity) else { return nil }
        return matchingSceneReport(sceneReport(cancelled: cancelled), media: media)
    }

    private func matchingSceneReport(_ report: SceneReport?, media: MediaInfo) -> SceneReport? {
        guard let report, report.timeBase == media.video.timeBase, report.duration == media.duration,
              report.origin == media.origin else { return nil }
        return report
    }

    package func editorMetadata(for media: MediaInfo, cancelled: () -> Bool) -> (SceneReport?, [Int: Double])? {
        guard identity.matchesSnapshot(media.identity) else { return nil }
        return try? withReadSnapshot(cancelled: cancelled) { read in
            let report = media.hasVideo
                ? matchingSceneReport(try? decodeSceneReport(read: read, cancelled: cancelled), media: media)
                : nil
            let thresholds = read(AnalysisSidecar.silenceThresholdOverridesKey).flatMap {
                try? JSONDecoder().decode([Int: Double].self, from: $0)
            } ?? [:]
            return (report, thresholds)
        }
    }

    private func audioRecord<Value: Codable>(_ type: Value.Type, key: String, media: MediaInfo,
                                             stream: Int, maxBytes: Int? = nil,
                                             cancelled: @escaping () -> Bool = { Task.isCancelled }) -> Value? {
        let clock = AudioAnalysisClock(media: media, stream: stream)
        guard media.identity.matchesSnapshot(identity), clock.indexed, !cancelled(),
              let data = read(key, maxBytes: maxBytes, cancelled: cancelled), !cancelled() else { return nil }
        let decoder = PropertyListDecoder()
        decoder.userInfo[silenceCancellationKey] = cancelled
        guard let record = try? decoder.decode(CachedAudio<Value>.self, from: data),
              record.clock == clock, !cancelled() else { return nil }
        return record.value
    }

    public func waveform(for media: MediaInfo, stream: Int, cancelled: @escaping () -> Bool = { Task.isCancelled }) -> AudioWaveform? {
        let bins = ceil(media.duration.seconds * Double(AudioWaveform.rate)) + 1
        // Include space for the clock and binary property list metadata.
        guard let maxBytes = Int(exactly: bins * Double(MemoryLayout<Float>.stride) + 4096),
              let bytes = audioRecord(Data.self, key: "waveform_peaks.v1.\(stream)", media: media,
                                     stream: stream, maxBytes: maxBytes, cancelled: cancelled) else { return nil }
        return AudioWaveform(peakBytes: bytes, media: media, stream: stream, cancelled: cancelled)
    }

    public func envelopeOverview(for media: MediaInfo, stream: Int, cancelled: @escaping () -> Bool = { Task.isCancelled }) -> AudioEnvelope? {
        let maxBytes = AudioEnvelope.maxColumns * 2 * MemoryLayout<Float>.stride + 4096
        guard let saved = audioRecord(CachedEnvelope.self, key: "waveform_envelope.v1.\(stream)", media: media,
                                      stream: stream, maxBytes: maxBytes, cancelled: cancelled),
              var overview = saved.overview(duration: media.duration.seconds), !cancelled() else { return nil }
        overview.sourceIdentity = media.identity
        overview.analysisClock = AudioAnalysisClock(media: media, stream: stream)
        return overview
    }

    /// Save prepared analysis and metadata together. Another writer may have
    /// published a finer whole-track overview since these sections were prepared.
    package func saveAnalysisSections(_ sections: [String: Data], updating: [String: (Data?) throws -> Data] = [:],
                                      retainingLatest: [String: Int] = [:], cancelled: () -> Bool = { false }) throws {
        var replacements = sections
        var updates = updating
        for (key, data) in sections where Self.savedEnvelopeStream(forKey: key) != nil {
            guard updates[key] == nil else {
                throw CutError(code: "invalid_sidecar_analysis", message: "Two updates target the same waveform overview.")
            }
            replacements.removeValue(forKey: key)
            updates[key] = { current in
                guard let current, current != data else { return data }
                let decoder = PropertyListDecoder()
                guard let saved = try? decoder.decode(CachedAudio<CachedEnvelope>.self, from: current),
                      let incoming = try? decoder.decode(CachedAudio<CachedEnvelope>.self, from: data),
                      saved.clock == incoming.clock,
                      saved.value.low.count >= incoming.value.low.count,
                      saved.value.overview(duration: saved.clock.duration.seconds) != nil else { return data }
                return current
            }
        }
        try save(replacements, updating: updates, retainingLatest: retainingLatest, cancelled: cancelled)
    }

    func saveOverviewAutomatically(_ overview: AudioEnvelope, for media: MediaInfo, stream: Int,
                                   cancelled: () -> Bool) {
        guard Self.readsEnabled, Self.automaticWritesEnabled, !isExcluded, !cancelled() else { return }
        let sections = try? Self.sections(media: media, envelopeOverviews: [stream: overview], cancelled: cancelled)
        if let sections { try? saveAnalysisSections(sections, cancelled: cancelled) }
    }

    public func automaticThresholdDB(for media: MediaInfo, stream: Int, cancelled: @escaping () -> Bool = { Task.isCancelled }) -> Double? {
        guard let db = audioRecord(Double.self, key: "silence_automatic_threshold_db.v1.\(stream)", media: media, stream: stream, cancelled: cancelled),
              (-120...0).contains(db) else { return nil }
        return db
    }

    public func silence(for media: MediaInfo, stream: Int, thresholdDB: Double?, minimum: Double,
                        cancelled: @escaping () -> Bool = { Task.isCancelled }) -> SilenceAnalysisResult? {
        let key = silenceKey(stream: stream, thresholdDB: thresholdDB, minimum: minimum)
        guard var result = audioRecord(SilenceAnalysisResult.self, key: key, media: media, stream: stream, cancelled: cancelled),
              result.stream == stream, result.requestedThresholdDB == thresholdDB, result.minimum == minimum,
              valid(result, for: media, cancelled: cancelled) else { return nil }
        result.sourceIdentity = identity
        result.sourceClock = AudioAnalysisClock(media: media, stream: stream)
        return result
    }

    /// Encode completed analyses for the storage layer's atomic multi-section save.
    public static func sections(media: MediaInfo, scenes: SceneReport? = nil, waveforms: [Int: AudioWaveform] = [:],
                                envelopeOverviews: [Int: AudioEnvelope] = [:],
                                silence: [SilenceAnalysisResult] = [], cancelled: () -> Bool = { false }) throws -> [String: Data] {
        var sections: [String: Data] = [:]
        let mismatch = CutError(code: "invalid_sidecar_analysis", message: "The analysis does not match this source and track.")
        func checkCancellation() throws {
            if cancelled() { throw CutError(code: "cancelled", message: "Saving analysis was cancelled.") }
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        func encode<Value: Codable>(_ key: String, _ clock: AudioAnalysisClock, _ value: Value) throws {
            sections[key] = try encoder.encode(CachedAudio(clock: clock, value: value))
        }
        try checkCancellation()
        if let scenes {
            guard media.hasVideo, scenes.sourceStamp == SceneSourceStamp(media: media),
                  URL(fileURLWithPath: scenes.file).standardizedFileURL == media.url.standardizedFileURL,
                  scenes.timeBase == media.video.timeBase, scenes.origin == media.origin,
                  scenes.duration == media.duration else { throw mismatch }
            sections = try sceneSections(for: scenes)
        }
        for (stream, overview) in envelopeOverviews {
            try checkCancellation()
            let clock = AudioAnalysisClock(media: media, stream: stream)
            guard clock.indexed, overview.sourceIdentity?.matchesSnapshot(media.identity) == true, overview.analysisClock == clock,
                  overview.from == 0, overview.to == media.duration.seconds,
                  overview.low.count == overview.high.count, (1...AudioEnvelope.maxColumns).contains(overview.low.count),
                  zip(overview.low, overview.high).allSatisfy({ $0.isFinite && $1.isFinite && $0 <= $1 }) else { throw mismatch }
            try encode("waveform_envelope.v1.\(stream)", clock, CachedEnvelope(overview))
        }
        for result in silence {
            try checkCancellation()
            let clock = AudioAnalysisClock(media: media, stream: result.stream)
            guard clock.indexed, result.sourceIdentity?.matchesSnapshot(media.identity) == true,
                  result.sourceClock == clock, valid(result, for: media, cancelled: cancelled) else {
                try checkCancellation()
                throw mismatch
            }
            guard result.hasSourceCalibration else { continue }
            try encode(silenceKey(stream: result.stream, thresholdDB: result.requestedThresholdDB,
                                  minimum: result.minimum), clock, result)
            try encode("silence_automatic_threshold_db.v1.\(result.stream)", clock, result.automaticThresholdDB)
        }
        for (stream, wave) in waveforms {
            try checkCancellation()
            guard wave.matches(media, stream: stream) else { throw mismatch }
            let clock = AudioAnalysisClock(media: media, stream: stream)
            guard clock.indexed else { throw mismatch }
            try encode("waveform_peaks.v1.\(stream)", clock, wave.peakBytes(checkingCancellation: checkCancellation))
            let key = "silence_automatic_threshold_db.v1.\(stream)"
            if sections[key] == nil {
                let db = try wave.automaticThresholdDB(checkingCancellation: checkCancellation)
                try encode(key, clock, db)
            }
        }
        try checkCancellation()
        return sections
    }
}

extension AudioAnalysis {
    /// Current detection settings select a saved pause list. New settings can
    /// be evaluated from saved peaks without decoding the audio track again.
    public static func silence(_ media: MediaInfo, stream: Int, thresholdDB: Double? = nil, minimum: Double = 1.5,
                               waveform: AudioWaveform? = nil, automaticThresholdDB: Double? = nil,
                               useSidecar: Bool = true,
                               cancelled: @escaping () -> Bool = { false }) throws -> SilenceAnalysisResult {
        func checkCancellation() throws {
            if cancelled() { throw CutError(code: "cancelled", message: "Silence analysis was cancelled.") }
        }
        try checkCancellation()
        guard minimum.isFinite, minimum > 0, thresholdDB.map({ (-120...0).contains($0) }) ?? true else {
            throw CutError(code: "invalid_arguments", message: "Use a positive minimum pause and a threshold between −120 and 0 dBFS.")
        }
        func checkSource() throws {
            guard media.identity.isCurrentSnapshot(at: media.url) else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
        }
        try checkSource()
        let sidecar = useSidecar ? AnalysisSidecar(media: media) : nil
        let suppliedCalibration = automaticThresholdDB.flatMap { (-120...0).contains($0) ? $0 : nil }
        if let saved = sidecar?.silence(for: media, stream: stream, thresholdDB: thresholdDB, minimum: minimum, cancelled: cancelled),
           suppliedCalibration.map({ saved.automaticThresholdDB == $0 }) ?? true {
            try checkCancellation()
            try checkSource()
            return saved
        }
        try checkCancellation()
        let wave: AudioWaveform
        if let waveform, waveform.matches(media, stream: stream) {
            wave = waveform
        } else {
            wave = try scan(media, stream: stream, useSidecar: useSidecar, cancelled: cancelled)
        }
        let savedCalibration = sidecar?.automaticThresholdDB(for: media, stream: stream, cancelled: cancelled)
        let calibrated: Double
        if let suppliedCalibration { calibrated = suppliedCalibration }
        else if let savedCalibration { calibrated = savedCalibration }
        else { calibrated = try wave.automaticThresholdDB(checkingCancellation: checkCancellation) }
        let runs = try wave.silenceRuns(thresholdDB: thresholdDB ?? calibrated, checkingCancellation: checkCancellation)
        let pauses = runs.pauses(minimum: minimum)
        try checkCancellation()
        try checkSource()
        var result = SilenceAnalysisResult(media: media, stream: stream, requestedThresholdDB: thresholdDB, minimum: minimum,
                                     automaticThresholdDB: calibrated, pauses: pauses, runs: runs)
        if let suppliedCalibration {
            let sourceCalibration = try savedCalibration ?? wave.automaticThresholdDB(checkingCancellation: checkCancellation)
            result.hasSourceCalibration = suppliedCalibration == sourceCalibration
        }
        sidecar?.saveAutomatically(try AnalysisSidecar.sections(media: media, silence: [result], cancelled: cancelled), cancelled: cancelled)
        try checkCancellation()
        try checkSource()
        return result
    }
}
