import Foundation

private struct MediaRefreshReference: Hashable {
    enum Track: Hashable {
        case video
        case audioStream(Int)
        case audioOrdinal(Int)
    }

    let id: String
    var range: Range<RationalTime>?
    var track: Track?
    var multicam = false
    var validatesPriorPicture = false
    var mayStartWithSilence = false
    var participantStamp: SceneSourceStamp?
    var participantInode: UInt64?
    var presenceOnly = false

    func collectIssues(in evidence: MediaRefreshEvidence, audioIndices: [Int], multicamOffset: RationalTime,
                       reviewStreams: Set<Int>, into issues: inout Set<MediaRefreshReferenceIssue>) throws {
        var start = RationalTime.zero
        var end = evidence.duration
        var hasDeclaredPCMStart = false
        let stream: Int?
        switch track {
        case .video:
            stream = evidence.videoIndex >= 0 ? evidence.videoIndex : nil
        case .audioStream(let index):
            stream = evidence.streams.indices.contains(index) && evidence.streams[index].kind == "audio" ? index : nil
        case .audioOrdinal(let ordinal):
            stream = audioIndices.indices.contains(ordinal) ? audioIndices[ordinal] : nil
        case nil:
            stream = nil
        }
        if let stream, evidence.streams.indices.contains(stream) {
            let descriptor = evidence.streams[stream]
            start = descriptor.audioStart ?? start
            end = descriptor.audioEnd ?? end
            hasDeclaredPCMStart = descriptor.hasDeclaredPCMStart
        }
        if let range {
            let offset = multicam ? multicamOffset : .zero
            let first = try start.adding(offset)
            let last = try end.adding(offset)
            let startsWithSilence = mayStartWithSilence && hasDeclaredPCMStart && range.lowerBound >= .zero
            if (!startsWithSilence && range.lowerBound < first) || range.lowerBound >= last || range.upperBound > last {
                issues.insert(.init(id: id, reason: .rangeOutsideMedia))
            }
        }
        if (track != nil && stream.map({ !reviewStreams.contains($0) }) != true) ||
            (validatesPriorPicture && evidence.pictureNeedsReview == true) {
            issues.insert(.init(id: id, reason: .trackNeedsReview))
        }
    }
}

