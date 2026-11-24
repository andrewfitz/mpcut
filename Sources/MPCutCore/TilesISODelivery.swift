import CryptoKit
import Darwin
import Foundation

public struct TilesISOManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let filename: String
        public let sha256: String
        public let bytes: Int64
        public var feed: TilesISOPlan.Feed? = nil
        public var media: Media? = nil
    }

    public struct Media: Codable, Equatable, Sendable {
        public let start: RationalTime
        public let duration: RationalTime
        public let width: Int?
        public let height: Int?
        public let frameRate: RationalTime?
        public let audio: [Audio]

        private enum CodingKeys: String, CodingKey {
            case start, duration, width, height, frameRate = "frame_rate", audio
        }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public let stream: Int
        public let codec: String
        public let channels: Int
        public let sampleRate: Int
        public let start: RationalTime

        private enum CodingKeys: String, CodingKey {
            case stream, codec, channels, sampleRate = "sample_rate", start
        }
    }

    public let schemaVersion: Int
    public let status: String
    public let sourceID: String
    public let sourceFingerprint: String
    public let planDigest: String
    public let duration: RationalTime
    public let sourceRange: MulticamRange?
    public let canvas: ParticipantCanvas
    public let framing: ParticipantSlotFraming
    public let cameraOff: Bool
    public let files: [File]
    public let withheld: [TilesISOPlan.WithheldFeed]
    public let issues: [TilesISOIssue]
    public let blankRanges: [MulticamRange]
    public let renderMetrics: ParticipantISORenderMetrics?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", status, sourceID = "source_id", planDigest = "plan_digest"
        case sourceFingerprint = "source_fingerprint"
        case duration, canvas, framing, cameraOff = "keep_camera_off", files, withheld, issues
        case sourceRange = "source_range", blankRanges = "blank_ranges", renderMetrics = "render_metrics"
    }
}

public struct TilesISOVerification: Codable, Sendable {
    public struct Issue: Codable, Sendable {
        public let code: String
        public let filename: String
        public let message: String
    }

    public let schemaVersion: Int
    public let valid: Bool
    public let directory: String
    public let issues: [Issue]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", valid, directory, issues
    }
}

extension TilesISODelivery {
    private static let manifestName = "manifest.json"
    private static let projectName = "multicam.cut"
    private static let mixName = "meeting-mix.mov"
    private static let workspaceName = ".mpcut-isos"
    private static let checkpointName = "checkpoint.json"

    static func validateReviewDestination(_ folder: URL) throws {
        var current = folder.standardizedFileURL.resolvingSymlinksInPath()
        while current.path != "/" {
            if current.lastPathComponent == workspaceName ||
                FileManager.default.fileExists(atPath: current.appendingPathComponent(workspaceName).path) {
                throw CutError(code: "invalid_output", message: "Choose a location outside the ISO delivery folder for tile review images.")
            }
            current.deleteLastPathComponent()
        }
    }

    private struct Checkpoint: Codable {
        let version: Int
        let sourceID: String
        let sourcePath: String
        var videoStream: Int?
        var files: [String: Artifact]

        struct Artifact: Codable {
            let fingerprint: String
            let file: TilesISOManifest.File
        }
    }

    package static func validatedPlan(_ plan: TilesISOPlan, project: CutProject, document: URL,
                                      cancelled: (@Sendable () -> Bool)? = nil) throws -> TilesISOPlan {
        try validatedPreparation(plan, project: project, document: document, cancelled: cancelled).plan
    }

    private static func validatedPreparation(_ plan: TilesISOPlan, project: CutProject, document: URL,
                                             cancelled: (@Sendable () -> Bool)?) throws -> Prepared {
        guard plan.schemaVersion == 1, plan.projectPath == document.standardizedFileURL.path,
              try digest(project) == plan.projectRevision else {
            throw CutError(code: "stale_iso_plan", message: "The saved plan no longer matches this project's revision.")
        }
        let prepared = try prepare(project: project, document: document, sourceID: plan.sourceID,
            feedIDs: plan.allFeeds ? nil : plan.feeds.map(\.id), range: plan.range, canvas: plan.canvas,
            framing: plan.framing, keepCameraOff: plan.keepCameraOff, blankUncertain: plan.blankUncertain,
            audio: plan.audio, countHints: plan.countHints, expectedSourceFingerprint: plan.sourceFingerprint,
            cancelled: cancelled)
        guard plan.sourceFingerprint == prepared.plan.sourceFingerprint, plan.provenance == prepared.plan.provenance else {
            throw CutError(code: "stale_iso_plan", message: "The recording or audio changed after planning.")
        }
        return prepared
    }

