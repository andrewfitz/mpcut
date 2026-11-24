import CryptoKit
import Darwin
import Foundation

public struct TranscriptAsset: Codable, Hashable, Sendable {
    public let file: String
    public let sha256: String
    public let unavailable: TranscriptAssetStatus?

    private enum CodingKeys: String, CodingKey { case file, sha256, unavailable }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        file = try values.decode(String.self, forKey: .file)
        sha256 = try values.decode(String.self, forKey: .sha256)
        unavailable = values.contains(.unavailable) ? try values.decode(TranscriptAssetStatus.self, forKey: .unavailable) : nil
    }

    public init(file: String, sha256: String, unavailable: TranscriptAssetStatus? = nil) {
        self.file = file
        self.sha256 = sha256
        self.unavailable = unavailable
    }

    func validate() throws {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        let namedStore = parts.count == 2 && parts[0].hasSuffix(".transcripts") && parts[0] != ".transcripts"
        let draftStore = parts.count == 4 && parts[0] == ".." && parts[1] == ".transcripts"
            && UUID(uuidString: String(parts[2])) != nil
        guard TranscriptStore.validDigest(sha256), namedStore || draftStore, ProjectFile.validMediaPath(file),
              parts.last == "\(sha256).json", unavailable != .available else {
            throw transcriptError("Invalid transcript asset reference.")
        }
    }
}

public enum TranscriptBindingStatus: String, Codable, Sendable {
    case available, unverified, offline, changed, unbound
    case bindingMissing = "binding_missing"
}

public struct TranscriptBinding: Codable, Hashable, Sendable {
    public var trackID: String
    public var sourceID: String?
    public var file: String?
    public var streamIndex: Int
    public var channel: Int?
    public var sequenceClockOrigin: RationalTime?
    public var sequenceStreamOrdinal: Int?
    public var sourceFingerprint: String?
    public var sourceConfirmed: Bool?
    public var offset: RationalTime

    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case sourceID = "source_id"
        case file
        case streamIndex = "audio_stream_index"
        case channel
        case sequenceClockOrigin = "sequence_clock_origin"
        case sequenceStreamOrdinal = "sequence_stream_ordinal"
        case sourceFingerprint = "source_fingerprint"
        case sourceConfirmed = "source_confirmed"
        case offset
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try values.decode(String.self, forKey: .trackID)
        sourceID = values.contains(.sourceID) ? try values.decode(String.self, forKey: .sourceID) : nil
        file = values.contains(.file) ? try values.decode(String.self, forKey: .file) : nil
        streamIndex = try values.decode(Int.self, forKey: .streamIndex)
        channel = values.contains(.channel) ? try values.decode(Int.self, forKey: .channel) : nil
        sequenceClockOrigin = values.contains(.sequenceClockOrigin) ? try values.decode(RationalTime.self, forKey: .sequenceClockOrigin) : nil
        sequenceStreamOrdinal = values.contains(.sequenceStreamOrdinal) ? try values.decode(Int.self, forKey: .sequenceStreamOrdinal) : nil
        sourceFingerprint = values.contains(.sourceFingerprint) ? try values.decode(String.self, forKey: .sourceFingerprint) : nil
        sourceConfirmed = values.contains(.sourceConfirmed) ? try values.decode(Bool.self, forKey: .sourceConfirmed) : nil
        offset = try values.decode(RationalTime.self, forKey: .offset)
    }

    public init(trackID: String, sourceID: String? = nil, file: String? = nil, streamIndex: Int,
                channel: Int? = nil, offset: RationalTime = .zero, sequenceClockOrigin: RationalTime? = nil,
                sequenceStreamOrdinal: Int? = nil, sourceFingerprint: String? = nil, sourceConfirmed: Bool? = nil) {
        self.trackID = trackID
        self.sourceID = sourceID
        self.file = file
        self.streamIndex = streamIndex
        self.channel = channel
        self.sequenceClockOrigin = sequenceClockOrigin
        self.sequenceStreamOrdinal = sequenceStreamOrdinal
        self.sourceFingerprint = sourceFingerprint
        self.sourceConfirmed = sourceConfirmed
        self.offset = offset
    }

    public func mapSourcePaths(_ transform: (String) -> String) -> Self {
        var copy = self
        copy.file = file.map(transform)
        return copy
    }

    private func sourcePath(in project: CutProject) -> String? {
        if case .multicam(let group) = project {
            return group.sources.first { $0.id == sourceID }?.file
        }
        return file
    }

    public func sourceStatus(in project: CutProject, relativeTo document: URL) -> TranscriptBindingStatus {
        guard file != nil || sourceID != nil else { return .unbound }
        guard let path = sourcePath(in: project) else { return .bindingMissing }
        guard let source = try? CutProject.checkedMediaURL(path, relativeTo: document),
              let current = try? SourceIdentity(source) else { return .offline }
        guard let sourceFingerprint else { return .unverified }
        guard sourceFingerprint == current.transcriptFingerprint else { return .changed }
        return sourceConfirmed == true ? .available : .unverified
    }

    /// Remember the selected recording's identity using a filesystem stat.
    /// Inferred imports still need confirmation from the editor.
    public func stamped(in project: CutProject, relativeTo document: URL, confirmed: Bool) -> Self {
        var copy = self
        let identity = sourcePath(in: project)
            .flatMap { try? CutProject.checkedMediaURL($0, relativeTo: document) }
            .flatMap { try? SourceIdentity($0) }
        copy.sourceFingerprint = identity?.transcriptFingerprint
        copy.sourceConfirmed = identity == nil ? nil : confirmed
        return copy
    }

    func validate() throws {
        let indices = 0...Int(Int32.max)
        guard validStillID(trackID), indices.contains(streamIndex), channel.map(indices.contains) ?? true,
              file == nil || sourceID == nil, file.map(ProjectFile.validMediaPath) ?? true,
              sourceID.map(validStillID) ?? true, sequenceStreamOrdinal.map(indices.contains) ?? true,
              sourceFingerprint.map(TranscriptStore.validDigest) ?? true,
              sourceConfirmed != true || sourceFingerprint != nil else {
            throw transcriptError("Invalid transcript binding for track ‘\(trackID)’.")
        }
    }
}

