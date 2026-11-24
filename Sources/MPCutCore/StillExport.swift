import Foundation

public struct StillPictureAction: Encodable, Sendable {
    public enum Action: String, Codable, Sendable {
        case copy, encodeCamera = "encode_camera", generateStill = "generate_still"
    }

    public let action: Action
    public let output: MulticamRange
    public let input: MulticamRange?
    public let source: String?
    public let sourceOccurrences: [String]
    public let placementID: String?
    public let clock: String
    public var writtenOutput: MulticamRange? = nil
    public var sampleCount: Int? = nil
}

public struct StillExportReport: Encodable, Sendable {
    public let mode: ExportMode
    public let tracks: ExportTracks
    public let container: String
    public let duration: RationalTime
    public let copiedCameraDuration: RationalTime
    public let encodedCameraDuration: RationalTime
    public let generatedStillDuration: RationalTime
    public let copiedVideoDuration: RationalTime
    public let encodedVideoDuration: RationalTime
    public let picture: [StillPictureAction]
    public let pictureTiming: StillPictureTiming
    public let videoCodec: String?
    public let generatedVideoSampleCount: Int
    public let writtenPictureDuration: RationalTime?
    public let cutMap: ExportCutMap
    public let placements: [StillTimelineSpan]
    public let audioOutput: MulticamAudioOutput
    public let soundActions: [StillSoundAction]
    public let colorPolicy: StillProgramColorPolicy?
    public let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case mode, tracks, container, duration, copiedCameraDuration, encodedCameraDuration
        case generatedStillDuration, copiedVideoDuration, encodedVideoDuration, picture, placements
        case audioOutput, soundActions, colorPolicy, warnings
        case pictureTiming, videoCodec, generatedVideoSampleCount, writtenPictureDuration
    }
}

public struct StillExportPlan: Sendable {
    public let report: StillExportReport
    public var duration: RationalTime { report.duration }
    public var container: String { report.container }

    let pictures: [StillExportPicture]
    let sound: StillSoundPlan?
    let identities: [URL: SourceIdentity]
    let settings: ReencodeSettings
    let hdrMetadata: StillHDRMetadata?

    func verifySources(using engine: CutEngine) throws {
        for (file, identity) in identities {
            try engine.checkCancellation()
            try engine.verifyIdentity(file, identity: identity)
        }
        try sound?.verifySources()
        try engine.checkCancellation()
    }
}

struct StillExportPicture: Sendable {
    enum Content: Sendable {
        case camera(media: MediaInfo, input: MulticamRange, frames: Range<Int>, edges: [EncodedEdge])
        case still(file: URL, framing: StillImageFraming, reference: StreamInfo, schedule: StillSampleSchedule)
    }

    let output: MulticamRange
    let clock: String
    let source: String?
    let sourceOccurrences: [String]
    let placementID: String?
    let content: Content
    var writtenOutput: MulticamRange? = nil
    var renderOutput: MulticamRange { writtenOutput ?? output }
}

public struct StillExportPlanner: Sendable {
    let useSidecar: Bool
    let cancelled: (@Sendable () -> Bool)?
    let replacementReferenceAngles: [String: String]
    let expectedSoundtrackIdentity: SourceIdentity?

    public init(useSidecar: Bool = true, cancelled: (@Sendable () -> Bool)? = nil) {
        self.init(useSidecar: useSidecar, cancelled: cancelled, replacementReferenceAngles: [:])
    }

    package init(useSidecar: Bool, cancelled: (@Sendable () -> Bool)?,
                 replacementReferenceAngles: [String: String],
                 expectedSoundtrackIdentity: SourceIdentity? = nil) {
        self.useSidecar = useSidecar
        self.cancelled = cancelled
        self.replacementReferenceAngles = replacementReferenceAngles
        self.expectedSoundtrackIdentity = expectedSoundtrackIdentity
    }

