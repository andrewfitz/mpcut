import Foundation

/// Merging two branches of a project file in version control.
///
/// A line merge of the saved files meets conflicts that are not disagreements about the edit:
/// each branch saved its own undo history in the same place, and each may have added a
/// recording to the media snapshot or the refs table in the same gap. The merge here hands
/// the line merge only the edit. Each side is written as the plain document with no history,
/// since undo steps of two branches cannot be combined, and with one media snapshot already
/// merged recording by recording, the same on all three sides.
package enum ProjectMerge {
    typealias Node = ProjectSavedLayout.Node
    typealias Member = ProjectSavedLayout.Member

    private static let entries = Array(#""entries""#.utf8)
    private static let path = Array(#""path""#.utf8)

    /// The three sides as text for a line merge. An empty `base` is a project both branches added.
    package static func sides(base: Data, ours: Data, theirs: Data) throws -> (base: Data, ours: Data, theirs: Data) {
        let before = base.isEmpty ? nil : try members(base)
        var mine = try members(ours)
        var other = try members(theirs)
        var ancestor = before ?? []
        let snapshot = merged(base: take(mediaSnapshot: &ancestor), ours: take(mediaSnapshot: &mine),
                              theirs: take(mediaSnapshot: &other))
        func text(_ members: [Member], capacity: Int) -> Data {
            var members = members.filter { $0.key != ProjectSavedLayout.history }
            if let snapshot { members.append(Member(key: ProjectSavedLayout.mediaSnapshot, value: snapshot)) }
            return ProjectSavedLayout.readable(.object(members), capacity: capacity)
        }
        return (before == nil ? Data() : text(ancestor, capacity: base.count),
                text(mine, capacity: ours.count), text(other, capacity: theirs.count))
    }

    /// The merged text as MPCut saves a project. Lines that merge can still make a project
    /// MPCut refuses, such as one with the same clip twice, so the result is opened first.
    package static func saved(_ merged: Data) throws -> Data {
        guard !merged.contains(0), String(data: merged, encoding: .utf8) != nil,
              let document = ProjectSavedLayout.parse(merged), case .object = document else {
            throw CutError(code: "invalid_cut_project", message: "The merged project is not a JSON object.")
        }
        let saved = try ProjectFile.diskBytes(merged, prefix: "cut")
        _ = try CutProject.decode(saved)
        return saved
    }

    private static func members(_ saved: Data) throws -> [Member] {
        let plain = try ProjectFile.documentJSON(saved)
        guard !plain.contains(0), String(data: plain, encoding: .utf8) != nil,
              let document = ProjectSavedLayout.parse(plain), case .object(let members) = document else {
            throw CutError(code: "invalid_cut_project", message: "Project must contain a UTF-8 JSON object")
        }
        return members
    }

    private static func take(mediaSnapshot members: inout [Member]) -> [Member]? {
        guard let position = members.firstIndex(where: { $0.key == ProjectSavedLayout.mediaSnapshot }) else { return nil }
        guard case .object(let snapshot) = members.remove(at: position).value else { return nil }
        return snapshot
    }

    /// One snapshot from three. A recording keeps the entry of the branch that changed it, and
    /// ours when both did. One that a branch dropped and the other left alone stays dropped.
    private static func merged(base: [Member]?, ours: [Member]?, theirs: [Member]?) -> Node? {
        guard let header = ours ?? theirs else { return nil }
        func recordings(_ snapshot: [Member]?) -> [[UInt8]: Node] {
            guard case .array(let items)? = snapshot?.first(where: { $0.key == entries })?.value else { return [:] }
            var held: [[UInt8]: Node] = [:]
            for item in items {
                guard case .object(let members) = item,
                      case .scalar(let name)? = members.first(where: { $0.key == path })?.value else { continue }
                held[name] = item
            }
            return held
        }
        let before = recordings(base)
        let other = recordings(theirs)
        var result = recordings(ours)
        for (name, entry) in other {
            if let mine = result[name] {
                if mine == before[name] { result[name] = entry }
            } else if before[name] != entry {
                result[name] = entry
            }
        }
        for (name, entry) in before where other[name] == nil && result[name] == entry {
            result[name] = nil
        }
        let ordered = result.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value)
        var members = header.filter { $0.key != entries }
        members.append(Member(key: entries, value: .array(ordered)))
        return .object(members)
    }
}