public struct TranscriptAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var asset: TranscriptAsset
    public var bindings: [TranscriptBinding]
    public var importOrigin: RationalTime?
    public var fingerprint: String?
    public var resultID: String { asset.sha256 }

    private enum CodingKeys: String, CodingKey {
        case id
        case asset
        case bindings
        case importOrigin = "import_origin"
        case fingerprint
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        asset = try values.decode(TranscriptAsset.self, forKey: .asset)
        bindings = try values.decode([TranscriptBinding].self, forKey: .bindings)
        importOrigin = values.contains(.importOrigin) ? try values.decode(RationalTime.self, forKey: .importOrigin) : nil
        fingerprint = values.contains(.fingerprint) ? try values.decode(String.self, forKey: .fingerprint) : nil
    }

    public init(id: String, asset: TranscriptAsset, bindings: [TranscriptBinding], importOrigin: RationalTime? = nil,
                fingerprint: String? = nil) {
        self.id = id
        self.asset = asset
        self.bindings = bindings
        self.importOrigin = importOrigin
        self.fingerprint = fingerprint
    }
}

public struct ProjectTranscripts: Codable, Equatable, Sendable {
    public var attachments: [TranscriptAttachment]
    public var authoring: [TranscriptAuthoredRecord]
    public var revision: UInt64
    public var documentID: UUID?

    private enum CodingKeys: String, CodingKey {
        case attachments
        case authoring
        case revision
        case documentID = "document_id"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_transcript_state")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachments = try values.decode([TranscriptAttachment].self, forKey: .attachments)
        authoring = try values.decode([TranscriptAuthoredRecord].self, forKey: .authoring)
        revision = try values.decode(UInt64.self, forKey: .revision)
        documentID = values.contains(.documentID) ? try values.decode(UUID.self, forKey: .documentID) : nil
    }

    public init(attachments: [TranscriptAttachment] = [], authoring: [TranscriptAuthoredRecord] = [],
                revision: UInt64 = 0, documentID: UUID? = nil) {
        self.attachments = attachments
        self.authoring = authoring
        self.revision = revision
        self.documentID = documentID
    }

    public var isEmpty: Bool { attachments.isEmpty && authoring.isEmpty && revision == 0 && documentID == nil }

    public mutating func advanceRevision() throws {
        guard revision < UInt64.max else { throw transcriptError("The transcript revision counter is exhausted.") }
        revision += 1
    }

    public func mapSourcePaths(_ transform: (String) -> String) -> Self {
        var copy = self
        copy.attachments = attachments.map { attachment in
            var value = attachment
            value.bindings = attachment.bindings.map { $0.mapSourcePaths(transform) }
            return value
        }
        copy.authoring = authoring.map { $0.mapSourcePaths(transform) }
        return copy
    }

    public func validate() throws {
        var ids = Set<String>()
        for attachment in attachments {
            guard validStillID(attachment.id), ids.insert(attachment.id).inserted,
                  Set(attachment.bindings.map(\.trackID)).count == attachment.bindings.count else {
                throw transcriptError("Transcript attachment and binding IDs must be unique.")
            }
            try attachment.asset.validate()
            for binding in attachment.bindings { try binding.validate() }
        }
        ids.removeAll(keepingCapacity: true)
        for record in authoring {
            guard validStillID(record.id), ids.insert(record.id).inserted else {
                throw transcriptError("Transcript authoring IDs must be unique.")
            }
            try record.validate()
        }
    }

    var protectedPaths: [(String, String)] {
        authoring.flatMap { record in record.protectedPaths.map { (record.id, $0) } } + attachments.flatMap { attachment in
            [(attachment.id, attachment.asset.file)]
                + attachment.bindings.compactMap { binding in binding.file.map { (attachment.id, $0) } }
        }
    }
}

extension TranscriptAuthoredRecord {
    var protectedPaths: [String] {
        anchors.compactMap { $0.binding.file } + [speakerReference?.binding.file].compactMap { $0 }
    }
}

func transcriptError(_ message: String, code: String = "invalid_transcript_state") -> CutError {
    CutError(code: code, message: message)
}

extension SourceIdentity {
    package var transcriptFingerprint: String {
        TranscriptStore.digest(Data("\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)".utf8))
    }
}

public enum TranscriptAssetStatus: String, Codable, Hashable, Sendable {
    case available, missing, invalid
}

