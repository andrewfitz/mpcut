import MPCutCore
import SwiftUI

struct SettingsMediaPage: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsForm(page: .media, preferences: preferences) {
            Section {
                Toggle(SettingsRow.watchMedia.title, isOn: $preferences.automaticallyRefreshMedia)
                    .settingsRow(.watchMedia)
                    .help("Refresh project media when a recording changes")
                Toggle(SettingsRow.sceneAutoScan.title, isOn: $preferences.autoScanScenes)
                    .settingsRow(.sceneAutoScan)
                    .help("Find scenes in each recording you add")
                Toggle(SettingsRow.silenceAutoScan.title, isOn: $preferences.autoScanSilence)
                    .settingsRow(.silenceAutoScan)
                    .help("Find pauses in each recording you add")
            } header: {
                Text("Media")
            } footer: {
                SettingsFootnote("Indexing, waveforms and thumbnails stay automatic. Automatic scans take time and cutcache space for every recording added.")
            }
            Section {
                SettingsNumericField(.minimumPause, value: $preferences.minimumPause,
                                     in: 1.0 / Double(AudioWaveform.rate)...Double.greatestFiniteMagnitude, step: 0.1, unit: "s")
                SettingsNumericField(.maxBlip, value: $preferences.maxBlip, in: 0...1, step: 0.02, unit: "s",
                                     help: "Count a brief sound between quiet stretches as part of one pause. Set to 0 to keep every interruption.")
                SettingsNumericField(.padding, value: $preferences.padding, in: 0...Double.greatestFiniteMagnitude, step: 0.05, unit: "s",
                                     help: "Silence to keep on each side of a cut.")
            } header: {
                Text("Silence")
            } footer: {
                SettingsFootnote("These values apply to the desktop app. The CLI and file jobs take their own arguments.")
            }
            Section {
                Picker(SettingsRow.tilesLayout.title, selection: Binding(
                    get: { Self.offered(preferences.tilesScanLayout) ? preferences.tilesScanLayout : .evenGrid },
                    set: { preferences.tilesScanLayout = $0 }
                )) {
                    ForEach(TilesScanLayout.allCases.filter(Self.offered), id: \.self) { layout in
                        switch layout {
                        case .videoCall: Text("Video Call").tag(layout)
                        case .cameraMultiview: Text("Camera Multiview").tag(layout)
                        case .evenGrid: Text("Even Grid").tag(layout)
                        }
                    }
                }
                .settingsRow(.tilesLayout)
                .help("Choose the Find Tiles layout for a recording with no saved layout")
                SettingsNumericField(.tilesColumns, value: $preferences.tilesScanColumns, in: EditorPreferences.tilesGridRange, step: 1)
                SettingsNumericField(.tilesRows, value: $preferences.tilesScanRows, in: EditorPreferences.tilesGridRange, step: 1)
                Picker(SettingsRow.tilesDetail.title, selection: $preferences.tilesScanDetail) {
                    Text("Adaptive").tag(ParticipantSampling.adaptive)
                    Text("Every Frame").tag(ParticipantSampling.everyFrame)
                    Text("Sampled").tag(ParticipantSampling.sparse)
                }
                .settingsRow(.tilesDetail)
                .help("Choose how closely Find Tiles reads the recording")
            } header: {
                Text("Find Tiles")
            } footer: {
                SettingsFootnote(ParticipantAnalysis.isAvailable
                    ? "Applies to a recording with no saved layout. A scanned recording restores its own layout from the project."
                    : "This build has no TileTrail meeting detector, so Find Tiles offers Even Grid only. A scanned recording restores its own layout from the project.")
            }
            Section("Dialogue switches") {
                SettingsNumericField(.dialogueHold, value: $preferences.dialogueMinimumHold, in: EditorPreferences.dialogueHoldRange,
                                     step: 0.25, unit: "s")
                Picker(SettingsRow.dialogueOverlap.title, selection: $preferences.dialogueOverlap) {
                    Text("Hold the Shot").tag(ParticipantDialogueOptions.Overlap.hold)
                    Text("Favor a Visible Speaker").tag(ParticipantDialogueOptions.Overlap.visibleSpeaker)
                }
                .settingsRow(.dialogueOverlap)
                .help("Choose the shot while people talk over each other")
                Picker(SettingsRow.dialogueOffscreen.title, selection: $preferences.dialogueOffscreen) {
                    Text("Hold the Shot").tag(ParticipantDialogueOptions.Offscreen.hold)
                    Text("Show Original Gallery").tag(ParticipantDialogueOptions.Offscreen.original)
                    Text("Show a Visible Reaction").tag(ParticipantDialogueOptions.Offscreen.reaction)
                }
                .settingsRow(.dialogueOffscreen)
                .help("Choose the shot while the speaker has no tile")
            }
        }
    }

    /// A build without TileTrail has no Video Call or Camera Multiview layout. The stored value is kept for a build that has one.
    static func offered(_ layout: TilesScanLayout) -> Bool {
        switch layout {
        case .videoCall: ParticipantAnalysis.isAvailable
        case .cameraMultiview: ParticipantAnalysis.supportsFeedLayouts
        case .evenGrid: true
        }
    }
}
