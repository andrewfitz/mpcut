import Foundation

public enum ProjectMediaMatch: String, Codable, Sendable {
    case verified, match, ambiguous, different, pending

    public var canRelink: Bool { self == .verified || self == .match }
}

public struct ProjectMediaCandidate: Encodable, Sendable {
    public let url: URL
    public let outcome: ProjectMediaMatch
    public let reason: String?
    public let duration: RationalTime?
    public let sourceClock: ProjectMediaSnapshot.Entry.SourceClock?
    let identity: SourceIdentity?
    let requiresGeneration: Bool

    init(url: URL, outcome: ProjectMediaMatch, reason: String? = nil, duration: RationalTime? = nil,
         sourceClock: ProjectMediaSnapshot.Entry.SourceClock? = nil,
         identity: SourceIdentity? = nil, requiresGeneration: Bool = true) {
        self.url = url
        self.outcome = outcome
        self.reason = reason
        self.duration = duration
        self.sourceClock = sourceClock
        self.identity = identity
        self.requiresGeneration = requiresGeneration
    }

    package func matchesGeneration(of media: MediaInfo) -> Bool {
        media.url == url && identity?.matchesSnapshot(media.identity) == true
    }

    public func checkGeneration() throws {
        guard requiresGeneration else { return }
        guard !ProjectMediaVolume.isChecking(url), identity?.isCurrentSnapshot(at: url) == true else {
            throw CutError(code: "source_changed", message: "The candidate changed before the project could be updated.")
        }
    }

    enum CodingKeys: String, CodingKey { case url, outcome, reason, duration, sourceClock = "source_clock" }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(url.path, forKey: .url)
        try fields.encode(outcome, forKey: .outcome)
        try fields.encodeIfPresent(reason, forKey: .reason)
        try fields.encodeIfPresent(duration, forKey: .duration)
        try fields.encodeIfPresent(sourceClock, forKey: .sourceClock)
    }
}

public struct ProjectMediaSearchRow: Encodable, Sendable {
    public let path: String
    public let outcome: ProjectMediaMatch
    public let candidates: [ProjectMediaCandidate]

    public init(path: String, outcome: ProjectMediaMatch, candidates: [ProjectMediaCandidate]) {
        self.path = path
        self.outcome = outcome
        self.candidates = candidates
    }

    package var eligibleMapping: ProjectMediaMapping? {
        guard outcome.canRelink, let candidate = candidates.first(where: { $0.outcome == outcome }) else {
            return nil
        }
        return .init(from: path, candidate: candidate)
    }
}

public struct ProjectMediaMapping: Sendable {
    public let from: String
    public let to: URL
    let reviewedCandidate: ProjectMediaCandidate?

    public init(from: String, to: URL) {
        self.from = from
        self.to = to
        reviewedCandidate = nil
    }

    public init(from: String, candidate: ProjectMediaCandidate) {
        self.from = from
        to = candidate.url
        reviewedCandidate = candidate
    }
}

public struct ProjectMediaRelinkResult: Sendable {
    public let project: CutProject
    public let undo: [CutHistoryState]
    public let redo: [CutHistoryState]
    public let snapshot: ProjectMediaSnapshot
    public let candidate: ProjectMediaCandidate
}

public struct ProjectMediaBatchRow: Encodable, Sendable {
    public let from: String
    public let to: URL
    public let candidate: ProjectMediaCandidate

    enum CodingKeys: String, CodingKey { case from, to, candidate }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(from, forKey: .from)
        try fields.encode(to.path, forKey: .to)
        try fields.encode(candidate, forKey: .candidate)
    }
}

public struct ProjectMediaBatchResult: Sendable {
    public let project: CutProject
    public let undo: [CutHistoryState]
    public let redo: [CutHistoryState]
    public let snapshot: ProjectMediaSnapshot
    public let rows: [ProjectMediaBatchRow]
}

extension ProjectMedia {
    public static func assess(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                              snapshot: ProjectMediaSnapshot = .init(), relativeTo document: URL,
                              from: String, to: URL, progress: ((Double) -> Void)? = nil,
                              cancelled: () -> Bool = { Task.isCancelled }) throws -> ProjectMediaCandidate {
        let space = RelinkSpace(project, undo: undo, redo: redo, snapshot: snapshot, document: document)
        return try space.inspect(from: from, to: to, progress: progress, cancelled: cancelled).candidate
    }

