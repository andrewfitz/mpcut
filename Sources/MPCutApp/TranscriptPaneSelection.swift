import Combine
import MPCutCore
import Foundation

struct MulticamTranscriptPlaybackPosition: Equatable {
    let time: RationalTime
    let space: TranscriptSpace

    static func resolve(output: RationalTime, readerSpace: TranscriptSpace, assemblyPreview: Bool,
                        interval: MulticamInterval?, assemblyItems: [StillAssemblyItem],
                        assemblyStart: (Int) -> RationalTime) -> Self? {
        if assemblyPreview, readerSpace != .group {
            return .init(time: output, space: .currentCut)
        }
        guard let interval, interval.output.contains(output),
              let offset = try? output.subtracting(interval.output.from),
              let group = try? interval.group.from.adding(offset) else { return nil }
        if readerSpace != .currentCut {
            return .init(time: group, space: .group)
        }
        // Group playback does not identify a replay if the assembly retains this time twice.
        var cut: RationalTime?
        for (index, item) in assemblyItems.enumerated() {
            guard let range = item.group, range.contains(group) else { continue }
            guard cut == nil, let elapsed = try? group.subtracting(range.from) else { return nil }
            cut = try? assemblyStart(index).adding(elapsed)
        }
        return cut.map { .init(time: $0, space: .currentCut) }
    }
}

extension TranscriptIndex {
    func activePanePositions(at time: RationalTime, playbackSpace: TranscriptSpace,
                             readerSpace: TranscriptSpace, scoped: TranscriptPaneWordList?) -> [Int] {
        guard readerSpace == playbackSpace || readerSpace == .source else { return [] }
        return activeWords(at: time, space: playbackSpace).compactMap { occurrence in
            let id: String
            if readerSpace == playbackSpace {
                id = occurrence.id
            } else {
                guard let source = locate(wordID: occurrence.wordID, space: .source).first(where: {
                    $0.attachmentID == occurrence.attachmentID && $0.trackID == occurrence.trackID
                        && $0.originalSourceRange == occurrence.originalSourceRange
                }) else { return nil }
                id = source.id
            }
            if let scoped { return scoped.position(of: id) }
            return position(of: id, space: readerSpace)
        }
    }

    /// A cut through a clip gives the part after it a new clip ID. `acrossClips` accepts a
    /// word the cut holds exactly once under another clip. A caller passes it for a word that
    /// the cut also held once before the edit, which rules out a replay of a deleted word.
    func revalidatedPaneWord(_ previous: TranscriptOccurrence, in space: TranscriptSpace,
                             after earlier: TranscriptIndex? = nil) -> TranscriptOccurrence? {
        let heard = paneOccurrences(of: previous, in: space)
        if let exact = heard.first(where: { $0.id == previous.id }) { return exact }
        let prior = earlier?.paneOccurrences(of: previous, in: space) ?? []
        if previous.clipID == nil, previous.assemblyIndex != nil {
            return matchingAssemblyReplay(previous, candidates: heard, prior: prior.map(TranscriptReplayAddress.init))
        }
        let candidates = heard.filter { $0.clipID == previous.clipID }
        if candidates.count == 1 { return candidates.first }
        return prior.count == 1 && candidates.isEmpty && heard.count == 1 ? heard.first : nil
    }

    /// Every place a clock holds the same stretch of the same recording as a word.
    func paneOccurrences(of word: TranscriptOccurrence, in space: TranscriptSpace) -> [TranscriptOccurrence] {
        locate(wordID: word.wordID, space: space).filter {
            $0.attachmentID == word.attachmentID && $0.trackID == word.trackID
                && $0.binding == word.binding && $0.originalSourceRange == word.originalSourceRange
                && $0.sourceRange == word.sourceRange
        }
    }
}

private struct TranscriptReplayAddress: Equatable, Sendable {
    let assemblyIndex: Int?
    let output: MulticamRange

    init(_ word: TranscriptOccurrence) {
        assemblyIndex = word.assemblyIndex
        output = word.range
    }
}

