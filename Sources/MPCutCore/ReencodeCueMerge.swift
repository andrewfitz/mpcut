import CFFmpeg
import Foundation

/// A cue of a text subtitle track as an ASS event, "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text",
/// the form in which FFmpeg's SubRip, ASS and WebVTT decoders hand cues to the 3GPP text encoder. Its start and end are
/// on the track's clock; an end at or before the start means the cue states no length.
struct TextCue: Equatable, Sendable {
    var start: Int64
    var end: Int64
    var event: String
}

/// 3GPP text (mov_text) shows one sample at a time, so cues that overlap cannot each be a sample. The timeline is split
/// at every cue start and end, and each stretch becomes one cue that holds the text of every cue shown then, in cue
/// order, one under the other. Each joined cue starts from its own style, so bold, italic, underline, colour, font and
/// size stay with the cue that set them.
enum TextCueMerge {
    /// Whether two cues are shown at once, counting a cue without a length as shown until the next one starts.
    static func overlaps(_ cues: [TextCue]) -> Bool {
        var latest = Int64.min
        for cue in resolved(cues).sorted(by: { $0.start < $1.start }) {
            if cue.start < latest { return true }
            latest = max(latest, cue.end)
        }
        return false
    }

    /// The cues with no two shown at once, numbered in order. A stretch where no cue is shown has no cue. `opening`
    /// gives the override block that starts a later cue of a style in a joined event, and `collapsing` shows identical
    /// lines once (joined).
    static func merged(_ cues: [TextCue], collapsing: Bool = false,
                       opening: (String) -> String = TextCueMerge.reset) -> [TextCue] {
        let cues = resolved(cues)
        guard !cues.isEmpty else { return [] }
        let bounds = Set(cues.flatMap { [$0.start, $0.end] }).sorted()
        let starting = cues.indices.sorted { (cues[$0].start, $0) < (cues[$1].start, $1) }
        var next = 0
        // The cues shown in the current stretch, in cue order.
        var shown: [Int] = []
        var result: [TextCue] = []
        for (from, to) in zip(bounds, bounds.dropFirst()) {
            shown.removeAll { cues[$0].end <= from }
            while next < starting.count, cues[starting[next]].start <= from {
                let cue = starting[next]
                next += 1
                guard cues[cue].end > from else { continue }
                shown.insert(cue, at: shown.firstIndex { $0 > cue } ?? shown.count)
            }
            guard !shown.isEmpty else { continue }
            // A cue that draws nothing can end without changing what is shown.
            if let last = result.last, last.end == from,
               joined(shown.map { cues[$0].event }, readOrder: result.count - 1, collapsing: collapsing, opening: opening) == last.event {
                result[result.count - 1].end = to
                continue
            }
            result.append(TextCue(start: from, end: to, event: joined(shown.map { cues[$0].event }, readOrder: result.count, collapsing: collapsing, opening: opening)))
        }
        // Cues without a length after every other cue has ended keep no length.
        let last = cues.indices.filter { cues[$0].end <= cues[$0].start }
        if let first = last.first {
            result.append(TextCue(start: cues[first].start, end: cues[first].start,
                                  event: joined(last.map { cues[$0].event }, readOrder: result.count, collapsing: collapsing, opening: opening)))
        }
        return result
    }

    /// A cue without a length is shown until the next cue starts, as a 3GPP text sample is, or until the last other
    /// cue ends. One after every other cue keeps no length.
    private static func resolved(_ cues: [TextCue]) -> [TextCue] {
        let starts = cues.map(\.start).sorted()
        let latest = cues.lazy.filter { $0.end > $0.start }.map(\.end).max()
        return cues.map { cue in
            guard cue.end <= cue.start else { return cue }
            var cue = cue
            let following = starts.first { $0 > cue.start }
            cue.end = following ?? latest.map { max($0, cue.start) } ?? cue.start
            return cue
        }
    }

    private struct Event {
        var fields: [String]
        var style: String { fields[2] }
        var text: String { fields[8] }

        init(_ line: String) {
            var parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            if parts.count < 9 { parts = ["0", "0", "Default", "", "0", "0", "0", "", line] }
            fields = parts
        }
    }

    /// The override block that resets to a style by name.
    static func reset(_ style: String) -> String { "{\\r\(style)}" }

