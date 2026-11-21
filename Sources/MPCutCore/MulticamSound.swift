import Foundation

extension MulticamEngine {
    func resolveSound(_ mapping: MulticamPlan, sources: [String: MediaInfo],
                      container: String) throws -> ResolvedEdit {
        let engine = CutEngine(cancelled: cancelled, tracks: .audio)
        var identities: [URL: SourceIdentity] = [:]
        var reference: MediaInfo?
        var segments: [ResolvedSegment] = []
        var silentAAC: [Int: Int] = [:]
        var audibleAAC = Set<Int>()
        let spans = mapping.audio
        for (index, span) in spans.enumerated() {
            try engine.checkCancellation()
            let segment = index + 1
            let first = index == 0
            let last = segment == spans.count
            do {
                guard let stream = span.stream, let source = sources[span.source] else {
                    throw CutError(code: "missing_audio", message: "No source or absolute stream index was supplied.")
                }
                let selector = CutEngine(cancelled: cancelled, tracks: .audio, audioStream: stream)
                let selected = try selector.selectedMedia(source)
                guard let track = selected.audio.first, track.stream.sampleRate > 0,
                      track.stream.isPCM || !track.packets.isEmpty || !track.presentationEdits.isEmpty else {
                    throw CutError(code: "audio_unavailable", message: "The selected soundtrack has no usable presentation clock.")
                }
                // An indexed issue names one track. Only another track's issue is irrelevant here.
                if let issue = selected.copyIssue, !issue.hasPrefix("The video "), !issue.hasPrefix("A ProRes "),
                   !issue.hasPrefix("RAW video"), issue != "Multiple video tracks are unsupported.",
                   !(issue.hasPrefix("Audio track ") || issue.hasPrefix("AAC track "))
                    || issue.hasPrefix("Audio track \(stream) ") || issue.hasPrefix("AAC track \(stream) ") {
                    throw CutError(code: "unsupported_tracks", message: issue)
                }
                if let issue = selector.muxIssue(selected, container: container) {
                    throw CutError(code: "unsupported_container", message: issue)
                }
                if container == "flac", !(first && last && span.input.from == .zero && span.input.to == track.end) {
                    throw CutError(code: "unsupported_container",
                                   message: "FLAC frames carry their original sample numbers. Choose MKA for an edited soundtrack.")
                }
                if let reference { try engine.checkCompatibility(selected, with: reference) }
                else { reference = selected }

                let from = span.input.from
                let to = span.input.to
                let movableLeadingSilence = first && container == "mov" && track.stream.isPCM
                    && track.stream.hasDeclaredStart && track.stream.start == track.start && from >= .zero
                guard (movableLeadingSilence || from >= max(.zero, track.start)), from < track.end, to <= track.end else {
                    let uncoveredFrom = from < max(.zero, track.start) ? from : max(from, track.end)
                    let uncoveredTo = from < max(.zero, track.start) ? min(to, max(.zero, track.start)) : to
                    let group = try groupRange(span, in: mapping)
                    let uncoveredGroup = try "\(group.from.adding(uncoveredFrom.subtracting(from)))–\(group.from.adding(uncoveredTo.subtracting(from)))"
                    let uncoveredOutput = try "\(span.output.from.adding(uncoveredFrom.subtracting(from)))–\(span.output.from.adding(uncoveredTo.subtracting(from)))"
                    throw CutError(code: "uncovered_audio", message: "The selected soundtrack does not cover group \(uncoveredGroup), output \(uncoveredOutput).",
                                   boundary: from < max(.zero, track.start) ? "from" : "to")
                }
                // Audio extraction may extend past the final picture. Preserve the
                // source clock and use the selected track's own positive end.
                let media = MediaInfo(url: selected.url, format: selected.format, duration: track.end,
                                      origin: selected.origin, streams: selected.streams, frames: [],
                                      audio: [track], copyIssue: nil, sourceStartSafe: selected.sourceStartSafe,
                                      identity: selected.identity, videoIndex: -1)

                try checkSoundBoundary(input: from, output: span.output.from, media: media, start: true,
                                       first: first, last: last, container: container, segment: segment)
                try checkSoundBoundary(input: to, output: span.output.to, media: media, start: false,
                                       first: first, last: last, container: container, segment: segment)
                let whole = first && last && from == .zero && to == track.end && !track.stream.isPCM
                    && !engine.supportsAACEdits(track.stream, container: container)
                try checkProgramPackets(track, media: media, from: from, to: to, single: first && last, container: container)
                let windows = try engine.trackWindows(media, from: from, to: to, outputStart: span.output.from,
                                                      outputEnd: span.output.to, first: first, last: last,
                                                      whole: whole, container: container, segment: segment,
                                                      silentAACSegments: &silentAAC, audibleAACTracks: &audibleAAC)
                guard let window = windows.first,
                      (movableLeadingSilence || window.outputStart == span.output.from),
                      window.outputEnd == span.output.to else {
                    throw CutError(code: "unsafe_boundary", message: "The selected codec cannot preserve the exact soundtrack interval.")
                }
                segments.append(ResolvedSegment(file: selected.url, from: from, to: to, outputStart: span.output.from,
                                                tracks: windows, sourceOrigin: selected.origin, reachesEnd: container == "flac" && whole))
                identities[selected.url] = selected.identity
            } catch let issue as CutError {
                throw try contextual(issue, span: span, mapping: mapping, index: segment, nearest: [])
            }
        }
        // Track index is local to a source. Check for at least one audible
        // presentation across the lane regardless of the source's stream index.
        if audibleAAC.isEmpty, let first = silentAAC.values.min() {
            let issue = CutError(code: "unsafe_boundary", message: "The entire selected AAC program is an empty presentation edit.")
            throw try contextual(issue, span: spans[first - 1], mapping: mapping, index: first)
        }
        for (file, identity) in identities { try engine.verifyIdentity(file, identity: identity) }
        return ResolvedEdit(segments: segments, duration: mapping.duration, container: container,
                            identities: identities, tracks: .audio,
                            audioStream: container == "flac" ? spans.first?.stream : nil)
    }

