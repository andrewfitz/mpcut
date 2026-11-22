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

    func issues(in result: MediaRefreshResult) throws -> [MediaRefreshReferenceIssue] {
        if result.state == .offline { return [.init(id: id, reason: .offline)] }
        guard let evidence = result.referenceEvidence else { return [] }
        var issues: [MediaRefreshReferenceIssue] = []
        var start = RationalTime.zero
        var end = evidence.duration
        var hasDeclaredPCMStart = false
        let audioIndices = evidence.streams.indices.filter { evidence.streams[$0].kind == "audio" }
        let stream: Int?
        switch track {
        case .video:
            stream = evidence.videoIndex >= 0 ? evidence.videoIndex : nil
        case .audioStream(let index):
            stream = audioIndices.contains(index) ? index : nil
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
            let offset = multicam && evidence.origin > .zero && evidence.format.split(separator: ",").contains("mov")
                ? evidence.origin : .zero
            let first = try start.adding(offset)
            let last = try end.adding(offset)
            let startsWithSilence = mayStartWithSilence && hasDeclaredPCMStart && range.lowerBound >= .zero
            if (!startsWithSilence && range.lowerBound < first) || range.lowerBound >= last || range.upperBound > last {
                issues.append(.init(id: id, reason: .rangeOutsideMedia))
            }
        }
        if (track != nil && stream.map({ !result.reviewStreams.contains($0) }) != true) ||
            (validatesPriorPicture && result.pictureNeedsReview) {
            issues.append(.init(id: id, reason: .trackNeedsReview))
        }
        return issues
    }
}

extension MediaRefresh {
    /// Checks each distinct recording in the saved timeline and its edit history.
    /// Refresh is a media operation and does not write the project document.
    public static func project(at url: URL, verification: MediaRefreshVerification = .stamp,
                               persist: Bool = true, progress: ((Double) -> Void)? = nil,
                               cancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> [MediaRefreshResult] {
        try checkCancellation(cancelled)
        let document = try CutProject.loadEditorDocument(from: url, limit: CutProject.maximumHistorySteps)
        let history = document.undo.map(\.project) + document.redo.map(\.project)
        var references: [URL: Set<MediaRefreshReference>] = [:]
        var resolved: [String: URL] = [:]
        func add(_ path: String, _ reference: MediaRefreshReference) {
            let source = resolved[path] ?? AnalysisSidecar.canonicalSource(CutProject.mediaURL(path, relativeTo: url))
            resolved[path] = source
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
        for project in [document.project] + history {
            try checkCancellation(cancelled)
            switch project {
            case .sequence(let clips):
                add(clips)
            case .stillSequence(let project):
                add(project.items.compactMap(\.source))
            case .multicam(let project):
                let sources = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0) })
                for source in project.sources {
                    add(source.file, .init(id: source.id, track: source.audioStream.map(MediaRefreshReference.Track.audioStream)))
                }
                let plan = try project.plan()
                for span in plan.picture + plan.audio {
                    guard let source = sources[span.source] else { continue }
                    add(source.file, .init(id: source.id, range: span.input.from..<span.input.to,
                                           track: span.stream.map(MediaRefreshReference.Track.audioStream) ?? .video,
                                           multicam: true, mayStartWithSilence: span == plan.audio.first))
                }
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
            var result = try check(group.url, identity: group.identity, previous: nil, verification: verification,
                                   persist: persist, exclusions: exclusions, progress: sourceProgress, cancelled: cancelled)
            result.referenceIssues = Set(try group.refs.flatMap { try $0.issues(in: result) })
                .sorted { ($0.id, $0.reason.rawValue) < ($1.id, $1.reason.rawValue) }
            return result
        }
    }
}
