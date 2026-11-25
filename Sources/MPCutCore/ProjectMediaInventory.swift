import Foundation

public enum ProjectMediaStatus: String, Codable, Sendable {
    case online, indexing, offline, checking, changed, needsReview, ignored
}

public struct ProjectMediaUse: Hashable, Encodable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case clip, original, still, stillAudioReference, stillSoundtrack, stillFragment, select, camera, microphone
        case multicamSpan, multicamSelection, transcript, transcriptAnchor, participant, participantAudio
        case analysisAnnotation, pendingTileReview

        package var canReplaceDirectly: Bool { self != .analysisAnnotation && self != .pendingTileReview }
    }

    public let path: String
    public let id: String
    public let kind: Kind
    public var range: MulticamRange?
    public var stream: Int?
    public var ordinal: Int?
    public var channel: Int?
    public var offset: RationalTime?
    var audio = false
    var picture = false
    var mayStartWithSilence = false
    public var sourceID: String?
    var minimumTime: RationalTime?
    var multicamClock = false
    var participantDigest: String?
    var participantStamp: SceneSourceStamp?
    var participantInode: UInt64?
    var participantGeometry = false
    var provenanceID: String?
    var transcriptImportOrigin: RationalTime?

    var provenanceKey: String {
        var fields = [kind.rawValue, provenanceID ?? id, range?.from.description, range?.to.description,
                      stream.map(String.init), ordinal.map(String.init), channel.map(String.init),
                      offset?.description, sourceID, minimumTime?.description, String(multicamClock),
                      participantDigest]
        if let transcriptImportOrigin { fields.append(transcriptImportOrigin.description) }
        // Length prefixes keep distinct identifiers from sharing a token.
        return fields.map { value in value.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined()
    }
}

public struct ProjectMediaRow: Encodable, Sendable {
    public let path: String
    public let url: URL
    public var status: ProjectMediaStatus
    public let uses: [ProjectMediaUse]
    public let canRevert: Bool
    public let duration: RationalTime?

    enum CodingKeys: String, CodingKey { case path, url, status, uses, canRevert = "can_revert", duration }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(path, forKey: .path)
        try fields.encode(url.path, forKey: .url)
        try fields.encode(status, forKey: .status)
        try fields.encode(uses, forKey: .uses)
        try fields.encode(canRevert, forKey: .canRevert)
        try fields.encodeIfPresent(duration, forKey: .duration)
    }
}

public enum ProjectMedia {
    package static func leaveOffline(_ path: String, project: CutProject, relativeTo document: URL,
                                     snapshot: inout ProjectMediaSnapshot) throws {
        func location(_ path: String) -> URL {
            let watched = ProjectMediaVolume.watchURL(path, relativeTo: document)
            return ProjectMediaVolume.isChecking(watched) ? watched : CutProject.mediaURL(path, relativeTo: document)
        }
        let source = location(path)
        guard let reference = references(in: project).first(where: { location($0.path) == source }) else {
            throw CutError(code: "missing_source", message: "This path does not reference project media.")
        }
        if let index = snapshot.entries.firstIndex(where: { location($0.path) == source }) {
            snapshot.entries[index].ignored = true
        } else {
            var entry = ProjectMediaSnapshot.Entry(path: reference.path)
            entry.ignored = true
            snapshot.entries.append(entry)
        }
    }