    /// One event that shows `events` together. The first event's layer, style, name, margins and effect describe it.
    /// Each later event starts on a new line with `opening` for its own style (by default a reset to it), and a bare
    /// reset in its text names that style too, since a reset without a name returns to the event's style. The 3GPP
    /// text encoder does not clear bold, italic or underline on a reset, so a conversion passes an opening that states
    /// the complete style (ThreeGPPTextStyles.opening).
    ///
    /// With `collapsing`, events with the same text outside override blocks are one line, as ASS layers drawn over
    /// each other show one: the line keeps the place of the first and the style of the one drawn on top, which is the
    /// highest layer and, among those, the last.
    static func joined(_ events: [String], readOrder: Int, collapsing: Bool = false,
                       opening: (String) -> String = TextCueMerge.reset) -> String {
        let parsed = events.map(Event.init)
        // A cue whose text draws nothing would add an empty line.
        let visible = parsed.filter { !visibleText($0.text).isEmpty }
        var kept: [Event] = []
        for event in visible.isEmpty ? Array(parsed.prefix(1)) : visible {
            if collapsing, let same = kept.firstIndex(where: { visibleText($0.text) == visibleText(event.text) }) {
                if (Int(event.fields[1]) ?? 0) >= (Int(kept[same].fields[1]) ?? 0) { kept[same] = event }
            } else {
                kept.append(event)
            }
        }
        guard var fields = kept.first?.fields else { return "\(readOrder),0,Default,,0,0,0,," }
        fields[0] = String(readOrder)
        for event in kept.dropFirst() {
            let style = event.style.isEmpty ? "Default" : event.style
            fields[8] += "\\N" + opening(style) + namingResets(event.text, style: style)
        }
        return fields.joined(separator: ",")
    }

    /// The text outside override blocks.
    private static func visibleText(_ text: String) -> String {
        var result = ""
        var inBlock = false
        for character in text {
            if character == "{" && !inBlock {
                inBlock = true
            } else if character == "}" && inBlock {
                inBlock = false
            } else if !inBlock {
                result.append(character)
            }
        }
        return result
    }

    /// Names `style` in every `\r` without a style name inside the text's override blocks.
    private static func namingResets(_ text: String, style: String) -> String {
        var result = ""
        var inBlock = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            result.append(character)
            if character == "{" && !inBlock {
                inBlock = true
            } else if character == "}" && inBlock {
                inBlock = false
            } else if inBlock, character == "\\", index + 1 < characters.count, characters[index + 1] == "r",
                      index + 2 < characters.count, characters[index + 2] == "\\" || characters[index + 2] == "}" {
                result += "r" + style
                index += 1
            }
            index += 1
        }
        return result
    }
}

