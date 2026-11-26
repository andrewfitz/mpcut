import MPCutCore
import SwiftUI

struct SettingsMediaPage: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsForm(page: .media, preferences: preferences) {
            Section {
                Toggle(SettingsRow.watchMedia.title, isOn: $preferences.automaticallyRefreshMedia)
                    .settingsRow(.watchMedia)
                    .help("Watch the recordings in open projects and refresh a recording when its file changes.")
                Toggle(SettingsRow.sceneAutoScan.title, isOn: $preferences.autoScanScenes)
                    .settingsRow(.sceneAutoScan)
                    .help("Find scenes in each recording you add to a project.")
                Toggle(SettingsRow.silenceAutoScan.title, isOn: $preferences.autoScanSilence)
                    .settingsRow(.silenceAutoScan)
                    .help("Find pauses in each recording you add to a project.")
            } header: {
                Text("Media")
            } footer: {
                SettingsFootnote("Indexing, waveforms and thumbnails stay automatic. Automatic scans take time and cutcache space for every recording added.")
            }
            Section {
                SettingsNumericField(.minimumPause, value: $preferences.minimumPause,
                                     in: EditorPreferences.minimumPauseRange, step: 0.1, unit: "s",
                                     help: "Type the shortest quiet stretch that counts as a pause")
                SettingsNumericField(.maxBlip, value: $preferences.maxBlip, in: EditorPreferences.maxBlipRange, step: 0.02, unit: "s",
                                     help: "Type the longest sound between two quiet stretches that still counts as part of one pause",
                                     zeroMeaning: "Every sound ends a pause")
                SettingsNumericField(.padding, value: $preferences.padding, in: EditorPreferences.paddingRange, step: 0.05, unit: "s",
                                     help: "Type the silence to keep on each side of a cut")
            } header: {
                Text("Silence")
            } footer: {
                SettingsFootnote("These values apply to the desktop app. The CLI and file jobs take their own arguments.")
            }
            Section {
                Picker(SettingsRow.tilesLayout.title, selection: Binding(
                    get: { Self.shown(preferences.tilesScanLayout) },
                    set: { preferences.tilesScanLayout = $0 }
                )) {
                    ForEach(Self.layouts, id: \.self) { layout in
                        switch layout {
                        case .videoCall: Text("Video Call").tag(layout)
                        case .cameraMultiview: Text("Camera Multiview").tag(layout)
                        case .evenGrid: Text("Even Grid").tag(layout)
                        }
                    }
                }
                .settingsRow(.tilesLayout)
                // A pop-up with a single item seems broken, so it shows its one layout without opening.
                .disabled(Self.layouts.count < 2)
                .help(Self.layouts.count < 2 ? "This build offers Even Grid only: automatic meeting layout detection is unavailable."
                                             : "Choose the layout Find Tiles starts with for a recording with no saved layout.")
                SettingsNumericField(.tilesColumns, value: $preferences.tilesScanColumns, in: EditorPreferences.tilesGridRange, step: 1,
                                     help: "Type how many columns of tiles Find Tiles starts with for an even grid")
                SettingsNumericField(.tilesRows, value: $preferences.tilesScanRows, in: EditorPreferences.tilesGridRange, step: 1,
                                     help: "Type how many rows of tiles Find Tiles starts with for an even grid")
                Picker(SettingsRow.tilesDetail.title, selection: $preferences.tilesScanDetail) {
                    Text("Adaptive").tag(ParticipantSampling.adaptive)
                    Text("Every Frame").tag(ParticipantSampling.everyFrame)
                    Text("Sampled").tag(ParticipantSampling.sparse)
                }
                .settingsRow(.tilesDetail)
                .help("Choose how closely Find Tiles reads the recording: adaptive, every frame or sampled.")
            } header: {
                Text("Find Tiles")
            } footer: {
                SettingsFootnote(ParticipantAnalysis.isAvailable
                    ? "Applies to a recording with no saved layout. A scanned recording restores its own layout from the project."
                    : "Automatic meeting layout detection is unavailable, so Find Tiles offers Even Grid only. A scanned recording restores its own layout from the project.")
            }
            Section {
                SettingsNumericField(.dialogueHold, value: $preferences.dialogueMinimumHold, in: EditorPreferences.dialogueHoldRange,
                                     step: 0.25, unit: "s", help: "Type the shortest time dialogue switches hold a shot")
                Picker(SettingsRow.dialogueOverlap.title, selection: $preferences.dialogueOverlap) {
                    Text("Hold the Shot").tag(ParticipantDialogueOptions.Overlap.hold)
                    Text("Favor a Visible Speaker").tag(ParticipantDialogueOptions.Overlap.visibleSpeaker)
                }
                .settingsRow(.dialogueOverlap)
                .help("Choose which shot dialogue switches show while people talk over each other.")
                Picker(SettingsRow.dialogueOffscreen.title, selection: $preferences.dialogueOffscreen) {
                    Text("Hold the Shot").tag(ParticipantDialogueOptions.Offscreen.hold)
                    Text("Show Original Gallery").tag(ParticipantDialogueOptions.Offscreen.original)
                    Text("Show a Visible Reaction").tag(ParticipantDialogueOptions.Offscreen.reaction)
                }
                .settingsRow(.dialogueOffscreen)
                .help("Choose which shot dialogue switches show while the speaker has no tile.")
            } header: {
                Text("Dialogue switches")
            } footer: {
                SettingsFootnote("Dialogue switches start from these values. You can change them for each recording when you review the switches.")
            }
        }
    }

    /// The layouts this build offers.
    nonisolated static var layouts: [TilesScanLayout] { TilesScanLayout.allCases.filter(offered) }

    /// The layout the picker shows for a stored one: Even Grid for a layout this build does not offer.
    nonisolated static func shown(_ layout: TilesScanLayout) -> TilesScanLayout { offered(layout) ? layout : .evenGrid }

    /// A build without the required layout detectors has no Video Call or Camera Multiview layout. The stored value is kept for a build that has one.
    nonisolated static func offered(_ layout: TilesScanLayout) -> Bool {
        switch layout {
        case .videoCall: ParticipantAnalysis.isAvailable
        case .cameraMultiview: ParticipantAnalysis.supportsFeedLayouts
        case .evenGrid: true
        }
    }
}