    public static func relink(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                              snapshot: ProjectMediaSnapshot = .init(), relativeTo document: URL,
                              from: String, to: URL, progress: ((Double) -> Void)? = nil,
                              cancelled: () -> Bool = { Task.isCancelled }) throws -> ProjectMediaRelinkResult {
        let space = RelinkSpace(project, undo: undo, redo: redo, snapshot: snapshot, document: document)
        let proposed = try space.inspect(from: from, to: to, progress: progress, cancelled: cancelled)
        guard proposed.candidate.outcome.canRelink else {
            let code = proposed.candidate.outcome == .different ? "media_relink_different" : "media_relink_pending"
            throw CutError(code: code, message: proposed.candidate.reason ?? "The recording could not be relinked.")
        }
        return try space.rewrite(from: from, using: proposed, reverting: false, cancelled: cancelled)
    }

    public static func relink(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                              snapshot: ProjectMediaSnapshot = .init(), relativeTo document: URL,
                              mappings: [ProjectMediaMapping], progress: ((Double) -> Void)? = nil,
                              cancelled: () -> Bool = { Task.isCancelled }) -> ProjectMediaBatchResult {
        var revised = project
        var updatedUndo = undo
        var updatedRedo = redo
        var saved = snapshot
        let initial = RelinkSpace(project, undo: undo, redo: redo, snapshot: snapshot, document: document)
        let fromPaths = mappings.map { initial.url($0.from) }
        let counts = Dictionary(grouping: fromPaths, by: { $0 }).mapValues(\.count)
        let destinations = mappings.map { ProjectMediaVolume.watchURL($0.to) }
        let destinationKeys = destinations.map { initial.url($0.path) }
        // Moves into a shared or existing location need to see preceding edits.
        // Independent moves can check the same states and then rewrite them once.
        let independent = Set(destinationKeys).count == mappings.count
            && destinationKeys.allSatisfy { initial.usesByURL[$0] == nil }
        var prepared: [(index: Int, change: RelinkChange)] = []
        var rows: [ProjectMediaBatchRow] = []
        for (index, mapping) in mappings.enumerated() {
            let candidate: ProjectMediaCandidate
            let source = fromPaths[index]
            let destination = destinations[index]
            let destinationKey = destinationKeys[index]
            if counts[source, default: 0] > 1 || (destinationKey != source && counts[destinationKey] != nil) {
                candidate = .init(url: destination, outcome: .different,
                                  reason: "This batch contains overlapping mappings. Choose one destination per source and apply chained moves separately.")
            } else {
                let space = independent ? initial
                    : RelinkSpace(revised, undo: updatedUndo, redo: updatedRedo, snapshot: saved, document: document)
                do {
                    try mapping.reviewedCandidate?.checkGeneration()
                    let proposed = try space.inspect(from: mapping.from, to: destination, progress: { portion in
                        progress?((Double(index) + portion) / Double(mappings.count))
                    }, cancelled: cancelled)
                    try mapping.reviewedCandidate?.checkGeneration()
                    if proposed.candidate.outcome.canRelink {
                        if independent {
                            prepared.append((index, space.change(from: mapping.from, using: proposed, reverting: false)))
                        } else {
                            let result = try space.rewrite(from: mapping.from, using: proposed, reverting: false, cancelled: cancelled)
                            revised = result.project
                            updatedUndo = result.undo
                            updatedRedo = result.redo
                            saved = result.snapshot
                        }
                    }
                    candidate = proposed.candidate
                } catch {
                    candidate = .init(url: destination, outcome: .pending, reason: Self.message(error))
                }
            }
            rows.append(.init(from: mapping.from, to: destination, candidate: candidate))
            if !independent || index + 1 < mappings.count {
                progress?(Double(index + 1) / Double(mappings.count))
            }
        }
        if !prepared.isEmpty {
            do {
                (revised, updatedUndo, updatedRedo, saved) = try initial.rewrite(prepared.map(\.change), cancelled: cancelled)
            } catch {
                // Isolate the failing row using the original inspected
                // generations. In particular, do not re-probe a changed file.
                for (index, change) in prepared {
                    do {
                        try change.inspection.candidate.checkGeneration()
                        let space = RelinkSpace(revised, undo: updatedUndo, redo: updatedRedo, snapshot: saved, document: document)
                        (revised, updatedUndo, updatedRedo, saved) = try space.rewrite([change], cancelled: cancelled)
                    } catch {
                        let row = rows[index]
                        rows[index] = .init(from: row.from, to: row.to,
                                            candidate: .init(url: row.to, outcome: .pending, reason: Self.message(error)))
                    }
                }
            }
        }
        if independent, !mappings.isEmpty { progress?(1) }
        return .init(project: revised, undo: updatedUndo, redo: updatedRedo, snapshot: saved, rows: rows)
    }

