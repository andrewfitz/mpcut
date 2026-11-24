import Foundation

public enum StillSoundtrack {
    /// Build a clip on the selected track's indexed presentation clock.
    public static func reference(media: MediaInfo, stream: Int? = nil,
                                 from: RationalTime? = nil, to: RationalTime? = nil,
                                 id: String = ProjectIdentifier.make()) throws -> CutSequenceClip {
        let streams = media.streams.filter { $0.kind == "audio" }
        guard let ordinal = streams.firstIndex(where: { stream == nil || $0.index == stream }),
              let track = media.audio.first(where: { $0.stream.index == streams[ordinal].index }) else {
            throw CutError(code: "missing_audio", message: "Choose an audio track for the still soundtrack.", track: stream)
        }
        let start = from ?? max(.zero, track.start)
        let end = to ?? track.end
        guard track.stream.sampleRate > 0, start >= max(.zero, track.start), end <= track.end, start < end else {
            throw stillError("The soundtrack range must lie within the selected track's audible extent.")
        }
        let rate = RationalTime(numerator: Int64(track.stream.sampleRate))
        for edge in [start, end] {
            guard try edge.subtracting(track.start).multiplied(by: rate).denominator == 1 else {
                throw stillError("The soundtrack range must begin and end on audio sample boundaries.")
            }
        }
        let clip = CutSequenceClip(id: id, file: media.url.path, from: start, to: end, audioTrack: ordinal)
        try clip.validateFields()
        return clip
    }
}

public struct StillSoundtrackMapping: Equatable, Sendable {
    public let clip: CutSequenceClip
    public let source: MulticamRange
    /// Intersection in absolute program time, before rebasing an export selection to zero.
    public let output: MulticamRange
}

extension CutProject {
    public var stillSoundtrack: CutSequenceClip? {
        if case .stillSequence(let project) = self { return project.stillSoundtrack }
        return nil
    }

    public func attachingStillSoundtrack(_ clip: CutSequenceClip?) throws -> CutProject {
        try editingStills(sequence: { $0.stillSoundtrack = clip }, multicam: { _ in
            throw stillError("A still soundtrack requires a still-only sequence.")
        })
    }

    public func fittingStillToSoundtrack() throws -> CutProject {
        try editingStills(sequence: { sequence in
            guard let soundtrack = sequence.stillSoundtrack, sequence.items.count == 1,
                  var insert = sequence.items.first?.still, let format = sequence.stillFormat,
                  sequence.stillAssets.contains(where: { $0.id == insert.assetID && !$0.isGap }) else {
                throw stillError("Fit Image to Soundtrack requires one image and an attached soundtrack.")
            }
            insert.duration = try soundtrack.to.subtracting(soundtrack.from)
            insert.usesExactDuration = (try? format.frameCount(for: insert.duration)) == nil
            sequence.items[0] = .still(insert)
        }, multicam: { _ in
            throw stillError("Fit Image to Soundtrack requires a still-only sequence.")
        })
    }

    public func stillSoundtrackMapping(in output: MulticamRange) throws -> StillSoundtrackMapping? {
        guard let clip = stillSoundtrack else { return nil }
        let overlap = MulticamRange(from: max(.zero, output.from),
                                    to: min(output.to, try clip.to.subtracting(clip.from)))
        guard overlap.from < overlap.to else { return nil }
        return try .init(clip: clip, source: .init(from: clip.from.adding(overlap.from), to: clip.from.adding(overlap.to)),
                         output: overlap)
    }
}

extension ProjectMediaSnapshot {
    package func expectedStillSoundtrack(_ clip: CutSequenceClip, relativeTo document: URL) throws -> SourceIdentity? {
        let file = CutProject.mediaURL(clip.file, relativeTo: document)
        guard let entry = entries.first(where: { CutProject.mediaURL($0.path, relativeTo: document) == file }),
              entry.size != nil || entry.modifiedSeconds != nil || entry.modifiedNanoseconds != nil else {
            return nil
        }
        let current = try SourceIdentity(file)
        guard entry.size.map({ $0 == current.size }) ?? true,
              entry.modifiedSeconds.map({ $0 == current.modifiedSeconds }) ?? true,
              entry.modifiedNanoseconds.map({ $0 == current.modifiedNanoseconds }) ?? true else {
            throw CutError(code: "source_changed", message: "The attached soundtrack changed. Review it in Project Media before exporting.")
        }
        return current
    }
}
