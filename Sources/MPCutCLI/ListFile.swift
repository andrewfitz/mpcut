import Foundation
import MPCutCore

/// File arguments carry data, including paths that happen to look like command-line flags.
enum ListFile {
    static func isListPath(_ path: String) -> Bool {
        ["csv", "json"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func invalid(_ message: String) -> CLIError { CLIError("invalid_list", message) }

    private struct Entries<Element: Decodable>: Decodable {
        let items: [Element]
        init(from decoder: Decoder) throws {
            var input = try decoder.unkeyedContainer()
            guard let count = input.count, (1...ClipEditCSV.maximumPieces).contains(count) else {
                throw invalid("Supply between 1 and \(ClipEditCSV.maximumPieces) list entries.")
            }
            var items: [Element] = []
            items.reserveCapacity(count)
            while !input.isAtEnd { items.append(try input.decode(Element.self)) }
            self.items = items
        }
    }

    private static func json<T: Decodable>(_ type: T.Type, data: Data) throws -> [T] {
        do { return try JSONDecoder().decode(Entries<T>.self, from: data).items }
        catch let issue as CLIError { throw issue }
        catch { throw invalid("Unexpected JSON list entry: \(error)") }
    }

    private static func jsonData(_ url: URL, cancelled: () -> Bool = { false }) throws -> Data {
        let data = try ClipEditCSV.readListData(url, kind: "JSON", cancelled: cancelled)
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw invalid("Expected UTF-8 JSON.") }
        return data
    }

    private static func validateJSON(_ data: Data) throws {
        // Decode first so malformed input never reaches the duplicate-key and trailing-comma scanner.
        if let issue = jsonInputIssue(data) { throw invalid("JSON \(issue).") }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 {  // JSON string
                    index += 1
                    while index < bytes.count, bytes[index] != 34 {
                        index += bytes[index] == 92 ? 2 : 1
                    }
                } else if byte == 45 || (48...57).contains(byte) {
                    let start = index
                    while index < bytes.count,
                          bytes[index] == 45 || bytes[index] == 46 || (48...57).contains(bytes[index]) {
                        index += 1
                    }
                    let coefficient = bytes[start..<index]
                    if let first = coefficient.firstIndex(where: { (49...57).contains($0) }),
                       let last = coefficient.lastIndex(where: { (49...57).contains($0) }) {
                        // Decimal can silently round longer coefficients. A quoted timestamp
                        // goes straight to the exact rational parser.
                        let significand = bytes[first...last]
                        let digits = significand.count - (significand.contains(46) ? 1 : 0)
                        guard digits <= 38 else {
                            throw invalid("A JSON number exceeds 38 significant digits. Use a quoted timestamp for exact values.")
                        }
                    }
                    if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
                        index += 1
                        while index < bytes.count,
                              bytes[index] == 43 || bytes[index] == 45 || (48...57).contains(bytes[index]) {
                            index += 1
                        }
                    }
                    continue
                }
                index += 1
            }
        }
    }

    private static func values<T>(_ path: String, csv: ([[String]]) throws -> [T], json decode: (Data) throws -> [T]) throws -> [T] {
        let url = try fileURL(path, label: "List")
        let result: [T]
        switch url.pathExtension.lowercased() {
        case "json":
            let data = try jsonData(url)
            result = try decode(data)
            try validateJSON(data)
        case "csv":
            let data = try ClipEditCSV.readListData(url, kind: "CSV")
            guard let text = String(data: data, encoding: .utf8) else { throw invalid("Expected UTF-8 CSV.") }
            result = try csv(rows(text))
        default: throw invalid("Choose a .csv or .json list file.")
        }
        guard !result.isEmpty, result.count <= ClipEditCSV.maximumPieces else {
            throw invalid("Supply between 1 and \(ClipEditCSV.maximumPieces) list entries.")
        }
        return result
    }

    private static func rows(_ text: String) throws -> [[String]] {
        var records: [[String]] = [], fields: [String] = []
        var field = "", quoted = false, closed = false
        let scalars = text.unicodeScalars
        var cursor = scalars.startIndex
        if scalars.first == "\u{feff}" { scalars.formIndex(after: &cursor) }
        func finishField() {
            fields.append(closed ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            closed = false
        }
        func finishRow() throws {
            let blank = fields.isEmpty && !closed && field.trimmingCharacters(in: .whitespaces).isEmpty
            finishField()
            if !blank { records.append(fields) }
            fields.removeAll(keepingCapacity: true)
            guard records.count <= ClipEditCSV.maximumPieces + 1 else { throw invalid("Too many CSV rows.") }
        }
        while cursor < scalars.endIndex {
            let c = scalars[cursor]
            scalars.formIndex(after: &cursor)
            if quoted {
                if c != "\"" { field.unicodeScalars.append(c) }
                else if cursor < scalars.endIndex, scalars[cursor] == "\"" {
                    field.unicodeScalars.append(c)
                    scalars.formIndex(after: &cursor)
                } else { quoted = false; closed = true }
            } else if c == "," {
                guard fields.count < 8 else { throw invalid("Too many columns in CSV row \(records.count + 1).") }
                finishField()
            } else if CharacterSet.newlines.contains(c) {
                if c == "\r", cursor < scalars.endIndex, scalars[cursor] == "\n" {
                    scalars.formIndex(after: &cursor)
                }
                try finishRow()
            } else if c == "\"", field.isEmpty, !closed {
                quoted = true
            } else if closed || c == "\"" {
                throw invalid("Invalid quotation in CSV row \(records.count + 1).")
            } else { field.unicodeScalars.append(c) }
        }
        guard !quoted else { throw invalid("Unclosed CSV quote.") }
        try finishRow()
        return records
    }

    private struct Scalar: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let scalar = try decoder.singleValueContainer()
            if let string = try? scalar.decode(String.self) { value = string }
            else if let time = try? ListFile.exactRational(from: decoder) { value = time.description }
            else { value = try scalar.decode(Decimal.self).description }
        }
    }

    static func exactRational(from decoder: Decoder, in label: String = "Timestamp") throws -> RationalTime {
        enum Fields: String, CodingKey, CaseIterable { case numerator, denominator }
        let fields = try decoder.requestFields(Fields.self, in: label)
        let numerator = try fields.decode(Decimal.self, forKey: .numerator)
        let denominator = try fields.decode(Decimal.self, forKey: .denominator)
        guard let top = Int64(numerator.description), let bottom = Int64(denominator.description), bottom > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Expected an integer timestamp numerator and a positive integer denominator."))
        }
        return RationalTime(numerator: top, denominator: bottom)
    }

    static func scalars(_ path: String, header: String) throws -> [String] {
        try values(path, csv: { rows in
            try rows.dropFirst(rows.first?.map { $0.lowercased() } == [header] ? 1 : 0).map {
                guard $0.count == 1, !$0[0].isEmpty else { throw invalid("Expected one \(header) per CSV row.") }
                return $0[0]
            }
        }, json: { try json(Scalar.self, data: $0).map(\.value) })
    }

    static func clips(_ path: String) throws -> [InputClip] {
        try values(path, csv: { records in
            guard let first = records.first else { return [] }
            let header = first.map { $0.lowercased() }
            let hasHeader = header.first == "file" || header.first == "project"
            let columns = hasHeader ? header : ["file"]
            guard Set(columns).isSubset(of: ["file", "project", "from", "to"]), Set(columns).count == columns.count else {
                throw invalid("Use CSV clip columns file or project, with optional from and to.")
            }
            return try records.dropFirst(hasHeader ? 1 : 0).map { row in
                guard row.count == columns.count else { throw invalid("Invalid CSV clip row.") }
                let fields = Dictionary(uniqueKeysWithValues: zip(columns, row)).filter { !$0.value.isEmpty }
                guard (fields["file"] == nil) != (fields["project"] == nil) else {
                    throw invalid("Choose one file or project for each clip.")
                }
                var clip = InputClip(file: "")
                clip.file = fields["file"]
                clip.project = fields["project"]
                clip.from = fields["from"]
                clip.to = fields["to"]
                return clip
            }
        }, json: { data in
            if let paths = try? json(String.self, data: data) { return paths.map(InputClip.init(file:)) }
            return try json(InputClip.self, data: data)
        })
    }

    static func scenes(_ path: String) throws -> [SceneExportInput.Scene] {
        struct Row: Decodable {
            let start: Scalar
            let end: Scalar
            let view: Decimal
            let number: Decimal?
        }
        return try values(path, csv: { records in
            guard let header = records.first, Set(header).isSuperset(of: ["start", "end", "view"]),
                  Set(header).isSubset(of: ["start", "end", "view", "number"]), Set(header).count == header.count else {
                throw invalid("Use CSV scene columns start,end,view and optional number.")
            }
            return try records.dropFirst().map { row in
                guard row.count == header.count else { throw invalid("Invalid scene row.") }
                let cells = Dictionary(uniqueKeysWithValues: zip(header, row))
                let rawNumber = cells["number"] ?? ""
                let number = Int(rawNumber)
                guard let view = Int(cells["view"]!), rawNumber.isEmpty || number != nil else {
                    throw invalid("Scene view and number must be integers.")
                }
                return try SceneExportInput.Scene(number: number, view: view,
                                                  start: RationalTime(parsing: cells["start"]!), end: RationalTime(parsing: cells["end"]!))
            }
        }, json: { data in
            try json(Row.self, data: data).map {
                let number = $0.number.flatMap { Int($0.description) }
                guard let view = Int($0.view.description), $0.number == nil || number != nil else {
                    throw invalid("Scene view and number must be integers.")
                }
                return try SceneExportInput.Scene(number: number, view: view, start: RationalTime(parsing: $0.start.value),
                                                  end: RationalTime(parsing: $0.end.value))
            }
        })
    }

    private struct RangeRow: Decodable {
        let from: Scalar
        let to: Scalar
        enum Keys: String, CodingKey, CaseIterable { case from, to }
        init(from decoder: Decoder) throws {
            let fields = try decoder.requestFields(Keys.self, in: "Range")
            from = try fields.decode(Scalar.self, forKey: .from)
            to = try fields.decode(Scalar.self, forKey: .to)
        }
    }

    static func ranges(_ url: URL, clip: AudioSpan, rangesOnly: Bool = false,
                       cancelled: () -> Bool) throws -> [AudioSpan] {
        if url.pathExtension.lowercased() == "csv" {
            return try ClipEditCSV.ranges(in: url, clip: clip, rangesOnly: rangesOnly, cancelled: cancelled)
        }
        guard url.pathExtension.lowercased() == "json" else { throw invalid("Choose a .csv or .json range list.") }
        let data = try jsonData(url, cancelled: cancelled)
        // Canonicalize validated timestamps before handing them to the shared edit-list validator.
        func time(_ value: Scalar) throws -> String { try RationalTime(parsing: value.value).description }
        let lines: [String]
        if !rangesOnly, let points = try? json(Scalar.self, data: data) {
            lines = try points.map(time)
        } else {
            lines = try json(RangeRow.self, data: data).map { try time($0.from) + "," + time($0.to) }
        }
        try validateJSON(data)
        return try ClipEditCSV.ranges(in: lines.joined(separator: "\n"), clip: clip, rangesOnly: rangesOnly,
                                     cancelled: cancelled)
    }
}
