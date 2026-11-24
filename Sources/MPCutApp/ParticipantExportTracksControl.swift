import AppKit
import MPCutCore
import UniformTypeIdentifiers

@MainActor
final class ParticipantExportTracksControl: NSObject {
    private weak var panel: NSSavePanel?
    private let picker = NSPopUpButton()

    var tracks: ExportTracks {
        switch picker.indexOfSelectedItem {
        case 1: .video
        case 2: .audio
        default: .all
        }
    }

    init(panel: NSSavePanel, allowsAudioOnly: Bool) {
        self.panel = panel
        super.init()
        picker.addItems(withTitles: ["Picture and Audio", "Video Only"])
        if allowsAudioOnly { picker.addItem(withTitle: "Audio Only") }
        picker.target = self
        picker.action = #selector(updatePanel)
        picker.setAccessibilityLabel("Output Tracks")
        let row = NSStackView(views: [NSTextField(labelWithString: "Tracks"), picker])
        row.orientation = .horizontal
        row.spacing = 8
        row.frame.size = row.fittingSize
        panel.accessoryView = row
    }

    @objc private func updatePanel() {
        guard let panel else { return }
        let filename = panel.nameFieldStringValue as NSString
        panel.allowedContentTypes = tracks == .audio ? [.wav] : [.quickTimeMovie]
        panel.nameFieldStringValue = filename.deletingPathExtension + (tracks == .audio ? ".wav" : ".mov")
    }
}
