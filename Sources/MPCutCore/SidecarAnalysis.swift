import Foundation

/// The exact presentation clock used when measuring this track. Preview timing
/// and a fully indexed MOV with audio edits can differ for the same source.
struct AudioAnalysisClock: Codable, Equatable, Sendable {
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
    private let clock: AudioAnalysisClock

    package init(media: MediaInfo, stream: Int) {
        identity = media.identity
        clock = AudioAnalysisClock(media: media, stream: stream)
    }
}

public struct SilenceAnalysisResult: Codable, Sendable {
    public let stream: Int
    public let requestedThresholdDB: Double?
    public let minimum: Double
    public let automaticThresholdDB: Double
    public let pauses: [AudioSpan]
    let runs: SilenceRuns?
    package var hasRouting: Bool { runs != nil }
    public var thresholdDB: Double { requestedThresholdDB ?? automaticThresholdDB }
    fileprivate var sourceIdentity: SourceIdentity?
    fileprivate var sourceClock: AudioAnalysisClock?
    fileprivate var hasSourceCalibration = true

    enum CodingKeys: String, CodingKey {
        case stream, requestedThresholdDB, minimum, automaticThresholdDB, pauses, runs
    }

    init(media: MediaInfo, stream: Int, requestedThresholdDB: Double?, minimum: Double,
                     automaticThresholdDB: Double, pauses: [AudioSpan], runs: SilenceRuns? = nil) {
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
        runs = try values.decodeIfPresent(SilenceRuns.self, forKey: .runs)
    }
}

private let silenceCancellationKey = CodingUserInfoKey(rawValue: "mpcut.silence.cancelled")!

private struct CachedAudio<Value: Codable>: Codable {
    let clock: AudioAnalysisClock
    let value: Value
    var sampleAlignedPeaks: Bool?
    var hasSourceCalibration: Bool?
}

private func needsSourceCalibration(_ key: String) -> Bool {
    // Earlier records could contain a caller-supplied override under a
    // source-wide calibration key. Recompute them before normal reuse.
    key.hasPrefix("silence.") || key.hasPrefix("calibration.")
}

// Earlier peak scans used each block's rounded container timestamp directly.
// Signed envelopes already tracked the continuous sample clock.
private func needsSampleAlignedPeaks(_ media: MediaInfo, stream: Int, key: String) -> Bool {
    guard AnalysisSidecar.savedEnvelopeStream(forKey: key) == nil,
          !media.requiresPresentationAudioAnalysis(stream: stream),
          let track = media.streams.first(where: { $0.index == stream }), track.sampleRate > 0 else { return false }
    return track.timeBase > RationalTime(numerator: 1, denominator: Int64(track.sampleRate))
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
    return "silence.v1.\(stream).\(threshold).\(String(minimum.bitPattern, radix: 16))"
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
    guard let runs = result.runs else { return true }
    return validSpans(runs.quiet, minimum: 0) && validSpans(runs.covered, minimum: 0)
}

extension AnalysisSidecar {
    // Revise these together when detection can change marker timing or view IDs.
    public static let sceneSectionKey = "scenes.v2"
    public static let viewNameSectionKey = "viewNames.v2"

