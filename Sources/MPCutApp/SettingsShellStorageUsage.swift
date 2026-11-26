import AppKit
import MPCutCore
import SwiftUI

/// The Storage page's usage list: sizes measured off the main actor, Show in Finder and Clear where the store table allows.
@MainActor
final class StorageUsageModel: ObservableObject {
    struct Report: Equatable {
        let kind: StoreKind
        let result: StoreClearResult
        /// What Clear left in the store's folders that it neither removed nor skipped: files MPCut does not recognize as
        /// its own, which the size still counts.
        var left = StoreLeftovers()
    }

    let locations: StorageLocations
    let preferences: EditorPreferences
    @Published private(set) var sizes: [StoreKind: Int64] = [:]
    /// Each store's first folder on disk, found off the main actor. A folder on a slow or offline volume never stalls a view.
    @Published private(set) var folders: [StoreKind: URL] = [:]
    /// Every store folder that existed at the last refresh.
    @Published private(set) var existing: Set<URL> = []
    @Published private(set) var clearing: StoreKind?
    @Published var report: Report?

    init(preferences: EditorPreferences, locations: StorageLocations) {
        self.preferences = preferences
        self.locations = locations
    }

    /// Counts refreshes, so a measurement that a later refresh overtook, such as one started before a Clear, is dropped.
    private var generation = 0

    /// Measures every store. Suggested cameras are measured from the value in memory, which is what Clear removes.
    func refresh() async {
        generation += 1
        let current = generation
        let locations = self.locations
        let existing = await Task.detached(priority: .utility) {
            Set(StoreKind.allCases.flatMap { locations.urls(for: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        }.value
        guard !Task.isCancelled, current == generation else { return }
        self.existing = existing
        folders = StoreKind.allCases.reduce(into: [StoreKind: URL]()) { found, kind in
            found[kind] = locations.urls(for: kind).first { existing.contains($0) }
        }
        for kind in StoreKind.allCases {
            guard !Task.isCancelled, current == generation else { return }
            if kind == .suggestedCameras {
                sizes[kind] = Int64(preferences.transcriptSuggestedAngles.count)
            } else if let bytes = try? await StorageInventory.size(of: kind, locations: locations, defaults: nil),
                      current == generation {
                sizes[kind] = bytes
            }
        }
    }

    /// The folder Show in Finder reveals: the store's first folder on disk, as of the last refresh.
    func folder(for kind: StoreKind) -> URL? { folders[kind] }

    /// Clears a store the table allows and reports what was reclaimed and skipped. Others do nothing.
    @discardableResult
    func clear(_ kind: StoreKind) async -> StoreClearResult? {
        guard kind.clearable, clearing == nil else { return nil }
        clearing = kind
        // A measurement still running from before the Clear would show the old size when it finished.
        generation += 1
        defer { clearing = nil }
        var result: StoreClearResult
        var left = StoreLeftovers()
        if kind == .suggestedCameras {
            // Through the shared preferences, so open windows forget the suggestions too.
            result = StoreClearResult()
            result.reclaimedBytes = Int64(preferences.transcriptSuggestedAngles.count)
            preferences.transcriptSuggestedAngles = Data()
        } else {
            result = await StorageInventory.clear(kind, locations: locations, defaults: nil)
            let folders = locations.urls(for: kind)
            let cleared = result
            left = await Task.detached(priority: .utility) { StoreLeftovers.find(in: folders, after: cleared) }.value
        }
        report = Report(kind: kind, result: result, left: left)
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
            SettingsFootnote("Each size counts everything in the store’s folder, including files MPCut did not write. Clear asks first, removes only MPCut’s own entries and skips anything in use, and says what it left.")
        }
        .task { await model.refresh() }
        .confirmationDialog(confirming.map { "Clear \($0.title.lowercased())?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { kind in
            Button("Clear", role: .destructive) { Task { await model.clear(kind) } }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(Self.confirmation(kind, size: model.sizes[kind]))
        }
        .alert(model.report.map(Self.title) ?? "",
               isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } }),
               presenting: model.report) { _ in
            Button("OK") { model.report = nil }
        } message: { report in
            Text(Self.summary(report.result, left: report.left))
        }
    }

