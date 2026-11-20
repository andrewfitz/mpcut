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

// Encode the large frame list in batches. Foundation's JSONEncoder otherwise
// holds an object tree for every timestamp until the complete report is encoded.
private struct InspectionSummary: Encodable {
    let media: MediaInfo

    private enum CodingKeys: String, CodingKey {
        case url, format, duration, origin, streams, audio, copyIssue, sourceStartSafe
    }

    func encode(to encoder: Encoder) throws {
        var details = encoder.container(keyedBy: CodingKeys.self)
        try details.encode(media.url, forKey: .url)
        try details.encode(media.format, forKey: .format)
        try details.encode(media.duration, forKey: .duration)
        try details.encode(media.origin, forKey: .origin)
        try details.encode(media.streams, forKey: .streams)
        try details.encode(media.audio, forKey: .audio)
        try details.encodeIfPresent(media.copyIssue, forKey: .copyIssue)
        try details.encode(media.sourceStartSafe, forKey: .sourceStartSafe)
    }
}

private struct CLIHelp: Encodable {
    let usage = Arguments.usage
    let version = Arguments.version
    let exportModes = ExportMode.allCases.map(\.rawValue)
    let videoCodecs = ReencodeCodec.allCases.map(\.rawValue)
    let qualities = ReencodeQuality.allCases.map(\.rawValue)
    let audioOptions = ReencodeAudio.allCases.map(\.rawValue)
    let snapOptions = SnapMode.allCases.map(\.rawValue)
    let defaultExportMode = ExportMode.copy.rawValue
    let defaultOrderedExportMode = ExportMode.smart.rawValue
    let clipOrderIndexBase = 1
    let defaultBulkMode = ExportMode.smart.rawValue
    let sceneExportGroups = SceneGrouping.allCases.map(\.rawValue)
}

private struct AccessPoint: Encodable {
    let dts: RationalTime?
    let time: RationalTime
    let duration: RationalTime
    let keyframe: Bool
    let canStart: Bool
    let canEnd: Bool
}

