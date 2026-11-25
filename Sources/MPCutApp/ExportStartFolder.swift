import Foundation

/// Chooses the folder an export save or open panel starts in.
enum ExportStartFolderMode: String, CaseIterable, Sendable {
    case automatic, project, source, chosen
}

struct ExportStartFolder: Equatable, Sendable {
    /// Nil leaves the panel at AppKit's own choice.
    let directory: URL?
    /// The chosen folder is set but missing or offline. Settings marks it unavailable.
    let chosenFolderUnavailable: Bool

    /// - Parameters:
    ///   - chosenFolder: the folder saved in Settings, used in `chosen` mode.
    ///   - projectFile: the saved project. Pass nil for an untitled project's draft.
    ///   - sourceRecording: the recording the export starts from.
    ///   - sessionFolder: the folder this window's session chose in an earlier panel. It always wins.
    ///   - automatic: the entry point's own rule, which every other mode falls back to.
    static func resolve(mode: ExportStartFolderMode, chosenFolder: URL?, projectFile: URL?,
                        sourceRecording: URL?, sessionFolder: URL?, automatic: URL?,
                        fileManager: FileManager = .default) -> ExportStartFolder {
        let unavailable = mode == .chosen && chosenFolder.map { !isAvailable($0, fileManager: fileManager) } == true
        if let sessionFolder { return .init(directory: sessionFolder, chosenFolderUnavailable: unavailable) }
        let preferred: URL? = switch mode {
        case .automatic: nil
        case .project: projectFile?.deletingLastPathComponent()
        case .source: sourceRecording?.deletingLastPathComponent()
        case .chosen: chosenFolder
        }
        guard let preferred, isAvailable(preferred, fileManager: fileManager) else {
            return .init(directory: automatic, chosenFolderUnavailable: unavailable)
        }
        return .init(directory: preferred, chosenFolderUnavailable: false)
    }

    /// For the Settings row: whether a saved folder can open now.
    static func isAvailable(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        var directory: ObjCBool = false
        return folder.isFileURL && fileManager.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue
    }
}

extension EditorPreferences {
    /// Settings → Export → Chosen folder, or nil when none is set.
    var chosenExportFolder: URL? {
        exportStartFolderPath.isEmpty ? nil : URL(fileURLWithPath: exportStartFolderPath, isDirectory: true)
    }
}

extension ExportStartFolder {
    /// `resolve` with the Settings mode and chosen folder. A project file inside the drafts folder counts as untitled.
    @MainActor
    static func resolve(_ preferences: EditorPreferences, projectFile: URL?, sourceRecording: URL?,
                        sessionFolder: URL?, automatic: URL?) -> ExportStartFolder {
        resolve(mode: preferences.exportStartFolder, chosenFolder: preferences.chosenExportFolder,
                projectFile: projectFile.flatMap { ProjectDraft.isManaged($0) ? nil : $0 },
                sourceRecording: sourceRecording, sessionFolder: sessionFolder, automatic: automatic)
    }
}
