import SwiftUI

struct SettingsStoragePage: View {
    @ObservedObject var preferences: EditorPreferences
    let cacheContext: @MainActor () -> SidecarClearContext
    /// The stores the usage list measures and clears. Tests pass temporary folders.
    var locations: StorageLocations = .standard
    private static let bytesPerGigabyte = 1_000_000_000

    var body: some View {
        SettingsForm(page: .storage, preferences: preferences) {
            SidecarStorageSettings(preferences: preferences, cacheContext: cacheContext)
            Section {
                SettingsNumericField(.cacheLimit, value: Binding(
                    get: { preferences.sharedCacheLimitBytes / Self.bytesPerGigabyte },
                    set: { preferences.sharedCacheLimitBytes = $0 * Self.bytesPerGigabyte }
                ), in: 0...1_000_000, step: 1, unit: "GB")
                SettingsNumericField(.draftRetention, value: $preferences.draftRetentionDays, in: EditorPreferences.draftRetentionRange,
                                     step: 1, unit: "days")
            } header: {
                Text("Limits")
            } footer: {
                SettingsFootnote("0 is no limit and never. The limit applies only to the managed MPCut Cache folder on a cache disk. MPCut checks it at launch, when it changes and after it saves analysis, removing the least recently written cutcaches first and never one an open project or its history uses. The CLI ignores it, so the folder can grow past the limit between runs. Drafts are checked at launch: expired drafts move to the Trash, and open or locked drafts stay.")
            }
            StorageUsageSection(preferences: preferences, locations: locations)
        }
    }
}
