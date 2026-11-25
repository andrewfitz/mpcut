import Foundation

extension AudioIndex {
    /// The first and last audible edit on the source presentation clock. Internal empty
    /// edits remain inside this span when extracting a soundtrack for a round trip.
    func audibleBounds(origin: RationalTime) throws -> ClosedRange<RationalTime> {
        guard let first = presentationEdits.first(where: \.isAudible),
              let last = presentationEdits.last(where: \.isAudible) else { return start...end }
        let rate = Int64(stream.sampleRate)
        let lower = try RationalTime(numerator: first.samples.lowerBound, denominator: rate).subtracting(origin)
        let upper = try RationalTime(numerator: last.samples.upperBound, denominator: rate).subtracting(origin)
        return lower...upper
    }
}

func commonAudioSampleRate(_ rates: [Int]) -> Int {
    rates.reduce(0) { previous, next in
        var a = previous, b = next
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

/// Matroska's PCM track metadata records a channel count without speaker positions.
func matroskaPCMLayoutIssue(_ layout: String, channels: Int, container: String) -> String? {
    guard ["mkv", "mka", "matroska"].contains(container),
          StreamInfo.canonicalChannelLayout(layout, channels: channels) !=
            StreamInfo.canonicalChannelLayout("\(channels) channels", channels: channels) else { return nil }
    return "\(container.uppercased()) cannot preserve the \(layout) PCM channel layout. Choose MOV or downmix."
}

extension CutEngine {
    func supportsAACEdits(_ track: StreamInfo, container: String) -> Bool {
        track.codec == "aac" && ["mov", "mp4", "m4v", "m4a"].contains(container)
    }

    func supportsMP3Crop(_ stream: StreamInfo, media: MediaInfo, container: String) -> Bool {
        !media.hasVideo && media.format == "mp3" && container == "mp3" && stream.codec == "mp3"
    }

    /// Present the same indexed clock to the planner while removing streams the caller excluded.
    /// Original stream numbers are retained so the writer can map input packets directly.
    func selectedMedia(_ media: MediaInfo) throws -> MediaInfo {
        if let audioStream, tracks != .audio || audioStream < 0 || audioStream > Int(Int32.max) {
            throw CutError(code: "invalid_arguments", message: "Choose an audio output and a nonnegative audio stream index.")
        }
        if let audioTrackOrdinal, tracks != .audio || audioStream != nil || !(0..<Int(Int32.max)).contains(audioTrackOrdinal) {
            throw CutError(code: "invalid_arguments", message: "Choose an audio output and one nonnegative audio track position.")
        }
        let selection: ExportTracks = !media.hasVideo && tracks == .all ? .audio : tracks
        if selection == .all { return media }
        let kept: [StreamInfo]
        if selection == .video {
            guard let video = media.videoStream else {
                throw CutError(code: "no_video", message: "The source has no video track.")
            }
            kept = [video]
        } else if let audioTrackOrdinal {
            let audioTracks = media.streams.filter { $0.kind == "audio" }
            guard audioTracks.indices.contains(audioTrackOrdinal) else {
                throw CutError(code: "no_audio", message: "The source does not have audio track \(audioTrackOrdinal + 1).")
            }
            kept = [audioTracks[audioTrackOrdinal]]
        } else {
            kept = media.streams.filter { $0.kind == "audio" && (audioStream == nil || $0.index == audioStream) }
            guard !kept.isEmpty else {
                throw CutError(code: "no_audio", message: "The source has no matching audio track.", track: audioStream)
            }
        }
        let indexes = Set(kept.map(\.index))
        // Explicit selection does not carry subtitles, attached pictures or auxiliary data.
        var issue = media.copyIssue == MediaInfo.auxiliaryTrackIssue
            ? nil : media.copyIssue
        if let reported = issue, media.audioIssues.values.contains(reported) {
            issue = nil
        }
        issue = issue ?? kept.lazy.compactMap { media.audioIssues[$0.index] }.first
        return MediaInfo(url: media.url, format: media.format, duration: media.duration, origin: media.origin,
                         streams: kept, frames: selection == .video ? media.frames : [],
                         audio: media.audio.filter { indexes.contains($0.stream.index) },
                         copyIssue: issue, sourceStartSafe: media.sourceStartSafe, identity: media.identity,
                         videoIndex: selection == .video ? 0 : -1, timelineIssue: media.timelineIssue,
                         reportedContainers: !media.hasVideo && audioStream == nil && audioTrackOrdinal == nil ? media.reportedContainers : nil,
                         metadataOnly: !media.hasFullEditIndex,
                         audioIssues: media.audioIssues.filter { indexes.contains($0.key) })
    }

    public func suggestedContainers(for media: MediaInfo, clips: [ClipRequest]) -> [String] {
        editContainers(suggestedContainers(for: media), for: media, clips: clips)
    }

    func editContainers(_ supported: [String], for media: MediaInfo, clips: [ClipRequest]) -> [String] {
        var candidates = supported
        if !isCompleteSource(clips, media: media) {
            candidates.removeAll { $0 == "flac" }
            if let selected = try? selectedMedia(media), !selected.hasVideo,
               selected.streams.contains(where: \.isPCM) {
                candidates.removeAll { $0 == "mka" || $0 == "mkv" }
            }
            if media.format.split(separator: ",").contains("ogg"),
               media.streams.contains(where: { $0.codec == "opus" }), candidates.contains("mka") {
                candidates.removeAll { $0 == "mka" }
                candidates.insert("mka", at: 0)
            }
        }
        return candidates
    }

    /// Only the original order, from first sample to last, preserves raw FLAC frame numbers.
    private func isCompleteSource(_ clips: [ClipRequest], media: MediaInfo) -> Bool {
        var cursor = RationalTime.zero
        for clip in clips {
            let end = clip.to ?? media.duration
            guard clip.file.standardizedFileURL == media.url.standardizedFileURL,
                  clip.from ?? .zero == cursor, end > cursor else { return false }
            cursor = end
        }
        return cursor == media.duration
    }

    func preferredAudioContainers(_ media: MediaInfo) -> [String] {
        let streams = media.streams.filter { $0.kind == "audio" }
        guard let stream = streams.first else { return [] }
        if streams.count > 1 { return ["m4a", "mov", "mka"] }
        if stream.isPCM {
            let first = stream.codec.hasSuffix("be") ? "aiff" : "wav"
            return [first, "caf", "mov", "mka"]
        }
        switch stream.codec {
        case "aac", "alac": return ["m4a", "mov", "mka"]
        case "mp3": return ["mp3", "mka"]
        case "flac": return ["flac", "mka"]
        case "opus":
            if media.format.split(separator: ",").contains("matroska") { return ["webm", "mka", "opus"] }
            return ["opus", "ogg", "mka"]
        case "vorbis": return ["ogg", "mka"]
        case "ac3", "eac3": return [stream.codec, "mka"]
        default: return ["mka", "mov"]
        }
    }

    /// Copies of a sound codec that the muxer of the bundled helper accepts at planning but refuses when it writes: MOV takes
    /// FLAC, Opus and TrueHD only in MP4 mode ("only supported in MP4"), and MP4 cannot finish a file of copied PCM whose
    /// channel layout is unstated. A copy is refused here, at planning, with the containers that carry it, so a dry run and
    /// the export agree.
    func audioCodecContainerIssue(_ media: MediaInfo, container: String) -> String? {
        // Picture alone copies no sound. A selected stream is the only sound copied.
        guard tracks != .video || !media.hasVideo else { return nil }
        for sound in media.audio where audioStream == nil || sound.stream.index == audioStream {
            let codec = sound.stream.codec
            let name = ExportRules.audioCodecName(codec)
            if container == "mov" && ["flac", "opus", "truehd"].contains(codec) {
                return "MOV cannot carry copied \(name) audio. Choose MP4 or MKV to copy it, or convert the audio."
            }
            // The MP4 PCM box names its speakers, so the muxer cannot finish a file whose PCM states no channel layout.
            let layout = sound.stream.channelLayout
            if ["mp4", "m4v"].contains(container), codec.hasPrefix("pcm_"), sound.stream.channels > 1,
               layout.isEmpty || layout == "unknown" || layout.hasSuffix(" channels") {
                return "MP4 cannot carry copied PCM audio without a stated channel layout. Choose MOV or MKV, or WAV or CAF for sound only, to copy it."
            }
        }
        return nil
    }

    func audioContainerIssue(_ media: MediaInfo, container: String) -> String? {
        if media.streams.count > 1 && ["wav", "wave", "aif", "aiff", "mp3", "flac", "aac", "caf", "ac3", "eac3"].contains(container) {
            return "Select one audio stream for \(container.uppercased()), or choose a multitrack audio container."
        }
        for stream in media.streams where stream.isPCM {
            if let issue = matroskaPCMLayoutIssue(stream.channelLayout, channels: stream.channels, container: container) {
                return issue
            }
        }
        if container != "mp3", media.audio.contains(where: { $0.stream.codec == "mp3" && $0.hasPriming }) {
            return "Use MP3 to preserve this soundtrack’s encoder delay and trailing padding."
        }
        // ADTS has no timeline edits or sample trimming metadata. Writing AAC with priming there
        // would expose priming samples and break a subsequent replacement into the source movie.
        if container == "aac" && media.audio.contains(where: { sound in
            sound.hasPriming || !sound.presentationEdits.isEmpty || sound.packets.last.map { packet in
                packet.decodedSamples > 0 && (try? packet.duration.roundedToSamples(sound.stream.sampleRate)) != Int64(packet.decodedSamples)
            } == true
        }) {
            return "Use M4A to preserve AAC priming and the final audible sample."
        }
        if media.audio.contains(where: { !$0.presentationEdits.isEmpty && !["m4a", "mp4", "mov", "m4v"].contains(container) }) {
            return "Use M4A or MOV to preserve the audio track’s presentation edits."
        }
        return nil
    }

    func audioPacketBoundaries(_ media: MediaInfo, starting: Bool) -> [RationalTime] {
        let tracks = media.audio.filter { !$0.stream.isPCM && $0.stream.codec != "aac" }
        guard let first = tracks.first else { return [.zero, media.duration] }
        if tracks.count == 1 {
            var edges: [RationalTime] = []
            edges.reserveCapacity(first.packets.count + 1)
            if starting { edges.append(.zero) }
            for packet in first.packets where packet.time >= .zero && packet.time <= media.duration && packet.time != edges.last {
                edges.append(packet.time)
            }
            if !starting && edges.last != media.duration && preservesAudioEnd(media) { edges.append(media.duration) }
            return edges
        }
        var common = Set(first.packets.lazy.map(\.time))
        for track in tracks.dropFirst() { common.formIntersection(track.packets.lazy.map(\.time)) }
        if starting { common.insert(.zero) }
        else if preservesAudioEnd(media) { common.insert(media.duration) }
        return common.filter { $0 >= .zero && $0 <= media.duration }.sorted()
    }

    func resolveAudioRanges(_ requests: [ClipRequest], sequence: [MediaInfo], uniqueMedia: [MediaInfo],
                            container: String, snap: SnapMode) throws -> ResolvedEdit {
        if container == "flac", !isCompleteSource(requests, media: sequence[0]) {
            throw CutError(code: "unsupported_container",
                           message: "FLAC frames carry their original sample numbers. Choose .mka to copy edited FLAC packets with the new timeline.")
        }
        // Adjacent source pieces share decoder state even if they were split on the timeline.
        var groups: [(first: Int, last: Int, media: MediaInfo, from: RationalTime, to: RationalTime)] = []
        for (offset, pair) in zip(requests, sequence).enumerated() {
            let (request, media) = pair
            let from = request.from ?? .zero, to = request.to ?? media.duration
            guard from >= .zero, from < to, to <= media.duration else {
                throw CutError(code: "invalid_range", message: "Choose a nonempty range within the source.", segment: offset + 1)
            }
            if let previous = groups.last, previous.media.url == media.url, previous.to == from {
                groups[groups.count - 1].to = to
                groups[groups.count - 1].last = offset + 1
            } else {
                groups.append((offset + 1, offset + 1, media, from, to))
            }
        }
        var segments: [ResolvedSegment] = []
        var duration = RationalTime.zero
        var commonPacketEdges: [URL: [RationalTime]] = [:]
        var silentAAC: [Int: Int] = [:]
        var audibleAAC = Set<Int>()
        for (index, group) in groups.enumerated() {
            try checkCancellation()
            let media = group.media
            let single = groups.count == 1
            let whole = single && group.from == .zero && group.to == media.duration
            guard !media.audio.isEmpty else { throw CutError(code: "no_audio", message: "There is no indexed audio track.") }
            if whole {
                if container == "mp3", let audio = media.audio.first, let head = audio.packets.first {
                    // Xing/LAME stores two 12-bit values. FFmpeg adds the decoder's 529 samples
                    // to the leading skip and subtracts them from end padding when reading.
                    var trailingPadding = 0
                    for packet in audio.packets.reversed() {
                        guard packet.discardSamples > 0 else { break }
                        trailingPadding += packet.discardSamples
                        if trailingPadding > 3566 { break }
                    }
                    let gapless = (529...4624).contains(head.skipSamples) && trailingPadding <= 3566
                    if !gapless && (head.skipSamples != 0 || trailingPadding != 0) {
                        throw CutError(code: "unsupported_container",
                                       message: "MP3 cannot represent the source track’s leading delay and trailing padding.",
                                       segment: group.first, track: audio.stream.index)
                    }
                }
                // The source clock belongs to the video when extracting from a movie. A sound
                // track can start later, end earlier, or extend beyond the final picture.
                let sourceTracks = try trackWindows(media, from: .zero, to: media.duration,
                                                    outputStart: .zero, outputEnd: media.duration,
                                                    first: true, last: true, whole: true, container: container,
                                                    segment: group.first, silentAACSegments: &silentAAC, audibleAACTracks: &audibleAAC)
                let first = sourceTracks.map(\.sourceStart).min()!
                let last = sourceTracks.map(\.sourceEnd).max()!
                duration = try last.subtracting(first)
                let normalized = try sourceTracks.map { track in
                    ResolvedTrack(index: track.index, kind: track.kind, sourceStart: track.sourceStart, sourceEnd: track.sourceEnd,
                                  outputStart: try track.sourceStart.subtracting(first), outputEnd: try track.sourceEnd.subtracting(first),
                                  opusPreSkip: track.opusPreSkip)
                }
                segments.append(ResolvedSegment(file: media.url, from: first, to: last, outputStart: .zero, tracks: normalized,
                                                sourceOrigin: media.origin, wholeAudioOrigin: try media.origin.adding(first),
                                                reachesEnd: true, sourceClipIndex: group.first - 1,
                                                sourceClipSeams: requests[(group.first - 1)..<(group.last - 1)].compactMap(\.to)))
                continue
            }
            let spans = try media.audio.map { try $0.audibleBounds(origin: media.origin) }
            let earliest = max(.zero, spans.map(\.lowerBound).min()!)
            let latest = min(media.duration, spans.map(\.upperBound).max()!)
            let requestedFrom = max(group.from, earliest)
            let requestedTo = min(group.to, latest)
            guard requestedFrom < requestedTo else {
                throw CutError(code: "invalid_range", message: "No selected audio overlaps this range.", segment: group.first)
            }
            let from = try audioBoundary(requestedFrom, media: media, start: true, first: index == 0, last: index == groups.count - 1,
                                         container: container, snap: snap, segment: group.first, common: &commonPacketEdges)
            let to = try audioBoundary(requestedTo, media: media, start: false, first: index == 0, last: index == groups.count - 1,
                                       container: container, snap: snap, segment: group.last, common: &commonPacketEdges)
            guard from < to else {
                throw CutError(code: "invalid_range", message: "The selection contains no complete audio sample or packet.", segment: group.first)
            }
            let end = try duration.adding(to.subtracting(from))
            let tracks = try trackWindows(media, from: from, to: to, outputStart: duration, outputEnd: end,
                                          first: index == 0, last: index == groups.count - 1, whole: false,
                                          container: container, segment: group.first,
                                          silentAACSegments: &silentAAC, audibleAACTracks: &audibleAAC)
            segments.append(ResolvedSegment(file: media.url, from: from, to: to, outputStart: duration,
                                            tracks: tracks, sourceOrigin: media.origin,
                                            reachesEnd: to == media.duration && preservesAudioEnd(media),
                                            sourceClipIndex: group.first - 1, sourceClipSeams: requests[(group.first - 1)..<(group.last - 1)].compactMap(\.to)))
            duration = end
        }
        if let position = silentAAC.keys.sorted().first(where: { !audibleAAC.contains($0) }),
           let segment = silentAAC[position] {
            let track = sequence[segment - 1].audio[position].stream.index
            throw CutError(code: "unsafe_boundary", message: "AAC track \(track) contains only empty presentation edits in this selection.",
                           segment: segment, track: track).because(.cutAACCoverage)
        }
        for media in uniqueMedia { try verifyIdentity(media.url, identity: media.identity) }
        var edit = ResolvedEdit(segments: segments, duration: duration, container: container,
                                identities: Dictionary(uniqueKeysWithValues: uniqueMedia.map { ($0.url, $0.identity) }),
                                tracks: .audio, audioStream: audioStream, usesPerSourceAudioStream: audioTrackOrdinal != nil)
        edit.noteAudioJoins(zip(segments, groups).map { AudioJoinNotes.Range(segment: $0, media: $1.media) })
        return edit
    }

    func preservesAudioEnd(_ media: MediaInfo) -> Bool {
        media.audio.allSatisfy { $0.end <= media.duration }
    }

    func audioBoundary(_ target: RationalTime, media: MediaInfo, start: Bool, first: Bool, last: Bool,
                               container: String, snap: SnapMode, segment: Int,
                               common: inout [URL: [RationalTime]]) throws -> RationalTime {
        let field = start ? "from" : "to"
        let preservesEnd = last && preservesAudioEnd(media)
        var packets: [AudioIndex] = []
        var sampleRates: [Int] = []
        for sound in media.audio {
            let stream = sound.stream
            if stream.isPCM || stream.codec == "aac" && ["m4a", "mov", "mp4", "m4v"].contains(container)
                || first && last && (supportsOpusTrim(sound, media: media, container: container)
                                     || supportsMP3Crop(stream, media: media, container: container)) {
                sampleRates.append(stream.sampleRate)
            } else {
                let originalEdge = start ? first && target == .zero : preservesEnd && target == media.duration
                // Inter-frame audio requires earlier decoder history. A packet boundary alone
                // cannot make a discontinuous MP3, Vorbis or Opus splice independently audible.
                if ["opus", "vorbis", "mp3", "aac"].contains(stream.codec),
                   (start && !originalEdge || !start && !last || !sound.presentationEdits.isEmpty) {
                    // Smart Trim is a movie export, so a sound-only AAC join into Matroska stays refused here.
                    let message = stream.codec == "aac" && ["mkv", "mka"].contains(container)
                        ? "AAC track \(stream.index) requires its original decoder history at this join. Smart Trim encodes AAC frames at joins only in a movie export; converting the audio makes the join exact."
                        : "\(stream.codec.uppercased()) track \(stream.index) requires its original decoder history at this join."
                    throw CutError(code: "unsafe_boundary", message: message,
                                   segment: segment, boundary: field, track: stream.index).because(.joinDecoderHistory)
                }
                if !originalEdge { packets.append(sound) }
            }
        }
        if start && target == .zero && first || !start && target == media.duration && preservesEnd { return target }
        // The edit clock must represent every selected track. Its common grid is the GCD of their sample rates.
        let rate = commonAudioSampleRate(sampleRates)
        if packets.isEmpty {
            guard rate > 0 else { return target }
            let nearest = RationalTime(numerator: try target.roundedToSamples(rate), denominator: Int64(rate))
            if nearest == target || snap == .nearest { return nearest }
            throw CutError(code: "unsafe_boundary", message: "The requested \(field) falls between audio samples.",
                           segment: segment, boundary: field, nearest: [nearest]).because(.cutAudioSample)
        }
        var neighbors: [RationalTime]
        if packets.count == 1 {
            let samples = packets[0].packets
            let index = samples.lowerBound { $0.time >= target }
            if index < samples.count, samples[index].time == target,
               rate == 0 || Int64(rate).isMultiple(of: target.denominator) { return target }
            func eligible(_ packet: AudioPacket) -> Bool {
                packet.time >= .zero && packet.time <= media.duration &&
                    (rate == 0 || Int64(rate).isMultiple(of: packet.time.denominator))
            }
            neighbors = [samples[..<index].reversed().first(where: eligible)?.time,
                         samples[index...].first(where: eligible)?.time].compactMap { $0 }
        } else {
            let sorted: [RationalTime]
            if let cached = common[media.url] { sorted = cached }
            else {
                var choices = Set(packets[0].packets.lazy.map(\.time))
                for track in packets.dropFirst() { choices.formIntersection(track.packets.lazy.map(\.time)) }
                sorted = choices.filter { time in time >= .zero && time <= media.duration &&
                        (rate == 0 || Int64(rate).isMultiple(of: time.denominator)) }.sorted()
                common[media.url] = sorted
            }
            let index = sorted.lowerBound { $0 >= target }
            if index < sorted.count && sorted[index] == target { return target }
            neighbors = [index - 1, index].compactMap { sorted.indices.contains($0) ? sorted[$0] : nil }
        }
        // The audible start/end may fall inside the first/last encoded packet.
        // At the outer edge the original priming and padding preserve these endpoints.
        if start && first && (neighbors.first ?? media.duration) > target { neighbors.insert(.zero, at: 0) }
        if !start && (neighbors.last ?? .zero) < target {
            // A complete unpadded packet also ends cleanly before the next source.
            // Packet-start indexes have no entry for the end of the final packet.
            let packetEndIsCopyable = packets.allSatisfy { track in
                guard let final = track.packets.last, final.discardSamples == 0 else { return false }
                return (try? final.time.adding(final.duration)) == media.duration
            } && (rate == 0 || Int64(rate).isMultiple(of: media.duration.denominator))
            if preservesEnd || packetEndIsCopyable {
                if target == media.duration { return target }
                neighbors.append(media.duration)
            }
        }
        if snap == .nearest, let low = neighbors.first, let high = neighbors.last {
            return target.isCloserToEarlier(low, than: high) ? low : high
        }
        throw CutError(code: "unsafe_boundary", message: "The requested \(field) falls between copyable audio packets.",
                       segment: segment, boundary: field, nearest: neighbors).because(.cutAudioPacket)
    }
}

extension ExportPlan {
    /// What a packet copy leaves behind, one sentence each. A copy writes no warnings of its own: it keeps every
    /// selected sample, so the only losses are a source’s cover art, chapters or timecode that the chosen container
    /// or track selection cannot hold. An encode reports its own warnings.
    public var copyOmissions: [String] {
        switch self {
        case .packets(let edit, _, _): return CutEngine().copyOmissions(edit)
        case .audio(let plan): return plan.isCopy ? CutEngine().copyOmissions(plan.edit) : []
        case .conversion: return []
        }
    }
}
