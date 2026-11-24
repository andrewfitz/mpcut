import AppKit
import MPCutCore
import UniformTypeIdentifiers

@MainActor
enum ResolveExportPanel {
    static func choose(name: String, in window: NSWindow?, accepted: @escaping (URL, Bool) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Project to DaVinci Resolve"
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = name + ".fcpxml"
        let open = NSButton(checkboxWithTitle: "Open timeline in the current Resolve project", target: nil, action: nil)
        open.toolTip = "Open timeline in Resolve"
        open.state = .on
        open.sizeToFit()
        panel.accessoryView = open
        ProjectPanels.present(panel, in: window) { ok in
            if ok, let url = panel.url { accepted(url, open.state == .on) }
        }
    }
}

extension MulticamEditorModel {
    func chooseResolveExport() {
        guard let project, !isBusy else { return }
        let location = projectURL ?? URL(fileURLWithPath: "/Untitled.cut")
        let imported = media
        ResolveExportPanel.choose(name: projectName ?? "Untitled Multicam", in: window) { output, open in
            do { try self.validateHistoryDestination(output) }
            catch { self.fail(error.localizedDescription); return }
            let checkingVolumes = self.interchangeCheckingVolumes
            self.run("Exporting Resolve timeline…", exporting: true) { token, useSidecar in
                try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                    try ResolveExport.write(project, relativeTo: location, to: output, useSidecar: useSidecar, matching: imported,
                                            cancelled: { token.isCancelled })
                }
                if open { try ResolveExport.openInResolve(output, cancelled: { token.isCancelled }) }
            } onSuccess: { self.status = "Exported \(output.lastPathComponent)." }
        }
    }
}
