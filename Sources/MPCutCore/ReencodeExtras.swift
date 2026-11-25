import Foundation

/// A subtitle or timed-data track that a movie re-encode carries beside the encoded picture and sound. Its packets are
/// staged as copies: each kept range keeps the cues that overlap it, a cue that runs across a cut is shortened to the
/// range, and a data sample is kept only when it lies wholly inside the range, as a copy does (writer.c remux_extra).
/// A text subtitle track that the output container cannot hold as is is converted from those staged cues by the final mux.
struct ReencodeExtraTrack: Sendable {
    /// The track's stream in each source file. Every source of the edit has one.
    let streams: [URL: StreamInfo]
    let kind: String
    let language: String
    let disposition: Int
    /// How the final mux converts the staged cues, or nil when it copies the packets.
    var conversion: ReencodeTextConversion? = nil
}

/// How a text subtitle track reaches a container that cannot hold its codec: the helper encoder that writes it, and a
/// container that holds the source codec as is, where its kept ranges are staged as packet copies first.
struct ReencodeTextConversion: Equatable, Sendable {
    let encoder: String
    let staging: String
}

extension ReencodeEngine {
    /// A track that travels beside picture and sound (writer.c extra_track): a subtitle track, or a data track other than
    /// the MOV timecode and a chapter list. The chapter list is written from the source chapters (ReencodeChapter).
    static func isExtraTrack(_ stream: StreamInfo) -> Bool {
        stream.kind == "subtitle" || (stream.kind == "data" && stream.codecTag != "tmcd" && !isChapterList(stream))
    }

    /// FFmpeg reads the text track that holds a QuickTime or MP4 chapter list as binary data with the 'text' entry name.
    static func isChapterList(_ stream: StreamInfo) -> Bool {
        stream.kind == "data" && stream.codec == "bin_data" && stream.codecTag == "text"
    }

    /// Whether the output container keeps an extra track's packets and sample description as they are. This is the rule
    /// of a copy (writer.c carried_extra), measured with the helper's muxers: 3GPP text in MP4 and MOV, QuickTime text
    /// only in MOV, GoPro telemetry ('gpmd') in MP4 and MOV, and SubRip, ASS, SSA and WebVTT in Matroska. A text track
    /// that another container needs in another codec may be converted instead (textConversion).
    static func carriesExtraTrack(_ stream: StreamInfo, container: String) -> Bool {
        let quickTime = ["mov", "mp4"].contains(container)
        switch (stream.kind, stream.codec) {
        case ("data", _): return quickTime && stream.codecTag == "gpmd"
        case ("subtitle", "mov_text"): return (quickTime && stream.codecTag == "tx3g") || (container == "mov" && stream.codecTag == "text")
        case ("subtitle", "subrip"), ("subtitle", "ass"), ("subtitle", "ssa"), ("subtitle", "webvtt"): return container == "mkv"
        default: return false
        }
    }

    /// Whether a 3GPP text decoder reads the track's sample description: a 'tx3g' entry, or a QuickTime 'text' entry
    /// laid out as 3GPP text with its font table at byte 34, as FFmpeg writes mov_text into MOV. A sample description of
    /// QuickTime's own text media has another layout, which the decoder would misread as styling.
    static func isThreeGPPText(_ stream: StreamInfo) -> Bool {
        guard stream.kind == "subtitle", stream.codec == "mov_text" else { return false }
        if stream.codecTag == "tx3g" { return true }
        let description = [UInt8](stream.configuration)
        return stream.codecTag == "text" && description.count >= 38 && Array(description[34..<38]) == Array("ftab".utf8)
    }

    /// The conversion of a text subtitle track that the output container cannot hold as is, measured with the helper's
    /// decoders and encoders: SubRip, ASS (which also holds SSA scripts) and WebVTT become 3GPP text in MP4 and MOV, and
    /// 3GPP text becomes SubRip in Matroska. Nil when the track is copied, or when the helper has no encoder for it
    /// (`encoders` nil or empty assumes the bundled helper, as automatic audio does). Bitmap subtitles stay out.
    static func textConversion(_ stream: StreamInfo, container: String, encoders: Set<String>?) -> ReencodeTextConversion? {
        guard stream.kind == "subtitle", !carriesExtraTrack(stream, container: container) else { return nil }
        let conversion: ReencodeTextConversion
        switch (stream.codec, container) {
        case ("subrip", "mp4"), ("subrip", "mov"), ("ass", "mp4"), ("ass", "mov"), ("webvtt", "mp4"), ("webvtt", "mov"):
            conversion = ReencodeTextConversion(encoder: "mov_text", staging: "mkv")
        case ("mov_text", "mkv") where isThreeGPPText(stream):
            conversion = ReencodeTextConversion(encoder: "srt", staging: "mov")
        default:
            return nil
        }
        guard encoders.map({ $0.isEmpty || $0.contains(conversion.encoder) }) ?? true else { return nil }
        return conversion
    }

