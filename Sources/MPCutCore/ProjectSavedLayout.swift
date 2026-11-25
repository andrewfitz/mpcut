import Darwin
import Foundation

/// The JSON text of a project, read and written without decoding it: a parser that keeps each
/// string and number as it was written, and the writers that lay a project out as MPCut saves it.
enum ProjectSavedLayout {
    private static let maximumDepth = 512

    // MARK: Document text

    indirect enum Node: Equatable {
        /// A string, number, literal or self-contained embedded asset exactly as written.
        case scalar([UInt8])
        case array([Node])
        case object([Member])
    }

    struct Member: Equatable {
        /// The name as written, with its quotes.
        var key: [UInt8]
        var value: Node

        func hasKey(_ canonical: [UInt8]) -> Bool {
            ProjectSavedLayout.matches(key, canonical)
        }
    }

    /// Reserved names are ASCII. An escaped spelling is always longer and must
    /// decode to the same name before it can select a layout operation.
    static func matches(_ quoted: [UInt8], _ canonical: [UInt8]) -> Bool {
        if quoted == canonical { return true }
        guard quoted.count > canonical.count, quoted.contains(0x5c),
              let name = try? JSONDecoder().decode(String.self, from: Data(quoted)) else { return false }
        return name.utf8.elementsEqual(canonical.dropFirst().dropLast())
    }

    static func mayContain(_ token: Data, in data: Data) -> Bool {
        if data.range(of: token) != nil { return true }
        // At the first escape in a reserved name, the preceding bytes still match its
        // quoted prefix. Ignore Unicode escapes in unrelated keys and large text values.
        let quoted = Array(token)
        let hex = Array("0123456789abcdef".utf8)
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let start = bytes.baseAddress, bytes.count >= 6 else { return false }
            var cursor = 0
            while let next = memchr(start + cursor, 0x5C, bytes.count - cursor) {
                let i = start.distance(to: next.assumingMemoryBound(to: UInt8.self))
                guard i <= bytes.count - 6 else { break }
                cursor = i + 1
                guard bytes[i + 1] == 0x75, bytes[i + 2] == 0x30, bytes[i + 3] == 0x30 else { continue }
                for prefix in 1..<(quoted.count - 1) where i >= prefix {
                    let byte = quoted[prefix]
                    if bytes[i + 4] == hex[Int(byte >> 4)],
                       bytes[i + 5] | 0x20 == hex[Int(byte & 15)],
                       bytes[(i - prefix)..<i].elementsEqual(quoted[..<prefix]) {
                        return true
                    }
                }
            }
            return false
        }
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