extension ReencodeEngine {
    /// Prepares every staged track that the final mux converts to 3GPP text. Its cues are decoded to ASS events, as the
    /// final mux would decode them, and their styling is rewritten into forms the 3GPP text encoder keeps
    /// (ThreeGPPTextStyles), with a script header that names every font the cues use. Each staged range is read on its
    /// own and its overlapping cues are joined (TextCueMerge), so the rounding where ranges meet on the output timeline
    /// never counts as an overlap: the final mux's microsecond nudge settles it as before. The track is then written as
    /// ASS in every range, beside the other tracks copied as they are and in the same order; the concat demuxer takes
    /// the codec and script header from the first range. Returns the ffconcat list of the rewritten ranges, or
    /// `manifest` when no track is converted to 3GPP text.
    func prepareThreeGPPText(_ plan: ReencodePlan, manifest: String, in staging: URL) throws -> String {
        let converted = plan.extras.indices.filter { plan.extras[$0].conversion?.encoder == "mov_text" }
        guard !converted.isEmpty else { return manifest }
        let list: String
        do {
            list = try String(contentsOf: staging.appendingPathComponent(manifest), encoding: .utf8)
        } catch {
            throw Self.preparationFailure("could not read the staged ranges")
        }
        let prefix = "file '"
        let files = list.split(separator: "\n").filter { $0.hasPrefix(prefix) && $0.hasSuffix("'") }
            .map { String($0.dropFirst(prefix.count).dropLast()) }

        // Every range is decoded first, since the script header of the first must name the fonts of all of them.
        var cues: [[Int: [TextCue]]] = []
        var headers: [Int: [UInt8]] = [:]
        // The script header each track is encoded with, before the fonts of its cues are added: it states a PlayResY,
        // since the encoder scales sizes from it to the picture height (extraTrackOutput), and no style size is
        // larger than the encoder can write at that height. A header that is not UTF-8 text is used as it is.
        var prepared: [Int: ThreeGPPTextStyles.Header] = [:]
        for file in files {
            try checkCancellation()
            let staged = try StagedRange(staging.appendingPathComponent(file), checking: checkCancellation)
            defer { staged.close() }
            guard converted.allSatisfy({ $0 < staged.packets.count }) else { throw Self.preparationFailure("a staged track is missing") }
            var decoded: [Int: [TextCue]] = [:]
            for index in converted {
                guard let stream = staged.input.pointee.streams[index] else { throw Self.preparationFailure("a staged track is missing") }
                let track = try Self.decodedCues(stream, packets: staged.packets[index])
                if headers[index] == nil {
                    headers[index] = track.header
                    prepared[index] = Self.preparedHeader(track.header, pictureHeight: plan.height)
                }
                guard let header = prepared[index] else { throw Self.preparationFailure("a staged track is missing") }
                decoded[index] = track.cues.map {
                    TextCue(start: $0.start, end: $0.end, event: ThreeGPPTextStyles.normalized($0.event, header: header))
                }
            }
            cues.append(decoded)
        }
        // A header that is not UTF-8 text is kept as it is, without added fonts.
        var scripts: [Int: [UInt8]] = [:]
        for index in converted {
            let bytes = headers[index] ?? []
            guard String(bytes: bytes, encoding: .utf8) != nil, let header = prepared[index] else {
                scripts[index] = bytes
                continue
            }
            let fonts = ThreeGPPTextStyles.fonts(cues.flatMap { ($0[index] ?? []).map(\.event) })
            scripts[index] = Array(header.addingFonts(fonts).utf8)
        }

        var rewritten = list
        for (position, file) in files.enumerated() {
            try checkCancellation()
            let staged = try StagedRange(staging.appendingPathComponent(file), checking: checkCancellation)
            defer { staged.close() }
            var joined: [Int: (cues: [TextCue], header: [UInt8])] = [:]
            for index in converted {
                guard let track = cues[position][index] else { throw Self.preparationFailure("a staged track is missing") }
                guard let header = prepared[index] else { throw Self.preparationFailure("a staged track is missing") }
                // ASS layers drawn over each other show one line; 3GPP text has no layers.
                let layered = plan.extras[index].streams.values.contains { $0.codec == "ass" }
                let merged = TextCueMerge.overlaps(track)
                    ? TextCueMerge.merged(track, collapsing: layered) { ThreeGPPTextStyles.opening($0, header: header) } : track
                joined[index] = (merged, scripts[index] ?? [])
            }
            let name = "text-\(position).mkv"
            try Self.writeStaged(staged.input, packets: staged.packets, joined: joined, to: staging.appendingPathComponent(name))
            rewritten = rewritten.replacingOccurrences(of: "\(prefix)\(file)'\n", with: "\(prefix)\(name)'\n")
        }
        let name = "extras-text.ffconcat"
        do {
            try rewritten.write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        return name
    }

    /// The script header a track is encoded with, before the fonts of its cues are added (prepareThreeGPPText).
    private static func preparedHeader(_ bytes: [UInt8], pictureHeight: Int) -> ThreeGPPTextStyles.Header {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            var header = ThreeGPPTextStyles.Header(String(decoding: bytes, as: UTF8.self))
            header.largestSize = ThreeGPPTextStyles.largestSize(pictureHeight: pictureHeight, scriptHeight: header.scriptHeight)
            return header
        }
        let stated = ThreeGPPTextStyles.Header(ThreeGPPTextStyles.Header(text).statingPlayResY())
        let largest = ThreeGPPTextStyles.largestSize(pictureHeight: pictureHeight, scriptHeight: stated.scriptHeight)
        var header = ThreeGPPTextStyles.Header(stated.clampingSizes(largest))
        header.largestSize = largest
        return header
    }

