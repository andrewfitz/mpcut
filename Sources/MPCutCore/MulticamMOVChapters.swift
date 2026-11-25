import CFFmpeg
import Foundation

/// The chapters of a multicam program and what a copy of it leaves out.
///
/// A program is cut from several cameras that recorded one event, so its chapters come from one clock: the
/// reference angle's. Each of its chapters is placed on the program clock through the group time the program
/// shows, whichever camera is on screen, and is clipped and rejoined as an ordinary copy of the same ranges would
/// be (ReencodeChapter.remapped). Taking the chapters of whichever camera is on screen instead would split a
/// chapter at every switch and mix the lists of cameras that state the same event twice.
struct MulticamProgramChapters: Sendable {
    var chapters: [ReencodeChapter] = []
    var omissions: [String] = []
}

extension MulticamEngine {
    /// Plans the program's chapters for `container`. A picture-free program, or a container without chapters,
    /// keeps none and says so. Only cancellation is thrown: a chapter list that cannot be read or placed is reported.
    func programChapters(_ mapping: MulticamPlan, project: MulticamProject?, sources: [String: URL],
                         media: [String: MediaInfo], container: String, hasPicture: Bool) throws -> MulticamProgramChapters {
        var result = MulticamProgramChapters()
        let name = container.uppercased()
        // The reference angle's recordings with their group offsets. A program assembled without a project
        // takes the first camera on screen as its reference.
        var reference: [(id: String, offset: RationalTime, coverage: MulticamRange?)] = []
        if let project {
            reference = project.recordings(for: project.referenceAngle).map { ($0.id, $0.offset, $0.coverage) }
        } else if let id = mapping.intervals.first(where: { $0.pictureSourceID != nil })?.pictureSourceID,
                  let span = mapping.picture.first(where: { $0.source == id }),
                  let group = try? groupRange(span, in: mapping), let offset = try? group.from.subtracting(span.input.from) {
            reference = [(id, offset, nil)]
        }
        let referenceIDs = Set(reference.map(\.id))
        // Other cameras' own chapter lists stay behind. Name them, once per file.
        var named = Set<URL>()
        for span in mapping.picture where !referenceIDs.contains(span.source) {
            guard let file = sources[span.source]?.standardizedFileURL, named.insert(file).inserted else { continue }
            let count = Self.chapterCount(file)
            if count > 0 {
                result.omissions.append("Chapters come from the reference angle. \(count) chapter\(count == 1 ? "" : "s") "
                                        + "of \(file.lastPathComponent) \(count == 1 ? "is" : "are") not copied.")
            }
        }

        var segments: [ResolvedSegment] = []
        var clocks: [URL: MediaInfo] = [:]
        for recording in reference {
            try checkChapterCancellation()
            guard let file = sources[recording.id]?.standardizedFileURL, Self.chapterCount(file) > 0 else { continue }
            // Chapter times are on the file's presentation clock; the multicam clock says where its input times start.
            guard let clock = media[recording.id] ?? (try? CutEngine(cancelled: cancelled).multicamClock(
                Probe.read(file, keyframes: false, previewOnly: true, cancelled: cancelled))) else {
                result.omissions.append("The chapters of \(file.lastPathComponent) could not be read and are not copied.")
                continue
            }
            clocks[file] = clock
            for interval in mapping.intervals {
                let lower = max(interval.group.from, recording.coverage?.from ?? interval.group.from)
                let upper = min(interval.group.to, recording.coverage?.to ?? interval.group.to)
                guard lower < upper,
                      let from = try? lower.subtracting(recording.offset), let to = try? upper.subtracting(recording.offset),
                      let start = try? interval.output.from.adding(lower.subtracting(interval.group.from)) else { continue }
                segments.append(ResolvedSegment(file: file, from: from, to: to, outputStart: start, tracks: [],
                                                sourceOrigin: clock.origin, reachesEnd: false))
            }
        }
        guard !segments.isEmpty else { return result }
        let placed: (chapters: [ReencodeChapter], warnings: [String])
        do {
            placed = try ReencodeChapter.remapped(segments, media: clocks, cancelled: cancelled)
        } catch let issue as CutError where issue.code != "cancelled" {
            result.omissions.append("The chapters could not be placed on the output timeline and are not copied.")
            return result
        }
        result.omissions += placed.warnings
        let count = placed.chapters.count
        guard count > 0 else { return result }
        let some = "\(count) chapter\(count == 1 ? " is" : "s are") not copied."
        if !hasPicture {
            result.omissions.append("Chapters are copied only with the program picture. " + some)
        } else if MulticamMux.movieContainers.contains(container) {
            let planned = MulticamChapterTrack.plan(placed.chapters, container: container)
            result.omissions += planned.notes
            if planned.track != nil { result.chapters = placed.chapters }
        } else if ["mkv", "webm"].contains(container) {
            if (try? ReencodeEngine.findHelper(override: nil)) == nil {
                result.omissions.append("Chapters cannot be written to \(name) without the FFmpeg helper. " + some)
            } else {
                result.chapters = placed.chapters
            }
        } else {
            result.omissions.append("Chapters cannot be written to \(name). " + some)
        }
        return result
    }

