import AppKit
import CryptoKit
import Darwin
import MPCutCore

extension Notification.Name {
    static let didSaveTileReview = Self("MPCut.didSaveTileReview")
}

/// Pending detector data lives in a companion directory that can travel with its cut.
struct TilesPendingReviewStore: Sendable {
    private struct Binding: Codable {
        let artifact: String
        let sha256: String
        var analysisIdentity: String?
    }

    private let directory: URL
    private let legacyDirectory: URL
    private static func key(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    init(project: URL, recordingID: String) {
        let project = project.standardizedFileURL
        let resourceKey = recordingID.hasPrefix("/")
            ? "relative:" + CutProject.relativeMediaPath(recordingID, to: project)
            : "id:" + recordingID
        directory = project.appendingPathExtension("tile-review").appendingPathComponent(Self.key(resourceKey))
        legacyDirectory = URL.applicationSupportDirectory.appending(path: "MPCut/Tile Reviews", directoryHint: .isDirectory)
            .appendingPathComponent(Self.key(project.path + "\u{0}" + recordingID))
    }

    /// Stable notification address. The manifest selects an immutable generation.
    var scanURL: URL { directory.appending(path: "scan.json") }
    private var bindingURL: URL { directory.appending(path: "binding.json") }
    private var choicesURL: URL { directory.appending(path: "review.json") }

    /// Lock the recording directory itself so readers in other editor processes
    /// can pin a generation before a writer retires it. Reading an unopened
    /// project does not create a companion directory.
    private func withDirectoryLock<T>(exclusive: Bool, create: Bool = false,
                                      _ body: (Bool) throws -> T) throws -> T {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT, !create { return try body(false) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        while flock(fd, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body(true)
    }

    private func binding() throws -> Binding? {
        guard FileManager.default.fileExists(atPath: bindingURL.path) else { return nil }
        let item = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: bindingURL))
        let stem = String(item.artifact.dropLast(5))
        guard item.artifact.hasSuffix(".json"), UUID(uuidString: stem) != nil else {
            throw CutError(code: "invalid_pending_tile_scan", message: "The pending tile scan reference is damaged. Find tiles again.")
        }
        return item
    }

    func load(recording: URL? = nil) throws -> (ParticipantScanResult, TilesReviewChoices)? {
        let snapshot = try withDirectoryLock(exclusive: false) { exists -> (Binding?, Data, [TilesReviewChoices])? in
            let item = exists ? try binding() : nil
            let url = item.map { directory.appending(path: $0.artifact) }
                ?? legacyDirectory.appending(path: "scan.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                if item != nil {
                    throw CutError(code: "missing_pending_tile_scan", message: "The pending tile scan is missing. Find tiles again.")
                }
                return nil
            }
            return try (item, Data(contentsOf: url, options: .mappedIfSafe), savedChoices())
        }
        guard let (item, data, choices) = snapshot else { return nil }
        if let item, Self.hex(SHA256.hash(data: data)) != item.sha256 {
            throw CutError(code: "invalid_pending_tile_scan", message: "The pending tile scan changed. Find tiles again.")
        }
        var scan = try JSONDecoder().decode(ParticipantScanResult.self, from: data)
        if let recording, item != nil {
            scan = try scan.rebindingPendingReview(to: recording)
        }
        return (scan, choices.first { $0.analysisIdentity == scan.analysisIdentity } ?? .init(scan: scan))
    }

    private func savedChoices() -> [TilesReviewChoices] {
        [choicesURL, legacyDirectory.appending(path: "review.json")].compactMap { url in
            try? JSONDecoder().decode(TilesReviewChoices.self, from: Data(contentsOf: url))
        }
    }

