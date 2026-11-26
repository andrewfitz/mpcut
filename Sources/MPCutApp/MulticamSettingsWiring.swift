import AppKit
import MPCutCore

// How the multicam editor reads the Settings defaults: starting folders, file names, completion actions,
// inserted still timing and the seconds played around a cut.

extension MulticamEditorModel {
    /// The frame counts an inserted still can take. Wide enough for the longest Settings duration at any cadence.
    static let stillFrameLimit: ClosedRange<Int64> = 1...Int64(Int32.max)

    /// The duration an inserted still starts with: the Settings duration, a whole number of frames at `cadence`.
    func defaultStillTiming(cadence: RationalTime?) -> (duration: RationalTime, cadence: RationalTime) {
        FrameAlignedDuration.duration(seconds: preferences.stillDuration, cadence: cadence, frames: Self.stillFrameLimit)
    }

    /// The seconds played before and after a cut, from Settings.
    var cutPreviewContext: (before: RationalTime, after: RationalTime) {
        func time(_ seconds: Double) -> RationalTime { timelineRationalTime(seconds) ?? RationalTime(numerator: 1) }
        return (time(preferences.cutPreviewPreroll), time(preferences.cutPreviewPostroll))
    }

    /// The name an export save panel suggests: the project's, as the window title shows it.
    func suggestedExportName(container: String) -> String {
        let stem = projectName ?? project?.angles.first.map { "\($0.displayName) Multicam" } ?? "Multicam"
        return stem + "." + container
    }

    /// The saved project file. Nil for an untitled project, whose document is a draft.
    private var savedProjectFile: URL? {
        projectURL.flatMap { ProjectDraft.isManaged($0) || draft.managesDestination($0) ? nil : $0 }
    }

    /// The recording an export of the whole program starts from: the opening camera.
    private var programSourceRecording: URL? {
        guard let project else { return nil }
        let source = project.sources.first { $0.id == project.referenceAngle } ?? project.sources.first
        guard let source else { return nil }
        return projectURL.map { project.sourceURL(for: source, relativeTo: $0) } ?? Self.availableURL(source)
    }

    /// The folder an export panel opens in. Automatic keeps the entry point's own rule: `automatic`, and `remembered`
    /// where the entry point already remembers its last folder. Any other Settings choice starts the session, and a
    /// folder chosen in a later panel of the session wins.
    func exportStartFolder(automatic: URL?, remembered: URL? = nil, sourceRecording: URL? = nil,
                           fileManager: FileManager = .default) -> URL? {
        let mode = preferences.exportStartFolder
        let chosen = preferences.exportStartFolderPath.isEmpty ? nil : URL(fileURLWithPath: preferences.exportStartFolderPath, isDirectory: true)
        return ExportStartFolder.resolve(mode: mode, chosenFolder: chosen, projectFile: savedProjectFile,
                                         sourceRecording: sourceRecording ?? programSourceRecording,
                                         sessionFolder: mode == .automatic ? remembered : exportSessionFolder,
                                         automatic: automatic, fileManager: fileManager).directory
    }

    /// Where the Resolve and project interchange panels open. They have no folder rule of their own, so Automatic leaves
    /// the folder to AppKit as before; any other Settings choice starts the session, and a folder chosen in a later panel
    /// of the session wins.
    var interchangeStartFolder: URL? { exportStartFolder(automatic: nil) }

    /// Records the folder an export panel chose, for the rest of this window's session.
    func noteExportFolder(_ folder: URL) {
        exportSessionFolder = folder.standardizedFileURL
    }

    /// Runs the Settings completion actions for a finished export and offers Show in Finder.
    func exportFinished(_ output: URL, title: String) {
        lastExportedURL = output
        (exportCompletion ?? .shared).exportFinished(output, title: title, reveal: preferences.revealsFinishedExport,
                                                     notify: preferences.notifiesFinishedExport,
                                                     playSound: preferences.playsFinishedExportSound)
    }

    func showExportInFinder() {
        guard let url = lastExportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension MulticamPauseEdits.Review {
    /// The Preview Join sheet's message, with the seconds the review plays.
    var joinMessage: String {
        func seconds(_ value: Double) -> String {
            value == 1 ? "one second"
                : value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))) + " seconds"
        }
        if before == after { return "Review up to \(seconds(before)) on each side of the join." }
        return "Review up to \(seconds(before)) before and \(seconds(after)) after the join."
    }
}
