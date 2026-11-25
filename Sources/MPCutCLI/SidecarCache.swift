import CryptoKit
import Foundation
import MPCutCore

struct SidecarCacheOptions {
    enum Operation: String, CaseIterable {
        case settings, configure, preview, clear
    }

    let operation: Operation
    private let folder: URL?
    private let project: URL?
    private let location: SidecarStorageMode?
    private let tokens: Set<String>
    private let readProtection: Bool

    init(_ operation: Operation, arguments: [String]) throws {
        self.operation = operation
        let allowed: Set<String>
        switch operation {
        case .settings: allowed = []
        case .configure: allowed = ["--mode", "--folder"]
        case .preview: allowed = ["--folder", "--project", "--location", "--stdin"]
        case .clear: allowed = ["--folder", "--project", "--location", "--select", "--confirm", "--stdin"]
        }
        func invalid(_ message: String) -> CLIError { CLIError("invalid_arguments", message) }
        var flags = Set<String>()
        var selection = Set<String>()
        var options: [String: String] = [:]
        var iterator = arguments.filter { $0 != "--json" }.makeIterator()
        while let flag = iterator.next() {
            guard allowed.contains(flag), flag == "--select" || flags.insert(flag).inserted else {
                throw invalid("Unexpected or repeated cache option '\(flag)'.")
            }
            if flag == "--confirm" || flag == "--stdin" { continue }
            guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw invalid("Supply a value for \(flag).")
            }
            if flag == "--select" {
                guard value.utf8.count == 64,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      selection.count < 500, selection.insert(value).inserted else {
                    throw invalid("Supply up to 500 distinct clear tokens from a cache preview.")
                }
            } else {
                options[flag] = value
            }
        }
        folder = try options["--folder"].map { try fileURL($0, label: "Cache folder", directory: true) }
        project = try options["--project"].map { try fileURL($0, label: "Project") }
        if let value = options["--mode"] ?? options["--location"] {
            guard let parsed = SidecarStorageMode(rawValue: value) else {
                throw invalid("Choose media, project or disk.")
            }
            location = parsed
        } else {
            location = nil
        }
        if operation == .configure && location == nil {
            throw invalid("Supply --mode media, project or disk.")
        }
        if operation == .configure && folder != nil && location != .disk {
            throw invalid("--folder applies to --mode disk.")
        }
        if operation == .preview || operation == .clear {
            guard folder != nil else { throw invalid("Supply the cache search folder with --folder.") }
        }
        if operation == .clear && (!flags.contains("--confirm") || selection.isEmpty) {
            throw invalid("Supply --confirm and one or more --select clear tokens from the preview.")
        }
        tokens = selection
        readProtection = flags.contains("--stdin")
    }

    func run(interruption: Interruption) throws -> SidecarCacheResponse {
        try interruption.check()
        switch operation {
        case .settings:
            return .settings(CacheSettings())
        case .configure:
            guard let location else { throw CLIError("invalid_arguments", "Supply a storage mode.") }
            try SidecarLocations.configureStorage(location, folder: folder)
            return .settings(CacheSettings())
        case .preview, .clear:
            return try inspect(interruption: interruption)
        }
    }

    private func inspect(interruption: Interruption) throws -> SidecarCacheResponse {
        guard let folder else { throw CLIError("invalid_arguments", "Supply a folder to search.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError("invalid_path", "The cache search folder is unavailable.")
        }
        var protected = Set<URL>()
        if readProtection {
            let paths = try JSONDecoder().decode([String].self, from: readStandardInput(interruption))
            protected.formUnion(try paths.map { try fileURL($0, label: "Protected path") })
        }
        var sources = [URL]()
        if let project {
            let media = try CutProjectMedia.load(from: project)
            sources = media.absoluteSources(relativeTo: project).keys.map { URL(fileURLWithPath: $0) }
            protected.insert(project)
        }
        let entries = SidecarLocations.$projectURL.withValue(project) {
            SidecarCacheCleaner.preview(scanning: [folder], protected: protected,
                                        sources: sources, projects: [project].compactMap { $0 }, scannedOnly: true)
        }
        let selected = entries.filter { location == nil || $0.location == location }
        let scope = [folder.resolvingSymlinksInPath().path, project?.resolvingSymlinksInPath().path ?? "",
                     location?.rawValue ?? ""]
        func token(_ entry: SidecarCacheEntry) -> String? {
            guard let generation = entry.clearToken else { return nil }
            let parts = (scope + [generation]).map { "\($0.utf8.count):\($0)" }.joined()
            return SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        try interruption.check()
        if operation == .preview {
            return .preview(CachePreview(folder: folder, location: location,
                                         entries: selected.map { CachePreview.Copy($0, clearToken: token($0)) }))
        }
        let confirmed = selected.filter { token($0).map(tokens.contains) == true }
        guard confirmed.count == tokens.count else {
            throw CLIError("stale_cache_preview", "One or more selected caches changed, became unavailable, or fall outside this scope. Preview again before clearing.")
        }
        protected.formUnion(sources)
        protected.formUnion(entries.map(\.source))
        let outcome = SidecarCacheCleaner.clear(confirmed, protected: protected)
        return .clear(CacheClear(outcome))
    }
}

enum SidecarCacheResponse: Encodable {
    case settings(CacheSettings), preview(CachePreview), clear(CacheClear)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .settings(let settings): try settings.encode(to: encoder)
        case .preview(let preview): try preview.encode(to: encoder)
        case .clear(let clear): try clear.encode(to: encoder)
        }
    }
}

struct CacheSettings: Encodable {
    let ok = true
    let mode: SidecarStorageMode
    let folder: String?
    let folderAvailable: Bool

    init() {
        let settings = SidecarLocations.settingsSnapshot()
        mode = settings.mode
        folder = settings.disk?.path
        folderAvailable = settings.available
    }
}

struct CachePreview: Encodable {
    struct Copy: Encodable {
        let path: String
        let source: String
        let folder: String
        let location: SidecarStorageMode
        let reclaimableBytes: Int64
        let usage: CutcacheUsage?
        let issue: String?
        let clearToken: String?

        init(_ entry: SidecarCacheEntry, clearToken: String?) {
            path = entry.url.path
            source = entry.source.path
            folder = entry.rootURL.path
            location = entry.location
            reclaimableBytes = clearToken != nil ? entry.bytes : 0
            usage = entry.usage
            issue = entry.issue
            self.clearToken = clearToken
        }
    }

    let ok = true
    let folder: String
    let location: SidecarStorageMode?
    let entries: [Copy]
    let reclaimableBytes: Int64

    init(folder: URL, location: SidecarStorageMode?, entries: [Copy]) {
        self.folder = folder.path
        self.location = location
        self.entries = entries
        reclaimableBytes = self.entries.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

struct CacheClear: Encodable {
    struct Skipped: Encodable {
        let path: String
        let reason: String
    }

    let ok = true
    let cleared: [String]
    let clearedSources: [String]
    let skipped: [Skipped]
    let reclaimedBytes: Int64

    init(_ result: SidecarClearResult) {
        cleared = result.cleared.map(\.path)
        clearedSources = result.clearedSources.map(\.path).sorted()
        skipped = result.skippedEntries.map { Skipped(path: $0.url.path, reason: $0.reason) }
        reclaimedBytes = result.reclaimedBytes
    }
}
