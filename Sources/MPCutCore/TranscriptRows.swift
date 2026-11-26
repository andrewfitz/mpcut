import Foundation

/// Transcript reads answer in compact rows unless the request sets `verbose`. A full word record is about
/// 2 KB of binding, lane and evidence fields. A compact row keeps what reading and selecting need.
package enum TranscriptRows {
    /// Keys a compact word keeps as they are.
    private static let kept = ["id", "word_id", "text", "speaker_id", "speaker_name", "attachment_id", "source_id", "file"]
    /// The transcript and recording repeat on every row. A value shared by a whole page is reported once.
    private static let shared = ["attachment_id", "file", "source_id"]

    private static func isWord(_ value: [String: Any]) -> Bool {
        value["word_id"] is String && value["range"] is [String: Any] && value["timeline_revision"] != nil
    }

    private static func isMatch(_ value: [String: Any]) -> Bool {
        guard let words = value["words"] as? [[String: Any]], let first = words.first else { return false }
        return isWord(first) && value["before"] is [Any] && value["after"] is [Any]
    }

    package static func word(_ full: [String: Any]) -> [String: Any] {
        var row = full.filter { kept.contains($0.key) }
        let range = full["range"] as? [String: Any]
        row["from"] = range?["from"]
        row["to"] = range?["to"]
        // Report a flag only where it departs from an ordinary recognized word.
        if let original = full["original_text"] as? String, original != full["text"] as? String { row["original_text"] = original }
        if full["precision"] as? String == "cue" { row["precision"] = "cue" }
        if full["audibility"] as? String == "inferred" { row["audibility"] = "inferred" }
        for flag in ["partial", "approximate", "stale_matches"] where full[flag] as? Bool == true { row[flag] = true }
        return row
    }

    private static func text(_ words: [[String: Any]]) -> String {
        words.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    /// One row for a run of words, with the four identifiers a selection takes.
    private static func span(_ words: [[String: Any]]) -> [String: Any] {
        guard let first = words.first, let last = words.last else { return [:] }
        var row: [String: Any] = ["text": text(words), "words": words.count]
        for key in ["speaker_id", "speaker_name", "attachment_id", "source_id", "file"] { row[key] = first[key] }
        row["from"] = (first["range"] as? [String: Any])?["from"]
        row["to"] = (last["range"] as? [String: Any])?["to"]
        row["first_word_id"] = first["word_id"]
        row["first_occurrence_id"] = first["id"]
        row["last_word_id"] = last["word_id"]
        row["last_occurrence_id"] = last["id"]
        return row
    }

    /// Compacts every word record in a result, and each phrase match or take to one row with its context as text.
    package static func compact(_ value: Any) -> Any {
        if let list = value as? [Any] { return list.map(compact) }
        guard var object = value as? [String: Any] else { return value }
        if isWord(object) { return word(object) }
        if isMatch(object), let words = object["words"] as? [[String: Any]] {
            let before = object["before"] as? [[String: Any]] ?? [], after = object["after"] as? [[String: Any]] ?? []
            for key in ["words", "before", "after"] { object[key] = nil }
            var row = object.mapValues(compact)
            row.merge(span(words)) { _, new in new }
            if !before.isEmpty { row["before"] = text(before) }
            if !after.isEmpty { row["after"] = text(after) }
            return row
        }
        return object.mapValues(compact)
    }

    /// Groups a page of words into dialogue lines: one row per utterance of one speaker in one clip.
    package static func lines(_ words: [[String: Any]]) -> [[String: Any]] {
        func seconds(_ word: [String: Any], _ edge: String) -> Double? {
            ((word["range"] as? [String: Any])?[edge] as? String).flatMap { try? RationalTime(parsing: $0).seconds }
        }
        func key(_ word: [String: Any]) -> [String?] {
            ["attachment_id", "speaker_id", "utterance_id", "clip_id", "source_id", "file"].map { word[$0] as? String }
                + [(word["assembly_index"] as? Int).map(String.init)]
        }
        var rows: [[String: Any]] = [], run: [[String: Any]] = []
        for word in words {
            if let last = run.last {
                let pause = (seconds(word, "from") ?? 0) - (seconds(last, "to") ?? 0)
                if key(last) != key(word) || pause > 2 || run.count >= 80 {
                    rows.append(span(run))
                    run = []
                }
            }
            run.append(word)
        }
        if !run.isEmpty { rows.append(span(run)) }
        return rows
    }

    /// Moves a recording identity that every row repeats to one top-level `shared` object.
    package static func hoist(_ page: inout [String: Any]) {
        guard let rows = page["items"] as? [[String: Any]], rows.count > 1 else { return }
        var common: [String: Any] = [:]
        for key in shared {
            guard let value = rows[0][key] as? String, rows.allSatisfy({ $0[key] as? String == value }) else { continue }
            common[key] = value
        }
        guard !common.isEmpty else { return }
        page["shared"] = common
        page["items"] = rows.map { row in row.filter { common[$0.key] == nil } }
    }

    /// A page as a reader asked for it: full records, compact rows, or dialogue lines for a page of words.
    /// The live tools, the command line and the saved-file tools all answer through this.
    package static func project(_ page: [String: Any], verbose: Bool, lines grouped: Bool) -> [String: Any] {
        guard !verbose else { return page }
        var compacted = page
        if grouped, let words = page["items"] as? [[String: Any]] {
            compacted["items"] = lines(words)
            compacted["words"] = words.count
            // The other lists on the page still hold word records.
            for (key, value) in page where key != "items" { compacted[key] = compact(value) }
        } else {
            compacted = compact(page) as? [String: Any] ?? page
        }
        hoist(&compacted)
        return compacted
    }
}