    public func resolve(_ project: MulticamProject, relativeTo location: URL? = nil,
                        tracks: ExportTracks = .all, audioStream: Int? = nil, audioTrackOrdinal: Int? = nil,
                        mode: ExportMode? = nil,
                        requireCameraCopy: Bool = false, container: String? = nil, output: URL? = nil,
                        settings: ReencodeSettings = .init(), offerAlternatives: Bool = true,
                        audioOutput: MulticamAudioOutput = .separateTracks,
                        audioAction: ReencodeAudio? = nil,
                        pictureTiming: StillPictureTiming? = nil,
                        videoCodec: ReencodeCodec? = nil) throws -> StillExportPlan {
        try resolve(.multicam(project), relativeTo: location, tracks: tracks, audioStream: audioStream,
                    audioTrackOrdinal: audioTrackOrdinal,
                    mode: mode, requireCameraCopy: requireCameraCopy, container: container, output: output,
                    settings: settings, offerAlternatives: offerAlternatives, audioOutput: audioOutput,
                    audioAction: audioAction, pictureTiming: pictureTiming, videoCodec: videoCodec)
    }

    public func resolve(_ project: CutProject, relativeTo location: URL? = nil,
                        tracks: ExportTracks = .all, audioStream: Int? = nil, audioTrackOrdinal: Int? = nil,
                        mode requestedMode: ExportMode? = nil,
                        requireCameraCopy: Bool = false, container requestedContainer: String? = nil, output: URL? = nil,
                        settings requestedSettings: ReencodeSettings = .init(), offerAlternatives: Bool = true,
                        audioOutput: MulticamAudioOutput = .separateTracks,
                        audioAction: ReencodeAudio? = nil,
                        pictureTiming: StillPictureTiming? = nil,
                        videoCodec: ReencodeCodec? = nil) throws -> StillExportPlan {
        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        guard project.participants.render == nil else { throw ParticipantProjectExport.unsupported("Still export") }
        let timeline = try project.resolveStills()
        let visible = timeline.spans.filter { $0.placementID != nil }
        let stillFormat = project.stillFormat
        let source: ExportSourceKind
        let usesMix: Bool
        if case .multicam(let multicam) = project {
            source = .multicam
            usesMix = multicam.audio == .mix
        } else {
            source = .movie
            usesMix = false
        }
        let defaultAudio = usesMix && audioOutput == .separateTracks && requestedSettings.audio == .auto
            ? ReencodeAudio.copyOriginal : requestedSettings.audio
        let codec = videoCodec ?? stillFormat?.codec ?? requestedSettings.codec
        let timing = pictureTiming ?? ExportRules.defaultStillPictureTiming(for: project)
        let ordinaryMode = tracks == .audio && project.stillSoundtrack != nil ? .encode :
            ExportRules.defaultMode(for: source, tracks: tracks)
        let selectionMode = requestedMode ?? ExportRules.defaultStillMode(tracks: tracks, placements: timeline.exportPlacementScope,
                                                                          otherwise: ordinaryMode)
        let mode = tracks == .audio ? ExportRules.cell(source: source, tracks: tracks, mode: selectionMode,
                                                       placements: timeline.exportPlacementScope).resolvedMode : selectionMode
        let ext = output?.pathExtension.lowercased() ?? ""
        let container = requestedContainer?.lowercased() ?? (ext.isEmpty ?
            (tracks == .audio ? "m4a" : project.stillFormat?.container ??
                (mode == .encode ? ExportRules.defaultReencodeContainer(codec) : "mov")) : ext)
        if let output { try engine.checkDestination(output) }
        guard ext.isEmpty || container == ext else {
            throw CutError(code: "invalid_output", message: "The destination extension must match the selected container.")
        }
        let soundtrackAudio: ReencodeAudio? = mode != .copy && project.stillSoundtrack != nil && audioAction == nil &&
            requestedSettings.audio == .auto ? ExportRules.defaultStillLosslessAudio(codec: codec, container: container) : nil
        let selectedAudio = audioAction ?? soundtrackAudio ?? defaultAudio
        let strictSoundtrackCopy = mode == .copy && tracks == .audio && project.stillSoundtrack != nil
        let settings = ReencodeSettings(codec: codec,
                                        quality: codec == requestedSettings.codec ? requestedSettings.quality : nil,
                                        audio: strictSoundtrackCopy && selectedAudio == .auto ? .copyOriginal : selectedAudio)
        let explicitAudioTreatment = audioAction.map { $0 != .copyOriginal || source == .multicam } ?? false
        let independentAudio = usesMix || explicitAudioTreatment || soundtrackAudio != nil || audioOutput != .separateTracks ||
            (source == .multicam && requestedSettings.audio != .auto)
        guard timeline.duration > .zero else {
            throw CutError(code: "empty_edit", message: "Add media to the timeline before exporting.")
        }
        guard audioStream.map({ tracks == .audio && (0...Int(Int32.max)).contains($0) }) ?? true,
              audioTrackOrdinal.map({ tracks == .audio && audioStream == nil && (0..<Int(Int32.max)).contains($0) }) ?? true,
              tracks != .audio || settings.audio != .removeAudio else {
            throw CutError(code: "invalid_arguments", message: "Choose an audio-only output and a nonnegative stream index.")
        }
        guard settings.audio == .auto || ExportRules.stillMovieAudioActions.contains(settings.audio) else {
            throw CutError(code: "unsupported_audio", message: "Still timeline exports support PCM, ALAC, FLAC and AAC conversion.")
        }
        let document = location ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Untitled.cut")
        do {
            return try plan(project, document: document, timeline: timeline, visible: visible, tracks: tracks,
                            audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal,
                            mode: mode, requireCameraCopy: requireCameraCopy,
                            container: container, settings: settings,
                            audioOutput: audioOutput, independentAudio: independentAudio,
                            pictureTiming: timing, videoCodec: videoCodec,
                            defaultSoundtrackPCM: soundtrackAudio == .alac && container == "mov")
        } catch {
            let join = error as? StillUnsafeJoin
            guard var failure = join?.issue ?? (error as? CutError) else { throw error }
            guard offerAlternatives, failure.code != "cancelled", failure.code != "source_changed" else { throw failure }
            if let join {
                var adjustments: [StillBoundaryAdjustment] = []
                for proposal in join.proposals {
                    do {
                        let adjusted = try project.applyingStillBoundary(proposal)
                        let adjustedTimeline = try adjusted.resolveStills()
                        _ = try plan(adjusted, document: document, timeline: adjustedTimeline,
                                     visible: adjustedTimeline.spans.filter { $0.placementID != nil },
                                     tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal, mode: mode,
                                     requireCameraCopy: requireCameraCopy, container: container, settings: settings,
                                     audioOutput: audioOutput, independentAudio: independentAudio,
                                     pictureTiming: timing, videoCodec: videoCodec)
                        adjustments.append(proposal)
                    } catch let issue as CutError where issue.code == "cancelled" || issue.code == "source_changed" {
                        throw issue
                    } catch {
                        continue
                    }
                }
                failure.stillBoundaryAdjustments = adjustments
            }
            let defaultContainer = tracks == .audio ? "m4a" : stillFormat?.container ??
                ExportRules.defaultReencodeContainer(settings.codec)
            var candidates = container == defaultContainer ? [container] : [container, defaultContainer]
            let containerFailure = failure.code == "unsupported_container" ||
                failure.code == "still_generation_unavailable" || failure.factor == .outputContainer
            if containerFailure || failure.code == "unsupported_audio" {
                let actions = tracks == .audio && settings.audio == .auto ? ExportRules.stillSoundConversions : [settings.audio]
                let supported = actions.flatMap {
                    ExportRules.stillContainers(mode: mode, tracks: tracks, codec: settings.codec, audio: $0)
                }
                for option in supported where !candidates.contains(option) { candidates.append(option) }
            }
            let preserveSamples = [.alac, .flac, .pcm].contains(settings.audio) ||
                (project.stillSoundtrack != nil && [.auto, .copyOriginal].contains(settings.audio))
            var modes: [(mode: ExportMode, requireCopy: Bool)] = []
            if tracks != .audio && !visible.isEmpty &&
                (mode == .copy || (mode == .smart && (failure.track != nil || containerFailure)) ||
                    (mode == .encode && requireCameraCopy && failure.code == "camera_copy_required")) {
                modes.append((.smart, requireCameraCopy))
            }
            if mode == .smart && requireCameraCopy && failure.code == "camera_copy_required" {
                modes.append((.smart, false))
            }
            if mode != .encode {
                modes.append((.encode, stillFormat != nil && requireCameraCopy))
            } else if containerFailure || independentAudio {
                modes.append((.encode, requireCameraCopy))
            }
            if (independentAudio || preserveSamples) && tracks != .video && settings.audio != .removeAudio &&
                !modes.contains(where: { $0.mode == mode && $0.requireCopy == requireCameraCopy }) {
                modes.insert((mode, requireCameraCopy), at: 0)
            }
            if preserveSamples, !candidates.contains("mov") { candidates.append("mov") }
            var alternatives: [ExportAlternative] = []
            for (alternateMode, alternateCopy) in modes {
                var soundActions = [settings.audio]
                if tracks != .video && settings.audio != .removeAudio &&
                    (independentAudio || alternateMode != mode || !containerFailure) {
                    let deliverable: [ReencodeAudio] = preserveSamples ? [.pcm, .alac, .flac] :
                        (independentAudio ? [.auto, .aac, .pcm] : [.aac, .pcm])
                    soundActions += deliverable.filter { $0 != settings.audio }
                }
                if !preserveSamples, !independentAudio, tracks == .audio, settings.audio == .auto {
                    soundActions = [.aac, .pcm]
                }
                let codecs: [ReencodeCodec] = alternateMode == .encode && alternateMode != mode && tracks != .audio && stillFormat == nil
                    && settings.codec != .hevc ? [settings.codec, .hevc] : [settings.codec]
                var found = false
                for candidate in candidates where !found {
                    for codec in codecs where !found {
                        for audio in soundActions where alternateMode != mode || alternateCopy != requireCameraCopy
                            || candidate != container || audio != settings.audio {
                            if preserveSamples && audio == .pcm && candidate != "mov" { continue }
                            let options = ReencodeSettings(codec: codec,
                                                           quality: codec == settings.codec ? settings.quality : nil,
                                                           audio: audio)
                            do {
                                let alternative = try plan(project, document: document, timeline: timeline, visible: visible,
                                                           tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal,
                                                           mode: alternateMode,
                                                           requireCameraCopy: alternateCopy, container: candidate,
                                                           settings: options, audioOutput: audioOutput,
                                                           independentAudio: independentAudio,
                                                           pictureTiming: timing, videoCodec: codec == settings.codec ? videoCodec : codec)
                                alternatives.append(offer(alternative.report, settings: options, requireCameraCopy: alternateCopy,
                                                          relaxesCameraCopy: requireCameraCopy && !alternateCopy,
                                                          audioStream: audioStream, independentAudio: independentAudio,
                                                          explicitCodec: videoCodec))
                                found = true
                                break
                            } catch let issue as CutError where issue.code == "cancelled" || issue.code == "source_changed" {
                                throw issue
                            } catch {
                                continue
                            }
                        }
                    }
                }
            }
            if timing == .held && failure.code == "unsupported_still_timing" {
                do {
                    let cadence = try plan(project, document: document, timeline: timeline, visible: visible,
                                           tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal,
                                           mode: mode, requireCameraCopy: requireCameraCopy, container: container,
                                           settings: settings, audioOutput: audioOutput, independentAudio: independentAudio,
                                           pictureTiming: .cadence, videoCodec: videoCodec)
                    alternatives.append(offer(cadence.report, settings: settings, requireCameraCopy: requireCameraCopy,
                                              relaxesCameraCopy: false, audioStream: audioStream,
                                              independentAudio: independentAudio, explicitCodec: videoCodec,
                                              timingFallback: true))
                } catch let issue as CutError where issue.code == "cancelled" || issue.code == "source_changed" {
                    throw issue
                } catch {
                    // Cadence is only offered when it plans successfully.
                }
            }
            if !alternatives.isEmpty { failure.alternatives = alternatives }
            throw failure
        }
    }