    @discardableResult
    func save(_ scan: ParticipantScanResult, adoptingCountHints: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".json"
        let artifact = directory.appending(path: name)
        FileManager.default.createFile(atPath: artifact.path, contents: nil)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: artifact) } }
        let handle = try FileHandle(forWritingTo: artifact)
        defer { try? handle.close() }
        var hash = SHA256()
        try scan.writeJSON(pretty: false) { chunk in
            hash.update(data: chunk)
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
        try handle.close()
        let entry = Binding(artifact: name, sha256: Self.hex(hash.finalize()), analysisIdentity: scan.analysisIdentity)
        try withDirectoryLock(exclusive: true) { exists in
            guard exists, FileManager.default.fileExists(atPath: artifact.path) else {
                throw CutError(code: "missing_pending_tile_scan", message: "The pending review was discarded while saving.")
            }
            let previous = try? binding()
            try JSONEncoder().encode(entry).write(to: bindingURL, options: .atomic)
            published = true
            if let previous { try? FileManager.default.removeItem(at: directory.appending(path: previous.artifact)) }
            if adoptingCountHints, let hints = scan.countHints {
                var review = savedChoices().first { $0.analysisIdentity == scan.analysisIdentity } ?? .init(scan: scan)
                if let feeds = hints.expectedFeeds { review.expectedFeeds = String(feeds) }
                if let tiles = hints.maxVisibleTiles { review.expectedTiles = String(tiles) }
                try writeChoices(review)
            }
        }
        NotificationCenter.default.post(name: .didSaveTileReview, object: scanURL)
        return artifact
    }

    func save(_ choices: TilesReviewChoices) throws {
        try withDirectoryLock(exclusive: true, create: true) { _ in
            if let identity = try binding()?.analysisIdentity, identity != choices.analysisIdentity {
                throw CutError(code: "stale_scan", message: "A newer tile scan is ready. Reload the review before editing.")
            }
            try writeChoices(choices)
        }
    }

    private func writeChoices(_ choices: TilesReviewChoices) throws {
        try JSONEncoder().encode(choices).write(to: choicesURL, options: .atomic)
    }

    private func stageReview(from former: Self) throws -> Binding? {
        try former.withDirectoryLock(exclusive: false) { exists in
            try stageReview(from: former, binding: exists ? former.binding() : nil)
        }
    }

    private func stageReview(from former: Self, binding item: Binding?) throws -> Binding? {
        let files = FileManager.default
        guard let item else {
            guard let (scan, choices) = try former.load() else { return nil }
            try save(choices)
            try save(scan)
            return try binding()
        }
        let source = former.directory.appending(path: item.artifact)
        guard files.fileExists(atPath: source.path) else {
            throw CutError(code: "missing_pending_tile_scan", message: "The pending tile scan is missing. Find tiles again.")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appending(path: item.artifact)
        try files.copyItem(at: source, to: artifact)
        let data = try Data(contentsOf: artifact, options: .mappedIfSafe)
        guard Self.hex(SHA256.hash(data: data)) == item.sha256 else {
            throw CutError(code: "invalid_pending_tile_scan", message: "The pending tile scan changed. Find tiles again.")
        }
        if files.fileExists(atPath: former.choicesURL.path) {
            try files.copyItem(at: former.choicesURL, to: choicesURL)
        }
        return item
    }

    private func publish(_ item: Binding, from stage: Self) throws {
        let files = FileManager.default
        let previous = try? binding()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Each transfer gets a new generation, including when the destination
        // already has an older copy of the same scan.
        let name = UUID().uuidString + ".json"
        let artifact = directory.appending(path: name)
        try files.moveItem(at: stage.directory.appending(path: item.artifact), to: artifact)
        var published = false
        defer { if !published { try? files.removeItem(at: artifact) } }
        if files.fileExists(atPath: stage.choicesURL.path) {
            try Data(contentsOf: stage.choicesURL).write(to: choicesURL, options: .atomic)
        } else if files.fileExists(atPath: choicesURL.path) {
            try files.removeItem(at: choicesURL)
        }
        try JSONEncoder().encode(Binding(artifact: name, sha256: item.sha256, analysisIdentity: item.analysisIdentity)).write(to: bindingURL, options: .atomic)
        published = true
        if let previous { try? files.removeItem(at: directory.appending(path: previous.artifact)) }
    }

    /// Prepare all companions before saving and publish them only after the
    /// document writer accepts the destination and commits its revision.
    static func carryReviews<T>(from source: URL?, to destination: URL, recordingIDs: Set<String>,
                                writingDocument: () throws -> T) throws -> T {
        guard source?.standardizedFileURL != destination.standardizedFileURL else { return try writingDocument() }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".mpcut-review-" + UUID().uuidString)
        defer { discardDraft(at: stage) }
        var transfers: [(target: Self, stage: Self, item: Binding?)] = []
        for id in recordingIDs {
            let staged = Self(project: stage, recordingID: id)
            let item = try source.flatMap { try staged.stageReview(from: Self(project: $0, recordingID: id)) }
            transfers.append((Self(project: destination, recordingID: id), staged, item))
        }
        let result = try writingDocument()
        for transfer in transfers {
            if let item = transfer.item {
                try transfer.target.withDirectoryLock(exclusive: true, create: true) { _ in
                    try transfer.target.publish(item, from: transfer.stage)
                }
            } else {
                try transfer.target.remove()
            }
        }
        return result
    }

    static func discardDraft(at url: URL) {
        try? FileManager.default.removeItem(at: url.appendingPathExtension("tile-review"))
    }

    func remove() throws {
        try withDirectoryLock(exclusive: true) { exists in try remove(hasDirectory: exists) }
    }

    private func remove(hasDirectory: Bool) throws {
        let files = FileManager.default
        if hasDirectory, let item = try? binding() {
            let url = directory.appending(path: item.artifact)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
        let urls = (hasDirectory ? [bindingURL, choicesURL] : [])
            + [legacyDirectory.appending(path: "scan.json"), legacyDirectory.appending(path: "review.json")]
        for url in urls where files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
    }
}

