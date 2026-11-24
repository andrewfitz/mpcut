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
    private static let apart = [ProjectSavedLayout.history, ProjectSavedLayout.mediaSnapshot, ProjectKeyedLayout.table]

    /// The key of the edit in a plain project document, whatever order its names are in. It is
    /// formed as a key of the refs table is.
    static func digest(_ root: [Member]) -> Node {
        func ordered(_ node: Node) -> Node {
            switch node {
            case .scalar: return node
            case .array(let items): return .array(items.map(ordered))
            case .object(let members):
                return .object(members.map { Member(key: $0.key, value: ordered($0.value)) }
                    .sorted { $0.key.lexicographicallyPrecedes($1.key) })
            }
        }
        let edit = ordered(.object(root.filter { !apart.contains($0.key) }))
        return .scalar([0x22] + ProjectKeyedLayout.key(Array(ProjectSavedLayout.text(edit, capacity: 4096))) + [0x22])
    }

    /// A plain document with its history marked as belonging to its edit.
    static func stamped(_ document: Node) -> Node {
        guard case .object(var root) = document,
              let position = root.firstIndex(where: { $0.key == ProjectSavedLayout.history }),
              case .object(var history) = root[position].value else { return document }
        history.removeAll { $0.key == member }
        history.insert(Member(key: member, value: digest(root)), at: 0)
        root[position].value = .object(history)
        return .object(root)
    }

    /// A plain document without the mark, and without the history when it belongs to another
    /// edit. Nil for a document whose history carries no mark.
    static func verified(_ document: Node) -> Node? {
        guard case .object(var root) = document,
              let position = root.firstIndex(where: { $0.key == ProjectSavedLayout.history }),
              case .object(var history) = root[position].value,
              let mark = history.firstIndex(where: { $0.key == member }) else { return nil }
        if history[mark].value == digest(root) {
            history.remove(at: mark)
            root[position].value = .object(history)
        } else {
            root.remove(at: position)
        }
        return .object(root)
    }

    static func verified(_ plain: Data) -> Data {
        guard plain.range(of: token) != nil, let document = ProjectSavedLayout.parse(plain),
              let checked = verified(document) else { return plain }
        return ProjectSavedLayout.text(checked, capacity: plain.count)
    }
}
