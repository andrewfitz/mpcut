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

/// What the Still Timeline Format panel opens with: Settings → Editing → New stills timeline.
struct StillTimelineFormatDefaults: Equatable {
    var width = 1920
    var height = 1080
    var frameRate = 30.0
    var codec = ReencodeCodec.h264

    init() {}

    @MainActor
    init(preferences: EditorPreferences) {
        width = preferences.stillTimelineWidth
        height = preferences.stillTimelineHeight
        frameRate = preferences.stillTimelineFrameRate
        codec = preferences.stillTimelineCodec
    }

    /// The frame rate as the panel's field shows it: "30", "29.97", "23.976".
    var frameRateText: String {
        guard frameRate.isFinite, frameRate > 0 else { return "30" }
        if frameRate.rounded() == frameRate { return String(Int(frameRate)) }
        var text = String(format: "%.3f", frameRate)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

@MainActor
extension StillPanels {
    static func format(defaults: StillTimelineFormatDefaults = .init(), in window: NSWindow?,
                       completion: @escaping (StillTimelineFormat, StillProgramColorPolicy) -> Void) {
        let width = NSTextField(string: String(defaults.width))
        width.toolTip = "Set canvas width"
        let height = NSTextField(string: String(defaults.height))
        height.toolTip = "Set canvas height"
        let rate = NSTextField(string: defaults.frameRateText)
        rate.toolTip = "Set frame rate"
        let codecs = ReencodeCodec.allCases.map(\.rawValue)
        let codec = NSPopUpButton()
        codec.toolTip = "Choose video codec"
        codec.addItems(withTitles: codecs)
        if codecs.contains(defaults.codec.rawValue) { codec.selectItem(withTitle: defaults.codec.rawValue) }
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