    /// What a conversion keeps and loses, read from the helper's decoders and its movtextenc.c and srtenc.c, for the
    /// plan's warnings.
    private static func conversionWarning(_ stream: StreamInfo, conversion: ReencodeTextConversion, container: String) -> String {
        let name = container.uppercased()
        guard conversion.encoder == "mov_text" else {
            let clock = stream.timeBase
            let rounding = (1_000 * clock.numerator) % max(1, clock.denominator) == 0 ? "" : " Cue times finer than a millisecond are rounded."
            return "Subtitle track \(stream.index) (\(stream.codec)) is converted to SubRip for \(name). Its text and line breaks "
                + "are kept, and its bold, italic, underline, colour, font, size and alignment become SubRip tags; its background "
                + "colour, transparency, highlighting and text box are not kept.\(rounding)"
        }
        // The cues are rewritten into styling the encoder keeps (ThreeGPPTextStyles), and every font they name gets a
        // style in the script header, so it reaches the font table; a font name with a comma cannot be written in a
        // style line, and the table holds names of up to 255 bytes. 3GPP text has no strikethrough. A sample has one
        // highlight span, which ASS secondary colours set, so cues joined into one sample (TextCueMerge) cannot keep a
        // highlight each; SubRip and WebVTT never set one. Sizes are scaled from the script's height to the picture's
        // (the encoder's height option, with a PlayResY stated in every script header) and written in one byte, so a
        // larger one is clamped (ThreeGPPTextStyles.largestSize). 3GPP text has no layers, so identical ASS lines shown
        // at once are one line (TextCueMerge.joined).
        let fonts = " A font whose name has a comma or is longer than 255 bytes is shown in the default font."
        let clamp = "; a size above 255 pixels, the most 3GPP text holds, is written at 255."
        let styles: String
        var notes = fonts
        switch stream.codec {
        case "ass":
            styles = "the bold, italic, underline, colour, transparency, font and size of its styles and overrides are kept; "
                + "strikethrough, outline and shadow colours, scaling, spacing, rotation, blur, positions, alignment, margins, "
                + "outlines, shadows, animation and karaoke are not"
            notes += " Font sizes are scaled from the script's PlayResY (288 when it states none) to the picture's height"
                + clamp + " Layers are flattened: lines shown at once are placed one under the other, and identical lines on "
                + "different layers appear once, in the style of the one drawn on top. Where two cues shown together both set "
                + "a highlight (secondary colour), it runs from the first to the last."
        case "webvtt":
            styles = "its bold, italic and underline are kept; its cue settings, classes, voices and timed karaoke are not"
            notes = ""
        default:
            styles = "its bold, italic, underline, colour, font and size are kept; its strikethrough, alignment and position "
                + "are not"
            notes += " Font sizes are measured against 288 lines and scaled to the picture's height" + clamp
        }
        return "Subtitle track \(stream.index) (\(stream.codec)) is converted to 3GPP text for \(name). Its text and line breaks "
            + "and \(styles). 3GPP text shows one cue at a time, so where cues overlap the track is split at each cue's start "
            + "and end, and each part shows every cue on screen then, one under the other in cue order.\(notes)"
    }

    private static func extraName(_ stream: StreamInfo) -> String {
        stream.kind == "data" && !stream.codecTag.isEmpty ? stream.codecTag : stream.codec
    }

    private static func leftOut(_ stream: StreamInfo, clip: Int, container: String) -> String {
        "Clip \(clip) \(stream.kind == "data" ? "data" : "subtitle") track \(stream.index) "
            + "(\(extraName(stream))) cannot be carried in \(container.uppercased()) and is left out."
    }

