import Foundation

struct StillPicturePlan {
    let pictures: [StillExportPicture]
    let identities: [URL: SourceIdentity]
    let colorPolicy: StillProgramColorPolicy
    let warnings: [String]
    let hdrMetadata: StillHDRMetadata?
}

extension StillExportPlanner {
    private struct CameraSpan {
        let file: URL
        let source: String
        let input: MulticamRange
        var coalescedSources: [String] = []

        var sourceOccurrences: [String] { coalescedSources.isEmpty ? [source] : coalescedSources }
    }

    private struct PictureWindow {
        let output: MulticamRange
        let clock: String
        let placementID: String?
        let camera: CameraSpan?
        let authoredClockRange: MulticamRange?
        var recordingGap = false
        var heldSources: [String] = []
        var heldEnd: RationalTime?
        var heldEndSource: String?
    }

    func planPicture(_ project: CutProject, document: URL, timeline: StillTimelinePlan, mode: ExportMode,
                     requireCameraCopy: Bool, container: String, settings: ReencodeSettings,
                     tracks: ExportTracks, pictureTiming: StillPictureTiming = .cadence,
                     format: StillTimelineFormat? = nil, videoCodec: ReencodeCodec? = nil) throws -> StillPicturePlan {
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: .video)
        let authored = try pictureWindows(project, document: document, timeline: timeline)
        let held = pictureTiming == .held
        let windows = held ? coalesceHeldWindows(authored) : authored
        let matroska = held && container == "mkv"
        let written = try windows.enumerated().map { index, window -> MulticamRange in
            guard matroska else { return window.output }
            let from = try StillSampleSchedule.matroskaBoundary(window.output.from, final: false)
            let to = try StillSampleSchedule.matroskaBoundary(window.output.to, final: index == windows.count - 1)
            guard to > from else {
                throw CutError(code: "unsupported_still_timing",
                               message: "The hold at \(window.output.from) would collapse on the MKV clock. Use MOV, MP4, or M4V.")
            }
            if mode != .encode, window.placementID == nil, !window.recordingGap,
               from != window.output.from || to != window.output.to {
                throw CutError(code: "unsupported_still_timing",
                               message: "The MKV clock would shift a camera boundary. Use MOV, MP4, or M4V.")
            }
            return .init(from: from, to: to)
        }
        let stagingContainer = matroska ? "mov" : ExportRules.multicamMuxContainer(container)
        let isMulticam: Bool
        if case .multicam = project { isMulticam = true } else { isMulticam = false }
        var indexed: [URL: MediaInfo] = [:]
        var identities: [URL: SourceIdentity] = [:]
        var sourceExtents: [String: MulticamRange] = [:]
        var reference: StreamInfo?
        var cameraReference: MediaInfo?
        for window in authored {
            guard let camera = window.camera else { continue }
            if indexed[camera.file] == nil {
                let original = try isMulticam ? engine.inspectMulticamSource(camera.file) : engine.inspect(camera.file, keyframes: true)
                if tracks == .all, let extra = original.streams.first(where: {
                    $0.kind != "audio" && $0.index != original.videoStream?.index
                }) {
                    throw CutError(code: "unsupported_still_ancillary_track",
                                   message: "Still-bearing export cannot preserve stream \(extra.index) (\(extra.codecTag)) from \(camera.file.lastPathComponent). Select video only or audio only to omit ancillary tracks.",
                                   track: extra.index)
                }
                let media = try MulticamEngine(cancelled: cancelled).isolatedPicture(original, using: engine)
                indexed[camera.file] = media
                let snapshot = try SourceIdentity(camera.file)
                guard media.identity.matchesSnapshot(snapshot) else {
                    throw CutError(code: "source_changed", message: "Camera source \(camera.file.lastPathComponent) changed during export planning.")
                }
                identities[camera.file] = snapshot
            }
            let media = indexed[camera.file]!
            if window.clock == "sequence" {
                for occurrence in camera.sourceOccurrences {
                    sourceExtents[occurrence] = .init(from: .zero, to: media.duration)
                }
            }
            if reference == nil { reference = media.video }
        }
        try project.validateStillSourceExtents(sourceExtents)

