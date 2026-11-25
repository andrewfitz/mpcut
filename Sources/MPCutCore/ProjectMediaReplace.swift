import Foundation

package enum MediaReplaceConform: String, Codable, Sendable { case trim, keep }
package enum MediaReplaceLoss: String, Codable, Sendable { case remove, keepOffline = "keep_offline" }
package enum MediaReplaceClock: String, Codable, Sendable {
    case sourceRelative = "source_relative"
    case sourceTimecode = "source_timecode"
}
package enum MediaReplaceTranscript: String, Codable, Sendable {
    case keepUnverified = "keep_unverified"
    case retranscribe
}
package enum MediaReplaceSync: String, Codable, Sendable { case timecode, waveform }

package struct MediaReplaceOptions: Sendable {
    package var useID: String? = nil
    package var conform: MediaReplaceConform = .trim
    package var loss: MediaReplaceLoss? = nil
    package var clock: MediaReplaceClock = .sourceRelative
    package var streamMapping: [Int: Int] = [:]
    package var resetCrop = false
    package var replacementOffset: RationalTime? = nil
    package var sharedTimeOfDay = false
    package var transcript: MediaReplaceTranscript = .keepUnverified
    package var resync: MediaReplaceSync? = nil

    package init(useID: String? = nil, conform: MediaReplaceConform = .trim, loss: MediaReplaceLoss? = nil,
                 clock: MediaReplaceClock = .sourceRelative, streamMapping: [Int: Int] = [:],
                 resetCrop: Bool = false, replacementOffset: RationalTime? = nil,
                 sharedTimeOfDay: Bool = false, transcript: MediaReplaceTranscript = .keepUnverified,
                 resync: MediaReplaceSync? = nil) {
        self.useID = useID
        self.conform = conform
        self.loss = loss
        self.clock = clock
        self.streamMapping = streamMapping
        self.resetCrop = resetCrop
        self.replacementOffset = replacementOffset
        self.sharedTimeOfDay = sharedTimeOfDay
        self.transcript = transcript
        self.resync = resync
    }
}

package struct MediaReplaceReport: Codable, Sendable {
    package struct AudioStream: Codable, Sendable {
        package let index: Int
        package let ordinal: Int
        package let layout: String
        package let language: String
        package let name: String?
        package let channels: Int
    }

    package struct Boundary: Codable, Sendable {
        package let useID: String
        package let at: RationalTime
        package let frameAligned: Bool
        package let copySafe: Bool

        enum CodingKeys: String, CodingKey {
            case useID = "use_id", at, frameAligned = "frame_aligned", copySafe = "copy_safe"
        }
    }

    package struct Offset: Codable, Sendable {
        package let useID: String
        package let before: RationalTime
        package let after: RationalTime

        enum CodingKeys: String, CodingKey { case useID = "use_id", before, after }
    }

    package var affectedUseIDs: [String] = []
    package var warnings: [String] = []
    package var blockers: [String] = []
    package var lostUseIDs: [String] = []
    package var trimmedUseIDs: [String] = []
    package var beforeDuration: RationalTime = .zero
    package var afterDuration: RationalTime = .zero
    package var canKeepTimecode = false
    package var needsSharedTimeOfDay = false
    package var audioMapping: [Int: Int] = [:]
    package var unresolvedAudioStreams: [Int] = []
    package var candidateAudioStreams: [AudioStream] = []
    package var boundaries: [Boundary] = []
    package var offsets: [Offset] = []
    package var participantIDs: [String] = []
    package var affectedRedactionIDs: [String] = []
    package var affectedParticipantBindingIDs: [String] = []
    package var affectedParticipantSlotIDs: [String] = []
    package var removedAppearanceIDs: [String] = []
    package var affectedTranscriptIDs: [String] = []
    package var oldStill: StillImageInfo?
    package var newStill: StillImageInfo?
    package var canApply = false

    enum CodingKeys: String, CodingKey {
        case affectedUseIDs = "affected_use_ids", warnings, blockers
        case lostUseIDs = "lost_use_ids", trimmedUseIDs = "trimmed_use_ids"
        case beforeDuration = "before_duration", afterDuration = "after_duration"
        case canKeepTimecode = "can_keep_timecode", needsSharedTimeOfDay = "needs_shared_time_of_day"
        case audioMapping = "audio_mapping", unresolvedAudioStreams = "unresolved_audio_streams"
        case candidateAudioStreams = "candidate_audio_streams", boundaries, offsets
        case participantIDs = "participant_ids", affectedRedactionIDs = "affected_redaction_ids"
        case affectedParticipantBindingIDs = "affected_participant_binding_ids"
        case affectedParticipantSlotIDs = "affected_participant_slot_ids", removedAppearanceIDs = "removed_appearance_ids"
        case affectedTranscriptIDs = "affected_transcript_ids", oldStill = "old_still", newStill = "new_still"
        case canApply = "can_apply"
    }
}

