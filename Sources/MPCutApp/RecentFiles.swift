import Foundation
import SwiftUI

@MainActor
final class RecentFiles: ObservableObject {
    private static let key = "recent_file_paths"
    private let defaults: UserDefaults?
    /// Settings → General → Recent items.
    private(set) var limit: Int
    @Published private(set) var urls: [URL]

    init(defaults: UserDefaults?, limit: Int = 10) {
        self.defaults = defaults
        self.limit = max(1, limit)
        urls = (defaults?.stringArray(forKey: Self.key) ?? []).prefix(max(1, limit)).map { URL(fileURLWithPath: $0) }
    }

    /// A lower limit trims the list. `persisting` false trims only what the menu shows.
    func applyLimit(_ newLimit: Int, persisting: Bool) {
        limit = max(1, newLimit)
        guard urls.count > limit else { return }
        let trimmed = Array(urls.prefix(limit))
        if persisting { update(trimmed) } else { urls = trimmed }
    }

    func record(_ files: [URL]) {
        var seen = Set<URL>()
        var recent: [URL] = []
        for file in files + urls where file.isFileURL {
            let url = file.standardizedFileURL
            if seen.insert(url).inserted { recent.append(url) }
            if recent.count == limit { break }
        }
        update(recent)
    }

    func clear() { update([]) }

    private func update(_ recent: [URL]) {
        guard urls != recent else { return }
        urls = recent
        defaults?.set(recent.map(\.path), forKey: Self.key)
    }
}

struct RecentFilesMenu: View {
    @ObservedObject var files: RecentFiles
    let open: (URL) -> Void

    var body: some View {
        Menu("Open Recent") {
            ForEach(files.urls, id: \.self) { url in
                let duplicate = files.urls.contains { $0 != url && $0.lastPathComponent == url.lastPathComponent }
                Button(duplicate ? url.path : url.lastPathComponent) { open(url) }
                    .help(url.path)
            }
            Divider()
            Button("Clear Menu", action: files.clear)
        }
        .disabled(files.urls.isEmpty)
    }
}