    public static func inventory(project: CutProject, undo: [CutHistoryState] = [], redo: [CutHistoryState] = [],
                                 relativeTo document: URL, snapshot: ProjectMediaSnapshot = .init(),
                                 includeHistory: Bool = false, statuses: [URL: ProjectMediaStatus] = [:], checkFile: Bool = true) -> [ProjectMediaRow] {
        let currentUses = Set(references(in: project))
        var resolved: [String: URL] = [:]
        func location(_ path: String) -> URL {
            if let url = resolved[path] { return url }
            let watched = ProjectMediaVolume.watchURL(path, relativeTo: document)
            let url = !checkFile || statuses[watched] != nil || ProjectMediaVolume.isChecking(watched)
                ? watched : ProjectFile.canonicalFileURL(CutProject.mediaURL(path, relativeTo: document))
            resolved[path] = url
            return url
        }
        let entries = Dictionary(snapshot.entries.map { (location($0.path), $0) },
                                 uniquingKeysWith: { $0.coalescingAlias($1) })
        let needsProvenance = entries.values.contains { $0.previousPath != nil && $0.relinkUses != nil }
        var retainedByURL: [URL: [ProjectMediaUse]] = [:]
        if needsProvenance || includeHistory {
            var retainedUses = currentUses
            // Adjacent history states usually repeat most uses.
            for state in undo + redo {
                retainedUses.formUnion(references(in: state.project))
            }
            retainedByURL = Dictionary(grouping: retainedUses) { location($0.path) }
        }
        let grouped = includeHistory ? retainedByURL : Dictionary(grouping: currentUses) { location($0.path) }
        return grouped.keys.sorted { $0.path < $1.path }.compactMap { url in
            let uses = (grouped[url] ?? []).map { (use: $0, token: $0.provenanceKey) }.sorted {
                ($0.use.path, $0.token) < ($1.use.path, $1.token)
            }
            guard let path = uses.first?.use.path else { return nil }
            let entry = entries[url]
            let knownStatus = statuses[url] ?? (ProjectMediaVolume.isChecking(url) ? .checking : nil)
            let identity = checkFile && knownStatus == nil ? try? SourceIdentity(url) : nil
            let status: ProjectMediaStatus
            if let known = knownStatus {
                status = known == .offline && entry?.ignored == true ? .ignored : known
            } else if let identity {
                let changed = entry?.size.map { $0 != identity.size } == true
                    || entry?.modifiedSeconds.map { $0 != identity.modifiedSeconds } == true
                    || entry?.modifiedNanoseconds.map { $0 != identity.modifiedNanoseconds } == true
                status = changed ? .changed : .online
            } else {
                status = entry?.ignored == true ? .ignored : (checkFile ? .offline : .checking)
            }
            let canRevert = entry.flatMap { entry in
                entry.relinkUses.map { allowed in
                    guard let previous = entry.previousPath, !allowed.isEmpty, retainedByURL[location(previous)] == nil else {
                        return false
                    }
                    let allowed = Set(allowed)
                    if includeHistory { return uses.allSatisfy { allowed.contains($0.token) } }
                    return retainedByURL[url, default: []].allSatisfy { allowed.contains($0.provenanceKey) }
                }
            } ?? false
            return ProjectMediaRow(path: path, url: url, status: status, uses: uses.map(\.use),
                                   canRevert: canRevert, duration: entry?.duration)
        }
    }

