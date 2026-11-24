import CryptoKit
import Foundation

/// The layout a project is saved in. It is the project document with what the document
/// repeats written once, in a root `refs` table:
///
/// - Long text that occurs more than once, such as the path of a recording that every clip
///   names, is an entry of `refs`, and each use is the text `"~KEY"`. Text that itself begins
///   with `~` is written with a second one.
/// - Inside `history`, an object or list that occurs more than once is an entry of `refs`, and
///   each use is `{"~": "KEY"}`. An undo step keeps every clip it restores, and nearly all of
///   them are the same from one step to the next.
///
/// A key is taken from the content it names and from nothing else. That is what lets version
/// control merge two branches of a project: the same recording has the same key on both, an
/// entry one branch adds cannot change what another branch's references mean, and two
/// different contents under one key are a conflict that is seen, where a table kept by
/// position would merge into references that name the wrong recording.
///
/// The rewrite works on the document's own text. A string or number is carried as it was
/// written, and a project is saved this way only when expanding the result gives back the
/// document it came from.
enum ProjectKeyedLayout {
    typealias Node = ProjectSavedLayout.Node
    typealias Member = ProjectSavedLayout.Member
    private struct Malformed: Error {}
    private struct Missing: Error { let key: [UInt8] }

    static let table = Array(#""refs""#.utf8)
    /// Sorts after every key, and is nothing a reference can name.
    private static let lastEntry = Array(#""~""#.utf8)
    private static let tilde: UInt8 = 0x7E
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)
    /// Fifty bits. Two contents of one project under one key are met about once in 10^9 projects
    /// of ten thousand entries, and that project is saved without the table.
    private static let keyLength = 10
    private static let textReference = keyLength + 3
    private static let valueReference = keyLength + 8
    /// A key, its quotes, a colon and a comma.
    private static let entryOverhead = keyLength + 4
    /// Shorter content costs more to list than it saves.
    private static let minimumText = 16
    private static let minimumValue = 24

    static func key(_ content: [UInt8]) -> [UInt8] {
        var bits: UInt64 = 0
        for byte in SHA256.hash(data: content).prefix(8) { bits = bits << 8 | UInt64(byte) }
        return (0..<keyLength).map { alphabet[Int(bits >> UInt64(59 - 5 * $0) & 31)] }
    }

    // MARK: Save

    /// What tells one value from another without holding its text. Two values that differ
    /// could share a mark, and the check that a saved project expands to the document it came
    /// from would then refuse the result.
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

    private struct Writer {
        var entries: [[UInt8]: (content: [UInt8], value: Node)] = [:]
        var consistent = true
        private var textUses: [[UInt8]: Int] = [:]
        private var texts: [[UInt8]: [UInt8]] = [:]
        private var valueUses: [Mark: Int] = [:]
        private var values: [Mark: [UInt8]?] = [:]

        private mutating func enter(_ key: [UInt8], content: [UInt8], value: Node) {
            if let held = entries[key] {
                if held.content != content { consistent = false }
            } else {
                entries[key] = (content, value)
            }
        }

        mutating func count(_ node: Node, inHistory: Bool, root: Bool = false) -> Mark {
            var mark: Mark
            switch node {
            case .scalar(let text):
                if ProjectSavedLayout.isString(text), text.count >= ProjectKeyedLayout.minimumText { textUses[text, default: 0] += 1 }
                return Mark(text)
            case .array(let items):
                mark = Mark(open: 0x5B)
                for (position, item) in items.enumerated() { mark.add(count(item, inHistory: inHistory), separated: position > 0) }
            case .object(let members):
                mark = Mark(open: 0x7B)
                for (position, member) in members.enumerated() {
                    mark.add(Mark(member.key), separated: position > 0)
                    // A snapshot is carried exactly as it is.
                    let inner = member.key == ProjectSavedLayout.mediaSnapshot
                        ? Mark(Array(ProjectSavedLayout.text(member.value, capacity: 64)))
                        : count(member.value, inHistory: inHistory || (root && member.key == ProjectSavedLayout.history))
                    mark.add(inner, separated: true)
                }
            }
            if inHistory, mark.length >= ProjectKeyedLayout.minimumValue { valueUses[mark, default: 0] += 1 }
            return mark
        }

        mutating func chooseTexts() {
            for (text, uses) in textUses where uses > 1
                && uses * (text.count - ProjectKeyedLayout.textReference) > text.count + ProjectKeyedLayout.entryOverhead {
                let key = ProjectKeyedLayout.key(text)
                texts[text] = key
                enter(key, content: text, value: .scalar(text))
            }
        }

        /// The value with what it repeats replaced, the mark it had before, and its length now.
        mutating func replace(_ node: Node, inHistory: Bool, root: Bool = false)
            -> (node: Node, mark: Mark, length: Int, changed: Bool) {
            let replaced: Node
            var mark: Mark
            var length = 2
            var changed = false
            switch node {
            case .scalar(let text):
                guard ProjectSavedLayout.isString(text) else { return (node, Mark(text), text.count, false) }
                if let key = texts[text] {
                    return (.scalar([0x22, ProjectKeyedLayout.tilde] + key + [0x22]), Mark(text), ProjectKeyedLayout.textReference, true)
                }
                // A reference is told from text by its first character.
                guard text.count > 2, text[1] == ProjectKeyedLayout.tilde else { return (node, Mark(text), text.count, false) }
                return (.scalar([0x22, ProjectKeyedLayout.tilde] + text.dropFirst()), Mark(text), text.count + 1, true)
            case .array(let items):
                mark = Mark(open: 0x5B)
                var parts = items
                for (position, item) in items.enumerated() {
                    let part = replace(item, inHistory: inHistory)
                    mark.add(part.mark, separated: position > 0)
                    length += part.length + (position > 0 ? 1 : 0)
                    if part.changed {
                        parts[position] = part.node
                        changed = true
                    }
                }
                replaced = changed ? .array(parts) : node
            case .object(let members):
                mark = Mark(open: 0x7B)
                var parts = members
                for (position, member) in members.enumerated() {
                    let part: (node: Node, mark: Mark, length: Int, changed: Bool)
                    if member.key == ProjectSavedLayout.mediaSnapshot {
                        let text = Array(ProjectSavedLayout.text(member.value, capacity: 64))
                        part = (member.value, Mark(text), text.count, false)
                    } else {
                        part = replace(member.value, inHistory: inHistory || (root && member.key == ProjectSavedLayout.history))
                    }
                    mark.add(Mark(member.key), separated: position > 0)
                    mark.add(part.mark, separated: true)
                    length += member.key.count + 1 + part.length + (position > 0 ? 1 : 0)
                    if part.changed {
                        parts[position].value = part.node
                        changed = true
                    }
                }
                replaced = changed ? .object(parts) : node
            }
            guard inHistory, let uses = valueUses[mark], uses > 1 else { return (replaced, mark, length, changed) }
            let key: [UInt8]?
            if let decided = values[mark] {
                key = decided
            } else if uses * (length - ProjectKeyedLayout.valueReference) > length + ProjectKeyedLayout.entryOverhead {
                // The key names the value as the document holds it, whatever its parts refer to.
                let content = Array(ProjectSavedLayout.text(node, capacity: mark.length))
                let named = ProjectKeyedLayout.key(content)
                enter(named, content: content, value: replaced)
                key = named
                values[mark] = .some(named)
            } else {
                key = nil
                values[mark] = .some(nil)
            }
            guard let key else { return (replaced, mark, length, changed) }
            let reference = Node.object([Member(key: ProjectSavedLayout.marker, value: .scalar([0x22] + key + [0x22]))])
            return (reference, mark, ProjectKeyedLayout.valueReference, true)
        }
    }

    /// The saved form of a project document, or nil when the text is not a plain project
    /// document or would not expand back to itself. Every project carries the table, an empty
    /// one included, so that text beginning with `~` is read the same way in each of them.
    static func compacted(_ project: Data) -> Data? {
        guard let original = ProjectSavedLayout.parse(project), let saved = compactedDocument(original) else { return nil }
        return ProjectSavedLayout.text(saved, capacity: project.count)
    }

    static func compactedDocument(_ original: Node) -> Node? {
        guard case .object(let members) = original,
              !members.contains(where: { $0.key == table }) else { return nil }
        var writer = Writer()
        _ = writer.count(original, inHistory: false, root: true)
        writer.chooseTexts()
        guard case .object(var root) = writer.replace(original, inHistory: false, root: true).node,
              writer.consistent else { return nil }
        var rows = writer.entries.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map {
            Member(key: [0x22] + $0.key + [0x22], value: $0.value.value)
        }
        // JSON puts a comma after every entry but the last, so an entry added at the end
        // would change the line before it, and version control would see two branches
        // touching the same line. A fixed last entry keeps every other line as it was.
        rows.append(Member(key: lastEntry, value: .scalar(Array(#""""#.utf8))))
        let position = root.firstIndex { table.lexicographicallyPrecedes($0.key) }
        root.insert(Member(key: table, value: .object(rows)), at: position ?? root.count)
        let saved = Node.object(root)
        // Verify the same expansion used on load, before writing the JSON.
        guard (try? expandedDocument(saved, code: "invalid_cut_project")) == original else { return nil }
        return saved
    }

    // MARK: Open

    /// The project document a saved project stands for, or nil for text with no `refs` table.
    static func expanded(_ saved: Data, code: String = "invalid_cut_project") throws -> Data? {
        try expandedDocument(saved, code: code).map { ProjectSavedLayout.text($0, capacity: saved.count * 2) }
    }

    private static func expandedDocument(_ saved: Data, code: String) throws -> Node? {
        guard saved.range(of: Data(table)) != nil, let document = ProjectSavedLayout.parse(saved) else { return nil }
        return try expandedDocument(document, code: code)
    }

    static func expandedDocument(_ document: Node, code: String) throws -> Node? {
        guard case .object(var root) = document,
              let position = root.firstIndex(where: { $0.key == table }) else { return nil }
        let damaged = CutError(code: code, message: "The project’s refs table is damaged.")
        guard case .object(let rows) = root[position].value else { throw damaged }
        root.remove(at: position)
        guard !root.contains(where: { $0.key == table }) else { throw damaged }
        var entries: [[UInt8]: Node] = [:]
        for row in rows {
            // The same entry twice is what a merge of two branches that added it can leave.
            let key = Array(row.key.dropFirst().dropLast())
            if let held = entries[key], held != row.value { throw damaged }
            entries[key] = row.value
        }

        // Nothing a project holds expands past this, so a table built to grow without end is refused.
        let limit = MulticamProject.maximumFileSize * 2
        // The CLI can expand a project on a Swift worker thread with a small stack.
        let maximumDepth = 128
        let maximumOpenReferences = 512
        var resolved: [[UInt8]: (node: Node, size: Int, height: Int)] = [:]
        var open: Set<[UInt8]> = []
        var expandingValues = 0

        func entry(_ key: [UInt8]) throws -> Node {
            guard let entry = entries[key] else { throw Missing(key: key) }
            return entry
        }
        func value(_ key: [UInt8], depth: Int) throws -> (node: Node, size: Int, height: Int) {
            var current = key
            var aliases: [[UInt8]] = []
            defer {
                for alias in aliases { open.remove(alias) }
            }
            let done: (node: Node, size: Int, height: Int)
            while true {
                if let cached = resolved[current] {
                    guard cached.height <= maximumDepth - depth else { throw Malformed() }
                    done = cached
                    break
                }
                let held = try entry(current)
                if case .scalar = held { throw Malformed() }
                guard open.count < maximumOpenReferences, open.insert(current).inserted else { throw Malformed() }
                if case .object(let members) = held, members.count == 1, members[0].key == ProjectSavedLayout.marker {
                    aliases.append(current)
                    current = try referenceKey(members[0].value)
                    continue
                }
                defer { open.remove(current) }
                var size = 0
                expandingValues += 1
                defer { expandingValues -= 1 }
                let result = try expand(held, depth: depth, size: &size)
                done = (node: result.node, size: size, height: result.height)
                resolved[current] = done
                break
            }
            for alias in aliases { resolved[alias] = done }
            return done
        }
        func referenceKey(_ marker: Node) throws -> [UInt8] {
            guard case .scalar(let quoted) = marker, ProjectSavedLayout.isString(quoted) else { throw Malformed() }
            return Array(quoted.dropFirst().dropLast())
        }
        func expand(_ node: Node, depth: Int, size: inout Int, opaque: Bool = false) throws
            -> (node: Node, changed: Bool, height: Int) {
            guard depth + expandingValues < maximumDepth else { throw Malformed() }
            var result = node
            var changed = false
            var height = 1
            switch node {
            case .scalar(let text):
                guard !opaque, ProjectSavedLayout.isString(text), text.count > 2, text[1] == tilde else {
                    size += text.count + 1
                    break
                }
                changed = true
                if text.count > 3, text[2] == tilde {
                    size += text.count
                    result = .scalar([0x22] + text.dropFirst(2))
                } else {
                    guard case .scalar(let literal) = try entry(Array(text.dropFirst(2).dropLast())),
                          ProjectSavedLayout.isString(literal) else { throw Malformed() }
                    size += literal.count + 1
                    result = .scalar(literal)
                }
            case .array(let items):
                size += 2
                var expanded = items
                for (index, item) in items.enumerated() {
                    let child = try expand(item, depth: depth + 1, size: &size, opaque: opaque)
                    height = max(height, child.height + 1)
                    if child.changed {
                        expanded[index] = child.node
                        changed = true
                    }
                }
                if changed { result = .array(expanded) }
            case .object(let members):
                if !opaque, members.count == 1, members[0].key == ProjectSavedLayout.marker {
                    let shared = try value(referenceKey(members[0].value), depth: depth)
                    size += shared.size
                    result = shared.node
                    changed = true
                    height = shared.height
                } else {
                    size += 2
                    var expanded = members
                    for (index, member) in members.enumerated() {
                        size += member.key.count + 1
                        let child = try expand(member.value, depth: depth + 1, size: &size,
                                               opaque: opaque || member.key == ProjectSavedLayout.mediaSnapshot)
                        height = max(height, child.height + 1)
                        if child.changed {
                            expanded[index].value = child.node
                            changed = true
                        }
                    }
                    if changed { result = .object(expanded) }
                }
            }
            guard size <= limit else { throw Malformed() }
            return (result, changed, height)
        }
        do {
            var size = 0
            return try expand(.object(root), depth: 0, size: &size).node
        } catch let missing as Missing {
            let name = String(decoding: missing.key, as: UTF8.self)
            throw CutError(code: code, message: "The project refers to ‘\(name)’, which its refs table does not hold. "
                           + "After a merge, restore that entry from the branch that had it.")
        } catch is Malformed {
            throw damaged
        }
    }
}