        let cameraSpans = windows.filter { $0.placementID == nil }.compactMap(\.camera)
        let retained = Dictionary(grouping: cameraSpans, by: \.file)
        let hdr = try planHDR(retained.mapValues { $0.map(\.input) }, media: indexed, preservingCamera: mode != .encode)
        if mode != .encode {
            var checked: Set<URL> = []
            let muxContainer = ExportRules.multicamMuxContainer(container)
            for camera in cameraSpans where checked.insert(camera.file).inserted {
                let media = indexed[camera.file]!
                if let videoCodec, media.video.codec != (videoCodec == .jpeg ? "mjpeg" : videoCodec.rawValue) {
                    throw CutError(code: "camera_copy_required",
                                   message: "Smart Trim retains the selected camera codec. Use Re-encode to change the picture codec.")
                }
                if let issue = media.copyIssue {
                    throw CutError(code: "unsupported_tracks", message: issue)
                }
                if let cameraReference {
                    try engine.checkPictureCompatibility(media, with: cameraReference, omittingContentLight: true)
                }
                if let issue = engine.muxIssue(media, container: muxContainer) {
                    throw CutError(code: "unsupported_container", message: issue)
                }
                if cameraReference == nil { cameraReference = media }
            }
        }
        if let cameraReference { reference = cameraReference.video }
        let effectiveFormat = format ?? project.stillFormat
        let exactStandaloneClock = held || project.stillSoundtrack != nil
        if reference == nil, let format = effectiveFormat {
            let pictureClock = exactStandaloneClock ? try StillSampleSchedule.pictureClock(
                [format.cadence.denominator] + written.flatMap { [$0.from.denominator, $0.to.denominator] }) : nil
            reference = try format.targetStream(color: project.programColorPolicy ?? StillTimelineFormat.sdrColorPolicy,
                                                duration: timeline.duration, pictureClock: pictureClock)
        }
        if reference == nil, case .multicam(let multicam) = project,
           let angle = multicam.angles.first(where: { $0.id == multicam.referenceAngle }) {
            let file = try CutProject.checkedMediaURL(angle.file, relativeTo: document)
            let media = try engine.inspect(file, keyframes: true)
            guard let video = media.videoStream else {
                throw CutError(code: "missing_still_format", message: "The multicam reference angle has no video format.")
            }
            reference = video
            indexed[file] = media
            identities[file] = media.identity
        }
        guard var reference else {
            throw CutError(code: "missing_still_format", message: "Select a video timeline or define the picture format for this project.")
        }

        var policy = try project.programColorPolicy ?? StillProgramColorPolicy.resolving(source: reference)
        if mode != .encode, effectiveFormat == nil, cameraSpans.isEmpty, let videoCodec {
            let rate = reference.frameRate
            let cadence = rate > .zero ? RationalTime(numerator: rate.denominator, denominator: rate.numerator) :
                RationalTime(numerator: 1, denominator: 30)
            let target = StillTimelineFormat(width: reference.displayWidth, height: reference.displayHeight,
                                             cadence: cadence, codec: videoCodec, container: container)
            let scale = held ? try StillSampleSchedule.pictureClock(
                [cadence.denominator] + written.flatMap { [$0.from.denominator, $0.to.denominator] }) : nil
            reference = try target.targetStream(color: policy, duration: timeline.duration, pictureClock: scale)
        }
        if mode != .encode && (!cameraSpans.isEmpty || (effectiveFormat == nil && videoCodec == nil)) && windows.contains(where: { $0.placementID != nil }) {
            try policy.validateSourceCompatibility(reference)
        }
        if mode == .encode ? settings.codec == .jpeg : reference.codec == "mjpeg" {
            policy.range = "pc"
        }
        if mode == .encode {
            guard ["tv", "pc"].contains(policy.range),
                  ["bt709", "smpte170m", "bt470bg", "bt2020nc", "smpte240m", "fcc"].contains(policy.matrix) else {
                throw CutError(code: "unsupported_still_color", message: "The selected picture encoder needs a supported YUV matrix and range.")
            }
            for file in retained.keys.sorted(by: { $0.path < $1.path }) {
                guard let video = indexed[file]?.video else { continue }
                let untagged = ["", "unknown", "unspecified", "reserved"]
                let compatible = [(video.colorTransfer, policy.transfer), (video.colorPrimaries, policy.primaries)].allSatisfy { actual, target in
                    actual == target || untagged.contains(actual)
                }
                guard compatible, video.colorMatrix != "bt2020c" else {
                    throw CutError(code: "unsupported_still_color",
                                   message: "This conversion cannot map the camera color of \(file.lastPathComponent) to the selected program color policy.")
                }
            }
        }

