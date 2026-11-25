import AppKit
import MPCutCore

/// A queue item can be saved after the source document has moved or pruned its attachments.
struct TranscriptQueueExcerpt: Sendable {
    var name: String
    private let project: CutProject
    private let location: URL
    private let mediaSnapshot: ProjectMediaSnapshot
    init(name: String, project: CutProject, location: URL, mediaSnapshot: ProjectMediaSnapshot = .empty) {
        self.name = name
        self.project = project
        self.location = location
        self.mediaSnapshot = mediaSnapshot

    }

    /// Automatic keeps the excerpt's rule: the saved project's folder, or AppKit's choice for an untitled draft.
    @MainActor
    func startDirectory(preferences: EditorPreferences?) -> URL? {
        let projectFile = ProjectDraft.isManaged(location) ? nil : location.resolvingSymlinksInPath()
        let automatic = projectFile?.deletingLastPathComponent()
        guard let preferences, preferences.exportStartFolder != .automatic else { return automatic }
        let chosen = preferences.exportStartFolderPath
        return ExportStartFolder.resolve(mode: preferences.exportStartFolder,
                                         chosenFolder: chosen.isEmpty ? nil : URL(fileURLWithPath: chosen),
                                         projectFile: projectFile,
                                         sourceRecording: project.sequenceClips?.first.map {
                                             URL(fileURLWithPath: $0.file, relativeTo: location.deletingLastPathComponent()).absoluteURL
                                         },
                                         sessionFolder: nil, automatic: automatic).directory
    }

    func save(to destination: URL) throws {
        guard isCutDocument(destination), !ProjectDraft.isManaged(destination) else {
            throw CutError(code: "invalid_output", message: "Choose a new .cut project outside the automatic recovery folder.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CutError(code: "output_exists", message: "Choose a new project destination.")
        }
        var paths: [String: String] = [:]
        var snapshot = try project.rebased(from: location, to: destination, paths: &paths, makeRelative: true)
        snapshot.transcripts.documentID = nil
        try snapshot.save(to: destination, undo: [], redo: [],
                          mediaSnapshot: mediaSnapshot.rebased(from: location, to: destination, makeRelative: true),
                          replacingExisting: false)
    }

    /// Pass the editor's preferences so Settings → Export → Start export panels in applies. Without
    /// them, and under Automatic, the panel starts beside the saved project as it always has.
    @MainActor
    func presentSave(in window: NSWindow?, canSave: ((URL) -> Bool)?, preferences: EditorPreferences? = nil) {
        let panel = ProjectPanels.cutSavePanel(name: name + ".cut")
        if let directory = startDirectory(preferences: preferences) { panel.directoryURL = directory }
        panel.title = "Save Excerpt Project"
        ProjectPanels.present(panel, in: window, fromSheet: true) { accepted in
            guard accepted, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    guard canSave?(destination) != false else {
                        throw CutError(code: "project_open", message: "A window already has this project open.")
                    }
                    try await Task.detached(priority: .userInitiated) { try save(to: destination) }.value
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Save Excerpt Project"
                    alert.informativeText = error.localizedDescription
                    ProjectPanels.present(alert, in: window?.attachedSheet ?? window)
                }
            }
        }
    }
}