    private func offer(_ report: StillExportReport, settings: ReencodeSettings, requireCameraCopy: Bool,
                       relaxesCameraCopy: Bool, audioStream: Int?, independentAudio: Bool,
                       explicitCodec: ReencodeCodec?, timingFallback: Bool = false) -> ExportAlternative {
        let mode = report.mode
        let audio = settings.audio == .removeAudio && report.tracks != .video ? .removeAudio :
            report.soundActions.first(where: { $0.audio != .copyOriginal })?.audio ?? report.soundActions.first?.audio
        let copies = mode == .copy && audio == .copyOriginal
        var label: String
        switch mode {
        case .copy where copies: label = "Copy soundtrack packets"
        case .smart: label = "Generate stills with Smart Trim"
        default: label = report.tracks == .audio ? "Convert the soundtrack" : "Re-encode the program"
        }
        if audio == .removeAudio {
            label += " and omit audio"
        } else if mode == .smart, let audio, audio != .copyOriginal {
            label += " and convert affected audio to \(audio.rawValue.uppercased())"
        }
        if timingFallback { label += " at the project cadence" }
        if relaxesCameraCopy && report.encodedCameraDuration > .zero { label += " (allows camera encoding)" }
        let rung: ExportRung
        switch mode {
        case .copy where copies: rung = .copyOtherContainer
        case .smart: rung = .smartTrim
        default: rung = report.tracks == .audio && audio == .aac ? .convertAAC : .reencode
        }
        var arguments = ["--mode", mode.rawValue]
        if report.tracks != .all { arguments += ["--tracks", report.tracks.rawValue] }
        if let audioStream { arguments += ["--audio-stream", String(audioStream)] }
        if report.tracks != .video {
            arguments += ["--audio", settings.audio.rawValue]
            if report.audioOutput != .separateTracks { arguments += ["--audio-output", report.audioOutput.rawValue] }
        }
        let codec = report.tracks == .audio || mode == .copy ? nil : mode == .encode ? settings.codec : explicitCodec
        if let codec {
            arguments += ["--video", codec.rawValue]
            if mode == .encode { arguments += ["--quality", settings.quality.rawValue] }
        }
        if report.tracks != .audio { arguments += ["--still-timing", report.pictureTiming.rawValue] }
        if requireCameraCopy { arguments.append("--require-camera-copy") }
        let id = "still-\(mode.rawValue)-\(report.container)" + (timingFallback ? "-cadence" : "")
        return ExportAlternative(id: id, rung: rung, label: label,
                                 mode: mode, tracks: report.tracks, container: report.container,
                                 audio: independentAudio && report.tracks != .video ? settings.audio : audio,
                                 codec: codec?.rawValue,
                                 bitRate: nil, quality: nil, lossless: copies,
                                 warnings: [], arguments: arguments, clips: nil)
    }

