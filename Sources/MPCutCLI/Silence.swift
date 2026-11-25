import Foundation
import MPCutCore

enum SilenceThresholdMode: String, Codable {
    case auto, manual
}

struct SilenceOptions {
    var file: String?
    var project: String?
    var output: String?
    var outProject: String?
    var protectedPauses = Set<String>()
    var retainedPauseSeconds: [String: Double] = [:]
    var takeBoundaries = Set<RationalTime>()
    var stream: Int?
    var audioStream: Int?
    var thresholdDB: Double?
    var maxBlip = AudioWaveform.defaultMaxBlip
    var minimum = 1.5
    var padding: Double?
    var columns: Int?
    var mode: ExportMode?
    var audio: ReencodeAudio?
    var audioOutput: MulticamAudioOutput?
    var tracks: ExportTracks?
    var pausesFile: String?
    var stdin = false
    var dryRun = false

    func splitTakeCandidates(_ retained: [AudioSpan], saved: Set<RationalTime> = []) throws -> [AudioSpan] {
        var points = takeBoundaries
        for point in saved {
            let first = retained.lowerBound { $0.to > point }
            if first < retained.endIndex, retained[first].from < point { points.insert(point) }
        }
        guard !points.isEmpty else { return retained }
        var boundaries = points.sorted()[...]
        var candidates: [AudioSpan] = []
        for range in retained {
            var start = range.from
            while let point = boundaries.first, point < range.to {
                guard point > start else {
                    throw CLIError("invalid_arguments", "Choose take boundaries strictly inside retained candidates.")
                }
                candidates.append(AudioSpan(from: start, to: point))
                start = point
                boundaries = boundaries.dropFirst()
            }
            candidates.append(AudioSpan(from: start, to: range.to))
        }
        guard boundaries.isEmpty else {
            throw CLIError("invalid_arguments", "Choose take boundaries strictly inside retained candidates.")
        }
        return candidates
    }

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        var positional = false
        var seen = Set<String>()
        func invalid(_ message: String) -> CLIError { CLIError("invalid_arguments", message) }
        while let flag = iterator.next() {
            if positional || !flag.hasPrefix("-") {
                guard file == nil else { throw invalid("Supply one media file.") }
                file = flag
                continue
            }
            guard ["--protect-pause", "--retain-pause", "--take-boundary"].contains(flag) || seen.insert(flag).inserted else { throw invalid("Duplicate option \(flag).") }
            func value() throws -> String {
                guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw invalid("Missing value for \(flag).")
                }
                return value
            }
            func number() throws -> Double {
                guard let number = Double(try value()), number.isFinite else { throw invalid("Invalid number for \(flag).") }
                return number
            }
            switch flag {
            case "--": positional = true
            case "--json": break
            case "--pauses-file": pausesFile = try value()
            case "--stdin": stdin = true
            case "--dry-run": dryRun = true
            case "--project": project = try value()
            case "--protect-pause": protectedPauses.insert(try value())
            case "--retain-pause":
                guard let input = iterator.next(), let separator = input.lastIndex(of: "="), separator != input.startIndex,
                      let seconds = Double(input[input.index(after: separator)...]), seconds.isFinite, seconds >= 0 else {
                    throw invalid("Use --retain-pause ID=SECONDS with a nonnegative duration.")
                }
                let id = String(input[..<separator])
                guard retainedPauseSeconds[id] == nil else { throw invalid("Set a retained duration only once per pause.") }
                retainedPauseSeconds[id] = seconds
            case "--take-boundary":
                let position = try RationalTime(parsing: value())
                guard position > .zero else { throw invalid("Choose a positive sequence time for --take-boundary.") }
                takeBoundaries.insert(position)
            case "--out-project": outProject = try value()
            case "--output": output = try value()
            case "--threshold-db":
                let threshold = try number()
                guard (-120...0).contains(threshold) else { throw invalid("Use a threshold between −120 and 0 dBFS.") }
                thresholdDB = threshold
            case "--max-blip-seconds":
                let seconds = try number()
                guard (0...1).contains(seconds) else { throw invalid("Use a maximum blip between 0 and 1 second.") }
                maxBlip = seconds
            case "--min-pause-seconds": minimum = try number()
            case "--padding-per-side-seconds":
                let seconds = try number()
                guard seconds >= 0 else { throw invalid("Padding must be nonnegative.") }
                padding = seconds
            case "--stream", "--audio-stream":
                guard let index = Int(try value()), index >= 0 else { throw invalid("Use a nonnegative stream index.") }
                if flag == "--stream" { stream = index } else { audioStream = index }
            case "--waveform":
                guard let count = Int(try value()), (1...8192).contains(count) else { throw invalid("Choose 1–8192 waveform columns.") }
                columns = count
            case "--tracks":
                let raw = try value()
                guard let choice = ExportTracks(rawValue: raw) else { throw invalid("Choose all, audio, or video.") }
                tracks = choice
            case "--audio":
                guard let choice = ReencodeAudio(rawValue: try value()),
                      [.auto, .copyOriginal, .aac, .pcm, .removeAudio].contains(choice) else {
                    throw invalid("Choose auto, copy, aac, pcm or remove for --audio.")
                }
                audio = choice
            case "--audio-output":
                guard let choice = MulticamAudioOutput(rawValue: try value()) else {
                    throw invalid("Choose separate_tracks, downmix_mono or downmix_stereo for --audio-output.")
                }
                audioOutput = choice
            case "--mode":
                let modes = ExportEntryPoint.cliSilence.modes
                guard let choice = ExportMode(rawValue: try value()), modes.contains(choice) else {
                    throw invalid("Choose \(modes.map(\.rawValue).joined(separator: " or ")).")
                }
                mode = choice
            default: throw invalid("Unknown silence option '\(flag)'.")
            }
        }
        guard [stdin, file != nil, project != nil].filter({ $0 }).count == 1, !dryRun || output != nil else {
            throw invalid("Supply one media file, --project, or --stdin. A dry run requires --output.")
        }
        if project != nil && !seen.isDisjoint(with: ["--stream", "--audio-stream", "--waveform", "--tracks"]) {
            throw invalid("Project silence uses the picture and audio selected in the project. Omit --stream, --audio-stream, --waveform and --tracks.")
        }
        if audio != nil || audioOutput != nil {
            guard project != nil, output != nil else {
                throw invalid("Use audio delivery options with --project and --output.")
            }
        }
        guard minimum > 0, (padding ?? 0) >= 0 else {
            throw invalid("Use a positive minimum pause and nonnegative padding time.")
        }
        if pausesFile != nil && project != nil { throw invalid("--pauses-file uses one recording or its saved silence report.") }
        if stdin && !seen.isDisjoint(with: ["--threshold-db", "--min-pause-seconds", "--max-blip-seconds", "--stream", "--waveform"]) {
            throw invalid("Detection settings and waveform columns require a new scan.")
        }
    }
}

