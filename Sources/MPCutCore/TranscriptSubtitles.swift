import Foundation

/// How captions break into cues and lines. The standard limits are the ones the CLI and agents
/// always use; the desktop app passes the editor's Settings values.
public struct TranscriptCaptionLimits: Equatable, Sendable {
    public var lineCharacters: Int
    public var lines: Int
    public var longestCue: RationalTime
    public var speakerLabels: Bool

    public init(lineCharacters: Int = 42, lines: Int = 2, longestCue: RationalTime = .init(numerator: 6),
                speakerLabels: Bool = true) {
        self.lineCharacters = max(1, lineCharacters)
        self.lines = max(1, lines)
        self.longestCue = longestCue
        self.speakerLabels = speakerLabels
    }

    public static let standard = TranscriptCaptionLimits()
}

enum TranscriptSubtitles {
    // Editors and converters also write one-digit hours and a period before the milliseconds.
    private static let srtClock = #"^[0-9]+:[0-5][0-9]:[0-5][0-9][,.][0-9]{3}$"#
    // SubRip styling and positioning are presentation, not dialogue.
    private static let srtMarkup = #"</?(?:b|i|u|s|font)(?:\s[^>]*)?>|\{\\[^}]*\}"#
    private static let vttClock = #"^(?:[0-9]{2,}:)?[0-5][0-9]:[0-5][0-9]\.[0-9]{3}$"#
    private static let voiceStart = try! NSRegularExpression(pattern: #"<v(?:\.[^\s>.]+)*\s+([^>]+)>"#)
    private static let cueMarkup = #"</?(?:b|i|u|c|lang|ruby|rt)(?:[.\s][^>]*)?>|</v>|<[0-9:.]+>"#

    static func decode(_ input: String, format: TranscriptFormat, origin: RationalTime?) throws -> TranscriptDocument {
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.first?.first == "\u{FEFF}" { lines[0].removeFirst() }
        let groups = lines.split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let isVTT = format == .vtt
        let blocks: ArraySlice<ArraySlice<String>>
        if isVTT {
            guard let header = groups.first?.first, header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t"),
                  groups.first?.contains(where: { $0.contains("-->") }) == false else {
                throw TranscriptDocument.invalid("Missing or malformed WEBVTT header")
            }
            blocks = groups.dropFirst()
        } else {
            blocks = groups[...]
        }

        var words: [TranscriptWord] = []
        var speakers: [TranscriptSpeaker] = []
        var speakerIDs: [String: String] = [:]
        let localOrigin = origin ?? .zero
        for (index, block) in blocks.enumerated() {
            guard let first = block.first else { continue }
            if isVTT {
                if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") { continue }
                let keyword = first.trimmingCharacters(in: .whitespaces)
                if keyword == "STYLE" || keyword == "REGION" {
                    // These keywords can also be cue identifiers immediately before a timing line.
                    if block.dropFirst().first?.contains("-->") != true { continue }
                }
            }
            let timingIndex = first.contains("-->") ? block.startIndex : block.index(after: block.startIndex)
            guard timingIndex < block.endIndex else {
                throw TranscriptDocument.invalid("Missing timing for subtitle cue \(index + 1)")
            }
            let (start, end) = try bounds(block[timingIndex], isVTT: isVTT)
            let payload = block.suffix(from: block.index(after: timingIndex)).joined(separator: "\n")
            let fragments = speakerFragments(payload, isVTT: isVTT).filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // A cue without text carries no dialogue. One of them is not a reason to refuse the file.
            guard !fragments.isEmpty else { continue }
            for (fragmentIndex, fragment) in fragments.enumerated() {
                let speakerID = fragment.name.map { name in
                    if let existing = speakerIDs[name] { return existing }
                    let id = "speaker-\(speakers.count)"
                    speakers.append(TranscriptSpeaker(id: id, name: name))
                    speakerIDs[name] = id
                    return id
                }
                words.append(TranscriptWord(id: "cue-\(index)-\(fragmentIndex)", text: fragment.text,
                                            start: try localOrigin.adding(start), end: try localOrigin.adding(end),
                                            utteranceID: "cue-\(index)", speakerID: speakerID, precision: .cue))
            }
        }
        let track = TranscriptTrack(id: "source", name: "Subtitle cues", origin: localOrigin, approximateClock: origin == nil)
        return TranscriptDocument(clock: .presentation, tracks: [track], speakers: speakers, words: words,
                                  approximateClock: origin == nil)
    }

    private static func bounds(_ timing: String, isVTT: Bool) throws -> (RationalTime, RationalTime) {
        let components = timing.components(separatedBy: "-->")
        let expression = isVTT ? vttClock : srtClock
        guard components.count == 2,
              let endToken = components[1].split(whereSeparator: \.isWhitespace).first else {
            throw TranscriptDocument.invalid("Invalid subtitle timing \(timing)")
        }
        let startToken = components[0].trimmingCharacters(in: .whitespaces)
        guard startToken.range(of: expression, options: .regularExpression) != nil,
              endToken.range(of: expression, options: .regularExpression) != nil else {
            throw TranscriptDocument.invalid("Invalid subtitle timestamp \(timing)")
        }
        let start = try RationalTime(parsing: startToken.replacingOccurrences(of: ",", with: "."))
        let end = try RationalTime(parsing: endToken.replacingOccurrences(of: ",", with: "."))
        guard start <= end else {
            throw TranscriptDocument.invalid("Subtitle end must come after its start")
        }
        // An instantaneous cue is kept at the shortest duration the encoder writes.
        return (start, start == end ? try start.adding(RationalTime(numerator: 1, denominator: 1000)) : end)
    }

    private static func speakerFragments(_ payload: String, isVTT: Bool) -> [(name: String?, text: String)] {
        func visible(_ text: String) -> String {
            guard isVTT else {
                return text.replacingOccurrences(of: srtMarkup, with: "", options: [.regularExpression, .caseInsensitive])
            }
            return unescape(text.replacingOccurrences(of: cueMarkup, with: "", options: .regularExpression))
        }
        let value = payload as NSString
        let voices = isVTT ? voiceStart.matches(in: payload, range: NSRange(location: 0, length: value.length)) : []
        if !voices.isEmpty {
            var result: [(name: String?, text: String)] = []
            let preceding = visible(value.substring(to: voices[0].range.location))
            if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((nil, preceding))
            }
            for (index, match) in voices.enumerated() {
                let start = NSMaxRange(match.range)
                let end = index + 1 < voices.count ? voices[index + 1].range.location : value.length
                let fragment = value.substring(with: NSRange(location: start, length: end - start))
                let name = unescape(value.substring(with: match.range(at: 1))).trimmingCharacters(in: .whitespaces)
                let parts = fragment.components(separatedBy: "</v>")
                let spoken = visible(parts[0])
                if !spoken.isEmpty { result.append((name.isEmpty ? nil : name, spoken)) }
                let following = visible(parts.dropFirst().joined())
                if !following.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append((nil, following))
                }
            }
            return result
        }