package struct MediaReplacePreview: Sendable {
    package let report: MediaReplaceReport
    package let snapshot: ProjectMediaSnapshot
    private let original: CutProject
    private let revised: CutProject
    package let sourceURL: URL
    package let candidateURL: URL
    package let replacesAtSameLocation: Bool
    private let identity: SourceIdentity

    fileprivate init(report: MediaReplaceReport, snapshot: ProjectMediaSnapshot, original: CutProject,
                     revised: CutProject, sourceURL: URL, candidate: URL, replacesAtSameLocation: Bool, identity: SourceIdentity) {
        self.report = report
        self.snapshot = snapshot
        self.original = original
        self.revised = revised
        self.sourceURL = sourceURL
        self.candidateURL = candidate
        self.replacesAtSameLocation = replacesAtSameLocation
        self.identity = identity
    }

    package func applying(to project: CutProject) throws -> CutProject {
        guard project == original else {
            throw CutError(code: "media_replace_stale", message: "The project changed. Preview the replacement again.")
        }
        guard report.canApply else {
            throw CutError(code: "media_replace_blocked", message: report.blockers.joined(separator: " "))
        }
        try checkGeneration()
        return revised
    }

    package func checkGeneration() throws {
        guard !ProjectMediaVolume.isChecking(candidateURL), identity.isCurrentSnapshot(at: candidateURL) else {
            throw CutError(code: "source_changed", message: "The replacement changed. Preview it again.")
        }
    }
}

package enum ProjectMediaReplace {
    package static func preview(_ project: CutProject, snapshot: ProjectMediaSnapshot = .init(),
                                relativeTo projectURL: URL, source: String, candidate: URL,
                                options: MediaReplaceOptions = .init(),
                                cancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) throws -> MediaReplacePreview {
        try ReplaceEdit(project: project, snapshot: snapshot, source: source, candidate: candidate,
                        projectURL: projectURL, options: options, cancelled: cancelled).prepare()
    }
}

final class ReplaceEdit {
    let project: CutProject
    let source: String
    let candidate: URL
    let projectURL: URL
    let destination: String
    let options: MediaReplaceOptions
    let identity: SourceIdentity
    let uses: [ProjectMediaUse]
    let selectedID: String?
    let oldURL: URL
    let requestedURL: URL
    let replacesAtSameLocation: Bool
    let sourcePaths: Set<String>
    let cancelled: @Sendable () -> Bool
    let engine: CutEngine
    var snapshot: ProjectMediaSnapshot
    var report = MediaReplaceReport()
    var oldMedia: MediaInfo?
    var previousEntry: ProjectMediaSnapshot.Entry?
    var candidateDigest: String?
    var media: MediaInfo?
    var clockDelta: RationalTime = .zero
    var audio: [StreamInfo] = []
    var oldAudio: [ProjectMediaSnapshot.Entry.Stream] = []
    var offsets: [String: RationalTime] = [:]
    var lossKeepsOldPath = Set<String>()

    init(project: CutProject, snapshot: ProjectMediaSnapshot, source: String,
         candidate: URL, projectURL: URL, options: MediaReplaceOptions,
         cancelled: @escaping @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        guard candidate.isFileURL, !ProjectMediaVolume.isChecking(candidate) else {
            throw CutError(code: "media_checking", message: "The replacement volume is unavailable or still being checked.")
        }
        self.project = project
        self.snapshot = snapshot
        self.projectURL = projectURL
        self.options = options
        self.cancelled = cancelled
        engine = CutEngine(cancelled: cancelled, useSidecar: false)
        let requested = Self.location(of: source, relativeTo: projectURL)
        let path = Self.comparisonURL(requested)
        oldURL = path
        requestedURL = requested
        self.source = source
        self.candidate = candidate.standardizedFileURL
        replacesAtSameLocation = path == Self.comparisonURL(candidate.standardizedFileURL)
        destination = CutProject.relativeMediaPath(candidate.path, to: projectURL)
        let references = ProjectMedia.references(in: project)
        let stored = Set(references.map(\.path) + snapshot.entries.map(\.path))
        sourcePaths = Set(stored.filter { reference in
            let location = Self.location(of: reference, relativeTo: projectURL)
            return location.path == requested.path || (location.lastPathComponent == requested.lastPathComponent
                && Self.comparisonURL(location).path == path.path)
        })
        let matching = sourcePaths
        let allUses = references.filter { matching.contains($0.path) && $0.kind.canReplaceDirectly }
        var selectedID = options.useID
        if let id = selectedID, let use = allUses.first(where: { $0.id == id }) {
            if use.kind == .multicamSpan || use.kind == .multicamSelection ||
                (project.sequenceItems == nil && (use.kind == .transcript || use.kind == .transcriptAnchor || use.kind == .participantAudio)) {
                selectedID = use.sourceID ?? id
            } else if use.kind == .stillFragment {
                selectedID = project.sequenceItems?.compactMap(\.source)
                    .first(where: { clip in id.hasSuffix("/" + clip.id) && project.stillReplacements.contains {
                        id == $0.id + "/" + clip.id
                    } })?.id ?? id
            }
        }
        uses = allUses.filter { selectedID == nil || selectedID == $0.id }
        self.selectedID = selectedID
        guard !uses.isEmpty else {
            throw CutError(code: "media_replace_unknown_source", message: "No selected project use references \(source).")
        }
        identity = try SourceIdentity(candidate)
    }

    private static func location(of path: String, relativeTo projectURL: URL) -> URL {
        let absolute = path.hasPrefix("/") ? path : projectURL.deletingLastPathComponent().path + "/" + path
        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = absolute
        let location = components.url ?? URL(fileURLWithPath: absolute)
        if ProjectMediaVolume.isChecking(location) { return location }
        return CutProject.mediaURL(path, relativeTo: projectURL)
    }

    private static func comparisonURL(_ location: URL) -> URL {
        ProjectMediaVolume.isChecking(location) ? location : ProjectFile.canonicalFileURL(location)
    }

    private func matches(_ path: String, useID: String) -> Bool {
        (selectedID == nil || selectedID == useID) && sameSource(path)
    }

    func sameSource(_ path: String) -> Bool { path == source || sourcePaths.contains(path) }