    /// A program soundtrack is written within its planned ranges. Unlike a linked
    /// copy, the writer keeps no packet before the first range or after the last,
    /// so packet-copied codecs cannot rely on priming or padding at those edges.
    private func checkProgramPackets(_ sound: AudioIndex, media: MediaInfo, from: RationalTime, to: RationalTime,
                                     single: Bool, container: String) throws {
        let engine = CutEngine(cancelled: cancelled, tracks: .audio)
        let stream = sound.stream
        if stream.isPCM || engine.supportsAACEdits(stream, container: container) { return }
        if single, supportsOpusTrim(sound, media: media, container: container)
            || engine.supportsMP3Crop(stream, media: media, container: container) { return }
        let packets = sound.packets
        let lower = packets.lowerBound { $0.time >= from }
        let upper = packets.lowerBound { $0.time >= to }
        func unsupported(_ boundary: String) -> CutError {
            let advice = stream.codec == "aac" ? "Choose MOV or MP4, or convert the audio." : "Convert the audio."
            return CutError(code: "unsupported_container",
                            message: "\(container.uppercased()) cannot keep this \(stream.codec.uppercased()) soundtrack’s encoder priming or padding in a multicam program. \(advice)",
                            boundary: boundary, track: stream.index)
        }
        if lower > 0, from <= max(.zero, sound.start), packets[..<lower].contains(where: { $0.skipSamples > 0 }) {
            throw unsupported("from")
        }
        for (index, packet) in packets[lower..<upper].enumerated() {
            if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
            if packet.skipSamples > 0 { throw unsupported("from") }
            if packet.discardSamples > 0 { throw unsupported("to") }
        }
    }

    func checkSoundBoundary(input time: RationalTime, output: RationalTime, media: MediaInfo,
                            start: Bool, first: Bool, last: Bool, container: String, segment: Int) throws {
        let engine = CutEngine(cancelled: cancelled, tracks: .audio)
        let sound = media.audio[0]
        let field = start ? "from" : "to"
        if sound.stream.isPCM || engine.supportsAACEdits(sound.stream, container: container) {
            let rate = Int64(sound.stream.sampleRate)
            let source = try media.origin.adding(time)
            guard rate.isMultiple(of: source.denominator), rate.isMultiple(of: output.denominator) else {
                throw CutError(code: "unsafe_boundary", message: "The selected soundtrack cut falls between audio samples.",
                               segment: segment, boundary: field)
            }
        } else {
            var common: [URL: [RationalTime]] = [:]
            _ = try engine.audioBoundary(time, media: media, start: start, first: first, last: last,
                                         container: container, snap: .exact, segment: segment, common: &common)
        }
    }
}