private enum SilenceReportField: String, CodingKey, CaseIterable {
    case ok, mode, tracks, file, duration, pauses
    case stream = "detection_audio_stream_index", audioStream = "output_audio_stream_index"
    case sourceStamp = "source_stamp"
    case thresholdMode = "threshold_mode"
    case thresholdDB = "threshold_db"
    case maxBlip = "max_blip_seconds"
    case minimumPause = "min_pause_seconds"
    case padding = "padding_per_side_seconds"
    case removals, clips, skippedPauses = "skipped_pauses", removedDuration = "removed_duration"
    case binSeconds = "bin_seconds", waveformPeakDBFS = "waveform_peak_dbfs"
}

struct SilenceInput: Decodable {
    let ok: Bool
    let mode: ExportMode
    let tracks: ExportTracks?
    let audioStream: Int?
    let file: String
    let sourceStamp: SceneSourceStamp
    let duration: RationalTime
    let stream: Int
    let thresholdMode: SilenceThresholdMode
    let thresholdDB: Double
    let maxBlip: Double
    let minimumPause: Double
    let padding: Double
    let pauses: [AudioSpan]

    init(from decoder: Decoder) throws {
        let fields = try decoder.requestFields(SilenceReportField.self, in: "Silence report")
        ok = try fields.decode(Bool.self, forKey: .ok)
        mode = try fields.decode(ExportMode.self, forKey: .mode)
        tracks = try fields.decodeIfPresent(ExportTracks.self, forKey: .tracks)
        audioStream = try fields.decodeIfPresent(Int.self, forKey: .audioStream)
        file = try fields.decode(String.self, forKey: .file)
        duration = try fields.decode(RationalTime.self, forKey: .duration)
        stream = try fields.decode(Int.self, forKey: .stream)
        sourceStamp = try fields.decode(SceneSourceStamp.self, forKey: .sourceStamp)
        thresholdMode = try fields.decode(SilenceThresholdMode.self, forKey: .thresholdMode)
        thresholdDB = try fields.decode(Double.self, forKey: .thresholdDB)
        maxBlip = try fields.decode(Double.self, forKey: .maxBlip)
        minimumPause = try fields.decode(Double.self, forKey: .minimumPause)
        padding = try fields.decode(Double.self, forKey: .padding)
        pauses = try fields.decode([AudioSpan].self, forKey: .pauses)
    }
}