    func prepare() throws -> MediaReplacePreview {
        report.affectedUseIDs = Set(uses.map(\.id)).sorted()
        report.beforeDuration = try project.stillTimelineDuration()
        var revised = project
        if uses.contains(where: { $0.kind == .still }) {
            if uses.contains(where: { $0.kind != .still }) {
                report.blockers.append("Choose a single use to replace a file referenced as both a still and time-based media.")
            } else {
                revised = try replaceStill()
            }
        } else {
            try prepareMedia()
            switch project {
            case .sequence(let clips):
                let edit = try replaceSequence(.init(items: clips.map(StillSequenceItem.source)))
                revised = .sequence(edit.items.compactMap(\.source))
                revised.participants = edit.participants
            case .stillSequence(let value):
                revised = .stillSequence(try replaceSequence(value))
            case .multicam(let value):
                revised = .multicam(try replaceMulticam(value))
            }
            revised.transcripts = try replaceTranscripts(revised)
            try rebindAnalysis(in: &revised)
        }

        report.lostUseIDs = Set(report.lostUseIDs).sorted()
        report.trimmedUseIDs = Set(report.trimmedUseIDs).sorted()
        report.affectedUseIDs = Set(report.affectedUseIDs + report.lostUseIDs + report.trimmedUseIDs).sorted()
        report.unresolvedAudioStreams = Set(report.unresolvedAudioStreams).sorted()
        if report.boundaries.contains(where: { !$0.copySafe }) {
            report.warnings.append("Some cuts no longer match safe copy boundaries. Exact cuts may require Smart Trim or re-encoding.")
        }
        if !report.lostUseIDs.isEmpty {
            report.warnings.append("One or more uses fall fully outside the replacement’s source range.")
        }
        if revised == project, report.blockers.isEmpty, !replacesAtSameLocation {
            report.blockers.append("The selected reference cannot be replaced on its own. Choose its recording or all uses.")
        }
        if !report.lostUseIDs.isEmpty, options.loss == nil {
            report.blockers.append("Choose whether to remove fully out-of-range uses or keep them offline.")
        }
        do {
            try revised.validate()
            report.afterDuration = try revised.stillTimelineDuration()
        } catch {
            report.blockers.append(error.localizedDescription)
            report.afterDuration = report.beforeDuration
        }
        report.warnings = unique(report.warnings)
        report.blockers = unique(report.blockers)
        report.canApply = report.blockers.isEmpty
        return MediaReplacePreview(report: report, snapshot: snapshot, original: project, revised: revised,
                                   sourceURL: requestedURL, candidate: candidate,
                                   replacesAtSameLocation: replacesAtSameLocation, identity: identity)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func conformed(_ range: MulticamRange, duration: RationalTime, id: String,
                           availableStart: RationalTime = .zero) throws -> MulticamRange? {
        let mapped = try MulticamRange(from: range.from.adding(clockDelta), to: range.to.adding(clockDelta))
        if mapped.from >= availableStart, mapped.to <= duration { return mapped }
        if mapped.from >= duration || mapped.to <= availableStart {
            report.lostUseIDs.append(id)
            if options.loss == .remove { return nil }
            if mapped.from < .zero {
                lossKeepsOldPath.insert(id)
                report.warnings.append("A negative mapped source time retains the saved recording and range.")
                return range
            }
            return mapped
        }
        report.warnings.append("One or more uses exceed the replacement’s source range.")
        if options.conform == .keep {
            if mapped.from < .zero {
                lossKeepsOldPath.insert(id)
                report.warnings.append("A negative mapped source time retains the saved recording and range.")
                return range
            }
            return mapped
        }
        report.trimmedUseIDs.append(id)
        return .init(from: max(availableStart, mapped.from), to: min(duration, mapped.to))
    }
}

extension ReplaceEdit {
    private func mergeCandidateSnapshot(_ entry: ProjectMediaSnapshot.Entry) {
        let target = Self.location(of: entry.path, relativeTo: projectURL)
        // A live snapshot may spell this location with an absolute path.
        // Merge its metadata before rebasing can collapse the two keys.
        for index in snapshot.entries.indices
            where Self.location(of: snapshot.entries[index].path, relativeTo: projectURL) == target {
            snapshot.entries[index].path = entry.path
        }
        snapshot = snapshot.merging(.init(entries: [entry]))
    }