    private func plan(_ project: CutProject, document: URL, timeline: StillTimelinePlan,
                      visible: [StillTimelineSpan], tracks: ExportTracks, audioStream: Int?, audioTrackOrdinal: Int?, mode: ExportMode,
                      requireCameraCopy: Bool, container: String, settings: ReencodeSettings,
                      audioOutput: MulticamAudioOutput, independentAudio: Bool,
                      pictureTiming: StillPictureTiming, videoCodec: ReencodeCodec?,
                      defaultSoundtrackPCM: Bool = false) throws -> StillExportPlan {
        if tracks != .audio {
            guard ExportRules.stillMovieContainers.contains(container) else {
                throw CutError(code: "unsupported_container", message: "Still-bearing movie export requires MOV, MP4, M4V or MKV.")
            }
            if mode == .copy && !visible.isEmpty {
                let source: ExportSourceKind
                if case .multicam = project { source = .multicam } else { source = .movie }
                if let refusal = ExportRules.cell(source: source, tracks: tracks, mode: mode,
                                                  placements: timeline.exportPlacementScope).refusal {
                    throw refusal
                }
            }
        }

        let engine = CutEngine(cancelled: cancelled)
        try engine.checkCancellation()
        let effectiveFormat = tracks == .audio ? nil : project.stillFormat.map {
            StillTimelineFormat(width: $0.width, height: $0.height, cadence: $0.cadence,
                                codec: settings.codec, container: container)
        }
        if let effectiveFormat {
            try effectiveFormat.validate(color: project.programColorPolicy ?? StillTimelineFormat.sdrColorPolicy)
        }
        if tracks == .audio && project.stillSoundtrack != nil && mode == .copy,
           settings.audio != .copyOriginal || audioOutput != .separateTracks {
            throw CutError(code: "unsupported_audio", message: "Choose Convert Audio to encode or mix the soundtrack.")
        }
        if tracks != .video,
           !ExportRules.allows(stillAudio: settings.audio, in: container, videoCodec: tracks == .all ? settings.codec : nil) {
            throw CutError(code: "unsupported_audio",
                           message: "\(ExportRules.displayName(audio: settings.audio)) is unavailable for the selected still delivery format.")
        }
        let picture = tracks == .audio ? nil :
            try planPicture(project, document: document, timeline: timeline, mode: mode,
                            requireCameraCopy: requireCameraCopy, container: container, settings: settings, tracks: tracks,
                            pictureTiming: pictureTiming, format: effectiveFormat, videoCodec: videoCodec)
        let sound = tracks == .video || settings.audio == .removeAudio ? nil :
            try StillSoundPlanner(cancelled: cancelled, expectedSoundtrackIdentity: expectedSoundtrackIdentity)
                .resolve(project, relativeTo: document, timeline: timeline,
                         tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal,
                         mode: mode, audio: settings.audio, container: container,
                         audioOutput: audioOutput, independentAudio: independentAudio,
                         defaultSoundtrackPCM: defaultSoundtrackPCM)
        let actions = try pictureActions(picture?.pictures ?? [])
        func total(_ action: StillPictureAction.Action) throws -> RationalTime {
            try actions.lazy.filter { $0.action == action }.reduce(.zero) {
                try $0.adding($1.output.to.subtracting($1.output.from))
            }
        }
        let copied = try total(.copy)
        let encoded = try total(.encodeCamera)
        let generated = try total(.generateStill)
        let encodedTotal = try encoded.adding(generated)
        if tracks != .audio, try copied.adding(encodedTotal) != timeline.duration {
            throw CutError(code: "uncovered_picture", message: "The resolved picture spans do not cover the program duration.")
        }
        let videoFormat: String?
        if let first = picture?.pictures.first {
            if mode == .encode {
                videoFormat = settings.codec == .jpeg ? "mjpeg" : settings.codec.rawValue
            } else {
                switch first.content {
                case .camera(let media, _, _, _): videoFormat = media.video.codec
                case .still(_, _, let reference, _): videoFormat = reference.codec
                }
            }
        } else {
            videoFormat = nil
        }
        let writtenPictureDuration = picture?.pictures.last.map { $0.renderOutput.to }
        let report = try StillExportReport(mode: mode, tracks: tracks, container: container, duration: timeline.duration,
                                       copiedCameraDuration: copied, encodedCameraDuration: encoded,
                                       generatedStillDuration: generated, copiedVideoDuration: copied,
                                       encodedVideoDuration: encodedTotal, picture: actions,
                                       pictureTiming: pictureTiming, videoCodec: videoFormat,
                                       generatedVideoSampleCount: actions.reduce(0) { $0 + ($1.sampleCount ?? 0) },
                                       writtenPictureDuration: writtenPictureDuration,
                                       cutMap: ExportCutMap(stills: project, relativeTo: document),
                                       placements: visible, audioOutput: audioOutput, soundActions: sound?.actions ?? [],
                                       colorPolicy: picture?.colorPolicy,
                                       warnings: (picture?.warnings ?? []) + (sound?.actions.flatMap(\.warnings) ?? []))
        let resolved = StillExportPlan(report: report, pictures: picture?.pictures ?? [], sound: sound,
                                       identities: picture?.identities ?? [:], settings: settings, hdrMetadata: picture?.hdrMetadata)
        try resolved.verifySources(using: engine)
        return resolved
    }