    public static func revert(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                              snapshot: ProjectMediaSnapshot = .init(), relativeTo document: URL,
                              from: String, cancelled: () -> Bool = { Task.isCancelled }) throws -> ProjectMediaRelinkResult {
        let space = RelinkSpace(project, undo: undo, redo: redo, snapshot: snapshot, document: document)
        let source = space.url(from)
        let uses = space.usesByURL[source] ?? []
        guard !uses.isEmpty, let entry = space.entry(for: source), let previous = entry.previousPath,
              let allowed = entry.relinkUses, !allowed.isEmpty,
              Set(uses.map(\.provenanceKey)).isSubset(of: Set(allowed)), space.usesByURL[space.url(previous)] == nil else {
            throw CutError(code: "media_revert_unavailable", message: "The destination has uses that cannot be traced to this relink.")
        }
        let destination = space.url(previous)
        let proposed: RelinkInspection
        if !ProjectMediaVolume.isChecking(destination), (try? SourceIdentity(destination)) != nil {
            proposed = try space.inspect(from: from, to: destination, progress: nil, cancelled: cancelled)
            // Revert restores the original reference even if its location is
            // now offline or contains different media. Do not restamp it.
            if !proposed.candidate.outcome.canRelink {
                return try space.rewrite(from: from, using: .unverifiedRevert(destination, reason: proposed.candidate.reason),
                                         reverting: true, cancelled: cancelled)
            }
        } else {
            proposed = .unverifiedRevert(destination, reason: "The previous location is offline.")
        }
        return try space.rewrite(from: from, using: proposed, reverting: true, cancelled: cancelled)
    }

    public static func prefixMappings(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                                      relativeTo document: URL, from: URL, to: URL) -> [ProjectMediaMapping] {
        let space = RelinkSpace(project, undo: undo, redo: redo, snapshot: .init(), document: document)
        let base = space.url(from.path).pathComponents
        let destinationRoot = space.url(to.path)
        return space.usesByURL.keys.sorted { $0.path < $1.path }.compactMap { url in
            let components = url.pathComponents
            guard components.starts(with: base), components.count > base.count else { return nil }
            let suffix = components.dropFirst(base.count)
            let destination = suffix.reduce(destinationRoot) { $0.appendingPathComponent($1) }
            return .init(from: url.path, to: destination)
        }
    }

    public static func locate(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                              snapshot: ProjectMediaSnapshot = .init(), relativeTo document: URL, folder: URL, includeHistory: Bool = false,
                              statuses: [URL: ProjectMediaStatus] = [:], progress: ((Double) -> Void)? = nil,
                              cancelled: () -> Bool = { Task.isCancelled }) throws -> [ProjectMediaSearchRow] {
        let space = RelinkSpace(project, undo: undo, redo: redo, snapshot: snapshot, document: document)
        let offline = inventory(project: project, undo: undo, redo: redo, relativeTo: document,
                                snapshot: snapshot, includeHistory: includeHistory, statuses: statuses).filter { $0.status == .offline }
        guard !offline.isEmpty else { return [] }
        let names = Set(offline.map { normalizedName($0.url) })
        var candidates: [String: [URL]] = [:]
        let root = space.url(folder.path)
        guard !ProjectMediaVolume.isChecking(root) else {
            throw CutError(code: "media_search_folder", message: "The selected folder is on a volume that is still checking.")
        }
        guard !root.path.split(separator: "/").contains(".."),
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw CutError(code: "media_search_folder", message: "Choose a readable folder to search for missing media.")
        }
        var visited = 0
        for case let url as URL in walk {
            try checkCancellation(cancelled)
            if ProjectMediaVolume.isChecking(url) {
                walk.skipDescendants()
                continue
            }
            visited += 1
            guard visited <= 100_000 else {
                throw CutError(code: "media_search_limit", message: "The folder contains too many entries to search. Choose a smaller folder.")
            }
            let name = normalizedName(url)
            guard names.contains(name), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            candidates[name, default: []].append(url)
        }
        return try offline.enumerated().map { index, row in
            try checkCancellation(cancelled)
            let urls = candidates[normalizedName(row.url), default: []].sorted { $0.path < $1.path }
            let inspected = try urls.map {
                try space.inspect(from: row.path, to: $0, progress: nil, cancelled: cancelled).candidate
            }
            let verified = inspected.filter { $0.outcome == .verified }
            let matches = inspected.filter { $0.outcome == .match }
            let eligible = verified.isEmpty ? matches : verified
            func relativePathRank(_ url: URL) -> Int {
                let found = url.pathComponents
                let expected = row.url.pathComponents
                let rootCount = root.pathComponents.count
                let relativeCount = max(0, found.count - rootCount)
                let indices = found.indices.dropFirst(rootCount).reversed()
                let matched = zip(indices, expected.indices.reversed()).prefix { index, oldIndex in
                    let candidate = normalizedComponent(found[index])
                    let stored = normalizedComponent(expected[oldIndex])
                    if candidate == stored { return true }
                    guard index == 2, oldIndex == 2, found[1] == "Volumes", expected[1] == "Volumes" else {
                        return false
                    }
                    return remountedVolume(candidate, named: stored) || remountedVolume(stored, named: candidate)
                }.count
                return matched * 2 + (matched == relativeCount ? 1 : 0)
            }
            let strongest = eligible.map { relativePathRank($0.url) }.max() ?? 0
            let preferred = eligible.filter { relativePathRank($0.url) == strongest }
            let unresolved = inspected.contains { $0.outcome == .pending && relativePathRank($0.url) >= strongest }
            let outcome: ProjectMediaMatch
            if preferred.count > 1 { outcome = .ambiguous }
            else if unresolved { outcome = .pending }
            else { outcome = preferred.first?.outcome ?? (inspected.isEmpty ? .pending : .different) }
            let others = inspected.filter { row in !preferred.contains { $0.url == row.url } }
            progress?(Double(index + 1) / Double(offline.count))
            return .init(path: row.path, outcome: outcome, candidates: preferred + others)
        }
    }

    private static func normalizedName(_ url: URL) -> String {
        normalizedComponent(url.lastPathComponent)
    }

    private static func normalizedComponent(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func remountedVolume(_ candidate: String, named stored: String) -> Bool {
        let prefix = stored + " "
        guard candidate.hasPrefix(prefix), let suffix = Int(candidate.dropFirst(prefix.count)) else { return false }
        return suffix > 0
    }

    fileprivate static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }

    fileprivate static func message(_ error: Error) -> String {
        (error as? CutError)?.message ?? (error is CancellationError ? "Media search was cancelled." : error.localizedDescription)
    }
}

