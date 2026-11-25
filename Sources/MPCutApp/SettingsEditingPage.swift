import MPCutCore
import SwiftUI

struct SettingsEditingPage: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsForm(page: .editing, preferences: preferences) {
            Section {
                SnapTargetPicker(selection: $preferences.snapTarget)
                    .settingsRow(.snapTarget)
                Toggle(SettingsRow.sourceTicks.title, isOn: $preferences.sourceTimeTicks)
                    .settingsRow(.sourceTicks)
                    .help("Show the original recording time inside each clip.")
                Toggle(SettingsRow.largePreviews.title, isOn: $preferences.largeThumbnails)
                    .settingsRow(.largePreviews)
                    .help("Enlarge timeline previews")
                Toggle(SettingsRow.cutSections.title, isOn: $preferences.showsCutSections)
                    .settingsRow(.cutSections)
                    .help("Start new windows with cut sections showing")
                Picker(SettingsRow.timeDisplay.title, selection: $preferences.timeDisplay) {
                    Text("Milliseconds").tag(TimelineTimeDisplay.milliseconds)
                    Text("Frames").tag(TimelineTimeDisplay.frames)
                }
                .settingsRow(.timeDisplay)
                .help("Show times as milliseconds or frames")
            } header: {
                Text("Timeline")
            } footer: {
                SettingsFootnote("Frames count at the timeline’s cadence and fall back to milliseconds for audio-only timelines.")
            }
            Section {
                Picker(SettingsRow.panelPosition.title, selection: $preferences.fullHeightSidebar) {
                    Text("Above timeline").tag(false)
                    Text("Full height").tag(true)
                }
                .settingsRow(.panelPosition)
                .help("Place the transcript and Tiles panel above the timeline or beside it")
                SettingsNumericField(.trackLabelWidth, value: $preferences.trackLabelWidth,
                                     in: EditorPreferences.trackLabelWidthRange, step: 1, unit: "pt", digits: 0)
            } header: {
                Text("Layout")
            } footer: {
                SettingsFootnote("Each window fits the track label width to its own space.")
            }
            Section("Stills and gaps") {
                SettingsNumericField(.stillDuration, value: $preferences.stillDuration, in: EditorPreferences.stillDurationRange,
                                     step: 0.5, unit: "s")
                SettingsNumericField(.gapDuration, value: $preferences.gapDuration, in: EditorPreferences.stillDurationRange,
                                     step: 0.5, unit: "s")
                ColorPicker(SettingsRow.gapColor.title, selection: Binding(
                    get: { Color(hex: preferences.gapColor) },
                    set: { preferences.gapColor = $0.hexRGB ?? preferences.gapColor }
                ), supportsOpacity: false)
                .settingsRow(.gapColor)
                .help("Choose the starting color of Insert Color Gap and Space Clips")
            }
            Section {
                SettingsNumericField(.stillTimelineWidth, value: $preferences.stillTimelineWidth,
                                     in: EditorPreferences.stillTimelinePixelRange, step: 2, unit: "px")
                SettingsNumericField(.stillTimelineHeight, value: $preferences.stillTimelineHeight,
                                     in: EditorPreferences.stillTimelinePixelRange, step: 2, unit: "px")
                SettingsNumericField(.stillTimelineFrameRate, value: $preferences.stillTimelineFrameRate,
                                     in: EditorPreferences.stillTimelineFrameRateRange, step: 1, unit: "fps", digits: 3)
                Picker(SettingsRow.stillTimelineCodec.title, selection: $preferences.stillTimelineCodec) {
                    ForEach(EditorPreferences.stillTimelineCodecs, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.stillTimelineCodec)
                .help("Choose the codec of a new stills timeline")
            } header: {
                Text("New stills timeline")
            } footer: {
                SettingsFootnote("Width and height are even. The container stays MOV and program color stays SDR.")
            }
        }
    }
}

extension Color {
    /// A `#RRGGBB` color. Anything else is black.
    init(hex: String) {
        let value = EditorPreferences.hexColor(hex).flatMap { UInt32($0.dropFirst(), radix: 16) } ?? 0
        self.init(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexRGB: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", min(255, max(0, $0))) }.joined()
    }
}