/// Multicam assembly rows have no saved IDs. When a word repeats, its set of output
/// addresses must still match before treating the old address as the same replay.
private func matchingAssemblyReplay(_ previous: TranscriptOccurrence, candidates: [TranscriptOccurrence],
                                    prior: [TranscriptReplayAddress]) -> TranscriptOccurrence? {
    if prior.count == 1 && candidates.count == 1 { return candidates.first }
    guard candidates.map(TranscriptReplayAddress.init) == prior else { return nil }
    let address = TranscriptReplayAddress(previous)
    let matches = candidates.filter { TranscriptReplayAddress($0) == address }
    return matches.count == 1 ? matches.first : nil
}

extension TranscriptIndex {
    /// The position of the word at a time, or of the last word that starts before it.
    func nearestPanePosition(to time: RationalTime, in space: TranscriptSpace) -> Int? {
        let total = read(space: space, limit: 1).total
        guard total > 0 else { return nil }
        var lower = 0
        var upper = total
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            guard let word = read(space: space, offset: middle, limit: 1).items.first else { return nil }
            if word.range.from <= time { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}

/// Where the reader is, in terms a later index can resolve. An edit gives every word a new
/// occurrence ID, so words are found again by their recording and time.
struct TranscriptReaderPlace {
    let owner: String
    let attachmentID: String?
    let resultID: String?
    let selectedAttachmentID: String?
    let scope: TranscriptPane.BrowseScope
    let searchText: String
    let query: String
    let anchor: TranscriptOccurrence?
    /// The visible word’s position in the current reader filter.
    let anchorIndex: Int
    let selectionStart: TranscriptOccurrence?
    let selectionEnd: TranscriptOccurrence?
    let matchNumber: Int?
    let matchWord: TranscriptOccurrence?
}

/// A window's reader state while its pane is hidden. Switching the multicam inspector to
/// another tab removes the pane, and a new one starts from what is kept here.
@MainActor
final class TranscriptPaneMemory {
    var place: TranscriptReaderPlace?
    /// The folder this window's transcript, caption or ISO save panel last chose. Under a Settings
    /// starting folder other than Automatic it starts those panels for the rest of the session.
    var exportFolder: URL?
}

struct TranscriptPaneWordList {
    let words: [TranscriptOccurrence]
    private let positions: [String: Int]

    init(_ words: [TranscriptOccurrence]) {
        self.words = words
        self.positions = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.id, $0.offset) })
    }

    func position(of id: String) -> Int? { positions[id] }

    func nearestPosition(to time: RationalTime) -> Int? {
        guard !words.isEmpty else { return nil }
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if words[middle].range.from <= time { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

}

@MainActor
final class TranscriptPaneBasket: ObservableObject {
    @Published var items: [TranscriptOrderedSelect] = []
    private var owner: String?

    func bind(to owner: String) {
        if let previous = self.owner, owner != previous { items = [] }
        self.owner = owner
    }
}

struct TranscriptBasketEndpoint: Sendable {
    let item: TranscriptOccurrence
    let anchor: TranscriptAnchor
    private let replays: [TranscriptReplayAddress]

    init(_ word: TranscriptOccurrence, in index: TranscriptIndex) throws {
        guard let binding = word.binding,
              let source = index.locate(wordID: word.wordID, space: .source).first(where: {
                  $0.binding == binding && $0.originalSourceRange == word.originalSourceRange
              }) else {
            throw CutError(code: "unanchored_transcript_selection", message: "Bind the passage to a source stream before adding it to ordered selects.")
        }
        self.item = word
        self.anchor = try TranscriptEditorial.anchor([source], binding: binding)
        self.replays = word.clipID == nil && word.assemblyIndex != nil
            ? index.paneOccurrences(of: word, in: .currentCut).map(TranscriptReplayAddress.init) : []
    }

    func resolve(in index: TranscriptIndex, space: TranscriptSpace, source: [TranscriptOccurrence]) throws -> TranscriptOccurrence {
        let resolved = TranscriptEditorial.reanchor(anchor, in: source)
        guard resolved.status == .resolved, let original = resolved.words.first else {
            throw endpointError(resolved.status == .ambiguous ? "The recorded wording has more than one possible source location." :
                                "The recorded wording no longer matches this source.")
        }
        if space == .source { return original }
        var candidates = index.locate(wordID: original.wordID, space: space).filter {
            $0.trackID == original.trackID && $0.originalSourceRange == original.originalSourceRange
        }
        if space == .currentCut, item.clipID == nil, item.assemblyIndex != nil {
            let replays = candidates.filter { $0.sourceRange == item.sourceRange }
            if let replay = matchingAssemblyReplay(item, candidates: replays, prior: self.replays) {
                return replay
            }
            throw endpointError("The recorded passage no longer identifies the same replay.")
        }
        if let clip = item.clipID {
            candidates = candidates.filter { $0.clipID == clip }
        }
        if candidates.count == 1, let candidate = candidates.first { return candidate }
        throw endpointError(candidates.isEmpty ? "The recorded passage has no retained occurrence." :
                            "The recorded passage now has more than one retained occurrence.")
    }

    private func endpointError(_ explanation: String) -> CutError {
        CutError(code: "unresolved_transcript_select", message: explanation)
    }
}

struct TranscriptOrderedSelect: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let source: String
    let attachmentID: String
    let space: TranscriptSpace
    let first: TranscriptBasketEndpoint
    let last: TranscriptBasketEndpoint
    let originalTerms: [String]

    func resolve(in index: TranscriptIndex) throws -> TranscriptWordSelection {
        guard index.attachment?.id == attachmentID else {
            throw CutError(code: "unresolved_transcript_select", message: "The original transcript attachment is unavailable.")
        }
        let source = index.readAll(space: .source)
        let start = try first.resolve(in: index, space: space, source: source)
        let end = try last.resolve(in: index, space: space, source: source)
        let between = transcriptWords(from: start, through: end, in: index, space: space)
        guard between.flatMap({ TranscriptEditorial.terms($0.originalText) }) == originalTerms else {
            throw CutError(code: "unresolved_transcript_select", message: "Speech between the recorded endpoints has changed.")
        }
        return transcriptAddress(from: start, through: end, space: space, attachment: attachmentID)
    }
}

