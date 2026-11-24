import Foundation

extension ParticipantRenderSession {
    func requirePublishable(sound: StillSoundPlan) throws {
        let report = report(sound: sound)
        if !report.publishable, let issue = report.privacyIssues.first {
            throw issue.unresolvedError
        }
    }

    func publishPicture(_ video: URL, sound: StillSoundPlan, staging: URL, output: URL, container: String,
                        cancelled: @escaping @Sendable () -> Bool, progress: @escaping (Double) -> Bool) throws -> ParticipantRenderReport {
        let report = report(sound: sound)
        let inspector = CutEngine(cancelled: cancelled, useSidecar: false, tracks: .video)
        let written = try inspector.inspect(video, keyframes: true)
        guard written.duration == report.duration, Int64(written.frames.count) == report.frameCount else {
            throw CutError(code: "participant_timing_mismatch",
                           message: "The encoder wrote \(written.frames.count) frames over \(written.duration) seconds, "
                           + "expected \(report.frameCount) frames over \(report.duration) seconds.")
        }
        for (index, frame) in written.frames.enumerated() {
            if index.isMultiple(of: 1_024) { try inspector.checkCancellation() }
            let (at, length) = try frameTiming(at: Int64(index))
            guard frame.time == at, frame.duration == length else {
                throw CutError(code: "participant_timing_mismatch",
                               message: "The encoder changed the presentation timing of frame \(index + 1).")
            }
        }
        if container == "mov", sound.actions.isEmpty {
            // AVAssetWriter already produced the requested MOV. Install the verified staging file
            // directly without reading and copying its compressed samples a second time.
            try ReencodeEngine().checkDestination(output, container: container)
            guard progress(1) else { throw CutError(code: "cancelled", message: "Operation cancelled.") }
            try verifySources()
            try sound.verifySources()
            try inspector.checkCancellation()
            try MulticamMux.publishMovie(video, to: output.standardizedFileURL)
        } else {
            let audio = try StillSoundPlanner(cancelled: cancelled).write(sound, in: staging) { progress($0 * 2 / 3) }
            try MulticamMux(cancelled: cancelled).export(picture: video, sounds: audio, to: output,
                                                       container: container, duration: report.duration,
                                                       progress: { progress(2 / 3 + $0 / 3) }) {
                try verifySources()
                try sound.verifySources()
            }
        }
        return self.report(sound: sound, output: output.standardizedFileURL.path)
    }
}
