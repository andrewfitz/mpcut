import Foundation

/// The layout a project is saved in. It is the expanded project document with what that
/// document repeats written once:
///
/// - Every `file` and `original_file` path is a position in the root `files` list. A long interview names one
///   recording on each clip, again on each clip that undo history keeps, and again on each
///   transcript binding.
/// - Transcript bindings that differ only in their track share one entry with a `track_ids` list.
/// - A binding's times are the text `n` or `n/d` that the rest of the project already uses.
/// - Any other long text that occurs more than once, such as a clip or angle ID that history and
///   switches repeat, is written once in the root `strings` list and referred to as `"~3"`.
///   Text that itself begins with `~` is written with a second one.
/// - Inside `history`, an object or list that occurs more than once is written once in the root
///   `shared` list and referred to as `{"~":3}`. An undo step keeps every clip or participant
///   span it restores, and nearly all of them are the same from one step to the next.
///
/// The rewrite works on the document's own text. A string or number is carried as it was
/// written, so nothing is parsed and spelled again, and a project is saved this way only when
/// expanding the result gives back the document it came from, byte for byte.
enum ProjectSavedLayout {
    static let schemaVersion = 5
    static let soundtrackSchemaVersion = 7
    static var prefersExpanded: Bool {
        ProcessInfo.processInfo.environment["MPCUT_PROJECT_VERSION"] == "4"
    }

    private static let maximumDepth = 512

    // MARK: Document text

    private indirect enum Node: Equatable {
        /// A string, number or literal exactly as written.
        case scalar([UInt8])
        case array([Node])
        case object([Member])
    }

    private struct Member: Equatable {
        /// The name as written, with its quotes.
        var key: [UInt8]
        var value: Node
    }

    private struct Malformed: Error {}

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

