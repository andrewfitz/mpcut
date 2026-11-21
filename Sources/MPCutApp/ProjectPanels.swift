import AppKit

@MainActor
enum ProjectPanels {
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