func transcriptWords(from first: TranscriptOccurrence, through last: TranscriptOccurrence,
                     in index: TranscriptIndex, space: TranscriptSpace) -> [TranscriptOccurrence] {
    if first.id == last.id { return [first] }
    guard let a = index.position(of: first.id, space: space),
          let b = index.position(of: last.id, space: space) else { return [] }
    var result: [TranscriptOccurrence] = []
    var cursor = min(a, b)
    let end = max(a, b)
    while cursor <= end {
        let page = index.read(space: space, offset: cursor, limit: min(500, end - cursor + 1))
        guard !page.items.isEmpty else { break }
        if space == .source { result += page.items.filter { $0.trackID == first.trackID } }
        else { result += page.items }
        cursor += page.items.count
    }
    return result
}

func transcriptWording(_ words: [TranscriptOccurrence]) -> String {
    var seen = Set<String>()
    return words.filter { seen.insert($0.id).inserted }
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func transcriptAddress(from first: TranscriptOccurrence, through last: TranscriptOccurrence,
                       space: TranscriptSpace, attachment: String?,
                       kind: TranscriptWordSelection.Kind = .phrase, leading: RationalTime? = nil,
                       trailing: RationalTime? = nil) -> TranscriptWordSelection {
    TranscriptWordSelection(firstWordID: first.wordID, lastWordID: last.wordID, space: space,
                            firstOccurrenceID: first.id, lastOccurrenceID: last.id, kind: kind,
                            leadingPadding: leading, trailingPadding: trailing, attachmentID: attachment)
}