private struct RelinkInspection {
    let candidate: ProjectMediaCandidate
    var entry: ProjectMediaSnapshot.Entry?
    var participantDigest: String?

    static func unverifiedRevert(_ url: URL, reason: String?) -> Self {
        .init(candidate: .init(url: url, outcome: .pending, reason: reason, requiresGeneration: false))
    }

    static func verifiesGeometry(digest: String?, stamp: SceneSourceStamp?, inode: UInt64?,
                                 inspectedDigest: String?, verifiedSourceFingerprint: String?) -> Bool {
        if let digest { return digest == inspectedDigest }
        guard let stamp, let inode, let verifiedSourceFingerprint else { return false }
        let value = "\(inode):\(stamp.bytes):\(stamp.modifiedSeconds):\(stamp.modifiedNanoseconds)"
        return TranscriptStore.digest(Data(value.utf8)) == verifiedSourceFingerprint
    }

    func verifiesGeometry(_ geometry: ParticipantSourceGeometry, old: ProjectMediaSnapshot.Entry?) -> Bool {
        Self.verifiesGeometry(digest: geometry.sourceContentSHA256, stamp: geometry.sourceStamp,
                              inode: geometry.sourceInode, inspectedDigest: participantDigest,
                              verifiedSourceFingerprint: candidate.outcome == .verified ? old?.sourceFingerprint : nil)
    }
}

private struct RelinkChange {
    let from: String
    let source: URL
    let destination: URL
    let storedDestination: String
    let oldPaths: Set<String>
    let previous: ProjectMediaSnapshot.Entry?
    let inspection: RelinkInspection
    let reverting: Bool
}

private struct RelinkSpace {
    let project: CutProject
    let undo: [CutHistoryState]
    let redo: [CutHistoryState]
    let document: URL
    let usesByURL: [URL: [ProjectMediaUse]]
    let entriesByURL: [URL: [ProjectMediaSnapshot.Entry]]