struct ParticipantPendingTilePreview {
    let sourceID: String
    let stamp: SceneSourceStamp
    let analysis: ParticipantTrackingResult
    let grids: [TilesReviewChoices.GridCorrection]
    private let appearanceEnds: [UInt64: RationalTime]

    init(sourceID: String, stamp: SceneSourceStamp, analysis: ParticipantTrackingResult,
         grids: [TilesReviewChoices.GridCorrection]) {
        self.sourceID = sourceID
        self.stamp = stamp
        self.analysis = analysis
        self.grids = grids
        appearanceEnds = Dictionary(analysis.appearances.map { ($0.id, $0.end) }, uniquingKeysWith: min)
    }

    func boxes(at time: RationalTime) -> [CGRect] {
        if let grid = grids.last(where: { $0.isValid && $0.range.contains(time) }) {
            let cellWidth = 1 / Double(grid.columns)
            let cellHeight = 1 / Double(grid.rows)
            return (0..<(grid.columns * grid.rows)).map { cell in
                .init(x: Double(cell % grid.columns) * cellWidth, y: Double(cell / grid.columns) * cellHeight,
                      width: cellWidth, height: cellHeight)
            }
        }
        guard analysis.start <= time, time < (analysis.resumeAt ?? analysis.end) else { return [] }
        let observations = analysis.observations
        let after = observations.lowerBound { $0.time > time }
        guard after > 0 else { return [] }
        return observations[after - 1].regions.compactMap { region in
            if let end = appearanceEnds[region.appearanceID], time >= end { return nil }
            return .init(x: region.rect.x, y: region.rect.y, width: region.rect.width, height: region.rect.height)
        }
    }
}

struct TilesReviewChoices: Codable, Sendable {
    var analysisIdentity = ""
    var names: [String: String] = [:]
    var unchecked: Set<String> = []
    var merged: [String: String] = [:]
    var expectedFeeds = ""
    var expectedTiles = ""
    var editedHints: Bool?
    var grids: [GridCorrection] = []