    /// The extra tracks a movie re-encode carries, and a warning for each one it leaves out or converts. One output track
    /// holds the track at its position among the carried tracks of every source, so the sources must agree on them.
    /// Decided from the streams, the container and the helper's encoders alone, so a plan that starts no process states
    /// the same as an export with the bundled helper.
    static func plannedExtraTracks(_ sources: [(file: URL, clip: Int, media: MediaInfo)], segments: [ResolvedSegment],
                                   container: String, encoders: Set<String>? = nil) -> (tracks: [ReencodeExtraTrack], warnings: [String]) {
        var warnings: [String] = []
        var carried: [[StreamInfo]] = []
        for source in sources {
            var kept: [StreamInfo] = []
            for stream in source.media.streams where isExtraTrack(stream) {
                if carriesExtraTrack(stream, container: container)
                    || textConversion(stream, container: container, encoders: encoders) != nil {
                    kept.append(stream)
                } else {
                    warnings.append(leftOut(stream, clip: source.clip, container: container))
                }
            }
            carried.append(kept)
        }
        // Every carried track of a range is staged in one file. A converted track is staged in a container that holds its
        // source codec, so it is carried only when that container also holds every copied track.
        let stagings = Set(carried.joined().compactMap { textConversion($0, container: container, encoders: encoders)?.staging })
        if let staging = stagings.first, stagings.count > 1 || !carried.joined().allSatisfy({
            textConversion($0, container: container, encoders: encoders) != nil || carriesExtraTrack($0, container: staging)
        }) {
            for (position, source) in sources.enumerated() {
                carried[position].removeAll { stream in
                    guard textConversion(stream, container: container, encoders: encoders) != nil else { return false }
                    warnings.append(leftOut(stream, clip: source.clip, container: container))
                    return true
                }
            }
        }
        guard carried.contains(where: { !$0.isEmpty }), let first = carried.first else { return ([], warnings) }
        let matching = carried.allSatisfy { kept in
            kept.count == first.count && zip(kept, first).allSatisfy {
                $0.kind == $1.kind && $0.codec == $1.codec && $0.codecTag == $1.codecTag && $0.configuration == $1.configuration
            }
        }
        guard matching else {
            let count = carried.reduce(0) { $0 + $1.count }
            warnings.append("Subtitle and data tracks are carried only when every source has the same ones. "
                + "\(count) track\(count == 1 ? " is" : "s are") left out.")
            return ([], warnings)
        }
        let tracks = first.indices.map { position in
            ReencodeExtraTrack(streams: Dictionary(zip(sources, carried).map { ($0.file, $1[position]) }, uniquingKeysWith: { kept, _ in kept }),
                               kind: first[position].kind, language: first[position].language,
                               disposition: first[position].disposition,
                               conversion: textConversion(first[position], container: container, encoders: encoders))
        }
        for stream in first {
            if let conversion = textConversion(stream, container: container, encoders: encoders) {
                warnings.append(conversionWarning(stream, conversion: conversion, container: container))
            }
        }
        let whole = segments.count == 1 && segments[0].from == .zero && segments[0].reachesEnd
        for stream in first where stream.kind == "data" && !whole {
            warnings.append("Data track \(stream.index) (\(extraName(stream))) keeps only the samples that lie wholly inside the kept ranges.")
        }
        return (tracks, warnings)
    }

    /// The packet filters of one kept range of an extra track, on the track's own clock: drop the packets outside it,
    /// then move the rest to the start of the range. A cue that crosses either end is shortened to the range. A data
    /// sample is kept only when it lies wholly inside, and a packet without a duration when it starts inside.
    static func extraPacketFilters(subtitle: Bool, start: Int64, end: Int64) -> String {
        let outside = subtitle
            ? "if(gt(duration\\,0)\\,lte(pts+duration\\,\(start))+gte(pts\\,\(end))\\,lt(pts\\,\(start))+gte(pts\\,\(end)))"
            : "if(gt(duration\\,0)\\,lt(pts\\,\(start))+gt(pts+duration\\,\(end))\\,lt(pts\\,\(start))+gte(pts\\,\(end)))"
        guard subtitle else { return "noise=drop=\(outside),setts=pts=PTS-\(start):dts=PTS-\(start)" }
        let placed = "max(PTS\\,\(start))-\(start)"
        return "noise=drop=\(outside),setts=pts=\(placed):dts=\(placed)"
            + ":duration=if(gt(DURATION\\,0)\\,min(PTS+DURATION\\,\(end))-max(PTS\\,\(start))\\,0)"
    }

    /// The container of the staged ranges: the output container, or the one that holds a converted track's source codec.
    /// plannedExtraTracks carries a converted track only when that container holds every carried track as is.
    static func extraStagingContainer(_ plan: ReencodePlan) -> String {
        plan.extras.lazy.compactMap(\.conversion?.staging).first ?? plan.edit.container
    }

