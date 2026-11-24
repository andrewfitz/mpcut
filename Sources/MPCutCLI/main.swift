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
    struct StillLosslessFormat: Encodable {
        let container: String
        let videoCodec: ReencodeCodec
        let audioOptions: [ReencodeAudio]
    }

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
    let stillPictureTimings = StillPictureTiming.allCases.map(\.rawValue)
    let stillLosslessFormats: [StillLosslessFormat] = ExportRules.stillMovieContainers.flatMap { container in
        ReencodeCodec.allCases.compactMap { codec in
            let actions = ExportRules.stillLosslessAudioActions(codec: codec, container: container)
            return actions.isEmpty ? nil : StillLosslessFormat(container: container, videoCodec: codec, audioOptions: actions)
        }
    }
    let qualities = ReencodeQuality.allCases.map(\.rawValue)
    let audioOptions = ReencodeAudio.allCases.map(\.rawValue)
    let snapOptions = SnapMode.allCases.map(\.rawValue)
    let defaultExportMode = ExportRules.defaultMode(for: ExportEntryPoint.cliExport.source).rawValue
    let defaultOrderedExportMode = ExportRules.defaultMode(for: ExportEntryPoint.cliExport.source).rawValue
    /// The mode each source kind is written with when a request names none, from the export rules.
    let defaultExportModes = Dictionary(uniqueKeysWithValues: ExportSourceKind.allCases.map {
        ($0.rawValue, ExportRules.defaultMode(for: $0, tracks: .all).rawValue)
    })
    let defaultMulticamExportMode = ExportRules.defaultMode(for: .multicam).rawValue
    let clipOrderIndexBase = 1
    let exportRangesSeparateDefaultMode = ExportRules.defaultMode(for: .movie).rawValue
    /// The modes each command writes, from the export rules.
    let entryPointModes = Dictionary(uniqueKeysWithValues: ExportEntryPoint.allCases.map { ($0.rawValue, $0.modes.map(\.rawValue)) })
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

/// Keep encoding failures separate from stdout. Small replies stay in memory;
/// large replies spill into an anonymous file which also closes on signals.
private final class InspectionOutput {
    private var memory = Data()
    private var file: UnsafeMutablePointer<FILE>?

    deinit { if let file { fclose(file) } }

    func append(_ bytes: Data) throws {
        if file == nil && memory.count + bytes.count <= 1024 * 1024 {
            memory.append(bytes)
            return
        }
        if let file {
            try store(bytes, in: file)
        } else {
            guard let temporary = tmpfile() else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            file = temporary
            try store(memory, in: temporary)
            memory = Data()
            try store(bytes, in: temporary)
        }
    }

    private func store(_ data: Data, in file: UnsafeMutablePointer<FILE>) throws {
        let count = data.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
        guard count == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func write(to interruption: Interruption) throws {
        guard let file else {
            try interruption.beginResponse()
            try writeOutput(memory)
            return
        }
        guard fseek(file, 0, SEEK_SET) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try interruption.beginResponse()
        var buffer = Data(count: 128 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, file) }
            if count > 0 { try writeOutput(buffer.prefix(count)) }
            if ferror(file) != 0 { throw OutputError(code: errno) }
            if feof(file) != 0 { return }
        }
    }
}

