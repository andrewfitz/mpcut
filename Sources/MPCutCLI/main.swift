import Darwin
import Dispatch
import Foundation
import MPCutCore

private struct Failure<Detail: Encodable>: Encodable {
    let ok = false
    let error: Detail
}

private struct CopyEligibility: Encodable {
    let eligible: Bool
    let reason: String?
    let containers: [String]

    init(reason: String?, containers: [String]) {
        self.eligible = reason == nil && !containers.isEmpty
        self.reason = reason ?? (containers.isEmpty ? "No available output container can carry this source." : nil)
        self.containers = containers
    }
}

private struct Inspection: Encodable {
    let ok = true
    let preview = "unchecked"
    let media: MediaInfo
    let copy: CopyEligibility

    private enum CodingKeys: String, CodingKey {
        case ok, preview, media, copy
    }

    private enum MediaKeys: String, CodingKey {
        case url, format, duration, origin, streams, frames, audio, copyIssue, sourceStartSafe
    }

    private struct AccessPoint: Encodable {
        let dts: RationalTime?
        let time: RationalTime
        let duration: RationalTime
        let keyframe: Bool
        let canStart: Bool
        let canEnd: Bool
    }

    func encode(to encoder: Encoder) throws {
        var result = encoder.container(keyedBy: CodingKeys.self)
        try result.encode(ok, forKey: .ok)
        try result.encode(preview, forKey: .preview)
        try result.encode(copy, forKey: .copy)
        var details = result.nestedContainer(keyedBy: MediaKeys.self, forKey: .media)
        try details.encode(media.url, forKey: .url)
        try details.encode(media.format, forKey: .format)
        try details.encode(media.duration, forKey: .duration)
        try details.encode(media.origin, forKey: .origin)
        try details.encode(media.streams, forKey: .streams)
        try details.encode(media.audio, forKey: .audio)
        try details.encodeIfPresent(media.copyIssue, forKey: .copyIssue)
        try details.encode(media.sourceStartSafe, forKey: .sourceStartSafe)
        let points = media.frames.compactMap { frame -> AccessPoint? in
            let canStart = frame.time == .zero ? media.sourceStartSafe :
                frame.canStart && frame.time > .zero && frame.time < media.duration
            guard frame.keyframe || canStart else { return nil }
            return AccessPoint(dts: frame.dts, time: frame.time, duration: frame.duration,
                               keyframe: frame.keyframe, canStart: canStart, canEnd: frame.canEnd)
        }
        try details.encode(points, forKey: .frames)
    }
}

private struct ExportResult: Encodable {
    let ok = true
    let dryRun: Bool
    let output: String
    let edit: ResolvedEdit

    private struct Segment: Encodable {
        let file: String
        let from: RationalTime
        let to: RationalTime
        let outputStart: RationalTime
        let duration: RationalTime
        let tracks: [ResolvedTrack]

        init(_ segment: ResolvedSegment) {
            file = segment.file.path
            from = segment.from
            to = segment.to
            outputStart = segment.outputStart
            duration = segment.duration
            tracks = segment.tracks
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, output, segments, duration, container
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encode(edit.segments.map(Segment.init), forKey: .segments)
        try fields.encode(edit.duration, forKey: .duration)
        try fields.encode(edit.container, forKey: .container)
    }
}

private final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        let queue = DispatchQueue(label: "mpcut.signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.interrupted = true
                self.lock.unlock()
            }
            source.activate()
            sources.append(source)
        }
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !interrupted
    }

    func check() throws {
        guard isActive else {
            throw CLIError("cancelled", "Operation cancelled.")
        }
    }
}

