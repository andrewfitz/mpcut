import Darwin
import Foundation

/// A single-clip edit list. Times in the file are relative to the supplied clip's in-point.
public enum ClipEditCSV {
    public static let maximumPieces = 100_000

    public static func ranges(in url: URL, clip: AudioSpan, rangesOnly: Bool = false,
                              cancelled: () -> Bool = { false }) throws -> [AudioSpan] {
        let data = try readListData(url, kind: "CSV", cancelled: cancelled)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CutError(code: "invalid_csv", message: "The CSV must be saved as UTF-8 text.")
        }
        return try ranges(in: text, clip: clip, rangesOnly: rangesOnly, cancelled: cancelled)
    }

    package static func readListData(_ url: URL, kind: String, maximumBytes: Int = MulticamProject.maximumFileSize,
                                     cancelled: () -> Bool = { false }) throws -> Data {
        try checkCancellation(cancelled, kind: kind)
        // A two-word kind such as "Transcript plan" still yields one error-code token.
        let code = kind.lowercased().replacingOccurrences(of: " ", with: "_")
        let expectedFile = CutError(code: "\(code)_read_failed", message: "Expected a regular \(kind) file at \(url.path).")
        guard url.isFileURL, url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true,
              url.query == nil, url.fragment == nil, !url.path.contains("\0") else { throw expectedFile }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw CutError(code: "\(code)_read_failed", message: "Couldn’t open \(url.path): \(String(cString: strerror(errno)))")
        }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw expectedFile }
        let tooLarge = CutError(code: "invalid_\(code)",
                               message: "The \(kind) exceeds the \(maximumBytes / (1024 * 1024)) MB file limit.")
        guard info.st_size <= maximumBytes else { throw tooLarge }
        var data = Data()
        while data.count <= maximumBytes {
            try checkCancellation(cancelled, kind: kind)
            let length = min(1 << 20, maximumBytes + 1 - data.count)
            do {
                guard let block = try reader.read(upToCount: length), !block.isEmpty else { break }
                data.append(block)
            } catch {
                throw CutError(code: "\(code)_read_failed", message: "Couldn’t read \(url.path): \(error.localizedDescription)")
            }
        }
        guard data.count <= maximumBytes else { throw tooLarge }
        return data
    }

    private static func checkCancellation(_ cancelled: () -> Bool, kind: String = "CSV") throws {
        if cancelled() { throw CutError(code: "cancelled", message: "\(kind) import was cancelled.") }
    }

    private static func lineError(_ line: Int, _ message: String) -> CutError {
        CutError(code: "invalid_csv", message: "CSV line \(line): \(message)")
    }

    private struct Timeline {
        let clip: AudioSpan
        let duration: RationalTime
        var ranges: [AudioSpan] = []
        var previous: RationalTime
        var total = RationalTime.zero
        var lastPointLine = 0

        init(clip: AudioSpan) throws {
            self.clip = clip
            duration = try clip.to.subtracting(clip.from)
            guard duration > .zero else { throw lineError(1, "The target clip must have positive duration.") }
            previous = clip.from
        }

        func absoluteTime(_ offset: RationalTime?, field: @autoclosure () -> String, line: Int) throws -> RationalTime {
            guard let offset, offset >= .zero, offset <= duration else {
                throw lineError(line, "Expected a timestamp between 0 and \(duration) seconds, got ‘\(field())’.")
            }
            guard let absolute = try? clip.from.adding(offset) else {
                throw lineError(line, "The timestamp exceeds the supported precision on this clip.")
            }
            return absolute
        }

        mutating func appendPoint(_ point: RationalTime, line: Int) throws {
            guard point > previous, point < clip.to else {
                throw lineError(line, "Cut points must increase and fall inside the clip.")
            }
            try append(previous, point, line: line)
            previous = point
            lastPointLine = line
        }

        mutating func append(_ from: RationalTime, _ to: RationalTime, line: Int) throws {
            guard from < to else { throw lineError(line, "The end must follow the start.") }
            guard ranges.count < maximumPieces else {
                throw lineError(line, "A CSV edit can produce at most 100,000 pieces.")
            }
            do {
                total = try total.adding(to.subtracting(from))
            } catch {
                throw lineError(line, "The range or timeline duration exceeds the supported precision.")
            }
            ranges.append(AudioSpan(from: from, to: to))
        }

        mutating func finish() throws -> [AudioSpan] {
            guard !ranges.isEmpty else { throw CutError(code: "invalid_csv", message: "The CSV contains no edit rows.") }
            if lastPointLine != 0 { try append(previous, clip.to, line: lastPointLine) }
            return ranges
        }
    }

    /// List files with structured timestamps share the CSV timeline rules without parsing the timestamps again.
    package static func ranges(points: [RationalTime], clip: AudioSpan, cancelled: () -> Bool) throws -> [AudioSpan] {
        var timeline = try Timeline(clip: clip)
        timeline.ranges.reserveCapacity(min(points.count + 1, maximumPieces))
        for (offset, point) in points.enumerated() {
            try checkCancellation(cancelled)
            let line = offset + 1
            let absolute = try timeline.absoluteTime(point, field: point.description, line: line)
            try timeline.appendPoint(absolute, line: line)
        }
        return try timeline.finish()
    }

    package static func ranges(intervals: [AudioSpan], clip: AudioSpan, cancelled: () -> Bool) throws -> [AudioSpan] {
        var timeline = try Timeline(clip: clip)
        timeline.ranges.reserveCapacity(min(intervals.count, maximumPieces))
        for (offset, interval) in intervals.enumerated() {
            try checkCancellation(cancelled)
            let line = offset + 1
            let from = try timeline.absoluteTime(interval.from, field: interval.from.description, line: line)
            let to = try timeline.absoluteTime(interval.to, field: interval.to.description, line: line)
            try timeline.append(from, to, line: line)
        }
        return try timeline.finish()
    }

    public static func ranges(in text: String, clip: AudioSpan, rangesOnly: Bool = false,
                              cancelled: () -> Bool = { false }) throws -> [AudioSpan] {
        var timeline = try Timeline(clip: clip)
        var width: Int?
        var content = text.drop(while: { $0 == "\u{feff}" })
        var number = 0
        while !content.isEmpty {
            try checkCancellation(cancelled)
            number += 1
            let end = content.firstIndex(where: \.isNewline) ?? content.endIndex
            let line = content[..<end]
            content = content[end...].dropFirst()
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let cells = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map { raw in
                var field = raw.trimmingCharacters(in: .whitespaces)
                if field.count >= 2, field.first == "\"", field.last == "\"" {
                    field = String(field.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                }
                return field
            }
            if rangesOnly, cells.count != 2 {
                throw lineError(number, "Use two columns (from,to) for each interval.")
            }
            if width == nil {
                width = cells.count
                let header = cells.map { $0.lowercased() }
                if [["time"], ["from", "to"], ["start", "end"]].contains(header) { continue }
            }
            guard cells.count == width, cells.count == 1 || cells.count == 2 else {
                throw lineError(number, "Use one timestamp per row or two columns (from,to) throughout.")
            }
            let times = try cells.map { field in
                try timeline.absoluteTime(try? RationalTime(parsing: field), field: field, line: number)
            }
            if times.count == 1 {
                try timeline.appendPoint(times[0], line: number)
            } else {
                try timeline.append(times[0], times[1], line: number)
            }
        }
        return try timeline.finish()
    }
}
