import Foundation

/// What a packet copy cannot keep exact where two ranges meet inside one output, one sentence per audio track.
///
/// An AAC copy into MOV, MP4 or M4A places each range with its own edit-list entry. The entry starts inside the
/// range's first AAC frame, after two whole frames of decoder history, and the previous entry ends inside its last
/// frame, so players that apply edit lists to the sample (Apple's) play each join exactly as the source decodes.
/// Players that apply an interior entry only at whole AAC frames, such as FFmpeg-based ones, play the whole last
/// frame before a join and leave out the partial first frame after it, so the sound there is moved and the cut
/// lands elsewhere. The note gives both distances for each such join.
///
/// AC-3 and E-AC-3 frames overlap their neighbours by one transform block. A copied frame after a join, or a copy
/// that starts inside the source, is decoded with another frame's overlap than its own, so its first block can
/// differ from the source and click. Placement stays exact: these joins are on frame boundaries.
struct AudioJoinNotes {
    /// One output range with the indexed source it was planned from.
    struct Range {
        let segment: ResolvedSegment
        let media: MediaInfo
    }

    /// How far a whole-frame reader moves the sound at one join, in samples of the track's rate.
    struct WholeFrameOffset: Equatable {
        /// Samples of the earlier range played after its cut: the rest of its last copied frame.
        let pastCut: Int64
        /// Samples of the later range left out after the join: the part of its first frame inside the range.
        let skipped: Int64
    }

    /// Joins named one by one in a note. A long edit, such as one that strips silence, sums up the rest.
    static let listedJoins = 12

    /// The transform overlap AC-3 and E-AC-3 decode from the previous frame, in samples.
    static let ac3OverlapSamples = 256

    static func notes(_ ranges: [Range], container: String) -> [String] {
        guard ranges.count > 0 else { return [] }
        let aacEdits = ["mov", "mp4", "m4v", "m4a"].contains(container)
        let positions = ranges.map { audioWindows($0) }
        let trackCount = positions.map(\.count).min() ?? 0
        var notes: [String] = []
        for position in 0..<trackCount {
            guard let (_, firstSound) = positions[0][position] else { continue }
            let codec = firstSound.stream.codec
            if codec == "aac" && aacEdits {
                if let note = aacNote(ranges, positions: positions, position: position) { notes.append(note) }
            } else if codec == "ac3" || codec == "eac3" {
                if let note = overlapNote(ranges, positions: positions, position: position) { notes.append(note) }
            }
        }
        return notes
    }

    /// Each audio track window of a range, in output order, with its source index.
    private static func audioWindows(_ range: Range) -> [(ResolvedTrack, AudioIndex)?] {
        range.segment.tracks.filter { $0.kind == "audio" }.map { track in
            range.media.audio.first(where: { $0.stream.index == track.index }).map { (track, $0) }
        }
    }

    /// The distances for one join, or nil when the source's packets do not place them: a track with its own
    /// presentation edits, or no packet index.
    static func wholeFrameOffset(before: AudioIndex, end: RationalTime,
                                 after: AudioIndex, start: RationalTime) -> WholeFrameOffset? {
        guard let past = pastCut(before, end: end), let skipped = skippedAfterCut(after, start: start) else { return nil }
        return WholeFrameOffset(pastCut: past, skipped: skipped)
    }

    /// The samples of the frame that holds the sample before `end` that lie after it, or nil when the source's packets
    /// do not place them: a track with its own presentation edits, or no packet index.
    static func pastCut(_ sound: AudioIndex, end: RationalTime) -> Int64? {
        guard sound.presentationEdits.isEmpty, sound.stream.sampleRate > 0, !sound.packets.isEmpty else { return nil }
        let closing = sound.packets.lowerBound { $0.time >= end }
        guard closing > 0, closing == sound.packets.count || sound.packets[closing].time != end else { return 0 }
        let frame = sound.packets[closing - 1]
        guard let frameEnd = try? frame.time.adding(frame.duration) else { return nil }
        guard frameEnd > end else { return 0 }
        return try? frameEnd.subtracting(end).roundedToSamples(sound.stream.sampleRate)
    }

    /// The samples from `start` to the first frame that starts at or after it, or nil as for `pastCut`.
    static func skippedAfterCut(_ sound: AudioIndex, start: RationalTime) -> Int64? {
        guard sound.presentationEdits.isEmpty, sound.stream.sampleRate > 0 else { return nil }
        let opening = sound.packets.lowerBound { $0.time >= start }
        guard opening < sound.packets.count else { return nil }
        return try? sound.packets[opening].time.subtracting(start).roundedToSamples(sound.stream.sampleRate)
    }

