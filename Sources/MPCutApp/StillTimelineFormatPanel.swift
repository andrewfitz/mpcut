import AppKit
import MPCutCore

private final class StillContainerPicker: NSPopUpButton {
    @objc func updateFormats(_ codecPicker: NSPopUpButton) {
        guard let codec = codecPicker.titleOfSelectedItem.flatMap(ReencodeCodec.init(rawValue:)) else { return }
        let previous = titleOfSelectedItem
        let choices = StillTimelineFormat.containers(for: codec)
        removeAllItems()
        addItems(withTitles: choices)
        if let previous, choices.contains(previous) {
            selectItem(withTitle: previous)
        } else if choices.contains("mov") {
            selectItem(withTitle: "mov")
        }
    }
}

@MainActor
extension StillPanels {
    static func format(in window: NSWindow?, completion: @escaping (StillTimelineFormat, StillProgramColorPolicy) -> Void) {
        let width = NSTextField(string: "1920")
        width.toolTip = "Set canvas width"
        let height = NSTextField(string: "1080")
        height.toolTip = "Set canvas height"
        let rate = NSTextField(string: "30")
        rate.toolTip = "Set frame rate"
        let codecs = ReencodeCodec.allCases.map(\.rawValue)
        let codec = NSPopUpButton()
        codec.toolTip = "Choose video codec"
        codec.addItems(withTitles: codecs)
        let container = StillContainerPicker()
        container.toolTip = "Choose file format"
        codec.target = container
        codec.action = #selector(StillContainerPicker.updateFormats(_:))
        container.updateFormats(codec)
        let color = NSPopUpButton()
        color.toolTip = "Choose program color"
        color.addItems(withTitles: StillTimelineFormat.Color.allCases.map { $0.rawValue.uppercased() })
        present(title: "Still Timeline Format", fields: [
            ("Canvas width", width), ("Canvas height", height), ("Frames per second", rate),
            ("Video codec", codec), ("Container", container), ("Program color", color)
        ], in: window) {
            do {
                let fps = try RationalTime(parsing: rate.stringValue.trimmingCharacters(in: .whitespaces))
                guard let width = Int(width.stringValue.trimmingCharacters(in: .whitespaces)),
                      let height = Int(height.stringValue.trimmingCharacters(in: .whitespaces)),
                      let codec = codec.titleOfSelectedItem.flatMap(ReencodeCodec.init(rawValue:)),
                      let container = container.titleOfSelectedItem,
                      let color = color.titleOfSelectedItem.flatMap({ StillTimelineFormat.Color(rawValue: $0.lowercased()) }),
                      fps > .zero else {
                    throw CutError(code: "invalid_still_format", message: "Enter a canvas size and a positive frame rate.")
                }
                let format = StillTimelineFormat(width: width, height: height,
                                                 cadence: .init(numerator: fps.denominator, denominator: fps.numerator),
                                                 codec: codec, container: container)
                try format.validate(color: color.policy)
                completion(format, color.policy)
            } catch {
                ProjectPanels.present(NSAlert(error: error), in: window)
            }
        }
    }
}