    private func pictureActions(_ pictures: [StillExportPicture]) throws -> [StillPictureAction] {
        var actions: [StillPictureAction] = []
        for picture in pictures {
            switch picture.content {
            case .still(_, _, _, let schedule):
                actions.append(.init(action: .generateStill, output: picture.output, input: nil,
                                     source: picture.source, sourceOccurrences: picture.sourceOccurrences,
                                     placementID: picture.placementID, clock: picture.clock,
                                     writtenOutput: picture.writtenOutput, sampleCount: schedule.count))
            case .camera(_, let input, _, let edges):
                func append(_ from: RationalTime, _ to: RationalTime, _ action: StillPictureAction.Action) throws {
                    guard from < to else { return }
                    let offset = try picture.output.from.subtracting(input.from)
                    actions.append(.init(action: action, output: .init(from: try offset.adding(from), to: try offset.adding(to)),
                                         input: .init(from: from, to: to), source: picture.source,
                                         sourceOccurrences: picture.sourceOccurrences,
                                         placementID: nil, clock: picture.clock,
                                         writtenOutput: from == input.from && to == input.to ? picture.writtenOutput : nil))
                }
                var cursor = input.from
                for edge in edges {
                    try append(cursor, edge.from, .copy)
                    try append(edge.from, edge.to, .encodeCamera)
                    cursor = edge.to
                }
                try append(cursor, input.to, .copy)
            }
        }
        return actions
    }
}
