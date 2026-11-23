import Foundation

/// The ordinary export settings that can deliver a saved participant composition.
package struct ParticipantProjectExport: Sendable {
    package let report: ParticipantRenderReport
    let project: CutProject
    let document: URL

    package static var requiresEncoding: CutError {
        CutError(code: "participant_render_requires_encoding",
                 message: "The saved participant composition requires Re-encode.")
    }

    package static func unsupported(_ operation: String) -> CutError {
        CutError(code: "participant_render_unavailable",
                 message: "\(operation) cannot apply the saved participant composition. Export the current assembly with Re-encode.")
    }

    package init(_ project: CutProject, relativeTo document: URL? = nil, output: URL,
                 mode: ExportMode, tracks: ExportTracks = .all, settings: ReencodeSettings = .init(),
                 audioOutput: MulticamAudioOutput = .separateTracks, audioAction: ReencodeAudio? = nil,
                 plannedSubfolder: URL? = nil, cancelled: (@Sendable () -> Bool)? = nil) throws {
        guard mode == .encode else { throw Self.requiresEncoding }
        guard tracks != .audio, settings.codec == .h264, settings.quality == .balanced,
              audioOutput == .separateTracks,
              [.auto, .pcm, .removeAudio].contains(audioAction ?? settings.audio) else {
            throw CutError(code: "participant_render_settings",
                           message: "Participant export uses balanced H.264 and the saved participant audio selection. Choose automatic audio, PCM, or remove audio.")
        }
        guard project.stillFormat == nil else {
            throw CutError(code: "participant_render_settings",
                           message: "The saved participant canvas and a custom still output format cannot be used together.")
        }
        let cutter = CutEngine(cancelled: cancelled)
        try cutter.checkCancellation()
        try cutter.checkDestination(output, plannedSubfolder: plannedSubfolder)
        var project = project
        if tracks == .video || (audioAction ?? settings.audio) == .removeAudio {
            var participants = project.participants
            participants.render?.audio = .init()
            project.participants = participants
        }
        self.project = project
        self.document = document ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("timeline.cut")
        report = try ParticipantRenderer(cancelled: cancelled).report(project, document: self.document, output: output)
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
        .known(tier: .reencode, factors: [TierFactor(Self.requiresEncoding, forces: .reencode)],
               container: container, warnings: [])
    }

    package func write(to output: URL, cancelled: (@Sendable () -> Bool)? = nil,
                       progress: ((Double) -> Bool)? = nil) throws {
        _ = try ParticipantRenderer(cancelled: cancelled).render(project, document: document, to: output, progress: progress)
    }

    package static func tier(_ project: CutProject, relativeTo document: URL? = nil,
                             preferredContainer: String? = nil, cancelled: (@Sendable () -> Bool)? = nil) -> TierState {
        let container = preferredContainer == "mp4" && project.participants.render?.audio.mode == .silence ? "mp4" : "mov"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mpcut-tier-\(UUID().uuidString)").appendingPathExtension(container)
        do {
            return try Self(project, relativeTo: document, output: output, mode: .encode, cancelled: cancelled)
                .tier(container: container)
        } catch let issue as CutError {
            return issue.code == "cancelled" ? .checking : .unavailable(issue)
        } catch {
            return .unavailable(CutError(code: "export_failed", message: error.localizedDescription))
        }
    }
}