    init() {}

    init(analysisIdentity: String, expectedFeeds: String = "", expectedTiles: String = "") {
        self.analysisIdentity = analysisIdentity
        self.expectedFeeds = expectedFeeds
        self.expectedTiles = expectedTiles
    }

    init(scan: ParticipantScanResult) {
        self.init(analysisIdentity: scan.analysisIdentity,
                  expectedFeeds: scan.countHints?.expectedFeeds.map(String.init) ?? "",
                  expectedTiles: scan.countHints?.maxVisibleTiles.map(String.init) ?? "")
    }

    struct GridCorrection: Codable, Equatable, Sendable {
        let range: MulticamRange
        let columns: Int
        let rows: Int

        var isValid: Bool {
            (1...64).contains(columns) && (1...64).contains(rows) && columns * rows <= 64
        }
    }

    func maximumVisibleTiles(in scan: ParticipantScanResult, rawMaximum: Int) -> Int {
        guard let analysis = scan.analysis, !grids.isEmpty else { return rawMaximum }
        let valid = grids.filter(\.isValid)
        guard !valid.isEmpty else { return rawMaximum }
        let boundaries = valid.flatMap { [$0.range.from, $0.range.to] }
            .filter { analysis.start <= $0 && $0 < analysis.end }.sorted()
        let observations = analysis.observations
        var observation = 0
        var boundary = 0
        var detectedCount = 0
        var maximum = 0
        while observation < observations.count || boundary < boundaries.count {
            let nextObservation = observation < observations.count ? observations[observation].time : nil
            let time: RationalTime
            if boundary < boundaries.count, nextObservation.map({ boundaries[boundary] <= $0 }) ?? true {
                time = boundaries[boundary]
                boundary += 1
            } else if let nextObservation {
                time = nextObservation
            } else {
                break
            }
            while observation < observations.count, observations[observation].time <= time {
                detectedCount = observations[observation].regions.count
                observation += 1
            }
            let correctedCount = valid.last(where: { $0.range.contains(time) }).map { $0.columns * $0.rows }
            maximum = max(correctedCount ?? detectedCount, maximum)
        }
        return maximum
    }

    mutating func merge(_ from: String, into to: String) {
        guard from != to, merged[from] == nil, merged[to] == nil else { return }
        for key in merged.keys.filter({ merged[$0] == from }) { merged[key] = to }
        merged[from] = to
    }
}

struct TilesReviewCard: Identifiable, Sendable {
    let id: String
    let name: String
    private(set) var ranges: [MulticamRange]
    let representative: ParticipantRegion
    let time: RationalTime
    private(set) var duration: Double = 0

    private mutating func coalesceRanges() {
        var combined: [MulticamRange] = []
        for range in ranges.sorted(by: { $0.from < $1.from }) where range.to > max(.zero, range.from) {
            if let last = combined.last, range.from <= last.to {
                combined[combined.count - 1].to = max(last.to, range.to)
            } else {
                combined.append(.init(from: max(.zero, range.from), to: range.to))
            }
        }
        ranges = combined
        duration = combined.reduce(0) { $0 + ($1.to.seconds - $1.from.seconds) }
    }

    static func applyingMerges(_ merged: [String: String], to cards: [Self]) -> [Self] {
        guard !merged.isEmpty else { return cards }
        var extraRanges: [String: [MulticamRange]] = [:]
        for card in cards {
            if let target = merged[card.id] {
                extraRanges[target, default: []].append(contentsOf: card.ranges)
            }
        }
        return cards.compactMap { card in
            guard merged[card.id] == nil else { return nil }
            guard let additional = extraRanges[card.id] else { return card }
            var updated = card
            updated.ranges.append(contentsOf: additional)
            updated.coalesceRanges()
            return updated
        }
    }

    private enum Key: Hashable {
        case share(UInt64)
        case feed(UInt64)

