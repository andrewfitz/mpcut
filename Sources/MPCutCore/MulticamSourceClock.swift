import Foundation

extension MediaInfo {
    /// Offset from the ordinary source editing clock to a movie's presentation clock.
    public var multicamSourceOffset: RationalTime {
        origin > .zero && format.split(separator: ",").contains("mov") ? origin : .zero
    }
}

extension CutEngine {
    /// Normal editing opens a movie at the primary track's start. Multicam
    /// keeps the original movie clock so a leading empty edit stays visible.
    public func inspectMulticamSource(_ file: URL) throws -> MediaInfo {
        try multicamClock(inspect(file, keyframes: true))
    }

    package func multicamClock(_ media: MediaInfo) throws -> MediaInfo {
        let offset = media.multicamSourceOffset
        let provisional = !media.hasFullEditIndex
        guard offset > .zero || provisional else { return media }

        let tracks: [AudioIndex]
        if provisional {
            tracks = try media.streams.filter { $0.kind == "audio" }.map { stream in
                let end = stream.duration > .zero ? try stream.start.adding(stream.duration) : media.duration
                return AudioIndex(stream: stream, packets: [], start: stream.start, end: end,
                                  hasPriming: false, pcmContinuity: false, presentationEdits: [])
            }
        } else {
            tracks = media.audio
        }
        let streams = try media.streams.map { stream in
            var shifted = stream
            shifted.start = try stream.start.adding(offset)
            return shifted
        }
        let frames = try media.frames.enumerated().map { index, frame in
            if index.isMultiple(of: 1_024) { try checkCancellation() }
            return try FrameInfo(dts: frame.dts.map { try $0.adding(offset) }, time: frame.time.adding(offset),
                                 duration: frame.duration, keyframe: frame.keyframe, canStart: frame.canStart,
                                 canEnd: frame.canEnd, byteCount: frame.byteCount)
        }
        let audio = try tracks.map { audio in
            let packets = try audio.packets.enumerated().map { index, packet in
                if index.isMultiple(of: 1_024) { try checkCancellation() }
                return try AudioPacket(time: packet.time.adding(offset), dts: packet.dts.map { try $0.adding(offset) },
                                       duration: packet.duration, skipSamples: packet.skipSamples,
                                       discardSamples: packet.discardSamples, decodedSamples: packet.decodedSamples)
            }
            guard let stream = streams.first(where: { $0.index == audio.stream.index }) else {
                throw CutError(code: "invalid_input", message: "Audio stream \(audio.stream.index) is missing from the source.")
            }
            return try AudioIndex(stream: stream, packets: packets,
                                  start: audio.start.adding(offset), end: audio.end.adding(offset),
                                  hasPriming: audio.hasPriming, pcmContinuity: audio.pcmContinuity,
                                  presentationEdits: audio.presentationEdits, opusWindow: audio.opusWindow)
        }
        let videoIndex = media.videoStream.flatMap { video in streams.firstIndex(where: { $0.index == video.index }) }
        return try MediaInfo(url: media.url, format: media.format, duration: media.duration.adding(offset),
                             origin: offset == .zero ? media.origin : .zero, streams: streams, frames: frames, audio: audio, copyIssue: media.copyIssue,
                             sourceStartSafe: media.sourceStartSafe, identity: media.identity,
                             videoIndex: videoIndex ?? -1, timelineIssue: media.timelineIssue, metadataOnly: provisional,
                             hasProvisionalClock: media.hasProvisionalClock, multicamClockOffset: offset,
                             audioIssues: media.audioIssues, refreshEvidence: media.refreshEvidence)
    }
}