    private func prepareMedia() throws {
        let inspected = try engine.inspectFresh(candidate, keyframes: true, expectedIdentity: identity)
        media = inspected
        audio = inspected.streams.filter { $0.kind == "audio" && $0.sampleRate > 0 }
        report.candidateAudioStreams = audio.enumerated().map { ordinal, stream in
            .init(index: stream.index, ordinal: ordinal, layout: stream.canonicalChannelLayout,
                  language: stream.language, name: stream.name, channels: stream.channels)
        }
        let saved = snapshot.entries.first { sameSource($0.path) }
        if !ProjectMediaVolume.isChecking(oldURL) {
            if saved == nil {
                oldMedia = try? engine.inspectFresh(oldURL, keyframes: false)
            } else {
                oldMedia = try? engine.inspectForPreview(oldURL)
            }
        }
        if cancelled() { throw CancellationError() }
        let previous = saved ?? oldMedia.map { ProjectMediaSnapshot.Entry(path: source, media: $0) }
        previousEntry = previous
        let entry = ProjectMediaSnapshot.Entry(path: destination, media: inspected)
        mergeCandidateSnapshot(entry)
        oldAudio = (previous?.streams ?? []).filter { $0.kind == "audio" }

        let previouslyVideo = previous?.streams.map { $0.contains { $0.kind == "video" } }
        let needsPicture = uses.contains { $0.picture }
        let needsAudioOnly = previouslyVideo == nil && uses.contains { $0.kind == .microphone }
        if uses.contains(where: { $0.audio }), audio.isEmpty {
            report.blockers.append("The replacement contains no audio streams.")
        }
        if previouslyVideo.map({ $0 != inspected.hasVideo }) == true || (needsPicture && !inspected.hasVideo)
            || (needsAudioOnly && inspected.hasVideo) {
            report.blockers.append("The replacement must have the same picture or audio-only media type.")
        }

        if let duration = previous?.duration, duration != inspected.duration {
            report.warnings.append("The source duration changes from \(duration) to \(inspected.duration).")
        }
        if let origin = previous?.origin, origin != inspected.origin {
            report.warnings.append("The presentation origin changes from \(origin) to \(inspected.origin).")
        }
        if let oldRate = previous?.frameRate, oldRate != entry.frameRate {
            report.warnings.append("Frame rate changes. Cuts retain their exact times.")
        }
        if let priorStreams = previous?.streams, priorStreams.filter({ $0.kind == "audio" }).count != audio.count {
            report.warnings.append("The number of audio streams changes.")
        }
        if previous?.width != entry.width || previous?.height != entry.height
            || (previous?.streams).map({ $0.map(\.codec) != entry.streams?.map(\.codec) }) == true
            || oldMedia.map({ (try? engine.checkCompatibility(inspected, with: $0)) == nil }) == true {
            if previous != nil {
                report.warnings.append("Source format differs. Copy export may require re-encoding.")
            }
        }

        if let oldClock = previous?.sourceClock, let newClock = entry.sourceClock {
            report.needsSharedTimeOfDay = oldClock.kind != newClock.kind
            report.canKeepTimecode = !report.needsSharedTimeOfDay || options.sharedTimeOfDay
            if oldClock.start != newClock.start {
                report.warnings.append("The embedded source clock changes from \(oldClock.start) to \(newClock.start).")
            }
            if options.clock == .sourceTimecode, report.canKeepTimecode {
                clockDelta = try oldClock.start.subtracting(newClock.start)
            }
        }
        if options.clock == .sourceTimecode, !report.canKeepTimecode {
            report.blockers.append("Keeping timecode requires comparable embedded clocks and a confirmed shared time of day for mixed clock types.")
        }
    }

    func mapStream(_ oldIndex: Int, channel: Int? = nil) -> Int {
        let selected: StreamInfo?
        if let mapped = options.streamMapping[oldIndex] {
            selected = audio.first { $0.index == mapped }
        } else if let old = oldAudio.first(where: { $0.index == oldIndex }) {
            let oldStream = oldMedia?.streams.first { $0.index == oldIndex }
            let oldLayout = old.channelLayout ?? oldStream?.canonicalChannelLayout
            let oldName = (old.name ?? oldStream?.name)?.lowercased()
            let matches = audio.filter {
                $0.channels == old.channels && $0.language == old.language
                    && (oldLayout == nil || $0.canonicalChannelLayout == oldLayout)
            }
            let named = oldName.map { name in audio.filter { $0.name?.lowercased() == name } } ?? []
            let matchingDescriptions = named.isEmpty ? matches : matches.filter { stream in
                named.contains { $0.index == stream.index }
            }
            if named.count == 1 {
                selected = named[0]
            } else if oldName != nil, named.isEmpty, !audio.isEmpty, audio.allSatisfy({ $0.name != nil }),
                      max(audio.count, oldAudio.count) > 1 {
                selected = nil
            } else if matchingDescriptions.count == 1 {
                selected = matchingDescriptions[0]
            } else if matchingDescriptions.isEmpty, audio.count == oldAudio.count {
                selected = audio.first { $0.index == oldIndex && ($0.language == old.language || audio.count == 1) }
            } else {
                selected = matchingDescriptions.first { $0.index == oldIndex }
            }
        } else {
            selected = audio.first { $0.index == oldIndex }
        }
        guard let selected, channel.map({ $0 < selected.channels }) != false else {
            report.unresolvedAudioStreams.append(oldIndex)
            report.blockers.append("Choose a replacement mapping for audio stream \(oldIndex)\(channel.map { ", channel \($0)" } ?? "").")
            return oldIndex
        }
        report.audioMapping[oldIndex] = selected.index
        if oldIndex != selected.index { report.warnings.append("Selected audio streams have been remapped.") }
        return selected.index
    }

    private func mapOrdinal(_ ordinal: Int) -> Int {
        if oldAudio.indices.contains(ordinal) {
            let index = mapStream(oldAudio[ordinal].index)
            return audio.firstIndex { $0.index == index } ?? ordinal
        }
        if options.streamMapping[ordinal] != nil {
            let index = mapStream(ordinal)
            return audio.firstIndex { $0.index == index } ?? ordinal
        }
        if !audio.indices.contains(ordinal) {
            report.unresolvedAudioStreams.append(ordinal)
            report.blockers.append("Choose a replacement mapping for audio track \(ordinal).")
        }
        return ordinal
    }

    private func reportBoundaries(_ range: MulticamRange, id: String, media: MediaInfo) {
        guard media.hasVideo else { return }
        for (time, isStart) in [(range.from, true), (range.to, false)] {
            let index = media.frames.lowerBound { $0.time >= time }
            let frame = media.frames.indices.contains(index) && media.frames[index].time == time ? media.frames[index] : nil
            let end = !isStart && time == media.duration
            let aligned = frame != nil || end
            let safe = end || (isStart ? frame?.canStart == true : frame?.canEnd == true)
            if !aligned || !safe {
                report.boundaries.append(.init(useID: id, at: time, frameAligned: aligned, copySafe: safe))
            }
        }
    }