    private func checkChapterCancellation() throws {
        if cancelled?() == true { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
    }

    /// How many chapters a file lists. Only its header is read.
    static func chapterCount(_ file: URL) -> Int {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, file.path, nil, nil) >= 0, let input = context else { return 0 }
        defer { avformat_close_input(&context) }
        return Int(input.pointee.nb_chapters)
    }
}

/// A QuickTime chapter track for a combined multicam movie, in the form the packet writer gives a copied movie:
/// a disabled text track on a millisecond clock whose samples are the chapter titles, named by a 'chap'
/// reference from each picture and sound track. A sample lasts until the next one starts.
struct MulticamChapterTrack: Sendable {
    let samples: Data
    let sizes: [UInt32]
    let durations: [UInt32]
    let mp4: Bool

    /// The samples that the chapters make, and a note for each way the track differs from the list:
    /// the first sample always starts the movie, a gap closes, and a chapter that does not start after the one
    /// before it on the millisecond clock cannot be stored. The notes match a packet copy's.
    static func plan(_ chapters: [ReencodeChapter], container: String) -> (track: MulticamChapterTrack?, notes: [String]) {
        let name = container.uppercased()
        var starts: [Int64] = [], ends: [Int64] = [], titles: [Data] = []
        var unstored = 0, moved: Int64 = 0, closed = 0
        for chapter in chapters {
            guard var start = try? chapter.start.roundedToSamples(1000), let end = try? chapter.end.roundedToSamples(1000),
                  end > start, start > (starts.last ?? -1), end - start < Int64(Int32.max),
                  chapter.title.utf8.count <= Int(UInt16.max) else {
                unstored += 1
                continue
            }
            if starts.isEmpty {
                moved = start
                start = 0
            }
            if let previous = ends.last, start > previous { closed += 1 }
            starts.append(start)
            ends.append(end)
            titles.append(Data(chapter.title.utf8))
        }
        var notes: [String] = []
        if unstored > 0 {
            notes.append("\(unstored) chapter\(unstored == 1 ? "" : "s") cannot be written to \(name) and \(unstored == 1 ? "is" : "are") not copied.")
        }
        if moved > 0 {
            notes.append("\(name) chapters begin with the file, so the first chapter starts at 0 instead of "
                         + String(format: "%lld.%03lld s.", moved / 1000, moved % 1000))
        }
        if closed > 0 {
            notes.append("\(name) chapters follow one another without a gap, so \(closed) chapter\(closed == 1 ? " runs" : "s run") on to the start of the next.")
        }
        guard !starts.isEmpty else { return (nil, notes) }
        var samples = Data(), sizes: [UInt32] = [], durations: [UInt32] = []
        for index in starts.indices {
            let next = index + 1 < starts.count ? starts[index + 1] : ends[index]
            var sample = Data()
            sample.appendBigEndian(UInt16(titles[index].count))
            sample.append(titles[index])
            // The text encoding atom: UTF-8.
            sample.appendBigEndian(UInt32(12))
            sample.append(contentsOf: "encd".utf8)
            sample.appendBigEndian(UInt32(0x100))
            samples.append(sample)
            sizes.append(UInt32(sample.count))
            durations.append(UInt32(clamping: next - starts[index]))
        }
        return (MulticamChapterTrack(samples: samples, sizes: sizes, durations: durations,
                                     mp4: ["mp4", "m4v"].contains(container)), notes)
    }

    /// The finished 'trak' box, with its samples at `offset` in the file, and its duration on the movie clock.
    func trak(id: UInt32, movieRate: UInt32, offset: UInt64) throws -> (data: Data, duration: UInt64) {
        let box = MulticamMOV.box
        let milliseconds = durations.reduce(UInt64(0)) { $0 + UInt64($1) }
        let (scaled, overflow) = milliseconds.multipliedReportingOverflow(by: UInt64(movieRate))
        guard !overflow else { throw MulticamMOV.invalidMovie }
        let duration = (scaled + 500) / 1000

        var header = Data([1, 0, 0, 2]) // Version 1; in the movie, not enabled, as a packet copy writes it.
        header.append(Data(count: 16))
        header.appendBigEndian(id)
        header.append(Data(count: 4))
        header.appendBigEndian(duration)
        header.append(Data(count: 16)) // Reserved, layer, alternate group, volume, reserved.
        for value: UInt32 in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000] { header.appendBigEndian(value) }
        header.append(Data(count: 8)) // No picture size.

