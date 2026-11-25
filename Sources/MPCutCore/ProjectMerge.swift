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

    private static let assetsKey = Array(#""embedded_assets""#.utf8)
    private static let entries = Array(#""entries""#.utf8)
    private static let path = Array(#""path""#.utf8)

    package struct Inputs {
        package let base: Data
        package let ours: Data
        package let theirs: Data
        fileprivate let assets: Data?

        /// Restore the union in both clean results and documents with conflict markers.
        /// All three inputs use the same root line, so Git never diffs the payloads.
        package func restoringAssets(in merged: Data) throws -> Data {
            guard let assets else { return merged }
            let marker = Data("\n  \"embedded_assets\": {}".utf8)
            guard var match = merged.range(of: marker) else { throw ProjectMerge.invalidAssets() }
            var restored = Data()
            var start = merged.startIndex
            repeat {
                restored.append(merged[start..<(match.upperBound - 2)])
                restored.append(assets)
                start = match.upperBound
                guard let next = merged.range(of: marker, in: start..<merged.endIndex) else { break }
                match = next
            } while true
            restored.append(merged[start..<merged.endIndex])
            return restored
        }
    }

    /// The three sides as text for a line merge. An empty `base` is a project both branches added.
    package static func sides(base: Data, ours: Data, theirs: Data) throws -> Inputs {
        let before = base.isEmpty ? nil : try members(base)
        var mine = try members(ours)
        var other = try members(theirs)
        var ancestor = before ?? []
        try mergeIndependentReviewChoices(base: &ancestor, ours: &mine, theirs: &other)
        let snapshot = try merged(base: take(mediaSnapshot: &ancestor), ours: take(mediaSnapshot: &mine),
                                  theirs: take(mediaSnapshot: &other))
        // Once the inputs have been verified, a digest names the same immutable
        // payload on every branch. Keep those bytes out of competing line edits.
        var assets: [[UInt8]: [[UInt8]: Node]] = [:]
        for side in [ancestor, mine, other] {
            guard let asset = side.first(where: { $0.key == assetsKey }) else { continue }
            guard case .object(let collections) = asset.value else { throw invalidAssets() }
            for collection in collections {
                guard case .object(let items) = collection.value else { throw invalidAssets() }
                let name = try normalizedKey(collection.key)
                for item in items {
                    let digest = try normalizedKey(item.key)
                    assets[name, default: [:]][digest] = item.value
                }
            }
        }
        let union = Node.object(assets.map { collection, items in
            Member(key: collection, value: .object(items.map { Member(key: $0.key, value: $0.value) }
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }))
        }.sorted { $0.key.lexicographicallyPrecedes($1.key) })
        func text(_ members: [Member], capacity: Int) -> Data {
            var members = members.filter { $0.key != ProjectSavedLayout.history && $0.key != assetsKey }
            if !assets.isEmpty { members.append(Member(key: assetsKey, value: .object([]))) }
            if let snapshot { members.append(Member(key: ProjectSavedLayout.mediaSnapshot, value: snapshot)) }
            return ProjectSavedLayout.readable(.object(members), capacity: capacity)
        }
        return Inputs(base: before == nil ? Data() : text(ancestor, capacity: 4096),
                      ours: text(mine, capacity: 4096), theirs: text(other, capacity: 4096),
                      assets: assets.isEmpty ? nil : ProjectSavedLayout.text(union, capacity: 4096))
    }

    /// The merged text as MPCut saves a project. Lines that merge can still make a project
    /// MPCut refuses, such as one with the same clip twice, so the result is opened first.
    package static func saved(_ merged: Data) throws -> Data {
        guard !merged.contains(0), String(data: merged, encoding: .utf8) != nil,
              case .object(let members)? = ProjectSavedLayout.parse(merged) else {
            throw CutError(code: "invalid_cut_project", message: "The merged project is not a JSON object.")
        }
        let project = try CutProject.decode(merged)
        var root = try normalizedMembers(members)
        guard let position = root.firstIndex(where: { $0.key == assetsKey }),
              case .object(let collections) = root[position].value else {
            return try ProjectFile.diskBytes(merged, prefix: "cut")
        }
        let used: [[UInt8]: Set<String>] = [
            Array(#""transcripts""#.utf8): Set(project.transcripts.attachments.map { $0.asset.sha256 }),
            Array(#""tile_scans""#.utf8): Set(project.participants.pendingReviews.map(\.scanSHA256))
        ]
        let retained = try normalizedMembers(collections).compactMap { collection -> Member? in
            guard let keys = used[collection.key], case .object(let items) = collection.value else { return nil }
            let itemsInEdit = try normalizedMembers(items).filter {
                keys.contains(String(decoding: $0.key.dropFirst().dropLast(), as: UTF8.self))
            }
            return itemsInEdit.isEmpty ? nil : Member(key: collection.key, value: .object(itemsInEdit))
        }
        if retained.isEmpty { root.remove(at: position) }
        else { root[position].value = .object(retained) }
        return try ProjectFile.diskBytes(ProjectSavedLayout.text(.object(root), capacity: 4096), prefix: "cut")
    }

    private static func members(_ saved: Data) throws -> [Member] {
        _ = try CutProject.decode(saved)
        let plain = try ProjectFile.documentJSON(saved)
        guard !plain.contains(0), String(data: plain, encoding: .utf8) != nil,
              let document = ProjectSavedLayout.parse(plain), case .object(let members) = document else {
            throw CutError(code: "invalid_cut_project", message: "Project must contain a UTF-8 JSON object")
        }
        return try normalizedMembers(members)
    }

    private static func normalizedKey(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.contains(0x5C) else { return bytes }
        let name = try JSONDecoder().decode(String.self, from: Data(bytes))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try Array(encoder.encode(name))
    }

    private static func normalizedMembers(_ members: [Member]) throws -> [Member] {
        try members.map { Member(key: try normalizedKey($0.key), value: $0.value) }
    }

    /// Present independently edited choices as identical lines to the text merge.
    /// A genuine conflict keeps its original three values for Git to mark.
    private static func mergeIndependentReviewChoices(base: inout [Member], ours: inout [Member], theirs: inout [Member]) throws {
        let participants = Array(#""participants""#.utf8)
        let pending = Array(#""pending_reviews""#.utf8)
        let choices = Array(#""choices""#.utf8)
        let unchecked = Array(#""unchecked""#.utf8)
        let id = Array(#""id""#.utf8)
        let scan = Array(#""scan_sha256""#.utf8)

        func field(_ members: [Member], _ key: [UInt8]) -> Node? {
            members.first { $0.key == key }?.value
        }
        func reviews(_ root: [Member]) -> [[UInt8]: [Member]] {
            guard case .object(let roster)? = field(root, participants),
                  case .array(let rows)? = field(roster, pending) else { return [:] }
            var byID: [[UInt8]: [Member]] = [:]
            for row in rows {
                if case .object(let members) = row, case .scalar(let key)? = field(members, id) { byID[key] = members }
            }
            return byID
        }
        enum ChoiceConflict: Error { case competingChanges }
        func combine(_ before: Node?, _ mine: Node?, _ other: Node?, reviewChoices: Bool = false) throws -> Node? {
            if mine == before { return other }
            if other == before || mine == other { return mine }
            guard case .object(let a)? = before, case .object(let b)? = mine, case .object(let c)? = other else {
                throw ChoiceConflict.competingChanges
            }
            let keys = Set(a.map(\.key)).union(b.map(\.key)).union(c.map(\.key))
            return try .object(keys.sorted(by: { $0.lexicographicallyPrecedes($1) }).compactMap { key in
                let old = field(a, key), left = field(b, key), right = field(c, key)
                if reviewChoices && key == unchecked {
                    func excluded(_ node: Node?) throws -> Set<String> {
                        guard let node else { return [] }
                        return try JSONDecoder().decode(Set<String>.self, from: ProjectSavedLayout.text(node, capacity: 128))
                    }
                    let original = try excluded(old), mine = try excluded(left), theirs = try excluded(right)
                    let kept = original.intersection(mine).intersection(theirs)
                    let added = mine.union(theirs).subtracting(original)
                    let ids = try kept.union(added).sorted().map { Node.scalar(Array(try JSONEncoder().encode($0))) }
                    return Member(key: key, value: .array(ids))
                }
                return try combine(old, left, right).map { Member(key: key, value: $0) }
            })
        }

        let before = reviews(base), mine = reviews(ours), other = reviews(theirs)
        var resolved: [[UInt8]: Node] = [:]
        for (key, review) in before {
            guard let b = mine[key], let c = other[key], field(review, scan) == field(b, scan),
                  field(review, scan) == field(c, scan), let a = field(review, choices),
                  let left = field(b, choices), let right = field(c, choices), left != a, right != a else { continue }
            if let combined = try? combine(a, left, right, reviewChoices: true) {
                let changes = try JSONDecoder().decode(TilesReviewChoices.self, from: ProjectSavedLayout.text(combined, capacity: 256))
                // Keep both original edits in the line merge so the user can resolve overlapping feed merges.
                guard TilesReviewChoices.validMerges(changes.merged) else { continue }
                resolved[key] = combined
            }
        }
        guard !resolved.isEmpty else { return }
        func apply(_ root: inout [Member]) {
            guard let p = root.firstIndex(where: { $0.key == participants }), case .object(var roster) = root[p].value,
                  let r = roster.firstIndex(where: { $0.key == pending }), case .array(var rows) = roster[r].value else { return }
            for i in rows.indices {
                guard case .object(var members) = rows[i], case .scalar(let key)? = field(members, id),
                      let merged = resolved[key], let position = members.firstIndex(where: { $0.key == choices }) else { continue }
                members[position].value = merged
                rows[i] = .object(members)
            }
            roster[r].value = .array(rows)
            root[p].value = .object(roster)
        }
        apply(&base)
        apply(&ours)
        apply(&theirs)
    }

    private static func invalidAssets() -> CutError {
        CutError(code: "invalid_cut_project", message: "Invalid embedded asset table in project merge.")
    }

    private static func take(mediaSnapshot members: inout [Member]) throws -> [Member]? {
        guard let position = members.firstIndex(where: { $0.key == ProjectSavedLayout.mediaSnapshot }) else { return nil }
        guard case .object(let snapshot) = members.remove(at: position).value else { return nil }
        return try normalizedMembers(snapshot)
    }

    /// One snapshot from three. A recording keeps the entry of the branch that changed it, and
    /// ours when both did. One that a branch dropped and the other left alone stays dropped.
    private static func merged(base: [Member]?, ours: [Member]?, theirs: [Member]?) throws -> Node? {
        guard let header = ours ?? theirs else { return nil }
        func recordings(_ snapshot: [Member]?) throws -> [[UInt8]: Node] {
            guard case .array(let items)? = snapshot?.first(where: { $0.key == entries })?.value else { return [:] }
            var held: [[UInt8]: Node] = [:]
            for item in items {
                guard case .object(let fields) = item else { continue }
                var members = try normalizedMembers(fields)
                guard let position = members.firstIndex(where: { $0.key == path }),
                      case .scalar(let name) = members[position].value,
                      ProjectSavedLayout.isString(name) else { continue }
                let key = try normalizedKey(name)
                members[position].value = .scalar(key)
                held[key] = .object(members)
            }
            return held
        }
        let before = try recordings(base)
        let other = try recordings(theirs)
        var result = try recordings(ours)
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
