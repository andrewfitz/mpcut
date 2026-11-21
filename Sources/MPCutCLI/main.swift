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
        case url, format, duration, origin, streams, audio, copyIssue, sourceStartSafe, hasVideo
    }

    func encode(to encoder: Encoder) throws {
        var details = encoder.container(keyedBy: CodingKeys.self)
        try details.encode(media.url, forKey: .url)
        try details.encode(media.format, forKey: .format)
        try details.encode(media.hasVideo, forKey: .hasVideo)
        try details.encode(media.duration, forKey: .duration)
        try details.encode(media.origin, forKey: .origin)
        try details.encode(media.streams, forKey: .streams)
        try details.encode(media.audio, forKey: .audio)
        try details.encodeIfPresent(media.copyIssue, forKey: .copyIssue)
        try details.encode(media.sourceStartSafe, forKey: .sourceStartSafe)
    }
}

private struct CLIHelp: Encodable {
    let sidecarSections = SidecarContent.allCases.map(\.rawValue)
    let readsSidecarsByDefault = true
    let framePresets = JPEGPreset.allCases.map(\.rawValue)
    let frameSamples = JPEGSample.allCases.map(\.rawValue)
    let usage = CommandHelp.synopsis
    let conventions = CommandHelp.conventions
    let commands = Dictionary(uniqueKeysWithValues: CommandHelp.commands.map { ($0.name, $0) })
    let version = Arguments.version
    let exportModes = ExportMode.allCases.map(\.rawValue)
    let exportTracks = ExportTracks.allCases.map(\.rawValue)
    let supportsAudioReplacement = true
    let videoCodecs = ReencodeCodec.allCases.map(\.rawValue)
    let qualities = ReencodeQuality.allCases.map(\.rawValue)
    let audioOptions = ReencodeAudio.allCases.map(\.rawValue)
    let snapOptions = SnapMode.allCases.map(\.rawValue)
    let defaultExportMode = ExportMode.copy.rawValue
    let defaultOrderedExportMode = ExportMode.smart.rawValue
    let defaultMulticamExportMode = ExportMode.smart.rawValue
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

private struct PacketPoint: Encodable {
    let stream: Int
    let time: RationalTime
    let duration: RationalTime
    let dts: RationalTime?
    let skipSamples: Int
    let discardSamples: Int
}

private func inspectionJSON(_ media: MediaInfo, copy: CopyEligibility, allFrames: Bool, packets: AudioIndex?,
                            from: RationalTime?, to: RationalTime?, pretty: Bool,
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
    let header = pretty ? "{\n  \"ok\" : true,\n  \"file\" : " : #"{"ok":true,"file":"#
    result.append(contentsOf: header.utf8)
    result.append(try encoder.encode(media.url.path))
    result.append(contentsOf: (pretty ? ",\n  \"preview\" : \"unchecked\",\n  \"copy\" : "
                                      : #","preview":"unchecked","copy":"#).utf8)
    appendJSON(try encoder.encode(copy), indent: "  ")
    result.append(contentsOf: (pretty ? ",\n  \"media\" : " : #","media":"#).utf8)
    // InspectionSummary always encodes an object. Append the frames member
    // before closing that object, keeping paths and other strings JSON-escaped.
    var metadata = try encoder.encode(InspectionSummary(media: media)).dropLast()
    if metadata.last == 0x0a { metadata = metadata.dropLast() }
    appendJSON(metadata, indent: "  ")
    result.append(contentsOf: (pretty ? ",\n    \"frames\" : [" : #","frames":["#).utf8)
    var needsComma = false
    func appendBatches<Row, Point: Encodable>(_ rows: [Row], time: KeyPath<Row, RationalTime>,
                                               point: (Row) -> Point?) throws {
        let batchSize = 512
        var starts: [Int] = []
        for start in stride(from: 0, to: rows.count, by: batchSize) {
            try interruption.check()
            if let to, rows[start][keyPath: time] >= to { break }
            if let from, rows[min(start + batchSize, rows.count) - 1][keyPath: time] < from { continue }
            starts.append(start)
        }
        try forEachOrderedBatch(count: starts.count, batchSize: 1, check: interruption.check, transform: { indices -> Data? in
            let start = starts[indices.lowerBound]
            let points = rows[start..<min(start + batchSize, rows.count)].compactMap(point)
            guard !points.isEmpty else { return nil }
            return try jsonEncoder(pretty: pretty).encode(points)
        }, consume: { fragment in
            guard let fragment else { return }
            if needsComma { result.append(0x2c) }
            var elements = fragment.dropFirst().dropLast()
            if elements.last == 0x0a { elements = elements.dropLast() }
            appendJSON(elements, indent: "    ")
            needsComma = true
        })
    }
    try appendBatches(media.frames, time: \.time) { frame -> AccessPoint? in
        let canStart = frame.time == .zero ? media.sourceStartSafe :
            frame.canStart && frame.time > .zero && frame.time < media.duration
        if let from, frame.time < from { return nil }
        if let to, frame.time >= to { return nil }
        guard allFrames || frame.keyframe || canStart else { return nil }
        return AccessPoint(dts: frame.dts, time: frame.time, duration: frame.duration,
                           keyframe: frame.keyframe, canStart: canStart, canEnd: frame.canEnd)
    }
    if pretty && needsComma { result.append(contentsOf: "\n    ".utf8) }
    if let packets {
        result.append(contentsOf: (pretty ? "],\n    \"audioPackets\" : [" : #"],"audioPackets":["#).utf8)
        needsComma = false
        try appendBatches(packets.packets, time: \.time) { packet -> PacketPoint? in
            if let from, packet.time < from { return nil }
            if let to, packet.time >= to { return nil }
            return PacketPoint(stream: packets.stream.index, time: packet.time, duration: packet.duration,
                               dts: packet.dts, skipSamples: packet.skipSamples, discardSamples: packet.discardSamples)
        }
        if pretty && needsComma { result.append(contentsOf: "\n    ".utf8) }
    }
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
    var sourceFiles: [URL] = []
    var silence: SilenceExportSummary?

    init(dryRun: Bool, output: String, edit: ResolvedEdit, mode: ExportMode, conversion: ReencodePlan?,
         order: [Int]? = nil) throws {
        self.dryRun = dryRun
        self.output = output
        self.edit = edit
        self.mode = edit.tracks == .all ? mode : .copy
        self.conversion = conversion
        self.order = order
        self.copiedDuration = try edit.copiedVideoDuration(for: mode)
        self.encodedDuration = try edit.encodedVideoDuration(for: mode)
    }

    struct Segment: Encodable {
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

        init(_ segment: ResolvedSegment, mode: ExportMode, audioAction: ReencodeAudio? = nil, original: URL? = nil) {
            file = (original ?? segment.file).path
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
                if let audioAction {
                    return TrackAction(index: track.index, kind: track.kind,
                                       action: audioAction == .copyOriginal ? "copy" : "encode")
                }
                // The encode plan lists output audio actions separately.
                guard mode != .encode else { return nil }
                return TrackAction(index: track.index, kind: track.kind, action: "copy")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, output, segments, duration, container, mode, copiedDuration, encodedDuration, order
        case video, quality, audio, audioActions, width, height, warnings, silence, tracks, audioStream
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encode(edit.segments.map { segment in
            let original = segment.sourceClipIndex.flatMap { sourceFiles.indices.contains($0) ? sourceFiles[$0] : nil }
            return Segment(segment, mode: mode, original: original)
        }, forKey: .segments)
        try fields.encode(edit.duration, forKey: .duration)
        try fields.encode(edit.container, forKey: .container)
        try fields.encode(mode, forKey: .mode)
        if edit.tracks != .all { try fields.encode(edit.tracks, forKey: .tracks) }
        try fields.encodeIfPresent(edit.audioStream, forKey: .audioStream)
        try fields.encode(encodedDuration, forKey: .encodedDuration)
        try fields.encode(copiedDuration, forKey: .copiedDuration)
        try fields.encodeIfPresent(order, forKey: .order)
        try fields.encodeIfPresent(silence, forKey: .silence)
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

private struct MulticamInspectionResponse: Encodable {
    let ok = true
    let project: String
    let report: MulticamInspection
    let groupIntervals: [MulticamInterval]

    private enum CodingKeys: String, CodingKey { case ok, project, inspection, groupIntervals }
    private enum InspectionKeys: String, CodingKey { case mapping, sources, issues }
    private enum SourceKeys: String, CodingKey { case source, media, coverage, audioCoverage }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(project, forKey: .project)
        try fields.encode(groupIntervals, forKey: .groupIntervals)
        var inspection = fields.nestedContainer(keyedBy: InspectionKeys.self, forKey: .inspection)
        try inspection.encode(report.mapping, forKey: .mapping)
        try inspection.encode(report.issues, forKey: .issues)
        var sources = inspection.nestedUnkeyedContainer(forKey: .sources)
        for result in report.sources {
            var source = sources.nestedContainer(keyedBy: SourceKeys.self)
            try source.encode(result.source, forKey: .source)
            try source.encode(InspectionSummary(media: result.media), forKey: .media)
            try source.encode(result.coverage, forKey: .coverage)
            try source.encode(result.audioCoverage, forKey: .audioCoverage)
        }
    }
}

private struct MulticamExportResponse: Encodable {
    let ok = true
    let dryRun: Bool
    let output: String
    let order: [Int]?
    let sources: [String: String]
    let preflight: MulticamExportPlan

    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, output, order, sources, plan, mode, tracks, container, duration, warnings
        case picture, audio, audioAction, copiedVideoDuration, encodedVideoDuration
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encodeIfPresent(order, forKey: .order)
        try fields.encode(sources, forKey: .sources)
        try fields.encode(preflight.mapping, forKey: .plan)
        try fields.encode(preflight.mode, forKey: .mode)
        try fields.encode(preflight.tracks, forKey: .tracks)
        try fields.encode(preflight.container, forKey: .container)
        try fields.encode(preflight.duration, forKey: .duration)
        try fields.encode(preflight.warnings, forKey: .warnings)
        try fields.encode(preflight.copiedVideoDuration, forKey: .copiedVideoDuration)
        try fields.encode(preflight.encodedVideoDuration, forKey: .encodedVideoDuration)
        try fields.encode(preflight.picture.map { ExportResult.Segment($0, mode: preflight.mode) }, forKey: .picture)
        try fields.encode(preflight.audio.map {
            ExportResult.Segment($0, mode: .copy, audioAction: preflight.audioAction)
        }, forKey: .audio)
        try fields.encodeIfPresent(preflight.audioAction, forKey: .audioAction)
    }
}

private struct ReplacementResult: Encodable {
    let ok = true
    let mode = "copy"
    let encodedDuration = RationalTime.zero
    let dryRun: Bool
    let output: String
    let duration: RationalTime
    let copiedDuration: RationalTime
    let container: String
    let replacement: AudioReplacementPlan
}

private final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var writingResponse = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        let queue = DispatchQueue(label: "mpcut.signals")
        for number in [SIGINT, SIGTERM, SIGHUP] {
            // A hangup that the caller chose to ignore, as under nohup, must not cancel the edit.
            if number == SIGHUP {
                var inherited = sigaction()
                if sigaction(number, nil, &inherited) == 0,
                   unsafeBitCast(inherited.__sigaction_u.__sa_handler, to: Int.self)
                    == unsafeBitCast(SIG_IGN, to: Int.self) { continue }
            }
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
    try writeOutput(data)
}

/// A failed write to standard output. A closed pipe (`EPIPE`) ends the command quietly.
private struct OutputError: Error {
    let code: Int32
}

private func writeOutput(_ text: String) throws {
    try writeOutput(Data((text + "\n").utf8))
}

private func writeOutput(_ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
            if count >= 0 {
                offset += count
            } else if errno == EAGAIN {
                var output = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = poll(&output, 1, -1)
            } else if errno != EINTR {
                throw OutputError(code: errno)
            }
        }
    }
}

private func reportOutputFailure(_ error: OutputError) {
    guard error.code != EPIPE else { return }
    errorOutput("mpcut: Unable to write to standard output. \(String(cString: strerror(error.code)))")
}

private func reportFailure<T: Encodable>(_ error: T, message: String, json: Bool) {
    if json {
        do {
            try writeJSON(Failure(error: error), checkCancellation: false)
        } catch let error as OutputError {
            reportOutputFailure(error)
        } catch {
            errorOutput("mpcut: Unable to write to standard output. \(error.localizedDescription)")
        }
    } else {
        try? interruption.beginResponse(checkCancellation: false)
        errorOutput("mpcut: \(message)")
    }
}

private let inputLimit = 64 * 1024 * 1024

/// A saved project and the location that its relative media paths resolve from.
private struct LoadedProject {
    let project: MulticamProject
    let location: URL
    /// Nil when the project arrived on standard input.
    let file: URL?
    var path: String { file?.path ?? "-" }
}

private func isStandardInput(_ path: String) -> Bool {
    ["-", "/dev/stdin", "/dev/fd/0"].contains(path)
}

/// `--project -` reads the project from standard input under the request limit. Its relative
/// media paths then resolve from the working directory, as paths in a stdin request do.
private func loadProject(_ path: String, interruption: Interruption) throws -> LoadedProject {
    guard isStandardInput(path) else {
        let location = try fileURL(path, label: "Project")
        return LoadedProject(project: try MulticamProject.load(from: location), location: location, file: location)
    }
    let project = try MulticamProject.decode(try readStandardInput(interruption))
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return LoadedProject(project: project, location: directory.appendingPathComponent("-"), file: nil)
}

private func readInput<T: Decodable>(_ interruption: Interruption) throws -> T {
    let data = try readStandardInput(interruption)
    // Foundation also auto-detects UTF-16/32. Raw NUL bytes are never legal in UTF-8 JSON.
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
        throw CLIError("invalid_json", "Standard input must contain a UTF-8 JSON object.")
    }
    do {
        let edit = try JSONDecoder().decode(T.self, from: data)
        if let issue = jsonInputIssue(data) {
            throw CLIError("invalid_json", "Standard input \(issue).")
        }
        return edit
    } catch let error as CLIError {
        throw error
    } catch {
        if T.self == BulkInput.self {
            throw CLIError("invalid_json", "Expected file, outputDirectory and ranges containing from and to timestamps.")
        }
        if T.self == SilenceInput.self {
            throw CLIError("invalid_json", "Expected a silence report containing file, sourceStamp, duration, stream, thresholdDB, minimumPause, leave, mode and pauses.")
        }
        if T.self == SceneExportInput.self {
            throw CLIError("invalid_json", "Expected a scene report containing file and scenes with view, start and end.")
        }
        throw CLIError("invalid_json", "Expected an export object with output and clips. File and project paths are strings, timestamps accept strings or rational objects, and order must be an array of clip numbers.")
    }
}

private func readStandardInput(_ interruption: Interruption) throws -> Data {
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
        guard data.count + count <= inputLimit else {
            throw CLIError("invalid_json", "Standard input exceeds the 64 MB request limit.")
        }
        data.append(contentsOf: buffer.prefix(count))
    }

    try interruption.check()
    return data
}

private func fileURL(_ path: String, label: String, directory: Bool = false) throws -> URL {
    guard !path.isEmpty, !path.utf8.contains(0) else {
        throw CLIError("invalid_path", "\(label) must be a nonempty local file path.")
    }
    // URL folds "link/.." textually to the link's own folder. POSIX resolves ".." physically,
    // so resolve everything up to the last ".." through the file system. A ".." that cannot be
    // resolved is rejected rather than folded, as opening the path would fail.
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    if !directory && (path.hasSuffix("/") || components.last == "." || components.last == "..") {
        if label == "Output" { throw CutError(code: "invalid_output", message: "Choose a local destination file.") }
        throw CLIError("invalid_path", "\(label) must name a file: '\(path)'.")
    }
    guard let last = components.lastIndex(of: "..") else {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        return URL(fileURLWithPath: absolute, isDirectory: directory).standardizedFileURL
    }
    let prefix = (path.hasPrefix("/") ? "/" : "./") + components[...last].joined(separator: "/")
    guard let real = realpath(prefix, nil) else {
        throw CLIError("invalid_path", "\(label) path '\(path)' cannot be resolved: \(String(cString: strerror(errno))).")
    }
    defer { free(real) }
    return components[(last + 1)...].filter { $0 != "." }.reduce(URL(fileURLWithPath: String(cString: real), isDirectory: true)) {
        $0.appendingPathComponent(String($1), isDirectory: false)
    }
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
    try options.checkTrackSelection()
    if mode == .encode {
        guard (options.tracks ?? .all) == .all, options.replaceAudio == nil else {
            throw CLIError("invalid_arguments", "A selected track type or audio replacement uses stream copy.")
        }
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
        let report = try SceneAnalysis.scan(fileURL(file, label: "Input"), cancelled: { !interruption.isActive })
        try writeJSON(report, pretty: !json)
        return
    }
    let directory = try fileURL(options.directory, label: "Output directory", directory: true)
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
                               tracks: options.tracks, audioStream: options.audioStream, container: options.container, media: [media.url: media], cancelled: { !interruption.isActive })
    let result = runBatch(batch, dryRun: options.dryRun, interruption: interruption)
    let outputs = zip(jobs, result.outputs).map { job, export in
        SceneExportResponse.Output(view: job.view, viewLabel: job.viewLabel, sceneNumbers: job.sceneNumbers, export: export)
    }
    try writeJSON(SceneExportResponse(ok: result.failure == nil, dryRun: options.dryRun, groupBy: options.grouping.rawValue,
                                     outputs: outputs, failedRange: result.failure?.range, error: result.failure?.issue),
                  pretty: !json, checkCancellation: options.dryRun && result.failure == nil)
    if let failure = result.failure {
        exit(exitStatus(failure.issue.code, operation: true))
    }
}

private struct SilenceExportSummary: Encodable {
    let thresholdMode: SilenceThresholdMode
    let thresholdDB: Double
    let detectedPauses: Int
    let shortenedPauses: Int
    let skippedPauses: Int
    let removedDuration: RationalTime
    let waveformPeakDBFS: [Double?]?
}

private func runSilence(_ options: SilenceOptions, json: Bool, interruption: Interruption) throws {
    if let project = options.project {
        try runProjectSilence(options, path: project, json: json, interruption: interruption)
        return
    }
    let saved = options.stdin ? try readInput(interruption) as SilenceInput : nil
    guard let path = saved?.file ?? options.file else { throw CLIError("invalid_arguments", "Supply a media file.") }
    let source = try fileURL(path, label: "Input")
    let tracks = options.tracks ?? saved?.tracks ?? .all
    let audioStream = options.audioStream ?? (tracks == .audio ? saved?.audioStream : nil)
    if let audioStream, tracks != .audio || audioStream < 0 {
        throw CLIError("invalid_arguments", "--audio-stream requires --tracks audio and a nonnegative absolute stream index.")
    }
    let requestedMode = options.mode ?? saved?.mode ?? .smart
    let mode: ExportMode = tracks == .all ? requestedMode : .copy
    guard requestedMode != .encode, saved?.ok != false else {
        throw CLIError("invalid_json", "Supply a successful silence report with smart or copy mode.")
    }
    let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: mode == .smart, tracks: tracks, audioStream: audioStream)
    let original = try engine.inspect(source, keyframes: true)
    let media = tracks == .audio ? try original.extendingToAudioEnd(stream: audioStream) : original
    let reuseAnalysis = original.duration == media.duration
    if tracks == .video && !media.hasVideo { throw CutError(code: "no_video", message: "Video output requires a video stream.") }
    if let audioStream, !media.streams.contains(where: { $0.kind == "audio" && $0.index == audioStream }) {
        throw CutError(code: "no_audio", message: "The source has no matching output audio stream.")
    }
    let stamp = SceneSourceStamp(media: media)
    if let saved {
        let scanned = saved.tracks == .audio ? try original.extendingToAudioEnd(stream: saved.audioStream) : original
        guard saved.sourceStamp == stamp,
              saved.duration == scanned.duration || saved.duration == original.duration else {
            throw CutError(code: "source_changed", message: "The recording differs from the saved silence report.")
        }
    }
    let track = saved?.stream ?? options.stream ?? audioStream ?? media.streams.first(where: { $0.kind == "audio" })?.index
    guard let track, media.streams.contains(where: { $0.index == track && $0.kind == "audio" }) else {
        throw CutError(code: "no_audio", message: "The source has no matching audio stream.")
    }
    let threshold: Double
    let thresholdMode: SilenceThresholdMode
    let minimum = saved?.minimumPause ?? options.minimum
    let leave = options.leave ?? saved?.leave ?? 0.4
    let pauses: [AudioSpan]
    var columns: [Double?]?
    if let saved {
        threshold = saved.thresholdDB
        thresholdMode = saved.thresholdMode ?? .manual
        var cursor = RationalTime.zero
        guard leave >= 0, minimum > 0, (-120...0).contains(threshold),
              saved.pauses.allSatisfy({ span in
                  defer { cursor = span.to }
                  return span.from >= cursor && span.to > span.from && span.to <= saved.duration
              }) else { throw CLIError("invalid_json", "Invalid settings or overlapping/out-of-bounds pauses.") }
        pauses = saved.pauses.prefix { $0.from < media.duration }.map {
            AudioSpan(from: $0.from, to: min($0.to, media.duration))
        }
    } else {
        let wave = try options.columns.map { _ in
            try AudioAnalysis.scan(media, stream: track, useSidecar: reuseAnalysis, cancelled: { !interruption.isActive })
        }
        let detection = try AudioAnalysis.silence(media, stream: track, thresholdDB: options.thresholdDB,
                                                  minimum: minimum, waveform: wave, useSidecar: reuseAnalysis,
                                                  cancelled: { !interruption.isActive })
        threshold = detection.thresholdDB
        thresholdMode = options.thresholdDB == nil ? .auto : .manual
        pauses = detection.pauses
        if let wave, let count = options.columns {
            let width = media.duration.seconds / Double(count)
            columns = (0..<count).map { i in
                wave.peak(from: Double(i) * width, to: Double(i + 1) * width).map {
                    max(-120, 20 * log10(Double(max(0.000001, $0))))
                }
            }
        }
    }
    let output = try options.output.map { try fileURL($0, label: "Output") }
    let ext = output?.pathExtension.lowercased()
    let cuts = silenceRemovals(pauses, in: media, leave: leave, engine: engine, tracks: tracks, audioStream: audioStream,
                               container: ext?.isEmpty == false ? ext : nil)
    let retained = AudioAnalysis.retained(in: AudioSpan(from: .zero, to: media.duration), removing: cuts)
    let removedDuration = cuts.reduce(RationalTime.zero) { $0 + ($1.to - $1.from) }
    try interruption.check()
    guard let output else {
        let report = SilenceData(file: source.path, sourceStamp: stamp, duration: media.duration,
                                 stream: track, thresholdMode: thresholdMode, thresholdDB: threshold, minimumPause: minimum, leave: leave,
                                 mode: media.hasVideo ? mode : .copy, tracks: tracks == .all ? nil : tracks, audioStream: audioStream, pauses: pauses, removals: cuts, clips: retained,
                                 skippedPauses: pauses.count - cuts.count,
                                 removedDuration: removedDuration,
                                 waveformPeakDBFS: columns)
        try writeJSON(report, pretty: !json)
        return
    }
    guard !retained.isEmpty else {
        throw CutError(code: "empty_edit", message: "The selected pauses cover the entire source. Increase --leave to retain footage.")
    }
    let clips = retained.map { ClipRequest(file: source, from: $0.from, to: $0.to) }
    let edit = try engine.resolve(clips, output: output, media: [media.url: media])
    var result = try ExportResult(dryRun: options.dryRun, output: output.path, edit: edit, mode: mode, conversion: nil)
    result.silence = SilenceExportSummary(thresholdMode: thresholdMode, thresholdDB: threshold,
                                          detectedPauses: pauses.count, shortenedPauses: cuts.count,
                                          skippedPauses: pauses.count - cuts.count, removedDuration: removedDuration,
                                          waveformPeakDBFS: columns)
    if !options.dryRun {
        let progress = ExportProgress(interruption: interruption)
        try engine.export(edit, to: output) { progress.report($0) }
    }
    try writeJSON(result, pretty: !json, checkCancellation: options.dryRun)
}

private func runProjectSilence(_ options: SilenceOptions, path: String, json: Bool,
                               interruption: Interruption) throws {
    let loaded = try loadProject(path, interruption: interruption)
    let (project, location) = (loaded.project, loaded.location)
    let output = try options.output.map { try fileURL($0, label: "Output") }
    let cancelled: @Sendable () -> Bool = { !interruption.isActive }
    let engine = MulticamEngine(cancelled: cancelled)
    let container = try output.map { try engine.checkCombinedDestination($0) } ?? "mov"
    var report = try ProjectSilenceReport(project, at: location, options: options,
                                          container: container, cancelled: cancelled)
    report.project = loaded.path
    if let output {
        guard !report.clips.isEmpty else {
            throw CutError(code: "empty_edit", message: "The selected pauses cover the entire assembly. Increase --leave to retain footage.")
        }
        let preflight = try engine.resolve(project, relativeTo: location, output: output, mode: report.mode,
                                           assembly: report.clips.map { MulticamSilencePlanner.range($0.group) },
                                           indexedSources: report.indexedSources)
        report.output = output.path
        report.dryRun = options.dryRun
        report.preflight = preflight
    }
    try report.checkSources(cancelled: cancelled)
    if let output, let preflight = report.preflight, !options.dryRun {
        let progress = ExportProgress(interruption: interruption)
        try engine.write(preflight, to: output) { _ = progress.report($0) }
    }
    try writeJSON(report, pretty: !json, checkCancellation: output == nil || options.dryRun)
}

private func runMulticamExport(project path: String? = nil, input: InputEdit? = nil,
                               order: [Int]? = nil, output: URL, options: ExportOptions,
                               dryRun: Bool, json: Bool, interruption: Interruption) throws {
    let tracks = options.tracks ?? .all
    // Reject the settings multicam never accepts before the general checks, whose advice
    // (add --tracks audio, add --replace-audio, change the mode) would lead to another refusal.
    guard options.snap != .nearest else {
        throw CLIError("invalid_arguments", "Multicam export uses exact cuts. Apply a suggested group time to the project or request before exporting.")
    }
    guard options.audioStream == nil else {
        throw CLIError("invalid_arguments", "Choose project microphones in the project audio policy, angle audioStream fields, or switch overrides.")
    }
    guard options.replaceAudio == nil, options.replaceTrack == nil, options.replacementStream == nil else {
        throw CLIError("invalid_arguments", "Set an external recorder in audioSources and select it in the project audio policy.")
    }
    if tracks != .all, let requested = options.mode, requested != .copy {
        throw CLIError("invalid_arguments", "Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.")
    }
    let mode = tracks == .all ? (options.mode ?? .smart) : .copy
    try validate(options, mode: options.mode ?? mode)
    let settings = ReencodeSettings(codec: options.video ?? .h264, quality: options.quality, audio: options.audio ?? .auto)
    let engine = MulticamEngine(cancelled: { !interruption.isActive })
    let plan: MulticamExportPlan
    let sources: [String: URL]
    if let path {
        let loaded = try loadProject(path, interruption: interruption)
        let (project, location) = (loaded.project, loaded.location)
        sources = Dictionary(uniqueKeysWithValues: (project.angles + project.audioSources).map {
            ($0.id, project.sourceURL(for: $0, relativeTo: location))
        })
        plan = try engine.resolve(project, relativeTo: location, output: output, mode: mode, tracks: tracks, settings: settings)
    } else if let input {
        var assembly = MulticamAssembly()
        var projects: [URL: MulticamProject] = [:]
        var files: [URL: MediaInfo] = [:]
        let fileEngine = CutEngine(cancelled: { !interruption.isActive })
        for number in order ?? Array(1...input.clips.count) {
            try interruption.check()
            let clip = input.clips[number - 1]
            let from = try timestamp(clip.from, segment: number, boundary: "from")
            let to = try timestamp(clip.to, segment: number, boundary: "to")
            if let path = clip.project {
                guard !isStandardInput(path) else {
                    throw CLIError("invalid_json", "Project clip \(number) must name a saved project file. Standard input carries the request. Use ./- for a file named '-'.")
                }
                let location = try fileURL(path, label: "Project clip \(number)")
                let project: MulticamProject
                if let loaded = projects[location] {
                    project = loaded
                } else {
                    do {
                        project = try MulticamProject.load(from: location)
                    } catch let error as CutError {
                        // Name the clip, as a request can reference several projects.
                        throw CutError(code: error.code, message: "Project clip \(number) (\(location.path)): \(error.message)",
                                       segment: number)
                    }
                    projects[location] = project
                }
                try assembly.appendProject(project, at: location,
                                           range: MulticamRange(from: from ?? project.range.from, to: to ?? project.range.to),
                                           segment: number)
            } else {
                guard let path = clip.file ?? input.file else {
                    throw CLIError("invalid_json", "Clip \(number) requires a project or file path, or a top-level file.")
                }
                let location = try fileURL(path, label: "Clip \(number)")
                let media: MediaInfo
                if let cached = files[location] {
                    media = cached
                } else if tracks == .audio {
                    let source = try fileEngine.inspect(location)
                    let stream = source.streams.first(where: { $0.kind == "audio" })?.index
                    media = try source.extendingToAudioEnd(stream: stream)
                } else {
                    media = try fileEngine.inspectSummary(location)
                }
                files[location] = media
                try assembly.appendFile(media, range: MulticamRange(from: from ?? .zero, to: to ?? media.duration),
                                        segment: number, tracks: tracks)
            }
        }
        sources = assembly.sources
        let request = assembly
        plan = try engine.resolve(request.mapping, sources: sources, output: output, mode: mode,
                                  tracks: tracks, settings: settings, requireAudio: request.requiresAudio) { clip, boundary, time in
            try request.moving(clip: clip, boundary: boundary, to: time).mapping
        }
    } else {
        throw CLIError("invalid_arguments", "Export a project or an ordered list of clips.")
    }
    try interruption.check()
    if !dryRun {
        let progress = ExportProgress(interruption: interruption)
        try engine.write(plan, to: output) { _ = progress.report($0) }
    }
    if json || dryRun {
        try writeJSON(MulticamExportResponse(dryRun: dryRun, output: output.path, order: order,
                                            sources: sources.mapValues(\.path), preflight: plan),
                      pretty: !json, checkCancellation: dryRun)
    } else {
        try interruption.beginResponse(checkCancellation: false)
        for warning in plan.warnings { errorOutput("mpcut: \(warning)") }
        try writeOutput("Exported \(output.path)")
    }
}

private func run(_ arguments: Arguments, interruption: Interruption) async throws {
    switch arguments.command {
    case let .sidecar(options):
        let source = try fileURL(options.file, label: "Input")
        let result = try await AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
            try await options.run(source: source, cancelled: { !interruption.isActive })
        }
        try writeJSON(result, pretty: !arguments.json, checkCancellation: options.statusOnly)
    case .version:
        if arguments.json {
            try writeJSON(["version": Arguments.version])
        } else {
            try interruption.beginResponse()
            try writeOutput(Arguments.version)
        }
    case .manual:
        let manual = CommandHelp.manual
        if arguments.json {
            try writeJSON(["version": Arguments.version, "manual": manual])
        } else {
            try interruption.beginResponse()
            try writeOutput(manual)
        }
    case let .help(topic):
        if arguments.json {
            if let topic { try writeJSON(topic) } else { try writeJSON(CLIHelp()) }
        } else {
            try interruption.beginResponse()
            try writeOutput(topic?.text ?? CommandHelp.overview)
        }
    case let .silence(options):
        try runSilence(options, json: arguments.json, interruption: interruption)
    case let .scenes(file, options):
        try runScenes(file: file, options: options, json: arguments.json, interruption: interruption)
    case let .waveform(options):
        let result = try options.run(fileURL(options.file, label: "Input"), cancelled: { !interruption.isActive })
        try writeJSON(result, pretty: !arguments.json)
    case let .frames(options):
        let output = try fileURL(options.output, label: "Output directory", directory: true)
        switch options.source {
        case let .video(file, selection, sample, limit):
            let media = try CutEngine(cancelled: { !interruption.isActive }).inspect(
                fileURL(file, label: "Input"), keyframes: true)
            guard media.hasVideo else { throw CutError(code: "no_video", message: "JPEG export requires a video stream.") }
            let result = try JPEGExport.write(media, to: output, selection: selection, sample: sample,
                                              preset: options.preset, limit: limit, cancelled: { !interruption.isActive })
            try writeJSON(result, pretty: !arguments.json, checkCancellation: false)
        case let .project(file, times):
            let result: MulticamJPEGManifest
            if isStandardInput(file) {
                let loaded = try loadProject(file, interruption: interruption)
                result = try JPEGExport.writeMulticam(loaded.project, document: nil, at: times, to: output,
                                                      preset: options.preset, useSidecar: true,
                                                      cancelled: { !interruption.isActive })
            } else {
                result = try JPEGExport.writeMulticam(project: fileURL(file, label: "Project"), at: times, to: output,
                                                      preset: options.preset, cancelled: { !interruption.isActive })
            }
            try writeJSON(result, pretty: !arguments.json, checkCancellation: false)
        }
    case let .inspectProject(path):
        let loaded = try loadProject(path, interruption: interruption)
        let project = loaded.project
        let result = try MulticamEngine(cancelled: { !interruption.isActive }).inspect(project, relativeTo: loaded.location)
        let group = try project.groupIntervals()
        try writeJSON(MulticamInspectionResponse(project: loaded.path, report: result, groupIntervals: group),
                      pretty: !arguments.json)
    case let .inspect(file, keyframes, allFrames, audioPackets, packetStream, from, to, tracks, audioStream):
        let engine = CutEngine(cancelled: { !interruption.isActive }, tracks: tracks, audioStream: audioStream)
        try interruption.check()
        let source = try fileURL(file, label: "Input")
        let media: MediaInfo
        if keyframes || allFrames { media = try engine.inspect(source, keyframes: true) }
        else if tracks == .all && !audioPackets { media = try engine.inspectSummary(source) }
        else { media = try engine.inspect(source) }
        if (allFrames || keyframes) && !media.hasVideo {
            throw CutError(code: "no_video", message: "Picture and keyframe queries require a video stream.")
        }
        let issue: String?
        if tracks == .video && !media.hasVideo { issue = "The source has no video stream." }
        else if tracks == .audio && !media.streams.contains(where: { $0.kind == "audio" && (audioStream == nil || $0.index == audioStream) }) {
            issue = "The source has no matching audio stream."
        } else if tracks == .video && !media.sourceStartSafe {
            issue = "The source does not begin at a verified video access point."
        } else if tracks == .all {
            issue = media.copyIssue ?? (media.hasVideo && !media.sourceStartSafe ? "The source does not begin at a verified video access point." : nil)
        } else { issue = nil }
        let containers = issue == nil ? engine.suggestedContainers(for: media) : []
        try interruption.check()
        var packets: AudioIndex?
        if audioPackets {
            let index = packetStream ?? audioStream
            packets = media.audio.first { index == nil || $0.stream.index == index }
            guard packets != nil else { throw CutError(code: "no_audio", message: "The source has no matching audio stream.") }
        }
        let data = try inspectionJSON(media, copy: CopyEligibility(reason: issue, containers: containers),
                                      allFrames: allFrames, packets: packets, from: from, to: to,
                                      pretty: !arguments.json, interruption: interruption)
        try interruption.beginResponse()
        try writeOutput(data)
    case let .bulk(dryRun, flags):
        let input: BulkInput = try readInput(interruption)
        let options = try flags.merging(input.options)
        let mode = options.mode ?? .smart
        try validate(options, mode: mode)
        let file = try fileURL(input.file, label: "Source")
        let directory = try fileURL(input.outputDirectory, label: "Output directory", directory: true)
        let groups = try input.ranges.enumerated().map { index, range in
            [try ClipRequest(file: file, from: timestamp(range.from, segment: index + 1, boundary: "from"),
                             to: timestamp(range.to, segment: index + 1, boundary: "to"))]
        }
        let settings = ReencodeSettings(codec: options.video ?? .h264, quality: options.quality, audio: options.audio ?? .auto)
        let batch = try BulkExport(groups: groups, directory: directory, mode: mode, tracks: options.tracks ?? .all, audioStream: options.audioStream, container: input.container,
                                   snap: options.snap ?? .exact, settings: settings, cancelled: { !interruption.isActive })
        let result = runBatch(batch, dryRun: dryRun, interruption: interruption)
        try writeJSON(BulkResponse(ok: result.failure == nil, dryRun: dryRun, outputs: result.outputs,
                                   failedRange: result.failure?.range, error: result.failure?.issue),
                      checkCancellation: dryRun && result.failure == nil)
        if let failure = result.failure {
            exit(exitStatus(failure.issue.code, operation: true))
        }
    case let .exportProject(project, path, dryRun, options):
        try runMulticamExport(project: project, output: fileURL(path, label: "Output"), options: options,
                              dryRun: dryRun, json: arguments.json, interruption: interruption)
    case let .export(supplied, dryRun, flags, requestedOrder):
        let input = try supplied ?? readInput(interruption)
        let options = try flags.merging(input.options)
        guard !input.clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires at least one clip.")
        }
        let order = try input.resolvedOrder(requestedOrder)
        if (order ?? Array(1...input.clips.count)).contains(where: { input.clips[$0 - 1].project != nil }) {
            guard !input.clips.contains(where: { $0.soundtrack != nil }) else { throw CLIError("invalid_arguments", "Apply file soundtrack replacements before mixing multicam projects.") }
            try runMulticamExport(input: input, order: order, output: fileURL(input.output, label: "Output"),
                                  options: options, dryRun: dryRun, json: arguments.json, interruption: interruption)
            return
        }
        var soundtracks: [URL: SourceSoundtrack] = [:]
        for (index, clip) in input.clips.enumerated() {
            var binding = clip.soundtrack
            if index == 0, let file = options.replaceAudio {
                let global = SourceSoundtrack(file: file, target: options.replaceTrack, stream: options.replacementStream)
                guard binding == nil || binding == global else {
                    throw CLIError("invalid_arguments", "Conflicting replacement audio for the first source.")
                }
                binding = global
            }
            guard let binding else { continue }
            guard clip.project == nil, let path = clip.file ?? input.file else {
                throw CLIError("invalid_json", "Clip \(index + 1) requires a file path or a top-level file for audio replacement.")
            }
            let source = try fileURL(path, label: "Replacement target").resolvingSymlinksInPath()
            guard soundtracks[source] == nil || soundtracks[source] == binding else {
                throw CLIError("invalid_arguments", "Cuts from the same source must use the same replacement audio.")
            }
            soundtracks[source] = binding
        }
        let requestedMode = options.mode ?? (order == nil || !soundtracks.isEmpty ? .copy : .smart)
        try validate(options, mode: requestedMode)
        let mode: ExportMode = (options.tracks ?? .all) == .all ? requestedMode : .copy
        let output = try fileURL(input.output, label: "Output")
        var clips = try (order ?? Array(1...input.clips.count)).map { number in
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
        var staging: URL?
        var sourceFiles: [URL] = []
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        if !soundtracks.isEmpty {
            guard requestedMode == .copy, (options.tracks ?? .all) == .all else {
                throw CLIError("invalid_arguments", "Replacement audio requires copy mode and both track types.")
            }
            let inspector = CutEngine(cancelled: { !interruption.isActive })
            try inspector.checkDestination(output)
            let engine = AudioReplacementEngine(cancelled: { !interruption.isActive })
            var prepared: [URL: URL] = [:]
            let clipSources = clips.map { $0.file.resolvingSymlinksInPath() }
            for (clip, source) in zip(clips, clipSources) {
                guard let binding = soundtracks[source], prepared[source] == nil else { continue }
                let donor = try fileURL(binding.file, label: "Replacement audio")
                let fullSource: Bool
                if clips.count == 1, (clip.from ?? .zero) == .zero {
                    if let end = clip.to {
                        let media = try inspector.inspect(clip.file)
                        fullSource = end == media.duration
                    } else {
                        fullSource = true
                    }
                } else {
                    fullSource = false
                }
                let plan = try engine.resolve(source: fullSource ? clip.file : source, replacement: donor,
                                              output: fullSource ? output : nil,
                                              targetStream: binding.target, replacementStream: binding.stream)
                if fullSource {
                    if !dryRun { try engine.export(plan, to: output) { progress.report($0) } }
                    if arguments.json || dryRun {
                        try writeJSON(ReplacementResult(dryRun: dryRun, output: output.path, duration: plan.duration,
                                                      copiedDuration: plan.duration, container: plan.container, replacement: plan),
                                      pretty: !arguments.json, checkCancellation: dryRun)
                    } else {
                        try interruption.beginResponse(checkCancellation: false)
                        try writeOutput("Exported \(output.path)")
                    }
                    return
                }
                if staging == nil {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    staging = folder
                }
                let working = staging!.appendingPathComponent(UUID().uuidString).appendingPathExtension(plan.container)
                try engine.export(plan, to: working)
                prepared[source] = working
            }
            sourceFiles = clips.map(\.file)
            clips = zip(clips, clipSources).map { clip, source in
                ClipRequest(file: prepared[source] ?? clip.file, from: clip.from, to: clip.to)
            }
        }
        var result: ExportResult
        do {
            switch mode {
            case .copy, .smart:
                let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: mode == .smart,
                                       tracks: options.tracks ?? .all, audioStream: options.audioStream)
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
        } catch let error as CutError {
            // The engine numbers clips by playback position. Report the caller's clip number,
            // as timestamp errors do, so `nearest` applies to the right entry under `order`.
            guard let order, let position = error.segment, order.indices.contains(position - 1) else { throw error }
            throw CutError(code: error.code, message: error.message, segment: order[position - 1],
                           boundary: error.boundary, nearest: error.nearest, track: error.track)
        }
        result.sourceFiles = sourceFiles
        if let folder = staging {
            try? FileManager.default.removeItem(at: folder)
            staging = nil
        }
        if arguments.json || dryRun {
            try writeJSON(result, pretty: !arguments.json, checkCancellation: dryRun)
        } else {
            try interruption.beginResponse(checkCancellation: false)
            for warning in result.conversion?.warnings ?? [] {
                errorOutput("mpcut: \(warning)")
            }
            try writeOutput("Exported \(output.path)")
        }
    }
}

/// 130 for cancellation, 2 for a request the caller must correct, 1 for an operation failure.
/// The pure request codes exit 2 whichever layer rejects them. `invalid_range` keeps its
/// thrower's status because it also reports ranges that only the opened source can refute.
private func exitStatus(_ code: String, operation: Bool) -> Int32 {
    if code == "cancelled" { return 130 }
    if ["invalid_time", "invalid_arguments", "empty_edit"].contains(code) { return 2 }
    return operation ? 1 : 2
}

signal(SIGPIPE, SIG_IGN)
let tokens = Array(CommandLine.arguments.dropFirst())
let json = Arguments.requestsJSON(tokens)
private let interruption = Interruption()
do {
    let arguments = try Arguments.parse(tokens)
    try await AnalysisSidecar.$readsEnabled.withValue(arguments.useSidecar) {
        try await run(arguments, interruption: interruption)
    }
} catch let error as CutError {
    reportFailure(error, message: error.message, json: json)
    exit(exitStatus(error.code, operation: true))
} catch let error as CLIError {
    reportFailure(error, message: error.message, json: json)
    exit(exitStatus(error.code, operation: false))
} catch let error as OutputError {
    reportOutputFailure(error)
    exit(1)
} catch {
    let failure = CLIError("operation_failed", error.localizedDescription)
    reportFailure(failure, message: failure.message, json: json)
    exit(1)
}
