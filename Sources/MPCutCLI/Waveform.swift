import Foundation
import MPCutCore

struct WaveformOptions {
    let file: String
    let stream: Int?
    let from: RationalTime?
    let to: RationalTime?
    let columns: Int

    init(_ arguments: [String]) throws {
        var file: String?, stream: Int?, from: RationalTime?, to: RationalTime?
        var columns = 1024
        var positional = false
        var seen = Set<String>()
        var iterator = arguments.makeIterator()
        func invalid(_ message: String) -> CLIError { CLIError("invalid_arguments", message) }
        while let flag = iterator.next() {
            if positional || !flag.hasPrefix("-") {
                guard file == nil else { throw invalid("Waveform accepts one source file.") }
                file = flag
                continue
            }
            guard seen.insert(flag).inserted else { throw invalid("Duplicate waveform option \(flag).") }
            func value() throws -> String {
                guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw invalid("Missing value for \(flag).")
                }
                return value
            }
            switch flag {
            case "--": positional = true
            case "--json": break
            case "--columns":
                guard let count = Int(try value()), (1...AudioEnvelope.maxColumns).contains(count) else {
                    throw invalid("--columns accepts 1–65,536.")
                }
                columns = count
            case "--stream":
                guard let index = Int(try value()), index >= 0 else { throw invalid("--stream requires an audio stream index.") }
                stream = index
            case "--from": from = try RationalTime(parsing: value())
            case "--to": to = try RationalTime(parsing: value())
            default: throw invalid("Unknown waveform option '\(flag)'.")
            }
        }
        guard let file else { throw invalid("Waveform requires an input file.") }
        self.file = file
        self.stream = stream
        self.from = from
        self.to = to
        self.columns = columns
    }

    struct Report: Encodable {
        let ok = true
        let file: String
        let stream: Int
        let sampleRate: Int
        let columns: Int
        private enum CodingKeys: String, CodingKey {
            case ok, file, stream = "audio_stream_index", sampleRate = "sample_rate", columns, envelope
        }
        let envelope: AudioEnvelope
    }

    func run(_ source: URL, cancelled: @escaping @Sendable () -> Bool) throws -> Report {
        let original = try CutEngine(cancelled: cancelled).inspectForAudioAnalysis(source)
        guard let track = original.streams.first(where: { $0.kind == "audio" && (stream == nil || $0.index == stream) }) else {
            throw CutError(code: "no_audio", message: "Choose an available audio stream.")
        }
        let media = try original.extendingToAudioEnd(stream: track.index)
        let wave = try AudioAnalysis.envelope(media, stream: track.index, from: from?.seconds ?? 0,
                                              to: to?.seconds ?? media.duration.seconds, columns: columns, cancelled: cancelled)
        return Report(file: media.url.path, stream: track.index, sampleRate: track.sampleRate, columns: columns, envelope: wave)
    }
}
