import Foundation

/// An ordinary export that renders the project’s layouts and feed treatments.
package struct ParticipantProjectExport: Sendable {
    package let report: ParticipantRenderReport
    let project: CutProject
    let document: URL
    let settings: ReencodeSettings
    let range: MulticamRange?
    let audioOutput: MulticamAudioOutput
    private let soundOnly: StillExportPlan?
    /// What the caller chose in place of what was asked, such as HEVC for an HDR composition asked for in H.264.
    /// Listed first among `notices`.
    package var substitutions: [String] = []

    package static var requiresEncoding: CutError {
        CutError(code: "participant_render_requires_encoding",
                 message: "Tile layouts and feed treatments require Re-encode.")
    }

    package static func unsupported(_ operation: String) -> CutError {
        CutError(code: "participant_render_unavailable",
                 message: "\(operation) cannot render tile layouts and feed treatments. Use a Re-encode export.")
    }

    package init(_ project: CutProject, relativeTo document: URL? = nil, output: URL,
                 mode: ExportMode, tracks: ExportTracks = .all, settings: ReencodeSettings = .init(),
                 audioOutput: MulticamAudioOutput = .separateTracks, audioAction: ReencodeAudio? = nil,
                 plannedSubfolder: URL? = nil, range: MulticamRange? = nil, audioStream: Int? = nil,
                 audioTrackOrdinal: Int? = nil, cancelled: (@Sendable () -> Bool)? = nil) throws {
        let nativeAudio = tracks == .audio && project.participants.render == nil
        if !nativeAudio {
            guard mode == .encode else { throw Self.requiresEncoding }
            guard tracks != .audio else {
                throw CutError(code: "participant_render_settings", message: "Choose a movie export to render the saved participant composition.")
            }
        }
        let action = tracks == .video ? .removeAudio : audioAction ?? settings.audio
        let settings = ReencodeSettings(codec: settings.codec, quality: settings.quality, audio: action)
        let cutter = CutEngine(cancelled: cancelled)
        try cutter.checkCancellation()
        try cutter.checkDestination(output, plannedSubfolder: plannedSubfolder)
        self.project = project
        self.settings = settings
        self.range = range
        self.audioOutput = audioOutput
        self.document = document ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("timeline.cut")
        if nativeAudio {
            if case .multicam = project, audioStream != nil || audioTrackOrdinal != nil {
                throw CutError(code: "invalid_arguments", message: "Choose project microphones in the audio policy.")
            }
            try project.validateDestination(output, relativeTo: self.document)
            let original = try project.resolveStills()
            if let range, range.from < .zero || range.to > original.duration || range.from >= range.to {
                throw CutError(code: "invalid_range", message: "Choose a nonempty selection inside the program.")
            }
            let timeline = try range.map { try original.participantScoped(to: $0) } ?? original
            let container = output.pathExtension.lowercased()
            guard ExportRules.stillContainers(mode: mode, tracks: .audio, codec: settings.codec, audio: action).contains(container) else {
                throw CutError(code: "unsupported_container", message: "Choose an audio container supported by the selected codec.")
            }
            let policy = project.projectOutputSettings
            let soundAction: ReencodeAudio
            if action == .auto, mode == .copy {
                soundAction = .copyOriginal
            } else if action == .auto, ![.aac, .pcm].contains(where: { ExportRules.allows(stillAudio: $0, in: container) }),
                      let lossless = ExportRules.defaultStillLosslessAudio(codec: settings.codec, container: container) {
                soundAction = lossless
            } else {
                soundAction = action
            }
            let scoped = try project.participantSound(in: range)
            let sound = try ParticipantRenderSound.resolve(
                scoped, document: self.document, timeline: timeline, audio: policy.audio, cancelled: cancelled,
                action: soundAction, container: container, audioOutput: audioOutput,
                tracks: .audio, mode: mode, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal
            )
            try sound.verifySources()
            let warning = Self.sharedAudioNotice(project, audio: policy.audio, actions: sound.actions)
            report = .init(canvas: policy.canvas, duration: timeline.duration, frameCount: 0, audio: policy.audio,
                           audioActions: sound.actions, privacyIssues: [], publishable: true, staleSourceIDs: [],
                           output: nil, audioPrivacyNotice: warning)
            let exportReport = try StillExportReport(
                mode: mode, tracks: .audio, container: container, duration: timeline.duration,
                copiedCameraDuration: .zero, encodedCameraDuration: .zero, generatedStillDuration: .zero,
                copiedVideoDuration: .zero, encodedVideoDuration: .zero, picture: [], pictureTiming: .cadence,
                videoCodec: nil, generatedVideoSampleCount: 0, writtenPictureDuration: nil,
                cutMap: ExportCutMap(stills: scoped, relativeTo: self.document), placements: [],
                audioOutput: audioOutput, soundActions: sound.actions, colorPolicy: nil,
                warnings: sound.actions.flatMap(\.warnings) + [warning].compactMap { $0 }
            )
            soundOnly = .init(report: exportReport, pictures: [], sound: sound, identities: [:], settings: settings, hdrMetadata: nil)
            return
        }
        soundOnly = nil
        report = try ParticipantRenderer(cancelled: cancelled, legacyWholeFramePrivacy: false, allowsOriginal: true).report(
            project, document: self.document, output: output, settings: settings, range: range, audioOutput: audioOutput
        )
        if !report.publishable {
            let detail = report.privacyIssues.first.map {
                "Review source ‘\($0.sourceID)’ from \($0.source.from) to \($0.source.to) "
                + "(output \($0.output.from) to \($0.output.to)) before publishing."
            }
            throw CutError(code: "unresolved_participant_privacy",
                           message: detail ?? "Review unresolved participant privacy coverage before exporting.")
        }
    }

    package func tier(container: String) -> TierState {
        if let soundOnly {
            let copied = soundOnly.report.soundActions.allSatisfy { $0.audio == .copyOriginal }
            return .known(tier: copied ? .trueLossless : .reencode, factors: [], container: container,
                          warnings: soundOnly.report.warnings)
        }
        return .known(tier: .reencode, factors: [TierFactor(Self.requiresEncoding, forces: .reencode)],
                      container: container, warnings: notices)
    }

    /// The privacy notices of the plan, then what its picture gives up, as the export sheet, queue, CLI and MCP list them.
    package var notices: [String] {
        substitutions + [report.picturePrivacyNotice, report.audioPrivacyNotice].compactMap { $0 } + (report.warnings ?? [])
    }

    /// Writes the export and returns what only writing showed, reported as `written_warnings`: constant quality the
    /// encoder could not take. Empty for a sound-only export.
    @discardableResult
    package func write(to output: URL, cancelled: (@Sendable () -> Bool)? = nil,
                       progress: ((Double) -> Bool)? = nil) throws -> [String] {
        if let soundOnly {
            try StillExportPlanner(cancelled: cancelled).write(soundOnly, to: output, progress: progress)
            return []
        }
        let written = try ParticipantRenderer(cancelled: cancelled, legacyWholeFramePrivacy: false, allowsOriginal: true).render(
            project, document: document, to: output, settings: settings, range: range, audioOutput: audioOutput, progress: progress
        )
        ExportWriteNotices.record(written.writtenWarnings ?? [])
        return written.writtenWarnings ?? []
    }

    static func sharedAudioNotice(_ project: CutProject, audio: ParticipantRenderAudio,
                                  actions: [StillSoundAction]) -> String? {
        guard project.participants.hasEffectiveTreatments, audio.mode != .iso, !actions.isEmpty else { return nil }
        return "Shared audio can still contain speech from treated feeds."
    }

    package static func tier(_ project: CutProject, relativeTo document: URL? = nil,
                             preferredContainer: String? = nil, cancelled: (@Sendable () -> Bool)? = nil) -> TierState {
        let defaultCodec = project.stillFormat?.codec ?? .h264
        func checked(_ codec: ReencodeCodec) throws -> TierState {
            let supported = ExportRules.multicamReencodeContainers(codec)
            let preference = preferredContainer ?? project.stillFormat?.container
            let container = preference.flatMap { supported.contains($0) ? $0 : nil } ?? "mov"
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(".mpcut-tier-\(UUID().uuidString)").appendingPathExtension(container)
            return try Self(project, relativeTo: document, output: output, mode: .encode,
                            settings: .init(codec: codec), cancelled: cancelled).tier(container: container)
        }
        do {
            do { return try checked(defaultCodec) }
            catch let issue as CutError where issue.code == "unsupported_format" && defaultCodec == .h264 {
                return try checked(.hevc)
            }
        } catch let issue as CutError {
            return issue.code == "cancelled" ? .checking : .unavailable(issue)
        } catch {
            return .unavailable(CutError(code: "export_failed", message: error.localizedDescription))
        }
    }
}