    private static func preparationFailure(_ reason: String) -> CutError {
        CutError(code: "encode_failed", message: "Subtitle cues could not be prepared for 3GPP text: \(reason).")
    }

    /// The cues of a staged text track as ASS events, decoded as the final mux decodes them, with the decoder's
    /// script header. Each event of a packet is one cue.
    private static func decodedCues(_ stream: UnsafeMutablePointer<AVStream>,
                                    packets: [UnsafeMutablePointer<AVPacket>]) throws -> (cues: [TextCue], header: [UInt8]) {
        guard let parameters = stream.pointee.codecpar, let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw preparationFailure("this build has no decoder for the subtitle track")
        }
        var codec = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codec) }
        guard let context = codec, avcodec_parameters_to_context(context, parameters) >= 0 else {
            throw preparationFailure("out of memory")
        }
        context.pointee.pkt_timebase = stream.pointee.time_base
        guard avcodec_open2(context, decoder, nil) >= 0 else { throw preparationFailure("the subtitle decoder could not be opened") }
        var cues: [TextCue] = []
        for packet in packets where packet.pointee.pts != Int64.min {
            var subtitle = AVSubtitle()
            var got: Int32 = 0
            guard avcodec_decode_subtitle2(context, &subtitle, &got, packet) >= 0 else {
                throw preparationFailure("a cue could not be decoded")
            }
            defer { avsubtitle_free(&subtitle) }
            guard got != 0 else { continue }
            let start = packet.pointee.pts
            let end = packet.pointee.duration > 0 ? start + packet.pointee.duration : start
            for position in 0..<Int(subtitle.num_rects) {
                guard let rect = subtitle.rects[position], let event = rect.pointee.ass else { continue }
                cues.append(TextCue(start: start, end: end, event: String(cString: event)))
            }
        }
        var header: [UInt8] = []
        if let bytes = context.pointee.subtitle_header, context.pointee.subtitle_header_size > 0 {
            header = Array(UnsafeBufferPointer(start: bytes, count: Int(context.pointee.subtitle_header_size)))
        }
        return (cues, header)
    }

    /// Writes every staged track into one Matroska file in the staged order: the joined tracks as ASS, the rest as the
    /// packets read.
    private static func writeStaged(_ input: UnsafeMutablePointer<AVFormatContext>,
                                    packets: [[UnsafeMutablePointer<AVPacket>]],
                                    joined: [Int: (cues: [TextCue], header: [UInt8])], to file: URL) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&context, nil, "matroska", file.path) >= 0, let output = context else {
            throw preparationFailure("the staged cues could not be written")
        }
        defer {
            if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }
            avformat_free_context(output)
        }
        var bases: [AVRational] = []
        for index in 0..<Int(input.pointee.nb_streams) {
            guard let source = input.pointee.streams[index], let stream = avformat_new_stream(output, nil) else {
                throw preparationFailure("out of memory")
            }
            stream.pointee.time_base = source.pointee.time_base
            bases.append(source.pointee.time_base)
            if let track = joined[index] {
                let parameters = stream.pointee.codecpar!
                parameters.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
                parameters.pointee.codec_id = AV_CODEC_ID_ASS
                if !track.header.isEmpty {
                    guard let bytes = av_mallocz(track.header.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else {
                        throw preparationFailure("out of memory")
                    }
                    track.header.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: track.header.count) }
                    parameters.pointee.extradata = bytes.assumingMemoryBound(to: UInt8.self)
                    parameters.pointee.extradata_size = Int32(track.header.count)
                }
            } else {
                guard avcodec_parameters_copy(stream.pointee.codecpar, source.pointee.codecpar) >= 0 else {
                    throw preparationFailure("out of memory")
                }
                stream.pointee.codecpar.pointee.codec_tag = 0
            }
        }
        guard avio_open(&output.pointee.pb, file.path, AVIO_FLAG_WRITE) >= 0,
              avformat_write_header(output, nil) >= 0 else {
            throw preparationFailure("the staged cues could not be written")
        }

        // Every packet, in presentation order across the tracks.
        var written: [(stream: Int, packet: UnsafeMutablePointer<AVPacket>, owned: Bool)] = []
        defer {
            for entry in written where entry.owned {
                var pointer: UnsafeMutablePointer<AVPacket>? = entry.packet
                av_packet_free(&pointer)
            }
        }
        for (index, list) in packets.enumerated() {
            guard let track = joined[index] else {
                written += list.map { (index, $0, false) }
                continue
            }
            for cue in track.cues {
                guard let packet = av_packet_alloc() else { throw preparationFailure("out of memory") }
                written.append((index, packet, true))
                let bytes = Array(cue.event.utf8)
                guard av_new_packet(packet, Int32(bytes.count)) >= 0 else { throw preparationFailure("out of memory") }
                bytes.withUnsafeBytes { packet.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
                packet.pointee.pts = cue.start
                packet.pointee.dts = cue.start
                packet.pointee.duration = cue.end - cue.start
                packet.pointee.flags |= AV_PKT_FLAG_KEY
            }
        }
        written = written.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            let order = av_compare_ts(timestamp(a.packet), bases[a.stream], timestamp(b.packet), bases[b.stream])
            return order != 0 ? order < 0 : left.offset < right.offset
        }.map(\.element)
        for entry in written {
            guard let stream = output.pointee.streams[entry.stream] else { continue }
            // The muxer takes the packet's reference, so a read packet is written from a copy that keeps it whole.
            guard let packet = av_packet_clone(entry.packet) else { throw preparationFailure("out of memory") }
            var pointer: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&pointer) }
            packet.pointee.stream_index = Int32(entry.stream)
            packet.pointee.pos = -1
            av_packet_rescale_ts(packet, bases[entry.stream], stream.pointee.time_base)
            guard av_interleaved_write_frame(output, packet) >= 0 else { throw preparationFailure("the staged cues could not be written") }
        }
        guard av_write_trailer(output) >= 0 else { throw preparationFailure("the staged cues could not be written") }
    }

    private static func timestamp(_ packet: UnsafeMutablePointer<AVPacket>) -> Int64 {
        packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts != Int64.min ? packet.pointee.pts : 0
    }
}

