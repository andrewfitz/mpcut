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

    /// The chapters a container lists. Nil when the file cannot be opened.
    private static func read(_ file: URL) -> [Listed]? {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, file.path, nil, nil) >= 0, let input = context else { return nil }
        defer { avformat_close_input(&context) }
        var listed: [Listed] = []
        for index in 0..<Int(input.pointee.nb_chapters) {
            guard let chapter = input.pointee.chapters[index]?.pointee,
                  chapter.time_base.num > 0, chapter.time_base.den > 0, chapter.start != Int64.min else { continue }
            let base = RationalTime(numerator: Int64(chapter.time_base.num), denominator: Int64(chapter.time_base.den))
            guard let start = try? RationalTime(numerator: chapter.start).multiplied(by: base) else { continue }
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
        return listed
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
        let whole = segments.count == 1 && segments[0].from == .zero && segments[0].reachesEnd
        for segment in segments {
            if cancelled?() == true { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
            if !sources.contains(segment.file) {
                sources.append(segment.file)
                known[segment.file] = read(segment.file) ?? []
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
            return ([], unplaced.map { "The chapters of \($0) could not be placed on the output timeline and will be omitted." })
        }
        return (chapters, [])
    }

    /// The chapters as an FFMETADATA document, which the helper reads as an input without streams.
    static func metadata(_ chapters: [ReencodeChapter]) -> String {
        func escaped(_ text: String) -> String {
            var result = ""
            for character in text {
                if "=;#\\\n".contains(character) { result.append("\\") }
                result.append(character)
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
            func ticks(_ time: RationalTime) -> Int64 {
                if exact { return time.numerator * (clock / time.denominator) }
                return Int64((Double(time.numerator) / Double(time.denominator) * Double(clock)).rounded())
            }
            lines += ["[CHAPTER]", "TIMEBASE=1/\(clock)", "START=\(ticks(chapter.start))", "END=\(ticks(chapter.end))"]
            lines += chapter.tags.map { "\(escaped($0.key))=\(escaped($0.value))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
