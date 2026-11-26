import AppKit
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

enum ExternalProjectFormat: String, CaseIterable {
    case resolve = "drp"
    case resolveTimeline = "drt"
    case premiere = "prproj"
    case finalCut = "fcpbundle"
    case finalCutXML = "fcpxml"
    case finalCutXMLBundle = "fcpxmld"

    var title: String {
        switch self {
        case .resolve: "DaVinci Resolve Project"
        case .resolveTimeline: "DaVinci Resolve Timeline"
        case .premiere: "Adobe Premiere Pro Project"
        case .finalCut: "Final Cut Pro Library"
        case .finalCutXML: "Final Cut Pro XML"
        case .finalCutXMLBundle: "Final Cut Pro XML Bundle"
        }
    }

    var isPackage: Bool { self == .finalCut || self == .finalCutXMLBundle }

    var contentType: UTType { UTType(filenameExtension: rawValue) ?? .data }
}

private final class PremiereFlattenOption: NSButton {
    @objc func updateApproval(_ loss: NSButton) {
        isEnabled = loss.state == .on
        if !isEnabled { state = .off }
    }
}

@MainActor
extension ProjectSessions {
    func chooseExternalImport(in session: ProjectSession?, using action: OpenWindowAction) {
        setWindowOpener(action)
        let panel = NSOpenPanel()
        panel.title = "Import Project"
        panel.allowedContentTypes = ExternalProjectFormat.allCases.map(\.contentType)
        panel.treatsFilePackagesAsDirectories = false
        // Native libraries and XML bundles are directories when their host is absent.
        panel.canChooseDirectories = true
        let loss = Self.lossOption(in: panel)
        ProjectPanels.present(panel, in: session?.window) { accepted in
            guard accepted, let input = panel.url else { return }
            let allowLoss = loss.state == .on
            let outputPanel = ProjectPanels.cutSavePanel(name: input.deletingPathExtension().lastPathComponent + ".cut")
            outputPanel.title = "Save Imported MPCut Project"
            Task { @MainActor in
                ProjectPanels.present(outputPanel, in: session?.window) { accepted in
                    guard accepted, let output = outputPanel.url else { return }
                    self.convert(in: session, output: output, imported: true) { token in
                        try ProjectConverter.convert(input: input, output: output, allowLoss: allowLoss, cancelled: { token.isCancelled })
                    }
                }
            }
        }
    }