struct SilenceData: Encodable {
    let ok = true
    let file: String
    let sourceStamp: SceneSourceStamp
    let duration: RationalTime
    let stream: Int
    let thresholdMode: SilenceThresholdMode
    let thresholdDB: Double
    let maxBlip: Double
    let minimumPause: Double
    let padding: Double
    let mode: ExportMode
    let tracks: ExportTracks?
    let audioStream: Int?
    let pauses: [AudioSpan]
    let removals: [AudioSpan]
    let clips: [AudioSpan]
    let skippedPauses: Int
    let removedDuration: RationalTime
    let binSeconds = 1.0 / Double(AudioWaveform.rate)
    let waveformPeakDBFS: [Double?]?

    private typealias CodingKeys = SilenceReportField
}

func silenceRemovals(_ pauses: [AudioSpan], in media: MediaInfo, padding: Double,
                     engine: CutEngine, tracks: ExportTracks, audioStream: Int?, container requestedContainer: String?) -> [AudioSpan] {
    guard !pauses.isEmpty else { return [] }
    let source = AudioSpan(from: .zero, to: media.duration)
    if !media.hasVideo || tracks == .audio {
        return pauses.compactMap {
            AudioAnalysis.audioRemoval(in: $0, padding: padding, media: media, stream: audioStream, clip: source,
                                       container: requestedContainer)
        }
    }
    let container = requestedContainer ?? engine.suggestedContainers(for: media).first ?? media.url.pathExtension.lowercased()

    // Removing a leading or trailing pause creates only one cut edge. A codec
    // can permit a single source trim even when it cannot join two pieces.
    let trimHead = padding == 0 && pauses.first?.from == .zero
    let trimTail = padding == 0 && pauses.last?.to == media.duration
    if pauses.count == 1 && trimHead && trimTail { return [source] }
    let middle = pauses.dropFirst(trimHead ? 1 : 0).dropLast(trimTail ? 1 : 0)
    var cuts: [AudioSpan] = []
    if !middle.isEmpty {
        let ends = engine.validBoundaries(in: media, start: false, first: false, last: false, container: container)
        let starts = engine.validBoundaries(in: media, start: true, first: false, last: false, container: container)
        cuts = middle.compactMap { AudioAnalysis.removal(in: $0, padding: padding, ends: ends, starts: starts) }
    }
    let singleClip = cuts.isEmpty
    if trimHead, let head = pauses.first {
        let starts = engine.validBoundaries(in: media, start: true, first: true, last: singleClip, container: container)
        if let cut = AudioAnalysis.removal(in: head, padding: 0, ends: [], starts: starts, clip: source) {
            cuts.insert(cut, at: 0)
        }
    }
    if trimTail, let tail = pauses.last {
        let ends = engine.validBoundaries(in: media, start: false, first: singleClip, last: true, container: container)
        if let cut = AudioAnalysis.removal(in: tail, padding: 0, ends: ends, starts: [], clip: source) {
            cuts.append(cut)
        }
    }
    return cuts
}