private func inspectionJSON(_ media: MediaInfo, copy: CopyEligibility, allFrames: Bool, from: RationalTime?, to: RationalTime?, pretty: Bool,
                            interruption: Interruption) throws -> Data {
    let encoder = jsonEncoder(pretty: pretty)
    var result = Data()
    func appendJSON(_ fragment: Data, indent: String) {
        if pretty {
            let text = String(decoding: fragment, as: UTF8.self)
            result.append(contentsOf: text.replacingOccurrences(of: "\n", with: "\n" + indent).utf8)
        } else {
            result.append(fragment)
        }
    }
    let header = pretty ? "{\n  \"ok\" : true,\n  \"preview\" : \"unchecked\",\n  \"copy\" : "
                        : #"{"ok":true,"preview":"unchecked","copy":"#
    result.append(contentsOf: header.utf8)
    appendJSON(try encoder.encode(copy), indent: "  ")
    result.append(contentsOf: (pretty ? ",\n  \"media\" : " : #","media":"#).utf8)
    // InspectionSummary always encodes an object. Append the frames member
    // before closing that object, keeping paths and other strings JSON-escaped.
    var metadata = try encoder.encode(InspectionSummary(media: media)).dropLast()
    if metadata.last == 0x0a { metadata = metadata.dropLast() }
    appendJSON(metadata, indent: "  ")
    result.append(contentsOf: (pretty ? ",\n    \"frames\" : [" : #","frames":["#).utf8)
    var needsComma = false
    let batchSize = 512
    for start in stride(from: 0, to: media.frames.count, by: batchSize) {
        try interruption.check()
        let frames = media.frames[start..<min(start + batchSize, media.frames.count)]
        if let from, let last = frames.last, last.time < from { continue }
        if let to, let first = frames.first, first.time >= to { break }
        let points = frames.compactMap { frame -> AccessPoint? in
            let canStart = frame.time == .zero ? media.sourceStartSafe :
                frame.canStart && frame.time > .zero && frame.time < media.duration
            if let from, frame.time < from { return nil }
            if let to, frame.time >= to { return nil }
            guard allFrames || frame.keyframe || canStart else { return nil }
            return AccessPoint(dts: frame.dts, time: frame.time, duration: frame.duration,
                               keyframe: frame.keyframe, canStart: canStart, canEnd: frame.canEnd)
        }
        if points.isEmpty { continue }
        if needsComma { result.append(0x2c) }
        var elements = try encoder.encode(points).dropFirst().dropLast()
        if elements.last == 0x0a { elements = elements.dropLast() }
        appendJSON(elements, indent: "    ")
        needsComma = true
    }
    if pretty && needsComma { result.append(contentsOf: "\n    ".utf8) }
    result.append(contentsOf: (pretty ? "]\n  }\n}\n" : "]}}\n").utf8)
    return result
}

private struct ExportResult: Encodable {
    let ok = true
    let dryRun: Bool
    let output: String
    let edit: ResolvedEdit
    let mode: ExportMode
    let conversion: ReencodePlan?
    let copiedDuration: RationalTime
    let encodedDuration: RationalTime
    let order: [Int]?

    init(dryRun: Bool, output: String, edit: ResolvedEdit, mode: ExportMode, conversion: ReencodePlan?,
         order: [Int]? = nil) throws {
        self.dryRun = dryRun
        self.output = output
        self.edit = edit
        self.mode = mode
        self.conversion = conversion
        self.order = order
        self.copiedDuration = try edit.copiedVideoDuration(for: mode)
        self.encodedDuration = try edit.encodedVideoDuration(for: mode)
    }

    private struct Segment: Encodable {
        struct TrackAction: Encodable {
            let index: Int
            let kind: String
            let action: String
        }

        let file: String
        let from: RationalTime
        let to: RationalTime
        let outputStart: RationalTime
        let duration: RationalTime
        let tracks: [ResolvedTrack]
        let encodedEdges: [EncodedEdge]?
        let trackActions: [TrackAction]

        init(_ segment: ResolvedSegment, mode: ExportMode) {
            file = segment.file.path
            from = segment.from
            to = segment.to
            outputStart = segment.outputStart
            duration = segment.duration
            tracks = segment.tracks
            encodedEdges = segment.encodedEdges
            let edges = segment.encodedEdges ?? []
            let videoAction: String
            if mode == .encode || (edges.count == 1 && edges[0].from == segment.from && edges[0].to == segment.to) {
                videoAction = "encode"
            } else {
                videoAction = edges.isEmpty ? "copy" : "copyAndEncode"
            }
            trackActions = segment.tracks.compactMap { track in
                if track.kind == "video" {
                    return TrackAction(index: track.index, kind: track.kind, action: videoAction)
                }
                // The encode plan lists output audio actions separately.
                guard mode != .encode else { return nil }
                return TrackAction(index: track.index, kind: track.kind, action: "copy")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, output, segments, duration, container, mode, copiedDuration, encodedDuration, order
        case video, quality, audio, audioActions, width, height, warnings
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encode(edit.segments.map { Segment($0, mode: mode) }, forKey: .segments)
        try fields.encode(edit.duration, forKey: .duration)
        try fields.encode(edit.container, forKey: .container)
        try fields.encode(mode, forKey: .mode)
        try fields.encode(encodedDuration, forKey: .encodedDuration)
        try fields.encode(copiedDuration, forKey: .copiedDuration)
        try fields.encodeIfPresent(order, forKey: .order)
        if let conversion {
            try fields.encode(conversion.settings.codec, forKey: .video)
            try fields.encode(conversion.settings.quality, forKey: .quality)
            try fields.encode(conversion.settings.audio, forKey: .audio)
            try fields.encode(conversion.audioActions, forKey: .audioActions)
            try fields.encode(conversion.width, forKey: .width)
            try fields.encode(conversion.height, forKey: .height)
            try fields.encode(conversion.warnings, forKey: .warnings)
        }
    }
}

private final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var writingResponse = false
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
                let writingResponse = self.writingResponse
                self.lock.unlock()
                // The edit has finished and closed its staging file. A caller
                // reading a partial result may have stopped draining its pipe.
                if writingResponse { Darwin._exit(130) }
            }
            source.activate()
            sources.append(source)
        }
    }

    func beginResponse(checkCancellation: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        if checkCancellation && interrupted { throw CLIError("cancelled", "Operation cancelled.") }
        writingResponse = true
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

private func jsonEncoder(pretty: Bool) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
    return encoder
}

private func writeJSON<T: Encodable>(_ result: T, pretty: Bool = false, checkCancellation: Bool = true) throws {
    var data = try jsonEncoder(pretty: pretty).encode(result)
    data.append(0x0A)
    try interruption.beginResponse(checkCancellation: checkCancellation)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func reportFailure<T: Encodable>(_ error: T, message: String, json: Bool) {
    if json {
        do {
            try writeJSON(Failure(error: error), checkCancellation: false)
        } catch {
            errorOutput("mpcut: Unable to write the result. \(error.localizedDescription)")
        }
    } else {
        try? interruption.beginResponse(checkCancellation: false)
        errorOutput("mpcut: \(message)")
    }
}

private func readInput<T: Decodable>(_ interruption: Interruption) throws -> T {
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
    // Foundation also auto-detects UTF-16/32. Raw NUL bytes are never legal in UTF-8 JSON.
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
        throw CLIError("invalid_json", "Standard input must contain a UTF-8 JSON object.")
    }
    do {
        let edit = try JSONDecoder().decode(T.self, from: data)
        if let key = repeatedJSONKey(in: data) {
            throw CLIError("invalid_json", "Standard input repeats the field '\(key)'.")
        }
        return edit
    } catch let error as CLIError {
        throw error
    } catch {
        if T.self == BulkInput.self {
            throw CLIError("invalid_json", "Expected file, outputDirectory and ranges containing from and to timestamps.")
        }
        if T.self == SceneExportInput.self {
            throw CLIError("invalid_json", "Expected a scene report containing file and scenes with view, start and end.")
        }
        throw CLIError("invalid_json", "Expected an export object with output and clips. File paths are strings, timestamps accept strings or rational objects, and order must be an array of clip numbers.")
    }
}

private func fileURL(_ path: String, label: String) throws -> URL {
    guard !path.isEmpty, !path.utf8.contains(0) else {
        throw CLIError("invalid_path", "\(label) must be a nonempty local file path.")
    }
    // URL folds "link/.." textually to the link's own folder. POSIX resolves ".." physically,
    // so resolve the parent through the file system first.
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    if let name = components.last, name != ".", name != "..", components.dropLast().contains("..") {
        let parentPath = (path.hasPrefix("/") ? "/" : "./") + components.dropLast().joined(separator: "/")
        if let parent = realpath(parentPath, nil) {
            defer { free(parent) }
            return URL(fileURLWithPath: String(cString: parent), isDirectory: true)
                .appendingPathComponent(String(name), isDirectory: false)
        }
    }
    return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
}

private func timestamp(_ value: String?, segment: Int, boundary: String) throws -> RationalTime? {
    guard let value else { return nil }
    do {
        let time = try RationalTime(parsing: value)
        guard time >= .zero else { throw CutError(code: "invalid_time", message: "") }
        return time
    } catch {
        throw CutError(
            code: "invalid_time",
            message: "Clip \(segment) has an invalid \(boundary) timestamp '\(value)'.",
            segment: segment,
            boundary: boundary
        )
    }
}

private final class ExportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = -1
    private let interruption: Interruption

    init(interruption: Interruption) {
        self.interruption = interruption
    }

    func report(_ progress: Double) -> Bool {
        guard interruption.isActive else { return false }
        guard progress.isFinite else { return true }
        let percent = Int((min(1, max(0, progress)) * 100).rounded(.down))

        lock.lock()
        defer { lock.unlock() }
        if percent / 5 > reported {
            // Progress is advisory. A full stderr pipe must never stall
            // an export or prevent its cancellation cleanup.
            var destination = pollfd(fd: STDERR_FILENO, events: Int16(POLLOUT), revents: 0)
            if poll(&destination, 1, 0) > 0 && destination.revents & Int16(POLLOUT) != 0 {
                errorOutput("Export \(percent)%")
            }
            reported = percent / 5
        }
        return true
    }
}

private func validate(_ options: ExportOptions, mode: ExportMode) throws {
    if mode == .encode {
        guard options.snap != .nearest else {
            throw CLIError("invalid_arguments", "--snap nearest applies to copy and smart exports.")
        }
    } else if options.video != nil || options.quality != nil || options.audio != nil {
        throw CLIError("invalid_arguments", "Video, quality and audio settings require --mode encode.")
    }
}

private struct BulkResponse: Encodable {
    let ok: Bool
    let dryRun: Bool
    let outputs: [ExportResult]
    let failedRange: Int?
    let error: CutError?
}

private struct SceneExportResponse: Encodable {
    struct Output: Encodable {
        let view: Int
        let viewLabel: String
        let sceneNumbers: [Int]
        let export: ExportResult
    }

    let ok: Bool
    let dryRun: Bool
    let groupBy: String
    let outputs: [Output]
    let failedRange: Int?
    let error: CutError?
}

private func runBatch(_ batch: BulkExport, dryRun: Bool, interruption: Interruption)
    -> (outputs: [ExportResult], failure: (range: Int, issue: CutError)?) {
    var outputs: [ExportResult] = []
    let progress = ExportProgress(interruption: interruption)
    for (index, item) in batch.items.enumerated() {
        do {
            guard interruption.isActive else {
                throw CutError(code: "cancelled", message: "Operation cancelled.")
            }
            let result = try ExportResult(dryRun: dryRun, output: item.output.path, edit: item.edit,
                                          mode: batch.mode, conversion: item.conversion)
            if !dryRun {
                try batch.write(item) { _ = progress.report((Double(index) + $0) / Double(batch.items.count)) }
            }
            outputs.append(result)
        } catch {
            let issue = error as? CutError ?? CutError(code: "export_failed", message: error.localizedDescription)
            return (outputs, (index + 1, issue))
        }
    }
    return (outputs, nil)
}

private func runScenes(file: String?, options: SceneExportOptions?, json: Bool, interruption: Interruption) throws {
    guard let options else {
        guard let file else { throw CLIError("invalid_arguments", "Scenes requires an input file.") }
        let media = try CutEngine(cancelled: { !interruption.isActive }).inspect(fileURL(file, label: "Input"))
        let report = try SceneAnalysis.scan(media, cancelled: { !interruption.isActive })
        try writeJSON(report, pretty: !json)
        return
    }
    let directory = try fileURL(options.directory, label: "Output directory")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CutError(code: "invalid_output", message: "The output directory must already exist.")
    }
    let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: true)
    let media: MediaInfo
    let request: SceneExportInput
    if let file {
        media = try engine.inspect(fileURL(file, label: "Input"), keyframes: true)
        let report = try SceneAnalysis.scan(media, cancelled: { !interruption.isActive })
        request = SceneExportInput(report)
    } else {
        request = try readInput(interruption)
        media = try engine.inspect(fileURL(request.file, label: "Input"), keyframes: true)
    }
    let jobs = try request.jobs(for: media, grouping: options.grouping)
    let batch = try BulkExport(groups: jobs.map(\.clips), directory: directory, outputSuffixes: jobs.map(\.outputSuffix),
                               container: options.container, media: [media.url: media], cancelled: { !interruption.isActive })
    let result = runBatch(batch, dryRun: options.dryRun, interruption: interruption)
    let outputs = zip(jobs, result.outputs).map { job, export in
        SceneExportResponse.Output(view: job.view, viewLabel: job.viewLabel, sceneNumbers: job.sceneNumbers, export: export)
    }
    try writeJSON(SceneExportResponse(ok: result.failure == nil, dryRun: options.dryRun, groupBy: options.grouping.rawValue,
                                     outputs: outputs, failedRange: result.failure?.range, error: result.failure?.issue),
                  pretty: !json, checkCancellation: options.dryRun && result.failure == nil)
    if let failure = result.failure {
        exit(failure.issue.code == "cancelled" ? 130 : 1)
    }
}