        if hdr.contains(where: { $0.mastering != nil }), policy.transfer != "smpte2084" {
            throw CutError(code: "unsupported_hdr_mastering",
                           message: "The output must use PQ to retain the camera mastering-display metadata.")
        }

        let generator = StillVideoGenerator(cancelled: cancelled, colorPolicy: policy, standalone: indexed.isEmpty || (cameraSpans.isEmpty && videoCodec != nil))
        let assets = Dictionary(uniqueKeysWithValues: project.stillAssets.map { ($0.id, $0) })
        let inserts = Dictionary(uniqueKeysWithValues: project.stillInserts.map { ($0.id, $0) })
        let replacements = Dictionary(uniqueKeysWithValues: project.stillReplacements.map { ($0.id, $0) })
        var opened: [String: URL] = [:]
        func assetFile(_ asset: StillAsset, placementID: String) throws -> URL {
            if let cached = opened[asset.id] { return cached }
            let file = try openAsset(asset, placementID: placementID, document: document, engine: engine, identities: &identities)
            opened[asset.id] = file
            return file
        }
        var pictures: [StillExportPicture] = []
        var allConversionInputs: [ClipRequest] = []
        let timescale = mode != .encode ? Int(exactly: reference.timeBase.denominator) : nil

        var variableTimeline: Bool?
        func allowsShortFinalSample() throws -> Bool {
            guard ["mov", "mp4", "m4v"].contains(container) else { return false }
            if project.stillSoundtrack != nil && effectiveFormat != nil { return true }
            if let variableTimeline { return variableTimeline }
            let cadence = indexed.values.lazy.compactMap { $0.frames.first?.duration }.first
            for media in indexed.values {
                for (index, frame) in media.frames.enumerated() {
                    if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
                    if frame.duration != cadence {
                        variableTimeline = true
                        return true
                    }
                }
            }
            variableTimeline = false
            return false
        }