        var id: String {
            switch self {
            case .share(let id): "share-\(id)"
            case .feed(let id): "feed-\(id)"
            }
        }

        var name: String {
            switch self {
            case .share: "Screen share"
            case .feed(let id): "Feed \(id)"
            }
        }
    }

    static func list(_ scan: ParticipantScanResult) -> (cards: [Self], visible: Int) {
        guard let analysis = scan.analysis else { return ([], 0) }
        var representatives: [Key: (region: ParticipantRegion, time: RationalTime)] = [:]
        var visible = 0
        for observation in analysis.observations {
            visible = max(visible, observation.regions.count)
            for region in observation.regions {
                let key: Key
                if region.kind == .screenShare {
                    key = .share(region.appearanceID)
                } else if let id = region.participantID {
                    key = .feed(id)
                } else {
                    continue
                }
                if let current = representatives[key], current.region.kind == .video || region.kind != .video { continue }
                representatives[key] = (region, observation.time)
            }
        }
        var ranges: [Key: [MulticamRange]] = [:]
        for appearance in analysis.appearances {
            let share = Key.share(appearance.id)
            let key = representatives[share] != nil ? share : appearance.participantID.map(Key.feed)
            if let key, representatives[key] != nil {
                ranges[key, default: []].append(.init(from: appearance.start, to: appearance.end))
            }
        }
        let cards = representatives.map { key, candidate in
            var card = Self(id: key.id, name: key.name, ranges: ranges[key] ?? [],
                            representative: candidate.region, time: candidate.time)
            card.coalesceRanges()
            return card
        }
        return (cards.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }, visible)
    }
}

extension TilesReviewChoices {
    func apply(to project: inout ParticipantProject, sourceID: String, analysisIdentity: String) throws {
        guard self.analysisIdentity == analysisIdentity,
              let index = project.sources.firstIndex(where: { $0.sourceID == sourceID }) else { return }
        let source = project.sources[index]
        let feeds = Int(expectedFeeds).flatMap { $0 > 0 ? $0 : nil }
        let tiles = Int(expectedTiles).flatMap { $0 > 0 ? $0 : nil }
        if editedHints == true || feeds != nil || tiles != nil {
            try project.setTileCountHints(sourceID: sourceID, hints: .init(expectedFeeds: feeds, maxVisibleTiles: tiles))
        }
        var keys: [String: String] = [:]
        for appearance in source.appearances {
            guard let id = appearance.participantID else { continue }
            if appearance.state == .presentation, let rawID = appearance.id.components(separatedBy: "-appearance-").last {
                keys[id] = "share-\(rawID)"
            } else if let rawID = id.components(separatedBy: "-participant-").last, UInt64(rawID) != nil {
                keys[id] = "feed-\(rawID)"
            }
        }
        let ids = Dictionary(keys.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for grid in grids {
            _ = try project.correctGrid(sourceID: sourceID, range: grid.range, columns: grid.columns, rows: grid.rows)
        }
        for (from, to) in merged.sorted(by: { $0.key < $1.key }) {
            if let removed = ids[from], let surviving = ids[to] {
                _ = try project.mergeFeeds(removed, into: surviving)
            }
        }
        let removed = Set(ids.compactMap { key, id in unchecked.contains(key) ? id : nil })
        // Preserve the detected box when its assignment is unconfirmed.
        for offset in project.sources[index].appearances.indices {
            if let id = project.sources[index].appearances[offset].participantID, removed.contains(id) {
                project.sources[index].appearances[offset].participantID = nil
            }
        }
        let referenced = Set(project.sources.flatMap { $0.appearances.compactMap(\.participantID) + $0.unresolvedParticipantIDs })
        project.people.removeAll { removed.contains($0.id) && !referenced.contains($0.id) }
        for person in project.people.indices {
            if let key = keys[project.people[person].id], let name = names[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                project.people[person].name = name
            }
        }
        try project.validate()
    }
}