    public static func savedSilenceSettings(forKey key: String) -> (stream: Int, thresholdDB: Double?, minimum: Double)? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "silence", parts[1] == "v1", let stream = Int(parts[2]), stream >= 0,
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
        guard key.hasPrefix("wave.v1."), let stream = Int(key.dropFirst("wave.v1.".count)), stream >= 0,
              key == "wave.v1.\(stream)" else { return nil }
        return stream
    }

    public static func savedEnvelopeStream(forKey key: String) -> Int? {
        guard key.hasPrefix("envelope.v2."), let stream = Int(key.dropFirst("envelope.v2.".count)),
              stream >= 0, key == "envelope.v2.\(stream)" else { return nil }
        return stream
    }

    public static func sceneSections(for report: SceneReport) throws -> [String: Data] {
        [sceneSectionKey: try JSONEncoder().encode(CachedScenes(report))]
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

    private func viewNames(matching cached: @autoclosure () -> CachedScenes, read: (String) -> Data?) -> [Int: String] {
        // An explicitly empty current map clears all names, including legacy names.
        if let data = read(Self.viewNameSectionKey) {
            return (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        }
        guard let data = read("viewNames.v1"),
              let names = try? JSONDecoder().decode([Int: String].self, from: data), !names.isEmpty,
              let markers = read("scenes.v1"),
              let legacy = try? JSONDecoder().decode(CachedScenes.self, from: markers), legacy == cached()
        else { return [:] }
        return names
    }

    func restoringViewNames(to report: SceneReport, cancelled: () -> Bool) -> SceneReport {
        guard report.sourceStamp == SceneSourceStamp(identity: identity) else { return report }
        return (try? withReadSnapshot(cancelled: cancelled) { read in
            let names = viewNames(matching: CachedScenes(report), read: read)
            var updated = report
            for (view, name) in names { updated.setViewName(name, for: view) }
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

    private func decodeSceneReport(read: (String) -> Data?, cancelled: () -> Bool) throws -> SceneReport? {
        guard let data = read(Self.sceneSectionKey),
              let cached = try? JSONDecoder().decode(CachedScenes.self, from: data)
        else { return nil }
        let names = viewNames(matching: cached, read: read)
        return try cached.report(source: source, identity: identity, names: names, cancelled: cancelled)
    }

    public func sceneReport(for media: MediaInfo, cancelled: () -> Bool = { Task.isCancelled }) -> SceneReport? {
        guard media.hasVideo, identity == media.identity else { return nil }
        return matchingSceneReport(sceneReport(cancelled: cancelled), media: media)
    }

    private func matchingSceneReport(_ report: SceneReport?, media: MediaInfo) -> SceneReport? {
        guard let report, report.timeBase == media.video.timeBase, report.duration == media.duration,
              report.origin == media.origin else { return nil }
        return report
    }

    package func editorMetadata(for media: MediaInfo, cancelled: () -> Bool) -> (SceneReport?, [Int: Double])? {
        guard identity == media.identity else { return nil }
        return try? withReadSnapshot(cancelled: cancelled) { read in
            let report = media.hasVideo
                ? matchingSceneReport(try? decodeSceneReport(read: read, cancelled: cancelled), media: media)
                : nil
            let thresholds = read("thresholdOverrides.v1").flatMap {
                try? JSONDecoder().decode([Int: Double].self, from: $0)
            } ?? [:]
            return (report, thresholds)
        }
    }

    private func audioRecord<Value: Codable>(_ type: Value.Type, key: String, media: MediaInfo,
                                             stream: Int, maxBytes: Int? = nil,
                                             cancelled: @escaping () -> Bool = { Task.isCancelled }) -> Value? {
        let clock = AudioAnalysisClock(media: media, stream: stream)
        guard media.identity == identity, clock.indexed, !cancelled(),
              let data = read(key, maxBytes: maxBytes, cancelled: cancelled), !cancelled() else { return nil }
        let decoder = PropertyListDecoder()
        decoder.userInfo[silenceCancellationKey] = cancelled
        guard let record = try? decoder.decode(CachedAudio<Value>.self, from: data),
              record.clock == clock, !cancelled(),
              record.hasSourceCalibration == true || !needsSourceCalibration(key),
              record.sampleAlignedPeaks == true || !needsSampleAlignedPeaks(media, stream: stream, key: key) else { return nil }
        return record.value
    }

    public func waveform(for media: MediaInfo, stream: Int, cancelled: @escaping () -> Bool = { Task.isCancelled }) -> AudioWaveform? {
        let bins = ceil(media.duration.seconds * Double(AudioWaveform.rate)) + 1
        // Include space for the clock and binary property list metadata.
        guard let maxBytes = Int(exactly: bins * Double(MemoryLayout<Float>.stride) + 4096),
              let bytes = audioRecord(Data.self, key: "wave.v1.\(stream)", media: media,
                                     stream: stream, maxBytes: maxBytes, cancelled: cancelled) else { return nil }
        return AudioWaveform(peakBytes: bytes, media: media, stream: stream, cancelled: cancelled)
    }

    public func envelopeOverview(for media: MediaInfo, stream: Int, cancelled: @escaping () -> Bool = { Task.isCancelled }) -> AudioEnvelope? {
        let maxBytes = AudioEnvelope.maxColumns * 2 * MemoryLayout<Float>.stride + 4096
        guard let saved = audioRecord(CachedEnvelope.self, key: "envelope.v2.\(stream)", media: media,
                                      stream: stream, maxBytes: maxBytes, cancelled: cancelled),
              var overview = saved.overview(duration: media.duration.seconds), !cancelled() else { return nil }
        overview.sourceIdentity = media.identity
        overview.analysisClock = AudioAnalysisClock(media: media, stream: stream)
        return overview
    }

    func saveOverviewAutomatically(_ overview: AudioEnvelope, for media: MediaInfo, stream: Int,
                                   cancelled: () -> Bool) {
        guard Self.readsEnabled, Self.automaticWritesEnabled, !isExcluded, !cancelled() else { return }
        let key = "envelope.v2.\(stream)"
        guard let data = try? Self.sections(media: media, envelopeOverviews: [stream: overview], cancelled: cancelled)[key] else { return }
        try? save([:], updating: [key: { current in
            // Another process can finish a finer overview while this one is decoding.
            if let current,
               let saved = try? PropertyListDecoder().decode(CachedAudio<CachedEnvelope>.self, from: current),
               saved.clock == overview.analysisClock,
               saved.value.low.count >= overview.low.count * MemoryLayout<Float>.stride,
               saved.value.overview(duration: media.duration.seconds) != nil {
                return current
            }
            return data
        }], cancelled: cancelled)
    }

    public func automaticThresholdDB(for media: MediaInfo, stream: Int, cancelled: @escaping () -> Bool = { Task.isCancelled }) -> Double? {
        guard let db = audioRecord(Double.self, key: "calibration.v1.\(stream)", media: media, stream: stream, cancelled: cancelled),
              (-120...0).contains(db) else { return nil }
        return db
    }

    public func silence(for media: MediaInfo, stream: Int, thresholdDB: Double?, minimum: Double,
                        requireRouting: Bool = false,
                        cancelled: @escaping () -> Bool = { Task.isCancelled }) -> SilenceAnalysisResult? {
        let key = silenceKey(stream: stream, thresholdDB: thresholdDB, minimum: minimum)
        guard var result = audioRecord(SilenceAnalysisResult.self, key: key, media: media, stream: stream, cancelled: cancelled),
              result.stream == stream, result.requestedThresholdDB == thresholdDB, result.minimum == minimum,
              !requireRouting || result.hasRouting,
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
            let aligned = needsSampleAlignedPeaks(media, stream: clock.stream, key: key)
            sections[key] = try encoder.encode(CachedAudio(clock: clock, value: value, sampleAlignedPeaks: aligned ? true : nil,
                                                           hasSourceCalibration: needsSourceCalibration(key) ? true : nil))
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
            guard clock.indexed, overview.sourceIdentity == media.identity, overview.analysisClock == clock,
                  overview.from == 0, overview.to == media.duration.seconds,
                  overview.low.count == overview.high.count, (1...AudioEnvelope.maxColumns).contains(overview.low.count),
                  zip(overview.low, overview.high).allSatisfy({ $0.isFinite && $1.isFinite && $0 <= $1 }) else { throw mismatch }
            try encode("envelope.v2.\(stream)", clock, CachedEnvelope(overview))
        }
        for result in silence {
            try checkCancellation()
            let clock = AudioAnalysisClock(media: media, stream: result.stream)
            guard clock.indexed, result.sourceIdentity == media.identity,
                  result.sourceClock == clock, valid(result, for: media, cancelled: cancelled) else {
                try checkCancellation()
                throw mismatch
            }
            guard result.hasSourceCalibration else { continue }
            try encode(silenceKey(stream: result.stream, thresholdDB: result.requestedThresholdDB,
                                  minimum: result.minimum), clock, result)
            try encode("calibration.v1.\(result.stream)", clock, result.automaticThresholdDB)
        }
        for (stream, wave) in waveforms {
            try checkCancellation()
            guard wave.matches(media, stream: stream) else { throw mismatch }
            let clock = AudioAnalysisClock(media: media, stream: stream)
            guard clock.indexed else { throw mismatch }
            try encode("wave.v1.\(stream)", clock, wave.peakBytes(checkingCancellation: checkCancellation))
            let key = "calibration.v1.\(stream)"
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
                               useSidecar: Bool = true, requireRouting: Bool = false,
                               cancelled: @escaping () -> Bool = { false }) throws -> SilenceAnalysisResult {
        func checkCancellation() throws {
            if cancelled() { throw CutError(code: "cancelled", message: "Silence analysis was cancelled.") }
        }
        try checkCancellation()
        guard minimum.isFinite, minimum > 0, thresholdDB.map({ (-120...0).contains($0) }) ?? true else {
            throw CutError(code: "invalid_arguments", message: "Use a positive minimum pause and a threshold between −120 and 0 dBFS.")
        }
        func checkSource() throws {
            guard try SourceIdentity(media.url) == media.identity else {
                throw CutError(code: "source_changed", message: "The source changed since inspection.")
            }
        }
        try checkSource()
        let sidecar = useSidecar ? AnalysisSidecar(media: media) : nil
        let suppliedCalibration = automaticThresholdDB.flatMap { (-120...0).contains($0) ? $0 : nil }
        if let saved = sidecar?.silence(for: media, stream: stream, thresholdDB: thresholdDB, minimum: minimum,
                                        requireRouting: requireRouting, cancelled: cancelled),
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