        for (index, window) in windows.enumerated() {
            try engine.checkCancellation()
            let renderOutput = written[index]
            let camera = window.camera
            let media = camera.flatMap { indexed[$0.file] }
            let frames: Range<Int>?
            if let camera, let media, !held || window.placementID == nil {
                frames = try frameRange(media, input: camera.input, segment: index + 1, placementID: window.placementID)
                if window.placementID == nil {
                    allConversionInputs.append(ClipRequest(file: media.url, from: camera.input.from, to: camera.input.to))
                }
            } else {
                frames = nil
            }
            let content: StillExportPicture.Content
            if window.recordingGap && (!held || window.placementID == nil) {
                guard mode == .encode else {
                    throw CutError(code: "recording_gap_requires_encoding",
                                   message: "The selected camera has a recording gap at output \(window.output.from)–\(window.output.to). Re-encode to fill it with black.")
                        .because(.placementPicture)
                }
                let rate = reference.frameRate
                let cadence = rate > .zero ? RationalTime(numerator: rate.denominator, denominator: rate.numerator) :
                    RationalTime(numerator: 1, denominator: 30)
                let duration = try renderOutput.to.subtracting(renderOutput.from)
                let schedule = try held && window.placementID != nil ? StillSampleSchedule(hold: duration, cadence: cadence) :
                    StillSampleSchedule(duration: duration, cadence: cadence, allowShortFinalSample: true)
                let file: URL
                let framing: StillImageFraming
                if let id = window.placementID, let replacement = replacements[id], let asset = assets[replacement.assetID] {
                    file = try assetFile(asset, placementID: id)
                    framing = replacement.framing
                } else {
                    file = StillAsset.gapImage
                    if identities[file] == nil { identities[file] = try SourceIdentity(file) }
                    framing = .fit
                }
                try generator.checkLossless(reference: reference, schedule: schedule)
                content = .still(file: file, framing: framing, reference: reference, schedule: schedule)
            } else if let id = window.placementID {
                let assetID: String
                let framing: StillImageFraming
                let duration = try renderOutput.to.subtracting(renderOutput.from)
                let schedule: StillSampleSchedule
                if let insert = inserts[id] {
                    assetID = insert.assetID
                    framing = insert.framing
                    schedule = try held ? .init(hold: duration, cadence: insert.cadence) :
                        .init(duration: duration, cadence: insert.cadence, allowShortFinalSample: try allowsShortFinalSample())
                } else if let replacement = replacements[id] {
                    assetID = replacement.assetID
                    framing = replacement.framing
                    if held {
                        let rate = reference.frameRate
                        let cadence = rate > .zero ? RationalTime(numerator: rate.denominator, denominator: rate.numerator) :
                            RationalTime(numerator: 1, denominator: 30)
                        schedule = try .init(hold: duration, cadence: max(cadence, .init(numerator: 1, denominator: 240)))
                    } else if let media, let frames {
                        schedule = try .init(frames: media.frames[frames], duration: duration, cancelled: cancelled)
                    } else {
                        throw CutError(code: "invalid_still_placement", message: "Still placement \(id) has no source schedule.")
                    }
                } else {
                    throw CutError(code: "invalid_still_placement", message: "Still placement \(id) has no source schedule.")
                }
                guard let asset = assets[assetID] else {
                    throw CutError(code: "missing_still_asset", message: "Still placement \(id) references missing asset \(assetID).")
                }
                let file = try assetFile(asset, placementID: id)
                if mode == .encode {
                    try generator.checkLossless(reference: reference, schedule: schedule)
                } else {
                    try generator.check(reference: reference, container: stagingContainer, schedule: schedule)
                }
                content = .still(file: file, framing: framing, reference: reference, schedule: schedule)
            } else if let camera, let media, let frames {
                if mode == .encode && requireCameraCopy {
                    throw CutError(code: "camera_copy_required", message: "Full conversion encodes retained camera picture.")
                }
                let edges = try cameraEdges(media, input: camera.input, frames: frames, index: index, windows: windows,
                                            mode: mode, requireCameraCopy: requireCameraCopy,
                                            container: stagingContainer, engine: engine)
                if matroska && mode == .encode {
                    let shift = try window.output.from.subtracting(camera.input.from)
                    var previous = renderOutput.from
                    for frame in frames.dropFirst() {
                        if frame.isMultiple(of: 1_024) { try engine.checkCancellation() }
                        let next = try StillSampleSchedule.matroskaBoundary(media.frames[frame].time.adding(shift), final: false)
                        guard next > previous, next < renderOutput.to else { throw StillSampleSchedule.unsupported }
                        previous = next
                    }
                }
                content = .camera(media: media, input: camera.input, frames: frames, edges: edges)
            } else {
                throw CutError(code: "uncovered_picture", message: "There is no picture at output \(window.output.from).")
            }
            if let timescale {
                let clock = Int64(timescale)
                let exact: Bool
                if window.placementID == nil, let media, let frames {
                    exact = media.frames[frames].allSatisfy {
                        clock % $0.time.denominator == 0 && clock % $0.duration.denominator == 0 &&
                            $0.dts.map { clock % $0.denominator == 0 } == true
                    }
                } else {
                    exact = true
                }
                guard timescale > 0, timescale <= Int32.max, exact, clock % renderOutput.from.denominator == 0,
                      clock % renderOutput.to.denominator == 0 else {
                    throw CutError(code: "unsupported_still_timing",
                                   message: "The selected MOV-family video clock cannot represent the picture at output \(window.output.from).")
                }
            }
            pictures.append(.init(output: window.output, clock: window.clock, source: camera?.source,
                                  sourceOccurrences: window.heldSources.isEmpty ? camera?.sourceOccurrences ?? [] : window.heldSources,
                                  placementID: window.placementID, content: content,
                                  writtenOutput: renderOutput == window.output ? nil : renderOutput))
        }