    package static func references(in project: CutProject, includePlannedSpans: Bool = true) -> [ProjectMediaUse] {
        var uses: [ProjectMediaUse] = []
        var recordings: [String: MulticamSource] = [:]
        func clip(_ clip: CutSequenceClip, kind: ProjectMediaUse.Kind = .clip) {
            let range = MulticamRange(from: clip.from, to: clip.to)
            uses.append(.init(path: clip.file, id: clip.id, kind: kind, range: range,
                              ordinal: clip.audioTrack, audio: clip.audioTrack != nil || kind == .stillAudioReference || kind == .stillSoundtrack))
            if let original = clip.originalFile {
                uses.append(.init(path: original, id: clip.id, kind: .original, range: range))
            }
            for ordinal in clip.replacementNames.keys.sorted() {
                uses.append(.init(path: clip.file, id: clip.id, kind: kind, ordinal: ordinal, audio: true))
            }
        }
        func stills(_ assets: [StillAsset]) {
            for asset in assets where !asset.isGap {
                uses.append(.init(path: asset.file, id: asset.id, kind: .still))
            }
        }
        let assets = Dictionary(project.stillAssets.filter { !$0.isGap }.map { ($0.id, $0.file) },
                                uniquingKeysWith: { first, _ in first })
        for insert in project.stillInserts {
            if let path = assets[insert.assetID] {
                uses.append(.init(path: path, id: insert.id, kind: .still, sourceID: insert.assetID))
            }
        }
        for replacement in project.stillReplacements {
            if let path = assets[replacement.assetID] {
                uses.append(.init(path: path, id: replacement.id, kind: .still, sourceID: replacement.assetID))
            }
        }
        func selection(_ value: MulticamAudioSelection, id: String, kind: ProjectMediaUse.Kind,
                       range: MulticamRange? = nil, allowsSilence: Bool = false) {
            guard let path = project.sequenceItems != nil ? value.source : recordings[value.source]?.file else { return }
            uses.append(.init(path: path, id: id, kind: kind, range: range, stream: value.stream,
                              audio: true, mayStartWithSilence: allowsSilence,
                              sourceID: project.sequenceItems == nil ? value.source : nil,
                              multicamClock: project.sequenceItems == nil))
        }
        switch project {
        case .sequence(let clips):
            clips.forEach { clip($0) }
        case .stillSequence(let sequence):
            let clips = sequence.items.compactMap(\.source)
            clips.forEach { clip($0) }
            if let reference = sequence.stillAudioReference { clip(reference, kind: .stillAudioReference) }
            if let soundtrack = sequence.stillSoundtrack { clip(soundtrack, kind: .stillSoundtrack) }
            stills(sequence.stillAssets)
            for select in sequence.sourceSelects {
                let range = MulticamRange(from: select.range.from, to: select.range.to)
                uses.append(.init(path: select.range.file, id: select.id, kind: .select, range: range))
            }
            let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for replacement in sequence.stillReplacements {
                guard case .sequence(let fragments) = replacement.coverage else { continue }
                for fragment in fragments {
                    guard let clip = byID[fragment.clipID] else { continue }
                    uses.append(.init(path: clip.file, id: "\(replacement.id)/\(fragment.clipID)",
                                      kind: .stillFragment, range: fragment.range, picture: true))
                }
            }
        case .multicam(let multicam):
            let cameras = Set(multicam.pictureSources.map(\.id))
            for source in multicam.sources {
                recordings[source.id] = source
                let picture = cameras.contains(source.id)
                uses.append(.init(path: source.file, id: source.id, kind: picture ? .camera : .microphone,
                                  range: source.coverage, stream: source.audioStream, offset: source.offset,
                                  audio: !picture || source.audioStream != nil, picture: picture, multicamClock: true))
            }
            stills(multicam.stillAssets)
            var selections = multicam.switches.compactMap(\.audio)
            if let fixed = multicam.fixedAudio { selections.append(fixed) }
            for lane in multicam.mixLanes {
                if case .recording(let value) = lane.target { selections.append(value) }
            }
            for replacement in multicam.audioReplacements {
                selections += [replacement.original, replacement.replacement]
            }
            for value in selections {
                selection(value, id: value.source, kind: .multicamSelection)
            }
            if includePlannedSpans, let plan = try? multicam.plan() {
                for span in plan.picture {
                    guard let source = recordings[span.source] else { continue }
                    uses.append(.init(path: source.file, id: span.source, kind: .multicamSpan,
                                      range: span.input, picture: true, sourceID: span.source, multicamClock: true))
                }
                for lane in plan.audioLanes {
                    for (index, span) in lane.spans.enumerated() {
                        guard let stream = span.stream else { continue }
                        let original = MulticamAudioSelection(source: span.source, stream: stream)
                        selection(original, id: lane.id, kind: .multicamSpan,
                                  range: span.input, allowsSilence: index == 0)
                        for replacement in multicam.audioReplacements where replacement.original == original {
                            guard let from = try? span.input.from.subtracting(replacement.relativeOffset),
                                  let to = try? span.input.to.subtracting(replacement.relativeOffset),
                                  to > .zero else { continue }
                            // A replacement can cover a subset of the original span.
                            let range = MulticamRange(from: max(from, .zero), to: to)
                            guard let replacementSource = recordings[replacement.replacement.source] else { continue }
                            uses.append(.init(path: replacementSource.file, id: replacement.id,
                                              kind: .multicamSelection,
                                              stream: replacement.replacement.stream, audio: true,
                                              sourceID: replacement.replacement.source,
                                              minimumTime: range.from, multicamClock: true))
                        }
                    }
                }
            }
        }

        func transcript(_ binding: TranscriptBinding, id: String, range: MulticamRange? = nil,
                        importOrigin: RationalTime? = nil) {
            guard let path = binding.file ?? binding.sourceID.flatMap({ recordings[$0]?.file }) else { return }
            uses.append(.init(path: path, id: "\(id)/\(binding.trackID)",
                              kind: range == nil ? .transcript : .transcriptAnchor, range: range,
                              stream: binding.streamIndex, ordinal: binding.sequenceStreamOrdinal,
                              channel: binding.channel, offset: range != nil && binding.offset != .zero ? binding.offset : nil,
                              audio: true, sourceID: binding.sourceID, multicamClock: binding.sourceID != nil,
                              transcriptImportOrigin: importOrigin))
        }
        let transcripts = project.transcripts
        var importOrigins: [String: RationalTime] = [:]
        for attachment in transcripts.attachments {
            importOrigins[attachment.id] = attachment.importOrigin
            for binding in attachment.bindings { transcript(binding, id: attachment.id) }
        }
        for record in transcripts.authoring {
            let origin = importOrigins[record.attachmentID]
            for (index, anchor) in record.anchors.enumerated() {
                transcript(anchor.binding, id: "\(record.id)/\(index)", range: anchor.range, importOrigin: origin)
            }
            if let anchor = record.speakerReference {
                transcript(anchor.binding, id: "\(record.id)/speaker", range: anchor.range, importOrigin: origin)
            }
        }

        func participantPath(_ id: String) -> String? {
            project.sequenceItems != nil ? id : recordings[id]?.file
        }
        for geometry in project.participants.sources {
            guard let path = participantPath(geometry.sourceID) else { continue }
            uses.append(.init(path: path, id: geometry.sourceID, kind: .participant, picture: true,
                              participantDigest: geometry.sourceContentSHA256, participantStamp: geometry.sourceStamp,
                              participantInode: geometry.sourceInode, participantGeometry: true,
                              provenanceID: "geometry/\(geometry.analysisIdentity ?? "manual")"))
        }
        for override in project.participants.appearanceOverrides {
            guard let path = participantPath(override.sourceID) else { continue }
            uses.append(.init(path: path, id: override.appearanceID, kind: .participant, picture: true))
        }
        for person in project.participants.people {
            if let value = person.audio?.selection { selection(value, id: person.id, kind: .participantAudio) }
        }
        for (shotIndex, shot) in (project.participants.render?.shots ?? []).enumerated() {
            for (slotIndex, slot) in shot.slots.enumerated() where slot.target == .camera {
                guard let path = participantPath(slot.id) else { continue }
                uses.append(.init(path: path, id: slot.id, kind: .participant, picture: true,
                                  provenanceID: "shot/\(shotIndex)/slot/\(slotIndex)"))
            }
        }
        let annotations = project.analysisAnnotations
        for scene in annotations.scenes {
            guard let evidence = scene.sourceEvidence else { continue }
            uses.append(.init(path: scene.file, id: "scene review", kind: .analysisAnnotation,
                              provenanceID: "scenes/\(evidence.stream)/\(evidence.sha256)"))
        }
        for threshold in annotations.silence {
            uses.append(.init(path: threshold.file, id: "silence threshold", kind: .analysisAnnotation,
                              provenanceID: "silence/\(threshold.stream)/\(threshold.sourceEvidence.sha256)"))
        }
        for review in annotations.pauseReviews {
            for source in review.sources {
                let span = "\(review.from)-\(review.to.map(\.description) ?? "")"
                uses.append(.init(path: source.file, id: "pause review", kind: .analysisAnnotation,
                                  sourceID: source.sourceID,
                                  provenanceID: "pause/\(review.kind.rawValue)/\(span)/\(source.stream)/\(source.evidence.sha256)/\(review.occurrenceID ?? "")"))
            }
        }
        for review in project.participants.pendingReviews {
            uses.append(.init(path: review.file, id: review.id, kind: .pendingTileReview))
            if project.sequenceItems != nil, review.sourceID != review.file {
                uses.append(.init(path: review.sourceID, id: review.id, kind: .pendingTileReview))
            }
        }
        return uses
    }
}
