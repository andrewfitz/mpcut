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

    package static func readListData(_ url: URL, kind: String, cancelled: () -> Bool = { false }) throws -> Data {
        try checkCancellation(cancelled)
        let expectedFile = CutError(code: "\(kind.lowercased())_read_failed", message: "Expected a regular \(kind) file at \(url.path).")
        guard url.isFileURL else { throw expectedFile }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw CutError(code: "\(kind.lowercased())_read_failed", message: "Couldn’t open \(url.path): \(String(cString: strerror(errno)))")
        }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw expectedFile }
        let limit = MulticamProject.maximumFileSize
        let tooLarge = CutError(code: "invalid_\(kind.lowercased())", message: "The \(kind) exceeds the 64 MB file limit.")
        guard info.st_size <= limit else { throw tooLarge }
        var data = Data()
        while data.count <= limit {
            try checkCancellation(cancelled)
            let length = min(1 << 20, limit + 1 - data.count)
            do {
                guard let block = try reader.read(upToCount: length), !block.isEmpty else { break }
                data.append(block)
            } catch {
                throw CutError(code: "\(kind.lowercased())_read_failed", message: "Couldn’t read \(url.path): \(error.localizedDescription)")
            }
        }
        guard data.count <= limit else { throw tooLarge }
        return data
    }

    private static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CutError(code: "cancelled", message: "CSV import was cancelled.") }
    }

    public static func ranges(in text: String, clip: AudioSpan, rangesOnly: Bool = false,
                              cancelled: () -> Bool = { false }) throws -> [AudioSpan] {
        func lineError(_ line: Int, _ message: String) -> CutError {
            CutError(code: "invalid_csv", message: "CSV line \(line): \(message)")
        }
        let duration = try clip.to.subtracting(clip.from)
        guard duration > .zero else { throw lineError(1, "The target clip must have positive duration.") }
        var width: Int?
        var ranges: [AudioSpan] = []
        var previous = clip.from
        var total = RationalTime.zero
        func append(_ from: RationalTime, _ to: RationalTime, line: Int) throws {
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
        var content = text.drop(while: { $0 == "\u{feff}" })
        var number = 0
        var lastPointLine = 0
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
                guard let offset = try? RationalTime(parsing: field), offset >= .zero, offset <= duration else {
                    throw lineError(number, "Expected a timestamp between 0 and \(duration) seconds, got ‘\(field)’.")
                }
                guard let absolute = try? clip.from.adding(offset) else {
                    throw lineError(number, "The timestamp exceeds the supported precision on this clip.")
                }
                return absolute
            }
            if times.count == 1 {
                guard times[0] > previous, times[0] < clip.to else {
                    throw lineError(number, "Cut points must increase and fall inside the clip.")
                }
                try append(previous, times[0], line: number)
                previous = times[0]
                lastPointLine = number
            } else {
                guard times[0] < times[1] else { throw lineError(number, "The end must follow the start.") }
                try append(times[0], times[1], line: number)
            }
        }
        guard !ranges.isEmpty else { throw CutError(code: "invalid_csv", message: "The CSV contains no edit rows.") }
        if width == 1 { try append(previous, clip.to, line: lastPointLine) }
        return ranges
    }
}