    /// Writes each kept range's share of the carried tracks into a file of the staging container, starting at zero, and
    /// an ffconcat list that places them on the output timeline. One helper run reads a source once for its ranges.
    /// Returns the list's name in `staging`, or nil when the plan carries no extra track.
    func stageExtraTracks(_ plan: ReencodePlan, in staging: URL) throws -> String? {
        guard !plan.extras.isEmpty else { return nil }
        let container = Self.extraStagingContainer(plan)
        var order: [URL] = []
        var ranges: [URL: [Int]] = [:]
        for (index, segment) in plan.edit.segments.enumerated() {
            if ranges[segment.file] == nil { order.append(segment.file) }
            ranges[segment.file, default: []].append(index)
        }
        for file in order {
            guard let media = plan.media[file] else {
                throw CutError(code: "invalid_input", message: "A source is missing from the export plan.")
            }
            let indexes = ranges[file] ?? []
            // Each output holds a file open. Bound them as the render bounds its inputs.
            for chunk in stride(from: 0, to: indexes.count, by: 32).map({ Array(indexes[$0..<min($0 + 32, indexes.count)]) }) {
                try checkCancellation()
                // The source clock, as the picture filters read it, so the ranges match the kept pictures.
                var args = ["-copyts", "-i", file.path]
                // The helper writes an unreadable Matroska file when a range keeps no cue. One millisecond of silence
                // after the carried tracks gives every file a block. The final mux maps only the carried tracks.
                let placeholder = container == "mkv"
                if placeholder { args += ["-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono:d=0.001"] }
                for index in chunk {
                    let segment = plan.edit.segments[index]
                    let start = try media.origin.adding(segment.from)
                    let end = try media.origin.adding(segment.to)
                    for (position, track) in plan.extras.enumerated() {
                        guard let stream = track.streams[file] else {
                            throw CutError(code: "invalid_input", message: "A source is missing from the export plan.")
                        }
                        args += ["-map", "0:\(stream.index)", "-bsf:\(position)",
                                 Self.extraPacketFilters(subtitle: track.kind == "subtitle",
                                                         start: try ticks(start, stream.timeBase), end: try ticks(end, stream.timeBase))]
                    }
                    if placeholder { args += ["-map", "1:a", "-c:a", "pcm_s16le"] }
                    args += ["-c:s", "copy", "-c:d", "copy", "-map_metadata", "-1", "-map_chapters", "-1",
                             "-f", muxerName(container), "extra-\(index).\(container)"]
                }
                try runHelper(plan.helper, arguments: args, in: staging)
            }
        }
        // As for export batches: round cumulative output times, then difference them, so no error accumulates.
        var manifest = "ffconcat version 1.0\n"
        for (index, segment) in plan.edit.segments.enumerated() {
            let from = try segment.outputStart.roundedToSamples(1_000_000)
            let to = try segment.outputStart.adding(segment.duration).roundedToSamples(1_000_000)
            // An in point of zero places the file's own zero at the start of the range, not its first cue.
            manifest += "file 'extra-\(index).\(container)'\ninpoint 0\nduration \(to - from)us\n"
        }
        do {
            try manifest.write(to: staging.appendingPathComponent("extras.ffconcat"), atomically: true, encoding: .utf8)
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        return "extras.ffconcat"
    }

    /// The final mux's input of staged extra tracks.
    static func extraTrackInput(_ manifest: String) -> [String] {
        ["-f", "concat", "-safe", "1", "-i", manifest]
    }

    /// Maps the staged extra tracks of input `input` after the picture and sound, with their language and disposition.
    /// A converted track is decoded from its staged cues and encoded, so each cue keeps its remapped start and length.
    static func extraTrackOutput(_ plan: ReencodePlan, input: Int) -> [String] {
        var args: [String] = []
        var counts: [String: Int] = [:]
        for (position, track) in plan.extras.enumerated() {
            let type = track.kind == "subtitle" ? "s" : "d"
            let specifier = "\(type):\(counts[type, default: 0])"
            counts[type, default: 0] += 1
            args += ["-map", "\(input):\(position)", "-c:\(specifier)", track.conversion?.encoder ?? "copy"]
            if track.conversion?.encoder == "mov_text" {
                // An MP4 or MOV track holds one sample at a time and refuses two at one time. Overlapping cues within
                // a kept range are joined before this mux (prepareThreeGPPText), but a cue that runs to the end of one
                // range can still reach a tick past the next range's start, where the two ranges' times round apart.
                // The later cue then starts a microsecond (one tick of the subtitle encoder's clock) after the earlier
                // one, and the muxer ends the earlier there.
                let start = "if(eq(PREV_OUTPTS\\,NOPTS)\\,PTS\\,max(PTS\\,PREV_OUTPTS+1))"
                args += ["-bsf:\(specifier)", "setts=pts=\(start):dts=\(start)"]
                // The encoder scales the script's sizes from its PlayResY (stated in every prepared header) to this
                // height; without it the sizes stay in script units, which are not the picture's pixels.
                if plan.height > 0 { args += ["-height:\(specifier)", "\(plan.height)"] }
            }
            args += ["-metadata:s:\(specifier)", "language=\(track.language)", "-disposition:\(specifier)", "\(track.disposition)"]
        }
        return args
    }

    /// A time on a stream clock of `timeBase` seconds per tick, to the nearest tick.
    private func ticks(_ time: RationalTime, _ timeBase: RationalTime) throws -> Int64 {
        guard timeBase.numerator > 0, timeBase.denominator <= Int64(Int32.max) else {
            throw CutError(code: "unsupported_timing", message: "A subtitle or data track has no usable clock.")
        }
        return try time.multiplied(by: RationalTime(numerator: 1, denominator: timeBase.numerator))
            .roundedToSamples(Int(timeBase.denominator))
    }
}
