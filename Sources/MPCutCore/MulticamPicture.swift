import Foundation

extension MulticamEngine {
    func isolatedPicture(_ original: MediaInfo, using engine: CutEngine) throws -> MediaInfo {
        let selected = try engine.selectedMedia(original)
        guard let issue = selected.copyIssue,
              ["Audio track ", "An audio track ", "An audio packet ", "AAC track ",
               "Unsupported AAC media edit list", "Cannot read MOV AAC track metadata"].contains(where: issue.hasPrefix) else {
            return selected
        }
        return MediaInfo(url: selected.url, format: selected.format, duration: selected.duration,
                         origin: selected.origin, streams: selected.streams, frames: selected.frames,
                         audio: [], copyIssue: nil, sourceStartSafe: selected.sourceStartSafe,
                         identity: selected.identity, videoIndex: 0, timelineIssue: selected.timelineIssue)
    }


    func checkPictureCoverage(_ media: MediaInfo, span: MulticamSpan, mapping: MulticamPlan,
                              container: String) throws {
        let frames = media.frames
        let from = span.input.from
        let to = span.input.to
        func uncovered(from lower: RationalTime, to upper: RationalTime) throws -> CutError {
            let group = try groupRange(span, in: mapping)
            let start = try lower.subtracting(from)
            let end = try upper.subtracting(from)
            let groupFrom = try group.from.adding(start)
            let groupTo = try group.from.adding(end)
            let outputFrom = try span.output.from.adding(start)
            let outputTo = try span.output.from.adding(end)
            return CutError(code: "uncovered_picture",
                            message: "The selected picture does not cover group \(groupFrom)–\(groupTo), output \(outputFrom)–\(outputTo).")
        }
        guard let first = frames.first else { throw try uncovered(from: from, to: to) }
        guard first.time <= from else { throw try uncovered(from: from, to: min(to, first.time)) }
        guard to <= media.duration else { throw try uncovered(from: max(from, media.duration), to: to) }
        let firstIndex = max(0, frames.lowerBound { $0.time > from } - 1)
        let endIndex = frames.lowerBound { $0.time >= to }
        let shift = try span.output.from.subtracting(from)
        let matroska = container == "mkv" || container == "webm"
        let engine = CutEngine(cancelled: cancelled)
        var coveredThrough = from
        for index in firstIndex..<endIndex {
            if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
            let frame = frames[index]
            guard frame.time <= coveredThrough else { throw try uncovered(from: coveredThrough, to: frame.time) }
            coveredThrough = max(coveredThrough, try frame.time.adding(frame.duration))
            if matroska, frame.time >= from {
                let presentation = try frame.time.adding(shift)
                if 1_000 % presentation.denominator != 0 || 1_000 % frame.duration.denominator != 0 {
                    throw CutError(code: "unsupported_container",
                                   message: "The Matroska clock cannot represent picture timing exactly at output \(presentation).")
                }
            }
        }
        guard coveredThrough >= to else { throw try uncovered(from: coveredThrough, to: to) }
    }
}
