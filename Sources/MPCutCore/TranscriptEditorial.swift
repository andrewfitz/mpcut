import Foundation

public struct TranscriptTake: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case words
        case before
        case after
        case kind
        case missingTerms = "missing_terms"
        case additionalTerms = "additional_terms"
    }
    public let words: [TranscriptOccurrence]
    public let before: [TranscriptOccurrence]
    public let after: [TranscriptOccurrence]
    public let kind: TranscriptTakeKind
    public let missingTerms: [String]
    public let additionalTerms: [String]
}

public enum TranscriptTakeKind: String, Codable, Sendable {
    case exact, approximate, partial
}

public enum TranscriptScriptStatus: String, Codable, Sendable {
    case exact, approximate, partial, missing, ambiguous
}

public struct TranscriptQualifier: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case text
        case presentIn = "present_in"
        case absentFrom = "absent_from"
    }
    public let text: String
    public let presentIn: [String]
    public let absentFrom: [String]
}

public struct TranscriptScriptBeat: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case text
        case status
        case candidates
        case qualifiers
        case approximateSearch = "approximate_search"
    }
    public let text: String
    public let status: TranscriptScriptStatus
    public let candidates: [TranscriptTake]
    public let qualifiers: [TranscriptQualifier]
    public let approximateSearch: Bool
}

public struct TranscriptSuggestion: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case filler, repetition, restart
    }

    public let id: String
    public let kind: Kind
    public let candidate: TranscriptTake
    public let continuation: TranscriptTake?
}

public enum TranscriptEditorial {
    public static let maximumApproximateTerms = 256

    public static func terms(_ text: String) -> [String] {
        TranscriptIndex.tokens(text)
    }

    public static func compare(_ phrase: String, words: [TranscriptOccurrence],
                               contextWords: Int = 8) -> [TranscriptTake] {
        let query = terms(phrase)
        guard !query.isEmpty else { return [] }
        var vocabulary = Vocabulary()
        let passages = passages(words, vocabulary: &vocabulary)
        let codes = vocabulary.codes(ofLine: query)
        return passages.flatMap { align(query, codes: codes, in: $0, context: contextWords) }.sorted(by: chronological)
    }

    public static func alignScript(_ script: String, words: [TranscriptOccurrence],
                                   contextWords: Int = 8) -> [TranscriptScriptBeat] {
        alignScript(scriptLines(script)[...], words: words, contextWords: contextWords)
    }

    public static func alignScriptPage(_ script: String, words: [TranscriptOccurrence], offset: Int = 0,
                                       limit: Int = 100, contextWords: Int = 8) -> TranscriptPage<TranscriptScriptBeat> {
        let lines = scriptLines(script)
        let offset = max(0, offset)
        let page = lines.dropFirst(offset).prefix(min(500, max(1, limit)))
        return .init(items: alignScript(page, words: words, contextWords: contextWords),
                     total: lines.count, offset: offset)
    }

    private struct ScriptLine {
        let text: String
        let terms: [String]
    }

