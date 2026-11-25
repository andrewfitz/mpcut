import Foundation

/// An undo step describes its change by position in the timeline it was made on, so a saved
/// history is good only for the edit it was saved with. A saved `history` carries `base`, a
/// digest of that edit. A project whose edit was changed as text, or merged from two
/// branches, no longer matches, and it opens with no history.
///
/// `base` belongs to the saved layout, as `refs` does. The document a project stands for has
/// neither.
enum ProjectHistoryStamp {
    typealias Node = ProjectSavedLayout.Node
    typealias Member = ProjectSavedLayout.Member

    static let member = Array(#""base""#.utf8)
    private static let token = Data(member)
    /// What a save writes for itself. Changing these leaves the edit as it was.
    private static let apart = [ProjectSavedLayout.history, ProjectSavedLayout.mediaSnapshot,
                                ProjectSavedLayout.embeddedAssets, ProjectKeyedLayout.table]

    /// The key of the edit in a plain project document, whatever order its names are in. It is
    /// formed as a key of the refs table is.
    private static func digest(_ root: [Member], canonical: Bool) -> (quoted: [UInt8], hasEscapes: Bool) {
        var hasEscapes = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func canonicalString(_ bytes: [UInt8]) -> [UInt8] {
            guard bytes.first == 0x22, bytes.contains(0x5c) else { return bytes }
            hasEscapes = true
            guard canonical, let text = try? JSONDecoder().decode(String.self, from: Data(bytes)),
                  let quoted = try? encoder.encode(text) else { return bytes }
            return Array(quoted)
        }
        func ordered(_ node: Node) -> Node {
            switch node {
            case .scalar(let text): return .scalar(canonicalString(text))
            case .array(let items): return .array(items.map(ordered))
            case .object(let members):
                return .object(members.map { Member(key: canonicalString($0.key), value: ordered($0.value)) }
                    .sorted { $0.key.lexicographicallyPrecedes($1.key) })
            }
        }
        let edit = ordered(.object(root.filter { member in !apart.contains(where: member.hasKey) }))
        return ([0x22] + ProjectKeyedLayout.key(Array(ProjectSavedLayout.text(edit, capacity: 4096))) + [0x22], hasEscapes)
    }

    /// A plain document with its history marked as belonging to its edit.
    static func stamped(_ document: Node) -> Node {
        guard case .object(var root) = document,
              let position = root.firstIndex(where: { $0.hasKey(ProjectSavedLayout.history) }),
              case .object(var history) = root[position].value else { return document }
        history.removeAll { $0.hasKey(member) }
        history.insert(Member(key: member, value: .scalar(digest(root, canonical: true).quoted)), at: 0)
        root[position].value = .object(history)
        return .object(root)
    }

    /// A plain document without the mark, and without the history when it belongs to another
    /// edit. Nil for a document whose history carries no mark.
    static func verified(_ document: Node) -> Node? {
        guard case .object(var root) = document,
              let position = root.firstIndex(where: { $0.hasKey(ProjectSavedLayout.history) }),
              case .object(var history) = root[position].value,
              let mark = history.firstIndex(where: { $0.hasKey(member) }),
              !history.dropFirst(mark + 1).contains(where: { $0.hasKey(member) }),
              !root.dropFirst(position + 1).contains(where: { $0.hasKey(ProjectSavedLayout.history) }) else { return nil }
        func matchesEdit() -> Bool {
            guard case .scalar(let saved) = history[mark].value else { return false }
            // Earlier schema 9 writers hashed the exact spelling of JSON strings.
            // Ordinary saves match on the first pass. Equivalent escape spellings
            // need a second hash only if the edit actually contains an escape.
            let literal = digest(root, canonical: false)
            if ProjectSavedLayout.matches(saved, literal.quoted) { return true }
            return literal.hasEscapes && ProjectSavedLayout.matches(saved, digest(root, canonical: true).quoted)
        }
        if matchesEdit() {
            history.remove(at: mark)
            root[position].value = .object(history)
        } else {
            root.remove(at: position)
        }
        return .object(root)
    }

    static func verified(_ plain: Data) -> Data {
        guard ProjectSavedLayout.mayContain(token, in: plain), let document = ProjectSavedLayout.parse(plain),
              let checked = verified(document) else { return plain }
        return ProjectSavedLayout.text(checked, capacity: plain.count)
    }
}
