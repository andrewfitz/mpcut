import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let mpcutProject = UTType(exportedAs: "com.mpcut.project", conformingTo: .json)
}

@MainActor
enum ProjectPanels {
    static func cutSavePanel(name: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Save MPCut Project"
        panel.allowedContentTypes = [.mpcutProject]
        panel.nameFieldStringValue = name
        return panel
    }

    static func present(_ panel: NSSavePanel, in window: NSWindow?, fromSheet: Bool = false,
                        completion: @escaping (Bool) -> Void) {
        guard let window else {
            panel.begin { completion($0 == .OK) }
            return
        }
        let owner = fromSheet ? window.attachedSheet ?? window : window
        guard owner.attachedSheet == nil else {
            completion(false)
            return
        }
        panel.beginSheetModal(for: owner) { completion($0 == .OK) }
    }

    static func present(_ alert: NSAlert, in window: NSWindow?) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
