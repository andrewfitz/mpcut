import Foundation
import MPCutCore

enum SilenceThresholdMode: String, Codable {
    case auto, manual
}

struct SilenceOptions {
    var file: String?
    var project: String?
    var output: String?
    var stream: Int?
    var audioStream: Int?
    var thresholdDB: Double?
    var minimum = 1.5
    var leave: Double?
    var columns: Int?
    var mode: ExportMode?
    var tracks: ExportTracks?
    var stdin = false
    var dryRun = false

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
            guard seen.insert(flag).inserted else { throw invalid("Duplicate option \(flag).") }
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
            case "--stdin": stdin = true
            case "--dry-run": dryRun = true
            case "--project": project = try value()
            case "--output": output = try value()
            case "--threshold-db":
                let threshold = try number()
                guard (-120...0).contains(threshold) else { throw invalid("Use a threshold between −120 and 0 dBFS.") }
                thresholdDB = threshold
            case "--min-pause": minimum = try number()
            case "--leave": leave = try number()
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
            case "--mode":
                guard let choice = ExportMode(rawValue: try value()), choice != .encode else { throw invalid("Choose smart or copy.") }
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
        guard minimum > 0, (leave ?? 0) >= 0 else {
            throw invalid("Use a positive minimum pause and nonnegative leave time.")
        }
        if stdin && !seen.isDisjoint(with: ["--threshold-db", "--min-pause", "--stream", "--waveform"]) {
            throw invalid("Detection settings and waveform columns require a new scan.")
        }
    }
}

struct SilenceInput: Codable {
    let ok: Bool
    let mode: ExportMode
    let tracks: ExportTracks?
    let audioStream: Int?
    let file: String
    let sourceStamp: SceneSourceStamp
    let duration: RationalTime
    let stream: Int
    let thresholdMode: SilenceThresholdMode?
    let thresholdDB: Double
    let minimumPause: Double
    let leave: Double
    let pauses: [AudioSpan]
}

struct SilenceData: Encodable {
    let ok = true
    let file: String
    let sourceStamp: SceneSourceStamp
    let duration: RationalTime
    let stream: Int
    let thresholdMode: SilenceThresholdMode
    let thresholdDB: Double
    let minimumPause: Double
    let leave: Double
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
}

func silenceRemovals(_ pauses: [AudioSpan], in media: MediaInfo, leave: Double,
                     engine: CutEngine, tracks: ExportTracks, audioStream: Int?, container requestedContainer: String?) -> [AudioSpan] {
    guard !pauses.isEmpty else { return [] }
    let source = AudioSpan(from: .zero, to: media.duration)
    if !media.hasVideo || tracks == .audio {
        return pauses.compactMap {
            AudioAnalysis.audioRemoval(in: $0, leave: leave, media: media, stream: audioStream, clip: source,
                                       container: requestedContainer)
        }
    }
    let container = requestedContainer ?? engine.suggestedContainers(for: media).first ?? media.url.pathExtension.lowercased()

    // Removing a leading or trailing pause creates only one cut edge. A codec
    // can permit a single source trim even when it cannot join two pieces.
    let trimHead = leave == 0 && pauses.first?.from == .zero
    let trimTail = leave == 0 && pauses.last?.to == media.duration
    if pauses.count == 1 && trimHead && trimTail { return [source] }
    let middle = pauses.dropFirst(trimHead ? 1 : 0).dropLast(trimTail ? 1 : 0)
    var cuts: [AudioSpan] = []
    if !middle.isEmpty {
        let ends = engine.validBoundaries(in: media, start: false, first: false, last: false, container: container)
        let starts = engine.validBoundaries(in: media, start: true, first: false, last: false, container: container)
        cuts = middle.compactMap { AudioAnalysis.removal(in: $0, leave: leave, ends: ends, starts: starts) }
    }
    let singleClip = cuts.isEmpty
    if trimHead, let head = pauses.first {
        let starts = engine.validBoundaries(in: media, start: true, first: true, last: singleClip, container: container)
        if let cut = AudioAnalysis.removal(in: head, leave: 0, ends: [], starts: starts, clip: source) {
            cuts.insert(cut, at: 0)
        }
    }
    if trimTail, let tail = pauses.last {
        let ends = engine.validBoundaries(in: media, start: false, first: singleClip, last: true, container: container)
        if let cut = AudioAnalysis.removal(in: tail, leave: 0, ends: ends, starts: [], clip: source) {
            cuts.append(cut)
        }
    }
    return cuts
}
