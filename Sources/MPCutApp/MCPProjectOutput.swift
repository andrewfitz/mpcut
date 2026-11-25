import Foundation
import MPCutCore

@MainActor
extension ProjectSession {
    func mcpProjectOutput(tool: String, arguments: [String: Any],
                          checkAccess: @MainActor () throws -> Void) throws -> [String: Any]? {
        guard tool == "project_editor_output_read" || tool == "project_editor_output_set" else { return nil }
        guard mcpHasProjectMedia else { throw MCPCommandError("invalid_target", "Open a project first.") }
        let current = outputSettingsProject
        let defaultCanvas = current.hasStoredOutputCanvas ? current.projectOutputSettings.canvas : sourceOutputCanvas
        if tool == "project_editor_output_set" {
            guard !hasLifecycleModal, mcpCanEditProjectMedia else {
                throw MCPCommandError("editor_busy", "Finish the current project operation before changing export settings.")
            }
            let frameRate = try (arguments["frame_rate"] as? String).map { try RationalTime(parsing: $0) }
            let mode = (arguments["audio_mode"] as? String).flatMap(ParticipantAudioMode.init(rawValue:))
            let ids = arguments["audio_ids"] as? [String]
            let privacy = (arguments["unresolved_privacy"] as? String).flatMap(ParticipantUnresolvedPrivacy.init(rawValue:))
            let width = arguments["width"] as? Int
            let height = arguments["height"] as? Int
            let background = (arguments["background"] as? Int).flatMap(UInt32.init(exactly:))
            guard width != nil || height != nil || frameRate != nil || background != nil || mode != nil || privacy != nil else {
                throw MCPCommandError("invalid_arguments", "Supply at least one export setting.")
            }
            guard ids == nil || mode != nil else {
                throw MCPCommandError("invalid_arguments", "Supply audio_mode with audio_ids.")
            }
            let audio = mode.map { ParticipantRenderAudio(mode: $0, ids: ids ?? []) }
            try checkAccess()
            try changeOutputSettings("Change Export Settings") {
                try $0.settingProjectOutput(width: width, height: height, frameRate: frameRate, background: background,
                                            audio: audio, privacy: privacy, defaultCanvas: defaultCanvas)
            }
        }
        let updated = outputSettingsProject
        let snapshot = ProjectOutputSettingsSnapshot(project: updated, defaultCanvas: defaultCanvas)
        return ["changed": updated != current, "output": try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(snapshot))]
    }
}