public enum TranscriptStore {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validDigest(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func document(_ url: URL) -> URL { ProjectFile.canonicalFileURL(ProjectFile.documentURL(url)) }

    /// Draft document and asset directories are independently keyed by the same draft ID.
    private static func draftFolderName(for document: URL) -> String? {
        let parent = document.deletingLastPathComponent()
        guard document.lastPathComponent == "Untitled.cut", UUID(uuidString: parent.lastPathComponent) != nil else { return nil }
        return parent.lastPathComponent
    }

    private static func draftFolder(for project: URL) -> URL? {
        guard let id = draftFolderName(for: project) else { return nil }
        return ProjectFile.canonicalFileURL(project.deletingLastPathComponent().deletingLastPathComponent())
            .appendingPathComponent(".transcripts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    public static func folder(relativeTo project: URL, draft: Bool = false) -> URL {
        if draft, let store = draftFolder(for: project) { return store }
        let project = document(project)
        return project.deletingLastPathComponent()
            .appendingPathComponent(project.lastPathComponent + ".transcripts", isDirectory: true)
    }

    static func hasStore(relativeTo project: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder(relativeTo: project).path)
    }

    private static func reference(digest: String, relativeTo project: URL, draft: Bool,
                                  unavailable: TranscriptAssetStatus? = nil) -> TranscriptAsset {
        let filename = digest + ".json"
        let path: String
        if draft, let store = draftFolder(for: project) {
            path = "../.transcripts/" + store.lastPathComponent + "/" + filename
        } else {
            path = folder(relativeTo: project).lastPathComponent + "/" + filename
        }
        return TranscriptAsset(file: path, sha256: digest, unavailable: unavailable)
    }

    package static func reference(for data: Data, relativeTo project: URL) -> TranscriptAsset {
        reference(digest: digest(data), relativeTo: project, draft: false)
    }

    public static func put(_ data: Data, relativeTo project: URL, draft: Bool = false) throws -> TranscriptAsset {
        try put(data, relativeTo: project, draft: draft) { _ in }
    }

    /// Store bytes that were read from `asset` in `source` when a snapshot was taken. While that
    /// file is still in place the new one shares its storage. A project that has since moved or
    /// pruned the file gets the held bytes instead.
    package static func put(_ data: Data, readFrom asset: TranscriptAsset, in source: URL, relativeTo project: URL,
                            draft: Bool = false) throws -> TranscriptAsset {
        try put(data, readFrom: asset, in: source, relativeTo: project, draft: draft, clone: clonefile)
    }

    static func put(_ data: Data, readFrom asset: TranscriptAsset, in source: URL, relativeTo project: URL,
                    draft: Bool, clone: Clone) throws -> TranscriptAsset {
        guard let file = try? assetURL(asset, relativeTo: source) else {
            return try put(data, relativeTo: project, draft: draft, expectedDigest: asset.sha256) { _ in }
        }
        return try put(asset, cloning: file, relativeTo: project, draft: draft, clone: clone, created: { _ in }) {
            guard digest(data) == asset.sha256 else {
                throw transcriptError("The transcript bytes do not match the expected SHA-256.", code: "damaged_transcript")
            }
            return data
        }
    }

    /// `verified` is the digest the caller has just proved for these bytes.
    private static func put(_ data: Data, relativeTo project: URL, draft: Bool, expectedDigest: String? = nil,
                            verified: String? = nil, created: (URL) -> Void) throws -> TranscriptAsset {
        let name = verified ?? digest(data)
        if let expectedDigest, name != expectedDigest {
            throw transcriptError("The transcript bytes do not match the expected SHA-256.", code: "damaged_transcript")
        }
        let asset = reference(digest: name, relativeTo: project, draft: draft)
        let directory = try preparedFolder(relativeTo: project, draft: draft)
        let url = directory.appendingPathComponent(name + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            try adopt(asset, at: url, relativeTo: project, draft: draft)
            return asset
        }
        let staged = directory.appendingPathComponent(".transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        try install(staged, as: asset, at: url, relativeTo: project, draft: draft, created: created)
        return asset
    }

    /// The signature of `clonefile`, which a test replaces with a volume that refuses.
    typealias Clone = (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32

    /// A failure in the file an asset is copied from, as distinct from one in the store receiving it.
    private struct UnusableSource: Error {
        let reason: Error

        static func reporting<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch { throw UnusableSource(reason: error) }
        }
    }

    /// Store an asset that is already a file. Where the volume can clone, the new file shares the
    /// storage of the one it came from, so a copied project spends no more space on its transcripts.
    /// `bytes` supplies the verified contents whenever a clone cannot be made or is not needed.
    /// The caller has validated the asset reference.
    private static func put(_ asset: TranscriptAsset, cloning file: URL, relativeTo project: URL, draft: Bool,
                            clone: Clone, created: (URL) -> Void, bytes: () throws -> Data) throws -> TranscriptAsset {
        var info = stat()
        var madeStore: URL?
        if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
            let hadStore = identity(folder(relativeTo: project, draft: draft).path) != nil
            let directory: URL
            do {
                directory = try preparedFolder(relativeTo: project, draft: draft)
            } catch {
                // A source that cannot be used is reported before a store that cannot.
                _ = try bytes()
                throw error
            }
            if !hadStore { madeStore = directory }
            let url = directory.appendingPathComponent(asset.sha256 + ".json")
            let staged = directory.appendingPathComponent(".transcript-\(UUID().uuidString)")
            if !FileManager.default.fileExists(atPath: url.path), stageClone(of: file, at: staged, for: asset, clone) {
                defer { unlink(staged.path) }
                let stored = reference(digest: asset.sha256, relativeTo: project, draft: draft)
                try install(staged, as: stored, at: url, relativeTo: project, draft: draft, created: created)
                return stored
            }
        }
        let data: Data
        do {
            data = try bytes()
        } catch {
            // The folder was made to stage a clone that the source turned out not to justify.
            if let madeStore { rmdir(madeStore.path) }
            throw error
        }
        return try put(data, relativeTo: project, draft: draft, verified: asset.sha256, created: created)
    }

    /// Stage a copy-on-write clone of an asset file and verify it there, because the source can
    /// change after it is checked while the clone cannot. A clone inherits the lock flags and the
    /// modification time of its source. A locked file could be neither published nor removed, and
    /// an old time would present a file that was just placed as one long abandoned.
    private static func stageClone(of file: URL, at staged: URL, for asset: TranscriptAsset, _ clone: Clone) -> Bool {
        guard clone(file.path, staged.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else { return false }
        var info = stat()
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        if lstat(staged.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
           info.st_flags & locks == 0 || lchflags(staged.path, info.st_flags & ~locks) == 0,
           (try? verifiedBytes(at: staged, for: asset)) != nil,
           lutimes(staged.path, nil) == 0 {
            return true
        }
        // Whatever the clone made under this private name, a link or a folder included, is this call’s to discard.
        try? FileManager.default.removeItem(at: staged)
        return false
    }

    private static func preparedFolder(relativeTo project: URL, draft: Bool) throws -> URL {
        let directory = folder(relativeTo: project, draft: draft)
        guard resolvesToItself(directory) else {
            throw transcriptError("The transcript store redirects to another location.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard resolvesToItself(directory) else {
            throw transcriptError("The transcript store redirects to another location.")
        }
        return directory
    }

    private static func install(_ staged: URL, as asset: TranscriptAsset, at url: URL, relativeTo project: URL,
                                draft: Bool, created: (URL) -> Void) throws {
        let status = publishExclusively(from: staged, to: url)
        if status == EEXIST {
            try adopt(asset, at: url, relativeTo: project, draft: draft)
        } else if status != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        } else {
            created(url)
        }
    }

    /// Accept the file the store already holds in place of the one that was about to be written.
    /// It may have lain unreferenced since an earlier import. This import has not been saved
    /// either, so its modification time has to show that the file is in use again.
    private static func adopt(_ asset: TranscriptAsset, at url: URL, relativeTo project: URL, draft: Bool) throws {
        _ = try read(asset, relativeTo: project)
        var info = stat()
        // Decoded results are remembered by change time, so a file that is already fresh is left alone.
        if !draft, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
           time(nil) - info.st_mtimespec.tv_sec > 60 * 60 {
            lutimes(url.path, nil)
        }
    }

    private static func checkedAssetURL(in store: URL, name: String) throws -> URL {
        let url = store.appendingPathComponent(name)
        guard resolvesToItself(url) else {
            throw transcriptError("The transcript asset redirects to another location.")
        }
        return url
    }

    private static func identity(_ path: String) -> [UInt64]? {
        var info = stat()
        return lstat(path, &info) == 0 ? [UInt64(info.st_dev), UInt64(info.st_ino)] : nil
    }

    /// Whether a path names the entry the volume resolves it to. A volume that ignores letter
    /// case reports the spelling on disk, so a project renamed only in case would otherwise
    /// appear to redirect to its own store.
    private static func resolvesToItself(_ url: URL) -> Bool {
        let canonical = ProjectFile.canonicalFileURL(url).path
        if canonical == url.path { return true }
        guard canonical.compare(url.path, options: .caseInsensitive) == .orderedSame else { return false }
        if let resolved = identity(canonical) { return resolved == identity(url.path) }
        // Not created yet: the folder that will hold it decides.
        return url.pathComponents.count > 1 && resolvesToItself(url.deletingLastPathComponent())
    }

    private static func declaredNamedAssetURL(_ asset: TranscriptAsset, relativeTo project: URL) throws -> URL {
        let parent = project.deletingLastPathComponent()
        let basename = String(asset.file.split(separator: "/")[0])
        let named = folder(relativeTo: project)
        let declared = parent.appendingPathComponent(basename, isDirectory: true)
        // The same folder under another letter case is this project's own store.
        let ownStore = identity(declared.path).map { $0 == identity(named.path) } ?? false
        if basename != named.lastPathComponent, !ownStore {
            var info = stat()
            let priorProject = parent.appendingPathComponent(String(basename.dropLast(".transcripts".count)))
            guard lstat(priorProject.path, &info) != 0, errno == ENOENT else {
                throw transcriptError("Choose the transcript store explicitly to recover the recording’s metadata.",
                                      code: "ambiguous_transcript_store")
            }
        }
        return try checkedAssetURL(in: parent.appendingPathComponent(basename, isDirectory: true), name: asset.sha256 + ".json")
    }

    private static func assetURL(_ asset: TranscriptAsset, relativeTo project: URL) throws -> URL {
        try asset.validate()
        let project = document(project)
        let name = asset.sha256 + ".json"
        let named = folder(relativeTo: project)
        if asset.file == named.lastPathComponent + "/" + name {
            return try checkedAssetURL(in: named, name: name)
        }
        if asset.file.hasPrefix("../") {
            guard let draft = draftFolder(for: project),
                  asset.file == "../.transcripts/" + draft.lastPathComponent + "/" + name else {
                throw transcriptError("Transcript asset is outside this project’s store.")
            }
            return try checkedAssetURL(in: draft, name: name)
        }

        // A Finder rename can leave the old relative reference in the .cut.
        // First use the current basename for a store renamed with the document.
        var info = stat()
        if lstat(named.appendingPathComponent(name).path, &info) == 0 {
            return try checkedAssetURL(in: named, name: name)
        }

        // A former store is usable only from an existing project and when no
        // file still owns the former basename.
        guard lstat(project.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw transcriptError("Transcript asset is outside this project’s store.")
        }
        return try declaredNamedAssetURL(asset, relativeTo: project)
    }

    package static func assetLocation(_ asset: TranscriptAsset, relativeTo project: URL) -> URL? {
        try? assetURL(asset, relativeTo: project)
    }

    /// Copy a verified asset from a selected project-local store into this project’s store.
    public static func recover(_ asset: TranscriptAsset, from store: URL, relativeTo project: URL,
                               draft: Bool = false) throws -> TranscriptAsset {
        try asset.validate()
        let parent = document(project).deletingLastPathComponent()
        let chosenParent = ProjectFile.canonicalFileURL(store.deletingLastPathComponent())
        guard chosenParent.path == parent.path, store.lastPathComponent.hasSuffix(".transcripts"),
              store.lastPathComponent.count > ".transcripts".count else {
            throw transcriptError("Choose a transcript store beside this project.")
        }
        let selected = parent.appendingPathComponent(store.lastPathComponent, isDirectory: true)
        let url = try checkedAssetURL(in: selected, name: asset.sha256 + ".json")
        func place() throws -> TranscriptAsset {
            try put(asset, cloning: url, relativeTo: project, draft: draft, clone: clonefile, created: { _ in }) {
                try UnusableSource.reporting { try verifiedBytes(at: url, for: asset, options: []) }
            }
        }
        do {
            return try place()
        } catch let failure as UnusableSource {
            throw failure.reason
        } catch let error as CutError where error.code == "damaged_transcript" {
            let destination = try checkedAssetURL(in: folder(relativeTo: project, draft: draft),
                                                  name: asset.sha256 + ".json")
            var observed = stat(), current = stat()
            let backup = destination.deletingLastPathComponent().appendingPathComponent(".damaged-\(UUID().uuidString)")
            // Preserve the existing bytes. link refuses directories, and the
            // inode check prevents removing a replacement at the canonical name.
            guard lstat(destination.path, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG,
                  link(destination.path, backup.path) == 0,
                  lstat(destination.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == observed.st_dev, current.st_ino == observed.st_ino,
                  unlink(destination.path) == 0 else { throw error }
            do {
                return try place()
            } catch let failure as UnusableSource {
                throw failure.reason
            }
        }
    }

    /// Check physical availability without opening or hashing an attachment.
    public static func assetStatus(_ asset: TranscriptAsset, relativeTo project: URL) -> TranscriptAssetStatus {
        guard let url = try? assetURL(asset, relativeTo: project) else { return .invalid }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? asset.unavailable ?? .missing : .invalid }
        return info.st_mode & S_IFMT == S_IFREG ? .available : .invalid
    }

    public static func read(_ asset: TranscriptAsset, relativeTo project: URL) throws -> Data {
        try verifiedBytes(at: assetURL(asset, relativeTo: project), for: asset)
    }

    /// The decoded result an attachment refers to. An asset is named for the SHA-256 of
    /// its bytes, so a document decoded once stays current while the file keeps the size,
    /// inode and change time it was verified with. An open editor asks for the same
    /// result after every edit; reading, hashing and decoding it again each time made
    /// the transcript unavailable for as long as that took.
    /// `known` is the value these bytes were encoded from, when the caller still holds it.
    /// The stored bytes are verified either way.
    public static func decoded(_ asset: TranscriptAsset, relativeTo project: URL) throws -> TranscriptDocument {
        try decoded(asset, relativeTo: project, known: nil)
    }

    package static func decoded(_ asset: TranscriptAsset, relativeTo project: URL,
                                known: TranscriptDocument?) throws -> TranscriptDocument {
        let url = try assetURL(asset, relativeTo: project)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            // Report a missing or damaged asset exactly as an uncached read does.
            return try TranscriptCodec.decode(verifiedBytes(at: url, for: asset), format: .json)
        }
        let key = DecodedAssets.Key(path: url.path, sha256: asset.sha256, size: Int64(info.st_size), inode: UInt64(info.st_ino),
                                    changed: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        if let document = decodedAssets.document(for: key) { return document }
        let bytes = try verifiedBytes(at: url, for: asset)
        let document = try known ?? TranscriptCodec.decode(bytes, format: .json)
        decodedAssets.remember(document, for: key)
        return document
    }

    private static let decodedAssets = DecodedAssets()

    /// Let go of the decoded results of a project whose window has closed.
    public static func releaseDecoded(relativeTo project: URL) {
        let project = document(project)
        decodedAssets.forget(inside: folder(relativeTo: project).path)
        if let draft = draftFolder(for: project) { decodedAssets.forget(inside: draft.path) }
    }

    private final class DecodedAssets: @unchecked Sendable {
        struct Key: Equatable {
            let path: String
            let sha256: String
            let size: Int64
            let inode: UInt64
            let changed: Int64
            let changedNanoseconds: Int64
        }

        private let lock = NSLock()
        // A project rarely shows more than a few results at once, and each can be large.
        // Beyond the newest, keep only what a modest share of stored bytes allows.
        private var entries: [(key: Key, document: TranscriptDocument)] = []
        private let limit = 4
        private let byteLimit: Int64 = 96 << 20

        func document(for key: Key) -> TranscriptDocument? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.document
        }

        func remember(_ document: TranscriptDocument, for key: Key) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.key.path == key.path }
            entries.append((key, document))
            while entries.count > 1, entries.count > limit || entries.reduce(0, { $0 + $1.key.size }) > byteLimit {
                entries.removeFirst()
            }
        }

        func forget(inside folder: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.key.path.hasPrefix(folder + "/") }
        }
    }

