import Foundation
import MPCutCore

final class StillAuthoringTiming {
    private enum Source {
        case sequence(CutSequenceClip)
        case group(MulticamProject, MulticamRange, occurrence: Int)
    }

    private struct Item {
        let output: MulticamRange
        let source: Source?
        let insert: StillInsert?
    }

    let project: CutProject
    let location: URL
    let engine: CutEngine

    private var lastIndex: (url: URL, media: MediaInfo)?

    init(project: CutProject, location: URL, engine: CutEngine) {
        self.project = project
        self.location = location
        self.engine = engine
    }

    private func items() throws -> [Item] {
        var outputStart = RationalTime.zero
        var result: [Item] = []
        func append(length: RationalTime, source: Source? = nil, insert: StillInsert? = nil) throws {
            let end = try outputStart.adding(length)
            result.append(Item(output: MulticamRange(from: outputStart, to: end), source: source, insert: insert))
            outputStart = end
        }
        switch project {
        case .sequence(let clips):
            for clip in clips {
                try append(length: clip.to.subtracting(clip.from), source: .sequence(clip))
            }
        case .stillSequence(let sequence):
            for item in sequence.items {
                switch item {
                case .source(let clip): try append(length: clip.to.subtracting(clip.from), source: .sequence(clip))
                case .still(let card): try append(length: card.duration, insert: card)
                }
            }
        case .multicam(let multicam):
            for (index, item) in (multicam.assemblyItems ?? [.group(multicam.range)]).enumerated() {
                switch item {
                case .group(let group, _): try append(length: group.to.subtracting(group.from), source: .group(multicam, group, occurrence: index))
                case .still(let card): try append(length: card.duration, insert: card)
                }
            }
        }
        return result
    }

    private func index(_ url: URL) throws -> MediaInfo? {
        if let lastIndex, lastIndex.url == url { return lastIndex.media }
        guard (try? SourceIdentity(url)) != nil else { return nil }
        let media = try engine.inspect(url, keyframes: true)
        guard media.hasVideo, !media.frames.isEmpty else {
            throw CutError(code: "no_video", message: "Still placement requires indexed picture in ‘\(url.path)’.")
        }
        lastIndex = (url, media)
        return media
    }

    func inferredCadence(_ at: RationalTime, requireUniform: Bool = true) throws -> RationalTime {
        let items = try items()
        let item = items.first { $0.output.contains(at) } ?? (items.last?.output.to == at ? items.last : nil)
        if let insert = item?.insert { return insert.cadence }
        let url: URL?
        switch item?.source {
        case .sequence(let clip):
            url = CutProject.mediaURL(clip.file, relativeTo: location)
        case .group(let multicam, _, _):
            url = multicam.angles.first { $0.id == multicam.referenceAngle }.map {
                multicam.sourceURL(for: $0, relativeTo: location)
            }
        case nil:
            url = nil
        }
        let error = CLIError("still_rate_required", "Specify --rate FPS for variable-rate or unavailable picture.")
        guard let url, let media = try index(url), let rate = media.videoStream?.frameRate, rate > .zero else {
            throw error
        }
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        guard !requireUniform || media.frames.allSatisfy({ $0.duration == cadence }) else { throw error }
        return cadence
    }

    func colorPolicy(in updated: CutProject) throws -> StillProgramColorPolicy? {
        let timeline = try updated.resolveStills()
        let clips = Dictionary(uniqueKeysWithValues: (updated.sequenceClips ?? []).map { ($0.id, $0) })
        let retained = timeline.spans.filter { $0.placementID == nil }
        // Fully covered projects still derive the format from their camera timeline.
        for span in retained.isEmpty ? timeline.spans : retained {
            let url: URL
            switch span.origin {
            case .source(let id, _):
                guard let clip = clips[id] else { continue }
                url = CutProject.mediaURL(clip.file, relativeTo: location)
            case .group(let occurrence, let range):
                guard case .multicam(let multicam) = updated,
                      let camera = multicam.pictureAngle(at: range.from, in: occurrence),
                      let source = multicam.pictureSource(for: camera, at: range.from) else { continue }
                url = multicam.sourceURL(for: source, relativeTo: location)
            case .insert:
                continue
            }
            guard (try? SourceIdentity(url)) != nil,
                  let video = try engine.inspectSummary(url).videoStream else { continue }
            return try? StillProgramColorPolicy.resolving(source: video)
        }
        return nil
    }

    func validateFragments(_ fragments: [StillReplacementFragment]) throws {
        let clips: [CutSequenceClip]
        switch project {
        case .sequence(let sequence): clips = sequence
        case .stillSequence(let sequence): clips = sequence.items.compactMap(\.source)
        case .multicam: return
        }
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var indexed: [URL: MediaInfo] = [:]
        for fragment in fragments {
            guard let clip = byID[fragment.clipID] else { continue }
            let url = CutProject.mediaURL(clip.file, relativeTo: location)
            guard let media = try indexed[url] ?? index(url) else { continue }
            indexed[url] = media
            try validateBoundary(fragment.range.from, in: media, label: "from")
            try validateBoundary(fragment.range.to, in: media, label: "to")
        }
    }

    func validateGroup(_ range: MulticamRange) throws {
        guard case .multicam(let multicam) = project else { return }
        let startCamera = multicam.selection(at: range.from)?.angle
        let endCamera = multicam.switches.last { $0.at < range.to }?.angle
        try validateGroupBoundary(range.from, multicam: multicam, angle: startCamera, label: "from")
        try validateGroupBoundary(range.to, multicam: multicam, angle: endCamera, label: "to", exclusiveEnd: true)
    }

    func validateInsertBoundary(_ at: RationalTime, moving placement: String? = nil) throws {
        guard let item = try items().first(where: { $0.output.contains(at) }), at > item.output.from else { return }
        if item.insert?.id == placement, placement != nil { return }
        let local = try at.subtracting(item.output.from)
        switch item.source {
        case .sequence(let clip):
            let url = CutProject.mediaURL(clip.file, relativeTo: location)
            if let media = try index(url) { try validateBoundary(clip.from.adding(local), in: media, label: "at") }
        case .group(let multicam, let range, let occurrence):
            let group = try range.from.adding(local)
            try validateGroupBoundary(group, multicam: multicam, angle: multicam.pictureAngle(at: group, in: occurrence), label: "at")
        case nil: break
        }
    }

    private func validateGroupBoundary(_ time: RationalTime, multicam: MulticamProject, angle: String?,
                                       label: String, exclusiveEnd: Bool = false) throws {
        guard let camera = angle.flatMap({ multicam.pictureSource(for: $0, at: time, exclusiveEnd: exclusiveEnd) }),
              let media = try index(multicam.sourceURL(for: camera, relativeTo: location)) else { return }
        try validateBoundary(time.subtracting(camera.offset).subtracting(media.multicamSourceOffset), in: media, label: label)
    }

    private func validateBoundary(_ time: RationalTime, in media: MediaInfo, label: String) throws {
        let at = media.frames.lowerBound { $0.time >= time }
        let end = try media.frames.last.map { try $0.time.adding($0.duration) }
        if at < media.frames.count && media.frames[at].time == time || time == end { return }
        var nearest: [RationalTime] = []
        if at > 0 { nearest.append(media.frames[at - 1].time) }
        if at < media.frames.count {
            nearest.append(media.frames[at].time)
        } else if let end {
            nearest.append(end)
        }
        throw CutError(code: "invalid_still_boundary",
                       message: "The \(label) edge at source time \(time) is between pictures in ‘\(media.url.path)’.",
                       boundary: label, nearest: nearest)
    }
}