    public static func render(_ plan: TilesISOPlan, project: CutProject, document: URL, to directory: URL,
                              cancelled: (@Sendable () -> Bool)? = nil,
                              progress: ((Double) -> Bool)? = nil) throws -> TilesISOManifest {
        let interruption = ParticipantRenderInterruption()
        let isCancelled: @Sendable () -> Bool = { cancelled?() == true || interruption.stopped }
        let engine = CutEngine(cancelled: isCancelled, useSidecar: false)
        let prepared = try validatedPreparation(plan, project: project, document: document, cancelled: isCancelled)
        let plan = prepared.plan
        guard !plan.requiresReview else {
            throw CutError(code: "needs_review", message: "Review the reported tile issues before exporting ISOs.")
        }

        let destination = directory.standardizedFileURL
        try project.validateDestination(destination, relativeTo: document, includesContents: true)
        let fs = FileManager.default
        if !exists(destination) {
            do { try fs.createDirectory(at: destination, withIntermediateDirectories: false) }
            catch where isDirectory(destination) { /* A concurrent delivery created the folder first. */ }
        }
        let lock = try lockDirectory(destination, exclusive: true)
        defer { close(lock) }
        let workspace = destination.appendingPathComponent(workspaceName, isDirectory: true)
        let checkpointURL = workspace.appendingPathComponent(checkpointName)
        let publicManifest = destination.appendingPathComponent(manifestName)
        // Sequence recording IDs are paths. Only the private checkpoint needs the original ID.
        let publicSourceID = try digest(plan.sourceID)
        var checkpoint: Checkpoint
        if exists(workspace) {
            guard isPrivateDirectory(workspace), isRegular(checkpointURL) else { throw invalid("Invalid ISO delivery workspace.") }
            checkpoint = try readJSON(Checkpoint.self, from: checkpointURL)
            guard checkpoint.version == 1, checkpoint.sourceID == plan.sourceID, checkpoint.sourcePath == plan.sourcePath,
                  checkpoint.videoStream.map({ $0 == prepared.videoStream }) ?? true
            else { throw invalid("The ISO delivery folder belongs to another recording.") }
            checkpoint.videoStream = prepared.videoStream
        } else {
            guard try fs.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw invalid("Choose a new folder or an existing MPCut ISO delivery.")
            }
            try fs.createDirectory(at: workspace, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            checkpoint = .init(version: 1, sourceID: plan.sourceID, sourcePath: plan.sourcePath,
                               videoStream: prepared.videoStream, files: [:])
            do { try writeJSON(checkpoint, to: checkpointURL) }
            catch {
                try? fs.removeItem(at: workspace)
                throw error
            }
        }

        for name in try fs.contentsOfDirectory(atPath: workspace.path) {
            let prefix = name.hasPrefix(".mpcut-participants-") ? ".mpcut-participants-" : "sound-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            let item = workspace.appendingPathComponent(name)
            if isDirectory(item) { try fs.removeItem(at: item) }
        }

        let desiredNames = Set(plan.feeds.map(\.filename) + [manifestName, projectName, mixName, workspaceName])
        let owned = Set(checkpoint.files.values.map(\.file.filename))
        guard owned.count == checkpoint.files.count, checkpoint.files.allSatisfy({ key, artifact in
            let name = artifact.file.filename
            if key == projectName || key == mixName { return key == name }
            return key.hasPrefix("feed:") && safeFilename(name) && name.hasSuffix(".mov") && name != mixName
        }), desiredNames.count == plan.feeds.count + 4 else {
            throw invalid("The delivery has conflicting artifact names.")
        }
        for item in try fs.contentsOfDirectory(atPath: destination.path) where item != workspaceName {
            if item == manifestName, isRegular(publicManifest),
               let previous = try? readJSON(TilesISOManifest.self, from: publicManifest), previous.schemaVersion == 1,
               (previous.sourceID == publicSourceID || previous.sourceID == checkpoint.sourceID),
               previous.files.allSatisfy({ owned.contains($0.filename) }) { continue }
            guard owned.contains(item.lowercased()), item == item.lowercased(),
                  isRegular(destination.appendingPathComponent(item)) else {
                throw invalid("The ISO delivery contains an unmanaged entry: \(item)")
            }
        }
        for file in checkpoint.files.values {
            if exists(workspace.appendingPathComponent(file.file.filename)),
               !isRegular(workspace.appendingPathComponent(file.file.filename)) {
                throw invalid("Invalid staged ISO artifact: \(file.file.filename)")
            }
        }

        _ = update(0)
        try engine.checkCancellation()
        // A previous generation stops being a publication before any movie changes.
        if exists(publicManifest) { try fs.removeItem(at: publicManifest) }
        for name in owned {
            let published = destination.appendingPathComponent(name)
            let hidden = workspace.appendingPathComponent(name)
            guard exists(published) else { continue }
            if exists(hidden) { try fs.removeItem(at: hidden) }
            try fs.moveItem(at: published, to: hidden)
        }
        try engine.checkCancellation()

        let count = Double(prepared.entries.count + (prepared.mixFingerprint == nil ? 0 : 1))
        var files = [String: TilesISOManifest.File]()
        var pending: [Entry] = []
        for entry in prepared.entries {
            if let reused = try reuse(key: feedKey(entry.feed.id), fingerprint: entry.fingerprint,
                                      filename: entry.feed.filename, feed: entry.feed) {
                files[entry.feed.id] = reused
            } else {
                pending.append(entry)
            }
        }
        let alreadyCompleted = Double(files.count)
        let renderer = ParticipantRenderer(cancelled: isCancelled)
        let jobs = pending.map { (plan: $0.renderPlan, output: workspace.appendingPathComponent($0.feed.filename)) }
        for job in jobs { try removeUncommitted(job.output) }
        let mixOutput = workspace.appendingPathComponent(mixName)
        let reusedMix = try prepared.mixFingerprint.flatMap { try reuse(key: mixName, fingerprint: $0, filename: mixName, feed: nil) }
        let mixBudget = reusedMix == nil ? prepared.mix.flatMap { sound in
            prepared.mixFingerprint == nil ? nil : sound.isoEstimatedBytes(duration: plan.duration)
        } : nil
        if mixBudget != nil { try removeUncommitted(mixOutput) }
        let metrics = try renderer.renderISOs(prepared.source, document: document, jobs: jobs, blankSourceRanges: prepared.blanks,
                additionalSpace: mixBudget.map { (file: mixOutput, estimated: $0) }, sharedInputs: prepared.sharedPicture,
                progress: { fraction in update((alreadyCompleted + Double(jobs.count) * fraction) / count) }) {
                    index, report in
                    let entry = pending[index]
                    let output = jobs[index].output
                    try ParticipantMulticam.verifyISOs(Set(ParticipantMulticam.usedSoundFiles(report)), against: prepared.snapshots)
                    files[entry.feed.id] = try record(key: feedKey(entry.feed.id), fingerprint: entry.fingerprint,
                        output: output, feed: entry.feed)
                }

        var published = try plan.feeds.map { feed -> TilesISOManifest.File in
            guard let file = files[feed.id] else { throw invalid("The renderer did not finish every selected feed.") }
            return file
        }
        if let mix = prepared.mix, let fingerprint = prepared.mixFingerprint {
            if let reused = reusedMix {
                published.append(reused)
            } else {
                let soundWork = workspace.appendingPathComponent("sound-\(UUID().uuidString)", isDirectory: true)
                try fs.createDirectory(at: soundWork, withIntermediateDirectories: false)
                defer { try? fs.removeItem(at: soundWork) }
                let sound = try StillSoundPlanner(cancelled: isCancelled).write(mix, in: soundWork) {
                    update((Double(plan.feeds.count) + $0) / count)
                }
                guard sound.count == 1, let track = sound.first else {
                    throw invalid("The meeting mix must contain exactly one audio track.")
                }
                try fs.moveItem(at: track, to: mixOutput)
                published.append(try record(key: mixName, fingerprint: fingerprint, output: mixOutput, feed: nil))
            }
        }

        let projectOutput = workspace.appendingPathComponent(projectName)
        try removeUncommitted(projectOutput)
        try makeProject(duration: plan.duration, files: published).save(to: projectOutput)
        let projectRecord = try artifact(projectOutput, feed: nil, media: nil, engine: engine)
        checkpoint.files[projectName] = .init(fingerprint: plan.projectRevision, file: projectRecord)
        try saveCheckpoint()
        published.append(projectRecord)
        try checkProject(projectOutput, files: published, duration: plan.duration)
        try prepared.mix?.verifySources()
        try ParticipantMulticam.verifyISOs(prepared.usedAudio, against: prepared.snapshots)
        try engine.verifyIdentity(prepared.gallery, identity: prepared.identity)
        try engine.checkCancellation()

        let usedNames = Set(published.map(\.filename))
        let obsolete = checkpoint.files.filter { !usedNames.contains($0.value.file.filename) }
        for (_, item) in obsolete {
            let url = workspace.appendingPathComponent(item.file.filename)
            if exists(url) { try removeUncommitted(url) }
        }
        checkpoint.files = checkpoint.files.filter { usedNames.contains($0.value.file.filename) }
        try saveCheckpoint()

        let manifest = TilesISOManifest(schemaVersion: 1, status: "completed", sourceID: publicSourceID,
            sourceFingerprint: plan.sourceFingerprint, planDigest: try digest(plan), duration: plan.duration, sourceRange: plan.range,
            canvas: plan.canvas, framing: plan.framing,
            cameraOff: plan.keepCameraOff, files: published, withheld: plan.withheld, issues: plan.issues,
            blankRanges: unite(prepared.blanks + plan.issues.filter { $0.code == "unchecked_privacy" }.compactMap(\.range)),
            renderMetrics: metrics)
        for file in published {
            try engine.checkCancellation()
            let target = destination.appendingPathComponent(file.filename)
            let failure = publishExclusively(from: workspace.appendingPathComponent(file.filename), to: target)
            guard failure == 0 else { throw invalid("Could not publish \(file.filename): \(String(cString: strerror(failure))).") }
        }
        try engine.checkCancellation()
        try writeJSON(manifest, to: publicManifest, staging: workspace)
        _ = progress?(1)
        return manifest

        func update(_ fraction: Double) -> Bool {
            if progress?(fraction) == false { interruption.stop() }
            return !isCancelled()
        }

        func feedKey(_ id: String) -> String { "feed:\(id)" }

        func saveCheckpoint() throws { try writeJSON(checkpoint, to: checkpointURL) }

        func removeUncommitted(_ url: URL) throws {
            guard exists(url) else { return }
            guard isRegular(url) else { throw invalid("Invalid staged output: \(url.lastPathComponent)") }
            try fs.removeItem(at: url)
        }

        func reuse(key: String, fingerprint: String, filename: String, feed: TilesISOPlan.Feed?) throws -> TilesISOManifest.File? {
            guard let entry = checkpoint.files[key] else { return nil }
            let oldURL = workspace.appendingPathComponent(entry.file.filename)
            guard exists(oldURL) else { return nil }
            guard fingerprint == entry.fingerprint,
                  try SourceIdentity(oldURL).size == entry.file.bytes,
                  try checksum(oldURL, engine: engine) == entry.file.sha256,
                  let expected = entry.file.media else { return nil }
            do {
                let actual = try inspect(oldURL, frameRate: feed == nil ? nil : plan.canvas.frameRate, engine: engine)
                guard actual == expected else { return nil }
                try checkMedia(actual, feed: feed, duration: plan.duration, canvas: plan.canvas, filename: filename)
            } catch {
                try engine.checkCancellation()
                return nil
            }
            let newURL = workspace.appendingPathComponent(filename)
            if oldURL != newURL {
                try removeUncommitted(newURL)
                try fs.moveItem(at: oldURL, to: newURL)
            }
            let updated = TilesISOManifest.File(filename: filename, sha256: entry.file.sha256, bytes: entry.file.bytes,
                                                feed: feed?.published, media: expected)
            checkpoint.files[key] = .init(fingerprint: fingerprint, file: updated)
            try saveCheckpoint()
            return updated
        }

        func record(key: String, fingerprint: String, output: URL, feed: TilesISOPlan.Feed?) throws -> TilesISOManifest.File {
            let media = try inspect(output, frameRate: feed == nil ? nil : plan.canvas.frameRate, engine: engine)
            try checkMedia(media, feed: feed, duration: plan.duration, canvas: plan.canvas, filename: output.lastPathComponent)
            let item = try artifact(output, feed: feed?.published, media: media, engine: engine)
            let old = checkpoint.files.updateValue(.init(fingerprint: fingerprint, file: item), forKey: key)
            try saveCheckpoint()
            if let old, old.file.filename != item.filename {
                try removeUncommitted(workspace.appendingPathComponent(old.file.filename))
            }
            return item
        }
    }