    init(_ project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState],
         snapshot: ProjectMediaSnapshot, document: URL) {
        self.project = project
        self.undo = undo
        self.redo = redo
        self.document = document
        let states = [project] + undo.map(\.project) + redo.map(\.project)
        var resolved: [String: URL] = [:]
        func location(_ path: String) -> URL {
            if let url = resolved[path] { return url }
            let url = Self.url(path, relativeTo: document)
            resolved[path] = url
            return url
        }
        usesByURL = Dictionary(grouping: Set(states.flatMap { ProjectMedia.references(in: $0) })) { location($0.path) }
        entriesByURL = Dictionary(grouping: snapshot.entries) { location($0.path) }
    }

    private static func url(_ path: String, relativeTo document: URL) -> URL {
        let watched = ProjectMediaVolume.watchURL(path, relativeTo: document)
        guard !ProjectMediaVolume.isChecking(watched) else { return watched }
        return ProjectFile.canonicalFileURL(CutProject.mediaURL(path, relativeTo: document))
    }

    func url(_ path: String) -> URL {
        Self.url(path, relativeTo: document)
    }

    func entry(for source: URL) -> ProjectMediaSnapshot.Entry? {
        entriesByURL[source, default: []].reduce(nil) { combined, entry in
            combined?.coalescingAlias(entry) ?? entry
        }
    }

    func inspect(from: String, to chosen: URL, progress: ((Double) -> Void)?,
                 cancelled: () -> Bool) throws -> RelinkInspection {
        try ProjectMedia.checkCancellation(cancelled)
        let source = url(from)
        let chosenPath = ProjectMediaVolume.watchURL(chosen)
        let candidateURL = ProjectMediaVolume.isChecking(chosenPath) ? chosenPath
            : CutProject.mediaURL(chosenPath.path, relativeTo: document)
        func rejection(_ outcome: ProjectMediaMatch, _ reason: String, duration: RationalTime? = nil) -> RelinkInspection {
            .init(candidate: .init(url: candidateURL, outcome: outcome, reason: reason, duration: duration))
        }
        guard let uses = usesByURL[source], !uses.isEmpty else {
            return rejection(.different, "The specified source has no uses in this project or its retained history.")
        }
        let destination = url(candidateURL.path)
        if source == destination {
            return rejection(.different, "Select a different location for the source.")
        }
        guard !candidateURL.path.split(separator: "/").contains("..") else {
            return rejection(.pending, "The candidate path has an unavailable parent directory.")
        }
        let saved = entry(for: source)
        let independentUses = usesByURL[destination] ?? []
        let destinationEntry = independentUses.isEmpty ? nil : entry(for: destination)
        let still = uses.contains { $0.kind == .still }
        if (uses + independentUses).contains(where: { ($0.kind == .still) != still }) {
            return rejection(.different, "These paths have incompatible still image and recording uses.")
        }
        guard !ProjectMediaVolume.isChecking(candidateURL) else {
            return rejection(.pending, "The candidate volume is still checking.")
        }
        do {
            let identity = try SourceIdentity(candidateURL)
            if still {
                let (info, digest) = try withoutActuallyEscaping(cancelled) {
                    try StillImage.inspectAndFingerprint(candidateURL, expectedIdentity: identity, cancelled: $0)
                }
                let assets = ([project] + undo.map(\.project) + redo.map(\.project)).flatMap(\.stillAssets)
                let known = stillFingerprints(assets: assets, at: source, snapshot: saved)
                let independent = stillFingerprints(assets: assets, at: destination, snapshot: destinationEntry)
                guard known.union(independent).isSubset(of: [digest]) else {
                    return rejection(.different, "The still image fingerprint differs from an affected use.")
                }
                if let bytes = saved?.size, known.isEmpty, bytes != identity.size {
                    return rejection(.different, "The candidate file size differs from the saved source.")
                }
                var entry = ProjectMediaSnapshot.Entry(path: from)
                entry.size = identity.size
                entry.modifiedSeconds = identity.modifiedSeconds
                entry.modifiedNanoseconds = identity.modifiedNanoseconds
                entry.width = info.displayWidth
                entry.height = info.displayHeight
                entry.stillSHA256 = digest
                return .init(candidate: .init(url: candidateURL, outcome: known.isEmpty ? .match : .verified,
                                             identity: identity), entry: entry)
            }
            let requiresProof = saved?.hasCompleteProof == true || destinationEntry?.hasCompleteProof == true
            let media = try withoutActuallyEscaping(cancelled) {
                try Probe.read(candidateURL, forcePayload: requiresProof, expectedIdentity: identity,
                               progress: progress, cancelled: $0)
            }
            let duration = media.duration
            var reasons = Set<String>()
            reasons.formUnion(try (uses + independentUses).flatMap { try issues(in: $0, media: media) })
            for streams in [saved?.streams, destinationEntry?.streams].compactMap({ $0 }) {
                let current = media.streams.map { [String($0.index), $0.kind, String($0.channels), $0.language] }
                let expected = streams.map { [String($0.index), $0.kind, String($0.channels), $0.language] }
                if current != expected { reasons.insert("The stream layout differs from a saved source.") }
            }
            guard reasons.isEmpty else {
                return rejection(.different, reasons.sorted().joined(separator: " "), duration: duration)
            }
            guard !requiresProof || media.snapshotEvidence?.hasCompleteProof == true else {
                return rejection(.pending, "Comparable content evidence could not be collected.", duration: duration)
            }
            let verifies = saved?.verifies(media) == true
            if saved?.hasCompleteProof == true, !verifies {
                return rejection(.different, "The candidate's recording content differs from the saved source.", duration: duration)
            }
            let destinationVerifies = destinationEntry?.verifies(media) == true
            if destinationEntry?.hasCompleteProof == true, !destinationVerifies {
                return rejection(.different, "The candidate differs from the recording already referenced at its destination.", duration: duration)
            }
            let unverifiedEntries = [verifies ? nil : saved, destinationVerifies ? nil : destinationEntry].compactMap { $0 }
            for entry in unverifiedEntries {
                if let size = entry.size, size != identity.size {
                    return rejection(.different, "The candidate file size differs from a saved source.", duration: duration)
                }
                if let previous = entry.duration, duration != previous {
                    return rejection(.different, "The candidate duration differs from a saved source.", duration: duration)
                }
            }

            let digests = Set(uses.compactMap(\.participantDigest))
            let participantDigest = digests.isEmpty ? nil : try participantSourceDigest(candidateURL, identity: identity, cancelled: cancelled)
            let updated = ProjectMediaSnapshot.Entry(path: from, media: media)
            let needsGeometryReview = uses.contains { use in
                use.participantGeometry && !RelinkInspection.verifiesGeometry(
                    digest: use.participantDigest, stamp: use.participantStamp, inode: use.participantInode,
                    inspectedDigest: participantDigest, verifiedSourceFingerprint: verifies ? saved?.sourceFingerprint : nil
                )
            }
            let note = needsGeometryReview ? "Some accepted participant geometry needs review." : nil
            let candidate = ProjectMediaCandidate(url: candidateURL, outcome: verifies ? .verified : .match,
                                                  reason: note, duration: duration, sourceClock: updated.sourceClock,
                                                  identity: media.identity)
            try candidate.checkGeneration()
            return .init(candidate: candidate, entry: updated, participantDigest: participantDigest)
        } catch {
            try ProjectMedia.checkCancellation(cancelled)
            return rejection(.pending, ProjectMedia.message(error))
        }
    }

    private func stillFingerprints(assets: [StillAsset], at location: URL, snapshot: ProjectMediaSnapshot.Entry?) -> Set<String> {
        let digests = assets.filter { !$0.isGap && url($0.file) == location }.map(\.fingerprint)
        return Set((digests + [snapshot?.stillSHA256].compactMap { $0 }).filter(TranscriptStore.validDigest))
    }

}