    private func replaceStill() throws -> CutProject {
        let result = try StillImage.inspectAndFingerprint(candidate, expectedIdentity: identity, cancelled: cancelled)
        report.newStill = result.info
        if !ProjectMediaVolume.isChecking(oldURL) {
            report.oldStill = try? StillImage.inspect(oldURL)
        }
        if cancelled() { throw CancellationError() }
        let assetIDs = Set(uses.map { $0.sourceID ?? $0.id })
        let selectedPlacement = selectedID.flatMap { id in uses.first(where: { $0.id == id && $0.sourceID != nil }) }
        var revised = project
        for asset in project.stillAssets where assetIDs.contains(asset.id) && !asset.isGap {
            if asset.fingerprint != result.fingerprint {
                report.warnings.append("Still image content changes. Review the placement and crop.")
            }
            let entry = snapshot.entries.first { sameSource($0.path) }
            if let width = report.oldStill?.displayWidth ?? entry?.width,
               let height = report.oldStill?.displayHeight ?? entry?.height,
               Double(width) * Double(result.info.displayHeight) != Double(result.info.displayWidth) * Double(height) {
                report.warnings.append("Still image aspect ratio changes.")
            }
            if let placement = selectedPlacement {
                let assetID = ProjectIdentifier.make(avoiding: revised.stillAssets.map(\.id))
                revised = try revised.addingStillAsset(.init(id: assetID, file: destination,
                                                            displayName: candidate.lastPathComponent,
                                                            fingerprint: result.fingerprint))
                let previousFraming = project.stillInserts.first { $0.id == placement.id }?.framing
                    ?? project.stillReplacements.first { $0.id == placement.id }?.framing
                var framing = previousFraming
                if options.resetCrop { framing?.crop = nil }
                revised = try revised.updatingStill(id: placement.id, assetID: assetID, framing: framing)
            } else {
                revised = try revised.relinkingStillAsset(asset.id, file: destination, fingerprint: result.fingerprint)
            }
        }
        if options.resetCrop, selectedPlacement == nil {
            for insert in revised.stillInserts where assetIDs.contains(insert.assetID) {
                var framing = insert.framing
                framing.crop = nil
                revised = try revised.updatingStill(id: insert.id, framing: framing)
            }
            for replacement in revised.stillReplacements where assetIDs.contains(replacement.assetID) {
                var framing = replacement.framing
                framing.crop = nil
                revised = try revised.updatingStill(id: replacement.id, framing: framing)
            }
        }
        var entry = ProjectMediaSnapshot.Entry(path: destination)
        entry.stillSHA256 = result.fingerprint
        entry.size = identity.size
        entry.modifiedSeconds = identity.modifiedSeconds
        entry.modifiedNanoseconds = identity.modifiedNanoseconds
        entry.width = result.info.displayWidth
        entry.height = result.info.displayHeight
        mergeCandidateSnapshot(entry)
        return revised
    }

