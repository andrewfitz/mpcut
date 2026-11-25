import CryptoKit
import Foundation
@testable import MPCutCore
import XCTest

/// Measurements of the transcript core, printed one machine-readable line each.
/// Set MPCUT_TRANSCRIPT_BENCH=1 to run them. Times are CPU milliseconds of the calling
/// thread, so a busy machine changes them less than it changes elapsed time. Every line
/// carries a digest of the encoded result, which stays the same while behaviour does.
final class TranscriptBenchmarkTests: XCTestCase {
    private func requireBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_BENCH"] == "1" else {
            throw XCTSkip("Set MPCUT_TRANSCRIPT_BENCH=1 to measure.")
        }
    }

    private func cpuMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }

    /// MPCUT_TRANSCRIPT_BENCH_REPEAT multiplies every run count, to hold a phase long enough to sample.
    private let repeats = Int(ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_BENCH_REPEAT"] ?? "") ?? 1

    private func median<T>(runs: Int = 7, _ work: () throws -> T) rethrows -> (milliseconds: Double, value: T) {
        var samples: [Double] = []
        var value: T?
        let runs = runs * repeats
        for _ in 0..<runs {
            let start = cpuMilliseconds()
            value = try work()
            samples.append(cpuMilliseconds() - start)
        }
        return (samples.sorted()[runs / 2], value!)
    }

    private func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return digest(try encoder.encode(value))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private struct Generator {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Words drawn so that a few are very common and most are rare, as in speech.
    private func speech(count: Int, vocabulary: Int, seed: UInt64) -> [String] {
        var generator = Generator(state: seed)
        return (0..<count).map { _ in
            let roll = generator.next(1_000)
            let rank = roll < 400 ? generator.next(12) : roll < 750 ? 12 + generator.next(120) : 132 + generator.next(vocabulary - 132)
            return "w\(rank)"
        }
    }

    private func document(_ texts: [String], nativeEvidence: Bool) -> TranscriptDocument {
        let names = ["lav", "wide", "close"]
        func bounds(_ number: Int) -> (RationalTime, RationalTime) {
            (RationalTime(numerator: Int64(number), denominator: 4), RationalTime(numerator: Int64(number) + 1, denominator: 4))
        }
        let tracks = names.map { name -> TranscriptTrack in
            guard nativeEvidence else { return TranscriptTrack(id: name, name: name) }
            let local = texts.enumerated().map { number, text -> TranscriptWord in
                let (start, end) = bounds(number)
                return .init(id: "t\(number)", text: text, start: start, end: end, confidence: 0.9)
            }
            let activity = (0..<texts.count).map { number -> TranscriptActivityFrame in
                let (start, end) = bounds(number)
                return .init(start: start, end: end, level: Double(number % 97) / 97)
            }
            return TranscriptTrack(id: name, name: name, activity: activity, words: local)
        }
        let words = texts.enumerated().map { number, text -> TranscriptWord in
            let (start, end) = bounds(number)
            return .init(id: "w\(number)", text: text, start: start, end: end, utteranceID: "u\(number / 12)",
                         observations: names.map {
                             .init(trackID: $0, wordID: nativeEvidence ? "t\(number)" : nil, start: start, end: end,
                                   evidence: .recognized)
                         })
        }
        return TranscriptDocument(clock: .presentation, tracks: tracks, words: words)
    }

    /// What one stored result costs to open, check, index, page and search.
    func testStoredResultBenchmark() throws {
        try requireBenchmark()
        let texts = speech(count: 28_800, vocabulary: 2_400, seed: 7)
        for (label, native) in [("plain", false), ("native", true)] {
            let document = document(texts, nativeEvidence: native)
            let bytes = try TranscriptCodec.encode(document, format: .json)
            let encode = try median(runs: 5) { try TranscriptCodec.encode(document, format: .json) }
            let decode = try median(runs: 5) { try TranscriptCodec.decode(bytes, format: .json) }
            // The writer leaves a track's level frames behind.
            XCTAssertEqual(decode.value, document)
            // The same bytes through the general decoder, which reads whatever the direct reader declines.
            let general = try median(runs: 5) { () -> TranscriptDocument in
                let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: bytes)
                try decoded.validate()
                return decoded
            }
            XCTAssertEqual(general.value, document)
            let validate = try median { try document.validate() }
            let index = try median(runs: 5) { try TranscriptIndex(document: document) }
            let source = try median(runs: 5) { try TranscriptIndex(document: document, spaces: [.source]) }
            let page = try median { try self.digest(index.value.read(space: .source, offset: 40_000, limit: 100)) }
            let phrase = texts[20_000...20_002].joined(separator: " ")
            let search = try median { try self.digest(index.value.search(phrase, space: .source, limit: 50)) }
            let export = try median(runs: 5) { try TranscriptCodec.encode(index.value, space: .source, format: .srt) }
            print(String(format: "TRANSCRIPT_BENCH stored=%@ words=%d bytes=%d encodeMs=%.1f decodeMs=%.1f generalDecodeMs=%.1f validateMs=%.2f "
                         + "indexMs=%.1f sourceIndexMs=%.1f pageMs=%.2f searchMs=%.3f exportSrtMs=%.1f "
                         + "digests=%@,%@,%@,%@", label, texts.count, bytes.count, encode.milliseconds,
                         decode.milliseconds, general.milliseconds, validate.milliseconds, index.milliseconds, source.milliseconds,
                         page.milliseconds, search.milliseconds, export.milliseconds,
                         digest(encode.value), page.value, search.value, digest(export.value)))
        }
    }

    /// Finding where each line of a script was said in a long recording.
    func testScriptAlignmentBenchmark() throws {
        try requireBenchmark()
        let texts = speech(count: 28_800, vocabulary: 2_400, seed: 11)
        let words = try TranscriptIndex(document: document(texts, nativeEvidence: false), spaces: [.source])
            .readAll(space: .source, filter: .init(trackID: "lav"))
        var generator = Generator(state: 3)
        func beat(length: Int, at start: Int, edits: Int) -> String {
            var line = Array(texts[start..<start + length])
            for _ in 0..<edits {
                let position = generator.next(line.count)
                switch generator.next(3) {
                case 0: line.remove(at: position)
                case 1: line.insert("w\(generator.next(2_400))", at: position)
                default: line[position] = "w\(generator.next(2_400))"
                }
            }
            return line.joined(separator: " ")
        }
        let long = [beat(length: 100, at: 4_000, edits: 0), beat(length: 100, at: 9_000, edits: 9),
                    beat(length: 100, at: 15_000, edits: 30), speech(count: 100, vocabulary: 2_400, seed: 99).joined(separator: " ")]
        let short = (0..<24).map { beat(length: 14, at: 500 + $0 * 1_100, edits: $0 % 4) }
        let longBeats = median(runs: 3) { TranscriptEditorial.alignScript(long.joined(separator: "\n"), words: words) }
        let shortBeats = median(runs: 3) { TranscriptEditorial.alignScript(short.joined(separator: "\n"), words: words) }
        let compare = median(runs: 3) { TranscriptEditorial.compare(short[5], words: words) }
        let suggest = median(runs: 3) { TranscriptEditorial.suggest(words: words, fillerTerms: ["w3", "w5 w7"]) }
        print(String(format: "TRANSCRIPT_BENCH editorial words=%d longBeats=%d longMs=%.1f shortBeats=%d shortMs=%.1f "
                     + "compareMs=%.1f suggestMs=%.1f statuses=%@ digests=%@,%@,%@,%@", words.count, long.count,
                     longBeats.milliseconds, short.count, shortBeats.milliseconds, compare.milliseconds,
                     suggest.milliseconds, longBeats.value.map(\.status.rawValue).joined(separator: "+"),
                     try digest(longBeats.value), try digest(shortBeats.value),
                     try digest(compare.value), try digest(suggest.value)))
    }

    /// Small scripts over small vocabularies, where near-ties between readings are common.
    /// The digest covers every beat, candidate, qualifier and context word.
    func testScriptAlignmentDigests() throws {
        try requireBenchmark()
        var generator = Generator(state: 2_024)
        var encoded = Data()
        for round in 0..<60 {
            let vocabulary = 3 + generator.next(12)
            let texts = (0..<(40 + generator.next(400))).map { _ in "w\(generator.next(vocabulary))" }
            let words = try TranscriptIndex(document: document(texts, nativeEvidence: false), spaces: [.source])
                .readAll(space: .source, filter: .init(trackID: round.isMultiple(of: 2) ? "lav" : nil))
            let script = (0..<6).map { _ in
                (0..<(1 + generator.next(24))).map { _ in "w\(generator.next(vocabulary + 2))" }.joined(separator: " ")
            }.joined(separator: "\n")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded.append(try encoder.encode(TranscriptEditorial.alignScript(script, words: words, contextWords: 2)))
            encoded.append(try encoder.encode(TranscriptEditorial.compare(script.split(separator: "\n")[0].description,
                                                                          words: words, contextWords: 1)))
        }
        print("TRANSCRIPT_BENCH alignmentDigest=\(digest(encoded)) bytes=\(encoded.count)")
    }

    /// The phases of one command-line read of a saved project. MPCUT_TRANSCRIPT_BENCH_PROJECT
    /// names a project whose media and transcript store are on disk.
    func testSavedProjectPhasesBenchmark() throws {
        try requireBenchmark()
        guard let path = ProcessInfo.processInfo.environment["MPCUT_TRANSCRIPT_BENCH_PROJECT"] else {
            throw XCTSkip("Set MPCUT_TRANSCRIPT_BENCH_PROJECT to a saved project.")
        }
        let url = URL(fileURLWithPath: path)
        let load = try median(runs: 3) { try CutProject.load(from: url) }
        let project = load.value
        guard let attachment = project.transcripts.attachments.first else { throw XCTSkip("No attachment.") }
        let inspect = try median(runs: 3) { () -> [String: MediaInfo] in
            guard case .multicam(let multicam) = project else { return [:] }
            var media: [String: MediaInfo] = [:]
            for source in multicam.sources {
                media[source.id] = try CutEngine().inspectMulticamSource(CutProject.checkedMediaURL(source.file, relativeTo: url))
            }
            return media
        }
        let read = try median(runs: 5) { try TranscriptStore.read(attachment.asset, relativeTo: url) }
        let decode = try median(runs: 5) { try TranscriptCodec.decode(read.value, format: .json) }
        let general = try median(runs: 5) { () -> TranscriptDocument in
            let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: read.value)
            try decoded.validate()
            return decoded
        }
        XCTAssertEqual(general.value, decode.value)
        let validate = try median { try decode.value.validate() }
        var line = String(format: "TRANSCRIPT_BENCH project words=%d loadMs=%.1f inspectMs=%.1f readHashMs=%.1f decodeMs=%.1f generalDecodeMs=%.1f validateMs=%.2f",
                          decode.value.words.count, load.milliseconds, inspect.milliseconds, read.milliseconds,
                          decode.milliseconds, general.milliseconds, validate.milliseconds)
        var digests: [String] = []
        for spaces in [[TranscriptSpace.currentCut], [.source], [.group], TranscriptSpace.allCases] {
            let index = try median(runs: 5) {
                try TranscriptIndex(document: decode.value, attachment: attachment, project: project, projectURL: url,
                                    multicamMedia: inspect.value, timelineRevision: 1,
                                    records: project.transcripts.authoring, spaces: Set(spaces))
            }
            line += String(format: " index[%@]Ms=%.1f", spaces.map(\.rawValue).joined(separator: "+"), index.milliseconds)
            for space in spaces {
                let total = index.value.read(space: space).total
                digests.append(try digest(index.value.read(space: space, offset: total / 2, limit: 200)))
            }
        }
        let all = try TranscriptIndex(document: decode.value, attachment: attachment, project: project, projectURL: url,
                                      multicamMedia: inspect.value, timelineRevision: 1, spaces: Set(TranscriptSpace.allCases))
        let coverage = try median { try self.digest(all.inputCoverage(space: .source, limit: 500)) }
        let cut = all.read(space: .currentCut, offset: all.read(space: .currentCut).total / 2, limit: 2).items
        // Copied media carries a new identity, which leaves the edit without bound words.
        guard cut.count == 2 else { throw XCTSkip("The project's current cut has no transcript words to select.") }
        let selection = TranscriptWordSelection(firstWordID: cut[0].wordID, lastWordID: cut[1].wordID,
                                                firstOccurrenceID: cut[0].id, lastOccurrenceID: cut[1].id)
        let record = try median(runs: 5) {
            try TranscriptEditorial.makeRecord(change: .replaceText(text: "delivery register"), selections: [selection],
                                               in: all, id: "benchmark")
        }
        let corrected = try median(runs: 5) {
            try TranscriptIndex(document: decode.value, attachment: attachment, project: project, projectURL: url,
                                multicamMedia: inspect.value, timelineRevision: 1, records: [record.value],
                                spaces: [.currentCut])
        }
        let subtitles = try median(runs: 5) { try TranscriptCodec.encode(all, space: .currentCut, format: .srt) }
        let json = try median(runs: 3) { try TranscriptCodec.encode(all, space: .currentCut, format: .json) }
        line += String(format: " inputCoverageMs=%.1f makeRecordMs=%.1f correctedIndex[currentCut]Ms=%.1f exportSrtMs=%.1f exportJsonMs=%.1f",
                       coverage.milliseconds, record.milliseconds, corrected.milliseconds, subtitles.milliseconds,
                       json.milliseconds)
        digests += [coverage.value, try digest(record.value.anchors), try digest(corrected.value.read(space: .currentCut, limit: 500)),
                    digest(subtitles.value), digest(json.value)]
        print(line + " digests=" + digests.joined(separator: ","))
    }
}