        var warnings: [String] = []
        if hdr.contains(where: { $0.hasContentLight || $0.hasInBandContentLight }) {
            warnings.append("Content-light statistics will be omitted because the still-bearing program has different content.")
        }
        if matroska {
            let helper = try ReencodeEngine.findHelper(override: nil)
            try StillMatroska.verifyHelper(helper, cancelled: cancelled)
        }
        if mode == .encode {
            let sourceClocks: [Int64] = try pictures.map {
                switch $0.content {
                case .camera(let media, _, _, _): return media.video.timeBase.denominator
                case .still(_, _, _, let schedule): return try schedule.exactTimescale()
                }
            }
            let clock = Int64(try matroska ? StillMatroska.pictureConversionClock(pictures, cancelled: cancelled) :
                conversionTimeScale(for: sourceClocks))
            for (picture, sourceClock) in zip(pictures, sourceClocks) {
                guard clock.isMultiple(of: picture.renderOutput.from.denominator),
                      clock.isMultiple(of: picture.renderOutput.to.denominator) else { throw StillSampleSchedule.unsupported }
                if matroska { continue }
                if clock.isMultiple(of: sourceClock) { continue }
                guard case .camera(let media, _, let frames, _) = picture.content else {
                    throw StillSampleSchedule.unsupported
                }
                // A finer source clock is safe when every retained frame duration
                // still falls exactly on the output clock.
                for index in frames {
                    if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
                    guard clock.isMultiple(of: media.frames[index].duration.denominator) else {
                        throw StillSampleSchedule.unsupported
                    }
                }
            }
            let videoSettings = ReencodeSettings(codec: settings.codec, quality: settings.quality, audio: .removeAudio)
            let conversionContainer = stagingContainer
            guard ExportRules.reencodeContainers(videoSettings.codec).contains(conversionContainer) else {
                throw ExportRules.reencodeContainerRefusal
            }
            if !allConversionInputs.isEmpty {
                let conversion = try ReencodeEngine(cancelled: cancelled).resolve(allConversionInputs, media: indexed,
                                                                                  container: conversionContainer, settings: videoSettings)
                warnings += conversion.warnings
            }
            let encoding = try ReencodeVideo(reference, settings: videoSettings, stillColor: policy)
            let helper = try ReencodeEngine.findHelper(override: nil)
            try ReencodeEngine(cancelled: cancelled).verifyHardware(helper, encoding: encoding, container: conversionContainer,
                                                                    actions: [], audio: [], exactPCM: [])
        }
        return StillPicturePlan(pictures: pictures, identities: identities, colorPolicy: policy, warnings: warnings, hdrMetadata: hdr.first { $0.mastering != nil })
    }

    private func pictureWindows(_ project: CutProject, document: URL, timeline: StillTimelinePlan) throws -> [PictureWindow] {
        let clips = Dictionary(uniqueKeysWithValues: (project.sequenceClips ?? []).map { ($0.id, $0) })
        let multicam: MulticamProject?
        if case .multicam(let program) = project { multicam = program } else { multicam = nil }
        let program = try multicam?.plan()
        let programPicture = program?.picture ?? []
        let gaps = program?.recordingGaps ?? []
        let recordings = Dictionary(uniqueKeysWithValues: (multicam?.pictureSources ?? []).map {
            ($0.id, $0.file)
        })
        var anglePaths: [String: URL] = [:]
        func anglePath(_ id: String) throws -> URL? {
            if let known = anglePaths[id] { return known }
            guard let path = recordings[id] else { return nil }
            let file = try CutProject.checkedMediaURL(path, relativeTo: document)
            anglePaths[id] = file
            return file
        }
        var windows: [PictureWindow] = []
        var cameraIndex = 0
        for span in timeline.spans {
            switch span.origin {
            case .insert:
                windows.append(.init(output: span.output, clock: multicam == nil ? "sequence" : "assembly",
                                     placementID: span.placementID, camera: nil, authoredClockRange: nil))
            case .source(let clipID, let range):
                guard let clip = clips[clipID] else {
                    throw CutError(code: "invalid_cut_project", message: "Unknown source occurrence \(clipID).")
                }
                let file = try CutProject.checkedMediaURL(clip.file, relativeTo: document)
                let camera = CameraSpan(file: file, source: clipID, input: range)
                windows.append(.init(output: span.output, clock: "sequence", placementID: span.placementID,
                                     camera: camera, authoredClockRange: range))
            case .group(_, let group):
                if let placementID = span.placementID,
                   let referenceID = replacementReferenceAngles[placementID] ?? multicam?.referenceAngle,
                   let reference = multicam?.pictureSource(for: referenceID, at: group.from),
                   reference.coverage.map({ group.to <= $0.to }) ?? true,
                   let file = try anglePath(reference.id) {
                    let input = MulticamRange(from: try group.from.subtracting(reference.offset),
                                              to: try group.to.subtracting(reference.offset))
                    windows.append(.init(output: span.output, clock: "group", placementID: placementID,
                                         camera: CameraSpan(file: file, source: reference.id, input: input),
                                         authoredClockRange: group))
                    continue
                }
                while cameraIndex < programPicture.count && programPicture[cameraIndex].output.to <= span.output.from {
                    cameraIndex += 1
                }
                var cursor = span.output.from
                while cursor < span.output.to {
                    let gapIndex = gaps.lowerBound { $0.to > cursor }
                    if gaps.indices.contains(gapIndex), gaps[gapIndex].contains(cursor) {
                        let upper = min(span.output.to, gaps[gapIndex].to)
                        let output = MulticamRange(from: cursor, to: upper)
                        let offset = try group.from.subtracting(span.output.from)
                        let authored = MulticamRange(from: try cursor.adding(offset), to: try upper.adding(offset))
                        windows.append(.init(output: output, clock: span.placementID == nil ? "assembly" : "group", placementID: span.placementID,
                                             camera: nil, authoredClockRange: authored, recordingGap: true))
                        cursor = upper
                        continue
                    }
                    guard cameraIndex < programPicture.count else { throw uncovered(cursor) }
                    let camera = programPicture[cameraIndex]
                    let upper = min(camera.output.to, span.output.to)
                    guard camera.output.from <= cursor, upper > cursor,
                          let file = try anglePath(camera.source) else { throw uncovered(cursor) }
                    let offset = try camera.input.from.subtracting(camera.output.from)
                    let output = MulticamRange(from: cursor, to: upper)
                    let input = MulticamRange(from: try cursor.adding(offset), to: try upper.adding(offset))
                    let origin = try group.from.subtracting(span.output.from)
                    let authored = MulticamRange(from: try cursor.adding(origin), to: try upper.adding(origin))
                    windows.append(.init(output: output, clock: span.placementID == nil ? "assembly" : "group",
                                         placementID: span.placementID,
                                         camera: CameraSpan(file: file, source: camera.source, input: input),
                                         authoredClockRange: authored))
                    cursor = upper
                    if cursor == camera.output.to { cameraIndex += 1 }
                }
            }
        }
        return coalesceCameraWindows(windows)
    }

    private func coalesceHeldWindows(_ windows: [PictureWindow]) -> [PictureWindow] {
        var result: [PictureWindow] = []
        for next in windows {
            guard let last = result.last, let placement = next.placementID,
                  last.placementID == placement, last.output.to == next.output.from, last.clock == next.clock,
                  last.clock == "sequence" || (last.heldEnd ?? last.authoredClockRange?.to) == next.authoredClockRange?.from else {
                result.append(next)
                continue
            }
            var sources = last.heldSources.isEmpty ? last.camera?.sourceOccurrences ?? [] : last.heldSources
            for source in next.camera?.sourceOccurrences ?? [] where sources.last != source {
                sources.append(source)
            }
            result[result.count - 1] = .init(output: .init(from: last.output.from, to: next.output.to), clock: last.clock,
                                             placementID: placement, camera: last.camera ?? next.camera,
                                             authoredClockRange: last.authoredClockRange,
                                             recordingGap: last.recordingGap && next.recordingGap, heldSources: sources,
                                             heldEnd: next.authoredClockRange?.to, heldEndSource: next.camera?.source)
        }
        return result
    }

    private func coalesceCameraWindows(_ windows: [PictureWindow]) -> [PictureWindow] {
        var result: [PictureWindow] = []
        var index = 0
        while index < windows.count {
            let first = windows[index]
            index += 1
            guard first.placementID == nil, let camera = first.camera else {
                result.append(first)
                continue
            }
            var outputEnd = first.output.to
            var inputEnd = camera.input.to
            var occurrences = [camera.source]
            while index < windows.count {
                let candidate = windows[index]
                guard candidate.placementID == nil, candidate.output.from == outputEnd,
                      let next = candidate.camera, next.file == camera.file, next.input.from == inputEnd else { break }
                inputEnd = next.input.to
                outputEnd = candidate.output.to
                if occurrences.last != next.source { occurrences.append(next.source) }
                index += 1
            }
            let span = CameraSpan(file: camera.file, source: camera.source, input: .init(from: camera.input.from, to: inputEnd),
                                  coalescedSources: occurrences)
            result.append(PictureWindow(output: .init(from: first.output.from, to: outputEnd), clock: first.clock,
                                        placementID: nil, camera: span, authoredClockRange: nil))
        }
        return result
    }

    private func uncovered(_ at: RationalTime) -> CutError {
        CutError(code: "uncovered_picture", message: "There is no camera picture at output \(at).")
    }

    private func frameRange(_ media: MediaInfo, input: MulticamRange, segment: Int,
                            placementID: String?) throws -> Range<Int> {
        let frames = media.frames
        let lower = frames.lowerBound { $0.time >= input.from }
        let upper = frames.lowerBound { $0.time >= input.to }
        guard input.from >= .zero, input.to <= media.duration, lower < upper,
              frames[lower].time == input.from, input.to == media.duration || (upper < frames.count && frames[upper].time == input.to)
        else {
            let whereText = placementID.map { "Still placement \($0)" } ?? "Camera span \(segment)"
            let start = lower == frames.count || frames[lower].time != input.from
            let time = start ? input.from : input.to
            throw CutError(code: "unsafe_boundary",
                           message: "\(whereText) needs exact picture presentation boundaries at \(time).",
                           segment: segment, boundary: start ? "from" : "to",
                           placementIDs: placementID.map { [$0] }).because(.cutOffFrame)
        }
        var cursor = input.from
        for index in lower..<upper {
            if index.isMultiple(of: 1_024) { try CutEngine(cancelled: cancelled).checkCancellation() }
            let frame = frames[index]
            guard frame.time == cursor else { throw uncovered(cursor) }
            cursor = try cursor.adding(frame.duration)
        }
        guard cursor == input.to else { throw uncovered(cursor) }
        return lower..<upper
    }

    private func cameraEdges(_ media: MediaInfo, input: MulticamRange, frames: Range<Int>, index: Int,
                             windows: [PictureWindow], mode: ExportMode, requireCameraCopy: Bool, container: String,
                             engine: CutEngine) throws -> [EncodedEdge] {
        if mode == .encode {
            return [.init(from: input.from, to: input.to, frameCount: frames.count)]
        }
        let startSafe = input.from == .zero ? media.sourceStartSafe : media.frames[frames.lowerBound].canStart
        let endSafe = input.to == media.duration || (frames.upperBound < media.frames.count && media.frames[frames.upperBound].canEnd)
        if startSafe && endSafe { return [] }
        if startSafe || input.from != .zero,
           mode == .smart, !requireCameraCopy, engine.smartTrimEligible(in: media, container: container) {
            return try smartTrimEdges(frames: media.frames, kept: frames, from: input.from, to: input.to,
                                      sourceEnd: media.duration, codec: media.video.codec, segment: index + 1)
        }

        let start = !startSafe
        let at = start ? input.from : input.to
        let times = engine.validBoundaries(in: media, start: start, first: false, last: false, container: container)
        let position = times.lowerBound { $0 >= at }
        let eligible = { (time: RationalTime) in start ? time < input.to : time > input.from }
        let nearest = [times[..<position].last(where: eligible),
                       times[position...].first(where: { $0 > at && eligible($0) })].compactMap { $0 }
        let neighbor = start ? index - 1 : index + 1
        let adjacent = windows.indices.contains(neighbor) ? windows[neighbor] : nil
        let location = adjacent?.placementID
        let edge = start ? "return" : "cut"
        let context = location.map { "Still placement \($0) has an unsafe camera \(edge)" } ?? "Camera span \(index + 1) has an unsafe \(edge)"
        let issue = CutError(code: requireCameraCopy ? "camera_copy_required" : "unsafe_boundary",
                             message: "\(context) at source \(at).", segment: index + 1,
                             boundary: start ? "from" : "to",
                             placementIDs: location.map { [$0] }).because(start ? .cutVideoStart : .cutVideoEnd)
        guard let adjacent, let location else { throw issue }
        let proposals = try nearest.map { candidate in
            let shift = try candidate.subtracting(at)
            if let authored = adjacent.authoredClockRange {
                let time = start ? adjacent.heldEnd ?? authored.to : authored.from
                let source = start ? adjacent.heldEndSource ?? adjacent.camera?.source : adjacent.camera?.source
                return StillBoundaryAdjustment(placementID: location, boundary: start ? .end : .start,
                                               clock: adjacent.clock,
                                               occurrenceID: adjacent.clock == "sequence" ? source : nil,
                                               requestedTime: time, adjustedTime: try time.adding(shift),
                                               durationChange: start ? shift : try RationalTime.zero.subtracting(shift))
            }
            return StillBoundaryAdjustment(placementID: location, boundary: .insertion, clock: adjacent.clock,
                                           occurrenceID: nil, requestedTime: adjacent.output.from,
                                           adjustedTime: try adjacent.output.from.adding(shift), durationChange: .zero)
        }
        throw StillUnsafeJoin(issue: issue, proposals: proposals)
    }

    private func openAsset(_ asset: StillAsset, placementID: String, document: URL, engine: CutEngine,
                           identities: inout [URL: SourceIdentity]) throws -> URL {
        do {
            let file = try CutProject.checkedMediaURL(asset.file, relativeTo: document)
            let identity = try SourceIdentity(file)
            guard identities[file]?.matchesSnapshot(identity) != false else {
                throw CutError(code: "source_changed", message: "The image changed during preflight.")
            }
            let fingerprint = try StillImage.inspectAndFingerprint(file, expectedIdentity: identity, cancelled: cancelled).fingerprint
            guard asset.fingerprint == fingerprint else {
                throw CutError(code: "source_changed", message: "The image fingerprint differs from the saved asset. Relink it to accept the new image.")
            }
            try engine.checkCancellation()
            guard identity.isCurrentSnapshot(at: file) else {
                throw CutError(code: "source_changed", message: "The image changed during preflight.")
            }
            identities[file] = identity
            return file
        } catch is CancellationError {
            throw CutError(code: "cancelled", message: "The operation was cancelled.")
        } catch {
            let issue = error as? CutError
            throw CutError(code: issue?.code ?? "missing_still_asset",
                           message: "Could not open asset \(asset.id) (\(asset.displayName)) for still placement \(placementID). \(error.localizedDescription)")
        }
    }

}
