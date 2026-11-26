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

    /// The cache limit's field, in gigabytes with up to three decimal places. Tests build it here too, so they see what
    /// the page shows.
    static func cacheLimitField(_ gigabytes: Binding<Double>) -> SettingsNumericField<Double> {
        SettingsNumericField(.cacheLimit, value: gigabytes, in: 0...cacheLimitMaximumGigabytes, step: 1, unit: "GB",
                             digits: cacheLimitDigits,
                             help: "Type the most space the shared cache folder may use, in gigabytes, with up to three decimal places",
                             zeroMeaning: "No limit")
    }

    var body: some View {
        SettingsForm(page: .storage, preferences: preferences) {
            SidecarStorageSettings(preferences: preferences, cacheContext: cacheContext)
            Section {
                Self.cacheLimitField(Binding(
                    get: { Self.cacheLimitGigabytes(preferences.sharedCacheLimitBytes) },
                    set: { preferences.sharedCacheLimitBytes = Self.cacheLimitBytes($0) }
                ))
                SettingsNumericField(.draftRetention, value: $preferences.draftRetentionDays, in: EditorPreferences.draftRetentionRange,
                                     step: 1, unit: "days", help: "Type how many days an untitled draft is kept",
                                     zeroMeaning: "Drafts are never removed")
            } header: {
                Text("Limits")
            } footer: {
                // What 0 means is shown under each field, so the footer does not repeat it.
                SettingsFootnote("The cache limit applies only to the shared cache folder on a cache disk. MPCut checks it at launch, when you change it and after it saves analysis, and removes the cutcaches written longest ago first, never one that an open project or its undo history needs. The command-line tool ignores the limit, so the folder can grow past it between runs. Drafts are checked at launch: expired drafts move to the Trash, and open or locked drafts stay.")
            }
            StorageUsageSection(preferences: preferences, locations: locations)
        }
    }
}