    private func row(_ kind: StoreKind) -> some View {
        let folder = model.folder(for: kind)
        let paths = model.locations.urls(for: kind)
        let id = "settings.storage.usage." + kind.rawValue
        let measured = model.sizes[kind]
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                Text(measured.map { Self.shownSize($0, of: kind) } ?? "Measuring…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(id + ".size")
                // Two fixed columns, Show in Finder then Clear…, so the buttons line up down the list. A store without one
                // keeps its place with a hidden copy.
                HStack(spacing: 6) {
                    Button("Show in Finder") { if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
                        .disabled(folder == nil)
                        .help(folder == nil ? "The folder does not exist yet. MPCut creates it when it first needs it."
                                            : "Show the \(kind.title.lowercased()) folder in Finder.")
                        .accessibilityLabel("Show \(kind.title.lowercased()) in Finder")
                        .accessibilityIdentifier(id + ".show")
                        .opacity(paths.isEmpty ? 0 : 1)
                        .accessibilityHidden(paths.isEmpty)
                        .allowsHitTesting(!paths.isEmpty)
                    Button("Clear…") { confirming = kind }
                        .disabled(!kind.clearable || model.clearing != nil || (measured ?? 0) == 0)
                        .help(clearHelp(kind, measured: measured))
                        .accessibilityLabel("Clear \(kind.title.lowercased())")
                        .accessibilityIdentifier(id + ".clear")
                        .opacity(kind.clearable ? 1 : 0)
                        .accessibilityHidden(!kind.clearable)
                        .allowsHitTesting(kind.clearable)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if paths.isEmpty {
                    Text(kind.storageDescription).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(paths.enumerated()), id: \.element) { index, url in
                        // The whole path, wrapping onto more lines under the store's name rather than losing its middle.
                        // A store with several folders numbers their identifiers: ".path.1", ".path.2".
                        let pathID = id + ".path" + (paths.count > 1 ? ".\(index + 1)" : "")
                        SettingsPathText(path: url.path, alignment: .leading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(pathID)
                        // A text of its own, so selecting the path never copies it.
                        if !model.sizes.isEmpty, !model.existing.contains(url) {
                            Text("Not created yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(pathID + ".status")
                        }
                    }
                }
            }
        }
    }

    /// Why Clear… is unavailable, or what it does.
    private func clearHelp(_ kind: StoreKind, measured: Int64?) -> String {
        if model.clearing != nil { return "Wait for the current Clear to finish." }
        guard let measured else { return "Wait until MPCut has measured \(kind.title.lowercased())." }
        if measured == 0 { return "There is nothing to clear." }
        return "Remove \(kind.title.lowercased()) MPCut can do without. MPCut asks first."
    }

    /// A store's size as the list shows it. Suggested cameras live in MPCut's preferences, where nothing reads as a size.
    static func shownSize(_ bytes: Int64, of kind: StoreKind) -> String {
        kind == .suggestedCameras && bytes == 0 ? "None" : SettingsPath.size(bytes)
    }

    /// A byte count for the page and its messages, written "0 KB" rather than "Zero KB".
    static func size(_ bytes: Int64) -> String { SettingsPath.size(bytes) }

    /// The Clear dialog's message: how much the store holds, then what Clear leaves.
    static func confirmation(_ kind: StoreKind, size: Int64?) -> String {
        guard let size, size > 0 else { return kind.note }
        return "It holds \(shownSize(size, of: kind)). " + kind.note
    }

    /// The alert's title says whether anything was removed; its message gives only the details, so neither repeats the other.
    static func title(_ report: StorageUsageModel.Report) -> String {
        removedAnything(report.result) ? "Cleared \(report.kind.title.lowercased())"
                                       : "Nothing removed from \(report.kind.title.lowercased())"
    }

    private static func removedAnything(_ result: StoreClearResult) -> Bool {
        result.reclaimedBytes > 0 || !result.removed.isEmpty
    }

    private static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    /// The bytes reclaimed; every item Clear skipped, with its reason; and what it left because MPCut does not recognize it
    /// as its own. That nothing was removed is the title's to say, so it is not said again here.
    static func summary(_ result: StoreClearResult, left: StoreLeftovers = StoreLeftovers()) -> String {
        var text = removedAnything(result) ? "Reclaimed \(size(result.reclaimedBytes))." : ""
        if !result.skipped.isEmpty {
            if !text.isEmpty { text += " " }
            text += "Left \(items(result.skipped.count)) in use or still needed:"
            for skip in result.skipped.prefix(10) { text += "\n\(skip.url.lastPathComponent): \(skip.reason)" }
            if result.skipped.count > 10 { text += "\n…and \(result.skipped.count - 10) more." }
        }
        if left.count > 0 {
            if !result.skipped.isEmpty { text += "\n" } else if !text.isEmpty { text += " " }
            text += "Left \(items(left.count)) (\(size(left.bytes))) that MPCut does not recognize as its own. "
                + "Remove \(left.count == 1 ? "it" : "them") in Finder if you no longer need \(left.count == 1 ? "it" : "them")."
        }
        return text
    }
}

/// Files Clear neither removed nor skipped, found by walking a store's folders afterwards. Folders themselves, such as
/// the stills cache's shard folders, are MPCut's and do not count.
struct StoreLeftovers: Equatable, Sendable {
    var count = 0
    var bytes: Int64 = 0

    static func find(in folders: [URL], after result: StoreClearResult) -> StoreLeftovers {
        let skipped = result.skipped.map { $0.url.standardizedFileURL.path }
        func coveredBySkip(_ path: String) -> Bool {
            let stem = (path as NSString).deletingPathExtension
            return skipped.contains { path == $0 || path.hasPrefix($0 + "/") || stem == $0 }
        }
        var left = StoreLeftovers()
        for folder in folders {
            guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in walk {
                let path = url.standardizedFileURL.path
                if coveredBySkip(path) {
                    walk.skipDescendants()
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                left.count += 1
                left.bytes += (try? StoreMeasurement.allocatedBytes(at: url)) ?? 0
            }
        }
        return left
    }
}