private func run(_ arguments: Arguments, interruption: Interruption) throws {
    switch arguments.command {
    case .version:
        if arguments.json {
            try writeJSON(["version": Arguments.version])
        } else {
            try interruption.beginResponse()
            print(Arguments.version)
        }
    case .help:
        if arguments.json {
            try writeJSON(CLIHelp())
        } else {
            try interruption.beginResponse()
            print(Arguments.usage)
        }
    case let .scenes(file, options):
        try runScenes(file: file, options: options, json: arguments.json, interruption: interruption)
    case let .inspect(file, keyframes, allFrames, from, to):
        let engine = CutEngine(cancelled: { !interruption.isActive })
        try interruption.check()
        let media = try engine.inspect(fileURL(file, label: "Input"), keyframes: keyframes || allFrames)
        let issue = media.copyIssue ?? (media.sourceStartSafe ? nil : "The source does not begin at a verified video access point.")
        let containers = issue == nil ? engine.suggestedContainers(for: media) : []
        try interruption.check()
        let data = try inspectionJSON(media, copy: CopyEligibility(reason: issue, containers: containers),
                                      allFrames: allFrames, from: from, to: to, pretty: !arguments.json, interruption: interruption)
        try interruption.beginResponse()
        try FileHandle.standardOutput.write(contentsOf: data)
    case let .bulk(dryRun, flags):
        let input: BulkInput = try readInput(interruption)
        let options = try flags.merging(input.options)
        let mode = options.mode ?? .smart
        try validate(options, mode: mode)
        let file = try fileURL(input.file, label: "Source")
        let directory = try fileURL(input.outputDirectory, label: "Output directory")
        let groups = try input.ranges.enumerated().map { index, range in
            [try ClipRequest(file: file, from: timestamp(range.from, segment: index + 1, boundary: "from"),
                             to: timestamp(range.to, segment: index + 1, boundary: "to"))]
        }
        let settings = ReencodeSettings(codec: options.video ?? .h264, quality: options.quality, audio: options.audio ?? .auto)
        let batch = try BulkExport(groups: groups, directory: directory, mode: mode, container: input.container,
                                   snap: options.snap ?? .exact, settings: settings, cancelled: { !interruption.isActive })
        let result = runBatch(batch, dryRun: dryRun, interruption: interruption)
        try writeJSON(BulkResponse(ok: result.failure == nil, dryRun: dryRun, outputs: result.outputs,
                                   failedRange: result.failure?.range, error: result.failure?.issue),
                      checkCancellation: dryRun && result.failure == nil)
        if let failure = result.failure {
            exit(failure.issue.code == "cancelled" ? 130 : 1)
        }
    case let .export(supplied, dryRun, flags, requestedOrder):
        let input = try supplied ?? readInput(interruption)
        let options = try flags.merging(input.options)
        guard !input.clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires at least one clip.")
        }
        let order = try input.resolvedOrder(requestedOrder)
        let mode = options.mode ?? (order == nil ? .copy : .smart)
        try validate(options, mode: mode)
        let output = try fileURL(input.output, label: "Output")
        let clips = try (order ?? Array(1...input.clips.count)).map { number in
            let clip = input.clips[number - 1]
            guard let path = clip.file ?? input.file else {
                throw CLIError("invalid_json", "Clip \(number) requires a file path or a top-level file.")
            }
            return try ClipRequest(
                file: fileURL(path, label: "Clip \(number)"),
                from: timestamp(clip.from, segment: number, boundary: "from"),
                to: timestamp(clip.to, segment: number, boundary: "to")
            )
        }
        try interruption.check()
        let progress = ExportProgress(interruption: interruption)
        let result: ExportResult
        switch mode {
        case .copy, .smart:
            let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: mode == .smart)
            let edit = try engine.resolve(clips, output: output, snap: options.snap ?? .exact)
            result = try ExportResult(dryRun: dryRun, output: output.path, edit: edit, mode: mode, conversion: nil, order: order)
            try interruption.check()
            if !dryRun {
                try engine.export(edit, to: output) { progress.report($0) }
            }
        case .encode:
            let engine = ReencodeEngine(cancelled: { !interruption.isActive })
            let codec = options.video ?? .h264
            let container = output.pathExtension.isEmpty
                ? (codec == .prores ? "mov" : "mp4") : output.pathExtension.lowercased()
            let settings = ReencodeSettings(codec: codec, quality: options.quality, audio: options.audio ?? .auto)
            let plan = try engine.resolve(clips, output: output, container: container, settings: settings)
            result = try ExportResult(dryRun: dryRun, output: output.path, edit: plan.edit, mode: mode, conversion: plan, order: order)
            try interruption.check()
            if !dryRun {
                try engine.write(plan, to: output) { _ = progress.report($0) }
            }
        }
        if arguments.json || dryRun {
            try writeJSON(result, pretty: !arguments.json, checkCancellation: dryRun)
        } else {
            try interruption.beginResponse(checkCancellation: false)
            for warning in result.conversion?.warnings ?? [] {
                errorOutput("mpcut: \(warning)")
            }
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