    private static func scriptLines(_ script: String) -> [ScriptLine] {
        script.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            let tokens = terms(text)
            return tokens.isEmpty ? nil : ScriptLine(text: text, terms: tokens)
        }
    }

    private static func alignScript(_ lines: ArraySlice<ScriptLine>, words: [TranscriptOccurrence],
                                    contextWords: Int) -> [TranscriptScriptBeat] {
        guard !lines.isEmpty else { return [] }
        var vocabulary = Vocabulary()
        let passages = passages(words, vocabulary: &vocabulary)
        var beats: [TranscriptScriptBeat] = []
        for line in lines {
            guard !Task.isCancelled else { return [] }
            let codes = vocabulary.codes(ofLine: line.terms)
            let candidates = passages.flatMap { align(line.terms, codes: codes, in: $0, context: contextWords) }
                .sorted(by: chronological)
            let exact = candidates.filter { $0.kind == .exact }.count
            let status: TranscriptScriptStatus
            if exact > 1 || (exact == 0 && candidates.count > 1) { status = .ambiguous }
            else if exact == 1 { status = .exact }
            else if let first = candidates.first { status = first.kind == .partial ? .partial : .approximate }
            else { status = .missing }
            let possibleQualifiers = Set(candidates.flatMap { $0.missingTerms + $0.additionalTerms })
            let candidateTerms = possibleQualifiers.isEmpty ? [] : candidates.map { Set($0.words.flatMap { terms($0.text) }) }
            let qualifiers = possibleQualifiers.sorted().compactMap { term -> TranscriptQualifier? in
                let present = zip(candidates, candidateTerms).compactMap { candidate, tokens in
                    tokens.contains(term) ? candidate.words.first?.id : nil
                }
                let absent = zip(candidates, candidateTerms).compactMap { candidate, tokens in
                    tokens.contains(term) ? nil : candidate.words.first?.id
                }
                guard !present.isEmpty, !absent.isEmpty else { return nil }
                return .init(text: term, presentIn: present, absentFrom: absent)
            }
            beats.append(.init(text: line.text, status: status, candidates: candidates, qualifiers: qualifiers,
                               approximateSearch: (2...maximumApproximateTerms).contains(line.terms.count)))
        }
        return Task.isCancelled ? [] : beats
    }

    public static func suggest(words: [TranscriptOccurrence], fillerTerms: [String] = []) -> [TranscriptSuggestion] {
        var result: [TranscriptSuggestion] = []
        var ids: Set<String> = []
        let fillers = Set(fillerTerms.map(terms)).filter { !$0.isEmpty }
        for passage in passages(words) {
            guard !Task.isCancelled else { return [] }
            func append(_ kind: TranscriptSuggestion.Kind, _ range: Range<Int>, continuation: Range<Int>? = nil) {
                guard passage.isWordBounded(range),
                      continuation.map(passage.isWordBounded) ?? true else { return }
                let candidate = passage.take(range, context: 8)
                let next = continuation.map { passage.take($0, context: 8) }
                guard let first = candidate.words.first, let last = candidate.words.last else { return }
                let id = [kind.rawValue, first.id, last.id, next?.words.first?.id ?? ""].joined(separator: "|")
                if ids.insert(id).inserted {
                    result.append(.init(id: id, kind: kind, candidate: candidate, continuation: next))
                }
            }
            for filler in fillers {
                for start in exactStarts(filler, in: passage.tokens) {
                    append(.filler, start..<start + filler.count)
                }
            }
            let tokens = passage.tokens
            guard tokens.count >= 2 else { continue }
            for start in tokens.indices where start + 1 < tokens.count {
                if start.isMultiple(of: 256), Task.isCancelled { return [] }
                let maxDistance = min(14, tokens.count - start - 1)
                for distance in 1...maxDistance {
                    let next = start + distance
                    guard tokens[start] == tokens[next] else { continue }
                    let firstWord = passage.words[passage.wordIndices[start]]
                    let nextWord = passage.words[passage.wordIndices[next]]
                    guard nextWord.range.from.seconds - firstWord.range.from.seconds <= 5 else { break }
                    var common = 1
                    let maxCommon = min(distance, tokens.count - next)
                    while common < maxCommon, tokens[start + common] == tokens[next + common] { common += 1 }
                    if start > 0, tokens[start - 1] == tokens[next - 1] { continue }
                    if common == distance {
                        append(.repetition, start..<next, continuation: next..<next + common)
                        break
                    }
                    if common >= 2 {
                        append(.restart, start..<next, continuation: next..<next + common)
                        break
                    }
                }
            }
        }
        return result.sorted {
            if chronological($0.candidate, $1.candidate) { return true }
            if chronological($1.candidate, $0.candidate) { return false }
            return $0.id < $1.id
        }
    }

    private struct PassageKey: Hashable {
        let attachment: String?
        let clip: String?
        let assembly: Int?
        let binding: TranscriptBinding?
        let track: String?
        let speaker: String?
    }

    /// Numbers the distinct terms of a transcript so passages compare integers instead of strings.
    private struct Vocabulary {
        private var codes: [String: Int] = [:]
        // Speech repeats a small set of spellings. Tokenizing each once avoids
        // folding the same text for every occurrence.
        private var termsByText: [String: [Int]] = [:]
        private let textLimit = 4_096
        private(set) var names: [String] = []

        mutating func code(_ term: String) -> Int {
            if let code = codes[term] { return code }
            codes[term] = names.count
            names.append(term)
            return names.count - 1
        }

        mutating func codes(in text: String) -> [Int] {
            if let known = termsByText[text] { return known }
            let result = TranscriptEditorial.terms(text).map { code($0) }
            if termsByText.count < textLimit { termsByText[text] = result }
            return result
        }

        /// A term the transcript never uses gets a negative number of its own, so it equals
        /// its repeats in the same line and nothing that was said.
        func codes(ofLine terms: [String]) -> [Int] {
            var unspoken: [String: Int] = [:]
            return terms.map { term in
                if let code = codes[term] ?? unspoken[term] { return code }
                let code = -1 - unspoken.count
                unspoken[term] = code
                return code
            }
        }
    }

    private struct Passage {
        let words: [TranscriptOccurrence]
        let tokens: [String]
        /// `tokens` as vocabulary numbers.
        let codes: [Int]
        let wordIndices: [Int]

        init(words: [TranscriptOccurrence], vocabulary: inout Vocabulary) {
            self.words = words
            var tokens: [String] = []
            var codes: [Int] = []
            var wordIndices: [Int] = []
            for (index, word) in words.enumerated() {
                let terms = vocabulary.codes(in: word.text)
                codes.append(contentsOf: terms)
                tokens.append(contentsOf: terms.map { vocabulary.names[$0] })
                wordIndices.append(contentsOf: repeatElement(index, count: terms.count))
            }
            self.tokens = tokens
            self.codes = codes
            self.wordIndices = wordIndices
        }

        func isWordBounded(_ range: Range<Int>) -> Bool {
            guard !range.isEmpty else { return false }
            return (range.lowerBound == 0 || wordIndices[range.lowerBound - 1] != wordIndices[range.lowerBound])
                && (range.upperBound == tokens.count || wordIndices[range.upperBound - 1] != wordIndices[range.upperBound])
        }

        func utteranceRange(containing range: Range<Int>, maximumExtra: Int) -> Range<Int>? {
            let initialFirst = wordIndices[range.lowerBound]
            let initialLast = wordIndices[range.upperBound - 1]
            func separates(_ left: Int, _ right: Int) -> Bool {
                let prior = words[left]
                let next = words[right]
                let ending = prior.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"’”)]")))
                if ending.last.map({ ".?!…".contains($0) }) == true { return true }
                if let first = prior.utteranceID, let second = next.utteranceID, first != second { return true }
                return next.range.from.seconds - prior.range.to.seconds > 1.2
            }
            if initialFirst < initialLast,
               (initialFirst..<initialLast).contains(where: { separates($0, $0 + 1) }) { return nil }
            var first = range.lowerBound
            while first > 0 {
                let previous = wordIndices[first - 1]
                let current = wordIndices[first]
                if previous != current, separates(previous, current) { break }
                first -= 1
                if range.lowerBound - first > maximumExtra { return nil }
            }
            var end = range.upperBound
            while end < tokens.count {
                let previous = wordIndices[end - 1]
                let current = wordIndices[end]
                if previous != current, separates(previous, current) { break }
                end += 1
                if range.lowerBound - first + end - range.upperBound > maximumExtra { return nil }
            }
            return first..<end
        }

        func take(_ range: Range<Int>, context: Int, kind: TranscriptTakeKind = .exact,
                  missing: [String] = [], extra: [String] = []) -> TranscriptTake {
            let start = wordIndices[range.lowerBound]
            var end = wordIndices[range.upperBound - 1] + 1
            if let replacement = words[end - 1].textReplacementID {
                while end < words.count, words[end].textReplacementID == replacement, words[end].text.isEmpty {
                    end += 1
                }
            }
            let before = start - min(start, max(0, context))
            let after = end + min(words.count - end, max(0, context))
            return .init(words: Array(words[start..<end]), before: Array(words[before..<start]),
                         after: Array(words[end..<after]), kind: kind, missingTerms: missing, additionalTerms: extra)
        }
    }

    private static func passages(_ words: [TranscriptOccurrence]) -> [Passage] {
        var vocabulary = Vocabulary()
        return passages(words, vocabulary: &vocabulary)
    }

    private static func passages(_ words: [TranscriptOccurrence], vocabulary: inout Vocabulary) -> [Passage] {
        let groups = Dictionary(grouping: words) { word in
            // Source parts and replayed clips have independent reading order.
            let sourceLane = word.space == .source || (word.space == nil && word.clipID == nil && word.assemblyIndex == nil)
            return PassageKey(attachment: word.attachmentID, clip: word.clipID, assembly: word.assemblyIndex,
                              binding: sourceLane ? word.binding : nil, track: sourceLane ? word.trackID : nil,
                              speaker: word.speakerID)
        }
        var result: [Passage] = []
        for group in groups.values {
            let sorted = group.sorted(by: occurrenceOrder)
            var current: [TranscriptOccurrence] = []
            for word in sorted {
                if let previous = current.last, word.range.from.seconds - previous.range.to.seconds > 5 {
                    result.append(Passage(words: current, vocabulary: &vocabulary))
                    current.removeAll(keepingCapacity: true)
                }
                current.append(word)
            }
            if !current.isEmpty { result.append(Passage(words: current, vocabulary: &vocabulary)) }
        }
        return result
    }

    private static func exactStarts<Term: Equatable>(_ query: [Term], in tokens: [Term]) -> [Int] {
        guard !query.isEmpty, tokens.count >= query.count else { return [] }
        var prefix = Array(repeating: 0, count: query.count)
        var matched = 0
        for index in query.indices.dropFirst() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            while matched > 0, query[matched] != query[index] { matched = prefix[matched - 1] }
            if query[matched] == query[index] { matched += 1 }
            prefix[index] = matched
        }
        matched = 0
        var starts: [Int] = []
        for (index, token) in tokens.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            while matched > 0, query[matched] != token { matched = prefix[matched - 1] }
            if query[matched] == token { matched += 1 }
            if matched == query.count {
                starts.append(index - matched + 1)
                matched = prefix[matched - 1]
            }
        }
        return starts
    }

    private static func chronological(_ left: TranscriptTake, _ right: TranscriptTake) -> Bool {
        occurrenceOrder(left.words[0], right.words[0])
    }

    static func occurrenceOrder(_ left: TranscriptOccurrence, _ right: TranscriptOccurrence) -> Bool {
        if left.range.from != right.range.from { return left.range.from < right.range.from }
        if left.range.to != right.range.to { return left.range.to < right.range.to }
        return left.id < right.id
    }

    private struct Alignment {
        var matched: Int
        var missing: [String]
        var extra: [String]

        var edits: Int { max(missing.count, extra.count) }
    }

    /// A run of transcript tokens read against a script line. The longest common subsequence
    /// leaves every other line term missing and every other token additional, so its length
    /// alone ranks the run.
    private struct Candidate {
        let range: Range<Int>
        let matched: Int
        let lineTerms: Int

        var missing: Int { lineTerms - matched }
        var extra: Int { range.count - matched }
        var edits: Int { max(missing, extra) }
        var score: Int { 2 * matched - missing - extra }
    }

    /// The best reading of a script line among the runs that start at one transcript token.
    struct Reading: Equatable {
        let start: Int
        let length: Int
        let matched: Int
    }

    /// For each transcript token that is a term of the line, the best-ranked run starting there
    /// that reads at least half of the line with at most a third as many additional tokens.
    /// A reading begins and ends on script material, preventing unrelated neighboring words
    /// from becoming qualifiers solely because they happen to touch a complete match.
    ///
    /// A long recording offers a start at nearly every token, and a full table of common
    /// subsequence lengths for each one costs the square of the line length. The lengths for
    /// every prefix of a run fall out of one pass that keeps a single column as bits: bit i is
    /// clear where the first i + 1 line terms share one more token with the run than the first i.
    static func approximateReadings(of line: [Int], in tokens: [Int]) -> [Reading] {
        let count = line.count
        guard count >= 2 else { return [] }
        let maxExtra = max(1, count / 3)
        let minimumMatched = max(2, (count + 1) / 2)
        let maxLength = count + maxExtra
        let width = (count + 63) / 64
        var slotByCode: [Int: Int] = [:]
        var masks: [UInt64] = []
        for (position, code) in line.enumerated() {
            let slot: Int
            if let known = slotByCode[code] {
                slot = known
            } else {
                slot = slotByCode.count
                slotByCode[code] = slot
                masks.append(contentsOf: repeatElement(0, count: width))
            }
            masks[slot * width + position / 64] |= 1 << UInt64(position % 64)
        }
        let slots = tokens.map { slotByCode[$0] ?? -1 }
        // Bits past the end of the line in the last word never count as unmatched terms.
        let unused: UInt64 = count % 64 == 0 ? 0 : ~0 << UInt64(count % 64)
        var column = [UInt64](repeating: 0, count: width)
        var readings: [Reading] = []
        for start in tokens.indices where slots[start] >= 0 {
            guard !Task.isCancelled else { return [] }
            let end = min(tokens.count, start + maxLength)
            guard end - start >= minimumMatched else { continue }
            for word in 0..<width { column[word] = ~0 }
            var matched = 0
            var best: (length: Int, matched: Int, score: Int, edits: Int)?
            for position in start..<end {
                let length = position - start + 1
                let slot = slots[position]
                if slot >= 0 {
                    var carry = false
                    var unmatched = 0
                    for word in 0..<width {
                        let shared = column[word] & masks[slot * width + word]
                        let (sum, overflow) = column[word].addingReportingOverflow(shared)
                        let (total, carried) = sum.addingReportingOverflow(carry ? 1 : 0)
                        carry = overflow || carried
                        column[word] = total | (column[word] & ~shared)
                        unmatched += column[word].nonzeroBitCount
                    }
                    matched = count - (unmatched - (column[width - 1] & unused).nonzeroBitCount)
                }
                // Each further token adds at most one shared term, so the surplus never shrinks.
                if length - matched > maxExtra { break }
                if slot >= 0, matched >= minimumMatched {
                    let score = 4 * matched - count - length
                    let edits = max(count - matched, length - matched)
                    if best.map({ score > $0.score || (score == $0.score && edits < $0.edits) }) ?? true {
                        best = (length, matched, score, edits)
                    }
                }
                if matched + (end - position - 1) < minimumMatched { break }
            }
            if let best { readings.append(.init(start: start, length: best.length, matched: best.matched)) }
        }
        return readings
    }

    private static func align(_ query: [String], codes: [Int], in passage: Passage, context: Int = 8) -> [TranscriptTake] {
        let tokens = passage.tokens
        guard !tokens.isEmpty, !Task.isCancelled else { return [] }
        let exact = exactStarts(codes, in: passage.codes)
        var candidates = exact.map {
            Candidate(range: $0..<$0 + query.count, matched: query.count, lineTerms: query.count)
        }
        let canAlignApproximately = (2...maximumApproximateTerms).contains(query.count)
        if canAlignApproximately {
            let readings = approximateReadings(of: codes, in: passage.codes)
            guard !Task.isCancelled else { return [] }
            candidates += readings.map {
                Candidate(range: $0.start..<$0.start + $0.length, matched: $0.matched, lineTerms: query.count)
            }
        }
        var selected: [Candidate] = []
        var occupied = Array(repeating: false, count: tokens.count)
        for candidate in candidates.sorted(by: { ranks($0, above: $1) }) where !occupied[candidate.range].contains(true) {
            selected.append(candidate)
            for position in candidate.range { occupied[position] = true }
        }
        var takes: [TranscriptTake] = []
        var table: [Int32] = []
        for candidate in selected {
            guard !Task.isCancelled else { return [] }
            var range = candidate.range
            if canAlignApproximately,
               let utterance = passage.utteranceRange(containing: range, maximumExtra: max(2, query.count / 3)),
               utterance != range,
               !occupied[utterance.lowerBound..<range.lowerBound].contains(true),
               !occupied[range.upperBound..<utterance.upperBound].contains(true) {
                range = utterance
            }
            // Only a reading that is kept needs its missing and additional terms listed.
            let alignment = range == candidate.range && candidate.edits == 0
                ? Alignment(matched: query.count, missing: [], extra: [])
                : traceAlignment(query, codes, passage, range, table: &table)
            let kind: TranscriptTakeKind = alignment.edits == 0 ? .exact
                : alignment.matched * 3 < query.count * 2 ? .partial : .approximate
            takes.append(passage.take(range, context: context, kind: kind,
                                      missing: alignment.missing, extra: alignment.extra))
        }
        return takes
    }

    private static func ranks(_ left: Candidate, above right: Candidate) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.edits != right.edits { return left.edits < right.edits }
        return left.range.lowerBound < right.range.lowerBound
    }

    /// The line terms a run of the passage leaves out and the tokens it adds, in reading order.
    /// `table` is scratch space kept between calls.
    private static func traceAlignment(_ query: [String], _ codes: [Int], _ passage: Passage, _ range: Range<Int>,
                                       table: inout [Int32]) -> Alignment {
        let columns = range.count + 1
        let cells = (query.count + 1) * columns
        if table.count < cells { table = Array(repeating: 0, count: cells) }
        let window = passage.codes[range]
        let first = range.lowerBound
        for j in 0..<columns { table[j] = 0 }
        for i in 1...query.count {
            let row = i * columns
            table[row] = 0
            for j in 1..<columns {
                table[row + j] = codes[i - 1] == window[first + j - 1]
                    ? table[row - columns + j - 1] + 1 : max(table[row - columns + j], table[row + j - 1])
            }
        }
        var i = query.count
        var j = range.count
        var missing: [String] = []
        var extra: [String] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0, codes[i - 1] == window[first + j - 1] {
                i -= 1
                j -= 1
            } else if i > 0, j == 0 || table[(i - 1) * columns + j] >= table[i * columns + j - 1] {
                i -= 1
                missing.append(query[i])
            } else {
                j -= 1
                extra.append(passage.tokens[first + j])
            }
        }
        return .init(matched: Int(table[query.count * columns + range.count]), missing: missing.reversed(),
                     extra: extra.reversed())
    }
}
