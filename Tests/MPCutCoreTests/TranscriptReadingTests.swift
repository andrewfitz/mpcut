import Foundation
@testable import MPCutCore
import XCTest

final class TranscriptReadingTests: XCTestCase {
    private struct Generator {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// The readings a full table of common subsequence lengths gives: every length of every
    /// run is traced and ranked by matched terms, then by fewer edits, then by the shorter run.
    private func tabulated(_ line: [Int], _ tokens: [Int]) -> [TranscriptEditorial.Reading] {
        let terms = Set(line)
        let maxExtra = max(1, line.count / 3)
        let minimumMatched = max(2, (line.count + 1) / 2)
        var readings: [TranscriptEditorial.Reading] = []
        for start in tokens.indices where terms.contains(tokens[start]) {
            let end = min(tokens.count, start + line.count + maxExtra)
            guard end - start >= minimumMatched else { continue }
            let window = Array(tokens[start..<end])
            var table = Array(repeating: Array(repeating: 0, count: window.count + 1), count: line.count + 1)
            for i in 1...line.count {
                for j in 1...window.count {
                    table[i][j] = line[i - 1] == window[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
                }
            }
            var best: (length: Int, matched: Int, score: Int, edits: Int)?
            for length in minimumMatched...window.count {
                let matched = table[line.count][length]
                guard matched >= minimumMatched, length - matched <= maxExtra, terms.contains(window[length - 1]) else { continue }
                var (i, j, missing, extra) = (line.count, length, 0, 0)
                while i > 0 || j > 0 {
                    if i > 0, j > 0, line[i - 1] == window[j - 1] {
                        i -= 1
                        j -= 1
                    } else if i > 0, j == 0 || table[i - 1][j] >= table[i][j - 1] {
                        i -= 1
                        missing += 1
                    } else {
                        j -= 1
                        extra += 1
                    }
                }
                let score = 2 * matched - missing - extra
                let edits = max(missing, extra)
                if best.map({ score > $0.score || (score == $0.score && edits < $0.edits) }) ?? true {
                    best = (length, matched, score, edits)
                }
            }
            if let best { readings.append(.init(start: start, length: best.length, matched: best.matched)) }
        }
        return readings
    }

    func testReadingsMatchAFullTableOfCommonSubsequenceLengths() {
        var generator = Generator(state: 41)
        // Lines of 64, 128 and 192 terms fill whole words of the column, and their neighbors carry between words.
        let short = [2, 3, 4, 5, 7, 12, 31]
        let lengths = short + short + short + [63, 64, 65, 100, 127, 128, 129, 191, 192, 193, 255, 256]
        for (round, length) in lengths.enumerated() {
            let alphabet = 2 + generator.next(round.isMultiple(of: 3) ? 4 : 40)
            // A long line is read against a short recording so the full tables stay small.
            let extent = generator.next(3) == 0 ? length / 2 : length < 64 ? 300 + generator.next(300) : length + 45 + generator.next(40)
            var tokens = (0..<extent).map { _ in generator.next(alphabet) }
            // Terms the recording never uses, and tokens the line never uses.
            var line = (0..<length).map { _ in generator.next(4) == 0 ? -1 - generator.next(3) : generator.next(alphabet) }
            if round.isMultiple(of: 2), tokens.count > length + 40 {
                // A reading of the line with a few words dropped, added and changed.
                line = Array(tokens[20..<20 + length])
                for _ in 0..<(length / 8) {
                    let position = generator.next(line.count)
                    line[position] = generator.next(alphabet + 2)
                }
                tokens.insert(alphabet + 5, at: 20 + length / 2)
                tokens.remove(at: 20 + length / 3)
            }
            XCTAssertEqual(TranscriptEditorial.approximateReadings(of: line, in: tokens), tabulated(line, tokens),
                           "line of \(length) terms over \(alphabet) distinct words, round \(round)")
        }
    }

    func testAOneTermLineHasNoApproximateReading() {
        XCTAssertEqual(TranscriptEditorial.approximateReadings(of: [1], in: [1, 1, 2]), [])
    }
}
