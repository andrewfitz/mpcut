import Foundation

/// The JSON text of a project, read and written without decoding it: a parser that keeps each
/// string and number as it was written, and the writers that lay a project out as MPCut saves it.
enum ProjectSavedLayout {
    private static let maximumDepth = 512

    // MARK: Document text

    indirect enum Node: Equatable {
        /// A string, number or literal exactly as written.
        case scalar([UInt8])
        case array([Node])
        case object([Member])
    }

    struct Member: Equatable {
        /// The name as written, with its quotes.
        var key: [UInt8]
        var value: Node
    }

    struct Malformed: Error {}

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x0A, 0x0D, 0x09: index += 1
                default: return
                }
            }
        }

        mutating func string() throws -> [UInt8] {
            guard index < bytes.count, bytes[index] == 0x22 else { throw Malformed() }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case 0x22:
                    index += 1
                    return Array(bytes[start..<index])
                case 0x5C:
                    index += 2
                default:
                    index += 1
                }
            }
            throw Malformed()
        }

        mutating func value(depth: Int = 0) throws -> Node {
            guard depth < ProjectSavedLayout.maximumDepth else { throw Malformed() }
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            switch bytes[index] {
            case 0x7B:
                index += 1
                var members: [Member] = []
                skipSpace()
                if index < bytes.count, bytes[index] == 0x7D {
                    index += 1
                    return .object(members)
                }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == 0x3A else { throw Malformed() }
                    index += 1
                    members.append(Member(key: key, value: try value(depth: depth + 1)))
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == 0x7D {
                        index += 1
                        return .object(members)
                    }
                    guard bytes[index] == 0x2C else { throw Malformed() }
                    index += 1
                }
            case 0x5B:
                index += 1
                var items: [Node] = []
                skipSpace()
                if index < bytes.count, bytes[index] == 0x5D {
                    index += 1
                    return .array(items)
                }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == 0x5D {
                        index += 1
                        return .array(items)
                    }
                    guard bytes[index] == 0x2C else { throw Malformed() }
                    index += 1
                }
            case 0x22:
                return .scalar(try string())
            default:
                let start = index
                scan: while index < bytes.count {
                    switch bytes[index] {
                    case 0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09: break scan
                    // A quote, colon or opening bracket cannot occur inside a number or literal.
                    case 0x22, 0x3A, 0x7B, 0x5B: throw Malformed()
                    default: index += 1
                    }
                }
                guard index > start else { throw Malformed() }
                return .scalar(Array(bytes[start..<index]))
            }
        }
    }

    static func parse(_ data: Data) -> Node? {
        data.withUnsafeBytes { raw -> Node? in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            guard let node = try? parser.value() else { return nil }
            parser.skipSpace()
            return parser.index == parser.bytes.count ? node : nil
        }
    }

    private static func write(_ node: Node, to output: inout Data) {
        switch node {
        case .scalar(let text):
            output.append(contentsOf: text)
        case .array(let items):
            output.append(0x5B)
            for (position, item) in items.enumerated() {
                if position > 0 { output.append(0x2C) }
                write(item, to: &output)
            }
            output.append(0x5D)
        case .object(let members):
            output.append(0x7B)
            for (position, member) in members.enumerated() {
                if position > 0 { output.append(0x2C) }
                output.append(contentsOf: member.key)
                output.append(0x3A)
                write(member.value, to: &output)
            }
            output.append(0x7D)
        }
    }

    /// The number of bytes `text` writes for a value.
    private static func length(_ node: Node) -> Int {
        switch node {
        case .scalar(let text):
            return text.count
        case .array(let items):
            return items.reduce(2 + max(0, items.count - 1)) { $0 + length($1) }
        case .object(let members):
            return members.reduce(2 + max(0, members.count - 1)) { $0 + $1.key.count + 1 + length($1.value) }
        }
    }

    /// The document with one member or element to a line, as version control wants it: a
    /// change to one clip is a change to a few lines, and two edits to different clips merge.
    /// Every string and number is carried as written and names are put in order, so text
    /// that is already in this form comes back the same.
    static func readable(_ document: Data) -> Data? {
        guard let root = parse(document), case .object = root else { return nil }
        return readable(root, capacity: document.count * 2)
    }

    static func readable(_ root: Node, capacity: Int) -> Data {
        var output = Data(capacity: capacity)
        func line(_ depth: Int) {
            output.append(0x0A)
            output.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }
        /// How the blocks MPCut keeps for itself are laid out. An undo step, a recording's
        /// entry in the media snapshot and an entry of the refs table each take one line, so
        /// a save changes a line for each thing it changed and the edit stays in view.
        enum Rows { case none, items, lists }
        func layout(_ key: [UInt8], depth: Int) -> Rows {
            guard depth == 0 else { return .none }
            if key == ProjectKeyedLayout.table { return .items }
            return key == history || key == mediaSnapshot ? .lists : .none
        }
        func write(_ node: Node, depth: Int, rows: Rows = .none) {
            switch node {
            case .scalar(let text):
                output.append(contentsOf: text)
            case .array(let items) where rows == .items:
                output.append(0x5B)
                for (position, item) in items.enumerated() {
                    if position > 0 { output.append(0x2C) }
                    line(depth + 1)
                    ProjectSavedLayout.write(item, to: &output)
                }
                if !items.isEmpty { line(depth) }
                output.append(0x5D)
            case .array(let items):
                output.append(0x5B)
                // A run of numbers, such as the span of clips an undo step keeps, reads as one thing.
                let numbers = items.allSatisfy { if case .scalar(let text) = $0 { return !isString(text) } else { return false } }
                for (position, item) in items.enumerated() {
                    if position > 0 { output.append(contentsOf: numbers ? [0x2C, 0x20] : [0x2C]) }
                    if !numbers { line(depth + 1) }
                    write(item, depth: depth + 1)
                }
                if !items.isEmpty, !numbers { line(depth) }
                output.append(0x5D)
            case .object(let unordered) where unordered.count == 1 && unordered[0].key == marker:
                // A reference to the refs table stands where a value would.
                output.append(0x7B)
                output.append(contentsOf: marker)
                output.append(contentsOf: [0x3A, 0x20])
                write(unordered[0].value, depth: depth)
                output.append(0x7D)
            case .object(let unordered):
                // MPCut writes names in order. A project written by hand or by another tool
                // should not differ from it by the order of its names alone.
                let ordered = zip(unordered, unordered.dropFirst()).allSatisfy {
                    !$1.key.lexicographicallyPrecedes($0.key)
                }
                let members = ordered ? unordered : unordered.sorted { $0.key.lexicographicallyPrecedes($1.key) }
                output.append(0x7B)
                for (position, member) in members.enumerated() {
                    if position > 0 { output.append(0x2C) }
                    line(depth + 1)
                    output.append(contentsOf: member.key)
                    output.append(contentsOf: [0x3A, 0x20])
                    switch rows {
                    case .items:
                        ProjectSavedLayout.write(member.value, to: &output)
                    case .lists:
                        if case .array = member.value { write(member.value, depth: depth + 1, rows: .items) }
                        else { write(member.value, depth: depth + 1) }
                    case .none:
                        write(member.value, depth: depth + 1, rows: layout(member.key, depth: depth))
                    }
                }
                if !members.isEmpty { line(depth) }
                output.append(0x7D)
            }
        }
        write(root, depth: 0)
        output.append(0x0A)
        return output
    }

    static func text(_ node: Node, capacity: Int) -> Data {
        var output = Data(capacity: capacity)
        write(node, to: &output)
        return output
    }

    // MARK: Names

    static let history = Array(#""history""#.utf8)
    static let marker = Array(#""~""#.utf8)
    static let mediaSnapshot = Array(#""media_snapshot""#.utf8)

    static func isString(_ text: [UInt8]) -> Bool {
        text.count >= 2 && text.first == 0x22
    }
}
