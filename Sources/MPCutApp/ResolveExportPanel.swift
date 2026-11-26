import AppKit
import MPCutCore
import UniformTypeIdentifiers

@MainActor
enum ResolveExportPanel {
    /// - Parameters:
    ///   - directory: the folder the panel opens in. Nil leaves it to AppKit.
    ///   - opensTimeline: the checkbox's starting state, Settings → Export → Open the timeline in Resolve after sending.
    static func choose(name: String, directory: URL? = nil, opensTimeline: Bool = true, in window: NSWindow?,
                       accepted: @escaping (URL, Bool) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Project to DaVinci Resolve"
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = name + ".fcpxml"
        if let directory { panel.directoryURL = directory }
        let open = openCheckbox(opensTimeline)
        panel.accessoryView = open
        ProjectPanels.present(panel, in: window) { ok in
            if ok, let url = panel.url { accepted(url, open.state == .on) }
        }
    }

    static func openCheckbox(_ isOn: Bool) -> NSButton {
        let open = NSButton(checkboxWithTitle: "Open timeline in the current Resolve project", target: nil, action: nil)
        open.toolTip = "Open timeline in Resolve"
        open.state = isOn ? .on : .off
        open.sizeToFit()
        return open
    }
}

extension MulticamEditorModel {
    func chooseResolveExport() {
        guard let project, !isBusy else { return }
        let location = projectURL ?? URL(fileURLWithPath: "/Untitled.cut")
        let imported = media
        ResolveExportPanel.choose(name: projectName ?? "Untitled Multicam", directory: interchangeStartFolder,
                                  opensTimeline: preferences.opensResolveTimeline, in: window) { output, open in
            do { try self.validateHistoryDestination(output) }
            catch { self.fail(error.localizedDescription); return }
            self.noteExportFolder(output.deletingLastPathComponent())
            let checkingVolumes = self.interchangeCheckingVolumes
            self.run("Exporting Resolve timeline…", exporting: true) { token, useSidecar in
                let awake = SleepPrevention(reason: "Exporting from MPCut")
                defer { awake.end() }
                // What the timeline gives up in FCPXML: rounded cuts, replaced name characters, narrowed sound.
                let warnings = try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                    try ResolveExport.write(project, relativeTo: location, to: output, useSidecar: useSidecar, matching: imported,
                                            cancelled: { token.isCancelled })
                }
                if open { try ResolveExport.openInResolve(output, cancelled: { token.isCancelled }) }
                return warnings
            } onSuccess: { warnings in
                self.status = (["Exported \(output.lastPathComponent)."] + warnings).joined(separator: " ")
                self.exportFinished(output, title: "Resolve timeline sent")
            }
        }
    }
}