        var result: [(name: String?, text: String)] = []
        for line in visible(payload).components(separatedBy: "\n") {
            if line.first == "[", let close = line.firstIndex(of: "]") {
                let label = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                let body = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty && !body.isEmpty {
                    result.append((label, body))
                    continue
                }
            }
            if result.isEmpty {
                if !line.isEmpty { result.append((nil, line)) }
            } else {
                result[result.count - 1].text += "\n" + line
            }
        }
        return result
    }

    private struct CueLane: Hashable {
        var attachment = 0
        let speaker: String?
        let track: String?
        let clip: String?
        let assembly: Int?
    }

    private struct Cue {
        var text: String
        var start: RationalTime
        var end: RationalTime
        let precision: TranscriptPrecision
        let utteranceID: String?
        let speakerName: String?
        let lane: CueLane
    }

    private enum Recording: Equatable {
        case file(String), source(String), unbound(Int, String?)
    }

    static func captionExport(_ indexes: [TranscriptIndex], space: TranscriptSpace, filter: TranscriptFilter,
                              limits: TranscriptCaptionLimits = .standard) throws -> (data: Data, wordCount: Int) {
        var words: [Cue] = []
        var recording: Recording?
        var count = 0
        for (position, index) in indexes.enumerated() {
            let rows = index.readAll(space: space, filter: filter)
            let speakers = Dictionary(uniqueKeysWithValues: index.speakers.map { ($0.id, $0.name) })
            // Exported documents can carry a different clock on each word.
            var originalClocks: [String: TranscriptClock]?
            count += rows.count
            for row in rows where !row.text.allSatisfy(\.isWhitespace) {
                var range = row.range
                if space == .source {
                    if row.sourceRange == nil {
                        if originalClocks == nil {
                            originalClocks = Dictionary(uniqueKeysWithValues: index.document.words.compactMap { word in
                                word.projection.map { (word.id, $0.clock) }
                            })
                        }
                        guard (originalClocks?[row.wordID] ?? index.document.clock) == .presentation,
                              row.candidateTrackIDs.count <= 1 else {
                            throw TranscriptDocument.invalid("Source timing is unavailable for this dialogue. Choose its timeline clock or select a bound recording track.")
                        }
                    }
                    let source = row.file.map(Recording.file) ?? row.sourceID.map(Recording.source) ?? .unbound(position, row.trackID)
                    guard recording == nil || recording == source else {
                        throw TranscriptDocument.invalid("Select one recording for source captions using an attachment, file, or track filter.")
                    }
                    recording = source
                    if let relative = row.sequenceSourceRange { range = relative }
                    else if let id = row.sourceID, let offset = index.multicamClockOffsets[id], let source = row.sourceRange {
                        range = try MulticamRange(from: source.from.subtracting(offset), to: source.to.subtracting(offset))
                    }
                }
                let lane = CueLane(attachment: position, speaker: row.speakerID, track: row.trackID,
                                   clip: row.clipID, assembly: row.assemblyIndex)
                let speakerName = limits.speakerLabels ? row.speakerID.flatMap { speakers[$0] } : nil
                words.append(Cue(text: row.text, start: range.from, end: range.to, precision: row.precision,
                                 utteranceID: row.utteranceID, speakerName: speakerName, lane: lane))
            }
        }
        // Index rows are ordered on the selected clock. Separate attachments need a merge.
        if indexes.count > 1 { words.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start } }
        let cues = groupWords(words, captions: limits)
        let text = try encodeTimed(cues, format: .srt, singleTrack: true, clock: "", limits: limits)
        guard !text.isEmpty else { throw TranscriptDocument.invalid("No captions are available on the selected clock.") }
        return (Data(text.utf8), count)
    }

    static func encode(_ document: TranscriptDocument, format: TranscriptFormat) throws -> String {
        let speakers = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0.name) })
        let words = document.words.compactMap { word -> Cue? in
            guard !word.text.allSatisfy(\.isWhitespace) else { return nil }
            let lane = CueLane(speaker: word.speakerID, track: word.projection?.trackID,
                               clip: word.projection?.clipID, assembly: word.projection?.assemblyIndex)
            return Cue(text: word.text, start: word.start, end: word.end, precision: word.precision,
                       utteranceID: word.utteranceID, speakerName: word.speakerID.flatMap { speakers[$0] }, lane: lane)
        }
        let cues = groupWords(words, captions: nil)
        if format == .text {
            let lines = cues.map { renderText($0.text, speaker: $0.speakerName, isVTT: false) }
            return (["Transcript (\(clockLabel(document)))"] + lines).joined(separator: "\n") + "\n"
        }
        return try encodeTimed(cues, format: format, singleTrack: false, clock: clockLabel(document))
    }

    private static func encodeTimed(_ cues: [Cue], format: TranscriptFormat, singleTrack: Bool, clock: String,
                                    limits: TranscriptCaptionLimits = .standard) throws -> String {
        let isVTT = format == .vtt
        var output = isVTT ? "WEBVTT\n\nNOTE Clock: \(clock)\n\n" : ""
        var index = 0
        func appendCue(from start: Int64, to end: Int64, text: String) {
            index += 1
            if !isVTT { output += "\(index)\n" }
            output += "\(timestamp(start, isVTT: isVTT)) --> \(timestamp(end, isVTT: isVTT))\n\(text)\n\n"
        }

        // An editor can show just one caption at a time on a subtitle track. Emit
        // the lines visible between each pair of speaker entrances and exits.
        var active: [(end: Int64, text: String)] = []
        var cursor: Int64 = 0
        func flush(until limit: Int64) {
            while cursor < limit, let firstEnd = active.lazy.map(\.end).min() {
                let boundary = min(firstEnd, limit)
                let text = active.count == 1 ? active[0].text : active.lazy.map(\.text).joined(separator: "\n")
                appendCue(from: cursor, to: boundary, text: text)
                cursor = boundary
                active.removeAll { $0.end == boundary }
            }
            cursor = limit
        }

        for cue in cues.sorted(by: { $0.start < $1.start }) {
            guard cue.end > .zero || cue.start == .zero else { continue }
            let start = try max(cue.start, .zero).roundedToSamples(1000)
            let end = try max(cue.end, .zero).roundedToSamples(1000)
            let cueEnd = end > start ? end : start.addingReportingOverflow(1).partialValue
            guard cueEnd > start else {
                throw TranscriptDocument.invalid("Subtitle timestamp exceeds the supported millisecond range")
            }
            let payload = renderText(cue.text, speaker: cue.speakerName, isVTT: isVTT)
            let text = singleTrack && cue.precision == .word
                ? captionLines(payload, width: limits.lineCharacters).joined(separator: "\n") : payload
            if singleTrack {
                flush(until: start)
                active.append((cueEnd, text))
            } else {
                appendCue(from: start, to: cueEnd, text: text)
            }
        }
        if singleTrack { flush(until: .max) }
        return output
    }

    private static func clockLabel(_ document: TranscriptDocument) -> String {
        let label: String
        switch document.clock {
        case .presentation: label = "Source presentation"
        case .session: label = "Session"
        case .group: label = "Group"
        case .currentCut: label = "Current Cut"
        }
        return label + (document.approximateClock ? " (approximate)" : "")
    }

    /// Joins the words of an utterance into one cue. People talk over each other, and in time
    /// order their words alternate; each speaker's cue carries on across the other's words
    /// instead of ending at every one. The cues stay in the order they begin, so overlapping
    /// speech reads as whole lines and as cues that overlap.
    /// `captions` holds the caption limits, or nil for a transcript export.
    private static func groupWords(_ words: [Cue], captions: TranscriptCaptionLimits?) -> [Cue] {
        var result: [Cue] = []
        // The cue each lane is still adding to, and the last word of every cue.
        var open: [CueLane: Int] = [:]
        var tails: [Int] = []
        var latest: Int?
        let pauseLimit = RationalTime(numerator: 1)
        for (position, word) in words.enumerated() {
            let lane = word.lane
            let cue: Int?
            if let latest, result[latest].lane == lane { cue = latest } else { cue = open[lane] }
            if let cue, word.precision == .word, result[cue].precision == .word,
               word.start >= result[cue].start,
               (try? word.start.subtracting(result[cue].end)).map({ $0 <= pauseLimit }) == true,
               (word.utteranceID != nil && words[tails[cue]].utteranceID != nil || captions != nil),
               word.utteranceID == words[tails[cue]].utteranceID || wasTalkedOver(result[cue], before: position, after: tails[cue], in: words),
               captions.map({ fitsCaption(result[cue], adding: word, limits: $0) }) ?? true {
                result[cue].text += word.text
                result[cue].end = max(result[cue].end, word.end)
                tails[cue] = position
                latest = cue
            } else {
                open[lane] = result.count
                latest = result.count
                tails.append(position)
                result.append(word)
            }
        }
        return result
    }

    private static func fitsCaption(_ cue: Cue, adding word: Cue, limits: TranscriptCaptionLimits) -> Bool {
        guard let duration = try? max(cue.end, word.end).subtracting(cue.start),
              duration <= limits.longestCue else { return false }
        let body = (cue.text + word.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = cue.speakerName.map { "[\($0)] " + body } ?? body
        let length = text.count
        // Every line full, with a space between each pair.
        let longest = limits.lineCharacters * limits.lines + limits.lines - 1
        return length <= limits.lineCharacters
            || length <= longest && captionLines(text, width: limits.lineCharacters).count <= limits.lines
    }

    private static func captionLines(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for token in text.split(whereSeparator: \.isWhitespace) {
            var word = token
            if !line.isEmpty && line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            while let split = word.index(word.startIndex, offsetBy: width, limitedBy: word.endIndex), split < word.endIndex {
                lines.append(String(word[..<split]))
                word = word[split...]
            }
            if !line.isEmpty { line += " " }
            line += word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Whether another lane spoke across the join between a cue and its lane's next word.
    /// A recognizer that numbers utterances in conversation order starts a new one each time
    /// the speaker changes, so a sentence someone talked over arrives as fragments. A cue that
    /// already ended its sentence is left as it is.
    private static func wasTalkedOver(_ cue: Cue, before next: Int, after tail: Int,
                                      in words: [Cue]) -> Bool {
        guard tail + 1 < next else { return false }
        let ending = cue.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"’”)]")))
        guard ending.last.map({ ".?!…".contains($0) }) != true else { return false }
        return words[(tail + 1)..<next].contains { $0.start < cue.end || $0.end > words[next].start }
    }

    private static func timestamp(_ milliseconds: Int64, isVTT: Bool) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1000) % 60
        let fraction = milliseconds % 1000
        return String(format: "%02lld:%02lld:%02lld%@%03lld", hours, minutes, seconds, isVTT ? "." : ",", fraction)
    }

    private static func renderText(_ text: String, speaker: String?, isVTT: Bool) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
        let name = speaker?.components(separatedBy: .newlines).joined(separator: " ")
        if isVTT {
            return name.map { "<v \(escape($0))>\(escape(body))</v>" } ?? escape(body)
        }
        return name.map { "[\($0)] \(body)" } ?? body
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{A0}")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
