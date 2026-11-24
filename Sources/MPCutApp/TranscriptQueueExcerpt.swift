import AppKit
import MPCutCore

/// A queue item can be saved after the source document has moved or pruned its attachments.
struct TranscriptQueueExcerpt: Sendable {
    var name: String
    private let project: CutProject
    private let location: URL
    private let mediaSnapshot: ProjectMediaSnapshot
    private enum CapturedAsset: Sendable {
        /// The bytes are held in case the file they came from is gone by the time the excerpt is saved.
        case data(Data, from: TranscriptAsset)
        case unavailable(TranscriptAssetStatus)
    }

    private let assets: [String: CapturedAsset]

    init(name: String, project: CutProject, location: URL, mediaSnapshot: ProjectMediaSnapshot = .empty) {
        self.name = name
        self.project = project
        self.location = location
        self.mediaSnapshot = mediaSnapshot
        var assets: [String: CapturedAsset] = [:]
        for attachment in project.transcripts.attachments where assets[attachment.resultID] == nil {
            do {
                assets[attachment.resultID] = .data(try TranscriptStore.read(attachment.asset, relativeTo: location),
                                                    from: attachment.asset)
            } catch {
                let missing = (error as? CutError)?.code == "missing_transcript"
                assets[attachment.resultID] = .unavailable(missing ? .missing : .invalid)
            }
        }
        self.assets = assets
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
        var transcripts = snapshot.transcripts
        transcripts.documentID = nil
        for index in transcripts.attachments.indices {
            let attachment = transcripts.attachments[index]
            guard let captured = assets[attachment.resultID] else {
                throw CutError(code: "missing_transcript", message: "The queued excerpt is missing a transcript reference.")
            }
            switch captured {
            case .data(let data, let asset):
                transcripts.attachments[index].asset = try TranscriptStore.put(data, readFrom: asset, in: location,
                                                                               relativeTo: destination)
            case .unavailable(let status):
                let store = TranscriptStore.folder(relativeTo: destination).lastPathComponent
                transcripts.attachments[index].asset = .init(file: "\(store)/\(attachment.resultID).json",
                                                            sha256: attachment.resultID, unavailable: status)
            }
        }
        snapshot.transcripts = transcripts
        try snapshot.save(to: destination, undo: [], redo: [],
                          mediaSnapshot: mediaSnapshot.rebased(from: location, to: destination, makeRelative: true),
                          replacingExisting: false)
    }

    @MainActor
    func presentSave(in window: NSWindow?, canSave: ((URL) -> Bool)?) {
        let panel = ProjectPanels.cutSavePanel(name: name + ".cut")
        if !ProjectDraft.isManaged(location) {
            panel.directoryURL = location.resolvingSymlinksInPath().deletingLastPathComponent()
        }
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