private extension RelinkSpace {
    func issues(in use: ProjectMediaUse, media: MediaInfo) throws -> [String] {
        let label = "\(use.kind.rawValue) ‘\(use.id)’"
        var issues: [String] = []
        if use.picture && !media.hasVideo {
            issues.append("\(label) requires picture.")
        }
        let audioStreams = media.streams.filter { $0.kind == "audio" }
        let ordinal = use.ordinal.flatMap { audioStreams.indices.contains($0) ? audioStreams[$0] : nil }
        let selected = use.stream.flatMap { index in audioStreams.first { $0.index == index } }
        if (use.ordinal != nil && ordinal == nil) || (use.stream != nil && selected == nil)
            || (use.audio && audioStreams.isEmpty) {
            issues.append("\(label) requires an audio track missing from the candidate.")
        }
        let stream = selected ?? ordinal ?? (use.audio && !use.picture ? audioStreams.first : nil)
        if let channel = use.channel, let stream, !(0..<stream.channels).contains(channel) {
            issues.append("\(label) requires channel \(channel) of stream \(stream.index).")
        }
        let sourceOffset = use.multicamClock || use.kind == .transcriptAnchor ? media.multicamSourceOffset : .zero
        let audio = stream.flatMap { stream in media.audio.first { $0.stream.index == stream.index } }
        let fullEnd = try (audio?.end ?? media.duration).adding(sourceOffset)
        let first = try (audio?.start ?? .zero).adding(sourceOffset)
        if let minimumTime = use.minimumTime, minimumTime >= fullEnd {
            issues.append("\(label) extends beyond the candidate's replacement audio.")
        }
        if let range = use.range {
            let offset = use.offset ?? .zero
            let from: RationalTime
            let to: RationalTime
            if use.kind == .transcriptAnchor {
                // Authored anchors keep the transcript's original coordinates.
                let adjustment = try offset.adding(use.transcriptImportOrigin ?? .zero)
                from = try range.from.adding(adjustment)
                to = try range.to.adding(adjustment)
            } else {
                from = try range.from.subtracting(offset)
                to = try range.to.subtracting(offset)
            }
            let validStart = from >= first || (use.mayStartWithSilence && stream?.isPCM == true && from >= .zero)
            if !validStart || to > fullEnd || from >= fullEnd {
                issues.append("\(label) uses \(range.from)–\(range.to), outside the candidate's available range.")
            }
        }
        return issues
    }