    func chooseExternalExport(_ format: ExternalProjectFormat, in session: ProjectSession) {
        let panel = NSSavePanel()
        panel.title = "Export " + format.title
        let name = session.isMulticam ? session.multicam.projectName : session.editor.projectURL?.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = (name ?? "Untitled") + "." + format.rawValue
        panel.allowedContentTypes = [format.contentType]
        // Project interchange has no folder rule of its own, so only Settings' starting folder and the session's folder apply.
        if session.isMulticam {
            if let start = session.multicam.interchangeStartFolder { panel.directoryURL = start }
        } else if let start = session.editor.exportPanelDirectory(source: session.editor.firstSourceURL, hasAutomaticRule: false) {
            panel.directoryURL = start
        }
        let loss = Self.lossOption(in: panel)
        let flatten: PremiereFlattenOption?
        if format == .premiere && session.isMulticam {
            let option = PremiereFlattenOption(checkboxWithTitle: "Flatten multicam for Premiere round trip", target: nil, action: nil)
            option.toolTip = "Flatten multicam to clips"
            option.updateApproval(loss)
            loss.target = option
            loss.action = #selector(PremiereFlattenOption.updateApproval(_:))
            let options = NSStackView(views: [loss, option])
            options.orientation = .vertical
            options.alignment = .leading
            options.setFrameSize(options.fittingSize)
            panel.accessoryView = options
            flatten = option
        } else {
            flatten = nil
        }
        ProjectPanels.present(panel, in: session.window) { accepted in
            guard accepted, let output = panel.url else { return }
            let snapshot: CutProject
            do {
                if session.isMulticam {
                    guard let project = session.multicam.project else { return }
                    try session.multicam.validateHistoryDestination(output, includesContents: format.isPackage)
                    snapshot = .multicam(project)
                } else {
                    try session.editor.validateHistoryDestination(output, includesContents: format.isPackage)
                    snapshot = session.editor.transcriptProject
                }
            } catch {
                ProjectPanels.present(NSAlert(error: error), in: session.window)
                return
            }
            let exclusions = session.isMulticam ? session.multicam.sidecarExclusions : session.editor.sidecarExclusions
            let checkingVolumes = session.isMulticam ? session.multicam.interchangeCheckingVolumes : session.editor.interchangeCheckingVolumes
            if session.isMulticam {
                session.multicam.noteExportFolder(output.deletingLastPathComponent())
            } else {
                session.editor.noteExportFolder(output.deletingLastPathComponent(), hasAutomaticRule: false)
            }
            let allowLoss = loss.state == .on
            let flattenMulticam = allowLoss && flatten?.state == .on
            // Unsaved desktop projects already retain absolute paths for all working media.
            let input = (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL) ?? output
            let mediaSnapshot = session.isMulticam ? session.multicam.projectMediaSnapshotForWriting : session.editor.projectMediaSnapshotForWriting
            self.convert(in: session, output: output, imported: false) { token in
                try AnalysisSidecar.$excludedSources.withValue(exclusions) {
                    try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                        try ProjectConverter.write(snapshot, relativeTo: input, to: output, mediaSnapshot: mediaSnapshot, allowLoss: allowLoss,
                                                   flattenMulticam: flattenMulticam, cancelled: { token.isCancelled })
                    }
                }
            }
        }
    }

    private static func lossOption(in panel: NSSavePanel) -> NSButton {
        let option = NSButton(checkboxWithTitle: "Allow conversion with reported losses", target: nil, action: nil)
        option.state = .off
        option.toolTip = "Permit reported conversion losses"
        option.sizeToFit()
        panel.accessoryView = option
        return option
    }

    private func convert(in session: ProjectSession?, output: URL, imported: Bool,
                         operation: @escaping @Sendable (EditCancellation) throws -> [String]) {
        guard !isConvertingProject else {
            let alert = NSAlert()
            alert.messageText = "A project conversion is already running."
            ProjectPanels.present(alert, in: session?.window)
            return
        }
        let token = EditCancellation()
        conversionOwner = session?.mcpHandle
        projectConversion = token
        let sidecarWork = session?.sidecarWork ?? ProjectSidecarWork(project: nil)
        let awake = imported ? nil : SleepPrevention(reason: "Exporting from MPCut")
        Task {
            defer {
                awake?.end()
                finishProjectConversion()
            }
            do {
                let warnings = try await sidecarWork.detached(priority: .userInitiated) { try operation(token) }.value
                guard conversionDidFinish == nil else { return }
                let target = session.flatMap { sessions[$0.id] === $0 ? $0 : nil }
                if imported { openFiles([output], in: target) }
                if !imported { ExportCompletion.runActions(for: output, preferences: preferences) }
                // Warnings always show. Settings → General can turn off the message for a clean project export.
                if !warnings.isEmpty || (!imported && preferences.showsProjectExportMessage) {
                    let alert = NSAlert()
                    alert.messageText = (imported ? "Imported " : "Exported ") + output.lastPathComponent
                    alert.informativeText = warnings.joined(separator: "\n")
                    ProjectPanels.present(alert, in: (imported ? project(at: output) : target)?.window)
                }
            } catch {
                guard conversionDidFinish == nil else { return }
                if token.isCancelled, (error as? CutError)?.code == "cancelled" { return }
                ProjectPanels.present(NSAlert(error: error), in: session?.window)
            }
        }
    }
}