        mutating func stringRange() throws -> Range<Int> {
            guard index < bytes.count, bytes[index] == 0x22 else { throw Malformed() }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case 0x22:
                    index += 1
                    return start..<index
                case 0x5C:
                    index += 2
                default:
                    index += 1
                }
            }
            throw Malformed()
        }

        /// Validate asset structure while keeping the entire payload as one value. The
        /// layout needs only its digest key; a typed decoder handles the words and frames.
        mutating func value(depth: Int = 0, inAssets: Bool = false, keep: Bool = true) throws -> Node? {
            guard depth < ProjectSavedLayout.maximumDepth else { throw Malformed() }
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            if inAssets, depth == 3 {
                let start = index
                _ = try value(depth: depth, keep: false)
                return .scalar(Array(bytes[start..<index]))
            }
            switch bytes[index] {
            case 0x7B:
                index += 1
                var members: [Member] = []
                skipSpace()
                if index < bytes.count, bytes[index] == 0x7D {
                    index += 1
                    return keep ? .object(members) : nil
                }
                while true {
                    skipSpace()
                    let keyRange = try stringRange()
                    let key = keep ? Array(bytes[keyRange]) : []
                    skipSpace()
                    guard index < bytes.count, bytes[index] == 0x3A else { throw Malformed() }
                    index += 1
                    let assets = inAssets || (depth == 0 && ProjectSavedLayout.matches(key, ProjectSavedLayout.embeddedAssets))
                    let child = try value(depth: depth + 1, inAssets: assets, keep: keep)
                    if let child { members.append(Member(key: key, value: child)) }
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == 0x7D {
                        index += 1
                        return keep ? .object(members) : nil
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
                    return keep ? .array(items) : nil
                }
                while true {
                    let child = try value(depth: depth + 1, keep: keep)
                    if let child { items.append(child) }
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == 0x5D {
                        index += 1
                        return keep ? .array(items) : nil
                    }
                    guard bytes[index] == 0x2C else { throw Malformed() }
                    index += 1
                }
            case 0x22:
                let range = try stringRange()
                return keep ? .scalar(Array(bytes[range])) : nil
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
                return keep ? .scalar(Array(bytes[start..<index])) : nil
            }
        }
    }

    static func parse(_ data: Data) -> Node? {
        data.withUnsafeBytes { raw -> Node? in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
            guard let node = try? parser.value() else { return nil }
            parser.skipSpace()
            return parser.index == parser.bytes.count ? node : nil
        }
    }

    private static func emit(_ node: Node, bytes: ([UInt8]) throws -> Void) rethrows {
        switch node {
        case .scalar(let text):
            try bytes(text)
        case .array(let items):
            try bytes([0x5B])
            for (position, item) in items.enumerated() {
                if position > 0 { try bytes([0x2C]) }
                try emit(item, bytes: bytes)
            }
            try bytes([0x5D])
        case .object(let members):
            try bytes([0x7B])
            for (position, member) in members.enumerated() {
                if position > 0 { try bytes([0x2C]) }
                try bytes(member.key)
                try bytes([0x3A])
                try emit(member.value, bytes: bytes)
            }
            try bytes([0x7D])
        }
    }

    private static func write(_ node: Node, to output: inout Data) {
        emit(node) { output.append(contentsOf: $0) }
    }

    /// Keep large reference expansions out of the heap. The temporary file has no
    /// directory entry, so interruption or a failed write cannot leave a partial document.
    static func expandedBytes(_ node: Node, size: Int, verifyingHistory: Bool) throws -> Data {
        try CutProject.checkDocumentRead()
        // Verify against the expanded tree while the embedded payloads are still opaque.
        // For large reference expansions, check disk capacity before traversing the edit.
        func checked() -> Node? { verifyingHistory ? ProjectHistoryStamp.verified(node) : nil }
        guard size > 32 << 20 else { return text(checked() ?? node, capacity: size) }
        var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-expand.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard unlink(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let block = Int(volume.f_bsize)
        guard block > 0, UInt64(size / block + (size % block == 0 ? 0 : 1)) <= volume.f_bavail else {
            throw POSIXError(.ENOSPC)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let batchSize = 1 << 20
        var buffer = Data(capacity: batchSize)
        func flush() throws {
            try CutProject.checkDocumentRead()
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        let verified = checked()
        try emit(verified ?? node) { bytes in
            if bytes.count >= batchSize {
                try flush()
                try bytes.withUnsafeBytes { raw in
                    try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                                                       count: raw.count, deallocator: .none))
                }
            } else {
                if buffer.count > batchSize - bytes.count { try flush() }
                buffer.append(contentsOf: bytes)
            }
        }
        try flush()
        let length = try handle.offset()
        // Removing the stamp or a stale history shortens the serialized document.
        guard length > 0, length <= UInt64(size), verified != nil || length == UInt64(size) else {
            throw POSIXError(.EIO)
        }
        let mapped = mmap(nil, Int(length), PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard mapped != MAP_FAILED, let mapped else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM) }
        return Data(bytesNoCopy: mapped, count: Int(length), deallocator: .unmap)
    }

    /// The document with one member or element to a line, as version control wants it: a
    /// change to one clip is a change to a few lines, and two edits to different clips merge.
    /// Every string and number is carried as written and names are put in order, so text
    /// that is already in this form comes back the same.
    static func readable(_ document: Data) -> Data? {
        guard let root = parse(document), case .object = root else { return nil }
        return readable(root, capacity: document.count)
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

    static let embeddedAssets = Array(#""embedded_assets""#.utf8)
    static let history = Array(#""history""#.utf8)
    static let marker = Array(#""~""#.utf8)
    static let mediaSnapshot = Array(#""media_snapshot""#.utf8)

    static func isString(_ text: [UInt8]) -> Bool {
        text.count >= 2 && text.first == 0x22
    }
}
