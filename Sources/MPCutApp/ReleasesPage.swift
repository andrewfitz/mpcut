import AppKit

/// Help → Check for Updates… opens the releases page; MPCut itself never checks the network.
enum ReleasesPage {
    static let url = URL(string: "https://github.com/andrewfitz/mpcut/releases/latest")!

    @MainActor @discardableResult
    static func open(using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        opener(url)
    }
}
