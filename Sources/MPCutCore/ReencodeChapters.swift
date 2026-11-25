import CFFmpeg
import Foundation

/// A source chapter on the output timeline of a movie re-encode.
struct ReencodeChapter: Sendable {
    var start: RationalTime
    var end: RationalTime
    /// The chapter's tags, such as its title, in source order.
    let tags: [Tag]
    /// The position of its source among the plan's sources, and of the chapter in that source.
    let source: Int
    let index: Int

    struct Tag: Sendable, Equatable {
        let key: String
        let value: String
    }

    var title: String { tags.first { $0.key.lowercased() == "title" }?.value ?? "" }

    private struct Listed {
        let start: RationalTime
        /// Nil when the source states no end, or one before the start.
        let end: RationalTime?
        let tags: [Tag]
    }

    /// The chapters a container lists, and how many it lists without a readable start. Nil when the file cannot be opened.
    private static func read(_ file: URL) -> (listed: [Listed], unreadable: Int)? {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, file.path, nil, nil) >= 0, let input = context else { return nil }
        defer { avformat_close_input(&context) }
        var listed: [Listed] = []
        var unreadable = 0
        for index in 0..<Int(input.pointee.nb_chapters) {
            guard let chapter = input.pointee.chapters[index]?.pointee,
                  chapter.time_base.num > 0, chapter.time_base.den > 0, chapter.start != Int64.min else {
                unreadable += 1
                continue
            }
            let base = RationalTime(numerator: Int64(chapter.time_base.num), denominator: Int64(chapter.time_base.den))
            guard let start = try? RationalTime(numerator: chapter.start).multiplied(by: base) else {
                unreadable += 1
                continue
            }
            var end: RationalTime?
            if chapter.end != Int64.min { end = try? RationalTime(numerator: chapter.end).multiplied(by: base) }
            var tags: [Tag] = []
            var entry: UnsafePointer<AVDictionaryEntry>?
            while let next = av_dict_iterate(chapter.metadata, entry) {
                tags.append(Tag(key: String(cString: next.pointee.key), value: String(cString: next.pointee.value)))
                entry = next
            }
            if let stated = end, stated < start { end = nil }
            listed.append(Listed(start: start, end: end, tags: tags))
        }
        return (listed, unreadable)
    }

    /// Places the chapters of each source on the output timeline, as a packet copy of the same ranges does:
    /// a chapter is clipped to each kept range and moved by that range's output offset, a chapter wholly inside
    /// removed material is dropped, and one that continues across adjacent kept ranges stays one chapter.
    static func remapped(_ segments: [ResolvedSegment], media: [URL: MediaInfo],
                         cancelled: (@Sendable () -> Bool)?) throws -> (chapters: [ReencodeChapter], warnings: [String]) {
        var sources: [URL] = []
        var known: [URL: [Listed]] = [:]
        var chapters: [ReencodeChapter] = []
        var unplaced: [String] = []
        var skipped: [String] = []
        let whole = segments.count == 1 && segments[0].from == .zero && segments[0].reachesEnd
        for segment in segments {
            if cancelled?() == true { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
            if !sources.contains(segment.file) {
                sources.append(segment.file)
                let found = read(segment.file)
                known[segment.file] = found?.listed ?? []
                if let count = found?.unreadable, count > 0 {
                    // A chapter without a readable start cannot be placed. Say so rather than leave it out quietly.
                    skipped.append("\(count == 1 ? "1 chapter" : "\(count) chapters") of \(segment.file.lastPathComponent) "
                                   + "\(count == 1 ? "has" : "have") no readable start and will be omitted.")
                }
            }
            guard let listed = known[segment.file], !listed.isEmpty, let source = sources.firstIndex(of: segment.file) else { continue }
            do {
                let origin = media[segment.file]?.origin ?? segment.sourceOrigin ?? .zero
                let sourceStart = try origin.adding(segment.from)
                let sourceEnd = try origin.adding(segment.to)
                let shift = try segment.outputStart.subtracting(sourceStart)
                for (index, chapter) in listed.enumerated() {
                    var start = chapter.start
                    // No stated end: the chapter runs to the next one, or to the end of the range.
                    var end = chapter.end ?? listed.map(\.start).filter { $0 > start }.min() ?? max(sourceEnd, start)
                    if !whole {
                        start = max(start, sourceStart)
                        end = min(end, sourceEnd)
                        if end <= start { continue }
                    }
                    let moved = try start.adding(shift)
                    let from = max(.zero, moved)
                    let to = try end.adding(shift)
                    if to < from { continue }
                    if let last = chapters.last, last.source == source {
                        if last.index == index, last.end == from {
                            chapters[chapters.count - 1].end = to
                            continue
                        }
                        // A movie can list one chapter twice, in its chapter track and in a Nero chapter list.
                        if last.start == from, last.end == to, last.title == (chapter.tags.first { $0.key.lowercased() == "title" }?.value ?? "") {
                            continue
                        }
                    }
                    chapters.append(ReencodeChapter(start: from, end: to, tags: chapter.tags, source: source, index: index))
                }
            } catch let issue as CutError where issue.code != "cancelled" {
                let name = segment.file.lastPathComponent
                if !unplaced.contains(name) { unplaced.append(name) }
            }
        }
        guard unplaced.isEmpty else {
            return ([], unplaced.map { "The chapters of \($0) could not be placed on the output timeline and will be omitted." } + skipped)
        }
        return (chapters, skipped)
    }

    /// The chapters as an FFMETADATA document, which the helper reads as an input without streams.
    static func metadata(_ chapters: [ReencodeChapter]) throws -> String {
        func escaped(_ text: String) -> String {
            var result = ""
            // FFmpeg parses escapes byte by byte. CRLF and a special character
            // followed by a combining mark can each be a single Swift Character.
            for scalar in text.unicodeScalars {
                switch scalar {
                case "=", ";", "#", "\\", "\r", "\n": result.append("\\")
                default: break
                }
                result.unicodeScalars.append(scalar)
            }
            return result
        }
        var lines = [";FFMETADATA1"]
        for chapter in chapters {
            // A clock that states both ends exactly, or nanoseconds when one would not fit.
            var scale = chapter.start.denominator
            var other = chapter.end.denominator
            while other != 0 { (scale, other) = (other, scale % other) }
            let common = chapter.start.denominator.multipliedReportingOverflow(by: chapter.end.denominator / max(1, scale))
            let exact = !common.overflow && common.partialValue <= Int64(Int32.max)
            let clock = exact ? common.partialValue : 1_000_000_000
            let start = try chapter.start.roundedToSamples(Int(clock))
            let end = try chapter.end.roundedToSamples(Int(clock))
            lines += ["[CHAPTER]", "TIMEBASE=1/\(clock)", "START=\(start)", "END=\(end)"]
            lines += chapter.tags.map { "\(escaped($0.key))=\(escaped($0.value))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension ReencodeChapter {
    /// Keys the writer sets itself, or that only describe the file that held them: brands, the writing tool and timecode.
    private static let writerKeys: Set<String> = ["major_brand", "minor_version", "compatible_brands", "encoder",
                                                   "encoding_tool", "software", "timecode"]

    /// The movie metadata of each source that a re-encode leaves out, one sentence for each source that has any: a
    /// re-encode writes no source metadata, so a title, a creation date or a camera's make and model would go quietly.
    static func droppedMetadata(_ segments: [ResolvedSegment]) -> [String] {
        droppedMetadata(of: segments.map(\.file), by: ExportRules.displayName(mode: .encode))
    }

    /// The same for any output that writes none of its sources' metadata, such as a multicam or still program.
    /// `subject` begins each sentence.
    static func droppedMetadata(of files: [URL], by subject: String) -> [String] {
        var seen: Set<URL> = []
        var notes: [String] = []
        for file in files where seen.insert(file.standardizedFileURL).inserted {
            var context: UnsafeMutablePointer<AVFormatContext>?
            guard avformat_open_input(&context, file.path, nil, nil) >= 0, let input = context else { continue }
            defer { avformat_close_input(&context) }
            var keys: [String] = []
            var entry: UnsafePointer<AVDictionaryEntry>?
            while let next = av_dict_iterate(input.pointee.metadata, entry) {
                let key = String(cString: next.pointee.key)
                if !writerKeys.contains(key.lowercased()) { keys.append(key) }
                entry = next
            }
            guard !keys.isEmpty else { continue }
            let listed = keys.prefix(6).joined(separator: ", ") + (keys.count > 6 ? " and \(keys.count - 6) more" : "")
            notes.append("\(subject) does not carry the movie metadata of \(file.lastPathComponent): \(listed).")
        }
        return notes
    }
}
