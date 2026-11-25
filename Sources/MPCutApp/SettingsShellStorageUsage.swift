import AppKit
import MPCutCore
import SwiftUI

/// The Storage page's usage list: sizes measured off the main actor, Show in Finder and Clear where the store table allows.
@MainActor
final class StorageUsageModel: ObservableObject {
    struct Report: Equatable {
        let kind: StoreKind
        let result: StoreClearResult
    }

    let locations: StorageLocations
    let preferences: EditorPreferences
    @Published private(set) var sizes: [StoreKind: Int64] = [:]
    @Published private(set) var clearing: StoreKind?
    @Published var report: Report?

    init(preferences: EditorPreferences, locations: StorageLocations) {
        self.preferences = preferences
        self.locations = locations
    }

    /// Measures every store. Suggested cameras are measured from the value in memory, which is what Clear removes.
    func refresh() async {
        for kind in StoreKind.allCases {
            if Task.isCancelled { return }
            if kind == .suggestedCameras {
                sizes[kind] = Int64(preferences.transcriptSuggestedAngles.count)
            } else if let bytes = try? await StorageInventory.size(of: kind, locations: locations, defaults: nil) {
                sizes[kind] = bytes
            }
        }
    }

    /// The folder Show in Finder reveals: the store's first folder on disk.
    func folder(for kind: StoreKind) -> URL? {
        locations.urls(for: kind).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Clears a store the table allows and reports what was reclaimed and skipped. Others do nothing.
    @discardableResult
    func clear(_ kind: StoreKind) async -> StoreClearResult? {
        guard kind.clearable, clearing == nil else { return nil }
        clearing = kind
        defer { clearing = nil }
        var result: StoreClearResult
        if kind == .suggestedCameras {
            // Through the shared preferences, so open windows forget the suggestions too.
            result = StoreClearResult()
            result.reclaimedBytes = Int64(preferences.transcriptSuggestedAngles.count)
            preferences.transcriptSuggestedAngles = Data()
        } else {
            result = await StorageInventory.clear(kind, locations: locations, defaults: nil)
        }
        report = Report(kind: kind, result: result)
        await refresh()
        return result
    }
}

struct StorageUsageSection: View {
    @StateObject private var model: StorageUsageModel
    @State private var confirming: StoreKind?

    init(preferences: EditorPreferences, locations: StorageLocations) {
        _model = StateObject(wrappedValue: StorageUsageModel(preferences: preferences, locations: locations))
    }

    var body: some View {
        Section {
            ForEach(StoreKind.allCases, id: \.self) { kind in
                row(kind)
            }
        } header: {
            Text(SettingsRow.storageUsage.title).settingsRow(.storageUsage)
        } footer: {
            SettingsFootnote("Sizes are the space each store uses now. Clear asks first and skips anything in use.")
        }
        .task { await model.refresh() }
        .confirmationDialog(confirming.map { "Clear \($0.title.lowercased())?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { kind in
            Button("Clear", role: .destructive) { Task { await model.clear(kind) } }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(kind.note)
        }
        .alert(model.report.map { "Cleared \($0.kind.title.lowercased())" } ?? "",
               isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } }),
               presenting: model.report) { _ in
            Button("OK") { model.report = nil }
        } message: { report in
            Text(Self.summary(report.result))
        }
    }

    private func row(_ kind: StoreKind) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(model.sizes[kind].map(Self.size) ?? "Measuring…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let folder = model.folder(for: kind) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .help("Show \(kind.title.lowercased()) in Finder")
                        .accessibilityLabel("Show \(kind.title) in Finder")
                }
                if kind.clearable {
                    Button("Clear…") { confirming = kind }
                        .disabled(model.clearing != nil || model.sizes[kind] == 0)
                        .help("Clear \(kind.title.lowercased())")
                        .accessibilityLabel("Clear \(kind.title)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("settings.storage.usage." + kind.rawValue)
    }

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "Zero KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The bytes reclaimed and every item Clear skipped, with its reason.
    static func summary(_ result: StoreClearResult) -> String {
        var text = "Reclaimed \(size(result.reclaimedBytes))."
        if !result.skipped.isEmpty {
            text += " Skipped \(result.skipped.count) in use:"
            for skip in result.skipped.prefix(10) { text += "\n\(skip.url.lastPathComponent): \(skip.reason)" }
            if result.skipped.count > 10 { text += "\n…and \(result.skipped.count - 10) more." }
        }
        return text
    }
}