    private func replaceSequence(_ sequence: StillSequenceProject) throws -> StillSequenceProject {
        guard let media else { return sequence }
        var sequence = sequence
        let selectedClips = Set(sequence.items.compactMap(\.source).filter { matches($0.file, useID: $0.id) }.map(\.id))
        func replaceClip(_ clip: CutSequenceClip, soundtrack: Bool = false) throws -> CutSequenceClip? {
            var clip = clip
            if let original = clip.originalFile, matches(original, useID: clip.id) {
                if clip.to > media.duration {
                    report.warnings.append("The replacement original is shorter than the recorded working-copy range.")
                }
                if clip.from >= media.duration {
                    report.lostUseIDs.append(clip.id)
                    clip.originalFile = options.loss == .remove ? nil : destination
                } else {
                    clip.originalFile = destination
                }
            }
            guard matches(clip.file, useID: clip.id) else { return clip }
            let ordinal = clip.audioTrack.map(mapOrdinal)
            let track: AudioIndex?
            if soundtrack {
                guard let ordinal, audio.indices.contains(ordinal),
                      let selected = media.audio.first(where: { $0.stream.index == audio[ordinal].index }) else {
                    report.blockers.append("The selected replacement soundtrack has no indexed audio clock.")
                    return clip
                }
                track = selected
            } else {
                track = nil
            }
            guard let range = try conformed(.init(from: clip.from, to: clip.to), duration: track?.end ?? media.duration,
                                            id: clip.id, availableStart: max(.zero, track?.start ?? .zero)) else {
                return nil
            }
            guard !lossKeepsOldPath.contains(clip.id) else { return clip }
            if !clip.tileLayouts.isEmpty {
                let originalDigest = sequence.participants.sources.first { $0.sourceID == clip.file }?.sourceContentSHA256
                if originalDigest != nil && candidateDigest == nil {
                    candidateDigest = try participantSourceDigest(candidate, identity: identity, cancelled: cancelled)
                }
                if originalDigest == nil || originalDigest != candidateDigest {
                    clip.tileLayouts.removeAll()
                    report.warnings.append("Tile layouts on clip ‘\(clip.id)’ are cleared for the replacement picture.")
                } else {
                    let previousFile = clip.file
                    clip.mapTileCameraPaths { $0 == previousFile ? destination : $0 }
                }
            }
            clip.file = destination
            clip.from = range.from
            clip.to = range.to
            clip.audioTrack = ordinal
            if let track,
               (try? StillSoundtrack.reference(media: media, stream: track.stream.index,
                                                from: range.from, to: range.to, id: clip.id)) == nil {
                report.warnings.append("The saved soundtrack range needs review on the replacement track’s sample clock.")
            }
            var names: [Int: String] = [:]
            for (old, name) in clip.replacementNames.sorted(by: { $0.key < $1.key }) {
                names[mapOrdinal(old)] = name
            }
            clip.replacementNames = names
            if !soundtrack { reportBoundaries(range, id: clip.id, media: media) }
            return clip
        }
        sequence.items = try sequence.items.compactMap { item in
            guard case .source(let clip) = item else { return item }
            return try replaceClip(clip).map(StillSequenceItem.source)
        }
        if let layoutReference = sequence.stillAudioReference {
            if matches(layoutReference.file, useID: layoutReference.id), oldMedia != nil, oldAudio.count != audio.count {
                report.warnings.append("The inherited still soundtrack layout changes.")
            }
            sequence.stillAudioReference = try replaceClip(layoutReference)
        }
        if let soundtrack = sequence.stillSoundtrack {
            sequence.stillSoundtrack = try replaceClip(soundtrack, soundtrack: true)
        }
        sequence.sourceSelects = try sequence.sourceSelects.compactMap { select in
            guard matches(select.range.file, useID: select.id) else { return select }
            guard let range = try conformed(.init(from: select.range.from, to: select.range.to),
                                            duration: media.duration, id: select.id) else { return nil }
            guard !lossKeepsOldPath.contains(select.id) else { return select }
            var copy = select
            copy.range = try .init(file: destination, from: range.from, to: range.to)
            return copy
        }
        let retainedClipIDs = Set(sequence.items.compactMap(\.source).map(\.id))
        sequence.stillReplacements = try sequence.stillReplacements.compactMap { replacement in
            guard case .sequence(let fragments) = replacement.coverage else { return replacement }
            let revised = try fragments.compactMap { fragment -> StillReplacementFragment? in
                let id = "\(replacement.id)/\(fragment.clipID)"
                guard retainedClipIDs.contains(fragment.clipID) else {
                    report.lostUseIDs.append(id)
                    return nil
                }
                guard selectedClips.contains(fragment.clipID), !lossKeepsOldPath.contains(fragment.clipID) else { return fragment }
                return try conformed(fragment.range, duration: media.duration, id: id)
                    .map { .init(clipID: fragment.clipID, range: $0) }
            }
            guard !revised.isEmpty else { return nil }
            var copy = replacement
            copy.coverage = .sequence(revised)
            return copy
        }
        let revisedClips = sequence.items.compactMap(\.source)
        let replacedPicture = revisedClips.contains {
            $0.file == destination && selectedClips.contains($0.id) && !lossKeepsOldPath.contains($0.id)
        }
        let participantUse = uses.contains { $0.kind == .participant || $0.kind == .participantAudio }
        if replacedPicture || participantUse {
            let retainsOldPicture = !replacesAtSameLocation && revisedClips.contains { sameSource($0.file) }
            var sourceIDs = Set(sequence.participants.protectedMediaPaths.map { $0.1 }.filter(sameSource))
            for review in sequence.participants.pendingReviews where sameSource(review.file) {
                sourceIDs.insert(review.sourceID)
            }
            if replacedPicture, sourceIDs.isEmpty, sequence.participants.hasEffectiveTreatments {
                sourceIDs.insert(source)
            }
            for id in sourceIDs.sorted() {
                try reviseParticipants(&sequence.participants, id: id, newID: destination, preserveOriginal: retainsOldPicture)
            }
        }
        return sequence
    }
}

extension ReplaceEdit {
    private func replaceMulticam(_ value: MulticamProject) throws -> MulticamProject {
        guard let media else { return value }
        let indexed = try engine.multicamClock(media)
        let targeted = Set(value.sources.filter { $0.feedAngle == nil && matches($0.file, useID: $0.id) }.map(\.id))
        if let selectedID, let reference = value.angles.first(where: { $0.id == selectedID })?.feedAngle {
            report.blockers.append("Replace the recording ‘\(reference.sourceID)’ that supplies this feed angle.")
            return value
        }
        let cameraIDs = Set(value.pictureSources.map(\.id))
        let parentIDs = Dictionary(uniqueKeysWithValues: value.angles.compactMap { angle in
            angle.feedAngle.map { (angle.id, $0.sourceID) }
        })
        let initialPlan = try value.plan()
        var removed = Set<String>()
        var pictureCoverage: [String: MulticamRange] = [:]
        let pictureSpansBySource = Dictionary(grouping: initialPlan.picture) { parentIDs[$0.source] ?? $0.source }
        let audioSpansBySource = Dictionary(grouping: initialPlan.audioLanes.flatMap(\.spans), by: \.source)
        var result = value

        func reviseSource(_ source: MulticamSource) throws -> MulticamSource? {
            guard targeted.contains(source.id) else { return source }
            var copy = source
            copy.file = destination
            copy.audioStream = source.audioStream.map { mapStream($0) }
            let bound = value.audioReplacements.filter { $0.replacement.source == source.id }
            let oldMulticamOffset = oldMedia?.multicamSourceOffset
                ?? previousEntry?.origin.map { MediaInfo.multicamSourceOffset(origin: $0, format: oldURL.pathExtension.lowercased()) }
                ?? .zero
            let shift = options.clock == .sourceTimecode
                ? try clockDelta.adding(indexed.multicamClockOffset).subtracting(oldMulticamOffset)
                : .zero
            let manual = bound.isEmpty ? options.replacementOffset : nil
            copy.offset = try manual ?? source.offset.subtracting(shift)
            if let sync = options.resync, bound.isEmpty {
                if source.id == value.referenceAngle {
                    report.blockers.append("The reference angle sets the group clock. Choose a different reference before re-syncing this source.")
                } else {
                    var trial = value
                    trial.angles = value.angles.map { angle in
                        var angle = angle
                        if angle.id == copy.id { angle.file = copy.file; angle.audioStream = copy.audioStream }
                        angle.additionalRecordings = angle.additionalRecordings.map { recording in
                            recording.id == copy.id ? copy : recording
                        }
                        return angle
                    }
                    trial.audioSources = value.audioSources.map { $0.id == copy.id ? copy : $0 }
                    trial.syncFeedAngleRecordings()
                    let analysis = try MulticamSync.analyze(trial, relativeTo: projectURL, indexed: [copy.id: indexed],
                                                            sourceID: copy.id, waveform: sync == .waveform,
                                                            useSidecar: false, cancelled: cancelled)
                    if let offset = synchronizationOffset(analysis, method: sync) { copy.offset = offset }
                }
            }
            offsets[source.id] = copy.offset
            if source.offset != copy.offset {
                report.offsets.append(.init(useID: source.id, before: source.offset, after: copy.offset))
            }
            let available = try MulticamRange(from: copy.offset, to: copy.offset.adding(indexed.duration))
            if cameraIDs.contains(source.id) { pictureCoverage[source.id] = available }
            let pictureSpans = pictureSpansBySource[source.id] ?? []
            let audioSpans = audioSpansBySource[source.id] ?? []
            let spans = pictureSpans + audioSpans
            let groups = try spans.map {
                try MulticamRange(from: $0.input.from.adding(source.offset), to: $0.input.to.adding(source.offset))
            }
            let bounds = source.coverage.map { [$0] } ?? groups
            let outside = bounds.filter { $0.from < available.from || $0.to > available.to }
            if !outside.isEmpty {
                report.warnings.append("The replacement changes group coverage for \(source.id).")
                if outside.contains(where: { $0.to <= available.from || $0.from >= available.to }) {
                    report.lostUseIDs.append(source.id)
                }
            }
            if let authored = source.coverage {
                let lower = max(authored.from, available.from)
                let upper = min(authored.to, available.to)
                if lower >= upper, options.loss == .remove {
                    removed.insert(source.id)
                    return nil
                }
                if options.conform == .trim, lower < upper, !outside.isEmpty {
                    copy.coverage = .init(from: lower, to: upper)
                    report.trimmedUseIDs.append(source.id)
                } else if authored.from < copy.offset {
                    report.blockers.append("The new offset is later than the saved coverage start. Trim the coverage or choose another offset.")
                }
            } else if !bounds.isEmpty, bounds.allSatisfy({ $0.to <= available.from || $0.from >= available.to }),
                      options.loss == .remove {
                removed.insert(source.id)
                return nil
            } else if options.conform == .trim, cameraIDs.contains(source.id), !outside.isEmpty {
                let lower = max(value.range.from, available.from)
                let upper = min(value.range.to, available.to)
                if lower < upper {
                    copy.coverage = .init(from: lower, to: upper)
                    report.trimmedUseIDs.append(source.id)
                }
            }
            for group in groups.prefix(pictureSpans.count) {
                let range = try MulticamRange(from: group.from.subtracting(copy.offset),
                                               to: group.to.subtracting(copy.offset))
                reportBoundaries(range, id: source.id, media: indexed)
            }
            return copy
        }

        result.angles = try value.angles.map { angle in
            if angle.feedAngle != nil { return angle }
            let recordings = try angle.recordings.compactMap(reviseSource)
            if var primary = recordings.first, primary.id == angle.id {
                primary.additionalRecordings = Array(recordings.dropFirst())
                return primary
            }
            // Switches and explicit assembly routes retain the logical angle ID. The
            // out-of-range occurrences are removed from the assembly below.
            var logicalAngle = angle
            logicalAngle.file = destination
            logicalAngle.audioStream = nil
            logicalAngle.additionalRecordings = recordings
            return logicalAngle
        }
        let remainingPictures = Set(result.pictureSources.filter { $0.feedAngle == nil }.map(\.id))
        if let orphaned = result.angles.first(where: { angle in
            angle.feedAngle.map { removed.contains($0.sourceID) || !remainingPictures.contains($0.sourceID) } ?? false
        }) {
            report.blockers.append("Removing the recording would leave feed angle ‘\(orphaned.name ?? orphaned.id)’ without its source.")
            return value
        }
        result.syncFeedAngleRecordings()
        result.audioSources = try value.audioSources.compactMap(reviseSource)
        let items = value.assemblyItems ?? [.group(value.range)]
        let intervalsByIndex = Dictionary(grouping: initialPlan.intervals, by: \.assemblyIndex)
        let piecesByOccurrence = items.enumerated().map { index, item -> [StillAssemblyItem] in
            guard let group = item.group else { return [item] }
            var ranges: [MulticamRange] = []
            for interval in intervalsByIndex[index] ?? [] {
                var kept = interval.group
                if let id = interval.pictureSourceID, let coverage = pictureCoverage[parentIDs[id] ?? id] {
                    let from = max(coverage.from, kept.from)
                    let to = min(coverage.to, kept.to)
                    if from >= to {
                        report.lostUseIDs.append(id)
                        if options.loss == .remove { continue }
                    } else if options.conform == .trim, from != kept.from || to != kept.to {
                        kept = .init(from: from, to: to)
                        report.trimmedUseIDs.append(id)
                    }
                }
                if ranges.last?.to == kept.from {
                    ranges[ranges.count - 1].to = kept.to
                } else {
                    ranges.append(kept)
                }
            }
            if ranges == [group] { return [item] }
            if let only = ranges.first, ranges.count == 1 { return [item.trimmingGroup(to: only)] }
            return ranges.enumerated().map { index, range in
                item.groupPiece(range, from: range.from, to: range.to, keepingID: index == 0)
            }
        }
        let conformedItems = piecesByOccurrence.flatMap { $0 }
        if items != conformedItems {
            if conformedItems.isEmpty {
                report.blockers.append("Removing the affected spans would leave an empty assembly. Keep one use offline or edit the assembly first.")
            } else {
                let origin = piecesByOccurrence.enumerated().flatMap { index, pieces in pieces.map { _ in index } }
                result.replaceAssembly(conformedItems, carryingPauseReviewsFrom: origin)
            }
        }
        func mapSelection(_ selection: MulticamAudioSelection) -> MulticamAudioSelection? {
            guard !removed.contains(selection.source) else { return nil }
            guard targeted.contains(selection.source) else { return selection }
            return .init(source: selection.source, stream: mapStream(selection.stream))
        }
        result.fixedAudio = value.fixedAudio.flatMap(mapSelection)
        if case .fixed(let selection) = value.audio {
            result.audio = mapSelection(selection).map(MulticamAudioPolicy.fixed) ?? .none
        }
        result.switches = value.switches.map { marker in
            var copy = marker
            copy.audio = marker.audio.flatMap(mapSelection)
            return copy
        }
        result.mixLanes = value.mixLanes.compactMap { lane in
            guard case .recording(let selection) = lane.target else { return lane }
            guard let selection = mapSelection(selection) else { return nil }
            var copy = lane
            copy.target = .recording(selection)
            return copy
        }
        if result.audio == .mix, result.mixLanes.isEmpty { result.audio = .none }
        result.audioReplacements = try value.audioReplacements.compactMap { binding in
            guard let original = mapSelection(binding.original), let replacement = mapSelection(binding.replacement) else { return nil }
            var offset = binding.relativeOffset
            var cameraClockShift = RationalTime.zero
            if (options.clock == .sourceTimecode || options.resync != nil),
               let oldCamera = value.pictureSources.first(where: { $0.id == original.source }),
               let newOffset = offsets[original.source] {
                cameraClockShift = try oldCamera.offset.subtracting(newOffset)
                offset = try offset.adding(cameraClockShift)
            }
            if targeted.contains(replacement.source) {
                if let sync = options.resync, let source = result.audioSources.first(where: { $0.id == replacement.source }) {
                    let analysis = try MulticamSync.analyzeReplacement(result,
                        request: .init(reference: original, source: source, stream: replacement.stream, seed: offset),
                        relativeTo: projectURL, indexed: [source.id: indexed], waveform: sync == .waveform,
                        useSidecar: false, cancelled: cancelled)
                    let absoluteOffset = synchronizationOffset(analysis, method: sync)
                    if let absoluteOffset, let originalSource = result.sources.first(where: { $0.id == original.source }) {
                        offset = try absoluteOffset.subtracting(originalSource.offset)
                    }
                } else if let manual = options.replacementOffset {
                    offset = manual
                } else if options.clock == .sourceTimecode {
                    offset = try offset.subtracting(clockDelta)
                }
                if let stream = indexed.audio.first(where: { $0.stream.index == replacement.stream }) {
                    let ranges = try (audioSpansBySource[binding.original.source] ?? [])
                        .filter { $0.stream == binding.original.stream }
                        .map {
                            try MulticamRange(from: $0.input.from.adding(cameraClockShift).subtracting(offset),
                                             to: $0.input.to.adding(cameraClockShift).subtracting(offset))
                        }
                    if ranges.contains(where: { $0.from < stream.start || $0.to > stream.end }) {
                        report.warnings.append("Replacement audio \(binding.id) leaves uncovered audio at its relative offset.")
                    }
                    if !ranges.isEmpty, ranges.allSatisfy({ $0.to <= stream.start || $0.from >= stream.end }) {
                        report.lostUseIDs.append(binding.id)
                        if options.loss == .remove { return nil }
                    }
                }
            }
            if offset != binding.relativeOffset {
                report.offsets.append(.init(useID: binding.id, before: binding.relativeOffset, after: offset))
            }
            return .init(id: binding.id, original: original, replacement: replacement, relativeOffset: offset,
                         uncovered: binding.uncovered)
        }
        let retainedIDs = Set(result.sources.map(\.id))
        for id in targeted.intersection(retainedIDs).sorted() {
            try reviseParticipants(&result.participants, id: id, newID: id, preserveOriginal: false)
        }
        for index in result.participants.people.indices {
            guard let selection = result.participants.people[index].audio?.selection, targeted.contains(selection.source) else { continue }
            result.participants.people[index].audio = mapSelection(selection).map { .init(selection: $0) }
        }
        return result
    }

    private func synchronizationOffset(_ analysis: MulticamSync.Report, method: MediaReplaceSync) -> RationalTime? {
        let suggestion = analysis.suggestions.first
        if method == .timecode, let reference = analysis.referenceStamp, let candidate = suggestion?.stamp,
           reference.kind != candidate.kind {
            report.needsSharedTimeOfDay = true
            if !options.sharedTimeOfDay {
                report.blockers.append("Confirm that Broadcast Wave and timecode use the same time of day before re-syncing.")
                return nil
            }
        }
        let offset = method == .waveform ? suggestion?.waveformOffset : suggestion?.metadataOffset
        if offset == nil {
            report.blockers.append((method == .waveform ? suggestion?.waveformIssue : suggestion?.metadataIssue)
                ?? "The replacement could not be synchronized to its reference.")
        }
        return offset
    }
}