    func change(from: String, using inspection: RelinkInspection, reverting: Bool) -> RelinkChange {
        let source = url(from)
        let destination = inspection.candidate.url
        let previous = entry(for: source)
        let storedDestination: String
        if reverting, let path = previous?.previousPath {
            storedDestination = path
        } else {
            storedDestination = CutProject.relativeMediaPath(destination.path, to: document)
        }
        return .init(from: from, source: source, destination: url(destination.path), storedDestination: storedDestination,
                     oldPaths: Set(usesByURL[source, default: []].map(\.path)), previous: previous,
                     inspection: inspection, reverting: reverting)
    }

    func rewrite(from: String, using inspection: RelinkInspection, reverting: Bool,
                 cancelled: () -> Bool) throws -> ProjectMediaRelinkResult {
        let (project, undo, redo, snapshot) = try rewrite([change(from: from, using: inspection, reverting: reverting)],
                                                         cancelled: cancelled)
        return .init(project: project, undo: undo, redo: redo, snapshot: snapshot, candidate: inspection.candidate)
    }

    func rewrite(_ changes: [RelinkChange], cancelled: () -> Bool) throws
        -> (CutProject, [CutHistoryState], [CutHistoryState], ProjectMediaSnapshot) {
        try ProjectMedia.checkCancellation(cancelled)
        var byPath: [String: RelinkChange] = [:]
        for change in changes {
            for path in change.oldPaths { byPath[path] = change }
        }
        func transform(_ path: String) -> String { byPath[path]?.storedDestination ?? path }

        func sourceFiles(_ state: CutProject) -> [String: String] {
            guard case .multicam(let multicam) = state else { return [:] }
            return Dictionary(multicam.sources.map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
        }

        func rewriteBinding(_ binding: TranscriptBinding, recordings: [String: String],
                            changed: (URL) -> Void = { _ in }) -> TranscriptBinding {
            guard let path = binding.file ?? binding.sourceID.flatMap({ recordings[$0] }),
                  let change = byPath[path] else { return binding }
            var value = binding
            value.file = binding.file.map { _ in change.storedDestination }
            if change.inspection.candidate.outcome == .verified,
               let oldFingerprint = change.previous?.sourceFingerprint, oldFingerprint == binding.sourceFingerprint,
               let fingerprint = change.inspection.entry?.sourceFingerprint {
                value.sourceFingerprint = fingerprint
            }
            if value != binding { changed(change.source) }
            return value
        }

        func rewriteState(_ state: CutProject) throws -> CutProject {
            try ProjectMedia.checkCancellation(cancelled)
            let recordings = sourceFiles(state)
            var updated = state.mapMediaPaths(transform)
            var transcripts = state.transcripts
            var changedSources = Set<URL>()
            func rewriteTranscriptBinding(_ binding: TranscriptBinding) -> TranscriptBinding {
                rewriteBinding(binding, recordings: recordings) { changedSources.insert($0) }
            }
            for index in transcripts.attachments.indices {
                transcripts.attachments[index].bindings = transcripts.attachments[index].bindings.map(rewriteTranscriptBinding)
            }
            transcripts.authoring = transcripts.authoring.map { record in
                func rewriteAnchor(_ original: TranscriptAnchor) -> TranscriptAnchor {
                    var anchor = original
                    anchor.binding = rewriteTranscriptBinding(anchor.binding)
                    return anchor
                }
                return .init(id: record.id, attachmentID: record.attachmentID, change: record.change,
                             anchors: record.anchors.map(rewriteAnchor), speakerReference: record.speakerReference.map(rewriteAnchor))
            }
            if !changedSources.isEmpty {
                for _ in changedSources { try transcripts.advanceRevision() }
                updated.transcripts = transcripts
            }

            var participants = updated.participants
            let participantIDs = Set(participants.people.map(\.id))
            for index in participants.sources.indices {
                let geometry = state.participants.sources[index]
                let path = state.sequenceItems != nil ? geometry.sourceID : recordings[geometry.sourceID]
                guard let change = path.flatMap({ byPath[$0] }) else { continue }
                participants.sources[index].confirmations = nil
                if let identity = change.inspection.candidate.identity,
                   change.inspection.verifiesGeometry(geometry, old: change.previous) {
                    participants.sources[index].sourceStamp = SceneSourceStamp(identity: identity)
                    participants.sources[index].sourceInode = identity.inode
                } else {
                    // Keep authored geometry and overrides available for review,
                    // but require privacy decisions to be checked on the candidate.
                    participants.sources[index].unresolvedParticipantIDs =
                        participantIDs.union(geometry.unresolvedParticipantIDs).sorted()
                }
            }
            if participants != updated.participants { updated.participants = participants }
            if changes.contains(where: { $0.inspection.entry?.stillSHA256 != nil }) {
                func stamp(_ assets: inout [StillAsset], previous: [StillAsset]) {
                    for i in assets.indices where !previous[i].isGap {
                        if let digest = byPath[previous[i].file]?.inspection.entry?.stillSHA256 {
                            assets[i].fingerprint = digest
                        }
                    }
                }
                switch updated {
                case .stillSequence(var sequence):
                    stamp(&sequence.stillAssets, previous: state.stillAssets)
                    updated = .stillSequence(sequence)
                case .multicam(var multicam):
                    stamp(&multicam.stillAssets, previous: state.stillAssets)
                    updated = .multicam(multicam)
                case .sequence:
                    break
                }
            }
            try updated.validate()
            return updated
        }

        let edited = try rewriteState(project)
        func rewriteBranch(_ stack: [CutHistoryState]) throws -> [CutHistoryState] {
            var previous = project
            return try stack.reversed().map { state in
                let before = sourceFiles(previous)
                let after = sourceFiles(state.project)
                let changes = state.bindingChanges?.map {
                    $0.mappingBindings(before: { rewriteBinding($0, recordings: before) },
                                       after: { rewriteBinding($0, recordings: after) })
                }.filter { $0.before != $0.after }
                previous = state.project
                return try CutHistoryState(action: state.action, origin: state.origin, project: rewriteState(state.project),
                                           bindingChanges: changes)
            }.reversed()
        }
        let revisedUndo = try rewriteBranch(undo)
        let revisedRedo = try rewriteBranch(redo)
        let changedURLs = Set(changes.flatMap { [$0.source, $0.destination] })
        let provenancePaths = Set(changes.compactMap { change in
            !change.reverting && usesByURL[change.destination] == nil ? change.storedDestination : nil
        })
        var provenance: [String: Set<String>] = [:]
        if !provenancePaths.isEmpty {
            var seen = Set<ProjectMediaUse>()
            for state in [edited] + revisedUndo.map(\.project) + revisedRedo.map(\.project) {
                try ProjectMedia.checkCancellation(cancelled)
                for use in ProjectMedia.references(in: state)
                    where provenancePaths.contains(use.path) && seen.insert(use).inserted {
                    provenance[use.path, default: []].insert(use.provenanceKey)
                }
            }
        }
        var entries = entriesByURL.filter { !changedURLs.contains($0.key) }.values.flatMap { $0 }
        for change in changes {
            let storedDestination = change.storedDestination
            let destinationPaths = Set(usesByURL[change.destination, default: []].map(\.path))
            let destinationEntries = Dictionary(entriesByURL[change.destination, default: []]
                .map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var entry = change.inspection.entry ?? .init(path: storedDestination)
            entry.path = storedDestination
            entry.unknownFields = change.previous?.unknownFields ?? [:]
            if provenancePaths.contains(storedDestination) {
                entry.previousPath = change.oldPaths.min() ?? change.from
                entry.relinkUses = provenance[storedDestination, default: []].sorted()
            }
            // The archive retains entries by stored path, including aliases
            // still used by independently imported media at the destination.
            for path in destinationPaths.union([storedDestination]).sorted() {
                var alias = entry
                alias.path = path
                if let saved = destinationEntries[path] {
                    if destinationPaths.contains(path) {
                        alias = saved
                        alias.previousPath = nil
                        alias.relinkUses = nil
                    }
                    alias.unknownFields.merge(saved.unknownFields) { _, destination in destination }
                    if path == storedDestination {
                        alias.unknownFields.merge(entry.unknownFields) { destination, _ in destination }
                    }
                }
                entries.append(alias)
            }
            try change.inspection.candidate.checkGeneration()
        }
        return (edited, revisedUndo, revisedRedo, .init(entries: entries.sorted { $0.path < $1.path }))
    }
}