    private static func aacNote(_ ranges: [Range], positions: [[(ResolvedTrack, AudioIndex)?]], position: Int) -> String? {
        guard ranges.count > 1 else { return nil }
        var details: [String] = []
        var unplaced: [String] = []
        var unlisted = 0
        var largestUnlisted: Int64 = 0
        var largestFrame = 1024
        var rate = 0
        for index in 1..<ranges.count {
            guard let (earlier, before) = positions[index - 1][position],
                  let (later, after) = positions[index][position],
                  before.stream.codec == "aac", after.stream.codec == "aac" else { continue }
            let at = ExportRules.seconds(later.outputStart.seconds)
            largestFrame = max(largestFrame, frameSamples(before), frameSamples(after))
            if rate == 0 { rate = before.stream.sampleRate }
            guard let offset = wholeFrameOffset(before: before, end: earlier.sourceEnd, after: after, start: later.sourceStart) else {
                unplaced.append(at)
                continue
            }
            if offset.pastCut == 0 && offset.skipped == 0 { continue }
            guard details.count < listedJoins else {
                unlisted += 1
                largestUnlisted = max(largestUnlisted, offset.pastCut, offset.skipped)
                continue
            }
            var parts: [String] = []
            if offset.pastCut > 0 { parts.append("\(milliseconds(offset.pastCut, rate: before.stream.sampleRate)) past the cut") }
            if offset.skipped > 0 {
                parts.append("the first \(milliseconds(offset.skipped, rate: after.stream.sampleRate)) of the next range left out")
            }
            details.append("at \(at), \(parts.joined(separator: " and "))")
        }
        if unlisted > 0 {
            details.append("at \(unlisted) more \(unlisted == 1 ? "join" : "joins"), by up to \(milliseconds(largestUnlisted, rate: max(1, rate))) each")
        }
        if !unplaced.isEmpty {
            details.append("at \(unplaced.joined(separator: ", ")), by up to \(milliseconds(Int64(largestFrame), rate: max(1, rate)))")
        }
        // With more than one entry, such a player can also keep the whole frame that holds the last sample.
        if let (last, sound) = positions[ranges.count - 1][position], sound.stream.codec == "aac" {
            let past = pastCut(sound, end: last.sourceEnd)
            if past == nil || past! > 0 {
                let samples = past ?? Int64(frameSamples(sound))
                details.append("up to \(milliseconds(samples, rate: sound.stream.sampleRate)) past the end")
            }
        }
        guard !details.isEmpty else { return nil }
        let track = trackName(positions, position: position, codec: "AAC")
        let joins = ranges.count - 1
        if details.count > 1 { details[details.count - 1] = "and " + details[details.count - 1] }
        return "\(track) is joined at \(joins == 1 ? "1 point" : "\(joins) points") by edit-list entries. "
            + "Players that apply edit lists to the sample, such as Apple's, play each join exactly; players that apply them "
            + "only at whole AAC frames, such as FFmpeg-based ones, move the sound: " + details.joined(separator: "; ")
            + ". Converting the audio writes one continuous track that every player places exactly."
    }

    private static func overlapNote(_ ranges: [Range], positions: [[(ResolvedTrack, AudioIndex)?]], position: Int) -> String? {
        var subjects: [String] = []
        var rate = 0
        if let (first, sound) = positions[0][position], let head = sound.packets.first, first.sourceStart > head.time {
            subjects.append("the first frame, which begins inside the source,")
            rate = sound.stream.sampleRate
        }
        var joins: [String] = []
        for index in 1..<max(1, ranges.count) {
            guard let (later, sound) = positions[index][position], ["ac3", "eac3"].contains(sound.stream.codec) else { continue }
            joins.append(ExportRules.seconds(later.outputStart.seconds))
            if rate == 0 { rate = sound.stream.sampleRate }
        }
        if joins.count > listedJoins {
            let more = joins.count - listedJoins
            joins = Array(joins.prefix(listedJoins)) + ["\(more) more \(more == 1 ? "join" : "joins")"]
        }
        if !joins.isEmpty {
            let list = joins.count == 1 ? joins[0] : joins.dropLast().joined(separator: ", ") + " and " + joins.last!
            subjects.append("the first frame after \(joins.count == 1 ? "the join" : "each join") (at \(list))")
        }
        guard !subjects.isEmpty, rate > 0 else { return nil }
        let codec = positions[0][position]?.1.stream.codec == "eac3" ? "E-AC-3" : "AC-3"
        let track = trackName(positions, position: position, codec: codec)
        return "\(track) is copied in whole frames, so \(subjects.joined(separator: " and ")) "
            + "\(subjects.count == 1 ? "is" : "are") decoded with another overlap than in the source: "
            + "up to \(milliseconds(Int64(ac3OverlapSamples), rate: rate)) there can differ from the source and click. "
            + "Converting the audio decodes each range from its own frames."
    }

    private static func trackName(_ positions: [[(ResolvedTrack, AudioIndex)?]], position: Int, codec: String) -> String {
        guard let index = positions[0][position]?.0.index else { return "The \(codec) track" }
        return "\(codec) track \(index)"
    }

    private static func frameSamples(_ sound: AudioIndex) -> Int {
        guard sound.stream.sampleRate > 0, let packet = sound.packets.first,
              let samples = try? packet.duration.roundedToSamples(sound.stream.sampleRate), samples > 0 else { return 1024 }
        return Int(samples)
    }

    static func milliseconds(_ samples: Int64, rate: Int) -> String {
        let value = Double(samples) * 1000 / Double(rate)
        return value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX"))) + " ms"
    }
}

extension ResolvedEdit {
    /// Plan the join notes of a packet copy from its segments and the indexed sources they came from.
    mutating func noteAudioJoins(_ ranges: [AudioJoinNotes.Range]) {
        audioJoinNotes = AudioJoinNotes.notes(ranges, container: container)
    }
}
