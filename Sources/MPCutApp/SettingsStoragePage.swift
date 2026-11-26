import SwiftUI

struct SettingsStoragePage: View {
    @ObservedObject var preferences: EditorPreferences
    let cacheContext: @MainActor () -> SidecarClearContext
    /// The stores the usage list measures and clears. Tests pass temporary folders.
    var locations: StorageLocations = .standard
    private static let bytesPerGigabyte = 1_000_000_000.0
    /// The field's precision, a megabyte. A smaller nonzero limit shows as this, never as 0, which reads as no limit.
    static let cacheLimitDigits = 3
    static let cacheLimitMaximumGigabytes = 1_000_000.0

    /// The stored limit in gigabytes for the field. Showing it writes nothing; only an edit stores a value.
    static func cacheLimitGigabytes(_ bytes: Int) -> Double {
        guard bytes > 0 else { return 0 }
        let smallest = pow(10, -Double(cacheLimitDigits))
        return max(smallest, Double(bytes) / bytesPerGigabyte)
    }

    static func cacheLimitBytes(_ gigabytes: Double) -> Int {
        let bytes = (max(0, gigabytes) * bytesPerGigabyte).rounded()
        return bytes < Double(Int.max) ? Int(bytes) : Int.max
    }

    var body: some View {
        SettingsForm(page: .storage, preferences: preferences) {
            SidecarStorageSettings(preferences: preferences, cacheContext: cacheContext)
            Section {
                SettingsNumericField(.cacheLimit, value: Binding(
                    get: { Self.cacheLimitGigabytes(preferences.sharedCacheLimitBytes) },
                    set: { preferences.sharedCacheLimitBytes = Self.cacheLimitBytes($0) }
                ), in: 0...Self.cacheLimitMaximumGigabytes, step: 1, unit: "GB", digits: Self.cacheLimitDigits,
                   help: "Type the most space the shared cache folder may use, in gigabytes to three decimals",
                   rangeText: "0–\(Int(Self.cacheLimitMaximumGigabytes).formatted()) GB", zeroMeaning: "No limit")
                SettingsNumericField(.draftRetention, value: $preferences.draftRetentionDays, in: EditorPreferences.draftRetentionRange,
                                     step: 1, unit: "days", help: "Type how many days an untitled draft is kept",
                                     zeroMeaning: "Drafts are never removed")
            } header: {
                Text("Limits")
            } footer: {
                SettingsFootnote("A cache limit of 0 GB means no limit. It applies only to the shared cache folder, the MPCut Cache folder on a cache disk. MPCut checks it at launch, when it changes and after it saves analysis, removing the least recently written cutcaches first and never one an open project or its history uses. The CLI ignores it, so the folder can grow past the limit between runs. Removing drafts after 0 days means drafts stay until you save or discard them. Drafts are checked at launch: expired drafts move to the Trash, and open or locked drafts stay.")
            }
            StorageUsageSection(preferences: preferences, locations: locations)
        }
    }
}
