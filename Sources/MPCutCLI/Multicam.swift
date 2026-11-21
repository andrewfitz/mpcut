import Foundation
import MPCutCore

struct MulticamAssembly {
    private(set) var sources: [String: URL] = [:]
    private var projectSourceIDs: [URL: [String: String]] = [:]
    private var fileIDs: [URL: String] = [:]
    private var intervals: [MulticamInterval] = []
    private var picture: [MulticamSpan] = []
    private var audio: [MulticamSpan] = []
    private var duration = RationalTime.zero
    private var followsCamera = false
    private var clips: [Clip] = []

    private enum Clip {
        case project(MulticamProject, URL, MulticamRange, Int)
        case file(MediaInfo, MulticamRange, Int, ExportTracks)
    }

    var requiresAudio: Bool { followsCamera || !audio.isEmpty }

    var mapping: MulticamPlan {
        MulticamPlan(intervals: intervals, picture: picture, audio: audio, duration: duration)
    }

    /// The same request with one edge of clip `number` moved, to validate a suggested boundary.
    /// A repeated clip moves at each of its positions, as it would in the caller's request.
    func moving(clip number: Int, boundary: String, to time: RationalTime) throws -> MulticamAssembly {
        func moved(_ range: MulticamRange, _ segment: Int) -> MulticamRange {
            guard segment == number else { return range }
            return boundary == "from" ? MulticamRange(from: time, to: range.to) : MulticamRange(from: range.from, to: time)
        }
        var result = MulticamAssembly()
        for clip in clips {
            switch clip {
            case let .project(project, url, range, segment):
                try result.appendProject(project, at: url, range: moved(range, segment), segment: segment)
            case let .file(media, range, segment, tracks):
                try result.appendFile(media, range: moved(range, segment), segment: segment, tracks: tracks)
            }
        }
        return result
    }

    mutating func appendProject(_ project: MulticamProject, at url: URL, range: MulticamRange,
                                segment: Int) throws {
        // A requested clip range is a request fault, reported like a file clip's.
        guard range.from >= project.range.from, range.from < range.to, range.to <= project.range.to else {
            throw CutError(code: "invalid_range",
                           message: "Project clip \(segment) must have increasing bounds within the group range \(project.range.from) to \(project.range.to) seconds.",
                           segment: segment)
        }
        let clip: MulticamPlan
        do {
            clip = try project.plan(ranges: [range])
        } catch let error as CutError {
            throw CutError(code: error.code, message: "Project clip \(segment) (\(url.path)): \(error.message)",
                           segment: segment, boundary: error.boundary, nearest: error.nearest, track: error.track)
        }
        var names = projectSourceIDs[url] ?? [:]
        for source in project.angles + project.audioSources where names[source.id] == nil {
            names[source.id] = register(project.sourceURL(for: source, relativeTo: url), as: source.id, segment: segment)
        }
        projectSourceIDs[url] = names
        if case .follow = project.audio { followsCamera = true }
        try append(clip, names: names, segment: segment)
        clips.append(.project(project, url, range, segment))
    }

    mutating func appendFile(_ media: MediaInfo, range: MulticamRange, segment: Int,
                             tracks: ExportTracks) throws {
        guard range.from >= .zero, range.to > range.from, range.to <= media.duration else {
            throw CutError(code: "invalid_range",
                           message: "Clip \(segment) must have increasing bounds within 0 to \(media.duration) seconds.",
                           segment: segment)
        }
        let id: String
        if let saved = fileIDs[media.url] {
            id = saved
        } else {
            id = register(media.url, as: "file-\(segment)", segment: segment)
            fileIDs[media.url] = id
        }
        let clipLength = try range.to.subtracting(range.from)
        let output = MulticamRange(from: .zero, to: clipLength)
        // A direct file clip uses the same source clock as ordinary export.
        // Translate into the presentation clock used by the multicam writer.
        let offset = media.multicamSourceOffset
        let input = try MulticamRange(from: range.from.adding(offset), to: range.to.adding(offset))
        let microphone = media.streams.first(where: { $0.kind == "audio" }).map {
            MulticamAudioSelection(source: id, stream: $0.index)
        }
        if tracks != .audio && !media.hasVideo {
            throw CutError(code: "no_video", message: "Clip \(segment) lacks video. Select --tracks audio for an audio-only assembly.", segment: segment)
        }
        if tracks == .audio && microphone == nil {
            throw CutError(code: "no_audio", message: "Clip \(segment) has no audio stream.", segment: segment)
        }
        let picture = media.hasVideo ? [MulticamSpan(source: id, stream: nil, input: input, output: output)] : []
        let audio = microphone.map { [MulticamSpan(source: id, stream: $0.stream, input: input, output: output)] } ?? []
        let interval = MulticamInterval(group: range, output: output, angle: id, audio: microphone, assemblyIndex: segment - 1)
        try append(MulticamPlan(intervals: [interval], picture: picture, audio: audio, duration: clipLength),
                   names: [id: id], segment: segment)
        clips.append(.file(media, range, segment, tracks))
    }

    private mutating func register(_ url: URL, as id: String, segment: Int) -> String {
        var name = id
        if sources[name] != nil {
            name = "\(segment):\(id)"
            while sources[name] != nil { name = "\(segment):\(name)" }
        }
        sources[name] = url
        return name
    }

    private mutating func append(_ clip: MulticamPlan, names: [String: String], segment: Int) throws {
        let start = duration
        func shifted(_ range: MulticamRange) throws -> MulticamRange {
            try MulticamRange(from: range.from.adding(start), to: range.to.adding(start))
        }
        func renamed(_ id: String) throws -> String {
            guard let name = names[id] else {
                throw CutError(code: "unknown_source", message: "Clip \(segment) has no source with ID '\(id)'.", segment: segment)
            }
            return name
        }
        func shiftedSpan(_ span: MulticamSpan) throws -> MulticamSpan {
            try MulticamSpan(source: renamed(span.source), stream: span.stream, input: span.input,
                             output: shifted(span.output))
        }
        let addedIntervals = try clip.intervals.map { interval in
            let microphone = try interval.audio.map {
                try MulticamAudioSelection(source: renamed($0.source), stream: $0.stream)
            }
            return try MulticamInterval(group: interval.group, output: shifted(interval.output),
                                        angle: renamed(interval.angle), audio: microphone, assemblyIndex: segment - 1)
        }
        let addedPicture = try clip.picture.map(shiftedSpan)
        let addedAudio = try clip.audio.map(shiftedSpan)
        duration = try duration.adding(clip.duration)
        intervals += addedIntervals
        for span in addedPicture { span.appendCoalescing(to: &picture) }
        for span in addedAudio { span.appendCoalescing(to: &audio) }
    }
}