        var edits = Data([1, 0, 0, 0])
        edits.appendBigEndian(UInt32(1))
        edits.appendBigEndian(duration)
        edits.appendBigEndian(UInt64(0))
        edits.appendBigEndian(UInt32(0x10000))

        var mediaHeader = Data(count: 12)
        mediaHeader.appendBigEndian(UInt32(1000))
        mediaHeader.appendBigEndian(UInt32(clamping: milliseconds))
        mediaHeader.append(Data(count: 4))

        func handler(_ component: String, _ subtype: String, _ name: String) -> Data {
            var data = Data(count: 4)
            if mp4 {
                data.append(Data(count: 4))
                data.append(contentsOf: subtype.utf8)
                data.append(Data(count: 12))
                data.append(contentsOf: name.utf8)
                data.append(0)
            } else {
                data.append(contentsOf: component.utf8)
                data.append(contentsOf: subtype.utf8)
                data.append(Data(count: 12))
                data.append(UInt8(name.utf8.count))
                data.append(contentsOf: name.utf8)
            }
            return data
        }
        let baseInfo = try box("gmin", Data(hex: "00000000004080008000800000000000"))
            + box("text", Data(hex: "000100000000000000000000000000000001000000000000000000000000000040000000"))
        let references = try box("dref", Data(hex: "00000000000000010000000c75726c2000000001"))
        // The text sample description the muxer writes for chapters.
        let description = Data(hex: "00000000000000010000003b746578740000000000000001000000010000000000000000000000000000000000"
                               + "0000010000000000000000000d667461620001000100")
        var times = Data(count: 4)
        var runs: [(count: UInt32, delta: UInt32)] = []
        for delta in durations {
            if let last = runs.last, last.delta == delta { runs[runs.count - 1].count += 1 } else { runs.append((1, delta)) }
        }
        times.appendBigEndian(UInt32(runs.count))
        for run in runs {
            times.appendBigEndian(run.count)
            times.appendBigEndian(run.delta)
        }
        var chunks = Data(count: 4)
        chunks.appendBigEndian(UInt32(1))
        for value: UInt32 in [1, UInt32(sizes.count), 1] { chunks.appendBigEndian(value) }
        var sampleSizes = Data(count: 8)
        sampleSizes.appendBigEndian(UInt32(sizes.count))
        for size in sizes { sampleSizes.appendBigEndian(size) }
        var offsets = Data(count: 4)
        offsets.appendBigEndian(UInt32(1))
        let wide = offset > UInt64(UInt32.max)
        if wide { offsets.appendBigEndian(offset) } else { offsets.appendBigEndian(UInt32(offset)) }
        let table = try box("stsd", description) + box("stts", times) + box("stsc", chunks)
            + box("stsz", sampleSizes) + box(wide ? "co64" : "stco", offsets)
        var information = try box("gmhd", baseInfo)
        if !mp4 { information += try box("hdlr", handler("dhlr", "url ", "DataHandler")) }
        information += try box("dinf", references) + box("stbl", table)
        let mediaBox = try box("mdhd", mediaHeader) + box("hdlr", handler("mhlr", "text", "SubtitleHandler"))
            + box("minf", information)
        let track = try box("tkhd", header) + box("mdia", mediaBox) + box("edts", box("elst", edits))
        return (try box("trak", track), duration)
    }

    /// A picture or sound track's payload with a 'chap' reference to the chapter track added. Other tracks are unchanged.
    static func referencing(_ trak: Data, chapterTrack id: UInt32) throws -> Data {
        let parts = try MulticamMOV.children(of: trak)
        guard let media = parts.first(where: { $0.type == "mdia" }),
              let handler = try MulticamMOV.children(of: media.data).first(where: { $0.type == "hdlr" }),
              handler.data.count >= 12 else { throw MulticamMOV.invalidMovie }
        let subtype = String(decoding: handler.data[handler.data.startIndex + 8..<handler.data.startIndex + 12], as: Unicode.ASCII.self)
        guard subtype == "vide" || subtype == "soun" else { return trak }
        var chapter = Data()
        chapter.appendBigEndian(id)
        let reference = try MulticamMOV.box("chap", chapter)
        var result = Data()
        var added = false
        for part in parts {
            if part.type == "tref" {
                guard try !MulticamMOV.children(of: part.data).contains(where: { $0.type == "chap" }) else { throw MulticamMOV.invalidMovie }
                result += try MulticamMOV.box("tref", part.data + reference)
                added = true
            } else if part.type == "mdia" && !added {
                result += try MulticamMOV.box("tref", reference) + MulticamMOV.box(part.type, part.data)
                added = true
            } else {
                result += try MulticamMOV.box(part.type, part.data)
            }
        }
        return result
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