    public static func verify(_ directory: URL, cancelled: (@Sendable () -> Bool)? = nil) throws -> TilesISOVerification {
        let directory = directory.standardizedFileURL
        let engine = CutEngine(cancelled: cancelled, useSidecar: false)
        var issues: [TilesISOVerification.Issue] = []
        guard isDirectory(directory) else {
            return .init(schemaVersion: 1, valid: false, directory: directory.path,
                         issues: [.init(code: "missing_delivery", filename: manifestName, message: "The delivery folder is missing.")])
        }
        let lock = try lockDirectory(directory, exclusive: false)
        defer { close(lock) }
        let manifestURL = directory.appendingPathComponent(manifestName)
        let manifest: TilesISOManifest
        do {
            manifest = try readJSON(TilesISOManifest.self, from: manifestURL)
            guard manifest.schemaVersion == 1, manifest.status == "completed",
                  manifest.duration > .zero, manifest.files.contains(where: { $0.filename == projectName }),
                  manifest.files.contains(where: { $0.feed != nil }) else { throw invalid("Invalid or unsupported completion manifest.") }
        } catch {
            return .init(schemaVersion: 1, valid: false, directory: directory.path,
                         issues: [.init(code: "incomplete_delivery", filename: manifestName, message: (error as? CutError)?.message ?? error.localizedDescription)])
        }
        var seen = Set<String>()
        var actualNames = Set<String>()
        var feedIDs = Set<String>()
        let withheldIDs = Set(manifest.withheld.map(\.id))
        for file in manifest.files {
            try engine.checkCancellation()
            let validKind = file.feed.map {
                validStillID($0.id) && $0.filename == file.filename && file.filename.hasSuffix(".mov")
                    && file.filename != mixName && !withheldIDs.contains($0.id) && feedIDs.insert($0.id).inserted
            } ?? ((file.filename == projectName && file.media == nil) || file.filename == mixName)
            guard safeFilename(file.filename), validKind, seen.insert(file.filename.lowercased()).inserted else {
                issues.append(.init(code: "invalid_filename", filename: file.filename, message: "Invalid or duplicate artifact entry."))
                continue
            }
            actualNames.insert(file.filename)
            let url = directory.appendingPathComponent(file.filename)
            guard isRegular(url) else {
                issues.append(.init(code: "missing_file", filename: file.filename, message: "The artifact is missing or is not a regular file."))
                continue
            }
            do {
                if file.filename == projectName {
                    try checkProject(url, files: manifest.files, duration: manifest.duration)
                } else {
                    let actual = try inspect(url, frameRate: file.feed == nil ? nil : manifest.canvas.frameRate, engine: engine)
                    try checkMedia(actual, feed: file.feed, duration: manifest.duration, canvas: manifest.canvas, filename: file.filename)
                    guard actual == file.media else { throw invalid("The media timing, dimensions or audio track layout changed.") }
                }
                guard try checksum(url, engine: engine) == file.sha256,
                      try SourceIdentity(url).size == file.bytes else { throw invalid("The artifact checksum changed.") }
            } catch {
                try engine.checkCancellation()
                issues.append(.init(code: "stale_file", filename: file.filename, message: (error as? CutError)?.message ?? error.localizedDescription))
            }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        where name != workspaceName && name != manifestName && !actualNames.contains(name) {
            issues.append(.init(code: "unexpected_file", filename: name, message: "The file is not in the completion manifest."))
        }
        return .init(schemaVersion: 1, valid: issues.isEmpty, directory: directory.path, issues: issues)
    }

    private static func inspect(_ url: URL, frameRate: RationalTime?, engine: CutEngine) throws -> TilesISOManifest.Media {
        let video = frameRate != nil
        let media = try engine.inspect(url, keyframes: video)
        let picture = media.videoStream
        let audio = media.streams.filter { $0.kind == "audio" }.map {
            TilesISOManifest.Audio(stream: $0.index, codec: $0.codec, channels: $0.channels, sampleRate: $0.sampleRate, start: $0.start)
        }
        guard media.streams.count == audio.count + (video ? 1 : 0),
              video == (picture != nil) else { throw invalid("Unexpected video, audio or auxiliary tracks in \(url.lastPathComponent).") }
        if let frameRate {
            guard frameRate > .zero, let first = media.frames.first, let last = media.frames.last, let picture else {
                throw invalid("The movie has no indexed frames.")
            }
            let cadence = RationalTime(numerator: frameRate.denominator, denominator: frameRate.numerator)
            for (index, frame) in media.frames.enumerated() {
                if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
                let time = try first.time.adding(cadence.multiplied(by: .init(numerator: Int64(index))))
                let validDuration = index == media.frames.count - 1
                    ? frame.duration > .zero && frame.duration <= cadence : frame.duration == cadence
                guard frame.time == time, validDuration else {
                    throw invalid("The picture cadence differs from the planned frame rate: \(url.lastPathComponent)")
                }
            }
            let duration = try last.time.adding(last.duration).subtracting(first.time)
            for track in media.streams where track.kind == "audio" {
                guard track.sampleRate > 0,
                      try max(track.duration, duration).subtracting(min(track.duration, duration))
                        <= RationalTime(numerator: 1, denominator: Int64(track.sampleRate)) else {
                    throw invalid("The ISO microphone duration differs from its picture: \(url.lastPathComponent)")
                }
            }
            return .init(start: try first.time.adding(media.origin), duration: duration,
                         width: picture.displayWidth, height: picture.displayHeight, frameRate: picture.frameRate, audio: audio)
        }
        return .init(start: media.origin, duration: media.duration, width: nil, height: nil, frameRate: nil, audio: audio)
    }

    private static func checkMedia(_ actual: TilesISOManifest.Media, feed: TilesISOPlan.Feed?, duration: RationalTime,
                                   canvas: ParticipantCanvas, filename: String) throws {
        if let feed {
            guard actual.start == .zero, actual.duration == duration,
                  actual.width == canvas.width, actual.height == canvas.height, actual.audio.count == feed.audioTracks,
                  actual.audio.allSatisfy({ $0.start == .zero }) else {
                throw invalid("Incorrect picture timing, canvas or audio track count in \(filename).")
            }
        } else {
            guard actual.audio.count == 1, actual.start == .zero, actual.audio[0].start == .zero,
                  abs(actual.duration.seconds - duration.seconds) <= 1 / Double(max(1, actual.audio[0].sampleRate)) else {
                throw invalid("Incorrect audio timing or track count in \(filename).")
            }
        }
    }

    private static func makeProject(duration: RationalTime, files: [TilesISOManifest.File]) throws -> MulticamProject {
        let movies: [MulticamSource] = files.compactMap { file in
            guard let feed = file.feed else { return nil }
            return .init(id: feed.id, file: file.filename, name: feed.name, audioStream: file.media?.audio.first?.stream)
        }
        guard let first = movies.first else { throw invalid("The ISO delivery has no angles.") }
        var mixID = "meeting-mix"
        let ids = Set(movies.map(\.id))
        while ids.contains(mixID) { mixID += "-" }
        let mixStream = files.first { $0.filename == mixName }?.media?.audio.first?.stream
        let audio: [MulticamSource] = mixStream.map { [.init(id: mixID, file: mixName, name: "Meeting mix", audioStream: $0)] } ?? []
        let policy: MulticamAudioPolicy = mixStream.map { .fixed(.init(source: mixID, stream: $0)) } ?? .none
        let lanes: [MulticamAudioLane] = movies.enumerated().compactMap { index, movie in
            guard let stream = movie.audioStream else { return nil }
            return .init(id: "iso-\(index + 1)", target: .recording(.init(source: movie.id, stream: stream)),
                         label: "\(movie.name ?? movie.id) ISO", colorSlot: index % MulticamAudioLane.colorSlotCount)
        }
        let result = MulticamProject(referenceAngle: first.id, range: .init(from: .zero, to: duration),
                                     angles: movies, audioSources: audio, audio: policy,
                                     switches: [.init(at: .zero, angle: first.id)], mixLanes: lanes)
        try result.validate()
        return result
    }

    private static func checkProject(_ file: URL, files: [TilesISOManifest.File], duration: RationalTime) throws {
        let actual = try MulticamProject.load(from: file)
        let expected = try makeProject(duration: duration, files: files)
        guard actual == expected else {
            throw invalid("The delivered project does not match the documented ISO media and audio routing.")
        }
    }

    private static func artifact(_ url: URL, feed: TilesISOPlan.Feed?, media: TilesISOManifest.Media?,
                                 engine: CutEngine) throws -> TilesISOManifest.File {
        let identity = try SourceIdentity(url)
        let hash = try checksum(url, engine: engine)
        try engine.verifyIdentity(url, identity: identity)
        return .init(filename: url.lastPathComponent, sha256: hash, bytes: identity.size, feed: feed, media: media)
    }

    private static func checksum(_ url: URL, engine: CutEngine) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid("Could not read \(url.lastPathComponent).") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw invalid("The artifact must be a regular file: \(url.lastPathComponent)")
        }
        let identity = try SourceIdentity(url)
        guard info.st_dev == identity.device, info.st_ino == identity.inode else {
            throw invalid("The artifact changed during verification.")
        }
        var sha = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try engine.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw invalid("Could not read \(url.lastPathComponent).")
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { sha.update(bufferPointer: .init(rebasing: $0[..<count])) }
        }
        try engine.verifyIdentity(url, identity: identity)
        return hex(sha.finalize())
    }

    private static func safeFilename(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.isEmpty && name.utf8.count <= 128 &&
            name.utf8.allSatisfy { $0 == 45 || $0 == 46 || (48...57).contains($0) || (97...122).contains($0) }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0
    }

    private static func isRegular(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func lockDirectory(_ url: URL, exclusive: Bool) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid("Choose a local, nonsymlink ISO directory.") }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor)
            throw CutError(code: "iso_delivery_busy", message: "Another operation is using this ISO delivery.")
        }
        return descriptor
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard isRegular(url), try SourceIdentity(url).size <= Int64(MulticamProject.maximumFileSize) else {
            throw invalid("The delivery record is missing or invalid: \(url.lastPathComponent)")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, staging: URL? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(value)
        guard bytes.count <= MulticamProject.maximumFileSize else { throw invalid("The delivery record is too large.") }
        if let staging {
            let temporary = staging.appendingPathComponent(".manifest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try bytes.write(to: temporary, options: [.withoutOverwriting])
            let failure = publishExclusively(from: temporary, to: url)
            guard failure == 0 else { throw invalid("Could not publish the ISO manifest.") }
        } else {
            try bytes.write(to: url, options: [.atomic])
        }
    }
}