/// The packets of one staged range file, read whole, with the file still open for its stream descriptions.
private struct StagedRange {
    let input: UnsafeMutablePointer<AVFormatContext>
    /// The packets of each stream, in file order.
    let packets: [[UnsafeMutablePointer<AVPacket>]]

    init(_ file: URL, checking: () throws -> Void) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, file.path, nil, nil) >= 0, let input = context else {
            throw CutError(code: "encode_failed", message: "Subtitle cues could not be prepared for 3GPP text: "
                + "could not read the staged cues.")
        }
        var packets: [[UnsafeMutablePointer<AVPacket>]] = Array(repeating: [], count: Int(input.pointee.nb_streams))
        var reading = av_packet_alloc()
        defer { av_packet_free(&reading) }
        var failure: Error?
        if let packet = reading {
            var count = 0
            while true {
                let result = av_read_frame(input, packet)
                if result == averror(EAGAIN) { continue }
                guard result >= 0 else {
                    if result != AVERROR_EOF_VALUE {
                        failure = CutError(code: "encode_failed", message: "Subtitle cues could not be prepared for 3GPP "
                            + "text: could not read the staged cues.")
                    }
                    break
                }
                let index = Int(packet.pointee.stream_index)
                if packets.indices.contains(index), let copy = av_packet_clone(packet) { packets[index].append(copy) }
                av_packet_unref(packet)
                count += 1
                if count % 256 == 0 {
                    do { try checking() } catch { failure = error; break }
                }
            }
        } else {
            failure = CutError(code: "encode_failed", message: "Subtitle cues could not be prepared for 3GPP text: out of memory.")
        }
        self.input = input
        self.packets = packets
        if let failure {
            close()
            throw failure
        }
    }

    func close() {
        for packet in packets.joined() {
            var pointer: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&pointer)
        }
        var context: UnsafeMutablePointer<AVFormatContext>? = input
        avformat_close_input(&context)
    }
}

/// FFmpeg's AVERROR(e) for a POSIX error number, which Swift cannot import as a macro.
private func averror(_ code: Int32) -> Int32 { -code }

/// FFmpeg's AVERROR_EOF, FFERRTAG('E','O','F',' ').
private let AVERROR_EOF_VALUE: Int32 = -Int32(bitPattern: UInt32(0x45) | UInt32(0x4F) << 8 | UInt32(0x46) << 16 | UInt32(0x20) << 24)