extension MediaRefresh {
    /// Checks each distinct media file referenced by the current project.
    /// Refresh is a media operation and does not write the project document.
    public static func project(at url: URL, verification: MediaRefreshVerification = .stamp,
                               persist: Bool = true, progress: ((Double) -> Void)? = nil,
                               cancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> [MediaRefreshResult] {
        try checkCancellation(cancelled)
        let document = try CutProject.loadEditorDocument(from: url, limit: 0)
        var references: [URL: Set<MediaRefreshReference>] = [:]
        var resolved: [String: URL] = [:]
        func add(_ path: String, _ reference: MediaRefreshReference) {
            let source: URL
            if let cached = resolved[path] {
                source = cached
            } else {
                let media = CutProject.mediaURL(path, relativeTo: url)
                source = media.path.split(separator: "/").contains("..") ? media : AnalysisSidecar.canonicalSource(media)
                resolved[path] = source
            }
            references[source, default: []].insert(reference)
        }
        func add(_ clips: [CutSequenceClip]) {
            for clip in clips {
                let range = clip.from..<clip.to
                add(clip.file, .init(id: clip.id, range: range, validatesPriorPicture: true))
                if let selected = clip.audioTrack {
                    add(clip.file, .init(id: clip.id, range: range, track: .audioOrdinal(selected)))
                }
                for ordinal in clip.replacementNames.keys {
                    add(clip.file, .init(id: clip.id, track: .audioOrdinal(ordinal)))
                }
                if let original = clip.originalFile {
                    add(original, .init(id: clip.id, range: range, validatesPriorPicture: true))
                }
            }
        }
        let project = document.project
        try checkCancellation(cancelled)
        switch project {
        case .sequence(let clips):
            add(clips)
        case .stillSequence(let project):
            add(project.items.compactMap(\.source))
            if let reference = project.stillAudioReference { add([reference]) }
            if let soundtrack = project.stillSoundtrack, let ordinal = soundtrack.audioTrack {
                add(soundtrack.file, .init(id: soundtrack.id, range: soundtrack.from..<soundtrack.to,
                                           track: .audioOrdinal(ordinal)))
                if let original = soundtrack.originalFile {
                    add(original, .init(id: soundtrack.id, range: soundtrack.from..<soundtrack.to))
                }
            }
        case .multicam(let project):
            let sources = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0) })
            for source in project.sources {
                add(source.file, .init(id: source.id, track: source.audioStream.map(MediaRefreshReference.Track.audioStream)))
            }
            for geometry in project.participants.sources {
                if let source = sources[geometry.sourceID] {
                    add(source.file, .init(id: geometry.sourceID, participantStamp: geometry.sourceStamp,
                                          participantInode: geometry.sourceInode))
                }
            }
            let participantSelections = project.participants.people.compactMap { $0.audio?.selection }
            let selections = project.switches.compactMap(\.audio) + [project.fixedAudio].compactMap { $0 }
                + project.mixLanes.compactMap { lane -> MulticamAudioSelection? in
                    if case .recording(let selection) = lane.target { return selection }
                    return nil
                }
                + project.audioReplacements.flatMap { [$0.original, $0.replacement] }
                + participantSelections
            for selection in selections {
                guard let source = sources[selection.source] else { continue }
                add(source.file, .init(id: source.id, track: .audioStream(selection.stream)))
            }
            let plan = try project.plan()
            for span in plan.picture {
                guard let source = sources[span.source] else { continue }
                add(source.file, .init(id: source.id, range: span.input.from..<span.input.to,
                                       track: .video, multicam: true))
            }
            for lane in plan.audioLanes {
                for (index, span) in lane.spans.enumerated() {
                    guard let source = sources[span.source], let stream = span.stream else { continue }
                    add(source.file, .init(id: source.id, range: span.input.from..<span.input.to,
                                           track: .audioStream(stream), multicam: true, mayStartWithSilence: index == 0))
                }
            }
        }
        if project.sequenceItems != nil {
            for geometry in project.participants.sources {
                add(geometry.sourceID, .init(id: geometry.sourceID, participantStamp: geometry.sourceStamp,
                                             participantInode: geometry.sourceInode))
            }
            for person in project.participants.people {
                if let selection = person.audio?.selection {
                    add(selection.source, .init(id: person.id, track: .audioStream(selection.stream)))
                }
            }
        }
        for use in ProjectMedia.references(in: project, includePlannedSpans: false) {
            switch use.kind {
            case .still:
                add(use.path, .init(id: use.id, presenceOnly: true))
            case .select, .transcript, .transcriptAnchor, .participant:
                let track = use.stream.map(MediaRefreshReference.Track.audioStream)
                    ?? use.ordinal.map(MediaRefreshReference.Track.audioOrdinal)
                add(use.path, .init(id: use.id, range: use.range.map { $0.from..<$0.to }, track: track,
                                    multicam: use.sourceID != nil))
            default: break
            }
        }
        var grouped: [(url: URL, identity: SourceIdentity?, refs: Set<MediaRefreshReference>)] = []
        var indexByIdentity: [SourceIdentity: Int] = [:]
        for url in references.keys.sorted(by: { $0.path < $1.path }) {
            let identity = try? SourceIdentity(url)
            if let identity, let index = indexByIdentity[identity] {
                grouped[index].refs.formUnion(references[url] ?? [])
            } else {
                if let identity { indexByIdentity[identity] = grouped.count }
                grouped.append((url, identity, references[url] ?? []))
            }
        }
        let exclusions = document.media.sidecarExclusions(relativeTo: url)
        return try grouped.enumerated().map { position, group in
            let sourceProgress = progress.map { report in
                { (fraction: Double) in report((Double(position) + fraction) / Double(grouped.count)) }
            }
            var result: MediaRefreshResult
            if group.refs.allSatisfy(\.presenceOnly) {
                try checkCancellation(cancelled)
                result = presence(of: group.url, identity: group.identity)
                sourceProgress?(1)
            } else {
                result = try check(group.url, identity: group.identity, previous: nil, verification: verification,
                                   persist: persist, exclusions: exclusions, progress: sourceProgress, cancelled: cancelled)
            }
            var issues: Set<MediaRefreshReferenceIssue> = []
            if result.state == .offline {
                for reference in group.refs {
                    issues.insert(.init(id: reference.id, reason: .offline))
                }
            } else if let evidence = result.referenceEvidence {
                let audioIndices = evidence.streams.indices.filter { evidence.streams[$0].kind == "audio" }
                let multicamOffset = evidence.origin > .zero && evidence.format.split(separator: ",").contains("mov")
                    ? evidence.origin : .zero
                for reference in group.refs {
                    try reference.collectIssues(in: evidence, audioIndices: audioIndices, multicamOffset: multicamOffset,
                                                reviewStreams: result.reviewStreams, into: &issues)
                    if let stamp = reference.participantStamp, let identity = group.identity,
                       stamp != SceneSourceStamp(identity: identity)
                           || reference.participantInode.map({ $0 != identity.inode }) == true {
                        issues.insert(.init(id: reference.id, reason: .participantGeometryNeedsReview))
                    }
                }
            }
            result.referenceIssues = issues.sorted { ($0.id, $0.reason.rawValue) < ($1.id, $1.reason.rawValue) }
            return result
        }
    }
}