private func errorOutput(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

private func writeJSON<T: Encodable>(_ result: T, pretty: Bool = false) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
    var data = try encoder.encode(result)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func reportFailure<T: Encodable>(_ error: T, message: String, json: Bool) {
    if json {
        do {
            try writeJSON(Failure(error: error))
        } catch {
            errorOutput("mpcut: Unable to write the result. \(error.localizedDescription)")
        }
    } else {
        errorOutput("mpcut: \(message)")
    }
}

private func readInput(_ interruption: Interruption) throws -> InputEdit {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    while true {
        try interruption.check()
        let ready = poll(&input, 1, 100)
        if ready == 0 || (ready < 0 && errno == EINTR) { continue }
        guard ready > 0 else {
            throw CLIError("stdin_read_failed", "Unable to read standard input.")
        }
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
        }
        if count == 0 { break }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else {
            throw CLIError("stdin_read_failed", "Unable to read standard input.")
        }
        data.append(contentsOf: buffer.prefix(count))
    }

    try interruption.check()
    guard String(data: data, encoding: .utf8) != nil else {
        throw CLIError("invalid_json", "Standard input must contain a UTF-8 JSON object.")
    }
    do {
        return try JSONDecoder().decode(InputEdit.self, from: data)
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError("invalid_json", "Expected one JSON object with an output path and clips containing file paths and optional timestamp strings.")
    }
}

private func fileURL(_ path: String, label: String) throws -> URL {
    guard !path.isEmpty, !path.utf8.contains(0) else {
        throw CLIError("invalid_path", "\(label) must be a nonempty local file path.")
    }
    return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
}

private func timestamp(_ value: String?, segment: Int, boundary: String) throws -> RationalTime? {
    guard let value else { return nil }
    do {
        return try RationalTime(parsing: value)
    } catch {
        throw CutError(
            code: "invalid_time",
            message: "Clip \(segment) has an invalid \(boundary) timestamp '\(value)'.",
            segment: segment,
            boundary: boundary
        )
    }
}

private func run(_ arguments: Arguments, interruption: Interruption) throws {
    let engine = CutEngine(cancelled: { !interruption.isActive })
    switch arguments.command {
    case .version:
        if arguments.json {
            try writeJSON(["version": Arguments.version])
        } else {
            print(Arguments.version)
        }
    case .help:
        if arguments.json {
            try writeJSON(["usage": Arguments.usage])
        } else {
            print(Arguments.usage)
        }
    case let .inspect(file, keyframes):
        try interruption.check()
        let media = try engine.inspect(fileURL(file, label: "Input"), keyframes: keyframes)
        let issue = media.copyIssue ?? (media.sourceStartSafe ? nil : "The source does not begin at a verified video access point.")
        let containers = issue == nil ? engine.suggestedContainers(for: media) : []
        try interruption.check()
        try writeJSON(Inspection(media: media, copy: CopyEligibility(reason: issue, containers: containers)),
                      pretty: !arguments.json)
    case let .export(supplied, dryRun, snapNearest):
        let input = try supplied ?? readInput(interruption)
        guard !input.clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires at least one clip.")
        }
        let output = try fileURL(input.output, label: "Output")
        let clips = try input.clips.enumerated().map { index, clip in
            let segment = index + 1
            return try ClipRequest(
                file: fileURL(clip.file, label: "Clip \(segment)"),
                from: timestamp(clip.from, segment: segment, boundary: "from"),
                to: timestamp(clip.to, segment: segment, boundary: "to")
            )
        }
        try interruption.check()
        let edit = try engine.resolve(clips, output: output, snap: snapNearest ? .nearest : .exact)
        try interruption.check()
        if !dryRun {
            var reported = -1
            try engine.export(edit, to: output) { progress in
                guard interruption.isActive else { return false }
                if progress.isFinite {
                    let percent = Int((min(1, max(0, progress)) * 100).rounded(.down))
                    if percent / 5 > reported {
                        errorOutput("Export \(percent)%")
                        reported = percent / 5
                    }
                }
                return true
            }
        }
        let result = ExportResult(dryRun: dryRun, output: output.path, edit: edit)
        if arguments.json || dryRun {
            try writeJSON(result, pretty: !arguments.json)
        } else {
            print("Exported \(output.path)")
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let tokens = Array(CommandLine.arguments.dropFirst())
let json = Arguments.requestsJSON(tokens)
private let interruption = Interruption()
do {
    try run(Arguments.parse(tokens), interruption: interruption)
} catch let error as CutError {
    reportFailure(error, message: error.message, json: json)
    exit(error.code == "cancelled" ? 130 : 1)
} catch let error as CLIError {
    reportFailure(error, message: error.message, json: json)
    exit(error.code == "cancelled" ? 130 : 2)
} catch {
    let failure = CLIError("operation_failed", error.localizedDescription)
    reportFailure(failure, message: failure.message, json: json)
    exit(1)
}
