import Foundation

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

    static func encode(_ document: TranscriptDocument, format: TranscriptFormat) throws -> String {
        let speakers = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0.name) })
        let cues = groupWords(document.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if format == .text {
            let lines = cues.map { cue in
                renderText(cue.text, speaker: cue.speakerID.flatMap { speakers[$0] }, isVTT: false)
            }
            return (["Transcript (\(clockLabel(document)))"] + lines).joined(separator: "\n") + "\n"
        }
        let isVTT = format == .vtt
        var output = isVTT ? "WEBVTT\n\nNOTE Clock: \(clockLabel(document))\n\n" : ""
        var index = 0
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            guard cue.end > .zero || cue.start == .zero else { continue }
            let start = try max(cue.start, .zero).roundedToSamples(1000)
            let end = try max(cue.end, .zero).roundedToSamples(1000)
            let cueEnd = end > start ? end : start.addingReportingOverflow(1).partialValue
            guard cueEnd > start else {
                throw TranscriptDocument.invalid("Subtitle timestamp exceeds the supported millisecond range")
            }
            index += 1
            if !isVTT { output += "\(index)\n" }
            let text = renderText(cue.text, speaker: cue.speakerID.flatMap { speakers[$0] }, isVTT: isVTT)
            output += "\(timestamp(start, isVTT: isVTT)) --> \(timestamp(cueEnd, isVTT: isVTT))\n\(text)\n\n"
        }
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

    /// The words one speaker says on one track of one edit interval.
    private struct CueLane: Hashable {
        let speaker: String?
        let track: String?
        let clip: String?
        let assembly: Int?

        init(_ word: TranscriptWord) {
            speaker = word.speakerID
            track = word.projection?.trackID
            clip = word.projection?.clipID
            assembly = word.projection?.assemblyIndex
        }
    }

    /// Joins the words of an utterance into one cue. People talk over each other, and in time
    /// order their words alternate; each speaker's cue carries on across the other's words
    /// instead of ending at every one. The cues stay in the order they begin, so overlapping
    /// speech reads as whole lines and as cues that overlap.
    private static func groupWords(_ words: [TranscriptWord]) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        // The cue each lane is still adding to, and the last word of every cue.
        var open: [CueLane: Int] = [:]
        var tails: [Int] = []
        var latest: Int?
        let pauseLimit = RationalTime(numerator: 1)
        for (position, word) in words.enumerated() {
            let lane = CueLane(word)
            let cue: Int?
            if let latest, CueLane(result[latest]) == lane { cue = latest } else { cue = open[lane] }
            if let cue, word.precision == .word, result[cue].precision == .word,
               let utteranceID = word.utteranceID, let spoken = words[tails[cue]].utteranceID,
               word.start >= result[cue].start,
               (try? word.start.subtracting(result[cue].end)).map({ $0 <= pauseLimit }) == true,
               utteranceID == spoken || wasTalkedOver(result[cue], before: position, after: tails[cue], in: words) {
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

    /// Whether another lane spoke across the join between a cue and its lane's next word.
    /// A recognizer that numbers utterances in conversation order starts a new one each time
    /// the speaker changes, so a sentence someone talked over arrives as fragments. A cue that
    /// already ended its sentence is left as it is.
    private static func wasTalkedOver(_ cue: TranscriptWord, before next: Int, after tail: Int,
                                      in words: [TranscriptWord]) -> Bool {
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
