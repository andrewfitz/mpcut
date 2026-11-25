import SwiftUI
import MPCutCore

private struct SceneScopeCommand: View {
    let title: String
    var enabled = true
    let state: SceneScanDisposition?
    let scan: (SceneScanPolicy) -> Void
    let restart: (Bool) -> Void

    var body: some View {
        Group {
            switch state {
            case .current:
                Menu(title) {
                    Button("Up to date") { scan(.reuse) }
                        .help("Use saved scene scan")
                    Button("Scan Again…") { restart(false) }
                        .help("Run a fresh scan")
                }
                .help("Show scan options")
            case let .partial(position, saved):
                Menu(title) {
                    Button(resumeTitle(position, saved: saved)) { scan(.resume) }
                        .help("Resume paused scan")
                    Button("Restart…") { restart(true) }
                        .help("Restart paused scan")
                }
                .help("Show paused scan options")
            case .stale:
                Menu(title) {
                    Button("Rescan") { scan(.reuse) }
                        .help("Rescan changed media")
                }
                .help("Show scan options")
            case nil:
                Button(title) { scan(.reuse) }
                    .help("Find scene changes")
            }
        }
        .disabled(!enabled)
    }

    private func resumeTitle(_ position: RationalTime?, saved: Bool) -> String {
        guard let position else { return "Resume" }
        return "Resume · \(saved ? "saved through" : "scanned through") \(timelineTime(position.seconds))"
    }
}

struct SequenceFindSceneCommands: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let clip = editor.sceneClipID
        SceneScopeCommand(title: "Selected Clip", enabled: editor.canScanSelectedScenes,
                          state: clip.flatMap { editor.sceneDisposition(clipID: $0) },
                          scan: { editor.scanForScenes(clipID: clip, policy: $0) },
                          restart: { editor.confirmSceneRestart(clipID: clip, paused: $0) })
        SceneScopeCommand(title: "All Sources", enabled: editor.canScanScenes(clipID: nil),
                          state: editor.sceneDisposition(clipID: nil),
                          scan: { editor.scanForScenes(policy: $0) },
                          restart: { editor.confirmSceneRestart(paused: $0) })

        if editor.scenePaused {
            Divider()
            Button("Resume Previous Scan") { editor.repeatSceneScan(policy: .resume) }
                .help("Resume previous scan")
            Button("Restart Previous Scan…") { editor.confirmSceneRestart(paused: true, repeatPrevious: true) }
                .help("Restart previous scan")
        }
        if editor.sceneCheckpointSaveFailed {
            Button("Retry Saving Scene Progress", action: editor.saveAnalysisSidecars)
                .disabled(!editor.canSaveAnalysisSidecars)
                .help("Save scene progress")
        }
    }
}

struct MulticamFindSceneCommands: View {
    @ObservedObject var model: MulticamEditorModel

    var body: some View {
        let camera = model.selectedSceneCamera
        SceneScopeCommand(title: "Selected Camera",
                          enabled: !model.isBusy && camera.map { model.analysis.canScanScenes(camera: $0) } == true,
                          state: camera.flatMap { model.analysis.sceneDisposition(camera: $0) },
                          scan: { model.analysis.scanScenes(camera: camera, policy: $0) },
                          restart: { model.confirmSceneRestart(camera: camera, paused: $0) })
        SceneScopeCommand(title: "All Cameras", enabled: !model.isBusy && model.analysis.canScanScenes(camera: nil),
                          state: model.analysis.sceneDisposition(camera: nil),
                          scan: { model.analysis.scanScenes(policy: $0) },
                          restart: { model.confirmSceneRestart(paused: $0) })

        if model.analysis.scenePaused {
            Divider()
            Button("Resume Previous Scan") { model.analysis.repeatSceneScan(policy: .resume) }
                .help("Resume previous scan")
            Button("Restart Previous Scan…") { model.confirmSceneRestart(paused: true, repeatPrevious: true) }
                .help("Restart previous scan")
        }
        if model.analysis.sceneCheckpointSaveFailed {
            Button("Retry Saving Scene Progress", action: model.saveAnalysisSidecars)
                .disabled(!model.canSaveSidecars)
                .help("Save scene progress")
        }
    }
}