    private static func verifiedBytes(at url: URL, for asset: TranscriptAsset,
                                      options: Data.ReadingOptions = .mappedIfSafe) throws -> Data {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw transcriptError("The transcript asset must be a regular file.", code: "damaged_transcript")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: options)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if asset.unavailable == .invalid {
                throw transcriptError("Transcript asset ‘\(asset.sha256)’ needs a verified copy.", code: "damaged_transcript")
            }
            throw transcriptError("Transcript asset ‘\(asset.sha256)’ is missing.", code: "missing_transcript")
        }
        guard digest(data) == asset.sha256 else {
            throw transcriptError("Transcript asset ‘\(asset.sha256)’ failed its SHA-256 check.", code: "damaged_transcript")
        }
        return data
    }

    public static func copy(in state: ProjectTranscripts, from source: URL, to destination: URL,
                            draft: Bool = false) throws -> ProjectTranscripts {
        try copy(in: state, from: source, to: destination, draft: draft, clone: clonefile)
    }

    static func copy(in state: ProjectTranscripts, from source: URL, to destination: URL,
                     draft: Bool, clone: Clone) throws -> ProjectTranscripts {
        try copy(in: state, from: source, to: destination, draft: draft, assetData: [:], clone: clone,
                 check: {}, created: { _ in })
    }

    private static func copy(in state: ProjectTranscripts, from source: URL, to destination: URL,
                             draft: Bool, assetData: [TranscriptAsset: Data], clone: Clone = clonefile,
                             check: () throws -> Void, created: (URL) -> Void) throws -> ProjectTranscripts {
        let inPlace = document(source) == document(destination)
        var result = state
        var copied: [TranscriptAsset: TranscriptAsset] = [:]
        for index in result.attachments.indices {
            try check()
            let asset = result.attachments[index].asset
            if let existing = copied[asset] {
                result.attachments[index].asset = existing
                continue
            }
            if let bytes = assetData[asset] {
                try asset.validate()
                let new = try put(bytes, relativeTo: destination, draft: draft, expectedDigest: asset.sha256,
                                  created: created)
                result.attachments[index].asset = new
                copied[asset] = new
                continue
            }
            if inPlace, asset.file == reference(digest: asset.sha256, relativeTo: destination, draft: draft).file { continue }
            do {
                let file = try UnusableSource.reporting { try assetURL(asset, relativeTo: source) }
                result.attachments[index].asset = try put(asset, cloning: file, relativeTo: destination, draft: draft,
                                                          clone: clone, created: created) {
                    try UnusableSource.reporting { try verifiedBytes(at: file, for: asset, options: []) }
                }
            } catch let failure as UnusableSource {
                try asset.validate()
                let missing = (failure.reason as? CutError)?.code == "missing_transcript"
                result.attachments[index].asset = reference(digest: asset.sha256, relativeTo: destination,
                                                            draft: draft, unavailable: missing ? .missing : .invalid)
            }
            copied[asset] = result.attachments[index].asset
        }
        return result
    }

    /// The caller holds the project directory lock through publication.
    static func withCopy<T>(in state: ProjectTranscripts, from source: URL, to destination: URL,
                            assetData: [TranscriptAsset: Data], check: () throws -> Void,
                            publish: (ProjectTranscripts) throws -> T) throws -> T {
        guard !state.attachments.isEmpty else { return try publish(state) }
        let store = folder(relativeTo: destination)
        let hadStore = identity(store.path) != nil
        var created: [(URL, [UInt64])] = []
        do {
            let copy = try copy(in: state, from: source, to: destination, draft: false, assetData: assetData, check: check) { url in
                if let entry = identity(url.path) { created.append((url, entry)) }
            }
            return try publish(copy)
        } catch {
            if resolvesToItself(store) {
                for (url, entry) in created where identity(url.path) == entry { unlink(url.path) }
                if !hadStore { rmdir(store.path) }
            }
            throw error
        }
    }

    package static func discardDraft(relativeTo project: URL) {
        guard let store = draftFolder(for: project),
              FileManager.default.fileExists(atPath: store.path),
              ProjectFile.canonicalFileURL(store).path == store.path else { return }
        try? FileManager.default.removeItem(at: store)
    }

    /// Publish first, then retire only the assets that the previous saved
    /// version referenced. Other assets may belong to an in-flight import,
    /// so they stay until they have gone a day without being touched, and
    /// for as long as another project sits in the same folder.
    static func publish(relativeTo project: URL, keeping assets: [TranscriptAsset], hasTranscriptMetadata: Bool,
                        now: Date = Date(), _ write: () throws -> Void) throws {
        let project = document(project)
        let inspectPrevious = hasTranscriptMetadata || hasStore(relativeTo: project)
        let previous = inspectPrevious ? (try? CutProject.load(from: project))?.transcripts.attachments ?? [] : []
        let old = Set(previous.map(\.asset))
        let keep = Set(assets)
        for asset in keep.subtracting(old) where asset.unavailable == nil {
            _ = try read(asset, relativeTo: project)
        }
        // A project written for the first time cannot have abandoned anything in a store that
        // is already there. Those files belong to whatever used the name before.
        var replaced = stat()
        let replacesProject = lstat(project.path, &replaced) == 0 && replaced.st_mode & S_IFMT == S_IFREG
        try write()
        // A project renamed in Finder leaves its store under the former name, where a new project
        // of that name would find it. With another project in the folder, or a folder that cannot
        // be listed, nothing here is known to be abandoned. The editor opens a project whatever
        // the letter case of its extension.
        let neighbours = try? FileManager.default.contentsOfDirectory(atPath: project.deletingLastPathComponent().path)
        let sharesFolder = neighbours?.contains {
            $0.lowercased().hasSuffix(".cut") && $0 != project.lastPathComponent
        } ?? true
        defer { if replacesProject, !sharesFolder { removeAbandoned(relativeTo: project, keeping: keep, now: now) } }
        guard !old.isEmpty else { return }
        let retained = Set(keep.compactMap { assetLocation($0, relativeTo: project)?.path })
        let retainedFiles = Set(retained.compactMap(identity))
        let ownStore = folder(relativeTo: project)
        // A duplicate of this project made before it was renamed still reads the former store.
        let hasSiblingProject = ((try? FileManager.default.contentsOfDirectory(atPath: project.deletingLastPathComponent().path)) ?? [])
            .contains { $0.hasSuffix(".cut") && $0 != project.lastPathComponent }
        for asset in old where !asset.file.hasPrefix("../") {
            guard let file = try? declaredNamedAssetURL(asset, relativeTo: project), !retained.contains(file.path) else { continue }
            // The retained file can be this one under another spelling of its folder.
            if let entry = identity(file.path), retainedFiles.contains(entry) { continue }
            let formerStore = identity(file.deletingLastPathComponent().path) != identity(ownStore.path)
            if formerStore, hasSiblingProject { continue }
            var observed = stat(), current = stat()
            guard lstat(file.path, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG,
                  (try? verifiedBytes(at: file, for: asset)) != nil,
                  (try? declaredNamedAssetURL(asset, relativeTo: project)) == file,
                  lstat(file.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == observed.st_dev, current.st_ino == observed.st_ino, current.st_size == observed.st_size,
                  current.st_mtimespec.tv_sec == observed.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == observed.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == observed.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == observed.st_ctimespec.tv_nsec else { continue }
            unlink(file.path)
        }
    }

    /// Remove the results in this project’s store that nothing refers to any longer. A result is
    /// written when it is attached, so one that was replaced or detached before the next save was
    /// never named by a saved project, and retiring the previous version’s assets cannot find it.
    /// Undo and redo restore authored records and keep the current attachments, so the project
    /// just written names every result it can show.
    /// The caller has found no other project in the folder. A project that was renamed and left
    /// its store behind still reads it, or recovers from it, under the former name, so a new
    /// project of that name cannot tell that store’s files from its own while the other exists.
    /// Another window or process may hold a result it has not saved yet. A file stays unless a day
    /// has passed since its contents were written and since it was last renamed, linked or otherwise
    /// changed, which also covers one that a copy or a sync delivered recently with an old
    /// modification time.
    /// Every entry is examined and removed through the open folder, so a link placed in the store
    /// cannot lead the removal elsewhere.
    private static func removeAbandoned(relativeTo project: URL, keeping keep: Set<TranscriptAsset>, now: Date) {
        // A recovery draft keeps its results in a store of its own, which is discarded whole.
        guard draftFolderName(for: project) == nil else { return }
        let store = folder(relativeTo: project)
        var named = stat(), opened = stat()
        guard lstat(store.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR, resolvesToItself(store) else { return }
        let directory = open(store.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { close(directory) }
        guard fstat(directory, &opened) == 0, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              let names = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return }
        let keptDigests = Set(keep.map(\.sha256))
        // A kept asset can also be reached under another name or another spelling of its folder.
        let keptFiles = Set(keep.compactMap { assetLocation($0, relativeTo: project)?.path }.compactMap(identity))
        let cutoff = Int(now.timeIntervalSince1970) - 24 * 60 * 60
        for name in names {
            let bytes = Array(name.utf8)
            guard bytes.count == 64 + 5, bytes.suffix(5).elementsEqual(".json".utf8) else { continue }
            let expected = String(decoding: bytes.prefix(64), as: UTF8.self)
            guard validDigest(expected), !keptDigests.contains(expected) else { continue }
            var observed = stat(), current = stat()
            // The contents are hashed last: a file that fails stays, like the damaged bytes
            // that retiring an asset leaves in place.
            guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0, observed.st_mode & S_IFMT == S_IFREG,
                  !keptFiles.contains([UInt64(observed.st_dev), UInt64(observed.st_ino)]),
                  observed.st_mtimespec.tv_sec < cutoff, observed.st_ctimespec.tv_sec < cutoff,
                  storedDigest(of: name, in: directory, matching: observed) == expected,
                  fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == observed.st_dev, current.st_ino == observed.st_ino, current.st_size == observed.st_size,
                  current.st_mtimespec.tv_sec == observed.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == observed.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == observed.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == observed.st_ctimespec.tv_nsec else { continue }
            unlinkat(directory, name, 0)
        }
    }

    /// The SHA-256 of a store entry, when it is still the regular file that was examined.
    private static func storedDigest(of name: String, in directory: Int32, matching observed: stat) -> String? {
        // A pipe that took the name after it was examined must not hold the save open.
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == observed.st_dev, info.st_ino == observed.st_ino else { return nil }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Resolve once per attachment state. Timeline operations can project the same
/// source-local protections without decoding a transcript or rebuilding a word index.
package struct TranscriptPauseProtectionCache {
    private var projectURL: URL?
    private var state: ProjectTranscripts?
    private var protections = TranscriptPauseProtections()

    package init() {}

    package mutating func resolve(_ state: ProjectTranscripts, relativeTo projectURL: URL?) -> TranscriptPauseProtections {
        if self.projectURL == projectURL && self.state == state { return protections }
        self.projectURL = projectURL
        self.state = state
        protections = projectURL.map { TranscriptPauseProtections(state: state, relativeTo: $0) } ?? .init()
        return protections
    }
}

package struct TranscriptPauseProtections {
    private struct Edge {
        let binding: TranscriptBinding
        let time: RationalTime
    }

    private struct Gap {
        let from: Edge
        let to: Edge
    }

    private var gaps: [Gap] = []

    package var isEmpty: Bool { gaps.isEmpty }

    fileprivate init() {}

    fileprivate init(state: ProjectTranscripts, relativeTo project: URL) {
        let records = Dictionary(grouping: state.authoring.filter {
            if case .pauseProtection = $0.change { return true }
            return false
        }, by: \.attachmentID)
        for attachment in state.attachments {
            guard let authored = records[attachment.id],
                  let document = try? TranscriptStore.decoded(attachment.asset, relativeTo: project),
                  let words = try? TranscriptIndex.sourceOccurrences(document: document, attachment: attachment) else { continue }
            let review = TranscriptEditorial.review(records: authored, sourceWords: words, attachmentID: attachment.id)
            for record in review {
                guard record.anchors.count == 2, record.anchors.allSatisfy({ $0.status == .resolved }),
                      let left = record.anchors[0].words.last, let right = record.anchors[1].words.first,
                      let from = left.sourceRange?.to, let to = right.sourceRange?.from,
                      let leftBinding = left.binding, let rightBinding = right.binding else { continue }
                gaps.append(Gap(from: Edge(binding: leftBinding, time: from), to: Edge(binding: rightBinding, time: to)))
            }
        }
    }

    private func ranges(_ time: (Edge) -> RationalTime?) -> [AudioSpan] {
        gaps.compactMap { gap in
            guard let from = time(gap.from), let to = time(gap.to), from < to else { return nil }
            return AudioSpan(from: from, to: to)
        }
    }

    package func sequence(file: String, origin: RationalTime, stream: Int, sourceFingerprint: String) -> [AudioSpan] {
        ranges { edge in
            let binding = edge.binding
            guard binding.file == file, binding.streamIndex == stream,
                  binding.sourceFingerprint.map({ $0 == sourceFingerprint }) ?? true else { return nil }
            return try? edge.time.subtracting(origin)
        }
    }

    package func group(sources: [MulticamSource], sourceFingerprints: [String: String]) -> [AudioSpan] {
        group(sources: sources, sourceFingerprints: sourceFingerprints, replacementOffsets: [:])
    }

    package func group(project: MulticamProject, sourceFingerprints: [String: String]) throws -> [AudioSpan] {
        let offsets = Dictionary(uniqueKeysWithValues: try project.transcriptReplacementPlacements().map {
            ($0.trackID, $0.offset)
        })
        return group(sources: project.sources, sourceFingerprints: sourceFingerprints, replacementOffsets: offsets)
    }

    private func group(sources: [MulticamSource], sourceFingerprints: [String: String],
                       replacementOffsets: [String: RationalTime]) -> [AudioSpan] {
        let sources = Dictionary(sources.map { ($0.id, $0.offset) }, uniquingKeysWith: { _, new in new })
        return ranges { edge in
            let binding = edge.binding
            guard let id = binding.sourceID, let offset = sources[id], let fingerprint = sourceFingerprints[id],
                  binding.sourceFingerprint.map({ $0 == fingerprint }) ?? true else { return nil }
            if let replacement = TranscriptJobPlan.replacementTrackIdentity(binding.trackID) {
                guard let replacementOffset = replacementOffsets[replacement] else { return nil }
                return try? edge.time.adding(replacementOffset)
            }
            return try? edge.time.adding(offset)
        }
    }
}