private func inspectionJSON(_ media: MediaInfo, copy: CopyEligibility, tier: TierSummary? = nil, listsFrames: Bool = true,
                            allFrames: Bool, packets: AudioIndex?,
                            from: RationalTime?, to: RationalTime?, pretty: Bool,
                            interruption: Interruption) throws -> InspectionOutput {
    let encoder = jsonEncoder(pretty: pretty)
    let result = InspectionOutput()
    func appendJSON(_ fragment: Data, indent: String) throws {
        if pretty {
            let text = String(decoding: fragment, as: UTF8.self)
            try result.append(Data(text.replacingOccurrences(of: "\n", with: "\n" + indent).utf8))
        } else {
            try result.append(fragment)
        }
    }
    let header = pretty ? "{\n  \"ok\" : true,\n  \"file\" : " : #"{"ok":true,"file":"#
    try result.append(Data(header.utf8))
    try result.append(try encoder.encode(media.url.path))
    try result.append(Data((pretty ? ",\n  \"preview\" : \"unchecked\",\n  \"copy\" : "
                                      : #","preview":"unchecked","copy":"#).utf8))
    try appendJSON(try encoder.encode(copy), indent: "  ")
    if let tier {
        try result.append(Data((pretty ? ",\n  \"tier\" : " : #","tier":"#).utf8))
        try appendJSON(try encoder.encode(tier), indent: "  ")
    }
    try result.append(Data((pretty ? ",\n  \"media\" : " : #","media":"#).utf8))
    // InspectionSummary always encodes an object. Append the frames member
    // before closing that object, keeping paths and other strings JSON-escaped.
    var metadata = try encoder.encode(InspectionSummary(media: media)).dropLast()
    if metadata.last == 0x0a { metadata = metadata.dropLast() }
    try appendJSON(metadata, indent: "  ")
    try result.append(Data((pretty ? ",\n    \"frames\" : [" : #","frames":["#).utf8))
    var needsComma = false
    func appendBatches<Row, Point: Encodable>(_ rows: [Row], time: KeyPath<Row, RationalTime>, ordered: Bool = true,
                                               point: (Row) -> Point?) throws {
        let batchSize = 512
        let first = ordered ? from.map { bound in rows.lowerBound { $0[keyPath: time] >= bound } } ?? 0 : 0
        let end = ordered ? to.map { bound in rows.lowerBound { $0[keyPath: time] >= bound } } ?? rows.count : rows.count
        try forEachOrderedBatch(count: end - first, batchSize: batchSize, check: interruption.check, transform: { indices -> Data? in
            let points = rows[(first + indices.lowerBound)..<(first + indices.upperBound)].compactMap(point)
            guard !points.isEmpty else { return nil }
            return try jsonEncoder(pretty: pretty).encode(points)
        }, consume: { fragment in
            guard let fragment else { return }
            if needsComma { try result.append(Data([0x2c])) }
            var elements = fragment.dropFirst().dropLast()
            if elements.last == 0x0a { elements = elements.dropLast() }
            try appendJSON(elements, indent: "    ")
            needsComma = true
        })
    }
    // A bare inspect reads the cut index for the tier and lists no pictures.
    try appendBatches(listsFrames ? media.frames : [], time: \.time) { frame -> AccessPoint? in
        let canStart = frame.time == .zero ? media.sourceStartSafe :
            frame.canStart && frame.time > .zero && frame.time < media.duration
        if let from, frame.time < from { return nil }
        if let to, frame.time >= to { return nil }
        guard allFrames || frame.keyframe || canStart else { return nil }
        return AccessPoint(dts: frame.dts, time: frame.time, duration: frame.duration,
                           keyframe: frame.keyframe, canStart: canStart, canEnd: frame.canEnd)
    }
    if pretty && needsComma { try result.append(Data("\n    ".utf8)) }
    if let packets {
        try result.append(Data((pretty ? "],\n    \"audio_packets\" : [" : #"],"audio_packets":["#).utf8))
        needsComma = false
        try appendBatches(packets.packets, time: \.time, ordered: media.copyIssue == nil) { packet -> PacketPoint? in
            if let from, packet.time < from { return nil }
            if let to, packet.time >= to { return nil }
            return PacketPoint(stream: packets.stream.index, time: packet.time, duration: packet.duration,
                               dts: packet.dts, skipSamples: packet.skipSamples, discardSamples: packet.discardSamples)
        }
        if pretty && needsComma { try result.append(Data("\n    ".utf8)) }
    }
    try result.append(Data((pretty ? "]\n  }\n}\n" : "]}}\n").utf8))
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
    var cutMap: ExportCutMap?
    var silence: SilenceExportSummary?
    /// The tier of the clips this export was asked for. Reported by a dry run.
    var tier: TierSummary?

    var audioExport: AudioExportPlan?

    init(dryRun: Bool, output: String, edit: ResolvedEdit, mode: ExportMode, conversion: ReencodePlan?,
         order: [Int]? = nil) throws {
        self.dryRun = dryRun
        self.output = output
        self.edit = edit
        self.mode = ExportRules.cell(source: .movie, tracks: edit.tracks, mode: mode).resolvedMode
        self.conversion = conversion
        self.order = order
        self.copiedDuration = try edit.copiedVideoDuration(for: mode)
        self.encodedDuration = try edit.encodedVideoDuration(for: mode)
    }

    /// The alternative that `--audio auto` applied, and the treatment that was asked for.
    var applied: ExportAlternative?
    var requestedAudio: ReencodeAudio?
    /// Cover art, chapters or timecode that a packet copy leaves behind. Reported under `warnings`.
    var copyOmissions: [String] = []

    /// A plan from the shared export rules.
    init(dryRun: Bool, output: String, plan: ExportPlan, requested: ExportRequest, applied: ExportAlternative?,
         order: [Int]? = nil) throws {
        switch plan {
        case .packets(let edit, let mode, _):
            try self.init(dryRun: dryRun, output: output, edit: edit, mode: mode, conversion: nil, order: order)
            // A sound-only encode request that copies reports what it was asked and what it did.
            if requested.mode == .encode { requestedAudio = requested.audio }
        case .conversion(let conversion):
            try self.init(dryRun: dryRun, output: output, edit: conversion.edit, mode: .encode, conversion: conversion, order: order)
        case .audio(let audio):
            try self.init(dryRun: dryRun, output: output, audio: audio, order: order)
            requestedAudio = requested.audio
        }
        self.applied = applied
    }

    /// A sound-only export reports the treatment it resolved: copy when the packets were kept.
    init(dryRun: Bool, output: String, audio plan: AudioExportPlan, order: [Int]? = nil) throws {
        self.dryRun = dryRun
        self.output = output
        edit = plan.edit
        mode = plan.mode
        conversion = nil
        audioExport = plan
        self.order = order
        copiedDuration = try plan.edit.copiedVideoDuration(for: plan.mode)
        encodedDuration = try plan.edit.encodedVideoDuration(for: plan.mode)
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
                videoAction = edges.isEmpty ? "copy" : "copy_and_encode"
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
        case ok, dryRun, output, segments, duration, container, mode, copiedDuration, encodedDuration, order, cutMap
        case video, quality, audio, audioActions, width, height, warnings, silence, tracks, audioStream, applied, tier, canvas
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encode(edit.segments.map { segment in
            let original = segment.sourceClipIndex.flatMap { sourceFiles.indices.contains($0) ? sourceFiles[$0] : nil }
            return Segment(segment, mode: mode, audioAction: audioExport?.action, original: original)
        }, forKey: .segments)
        try fields.encodeIfPresent(cutMap, forKey: .cutMap)
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
            // Present for a mixed timeline: the one format every clip is written in.
            try fields.encodeIfPresent(conversion.canvas, forKey: .canvas)
            try fields.encode(conversion.warnings, forKey: .warnings)
        }
        if let audioExport {
            try fields.encode(requestedAudio ?? audioExport.requested, forKey: .audio)
            try fields.encode(audioExport.actions, forKey: .audioActions)
            try fields.encode(audioExport.warnings + (applied?.warnings.filter { !audioExport.warnings.contains($0) } ?? [])
                              + copyOmissions, forKey: .warnings)
        } else if let requestedAudio, conversion == nil {
            try fields.encode(requestedAudio, forKey: .audio)
            let copied = edit.segments.first?.tracks.filter { $0.kind == "audio" } ?? []
            try fields.encode(copied.map { ReencodeAudioAction(track: $0.index, action: .copyOriginal, reason: nil) }, forKey: .audioActions)
            try fields.encode((applied?.warnings ?? []) + copyOmissions, forKey: .warnings)
        } else if conversion == nil, !copyOmissions.isEmpty {
            // A plain packet copy has no `warnings` field unless it leaves something behind.
            try fields.encode(copyOmissions, forKey: .warnings)
        }
        try fields.encodeIfPresent(applied?.id, forKey: .applied)
        try fields.encodeIfPresent(tier, forKey: .tier)
    }
}

private struct MulticamInspectionResponse: Encodable {
    let ok = true
    let project: String
    let report: MulticamInspection
    let groupIntervals: [MulticamInterval]
    /// The tier of the saved program, in the shape a file timeline reports.
    var tier: TierSummary?

    private enum CodingKeys: String, CodingKey { case ok, project = "project_path", inspection, groupIntervals, tier }
    private enum InspectionKeys: String, CodingKey { case mapping, sources, issues, audioBindings }
    private enum SourceKeys: String, CodingKey { case source, media, coverage, audioCoverage }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(project, forKey: .project)
        try fields.encode(groupIntervals, forKey: .groupIntervals)
        try fields.encodeIfPresent(tier, forKey: .tier)
        var inspection = fields.nestedContainer(keyedBy: InspectionKeys.self, forKey: .inspection)
        try inspection.encode(report.mapping, forKey: .mapping)
        try inspection.encode(report.issues, forKey: .issues)
        try inspection.encode(report.audioBindings, forKey: .audioBindings)
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
    var extraRangeInputs: [Int: Int] = [:]
    var isMixedJoin = false
    /// The alternative that `--audio auto` applied.
    var applied: ExportAlternative?
    /// The tier of the program, whatever mode was asked for.
    var tier: TierSummary?

    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, output, order, sources, plan, mode, tracks, container, duration, warnings
        case picture, audioLanes, audioOutput, copiedVideoDuration, encodedVideoDuration, generatedPictureGaps, applied, tier, cutMap
        case participantRender
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encodeIfPresent(applied?.id, forKey: .applied)
        try fields.encode(dryRun, forKey: .dryRun)
        try fields.encode(output, forKey: .output)
        try fields.encodeIfPresent(order, forKey: .order)
        try fields.encode(sources, forKey: .sources)
        let mapping = preflight.mapping
        var inputNumbers: [Int: Int]?
        if isMixedJoin {
            inputNumbers = [:]
            for interval in mapping.intervals {
                let number = interval.assemblyIndex + 1
                inputNumbers?[interval.assemblyIndex] = extraRangeInputs[number] ?? number
            }
        }
        try fields.encode(ExportCutMap(multicam: mapping, inputNumbersByAssemblyIndex: inputNumbers), forKey: .cutMap)
        if extraRangeInputs.isEmpty {
            try fields.encode(mapping, forKey: .plan)
        } else {
            let intervals = mapping.intervals.map { interval in
                guard let input = extraRangeInputs[interval.assemblyIndex + 1] else { return interval }
                return MulticamInterval(group: interval.group, output: interval.output, angle: interval.angle,
                                        pictureSourceID: interval.pictureSourceID, audio: interval.audio, assemblyIndex: input - 1, startsAtSwitch: interval.startsAtSwitch)
            }
            try fields.encode(MulticamPlan(intervals: intervals, picture: mapping.picture, audioLanes: mapping.audioLanes,
                                           duration: mapping.duration), forKey: .plan)
        }
        try fields.encode(preflight.mode, forKey: .mode)
        try fields.encode(preflight.tracks, forKey: .tracks)
        try fields.encode(preflight.container, forKey: .container)
        try fields.encode(preflight.duration, forKey: .duration)
        try fields.encode(preflight.warnings, forKey: .warnings)
        try fields.encode(preflight.copiedVideoDuration, forKey: .copiedVideoDuration)
        try fields.encode(preflight.encodedVideoDuration, forKey: .encodedVideoDuration)
        try fields.encodeIfPresent(preflight.generatedPictureGaps, forKey: .generatedPictureGaps)
        try fields.encodeIfPresent(preflight.participantRender, forKey: .participantRender)
        try fields.encode(preflight.picture.map { ExportResult.Segment($0, mode: preflight.mode) }, forKey: .picture)
        try fields.encode(preflight.audioOutput, forKey: .audioOutput)
        try fields.encode(preflight.audioLanes, forKey: .audioLanes)
        try fields.encodeIfPresent(tier, forKey: .tier)
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
    let cutMap: ExportCutMap
}

final class Interruption: @unchecked Sendable {
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

// An inherited stderr can share its blocking mode with the caller. Keep at most
// one advisory write in flight so a stalled reader cannot hold up media work.
private let progressWriteSlot = DispatchSemaphore(value: 1)
func progressOutput(_ message: String, waitForDelivery: Bool = false) {
    let deadline = DispatchTime.now() + .milliseconds(waitForDelivery ? 100 : 10)
    guard progressWriteSlot.wait(timeout: waitForDelivery ? deadline : .now()) == .success else { return }
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            progressWriteSlot.signal()
            finished.signal()
        }
        let bytes = Array((message + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(STDERR_FILENO, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                written += count
            }
        }
    }
    _ = finished.wait(timeout: deadline)
}

private func jsonEncoder(pretty: Bool) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
    return encoder
}

func writeJSON<T: Encodable>(_ result: T, pretty: Bool = false, checkCancellation: Bool = true) throws {
    var data = try jsonEncoder(pretty: pretty).encode(result)
    data.append(0x0A)
    try interruption.beginResponse(checkCancellation: checkCancellation)
    try writeOutput(data)
}

/// A failed write to standard output. A closed pipe (`EPIPE`) ends the command quietly.
private struct OutputError: Error {
    let code: Int32
}

func writeOutput(_ text: String) throws {
    try writeOutput(Data((text + "\n").utf8))
}

func writeOutput(_ data: Data) throws {
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
private struct LoadedProject<Project> {
    let project: Project
    let media: CutProjectMedia
    let location: URL
    /// Nil when the project arrived on standard input.
    let file: URL?
    var path: String { file?.path ?? "-" }
    var excludedSidecarSources: Set<URL> {
        guard AnalysisSidecar.readsEnabled else { return AnalysisSidecar.excludedSources }
        return AnalysisSidecar.excludedSources.union(media.sidecarExclusions(relativeTo: location))
    }
}

func isStandardInput(_ path: String) -> Bool {
    ["-", "/dev/stdin", "/dev/fd/0"].contains(path)
}

/// `--project -` reads the project from standard input under the request limit. Its relative
/// media paths then resolve from the working directory, as paths in a stdin request do.
private func loadDocument(_ path: String, interruption: Interruption) throws -> LoadedProject<CutProject> {
    guard isStandardInput(path) else {
        let location = try fileURL(path, label: "Project")
        let media = try CutProjectMedia.load(from: location)
        return LoadedProject(project: media.project, media: media, location: location, file: location)
    }
    let media = try CutProjectMedia.decode(try readStandardInput(interruption))
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    // A literal file named "-" may be a symlink to a project in another folder.
    let location = directory.appendingPathComponent(".mpcut-stdin-\(UUID().uuidString).cut")
    return LoadedProject(project: media.project, media: media, location: location, file: nil)
}

private func loadProject(_ path: String, interruption: Interruption) throws -> LoadedProject<MulticamProject> {
    let loaded = try loadDocument(path, interruption: interruption)
    guard case .multicam(let project) = loaded.project else {
        throw CLIError("expected_multicam", "This operation requires a multicam project.")
    }
    return LoadedProject(project: project, media: loaded.media, location: loaded.location, file: loaded.file)
}

private struct SequenceInspection: Encodable {
    let ok = true
    let kind = "sequence"
    let projectPath: String
    let clips: [CutSequenceClip]
    let sources: [String: String]
    let duration: RationalTime
    var tier: TierSummary?
    var sourceSelects: [NamedSourceSelect]?
}

private struct ConversionResponse: Encodable {
    let ok = true
    let input: String
    let output: String
    let warnings: [String]
}

private func readInput<T: Decodable>(_ interruption: Interruption, path: String?) throws -> T {
    let data: Data
    if let path {
        data = try ClipEditCSV.readListData(fileURL(path, label: "Request"), kind: "JSON", cancelled: { !interruption.isActive })
    } else {
        data = try readStandardInput(interruption)
    }
    let source = path ?? "Standard input"
    // Foundation also auto-detects UTF-16/32. Raw NUL bytes are never legal in UTF-8 JSON.
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
        throw CLIError("invalid_json", "\(source) must contain a UTF-8 JSON object.")
    }
    do {
        let edit = try JSONDecoder().decode(T.self, from: data)
        // These requests use strings for times and integer components in rational
        // objects. Check the wire numbers before accepting Foundation's conversion.
        let usesOnlyIntegerNumbers = T.self == InputEdit.self || T.self == BulkInput.self
        if let issue = jsonInputIssue(data, integerNumbersOnly: usesOnlyIntegerNumbers) {
            throw CLIError("invalid_json", "\(source) \(issue).")
        }
        return edit
    } catch let error as CLIError {
        throw error
    } catch {
        if T.self == BulkInput.self {
            throw CLIError("invalid_json", "Expected file, output_directory and ranges containing from and to timestamps.")
        }
        if T.self == SilenceInput.self {
            throw CLIError("invalid_json", "Expected a silence report containing file, source_stamp, duration, detection_audio_stream_index, threshold_db, min_pause_seconds, max_blip_seconds, padding_per_side_seconds, mode and pauses.")
        }
        if T.self == SceneExportInput.self {
            throw CLIError("invalid_json", "Expected a scene report containing file and scenes with view, start and end.")
        }
        throw CLIError("invalid_json", "Expected an export object with output and clips. File and project paths are strings, timestamps accept strings or rational objects, and order must be an array of clip numbers.")
    }
}

func readStandardInput(_ interruption: Interruption) throws -> Data {
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

func fileURL(_ path: String, label: String, directory: Bool = false) throws -> URL {
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

/// Keep ordinary destination diagnostics for existing files and also protect offline project media.
private func checkProjectOutput(_ output: URL, media: CutProjectMedia, location: URL) throws {
    try CutEngine().checkDestination(output)
    try media.validateDestination(output, relativeTo: location)
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
            progressOutput("Export \(percent)%")
            reported = percent / 5
        }
        return true
    }
}

private func validate(_ options: ExportOptions, mode: ExportMode, multicam: Bool = false) throws {
    try options.checkTrackSelection()
    guard multicam || options.audioOutput == nil else {
        throw CLIError("invalid_arguments", "--audio-output applies to multicam projects.")
    }
    if mode == .encode {
        // The matrix in ExportRules decides which selections a mode applies to, once the source is known.
        guard options.replaceAudio == nil else {
            throw CLIError("invalid_arguments", "Audio replacement uses Lossless Copy.")
        }
        guard options.snap != .nearest else {
            throw CLIError("invalid_arguments", "--snap nearest applies to copy and smart exports.")
        }
    } else if options.video != nil || options.quality != nil || (!multicam && options.audio != nil) {
        let settings = multicam ? "Video and quality settings" : "Video, quality and audio settings"
        throw CLIError("invalid_arguments", "\(settings) require --mode encode.")
    }
}

/// What a failed export says to people, set where the clips are known.
private final class FailureContext: @unchecked Sendable {
    static let shared = FailureContext()
    var text: String?
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

private func runBatch(_ batch: BulkExport, indexedMedia: [URL: MediaInfo], dryRun: Bool, interruption: Interruption)
    -> (outputs: [ExportResult], failure: (range: Int, issue: CutError)?) {
    var outputs: [ExportResult] = []
    let progress = ExportProgress(interruption: interruption)
    let tierMedia = indexedMedia.filter { $0.value.hasFullEditIndex }
    // Each range reports its tier. One evaluator shares the source indexes between them.
    let tiers = TimelineTierEvaluator(useSidecar: AnalysisSidecar.readsEnabled)
    for (index, item) in batch.items.enumerated() {
        do {
            guard interruption.isActive else {
                throw CutError(code: "cancelled", message: "Operation cancelled.")
            }
            // Each range reports the plan the export rules resolved for it.
            var result = try item.audio.map { try ExportResult(dryRun: dryRun, output: item.output.path, audio: $0) }
                ?? ExportResult(dryRun: dryRun, output: item.output.path, edit: item.edit,
                                mode: item.plan.mode, conversion: item.conversion)
            result.applied = item.applied
            result.copyOmissions = item.plan.copyOmissions
            // A dry run and the export it plans report the same fields, the tier among them.
            result.tier = tiers.summary(item.request.clips, media: tierMedia, cancelled: { !interruption.isActive })
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

private struct MediaProgressEvent: Encodable {
    let event = "progress"
    var file: String?
    var progress: SceneScanProgress?
    var fraction: Double?
}

private func reportMediaProgress(_ event: MediaProgressEvent, output: MediaProgressOutput) {
    switch output {
    case .none:
        break
    case .stderr:
        let percent = event.fraction.map { String(format: "%.1f%%", $0 * 100) }
        let elapsed = event.progress.flatMap { progress -> String? in
            guard let decoded = progress.decoded else { return nil }
            let start: RationalTime
            if case let .range(from, _) = progress.requested { start = from } else { start = .zero }
            return String(format: "%.2f s media scanned", max(0, decoded.seconds - start.seconds))
        }
        progressOutput([event.file, percent, elapsed].compactMap { $0 }.joined(separator: " · "))
    case .jsonl:
        if let data = try? jsonEncoder(pretty: false).encode(event) {
            progressOutput(String(decoding: data, as: UTF8.self))
        }
    }
}

private struct SceneSourceResult: Encodable {
    let file: String
    let outcome: SceneScanOutcome
}

private struct ProjectSceneResult: Encodable {
    let ok: Bool
    let projectPath: String
    let sources: [SceneSourceResult]
    let error: CLIError?
}

private struct PausedSceneResult: Encodable {
    let ok = false
    let state: SceneScanOutcome.State
    let progress: SceneScanProgress
    let error: CLIError
}

private struct SceneSourceRequest {
    let file: URL
    let scope: SceneScanScope
}

private func projectSceneRequests(_ loaded: LoadedProject<CutProject>,
                                  scope: SceneScanOptions.ProjectScope) throws -> [SceneSourceRequest] {
    switch (loaded.project, scope) {
    case (.multicam(let multicam), .allSources):
        return multicam.pictureSources.map { angle in
            SceneSourceRequest(file: multicam.sourceURL(for: angle, relativeTo: loaded.location), scope: .fullSource)
        }
    case (.multicam(let multicam), .camera(let id)):
        let recordings = multicam.recordings(for: id)
        guard !recordings.isEmpty else {
            throw CLIError("invalid_arguments", "The project has no camera with ID ‘\(id)’.")
        }
        return recordings.map {
            SceneSourceRequest(file: multicam.sourceURL(for: $0, relativeTo: loaded.location), scope: .fullSource)
        }
    case (.multicam, .clip), (_, .camera):
        throw CLIError("invalid_arguments", "Use a clip ID for a sequence or a camera ID for a multicam project.")
    case (_, .allSources):
        let clips = loaded.project.sequenceClips ?? []
        return try CutProject.sequence(clips).requests(relativeTo: loaded.location).map {
            SceneSourceRequest(file: $0.file, scope: .fullSource)
        }
    case (_, .clip(let id)):
        guard let clip = loaded.project.sequenceClips?.first(where: { $0.id == id }),
              let request = try CutProject.sequence([clip]).requests(relativeTo: loaded.location).first else {
            throw CLIError("invalid_arguments", "The project has no source clip with ID ‘\(id)’.")
        }
        return [SceneSourceRequest(file: request.file, scope: .range(start: clip.from, end: clip.to))]
    }
}

private func runSceneScan(_ options: SceneScanOptions, json: Bool, useSidecar: Bool, interruption: Interruption) throws {
    let cancelled: @Sendable () -> Bool = { !interruption.isActive }
    let cancellation = CLIError("cancelled", "Scene scan cancelled.")
    switch options.input {
    case .file(let path, let scope):
        let file = try fileURL(path, label: "Input")
        let outcome = try SceneAnalysis.run(file, scope: scope, policy: options.policy, useSidecar: useSidecar,
                                            cancelled: cancelled, progress: { progress in
            reportMediaProgress(MediaProgressEvent(file: file.path, progress: progress, fraction: progress.fraction),
                                output: options.progress)
        })
        if outcome.state == .paused {
            try writeJSON(PausedSceneResult(state: outcome.state, progress: outcome.progress, error: cancellation),
                          pretty: !json, checkCancellation: false)
            exit(130)
        }
        guard let report = outcome.report else {
            throw CLIError("scene_analysis_failed", "Scene analysis finished without a report.")
        }
        if options.progress != .jsonl, let error = outcome.progress.persistenceError {
            errorOutput("mpcut: \(error)")
        }
        try writeJSON(report, pretty: !json, checkCancellation: false)
    case .project(let path, let scope):
        let loaded = try loadDocument(path, interruption: interruption)
        let requests = try projectSceneRequests(loaded, scope: scope)
        try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
            let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
            let skipAudioOnly: Bool
            if case .allSources = scope { skipAudioOnly = true } else { skipAudioOnly = false }
            var seen = Set<SourceIdentity>()
            let sources = try requests.compactMap { request -> (MediaInfo, SceneScanScope, Double)? in
                try interruption.check()
                guard seen.insert(try SourceIdentity(request.file)).inserted else { return nil }
                let media = try engine.inspectForPreview(request.file)
                if !media.hasVideo {
                    if skipAudioOnly { return nil }
                    throw CutError(code: "no_video", message: "The selected recording has no video stream.")
                }
                let duration: Double
                switch request.scope {
                case .fullSource: duration = media.duration.seconds
                case .range(let start, let end): duration = end.seconds - start.seconds
                }
                return (media, request.scope, max(0, duration))
            }
            let total = sources.reduce(0) { $0 + $1.2 }
            var finished: Double = 0
            var results: [SceneSourceResult] = []
            for (index, source) in sources.enumerated() {
                if cancelled() { break }
                let (media, sourceScope, duration) = source
                let last = index == sources.count - 1
                let outcome = try SceneAnalysis.run(media, scope: sourceScope, policy: options.policy,
                                                    useSidecar: useSidecar, cancelled: cancelled, progress: { progress in
                    let fraction = total > 0 ? min(last ? 1 : 0.999, (finished + duration * progress.fraction) / total) : nil
                    reportMediaProgress(MediaProgressEvent(file: media.url.path, progress: progress, fraction: fraction),
                                        output: options.progress)
                })
                results.append(SceneSourceResult(file: media.url.path, outcome: outcome))
                if outcome.state == .paused { break }
                finished += duration
            }
            let completed = results.count == sources.count && results.last?.outcome.state != .paused
            if completed, total == 0 {
                reportMediaProgress(MediaProgressEvent(fraction: 1), output: options.progress)
            }
            try writeJSON(ProjectSceneResult(ok: completed, projectPath: loaded.path, sources: results,
                                             error: completed ? nil : cancellation),
                          pretty: !json, checkCancellation: false)
            if !completed { exit(130) }
        }
    }
}

private func runSceneExport(file: String?, requestFile: String?, options: SceneExportOptions, json: Bool, interruption: Interruption) throws {
    let directory = try fileURL(options.directory, label: "Output directory", directory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CutError(code: "invalid_output", message: "The output directory must already exist.")
    }
    let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: true)
    let media: MediaInfo
    var request: SceneExportInput
    if let file {
        media = try engine.inspect(fileURL(file, label: "Input"), keyframes: true)
        if let list = options.list {
            request = try SceneExportInput(file: file, scenes: ListFile.scenes(list))
        } else {
            request = SceneExportInput(try SceneAnalysis.scan(media, cancelled: { !interruption.isActive }))
        }
    } else {
        request = try readInput(interruption, path: requestFile)
        media = try engine.inspect(fileURL(request.file, label: "Input"), keyframes: true)
        if let list = options.list { request.scenes = try ListFile.scenes(list) }
    }
    let jobs = try request.jobs(for: media, grouping: options.grouping)
    let batch = try BulkExport(groups: jobs.map(\.clips), directory: directory, outputSuffixes: jobs.map(\.outputSuffix), organization: options.organization,
                               tracks: options.tracks, audioStream: options.audioStream, container: options.container, media: [media.url: media], cancelled: { !interruption.isActive })
    let result = runBatch(batch, indexedMedia: [media.url: media], dryRun: options.dryRun, interruption: interruption)
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
    let maxBlip: Double
    let padding: Double
    private enum CodingKeys: String, CodingKey {
        case thresholdMode, thresholdDB, detectedPauses, shortenedPauses, skippedPauses, removedDuration, waveformPeakDBFS
        case maxBlip = "max_blip_seconds", padding = "padding_per_side_seconds"
    }
    let detectedPauses: Int
    let shortenedPauses: Int
    let skippedPauses: Int
    let removedDuration: RationalTime
    let waveformPeakDBFS: [Double?]?
}

private func runSilence(_ options: SilenceOptions, arguments: Arguments, requestFile: String?, json: Bool, interruption: Interruption) async throws {
    if let project = options.project {
        let loaded = try loadDocument(project, interruption: interruption)
        if loaded.project.requiresPictureProcessing, options.output != nil {
            throw ParticipantProjectExport.unsupported("Pause removal export")
        }
        if case .multicam(let multicam) = loaded.project {
            guard options.protectedPauses.isEmpty else { throw CLIError("invalid_arguments", "--protect-pause addresses sequence clips.") }
            let input = LoadedProject(project: multicam, media: loaded.media, location: loaded.location, file: loaded.file)
            try runProjectSilence(options, loaded: input, json: json, interruption: interruption)
        } else {
            guard options.audioOutput == nil else {
                throw CLIError("invalid_arguments", "--audio-output applies to multicam projects.")
            }
            if let audio = options.audio, ![.copyOriginal, .aac, .pcm].contains(audio) ||
                (options.mode == .copy && audio != .copyOriginal) {
                throw CLIError("invalid_arguments", "Sequence silence supports copy, AAC or PCM. Converting sound requires Smart Trim.")
            }
            try await AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                let output = try options.output.map { try fileURL($0, label: "Output") }
                if let output { try checkProjectOutput(output, media: loaded.media, location: loaded.location) }
                var (updated, report) = try sequenceSilence(project: loaded.project, location: loaded.location, path: loaded.path,
                                                           options: options, output: output, interruption: interruption)
                if let path = options.outProject {
                    let destination = try fileURL(path, label: "Output project")
                    try saveShortened(updated, loaded: loaded, destination: destination, interruption: interruption)
                    report.outProject = destination.path
                } else if let output {
                    let edit = LoadedProject(project: updated, media: loaded.media, location: loaded.location, file: loaded.file)
                    try await renderLoadedProject(edit, output: output, flags: ExportOptions(mode: options.mode, audio: options.audio),
                                                  dryRun: options.dryRun, arguments: arguments, interruption: interruption)
                    return
                }
                try writeJSON(report, pretty: !json, checkCancellation: options.outProject == nil)
            }
        }
        return
    }
    let saved = options.stdin ? try readInput(interruption, path: requestFile) as SilenceInput : nil
    guard let path = saved?.file ?? options.file else { throw CLIError("invalid_arguments", "Supply a media file.") }
    let source = try fileURL(path, label: "Input")
    let tracks = options.tracks ?? saved?.tracks ?? .all
    let audioStream = options.audioStream ?? (tracks == .audio ? saved?.audioStream : nil)
    if let audioStream, tracks != .audio || audioStream < 0 {
        throw CLIError("invalid_arguments", "--audio-stream requires --tracks audio and a nonnegative absolute stream index.")
    }
    let requestedMode = options.mode ?? saved?.mode ?? ExportRules.defaultMode(for: ExportEntryPoint.cliSilence.source)
    let mode = ExportRules.cell(source: .movie, tracks: tracks, mode: requestedMode).resolvedMode
    guard requestedMode != .encode, saved?.ok != false else {
        throw CLIError("invalid_json", "Supply a successful silence report with smart or copy mode.")
    }
    let engine = CutEngine(cancelled: { !interruption.isActive }, smartTrim: mode == .smart, tracks: tracks, audioStream: audioStream)
    let original = try engine.inspect(source, keyframes: true)
    let media = tracks == .audio ? try original.extendingToAudioEnd(stream: audioStream) : original
    let reuseAnalysis = original.duration == media.duration
    // The matrix refuses a picture selection from a source without one, in its own words.
    if let refusal = ExportEntryPoint.cliSilence.answer(source: media.hasVideo ? .movie : .audio, tracks: tracks, mode: requestedMode).refusal {
        throw refusal
    }
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
    let overridePauses = try options.pausesFile.map { path in
        let ranges = try ListFile.ranges(fileURL(path, label: "Pause list"), clip: AudioSpan(from: .zero, to: media.duration),
                                         rangesOnly: true, cancelled: { !interruption.isActive })
        guard zip(ranges, ranges.dropFirst()).allSatisfy({ $0.to <= $1.from }) else {
            throw CLIError("invalid_list", "Pause intervals must be in source order without overlaps.")
        }
        return ranges
    }
    let threshold: Double
    let thresholdMode: SilenceThresholdMode
    let maxBlip = saved?.maxBlip ?? options.maxBlip
    let minimum = saved?.minimumPause ?? options.minimum
    let padding = options.padding ?? saved?.padding ?? 0.2
    var pauses: [AudioSpan]
    var columns: [Double?]?
    if let saved {
        threshold = saved.thresholdDB
        thresholdMode = saved.thresholdMode
        let supplied = saved.pauses
        var cursor = RationalTime.zero
        guard padding >= 0, minimum > 0, (0...1).contains(maxBlip), (-120...0).contains(threshold),
              supplied.allSatisfy({ span in
                  defer { cursor = span.to }
                  return span.from >= cursor && span.to > span.from && span.to <= saved.duration
              }) else { throw CLIError("invalid_json", "Invalid settings or overlapping/out-of-bounds pauses.") }
        pauses = overridePauses ?? supplied.prefix { $0.from < media.duration }.map {
            AudioSpan(from: $0.from, to: min($0.to, media.duration))
        }
    } else {
        let wave = try options.columns.map { _ in
            try AudioAnalysis.scan(media, stream: track, useSidecar: reuseAnalysis, cancelled: { !interruption.isActive })
        }
        if let overridePauses {
            pauses = overridePauses
            if let manual = options.thresholdDB {
                threshold = manual
            } else {
                let analysis = try wave ?? AudioAnalysis.scan(media, stream: track, useSidecar: reuseAnalysis, cancelled: { !interruption.isActive })
                threshold = try analysis.automaticThresholdDB(checkingCancellation: interruption.check)
            }
        } else {
            let detection = try AudioAnalysis.silence(media, stream: track, thresholdDB: options.thresholdDB,
                                                      minimum: minimum, waveform: wave, useSidecar: reuseAnalysis,
                                                      cancelled: { !interruption.isActive })
            threshold = detection.thresholdDB
            pauses = detection.pauses(maxBlip: maxBlip)
        }
        thresholdMode = options.thresholdDB == nil ? .auto : .manual
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
    let cuts = silenceRemovals(pauses, in: media, padding: padding, engine: engine, tracks: tracks, audioStream: audioStream,
                               container: ext?.isEmpty == false ? ext : nil)
    let retained = AudioAnalysis.retained(in: AudioSpan(from: .zero, to: media.duration), removing: cuts)
    let removedDuration = cuts.reduce(RationalTime.zero) { $0 + ($1.to - $1.from) }
    try interruption.check()
    guard let output else {
        let report = SilenceData(file: source.path, sourceStamp: stamp, duration: media.duration,
                                 stream: track, thresholdMode: thresholdMode, thresholdDB: threshold, maxBlip: maxBlip, minimumPause: minimum, padding: padding,
                                 mode: ExportRules.cell(source: media.hasVideo ? .movie : .audio, tracks: tracks, mode: mode).resolvedMode, tracks: tracks == .all ? nil : tracks, audioStream: audioStream, pauses: pauses, removals: cuts, clips: retained,
                                 skippedPauses: pauses.count - cuts.count,
                                 removedDuration: removedDuration,
                                 waveformPeakDBFS: columns)
        try writeJSON(report, pretty: !json)
        return
    }
    guard !retained.isEmpty else {
        throw CutError(code: "empty_edit", message: "The selected pauses cover the entire source. Increase --padding-per-side-seconds to retain footage.")
    }
    let clips = retained.map { ClipRequest(file: source, from: $0.from, to: $0.to) }
    // The retained ranges resolve through the shared rules, as export does.
    let planner = ExportPlanner(cancelled: { !interruption.isActive })
    let request = ExportRequest(clips: clips, mode: requestedMode, tracks: tracks, audioStream: audioStream,
                                container: ext?.isEmpty == false ? ext : nil)
    let plan: ExportPlan
    switch planner.resolve(request, output: output, media: [media.url: media]) {
    case .ready(let ready, _, _): plan = ready
    case .unavailable(var issue, let offers):
        // The failing clips are the retained ranges, so each alternative carries the clips to export.
        if !offers.isEmpty { issue.alternatives = offers.map { $0.alternative.listing($0.request.clips) } }
        throw issue
    }
    var result = try ExportResult(dryRun: options.dryRun, output: output.path, edit: plan.edit, mode: plan.mode, conversion: nil)
    result.copyOmissions = plan.copyOmissions
    result.silence = SilenceExportSummary(thresholdMode: thresholdMode, thresholdDB: threshold, maxBlip: maxBlip,
                                          padding: padding, detectedPauses: pauses.count, shortenedPauses: cuts.count,
                                          skippedPauses: pauses.count - cuts.count, removedDuration: removedDuration,
                                          waveformPeakDBFS: columns)
    // The tier of the retained ranges, as export reports it for the same clips.
    result.tier = TimelineTierEvaluator(useSidecar: AnalysisSidecar.readsEnabled)
        .summary(clips, media: [original.url: original], cancelled: { !interruption.isActive })
    try interruption.check()
    if !options.dryRun {
        let progress = ExportProgress(interruption: interruption)
        try planner.write(plan, to: output) { progress.report($0) }
    }
    try writeJSON(result, pretty: !json, checkCancellation: options.dryRun)
}

private func saveShortened<T>(_ updated: CutProject, loaded: LoadedProject<T>, destination: URL,
                              interruption: Interruption) throws {
    guard let file = loaded.file, destination.pathExtension.lowercased() == "cut" else {
        throw CLIError("invalid_arguments", "Choose a saved input project and a new .cut destination.")
    }
    let archive = try CutProject.loadEditorDocument(from: file, limit: CutProject.maximumHistorySteps)
    guard archive.media.diskRevision == loaded.media.diskRevision else { throw CutError(code: "source_changed", message: "The project changed during analysis.") }
    try archive.media.validateDestination(destination, relativeTo: file)
    try saveEditedProject(updated, source: file, destination: destination, action: "Shorten Pauses", original: archive.project,
                          undo: archive.undo, redo: archive.redo, mediaSnapshot: archive.media.mediaSnapshot,
                          interruption: interruption)
}

private func runProjectSilence(_ options: SilenceOptions, loaded: LoadedProject<MulticamProject>, json: Bool,
                               interruption: Interruption) throws {
    try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
        let (project, location) = (loaded.project, loaded.location)
        let output = try options.output.map { try fileURL($0, label: "Output") }
        if let output { try checkProjectOutput(output, media: loaded.media, location: location) }
        let cancelled: @Sendable () -> Bool = { !interruption.isActive }
        let engine = MulticamEngine(cancelled: cancelled)
        let container = try output.map { try engine.checkCombinedDestination($0) } ?? ExportRules.multicamContainers[0]
        var report = try ProjectSilenceReport(project, at: location, options: options,
                                              container: container, cancelled: cancelled)
        report.project = loaded.path
        if let path = options.outProject {
            guard !report.retainedAssembly.isEmpty else { throw CutError(code: "empty_edit", message: "The pauses cover the assembly.") }
            var updated = project
            updated.assemblyItems = report.retainedAssembly
            let destination = try fileURL(path, label: "Output project")
            try report.checkSources(cancelled: cancelled)
            try saveShortened(.multicam(updated), loaded: loaded, destination: destination, interruption: interruption)
            report.outProject = destination.path
        }
        var stillPlan: StillExportPlan?
        let stillPlanner = StillExportPlanner(useSidecar: AnalysisSidecar.readsEnabled, cancelled: cancelled)
        if let output {
            guard !report.retainedAssembly.isEmpty else {
                throw CutError(code: "empty_edit", message: "The selected pauses cover the entire assembly. Increase --padding-per-side-seconds to retain footage.")
            }
            var retainedProject = project
            retainedProject.assemblyItems = report.retainedAssembly
            let retained = CutProject.multicam(retainedProject)
            let audioOutput = options.audioOutput ?? .separateTracks
            if try retained.exportPlacementScope() != .none {
                do {
                    let planned = try stillPlanner.resolve(retained, relativeTo: location, mode: options.mode, output: output,
                                                           audioOutput: audioOutput, audioAction: options.audio)
                    stillPlan = planned
                    report.stillPreflight = planned.report
                } catch var issue as CutError {
                    let offers = issue.alternatives?.filter { ExportEntryPoint.cliSilence.modes.contains($0.mode) }
                    issue.alternatives = offers?.isEmpty == false ? offers : nil
                    throw issue
                }
            } else {
                let entry = ExportEntryPoint.cliSilence
                let mode = options.mode ?? ExportRules.defaultMode(for: .multicam)
                if let refusal = entry.answer(source: .multicam, tracks: .all, mode: mode).refusal { throw refusal }
                switch engine.resolution(retainedProject, relativeTo: location, output: output, mode: mode,
                                         indexedSources: report.indexedSources, audioOutput: audioOutput,
                                         audioAction: options.audio) {
                case .ready(let plan, _): report.preflight = plan
                case .unavailable(var issue, let offers):
                    let requestable = offers.map(\.alternative).filter { entry.modes.contains($0.mode) }
                    if !requestable.isEmpty { issue.alternatives = requestable }
                    throw issue
                }
                report.tier = engine.tier(retainedProject, relativeTo: location,
                                          indexedSources: report.indexedSources).summary(source: .multicam)
            }
            report.output = output.path
            report.dryRun = options.dryRun
        }
        try report.checkSources(cancelled: cancelled)
        if let output, !options.dryRun {
            let progress = ExportProgress(interruption: interruption)
            if let stillPlan {
                try stillPlanner.write(stillPlan, to: output, progress: progress.report)
                report.outputBytes = ExportOutputSize.bytes(at: output)
            }
            if let preflight = report.preflight { try engine.write(preflight, to: output) { _ = progress.report($0) } }
        }
        try writeJSON(report, pretty: !json, checkCancellation: options.outProject == nil && (output == nil || options.dryRun))
    }
}

/// Load every selected document before probing any recording. A later project's
/// Undo history can reference the sidecar path of an earlier clip.
private struct MixedProjectInput {
    enum Source {
        case project(MulticamProject, URL)
        case recording(URL)
    }
    struct Clip {
        let number: Int
        let from: RationalTime?
        let to: RationalTime?
        let source: Source
    }

    var hasVisibleReplacements: Bool {
        clips.contains { clip in
            guard case let .project(project, _) = clip.source else { return false }
            return project.hasVisibleReplacement(in: .init(from: clip.from ?? project.range.from,
                                                           to: clip.to ?? project.range.to))
        }
    }

    var hasRecordingGaps: Bool {
        clips.contains { clip in
            guard case let .project(project, _) = clip.source,
                  project.angles.contains(where: { $0.coverage != nil }) else { return false }
            let selection = MulticamRange(from: clip.from ?? project.range.from, to: clip.to ?? project.range.to)
            return (try? project.plan(ranges: [selection]).intervals.contains(where: { $0.pictureSourceID == nil })) == true
        }
    }

    let clips: [Clip]
    let excludedSidecarSources: Set<URL>
    let projectsBySource: [URL: URL]

    static func withSidecarContext(_ mixed: Self?, exclusions: Set<URL>, _ body: () throws -> Void) rethrows {
        try SidecarLocations.$projectsBySource.withValue(mixed?.projectsBySource ?? SidecarLocations.projectsBySource) {
            try AnalysisSidecar.$excludedSources.withValue(exclusions, operation: body)
        }
    }

    init(_ input: InputEdit, order: [Int]?, output: URL, interruption: Interruption) throws {
        var projects: [URL: MulticamProject] = [:]
        var references: [String: String] = [:]
        var owners: [URL: URL] = [:]
        var candidates = Set<URL>()
        var clips: [Clip] = []
        for number in order ?? Array(1...input.clips.count) {
            try interruption.check()
            let clip = input.clips[number - 1]
            let from = try timestamp(clip.from, segment: number, boundary: "from")
            let to = try timestamp(clip.to, segment: number, boundary: "to")
            let source: Source
            if let path = clip.project {
                guard !isStandardInput(path) else {
                    throw CLIError("invalid_json", "Project clip \(number) must name a saved project file. Standard input carries the request. Use ./- for a file named '-'.")
                }
                let location = try fileURL(path, label: "Project clip \(number)")
                if let cached = projects[location] {
                    source = .project(cached, location)
                } else {
                    do {
                        let media = try CutProjectMedia.load(from: location, multicam: true)
                        guard case .multicam(let project) = media.project else {
                            throw CutError(code: "invalid_multicam_project", message: "Expected a multicam project")
                        }
                        guard !media.project.requiresPictureProcessing else {
                            throw ParticipantProjectExport.unsupported("An ordered join")
                        }
                        try checkProjectOutput(output, media: media, location: location)
                        if AnalysisSidecar.readsEnabled {
                            references.merge(media.absoluteSources(relativeTo: location)) { first, _ in first }
                            for recording in project.sources {
                                let file = project.sourceURL(for: recording, relativeTo: location)
                                candidates.insert(file)
                                let key = SidecarLocations.sourceKey(file)
                                if owners[key] == nil { owners[key] = location }
                            }
                        }
                        projects[location] = project
                        source = .project(project, location)
                    } catch let error as CutError {
                        throw CutError(code: error.code, message: "Project clip \(number) (\(location.path)): \(error.message)",
                                       segment: number)
                    }
                }
            } else {
                guard let path = clip.file ?? input.file else {
                    throw CLIError("invalid_json", "Clip \(number) requires a project or file path, or a top-level file.")
                }
                let file = try fileURL(path, label: "Clip \(number)")
                candidates.insert(file)
                references[file.path] = path
                source = .recording(file)
            }
            clips.append(Clip(number: number, from: from, to: to, source: source))
        }
        self.clips = clips
        projectsBySource = owners
        excludedSidecarSources = SidecarLocations.$projectsBySource.withValue(owners) {
            AnalysisSidecar.readsEnabled ? CutProject.sidecarExclusions(absoluteSources: references, candidates: Array(candidates)) : []
        }
    }
}

private func runStill(_ options: StillOptions, json: Bool, interruption: Interruption) throws {
    if options.operation == .list {
        let loaded = try loadDocument(options.project, interruption: interruption)
        let report = try StillInspection(loaded.project, location: loaded.location, input: loaded.path,
                                         placement: options.placement)
        try writeJSON(report, pretty: !json)
        return
    }
    let isStdin = isStandardInput(options.project)
    guard !isStdin || !options.inPlace else {
        throw CLIError("invalid_arguments", "A project read from stdin requires --out-project FILE.")
    }
    let limit = CutProject.maximumHistorySteps
    let location: URL
    let current: CutProject
    let undo: [CutHistoryState]
    let redo: [CutHistoryState]
    let media: CutProjectMedia
    if isStdin {
        let bytes = try readStandardInput(interruption)
        let loaded = try CutProject.decodeEditorDocument(bytes, limit: limit)
        current = loaded.project
        undo = loaded.undo
        redo = loaded.redo
        media = loaded.media
        location = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".mpcut-stdin-\(UUID().uuidString).cut")
    } else {
        location = try fileURL(options.project, label: "Project")
        let loaded = try CutProject.loadEditorDocument(from: location, limit: limit)
        current = loaded.project
        undo = loaded.undo
        redo = loaded.redo
        media = loaded.media
    }
    let destination = try options.output.map { try fileURL($0, label: "Output project") } ?? location
    if !options.inPlace, media.diskRevision?.matchesDestination(destination) == true {
        throw CLIError("invalid_arguments", "Use --in-place to change the input project.")
    }
    try media.validateDestination(destination, relativeTo: location)
    if options.operation == .relink {
        let archive = CLIProjectMediaArchive(location: location, project: current, undo: undo, redo: redo, media: media)
        guard let id = options.asset, let asset = current.stillAssets.first(where: { $0.id == id && !$0.isGap }),
              let image = options.image else {
            throw CutError(code: "still_asset_missing", message: "Choose an existing still image asset.")
        }
        let result = try ProjectMedia.relink(project: current, undo: undo, redo: redo, snapshot: media.mediaSnapshot,
                                             relativeTo: location, from: asset.file, to: fileURL(image, label: "Image"),
                                             cancelled: { !interruption.isActive })
        let rebased = try result.project.rebased(from: location, to: destination)
        var report = try StillInspection(rebased, location: destination, input: destination.path)
        let saved = try archive.save(result.project, undo: result.undo, redo: result.redo, snapshot: result.snapshot,
                                     destination: .init(url: destination, inPlace: options.inPlace), interruption: interruption,
                                     beforePublish: result.candidate.checkGeneration)
        report.timeline = saved
        report.assetID = id
        try writeJSON(report, pretty: !json, checkCancellation: false)
        return
    }
    let edit = try AnalysisSidecar.$excludedSources.withValue(
        AnalysisSidecar.excludedSources.union(media.sidecarExclusions(relativeTo: location))
    ) {
        try options.edit(current, relativeTo: location, cancelled: { !interruption.isActive })
    }
    var paths: [String: String] = [:]
    let saved = try edit.project.rebased(from: location, to: destination, paths: &paths)
    var report = try StillInspection(saved, location: destination, input: destination.path)
    report.placementID = edit.placementID
    report.assetID = edit.assetID
    let changed = edit.project != current
    if changed || !options.inPlace {
        let existingAssets = Set(current.stillAssets)
        var newEntries = edit.project.stillAssets.filter { !existingAssets.contains($0) }.compactMap {
            ProjectMediaSnapshot.Entry(path: $0.file, asset: $0)
        }
        if let clip = edit.project.stillSoundtrack, let media = edit.soundtrackMedia {
            newEntries.append(.init(path: clip.file, media: media))
        }
        let snapshot = media.mediaSnapshot.merging(.init(entries: newEntries)).rebased(from: location, to: destination)
        func rebase(_ state: CutHistoryState) throws -> CutHistoryState {
            try state.rebased(from: location, to: destination, paths: &paths)
        }
        let history = changed ? undo + [CutHistoryState(action: edit.action, project: current)] : undo
        let savedUndo = try history.map(rebase)
        let savedRedo = try changed ? [] : redo.map(rebase)
        let beforePublish = {
            try interruption.check()
            if let media = edit.soundtrackMedia {
                guard media.identity.isCurrentSnapshot(at: media.url) else {
                    throw CutError(code: "source_changed", message: "The soundtrack changed while the project was being saved.")
                }
            }
        }
        try beforePublish()
        if options.inPlace {
            _ = try saved.saveRevision(to: destination, undo: savedUndo, redo: savedRedo,
                                       mediaSnapshot: snapshot,
                                       expected: media.diskRevision, beforePublish: beforePublish)
        } else {
            report.timeline = try saved.saveNewCopy(to: destination, copyingTranscriptsFrom: location,
                                                    undo: savedUndo, redo: savedRedo, mediaSnapshot: snapshot,
                                                    check: beforePublish)
        }
    }
    try writeJSON(report, pretty: !json, checkCancellation: false)
}

private func runStillExport(_ loaded: LoadedProject<CutProject>, output: URL, dryRun: Bool,
                            options: ExportOptions, json: Bool, useSidecar: Bool,
                            interruption: Interruption) throws {
    let soundtrackIdentity: SourceIdentity?
    if options.tracks != .video, options.audio != .removeAudio, let clip = loaded.project.stillSoundtrack {
        soundtrackIdentity = try loaded.media.mediaSnapshot.expectedStillSoundtrack(clip, relativeTo: loaded.location)
    } else {
        soundtrackIdentity = nil
    }
    try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
        try runStillExport(loaded.project, location: loaded.location, output: output, dryRun: dryRun, options: options,
                           json: json, useSidecar: useSidecar, interruption: interruption,
                           expectedSoundtrackIdentity: soundtrackIdentity)
    }
}

private func checkSpacing(_ options: ExportOptions) throws {
    guard options.tracks != .audio, options.snap != .nearest, options.replaceAudio == nil else {
        throw CLIError("invalid_arguments", "--space-clips requires picture output and exact cut boundaries without source audio replacement.")
    }
    try options.checkTrackSelection()
}

private func spacedProject(_ project: CutProject, using spacing: ClipSpacing, relativeTo location: URL,
                           engine: CutEngine) throws -> CutProject {
    guard project.hasSpacingBoundaries else { return project }
    let timing = StillAuthoringTiming(project: project, location: location, engine: engine)
    let cadence: RationalTime
    if spacing == .duration(.zero) {
        cadence = .init(numerator: 1, denominator: 30)
    } else {
        cadence = try project.stillFormat?.cadence ?? timing.inferredCadence(.zero, requireUniform: false)
    }
    switch spacing {
    case .source:
        return try project.spacingClipsUsingSourceTiming(cadence: cadence, background: "#000000", relativeTo: location)
    case .duration(let duration):
        return try project.spacingClips(duration: duration, cadence: cadence, background: "#000000")
    }
}

private func clipSequence(_ clips: [ClipRequest], media: [URL: MediaInfo], engine: CutEngine) throws -> CutProject {
    var sources = media
    let sequence = try clips.enumerated().map { index, clip in
        let info = try sources[clip.file] ?? engine.inspectSummary(clip.file)
        sources[clip.file] = info
        guard info.hasVideo else {
            throw CutError(code: "no_video", message: "Clip spacing requires a video source.", segment: index + 1)
        }
        let from = clip.from ?? .zero
        let to = clip.to ?? info.duration
        guard from >= .zero, from < to, to <= info.duration else {
            throw CutError(code: "invalid_range", message: "Choose a nonempty range within the source.", segment: index + 1)
        }
        return CutSequenceClip(id: "clip-\(index + 1)", file: clip.file.path, from: from, to: to)
    }
    return .sequence(sequence)
}

private func runStillExport(_ project: CutProject, location: URL?, output: URL, dryRun: Bool,
                            options: ExportOptions, json: Bool, useSidecar: Bool,
                            interruption: Interruption, replacementReferenceAngles: [String: String] = [:],
                            expectedSoundtrackIdentity: SourceIdentity? = nil) throws {
    let tracks = options.tracks ?? .all
    let spacingRequiresCopy = options.spaceClips != nil && project.hasInteriorSpacingGaps && options.mode != .encode
    if spacingRequiresCopy && options.requireCameraCopy == false {
        throw CLIError("invalid_arguments", "Use --mode encode to allow re-encoding camera picture with --space-clips.")
    }
    try options.checkTrackSelection()
    guard options.replaceAudio == nil, options.snap != .nearest else {
        throw CLIError("invalid_arguments", "Set the project soundtrack and edit exact still boundaries before exporting.")
    }
    if options.mode == .copy && (options.video != nil || options.quality != nil) {
        throw CLIError("invalid_arguments", "Video and quality settings require Smart Trim or Re-encode.")
    }
    if tracks == .audio && (options.video != nil || options.quality != nil) {
        throw CLIError(ExportRules.soundSettingsRefusal.code, ExportRules.soundSettingsRefusal.message)
    }
    let isMulticam: Bool
    if case .multicam = project { isMulticam = true } else { isMulticam = false }
    guard isMulticam || options.audioOutput == nil else {
        throw CLIError("invalid_arguments", "--audio-output applies to multicam projects.")
    }
    if !isMulticam && options.mode == .copy && (options.audio ?? .copyOriginal) != .copyOriginal {
        throw CLIError("invalid_arguments", "Use Smart Trim or Re-encode when converting sound.")
    }
    let settings = ReencodeSettings(codec: options.video ?? project.stillFormat?.codec ?? ExportRules.defaultCodec,
                                    quality: options.quality, audio: options.audio ?? .auto)
    let planner = StillExportPlanner(useSidecar: useSidecar, cancelled: { !interruption.isActive },
                                     replacementReferenceAngles: replacementReferenceAngles,
                                     expectedSoundtrackIdentity: expectedSoundtrackIdentity)
    let plan: StillExportPlan
    do {
        plan = try planner.resolve(project, relativeTo: location, tracks: tracks,
                                   audioStream: options.audioStream, mode: options.mode,
                                   requireCameraCopy: options.requireCameraCopy ?? spacingRequiresCopy,
                                   container: options.container, output: output, settings: settings,
                                   audioOutput: options.audioOutput ?? .separateTracks, audioAction: options.audio,
                                   pictureTiming: options.stillTiming, videoCodec: options.video)
    } catch var issue as CutError where options.spaceClips != nil && (spacingRequiresCopy || options.requireCameraCopy == true) {
        let replayable = issue.alternatives?.filter { offer in
            offer.arguments.contains("--require-camera-copy") ||
                (options.requireCameraCopy != true && offer.mode == .encode)
        }
        issue.alternatives = replayable?.isEmpty == false ? replayable : nil
        throw issue
    }
    if !dryRun {
        let progress = ExportProgress(interruption: interruption)
        try planner.write(plan, to: output, progress: progress.report)
    }
    let outputBytes = dryRun ? nil : ExportOutputSize.bytes(at: output)
    if json || dryRun {
        try writeJSON(StillCLIExportReport(dryRun: dryRun, output: output.path, outputBytes: outputBytes, report: plan.report,
                                           audioStream: options.audioStream), pretty: !json,
                      checkCancellation: dryRun)
    } else {
        try interruption.beginResponse(checkCancellation: false)
        let size = outputBytes.map { " (\($0) bytes)" } ?? ""
        try writeOutput("Exported " + output.path + size)
    }
}

private func runMulticamExport(project loaded: LoadedProject<MulticamProject>? = nil, input: InputEdit? = nil,
                               order: [Int]? = nil, output: URL, options: ExportOptions,
                               dryRun: Bool, json: Bool, interruption: Interruption) throws {
    let tracks = options.tracks ?? .all
    // Reject the settings multicam never accepts before the general checks, whose advice
    // (add --tracks audio, add --replace-audio, change the mode) would lead to another refusal.
    guard options.snap != .nearest else {
        throw CLIError("invalid_arguments", "Multicam export uses exact cuts. Apply a suggested group time to the project or request before exporting.")
    }
    guard options.audioStream == nil else {
        throw CLIError("invalid_arguments", "Choose project microphones in the project audio policy, angle audio_stream_index fields, or switch overrides.")
    }
    guard options.replaceAudio == nil, options.replaceTrack == nil, options.replacementStream == nil else {
        throw CLIError("invalid_arguments", "Set an external recorder in audio_sources and select it in the project audio policy.")
    }
    let mixed = try input.map { try MixedProjectInput($0, order: order, output: output, interruption: interruption) }
    let includesParticipants = loaded.map { CutProject.multicam($0.project).requiresPictureProcessing } ?? false
    if includesParticipants, tracks != .audio, options.requireCameraCopy == true {
        throw CutError(code: "camera_copy_required", message: "The participant export would encode picture.")
    }
    let mode = options.mode ?? (includesParticipants ? .encode : ExportRules.defaultMode(for: .multicam, tracks: tracks))
    let videoGapEncode = tracks == .video && mode == .encode && (
        (loaded?.project.angles.contains(where: { $0.coverage != nil }) == true &&
         (try? loaded?.project.plan().intervals.contains(where: { $0.pictureSourceID == nil })) == true) ||
        mixed?.hasRecordingGaps == true
    )
    let cell = ExportEntryPoint.cliProject.answer(source: .multicam, tracks: tracks, mode: mode,
                                                   placements: videoGapEncode ? .replacement : .none)
    if mixed?.hasVisibleReplacements != true {
        if !includesParticipants, let refusal = cell.refusal { throw CLIError(refusal.code, refusal.message) }
        try validate(options, mode: mode, multicam: true)
    }
    let settings = ReencodeSettings(codec: options.video ?? ExportRules.defaultCodec, quality: options.quality,
                                    audio: options.audio ?? .auto)
    var applied: ExportAlternative?
    let exclusions = loaded?.excludedSidecarSources ?? AnalysisSidecar.excludedSources.union(mixed?.excludedSidecarSources ?? [])
    try MixedProjectInput.withSidecarContext(mixed, exclusions: exclusions) {
        let engine = MulticamEngine(cancelled: { !interruption.isActive })
        var extraRangeInputs: [Int: Int] = [:]
        var tier: TierSummary?
        let plan: MulticamExportPlan
        let sources: [String: URL]
        if let loaded {
            let (project, location) = (loaded.project, loaded.location)
            sources = Dictionary(uniqueKeysWithValues: project.sources.map {
                ($0.id, project.sourceURL(for: $0, relativeTo: location))
            })
            // The plan, or the failure with the alternatives that work, as every export reports them.
            let resolution = engine.resolution(project, relativeTo: location, output: output, mode: mode,
                                               tracks: tracks, settings: settings,
                                               audioOutput: options.audioOutput ?? .separateTracks, audioAction: options.audio)
            plan = try resolution.get()
            applied = resolution.applied
            // A dry run and a JSON report also say how good the program is on its own, whatever mode was asked for.
            if json || dryRun {
                tier = plan.participantRenderTier?.summary(source: .multicam)
                    ?? engine.tier(project, relativeTo: location).summary(source: .multicam)
            }
        } else if let mixed {
            var assembly = MulticamAssembly(includeAudio: tracks != .video && options.audio != .removeAudio)
            var files: [URL: MediaInfo] = [:]
            let fileEngine = CutEngine(cancelled: { !interruption.isActive })
            var listedRanges: [Int: [AudioSpan]] = [:]
            var extraRangeStarts: [Int: Int] = [:]
            var listedPieces = 0
            for clip in mixed.clips {
                try interruption.check()
                switch clip.source {
                case .project(let project, let location):
                    try assembly.appendProject(project, at: location,
                                               range: MulticamRange(from: clip.from ?? project.range.from,
                                                                    to: clip.to ?? project.range.to),
                                               segment: clip.number)
                case .recording(let location):
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
                    let scope = AudioSpan(from: clip.from ?? .zero, to: clip.to ?? media.duration)
                    let entry = input?.clips[clip.number - 1]
                    let spans: [AudioSpan]
                    if let path = entry?.rangesFile {
                        guard scope.from >= .zero, scope.to <= media.duration else {
                            throw CLIError("invalid_range", "Clip \(clip.number) is outside its source.")
                        }
                        if let cached = listedRanges[clip.number] {
                            spans = cached
                        } else {
                            let url = try fileURL(path, label: "Range list")
                            spans = try ListFile.ranges(url, clip: scope, cancelled: { !interruption.isActive })
                            listedRanges[clip.number] = spans
                        }
                        listedPieces += spans.count
                        guard listedPieces <= ClipEditCSV.maximumPieces else {
                            throw CLIError("invalid_list", "Range lists and repetitions exceed the \(ClipEditCSV.maximumPieces)-piece export limit.")
                        }
                    } else { spans = [scope] }
                    // Repeating a clip repeats its rows. Each distinct row needs its own
                    // planner ID so trying a suggested boundary moves only that row.
                    if spans.count > 1, extraRangeStarts[clip.number] == nil {
                        let firstExtra = (input?.clips.count ?? 0) + extraRangeInputs.count + 1
                        extraRangeStarts[clip.number] = firstExtra
                        for offset in 0..<(spans.count - 1) { extraRangeInputs[firstExtra + offset] = clip.number }
                    }
                    for (offset, span) in spans.enumerated() {
                        let rangeID = offset == 0 ? clip.number : extraRangeStarts[clip.number]! + offset - 1
                        try assembly.appendFile(media, range: MulticamRange(from: span.from, to: span.to),
                                                segment: rangeID, tracks: tracks)
                    }
                }
            }
            if let flattened = try assembly.projectWithVisibleReplacements() {
                try runStillExport(.multicam(flattened.project), location: flattened.location, output: output, dryRun: dryRun,
                                   options: options, json: json, useSidecar: AnalysisSidecar.readsEnabled,
                                   interruption: interruption, replacementReferenceAngles: flattened.referenceAngles)
                return
            }
            sources = assembly.sources
            let request = assembly
            do {
                let resolution = engine.resolution(request.mapping, sources: sources, output: output, mode: mode,
                                                   tracks: tracks, settings: settings, requireAudio: request.requiresAudio,
                                                   audioOutput: options.audioOutput ?? .separateTracks, audioAction: options.audio) { clip, boundary, time in
                    try request.moving(clip: clip, boundary: boundary, to: time).mapping
                }
                plan = try resolution.get()
                applied = resolution.applied
                // Range lists expand into planner rows that the request does not number, so the tier is reported
                // when every clip is one range.
                if json || dryRun, extraRangeInputs.isEmpty {
                    tier = engine.tier(request.mapping, sources: sources, requireAudio: request.requiresAudio) { clip, boundary, time in
                        try request.moving(clip: clip, boundary: boundary, to: time).mapping
                    }.summary(source: .multicam)
                }
            } catch let issue as CutError {
                guard let id = issue.segment, let original = extraRangeInputs[id] else { throw issue }
                throw issue.reportingInputClip(original)
            }
        } else {
            throw CLIError("invalid_arguments", "Export a project or an ordered list of clips.")
        }
        if options.requireCameraCopy == true, plan.encodedVideoDuration > .zero {
            throw CutError(code: "camera_copy_required", message: "The selected export would encode camera picture.")
        }
        try interruption.check()
        if !dryRun {
            let progress = ExportProgress(interruption: interruption)
            try engine.write(plan, to: output) { _ = progress.report($0) }
        }
        if json || dryRun {
            try writeJSON(MulticamExportResponse(dryRun: dryRun, output: output.path, order: order,
                                                sources: sources.mapValues(\.path), preflight: plan, extraRangeInputs: extraRangeInputs,
                                                isMixedJoin: mixed != nil, applied: applied, tier: tier),
                          pretty: !json, checkCancellation: dryRun)
        } else {
            try interruption.beginResponse(checkCancellation: false)
            if let applied { errorOutput("mpcut: \(applied.label)") }
            for warning in plan.warnings { errorOutput("mpcut: \(warning)") }
            try writeOutput("Exported \(output.path)")
        }
    }
}

private func finishResolveExport(_ output: URL, open: Bool, json: Bool, interruption: Interruption,
                                 warnings: [String] = []) throws {
    if open { try ResolveExport.openInResolve(output, cancelled: { !interruption.isActive }) }
    if json {
        struct Result: Encodable {
            let ok = true
            let output: String
            let opened: Bool
            let warnings: [String]
        }
        try writeJSON(Result(output: output.path, opened: open, warnings: warnings), checkCancellation: false)
    } else {
        try interruption.beginResponse(checkCancellation: false)
        for warning in warnings { errorOutput("mpcut: " + warning) }
        try writeOutput("Exported " + output.path)
    }
}

private func inspectRangeListSource(_ file: URL, options: ExportOptions, interruption: Interruption) throws -> MediaInfo {
    do {
        return try CutEngine(cancelled: { !interruption.isActive }).inspect(file, keyframes: true)
    } catch let issue as CutError where options.mode == .encode && options.tracks != .audio
        && ["probe_failed", "unsupported_tracks"].contains(issue.code) {
        return try ReencodeEngine(cancelled: { !interruption.isActive }).conversionMedia(file)
    }
}

private func rangeListDuration(_ media: MediaInfo, options: ExportOptions) throws -> RationalTime {
    if options.mode == .encode, options.tracks == .audio {
        return try media.extendingToAudioEnd(stream: options.audioStream ?? media.audio.first?.stream.index).duration
    }
    return media.duration
}

private func renderLoadedProject(_ loaded: LoadedProject<CutProject>, output: URL, flags: ExportOptions, dryRun: Bool,
                                 arguments: Arguments, interruption: Interruption) async throws {
    let placements = try loaded.project.exportPlacementScope()
    if !loaded.project.requiresPictureProcessing, placements != .none || loaded.project.stillFormat != nil {
        try runStillExport(loaded, output: output, dryRun: dryRun, options: flags, json: arguments.json,
                           useSidecar: arguments.useSidecar, interruption: interruption)
        return
    }
    guard flags.stillTiming == nil, flags.container == nil else {
        throw CLIError("invalid_arguments", "--still-timing and --container apply to still project exports.")
    }
    var options = flags
    options.spaceClips = nil
    switch loaded.project {
    case .multicam(let multicam):
        let document = LoadedProject(project: multicam, media: loaded.media, location: loaded.location, file: loaded.file)
        try runMulticamExport(project: document, output: output, options: options,
                              dryRun: dryRun, json: arguments.json, interruption: interruption)
    case .sequence, .stillSequence:
        if loaded.project.requiresPictureProcessing {
            let mode = options.mode ?? .encode
            try validate(options, mode: mode)
            let tracks = options.tracks ?? .all
            if tracks != .audio, options.requireCameraCopy == true {
                throw CutError(code: "camera_copy_required", message: "The participant export would encode picture.")
            }
            if tracks != .audio, options.audioStream != nil {
                throw ParticipantProjectExport.unsupported("Selecting a source audio stream")
            }
            let settings = ReencodeSettings(codec: options.video ?? .h264, quality: options.quality,
                                            audio: options.audio ?? .auto)
            let cancelled: @Sendable () -> Bool = { !interruption.isActive }
            let export = try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                let export = try ParticipantProjectExport(loaded.project, relativeTo: loaded.location, output: output, mode: mode,
                                                          tracks: tracks, settings: settings, audioStream: options.audioStream,
                                                          cancelled: cancelled)
                if !dryRun {
                    let progress = ExportProgress(interruption: interruption)
                    try export.write(to: output, cancelled: cancelled) { progress.report($0) }
                }
                return export
            }
            if arguments.json || dryRun {
                struct Result: Encodable {
                    let ok = true
                    let output: String
                    let dryRun: Bool
                    let mode: ExportMode
                    let tracks: ExportTracks
                    let container: String
                    let duration: RationalTime
                    let encodedVideoDuration: RationalTime
                    let copiedVideoDuration = RationalTime.zero
                    let tier: TierSummary?
                    let participantRender: ParticipantRenderReport
                }
                let container = output.pathExtension.lowercased()
                try writeJSON(Result(output: output.path, dryRun: dryRun, mode: mode, tracks: tracks,
                                     container: container, duration: export.report.duration,
                                     encodedVideoDuration: tracks == .audio ? .zero : export.report.duration,
                                     tier: export.tier(container: container).summary(source: .movie),
                                     participantRender: export.report),
                              pretty: !arguments.json, checkCancellation: dryRun)
            } else {
                try interruption.beginResponse(checkCancellation: false)
                for warning in [export.report.picturePrivacyNotice, export.report.audioPrivacyNotice].compactMap({ $0 }) {
                    errorOutput("mpcut: " + warning)
                }
                try writeOutput("Exported " + output.path)
            }
            return
        }
        try await AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
            let clips = try (loaded.project.sequenceClips ?? []).map { source in
                let file = try CutProject.checkedMediaURL(source.file, relativeTo: loaded.location)
                var clip = InputClip(file: file.path)
                clip.occurrenceID = source.id
                clip.from = source.from.description
                clip.to = source.to.description
                return clip
            }
            let input = InputEdit(output: output.path, clips: clips)
            try await run(arguments.replacingCommand(.export(input: input, dryRun: dryRun, options: options, order: nil)),
                          interruption: interruption)
        }
    }
}

/// Project commands carry their own context, including recursive command dispatch for JSON requests.
private func run(_ arguments: Arguments, interruption: Interruption) async throws {
    let path: String?
    switch arguments.command {
    case .inspectProject(let project), .resolve(let project, _, _), .exportProject(let project, _, _, _):
        path = project
    case .convert(let source, _, _, _):
        path = URL(fileURLWithPath: source).pathExtension.lowercased() == "cut" ? source : nil
    case .multicamSync(let options): path = options.project
    case .refresh(let options): path = options.project
    case .projectMedia(let options): path = options.project
    case .still(let options): path = options.project
    case .silence(let options): path = options.project
    case .frames(let options):
        if case .project(let file, _, _) = options.source { path = file } else { path = nil }
    case .scenes(let options):
        if case .project(let project, _) = options.input { path = project } else { path = nil }
    default: path = nil
    }
    let project = try path.flatMap { isStandardInput($0) ? nil : try fileURL($0, label: "Project") }
    try await SidecarLocations.$projectURL.withValue(project ?? SidecarLocations.projectURL) {
        try await runCommand(arguments, interruption: interruption)
    }
}

private func runCommand(_ arguments: Arguments, interruption: Interruption) async throws {
    switch arguments.command {
    case let .multicamSync(options):
        let loaded = try loadProject(options.project, interruption: interruption)
        if let incoming = options.replacement, let referenceID = options.referenceSourceID {
            guard let reference = loaded.project.pictureSources.first(where: { $0.id == referenceID }) else {
                throw CLIError("invalid_target", "Choose an original camera recording.")
            }
            let url = try fileURL(incoming.path, label: "Replacement")
            let source = MulticamSource(id: UUID().uuidString, file: url.path, audioStream: incoming.stream)
            let ranges = try MulticamSync.usedReferenceRanges(project: loaded.project, referenceSourceID: referenceID,
                                                             referenceStream: incoming.referenceStream,
                                                             program: incoming.program)
            let request = MulticamSync.ReplacementRequest(
                referenceSourceID: referenceID, referenceStream: incoming.referenceStream,
                source: source, stream: incoming.stream, seed: incoming.seed,
                referenceRanges: ranges)
            let (report, track) = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                    let engine = CutEngine(cancelled: { !interruption.isActive }, useSidecar: arguments.useSidecar)
                    let media = try engine.inspectMulticamSource(url)
                    guard let track = media.audio.first(where: { $0.stream.index == incoming.stream }) else {
                        throw CLIError("invalid_target", "Choose an available absolute replacement audio stream index.")
                    }
                    let report = try MulticamSync.analyzeReplacement(
                        loaded.project, request: request, relativeTo: loaded.location, indexed: [source.id: media],
                        waveform: !options.metadataOnly && incoming.referenceStream != nil, useSidecar: arguments.useSidecar,
                        cancelled: { !interruption.isActive })
                    return (report, track)
                }
            }
            struct Reply: Encodable {
                let ok = true
                let report: MulticamSync.Report
                let metadataRelativeOffset: String?
                let waveformRelativeOffset: String?
                let metadataCoverage: MulticamSync.ReplacementCoverage?
                let waveformCoverage: MulticamSync.ReplacementCoverage?
            }
            let suggestion = report.suggestions.first
            let metadata = try suggestion?.metadataOffset.map { try $0.subtracting(reference.offset) }
            let waveform = try suggestion?.waveformOffset.map { try $0.subtracting(reference.offset) }
            try writeJSON(Reply(report: report,
                                metadataRelativeOffset: metadata?.description,
                                waveformRelativeOffset: waveform?.description,
                                metadataCoverage: metadata.map { try MulticamSync.replacementCoverage(in: ranges, track: track, relativeOffset: $0) },
                                waveformCoverage: waveform.map { try MulticamSync.replacementCoverage(in: ranges, track: track, relativeOffset: $0) }),
                          pretty: !arguments.json)
            return
        }
        let report = try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
            try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                try MulticamSync.analyze(loaded.project, relativeTo: loaded.location, sourceID: options.sourceID,
                                         referenceSourceID: options.referenceSourceID,
                                         waveform: !options.metadataOnly, useSidecar: arguments.useSidecar,
                                         cancelled: { !interruption.isActive })
            }
        }
        try writeJSON(report, pretty: !arguments.json)
    case let .sidecar(options):
        let source = try fileURL(options.file, label: "Input")
        if let path = options.project, isStandardInput(path) {
            throw CLIError("invalid_arguments", "--project requires a saved project file.")
        }
        let project = try options.project.map { try loadDocument($0, interruption: interruption) }
        let result = try await SidecarLocations.$projectURL.withValue(project?.file) {
            try await AnalysisSidecar.$excludedSources.withValue(project?.excludedSidecarSources ?? AnalysisSidecar.excludedSources) {
                try await AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                    try await options.run(source: source, cancelled: { !interruption.isActive })
                }
            }
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
    case let .stillCreate(options):
        try interruption.check()
        let result = try options.create(cancelled: { !interruption.isActive })
        try writeJSON(result, pretty: !arguments.json, checkCancellation: false)
    case let .still(options):
        try runStill(options, json: arguments.json, interruption: interruption)
    case let .tiles(options):
        try options.run(json: arguments.json, useSidecar: arguments.useSidecar, interruption: interruption)
    case let .participants(options):
        try options.run(json: arguments.json, useSidecar: arguments.useSidecar, interruption: interruption)
    case let .transcript(options):
        try options.run(json: arguments.json, useSidecar: arguments.useSidecar, interruption: interruption)
    case let .silence(options):
        try await runSilence(options, arguments: arguments, requestFile: arguments.requestFile, json: arguments.json, interruption: interruption)
    case let .scenes(options):
        try runSceneScan(options, json: arguments.json, useSidecar: arguments.useSidecar, interruption: interruption)
    case let .sceneExport(file, options):
        try runSceneExport(file: file, requestFile: arguments.requestFile, options: options, json: arguments.json, interruption: interruption)
    case let .projectMedia(options):
        try options.run(json: arguments.json, interruption: interruption)
    case let .refresh(options):
        struct Response: Encodable {
            let ok = true
            let projectPath: String
            let sources: [MediaRefreshResult]
            let media: [ProjectMediaRow]
        }
        let project = try fileURL(options.project, label: "Project")
        var lastUpdate = -Double.infinity
        let progress: ((Double) -> Void)? = options.progress == .none ? nil : { fraction in
            let now = ProcessInfo.processInfo.systemUptime
            guard fraction == 1 || now - lastUpdate >= 0.2 else { return }
            lastUpdate = now
            reportMediaProgress(MediaProgressEvent(fraction: fraction), output: options.progress)
        }
        let result = try MediaRefresh.project(at: project, verification: options.deep ? .deep : .stamp,
                                              persist: arguments.useSidecar, progress: progress,
                                              cancelled: { !interruption.isActive })
        let archive = try CLIProjectMediaArchive(at: project)
        let statuses: [URL: ProjectMediaStatus] = Dictionary(uniqueKeysWithValues: result.compactMap { source in
            if source.state == .offline { return (source.source, .offline) }
            if !source.referenceIssues.isEmpty { return (source.source, .needsReview) }
            return nil
        })
        let rows = ProjectMedia.inventory(project: archive.project, undo: archive.undo, redo: archive.redo,
                                          relativeTo: project, snapshot: archive.media.mediaSnapshot,
                                          statuses: statuses)
        try writeJSON(Response(projectPath: project.path, sources: result, media: rows), pretty: !arguments.json,
                      checkCancellation: false)
    case let .waveform(options):
        let result = try options.run(fileURL(options.file, label: "Input"), cancelled: { !interruption.isActive })
        try writeJSON(result, pretty: !arguments.json)
    case .multicamSwitchCoverage:
        let data = try arguments.requestFile.map { try ClipEditCSV.readListData(fileURL($0, label: "Request"), kind: "JSON",
                                                                                cancelled: { !interruption.isActive }) } ?? readStandardInput(interruption)
        try writeJSON(multicamSwitchCoverage(data: data, useSidecar: arguments.useSidecar, interruption: interruption),
                      pretty: !arguments.json)
    case let .timelineReview(options):
        try options.run(pretty: !arguments.json)
    case let .authorProject(creating):
        let data = try arguments.requestFile.map { try ClipEditCSV.readListData(fileURL($0, label: "Request"), kind: "JSON",
                                                                                cancelled: { !interruption.isActive }) } ?? readStandardInput(interruption)
        try writeJSON(authorProject(data: data, creating: creating, interruption: interruption), pretty: !arguments.json, checkCancellation: false)
    case let .frames(options):
        let output = try fileURL(options.output, label: "Output directory", directory: true)
        switch options.source {
        case let .video(file, selection, sample, limit):
            let media = try CutEngine(cancelled: { !interruption.isActive }).inspect(
                fileURL(file, label: "Input"), keyframes: true)
            guard media.hasVideo else { throw CutError(code: "no_video", message: "JPEG export requires a video stream.") }
            let result = try JPEGExport.write(media, to: output, selection: selection, sample: sample,
                                              preset: options.preset, format: options.format,
                                              limit: limit, cancelled: { !interruption.isActive })
            try writeJSON(result, pretty: !arguments.json, checkCancellation: false)
        case let .project(file, times, clock):
            let identity = isStandardInput(file) ? nil : (try? SourceIdentity(fileURL(file, label: "Project")))
            let loaded = try loadDocument(file, interruption: interruption)
            try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                if !loaded.project.requiresPictureProcessing, case .multicam(let multicam) = loaded.project, clock == nil || clock == .group {
                    let result = try JPEGExport.writeMulticam(multicam, document: loaded.file, at: times, to: output,
                                                              preset: options.preset, format: options.format,
                                                              useSidecar: arguments.useSidecar,
                                                              documentIdentity: identity,
                                                              projectMedia: loaded.media,
                                                              cancelled: { !interruption.isActive })
                    try writeJSON(result, pretty: !arguments.json, checkCancellation: false)
                } else {
                    let result = try writeProgramFrames(loaded.project, media: loaded.media, projectPath: loaded.path,
                                                        location: loaded.location, at: times, clock: clock, to: output,
                                                        preset: options.preset, format: options.format,
                                                        documentIdentity: identity,
                                                        useSidecar: arguments.useSidecar, cancelled: { !interruption.isActive })
                    try writeJSON(result, pretty: !arguments.json, checkCancellation: false)
                }
            }
        }
    case .printDocument(let source):
        let saved = try isStandardInput(source) ? readStandardInput(interruption)
            : Data(contentsOf: fileURL(source, label: "Project"))
        let document = try CutProject.readableDocument(saved: saved)
        try interruption.beginResponse(checkCancellation: false)
        try writeOutput(document)
    case let .mergeProject(base, ours, theirs):
        let target = URL(fileURLWithPath: ours)
        let sides = try ProjectMerge.sides(base: Data(contentsOf: URL(fileURLWithPath: base)),
                                           ours: Data(contentsOf: target),
                                           theirs: Data(contentsOf: URL(fileURLWithPath: theirs)))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let files = [("ours", sides.ours), ("base", sides.base), ("theirs", sides.theirs)].map {
            (scratch.appendingPathComponent($0.0), $0.1)
        }
        for (file, text) in files { try text.write(to: file) }
        // Git's own line merge, on the edit alone.
        let merge = Process()
        merge.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        merge.arguments = ["git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs"] + files.map(\.0.path)
        let output = Pipe()
        merge.standardOutput = output
        try merge.run()
        let merged = output.fileHandleForReading.readDataToEndOfFile()
        merge.waitUntilExit()
        try interruption.beginResponse(checkCancellation: false)
        switch merge.terminationStatus {
        case 0:
            let saved: Data
            do {
                saved = try ProjectMerge.saved(merged)
            } catch {
                // Git keeps what is in OURS, so both branches' lines must be there to put right.
                try merged.write(to: target, options: .atomic)
                let reason = (error as? CutError)?.message ?? error.localizedDescription
                throw CLIError("merge_invalid", "The lines of \(ours) merged, but MPCut cannot open the result: \(reason) The merged text is in the file.")
            }
            try saved.write(to: target, options: .atomic)
        case 1...127:
            try merged.write(to: target, options: .atomic)
            throw CLIError("merge_conflict", "Both branches changed the same lines of \(ours). Resolve the marked lines.")
        default:
            throw CLIError("merge_failed", "git merge-file could not merge \(ours).")
        }
    case let .convert(source, destination, allowLoss, flattenMulticam):
        func projectURL(_ path: String, label: String) throws -> URL {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            return try fileURL(path, label: label, directory: ["fcpxmld", "fcpbundle"].contains(ext))
        }
        let input = try projectURL(source, label: "Project")
        let output = try projectURL(destination, label: "Output")
        let warnings: [String]
        do {
            warnings = try ProjectConverter.convert(input: input, output: output, allowLoss: allowLoss,
                                                    flattenMulticam: flattenMulticam, cancelled: { !interruption.isActive })
        } catch let error as CutError where error.code == "conversion_loss" && !allowLoss {
            throw CutError(code: error.code, message: error.message + " To accept this loss, run convert again with --allow-loss.")
        }
        if arguments.json {
            try writeJSON(ConversionResponse(input: input.path, output: output.path, warnings: warnings), checkCancellation: false)
        } else {
            try interruption.beginResponse(checkCancellation: false)
            for warning in warnings { errorOutput("mpcut: " + warning) }
            try writeOutput("Converted " + output.path)
        }
    case let .resolve(path, destination, open):
        let loaded = try loadDocument(path, interruption: interruption)
        let output = try fileURL(destination, label: "Output")
        try checkProjectOutput(output, media: loaded.media, location: loaded.location)
        let warnings = try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
            try ResolveExport.write(loaded.project, relativeTo: loaded.location, to: output,
                                    useSidecar: arguments.useSidecar, cancelled: { !interruption.isActive })
        }
        try finishResolveExport(output, open: open, json: arguments.json, interruption: interruption, warnings: warnings)
    case let .inspectProject(path):
        let loaded = try loadDocument(path, interruption: interruption)
        if hasStillPlacements(loaded.project) || !loaded.project.stillAssets.isEmpty ||
            loaded.project.programColorPolicy != nil || loaded.project.stillFormat != nil {
            var report = try StillInspection(loaded.project, location: loaded.location, input: loaded.path)
            if loaded.project.requiresPictureProcessing {
                let source: ExportSourceKind
                if case .multicam = loaded.project { source = .multicam } else { source = .movie }
                report.tier = AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                    ParticipantProjectExport.tier(loaded.project, relativeTo: loaded.location,
                                                  cancelled: { !interruption.isActive }).summary(source: source)
                }
            }
            if case .multicam(let project) = loaded.project,
               project.audio == .mix || !project.audioReplacements.isEmpty {
                report.inspection = try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                    try MulticamEngine(cancelled: { !interruption.isActive }).inspect(project, relativeTo: loaded.location)
                }
            }
            try writeJSON(report, pretty: !arguments.json)
            return
        }
        try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
            switch loaded.project {
            case .sequence, .stillSequence:
                let clips = loaded.project.sequenceClips ?? []
                var paths: [String: URL] = [:]
                var unavailable: CutError?
                let requests = clips.map { clip -> ClipRequest in
                    let file: URL
                    if let cached = paths[clip.file] {
                        file = cached
                    } else {
                        do {
                            file = try CutProject.checkedMediaURL(clip.file, relativeTo: loaded.location)
                        } catch {
                            file = ProjectMediaVolume.watchURL(clip.file, relativeTo: loaded.location)
                            if unavailable == nil {
                                unavailable = CutError(code: "missing_source", message: error.localizedDescription)
                            }
                        }
                        paths[clip.file] = file
                    }
                    return ClipRequest(file: file, from: clip.from, to: clip.to)
                }
                let sources = Dictionary(uniqueKeysWithValues: zip(clips, requests).map { ($0.id, $1.file.path) })
                let duration = try clips.reduce(RationalTime.zero) { try $0.adding($1.to.subtracting($1.from)) }
                // A project is inspected to be exported, so its sources are indexed for the tier. An empty one has none.
                let tier: TierSummary?
                if let unavailable {
                    tier = TierState.unavailable(unavailable).summary(source: .movie)
                } else if loaded.project.requiresPictureProcessing {
                    tier = ParticipantProjectExport.tier(loaded.project, relativeTo: loaded.location,
                                                         cancelled: { !interruption.isActive }).summary(source: .movie)
                } else {
                    tier = requests.isEmpty ? nil : TimelineTierEvaluator(useSidecar: arguments.useSidecar)
                        .summary(requests, cancelled: { !interruption.isActive })
                }
                try interruption.check()
                let selects = loaded.project.sourceSelects.map { select in
                    select.mapPath { CutProject.mediaURL($0, relativeTo: loaded.location).path }
                }
                try writeJSON(SequenceInspection(projectPath: loaded.path, clips: clips, sources: sources, duration: duration,
                                                 tier: tier, sourceSelects: selects.isEmpty ? nil : selects),
                              pretty: !arguments.json)
            case .multicam(let project):
                let result = try MulticamEngine(cancelled: { !interruption.isActive }).inspect(project, relativeTo: loaded.location)
                let group = try project.groupIntervals()
                // A project is inspected to be exported, so its program is planned for the tier.
                let indexed = Dictionary(result.sources.map { ($0.source.id, $0.media) }, uniquingKeysWith: { first, _ in first })
                    .filter { $0.value.hasFullEditIndex }
                let tier = MulticamEngine(cancelled: { !interruption.isActive })
                    .tier(project, relativeTo: loaded.location, indexedSources: indexed).summary(source: .multicam)
                try interruption.check()
                try writeJSON(MulticamInspectionResponse(project: loaded.path, report: result, groupIntervals: group, tier: tier),
                              pretty: !arguments.json)
            }
        }
    case let .inspect(file, keyframes, allFrames, audioPackets, packetStream, from, to, tracks, audioStream):
        let engine = CutEngine(cancelled: { !interruption.isActive }, tracks: tracks, audioStream: audioStream)
        try interruption.check()
        let source = try fileURL(file, label: "Input")
        if StillImage.isImageInput(source) {
            guard !keyframes, !allFrames, !audioPackets, packetStream == nil, from == nil, to == nil,
                  tracks == .all, audioStream == nil else {
                throw CLIError("invalid_arguments", "A still image has no movie tracks or timed samples. Inspect the image without track, frame, packet or range options.")
            }
            struct ImageInspection: Encodable {
                let ok = true
                let file: String
                let image: StillImageInfo
            }
            let report = try ImageInspection(file: source.path, image: StillImage.inspect(source))
            try writeJSON(report, pretty: !arguments.json)
            break
        }
        let media: MediaInfo
        if keyframes || allFrames { media = try engine.inspect(source, keyframes: true) }
        else if tracks == .all && !audioPackets {
            // The tier needs the cut index. A sidecar supplies it without reading the media again.
            media = try engine.inspect(source, keyframes: true)
        }
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
        // The tier of the whole source, or of the range between --from and --to.
        let tier = tracks == .all && media.hasFullEditIndex
            ? TimelineTierEvaluator(useSidecar: arguments.useSidecar)
                .summary([ClipRequest(file: source, from: from, to: to)], media: [source: media], cancelled: { !interruption.isActive })
            : nil
        try interruption.check()
        let data = try inspectionJSON(media, copy: CopyEligibility(reason: issue, containers: containers), tier: tier,
                                      listsFrames: keyframes || allFrames,
                                      allFrames: allFrames, packets: packets, from: from, to: to,
                                      pretty: !arguments.json, interruption: interruption)
        try data.write(to: interruption)
    case let .bulk(dryRun, flags, list):
        let input: BulkInput
        var cachedMedia: [URL: MediaInfo] = [:]
        if let list {
            let url = try fileURL(list.source, label: "Source")
            let media = try inspectRangeListSource(url, options: flags, interruption: interruption)
            cachedMedia[url] = media
            let duration = try rangeListDuration(media, options: flags)
            let spans = try ListFile.ranges(fileURL(list.ranges, label: "Range list"),
                                            clip: AudioSpan(from: .zero, to: duration), cancelled: { !interruption.isActive })
            input = BulkInput(list: list, spans: spans)
        } else {
            input = try readInput(interruption, path: arguments.requestFile)
        }
        let options = try flags.merging(input.options)
        let mode = options.mode ?? ExportRules.defaultMode(for: ExportEntryPoint.cliBulk.source)
        try validate(options, mode: mode)
        let file = try fileURL(input.file, label: "Source")
        let directory = try fileURL(input.outputDirectory, label: "Output directory", directory: true)
        let groups: [[ClipRequest]]
        switch input.ranges {
        case .parsed(let spans):
            groups = spans.map { [ClipRequest(file: file, from: $0.from, to: $0.to)] }
        case .request(let ranges):
            groups = try ranges.enumerated().map { index, range in
                [try ClipRequest(file: file, from: timestamp(range.from, segment: index + 1, boundary: "from"),
                                 to: timestamp(range.to, segment: index + 1, boundary: "to"))]
            }
        }
        let settings = ReencodeSettings(codec: options.video ?? .h264, quality: options.quality, audio: options.audio ?? .auto)
        let batch = try BulkExport(groups: groups, directory: directory, organization: options.organization, mode: mode, tracks: options.tracks ?? .all, audioStream: options.audioStream, container: input.container,
                                   snap: options.snap ?? .exact, settings: settings, media: cachedMedia, cancelled: { !interruption.isActive })
        if batch.items.contains(where: { $0.audio != nil }), options.video != nil || options.quality != nil {
            throw CLIError(ExportRules.soundSettingsRefusal.code, ExportRules.soundSettingsRefusal.message)
        }
        let result = runBatch(batch, indexedMedia: cachedMedia, dryRun: dryRun, interruption: interruption)
        try writeJSON(BulkResponse(ok: result.failure == nil, dryRun: dryRun, outputs: result.outputs,
                                   failedRange: result.failure?.range, error: result.failure?.issue),
                      checkCancellation: dryRun && result.failure == nil)
        if let failure = result.failure {
            exit(exitStatus(failure.issue.code, operation: true))
        }
    case let .exportProject(project, path, dryRun, flags):
        var loaded = try loadDocument(project, interruption: interruption)
        let output = try fileURL(path, label: "Output")
        try checkProjectOutput(output, media: loaded.media, location: loaded.location)
        if let spacing = flags.spaceClips {
            guard !loaded.project.requiresPictureProcessing else { throw ParticipantProjectExport.unsupported("Clip spacing export") }
            try checkSpacing(flags)
            let updated = try AnalysisSidecar.$excludedSources.withValue(loaded.excludedSidecarSources) {
                try spacedProject(loaded.project, using: spacing, relativeTo: loaded.location,
                                  engine: CutEngine(cancelled: { !interruption.isActive }, useSidecar: arguments.useSidecar))
            }
            loaded = LoadedProject(project: updated, media: loaded.media, location: loaded.location, file: loaded.file)
        }
        try await renderLoadedProject(loaded, output: output, flags: flags, dryRun: dryRun, arguments: arguments, interruption: interruption)
    case let .export(supplied, dryRun, flags, requestedOrder, resolveOpen):
        let input = try supplied ?? readInput(interruption, path: arguments.requestFile)
        var options = try flags.merging(input.options)
        if let operation = arguments.operation, ["export project render", "export clips join", "export soundtrack replace"].contains(operation) {
            let replacesSound = options.replaceAudio != nil || input.clips.contains { $0.soundtrack != nil }
            let required = input.project != nil ? "export project render" : (replacesSound ? "export soundtrack replace" : "export clips join")
            guard operation == required else { throw CLIError("invalid_arguments", "Use " + required + " for this request.") }
        }
        if let project = input.project {
            guard resolveOpen == nil, requestedOrder == nil, !isStandardInput(project) else {
                throw CLIError("invalid_arguments", "Use a saved project path in an export request, with no clip order.")
            }
            try await run(arguments.replacingCommand(.exportProject(project: project, output: input.output,
                                                                     dryRun: dryRun, options: options)),
                          interruption: interruption)
            return
        }
        guard options.stillTiming == nil, options.container == nil else {
            throw CLIError("invalid_arguments", "Specify still timing and container with a saved still project.")
        }
        guard !input.clips.isEmpty else {
            throw CLIError("invalid_arguments", "Export requires at least one clip.")
        }
        if resolveOpen != nil {
            guard options.mode == nil, options.snap == nil, options.tracks == nil, options.video == nil,
                  options.audio == nil, options.audioOutput == nil, options.quality == nil,
                  options.audioStream == nil, options.spaceClips == nil else {
                throw CLIError("invalid_arguments", "Resolve timeline export accepts edits and soundtrack replacements. Omit render settings.")
            }
            guard !input.clips.contains(where: { $0.project != nil }) else {
                throw CLIError("invalid_arguments", "Use project resolve export or project resolve import with --project for a saved multicam project.")
            }
        }
        let order = try input.resolvedOrder(requestedOrder)
        let selected = order ?? Array(1...input.clips.count)
        let spacing = options.spaceClips
        if spacing != nil {
            try checkSpacing(options)
            guard !selected.contains(where: { input.clips[$0 - 1].project != nil }) else {
                throw CLIError("invalid_arguments", "--space-clips accepts file clips or the saved project assembly using --project.")
            }
        }
        func replacementTarget(_ clip: InputClip, number: Int) throws -> URL? {
            guard clip.project == nil, let path = clip.file ?? input.file else { return nil }
            return try fileURL(path, label: "Clip \(number)").resolvingSymlinksInPath()
        }
        var selectedFiles: Set<URL>?
        if let order, options.replaceAudio != nil || input.clips.contains(where: { $0.soundtrack != nil }) {
            selectedFiles = Set(try order.compactMap { number in
                try replacementTarget(input.clips[number - 1], number: number)
            })
        }
        var soundtracks: [URL: SourceSoundtrack] = [:]
        for (index, clip) in input.clips.enumerated() {
            var binding = clip.soundtrack
            let globalFile = index == 0 ? options.replaceAudio : nil
            guard binding != nil || globalFile != nil else { continue }
            // A replacement also applies to other selected cuts of the same source.
            let source: URL?
            if let selectedFiles {
                source = try? replacementTarget(clip, number: index + 1)
                if source.map(selectedFiles.contains) != true {
                    if globalFile != nil && !selected.contains(1) {
                        options.replaceAudio = nil
                        options.replaceTrack = nil
                        options.replacementStream = nil
                    }
                    continue
                }
            } else {
                source = try replacementTarget(clip, number: index + 1)
            }
            guard let source else {
                if clip.project != nil { continue } // Project export diagnoses global replacement options.
                throw CLIError("invalid_json", "Clip \(index + 1) requires a file path or a top-level file for audio replacement.")
            }
            if let globalFile {
                let global = SourceSoundtrack(file: globalFile, target: options.replaceTrack, stream: options.replacementStream)
                guard binding == nil || binding == global else {
                    throw CLIError("invalid_arguments", "Conflicting replacement audio for the first source.")
                }
                binding = global
            }
            guard let binding else { continue }
            guard soundtracks[source] == nil || soundtracks[source] == binding else {
                throw CLIError("invalid_arguments", "Cuts from the same source must use the same replacement audio.")
            }
            soundtracks[source] = binding
        }
        if selected.contains(where: { input.clips[$0 - 1].project != nil }) {
            guard soundtracks.isEmpty else { throw CLIError("invalid_arguments", "Apply file soundtrack replacements before mixing multicam projects.") }
            try runMulticamExport(input: input, order: order, output: fileURL(input.output, label: "Output"),
                                  options: options, dryRun: dryRun, json: arguments.json, interruption: interruption)
            return
        }
        if spacing != nil, !soundtracks.isEmpty {
            throw CLIError("invalid_arguments", "--space-clips requires a source without replacement audio.")
        }
        // Without --mode an export uses the table's default, as the app's sheet does. The table writes it as
        // Lossless Copy for a source without picture, and a replaced soundtrack has the one mode of its entry point.
        let requestedMode = options.mode ?? (soundtracks.isEmpty ? ExportRules.defaultMode(for: ExportEntryPoint.cliExport.source)
                                                                 : ExportEntryPoint.replacement.modes[0])
        if spacing == nil { try validate(options, mode: requestedMode) }
        guard options.audioOutput == nil else {
            throw CLIError("invalid_arguments", "--audio-output applies to multicam projects.")
        }
        let output = try fileURL(input.output, label: "Output")
        var indexedMedia: [URL: MediaInfo] = [:]
        var rangeRequests: [Int: [ClipRequest]] = [:]
        func requests(for number: Int) throws -> [ClipRequest] {
            if let cached = rangeRequests[number] { return cached }
            let clip = input.clips[number - 1]
            guard let path = clip.file ?? input.file else {
                throw CLIError("invalid_json", "Clip \(number) requires a file path or a top-level file.")
            }
            let file = try fileURL(path, label: "Clip \(number)")
            let from = try timestamp(clip.from, segment: number, boundary: "from")
            let to = try timestamp(clip.to, segment: number, boundary: "to")
            guard let rangeList = clip.rangesFile else { return [ClipRequest(file: file, from: from, to: to)] }
            let rangeListURL = try fileURL(rangeList, label: "Range list")
            do {
                let media: MediaInfo
                if let cached = indexedMedia[file] {
                    media = cached
                } else {
                    media = try inspectRangeListSource(file, options: options, interruption: interruption)
                    indexedMedia[file] = media
                }
                let duration = try rangeListDuration(media, options: options)
                let scope = AudioSpan(from: from ?? .zero, to: to ?? duration)
                guard scope.from < scope.to, scope.to <= duration else {
                    throw CutError(code: "invalid_range", message: "Choose a nonempty range within the source.")
                }
                let ranges = try ListFile.ranges(rangeListURL, clip: scope, cancelled: { !interruption.isActive })
                let requests = ranges.map { ClipRequest(file: file, from: $0.from, to: $0.to) }
                rangeRequests[number] = requests
                return requests
            } catch let issue as CutError where issue.code != "cancelled" {
                throw CutError(code: issue.code, message: "Clip \(number) (\(rangeListURL.lastPathComponent)): \(issue.message)",
                               segment: number, boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
            }
        }
        var clips: [ClipRequest] = []
        var inputNumbers: [Int] = []
        var expandedPieceCount = 0
        for number in selected {
            try interruption.check()
            let expanded = try requests(for: number)
            if input.clips[number - 1].rangesFile != nil {
                expandedPieceCount += expanded.count
                guard expandedPieceCount <= ClipEditCSV.maximumPieces else {
                    throw CLIError("invalid_list", "Range lists and repetitions exceed the \(ClipEditCSV.maximumPieces)-piece export limit.")
                }
            }
            clips.append(contentsOf: expanded)
            inputNumbers.append(contentsOf: repeatElement(number, count: expanded.count))
        }
        try interruption.check()
        if let spacing {
            let engine = CutEngine(cancelled: { !interruption.isActive }, useSidecar: arguments.useSidecar)
            try engine.checkDestination(output)
            let project = try clipSequence(clips, media: indexedMedia, engine: engine)
            let location = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Untitled.cut")
            let updated = try spacedProject(project, using: spacing, relativeTo: location, engine: engine)
            if try updated.exportPlacementScope() != .none {
                try runStillExport(updated, location: location, output: output, dryRun: dryRun, options: options,
                                   json: arguments.json, useSidecar: arguments.useSidecar, interruption: interruption)
                return
            }
            try validate(options, mode: requestedMode)
        }
        let progress = ExportProgress(interruption: interruption)
        var staging: URL?
        var sourceFiles: [URL] = []
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        if !soundtracks.isEmpty {
            guard requestedMode == .copy, (options.tracks ?? .all) == .all else {
                throw CLIError("invalid_arguments", "Replacement audio requires copy mode with all source tracks.")
            }
            let inspector = CutEngine(cancelled: { !interruption.isActive }, useSidecar: arguments.useSidecar)
            try inspector.checkDestination(output)
            let engine = AudioReplacementEngine(cancelled: { !interruption.isActive }, useSidecar: arguments.useSidecar)
            var prepared: [URL: URL] = [:]
            let clipSources = clips.map { $0.file.resolvingSymlinksInPath() }
            for (clip, source) in zip(clips, clipSources) {
                guard let binding = soundtracks[source], prepared[source] == nil else { continue }
                let donor = try fileURL(binding.file, label: "Replacement audio")
                var inspectedWholeSource: MediaInfo?
                let fullSource: Bool
                if resolveOpen == nil, clips.count == 1, (clip.from ?? .zero) == .zero {
                    if let end = clip.to {
                        let media = try inspector.inspect(clip.file)
                        fullSource = end == media.duration
                        if fullSource { inspectedWholeSource = media }
                    } else {
                        fullSource = true
                    }
                } else {
                    fullSource = false
                }
                let plan: AudioReplacementPlan
                if let inspectedWholeSource {
                    plan = try engine.resolve(source: inspectedWholeSource, replacement: donor, output: output,
                                              targetStream: binding.target, replacementStream: binding.stream)
                } else {
                    plan = try engine.resolve(source: fullSource ? clip.file : source, replacement: donor,
                                              output: fullSource ? output : nil,
                                              targetStream: binding.target, replacementStream: binding.stream)
                }
                if fullSource {
                    if !dryRun { try engine.export(plan, to: output) { progress.report($0) } }
                    if arguments.json || dryRun {
                        let number = inputNumbers[0]
                        let cutMap = ExportCutMap(wholeSource: clip, duration: plan.duration,
                                                  id: input.clips[number - 1].occurrenceID, inputNumber: number)
                        try writeJSON(ReplacementResult(dryRun: dryRun, output: output.path, duration: plan.duration,
                                                      copiedDuration: plan.duration, container: plan.container, replacement: plan,
                                                      cutMap: cutMap),
                                      pretty: !arguments.json, checkCancellation: dryRun)
                    } else {
                        try interruption.beginResponse(checkCancellation: false)
                        try writeOutput("Exported \(output.path)")
                    }
                    return
                }
                if staging == nil {
                    let folder = resolveOpen == nil
                        ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        : output.deletingLastPathComponent().appendingPathComponent("\(output.deletingPathExtension().lastPathComponent) Sources \(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    staging = folder
                }
                let stem = resolveOpen == nil ? UUID().uuidString
                    : "\(prepared.count + 1) \(source.deletingPathExtension().lastPathComponent) - replaced audio"
                let working = staging!.appendingPathComponent(stem).appendingPathExtension(plan.container)
                try engine.export(plan, to: working)
                prepared[source] = working
            }
            sourceFiles = clips.map(\.file)
            clips = zip(clips, clipSources).map { clip, source in
                ClipRequest(file: prepared[source] ?? clip.file, from: clip.from, to: clip.to)
            }
        }
        if let resolveOpen {
            let warnings = try ResolveExport.write(clips, to: output, useSidecar: arguments.useSidecar,
                                                   cancelled: { !interruption.isActive })
            staging = nil  // The XML references these working copies for the lifetime of the timeline.
            try finishResolveExport(output, open: resolveOpen, json: arguments.json, interruption: interruption, warnings: warnings)
            return
        }
        var result: ExportResult
        // Every export resolves through the shared rules, as the app's export sheet does.
        let planner = ExportPlanner(cancelled: { !interruption.isActive }, useSidecar: arguments.useSidecar)
        let named = output.pathExtension.lowercased()
        let request = ExportRequest(clips: clips, mode: requestedMode, tracks: options.tracks ?? .all,
                                    audioStream: options.audioStream, container: named.isEmpty ? nil : named,
                                    audio: options.audio ?? .auto, codec: options.video ?? ExportRules.defaultCodec,
                                    quality: options.quality, snap: options.snap ?? .exact,
                                    movieSettings: options.video != nil || options.quality != nil)
        switch planner.resolve(request, output: output, media: indexedMedia) {
        case .ready(let plan, _, let applied):
            result = try ExportResult(dryRun: dryRun, output: output.path, plan: plan, requested: request, applied: applied, order: order)
            result.copyOmissions = plan.copyOmissions
            if options.requireCameraCopy == true, result.encodedDuration > .zero,
               result.edit.tracks != .audio,
               result.edit.segments.contains(where: { $0.tracks.contains(where: { $0.kind == "video" }) }) {
                throw CutError(code: "camera_copy_required", message: "The selected export would encode camera picture.")
            }
            // A dry run also says how good the clips are on their own, whatever mode was asked for. The export it plans
            // reports the same fields, so its JSON carries the tier too. Plain text output does not pay for the check.
            if dryRun || arguments.json {
                let originalClips = clips.enumerated().map { index, clip in
                    ClipRequest(file: sourceFiles.indices.contains(index) ? sourceFiles[index] : clip.file,
                                from: clip.from, to: clip.to)
                }
                result.cutMap = try ExportCutMap(edit: plan.edit, clips: originalClips,
                                                 ids: inputNumbers.map { input.clips[$0 - 1].occurrenceID },
                                                 inputNumbers: inputNumbers)
                result.tier = TimelineTierEvaluator(useSidecar: arguments.useSidecar)
                    .summary(clips, media: indexedMedia, replacementSources: sourceFiles, cancelled: { !interruption.isActive })
            }
            try interruption.check()
            if !dryRun {
                try planner.write(plan, to: output) { progress.report($0) }
            }
        case .unavailable(let error, let offers):
            // The engine numbers clips by playback position. Report the caller's clip number,
            // as timestamp errors do, so `nearest` applies to the right entry under `order`.
            var failure = error
            if let position = error.segment, position > 0, position <= inputNumbers.count {
                failure = CutError(code: error.code, message: error.message, segment: inputNumbers[position - 1],
                                   boundary: error.boundary, nearest: error.nearest, track: error.track)
            }
            // Replacement stays bound to the caller's original source paths and requires copy mode.
            let alternatives = offers.compactMap { offer -> ExportAlternative? in
                if options.requireCameraCopy == true, offer.alternative.tracks != .audio,
                   offer.alternative.mode != .copy { return nil }
                if sourceFiles.isEmpty { return offer.alternative }
                guard offer.alternative.mode == .copy else { return nil }
                guard offer.alternative.clips != nil else { return offer.alternative }
                return offer.alternative.listing(zip(offer.request.clips, sourceFiles).map { clip, file in
                    ClipRequest(file: file, from: clip.from, to: clip.to)
                })
            }
            if !alternatives.isEmpty { failure.alternatives = alternatives }
            // Programs read which tier factor stopped the request.
            failure.reason = error.factor
            // People are told which clip and where, in the wording of the app's export sheet, and the tier of their clips.
            let tier = arguments.json ? "" : "\nTimeline tier: " + TimelineTierEvaluator(useSidecar: arguments.useSidecar)
                .summary(clips, media: indexedMedia, cancelled: { !interruption.isActive }).name
            let reportedClips = sourceFiles.isEmpty ? clips : zip(clips, sourceFiles).map { clip, file in
                ClipRequest(file: file, from: clip.from, to: clip.to)
            }
            FailureContext.shared.text = ExportRules.describe(error, clips: reportedClips, numbered: failure.segment) + tier
            throw failure
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
            if let applied = result.applied { errorOutput("mpcut: \(applied.label)") }
            for warning in (result.conversion?.warnings ?? result.audioExport?.warnings ?? result.applied?.warnings ?? [])
                + result.copyOmissions {
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
        let origin: HistoryOrigin = ProcessInfo.processInfo.environment["MPCUT_HISTORY_ORIGIN"] == "agent" ? .agent : .user
        try await HistoryOrigin.$current.withValue(origin) {
            try await run(arguments, interruption: interruption)
        }
    }
} catch let error as CutError {
    // People read the wording and the labels the app shows, with the flags that request each alternative. JSON keeps the raw message.
    let text = FailureContext.shared.text ?? ExportRules.describe(error, clips: [])
    reportFailure(error, message: text + ExportRules.describe(alternatives: error.alternatives ?? []), json: json)
    exit(exitStatus(error.code, operation: true))
} catch let error as CLIError {
    reportFailure(error, message: error.message, json: json)
    exit(exitStatus(error.code, operation: false))
} catch let error as OutputError {
    reportOutputFailure(error)
    exit(1)
} catch is CancellationError {
    let failure = CutError(code: "cancelled", message: "Operation cancelled.")
    reportFailure(failure, message: failure.message, json: json)
    exit(130)
} catch {
    let failure = CLIError("operation_failed", error.localizedDescription)
    reportFailure(failure, message: failure.message, json: json)
    exit(1)
}