    private static func parse(_ data: Data) -> Node? {
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

    private static func text(_ node: Node, capacity: Int) -> Data {
        var output = Data(capacity: capacity)
        write(node, to: &output)
        return output
    }

    // MARK: Names

    /// The members that hold a path to media.
    private static let paths = [Array(#""file""#.utf8), Array(#""original_file""#.utf8)]
    private static let files = Array(#""files""#.utf8)
    private static let strings = Array(#""strings""#.utf8)
    private static let shared = Array(#""shared""#.utf8)
    private static let history = Array(#""history""#.utf8)
    private static let marker = Array(#""~""#.utf8)
    // Snapshot entries may use arbitrary member names in later versions.
    private static let mediaSnapshot = Array(#""media_snapshot""#.utf8)
    private static let version = Array(#""schema_version""#.utf8)
    private static let bindings = Array(#""bindings""#.utf8)
    private static let binding = Array(#""binding""#.utf8)
    private static let trackID = Array(#""track_id""#.utf8)
    private static let trackIDs = Array(#""track_ids""#.utf8)
    private static let importOrigin = Array(#""import_origin""#.utf8)
    private static let bindingTimes = [Array(#""offset""#.utf8), Array(#""sequence_clock_origin""#.utf8)]
    private static let numerator = Array(#""numerator""#.utf8)
    private static let denominator = Array(#""denominator""#.utf8)

    private static func isString(_ text: [UInt8]) -> Bool {
        text.count >= 2 && text.first == 0x22
    }

    /// Digits with no leading zero, as the project writer spells an integer.
    private static func isInteger(_ text: ArraySlice<UInt8>, signed: Bool) -> Bool {
        var digits = text
        if signed, digits.first == 0x2D { digits = digits.dropFirst() }
        guard let first = digits.first, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
        return first != 0x30 || (digits.count == 1 && digits.startIndex == text.startIndex)
    }

    // MARK: Times

    /// `{"denominator":d,"numerator":n}` as `"n"` or `"n/d"`. Any other spelling stays as it is.
    private static func compactTime(_ node: Node) -> Node {
        guard case .object(let members) = node, members.count == 2,
              members[0].key == denominator, members[1].key == numerator,
              case .scalar(let bottom) = members[0].value, case .scalar(let top) = members[1].value,
              isInteger(bottom[...], signed: false), bottom != [0x30], isInteger(top[...], signed: true) else { return node }
        return .scalar([0x22] + top + (bottom == [0x31] ? [] : [0x2F] + bottom) + [0x22])
    }

    private static func expandedTime(_ node: Node) throws -> Node {
        // Only the compact spelling is a time here. The expanded document never has text in this place.
        guard case .scalar(let text) = node, isString(text) else { return node }
        let parts = text.dropFirst().dropLast().split(separator: 0x2F, maxSplits: 1, omittingEmptySubsequences: false)
        guard let top = parts.first, isInteger(top, signed: true) else { throw Malformed() }
        var bottom: [UInt8] = [0x31]
        if parts.count == 2 {
            guard isInteger(parts[1], signed: false), parts[1].elementsEqual([0x30]) == false,
                  parts[1].elementsEqual([0x31]) == false else { throw Malformed() }
            bottom = Array(parts[1])
        }
        return .object([Member(key: denominator, value: .scalar(bottom)), Member(key: numerator, value: .scalar(Array(top)))])
    }

    // MARK: Repeated text

    private static let reference: UInt8 = 0x7E
    /// Shorter text costs more to list than it saves.
    private static let minimumSharedLength = 14

    private struct Interner {
        var list: [[UInt8]] = []
        private var positions: [[UInt8]: Int] = [:]

        private func count(_ node: Node, into counts: inout [[UInt8]: Int], order: inout [[UInt8]]) {
            switch node {
            case .scalar(let text):
                guard ProjectSavedLayout.isString(text), text.count >= ProjectSavedLayout.minimumSharedLength else { return }
                if counts[text] == nil { order.append(text) }
                counts[text, default: 0] += 1
            case .array(let items):
                for item in items { count(item, into: &counts, order: &order) }
            case .object(let members):
                for member in members where member.key != ProjectSavedLayout.mediaSnapshot {
                    count(member.value, into: &counts, order: &order)
                }
            }
        }

        private func replace(_ node: Node) -> Node {
            switch node {
            case .scalar(let text):
                guard ProjectSavedLayout.isString(text) else { return node }
                if let position = positions[text] {
                    return .scalar([0x22, ProjectSavedLayout.reference] + Array(String(position).utf8) + [0x22])
                }
                // A reference is told from text by its first character.
                guard text[1] == ProjectSavedLayout.reference else { return node }
                return .scalar([0x22, ProjectSavedLayout.reference] + text.dropFirst())
            case .array(let items):
                return .array(items.map(replace))
            case .object(let members):
                return .object(members.map { member in
                    member.key == ProjectSavedLayout.mediaSnapshot ? member : Member(key: member.key, value: replace(member.value))
                })
            }
        }

        mutating func share(_ node: Node) -> Node {
            var counts: [[UInt8]: Int] = [:]
            var order: [[UInt8]] = []
            count(node, into: &counts, order: &order)
            for text in order {
                let uses = counts[text] ?? 0
                let reference = 3 + String(list.count).utf8.count
                // Listing the text once costs its length and a comma.
                guard uses > 1, uses * (text.count - reference) > text.count + 1 else { continue }
                positions[text] = list.count
                list.append(text)
            }
            return replace(node)
        }

        static func restore(_ node: Node, from list: [[UInt8]]) throws -> Node {
            switch node {
            case .scalar(let text):
                guard ProjectSavedLayout.isString(text), text[1] == ProjectSavedLayout.reference else { return node }
                if text.count > 3, text[2] == ProjectSavedLayout.reference {
                    return .scalar([0x22] + text.dropFirst(2))
                }
                let digits = text.dropFirst(2).dropLast()
                guard ProjectSavedLayout.isInteger(digits, signed: false),
                      let position = Int(String(decoding: digits, as: UTF8.self)), list.indices.contains(position) else {
                    throw Malformed()
                }
                return .scalar(list[position])
            case .array(let items):
                return .array(try items.map { try restore($0, from: list) })
            case .object(let members):
                return .object(try members.map { member in
                    member.key == ProjectSavedLayout.mediaSnapshot
                        ? member : Member(key: member.key, value: try restore(member.value, from: list))
                })
            }
        }
    }

    // MARK: Repeated values in history

    /// A shorter value costs more to list than it saves.
    private static let minimumSharedValue = 24

    private struct Sharer {
        /// What tells one value from another without holding its text: a hash of the text and
        /// its length. Two values that differ could share both, and the check that a saved
        /// project expands to the document it came from would then refuse the result.
        private struct Mark: Hashable {
            var hash: UInt64
            var length: Int

            init(_ text: [UInt8]) {
                hash = 0xcbf29ce484222325
                for byte in text { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                length = text.count
            }

            init(open: UInt8) {
                hash = (0xcbf29ce484222325 ^ UInt64(open)) &* 0x100000001b3
                length = 2
            }

            mutating func add(_ other: Mark, separated: Bool) {
                hash = ((hash << 7 | hash >> 57) ^ other.hash) &* 0x100000001b3
                length += other.length + (separated ? 1 : 0)
            }
        }

        var list: [Node] = []
        private var counts: [Mark: Int] = [:]
        private var positions: [Mark: Int] = [:]

        /// The mark of a value, having counted each object and list inside it.
        private mutating func count(_ node: Node) -> Mark {
            var mark: Mark
            switch node {
            case .scalar(let written):
                return Mark(written)
            case .array(let items):
                mark = Mark(open: 0x5B)
                for (position, item) in items.enumerated() { mark.add(count(item), separated: position > 0) }
            case .object(let members):
                mark = Mark(open: 0x7B)
                for (position, member) in members.enumerated() {
                    mark.add(Mark(member.key), separated: position > 0)
                    mark.add(count(member.value), separated: true)
                }
            }
            if mark.length >= ProjectSavedLayout.minimumSharedValue { counts[mark, default: 0] += 1 }
            return mark
        }

        /// The value with what it repeats replaced, the mark it had before, and its length now.
        private mutating func replace(_ node: Node) -> (node: Node, mark: Mark, length: Int) {
            let replaced: Node
            var mark: Mark
            var length = 2
            switch node {
            case .scalar(let written):
                return (node, Mark(written), written.count)
            case .array(let items):
                mark = Mark(open: 0x5B)
                var parts: [Node] = []
                parts.reserveCapacity(items.count)
                for (position, item) in items.enumerated() {
                    let part = replace(item)
                    mark.add(part.mark, separated: position > 0)
                    length += part.length + (position > 0 ? 1 : 0)
                    parts.append(part.node)
                }
                replaced = .array(parts)
            case .object(let members):
                mark = Mark(open: 0x7B)
                var parts: [Member] = []
                parts.reserveCapacity(members.count)
                for (position, member) in members.enumerated() {
                    let part = replace(member.value)
                    mark.add(Mark(member.key), separated: position > 0)
                    mark.add(part.mark, separated: true)
                    length += member.key.count + 1 + part.length + (position > 0 ? 1 : 0)
                    parts.append(Member(key: member.key, value: part.node))
                }
                replaced = .object(parts)
            }
            guard let uses = counts[mark], uses > 1 else { return (replaced, mark, length) }
            let reference = 6 + String(positions[mark] ?? list.count).utf8.count
            if let position = positions[mark] { return (Self.reference(position), mark, reference) }
            // Listing the value once costs its length and a comma.
            guard uses * (length - reference) > length + 1 else { return (replaced, mark, length) }
            positions[mark] = list.count
            list.append(replaced)
            return (Self.reference(list.count - 1), mark, reference)
        }

        private static func reference(_ position: Int) -> Node {
            .object([Member(key: ProjectSavedLayout.marker, value: .scalar(Array(String(position).utf8)))])
        }

        mutating func share(_ members: [Member]) -> [Member] {
            guard let position = members.firstIndex(where: { $0.key == ProjectSavedLayout.history }) else { return members }
            _ = count(members[position].value)
            var members = members
            members[position].value = replace(members[position].value).node
            return members
        }

        /// The history with each reference replaced by the value it names. An entry of the
        /// list may refer only to entries before it, and the result may not outgrow a project.
        static func restore(_ history: Node, from entries: [Node]) throws -> Node {
            let limit = MulticamProject.maximumFileSize * 2
            var values: [Node] = []
            var sizes: [Int] = []
            func expand(_ node: Node, room: inout Int) throws -> Node {
                switch node {
                case .scalar(let text):
                    room -= text.count + 1
                    guard room >= 0 else { throw Malformed() }
                    return node
                case .array(let items):
                    room -= 2
                    return .array(try items.map { try expand($0, room: &room) })
                case .object(let members):
                    if members.count == 1, members[0].key == ProjectSavedLayout.marker,
                       case .scalar(let digits) = members[0].value {
                        guard ProjectSavedLayout.isInteger(digits[...], signed: false),
                              let position = Int(String(decoding: digits, as: UTF8.self)), values.indices.contains(position) else {
                            throw Malformed()
                        }
                        room -= sizes[position]
                        guard room >= 0 else { throw Malformed() }
                        return values[position]
                    }
                    room -= 2
                    return .object(try members.map { member in
                        room -= member.key.count + 1
                        return Member(key: member.key, value: try expand(member.value, room: &room))
                    })
                }
            }
            for entry in entries {
                var room = limit
                values.append(try expand(entry, room: &room))
                sizes.append(limit - room)
            }
            var room = limit
            return try expand(history, room: &room)
        }
    }

    // MARK: Compact

    private struct Compactor {
        var paths: [[UInt8]] = []
        var positions: [[UInt8]: Int] = [:]

        mutating func compact(_ node: Node) -> Node {
            switch node {
            case .scalar:
                return node
            case .array(let items):
                return .array(items.map { compact($0) })
            case .object(let members):
                let attachment = members.contains { $0.key == ProjectSavedLayout.bindings }
                return .object(members.map { member in
                    if member.key == ProjectSavedLayout.mediaSnapshot { return member }
                    var member = member
                    if ProjectSavedLayout.paths.contains(member.key), case .scalar(let text) = member.value,
                       ProjectSavedLayout.isString(text) {
                        let position: Int
                        if let known = positions[text] {
                            position = known
                        } else {
                            position = paths.count
                            positions[text] = position
                            paths.append(text)
                        }
                        member.value = .scalar(Array(String(position).utf8))
                    } else if member.key == ProjectSavedLayout.bindings, case .array(let items) = member.value {
                        member.value = .array(grouped(items.map { self.binding($0) }))
                    } else if member.key == ProjectSavedLayout.binding, case .object = member.value {
                        member.value = binding(member.value)
                    } else if attachment, member.key == ProjectSavedLayout.importOrigin {
                        member.value = time(member.value)
                    } else {
                        member.value = compact(member.value)
                    }
                    return member
                })
            }
        }

        private func time(_ node: Node) -> Node {
            ProjectSavedLayout.compactTime(node)
        }

        private mutating func binding(_ node: Node) -> Node {
            let compacted = compact(node)
            guard case .object(let members) = compacted else { return compacted }
            return .object(members.map { member in
                guard ProjectSavedLayout.bindingTimes.contains(member.key) else { return member }
                return Member(key: member.key, value: time(member.value))
            })
        }

        /// Neighbouring bindings that differ only in their track become one entry.
        private mutating func grouped(_ items: [Node]) -> [Node] {
            func split(_ node: Node) -> (position: Int, track: [UInt8], rest: [Member])? {
                guard case .object(var members) = node,
                      let position = members.firstIndex(where: { $0.key == ProjectSavedLayout.trackID }),
                      case .scalar(let track) = members[position].value, ProjectSavedLayout.isString(track) else { return nil }
                members.remove(at: position)
                return (position, track, members)
            }
            var output: [Node] = []
            var index = 0
            while index < items.count {
                guard let first = split(items[index]) else {
                    output.append(items[index])
                    index += 1
                    continue
                }
                var tracks = [first.track]
                var next = index + 1
                while next < items.count, let other = split(items[next]), other.position == first.position,
                      other.rest == first.rest {
                    tracks.append(other.track)
                    next += 1
                }
                if tracks.count > 1 {
                    var members = first.rest
                    members.insert(Member(key: ProjectSavedLayout.trackIDs, value: .array(tracks.map { .scalar($0) })),
                                   at: first.position)
                    output.append(.object(members))
                } else {
                    output.append(items[index])
                }
                index = next
            }
            return output
        }
    }

    /// The saved form of an expanded project with repeated records.
    static func compacted(_ project: Data) -> Data? {
        guard case .object(var root)? = parse(project),
              let versionPosition = root.firstIndex(where: { $0.key == version }),
              !root.contains(where: { $0.key == files || $0.key == strings || $0.key == shared }) else { return nil }
        let savedVersion: Int
        switch root[versionPosition].value {
        case .scalar(Array("4".utf8)): savedVersion = schemaVersion
        case .scalar(Array(String(CutProject.schemaVersion).utf8)): savedVersion = soundtrackSchemaVersion
        default: return nil
        }
        let original = Node.object(root)
        var compactor = Compactor()
        var interner = Interner()
        var sharer = Sharer()
        guard case .object(let body) = interner.share(compactor.compact(.object(root))) else { return nil }
        root = sharer.share(body)
        root[versionPosition].value = .scalar(Array(String(savedVersion).utf8))
        // The writer sorts names, and a reader looking at the file finds each list where it expects it.
        let lists: [([UInt8], [Node])] = [(files, compactor.paths.map { .scalar($0) }), (shared, sharer.list),
                                           (strings, interner.list.map { .scalar($0) })]
        for (name, list) in lists where !list.isEmpty {
            let position = root.firstIndex { String(decoding: $0.key, as: UTF8.self) > String(decoding: name, as: UTF8.self) }
            root.insert(Member(key: name, value: .array(list)), at: position ?? root.count)
        }
        let saved = text(.object(root), capacity: project.count)
        // The saved text is read back as any reader would read it, and has to give the same document.
        guard (try? expandedDocument(saved, code: "invalid_cut_project")) == original else { return nil }
        return saved
    }

    // MARK: Expand

    private struct Expander {
        let paths: [[UInt8]]

        func expand(_ node: Node) throws -> Node {
            switch node {
            case .scalar:
                return node
            case .array(let items):
                return .array(try items.map(expand))
            case .object(let members):
                let attachment = members.contains { $0.key == ProjectSavedLayout.bindings }
                return .object(try members.map { member in
                    if member.key == ProjectSavedLayout.mediaSnapshot { return member }
                    var member = member
                    if ProjectSavedLayout.paths.contains(member.key), case .scalar(let text) = member.value,
                       !ProjectSavedLayout.isString(text) {
                        guard ProjectSavedLayout.isInteger(text[...], signed: false),
                              let position = Int(String(decoding: text, as: UTF8.self)), paths.indices.contains(position) else {
                            throw Malformed()
                        }
                        member.value = .scalar(paths[position])
                    } else if member.key == ProjectSavedLayout.bindings, case .array(let items) = member.value {
                        member.value = .array(try items.flatMap(ungrouped))
                    } else if member.key == ProjectSavedLayout.binding, case .object = member.value {
                        member.value = try binding(member.value)
                    } else if attachment, member.key == ProjectSavedLayout.importOrigin {
                        member.value = try ProjectSavedLayout.expandedTime(member.value)
                    } else {
                        member.value = try expand(member.value)
                    }
                    return member
                })
            }
        }

        private func binding(_ node: Node) throws -> Node {
            let expanded = try expand(node)
            guard case .object(let members) = expanded else { return expanded }
            return .object(try members.map { member in
                guard ProjectSavedLayout.bindingTimes.contains(member.key) else { return member }
                return Member(key: member.key, value: try ProjectSavedLayout.expandedTime(member.value))
            })
        }

        private func ungrouped(_ node: Node) throws -> [Node] {
            let expanded = try binding(node)
            guard case .object(let members) = expanded,
                  let position = members.firstIndex(where: { $0.key == ProjectSavedLayout.trackIDs }) else {
                return [expanded]
            }
            guard case .array(let tracks) = members[position].value, !tracks.isEmpty,
                  !members.contains(where: { $0.key == ProjectSavedLayout.trackID }) else { throw Malformed() }
            return try tracks.map { track in
                guard case .scalar(let text) = track, ProjectSavedLayout.isString(text) else { throw Malformed() }
                var members = members
                members[position] = Member(key: ProjectSavedLayout.trackID, value: track)
                return .object(members)
            }
        }
    }

    /// Whether the text may hold a saved-layout version. Most projects on disk are older, and
    /// this spares reading each of them twice.
    private static func mentionsSavedVersion(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let versions = [schemaVersion, soundtrackSchemaVersion].map { Array(String($0).utf8) }
            guard bytes.count >= version.count else { return false }
            var index = 0
            while index + version.count <= bytes.count {
                guard bytes[index] == 0x22, bytes[index..<index + version.count].elementsEqual(version) else {
                    index += 1
                    continue
                }
                index += version.count
                while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09, 0x3A].contains(bytes[index]) { index += 1 }
                if versions.contains(where: { digits in
                    index + digits.count <= bytes.count && bytes[index..<index + digits.count].elementsEqual(digits)
                }) { return true }
            }
            return false
        }
    }

    /// The expanded project, or nil for a document using the expanded layout already.
    static func expanded(_ saved: Data, code: String = "invalid_cut_project") throws -> Data? {
        try expandedDocument(saved, code: code).map { text($0, capacity: saved.count * 2) }
    }

    private static func expandedDocument(_ saved: Data, code: String) throws -> Node? {
        guard mentionsSavedVersion(saved), case .object(var root)? = parse(saved),
              let versionPosition = root.firstIndex(where: { $0.key == version }) else { return nil }
        let expandedVersion: Int
        switch root[versionPosition].value {
        case .scalar(Array(String(schemaVersion).utf8)): expandedVersion = 4
        case .scalar(Array(String(soundtrackSchemaVersion).utf8)): expandedVersion = CutProject.schemaVersion
        default: return nil
        }
        let invalid = CutError(code: code, message: "The project’s saved layout is damaged.")
        /// A list the document leaves out when it has nothing to hold.
        func list(_ name: [UInt8]) throws -> [[UInt8]] {
            guard let position = root.firstIndex(where: { $0.key == name }) else { return [] }
            guard case .array(let items) = root[position].value else { throw invalid }
            root.remove(at: position)
            guard !root.contains(where: { $0.key == name }) else { throw invalid }
            return try items.map { item in
                guard case .scalar(let text) = item, isString(text) else { throw invalid }
                return text
            }
        }
        let paths = try list(files)
        let texts = try list(strings)
        var values: [Node] = []
        if let position = root.firstIndex(where: { $0.key == shared }) {
            guard case .array(let items) = root[position].value else { throw invalid }
            values = items
            root.remove(at: position)
            guard !root.contains(where: { $0.key == shared }) else { throw invalid }
        }
        guard let position = root.firstIndex(where: { $0.key == version }) else { throw invalid }
        root[position].value = .scalar(Array(String(expandedVersion).utf8))
        do {
            if !values.isEmpty, let position = root.firstIndex(where: { $0.key == history }) {
                root[position].value = try Sharer.restore(root[position].value, from: values)
            }
            let restored = try Interner.restore(.object(root), from: texts)
            return try Expander(paths: paths).expand(restored)
        } catch {
            throw invalid
        }
    }
}
