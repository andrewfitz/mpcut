import Foundation
import SwiftUI

@MainActor
final class RecentFiles: ObservableObject {
    private static let key = "recent_file_paths"
    private static let limit = 10
    private let defaults: UserDefaults?
    @Published private(set) var urls: [URL]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        urls = (defaults?.stringArray(forKey: Self.key) ?? []).prefix(Self.limit).map { URL(fileURLWithPath: $0) }
    }

    func record(_ files: [URL]) {
        var seen = Set<URL>()
        var recent: [URL] = []
        for file in files + urls where file.isFileURL {
            let url = file.standardizedFileURL
            if seen.insert(url).inserted { recent.append(url) }
            if recent.count == Self.limit { break }
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
