import Foundation

/// The timeline occurrences behind the writer's possibly coalesced segments.
public struct ExportCutMap: Encodable, Sendable {
    public struct Occurrence: Encodable, Sendable {
        public let occurrenceNumber: Int
        public let occurrenceID: String?
        public let inputNumber: Int?
        public let file: String?
        public let inputClock: String
        public let requestedFrom: RationalTime?
        public let requestedTo: RationalTime?
        public let input: MulticamRange?
        public let output: MulticamRange?
        public let segmentNumber: Int?
        public let placementID: String?
    }

    public let version = 1
    public let occurrences: [Occurrence]

    package init(wholeSource clip: ClipRequest, duration: RationalTime, id: String?, inputNumber: Int) {
        let range = MulticamRange(from: .zero, to: duration)
        occurrences = [.init(occurrenceNumber: 1, occurrenceID: id, inputNumber: inputNumber,
                             file: clip.file.path, inputClock: "source", requestedFrom: clip.from,
                             requestedTo: clip.to, input: range, output: range, segmentNumber: nil,
                             placementID: nil)]
    }

    public init(edit: ResolvedEdit, clips: [ClipRequest], ids: [String?] = [], inputNumbers: [Int] = []) throws {
        var occurrences: [Occurrence] = []
        for (index, segment) in edit.segments.enumerated() {
            let first = segment.sourceClipIndex ?? index
            guard clips.indices.contains(first), segment.sourceClipSeams.count < clips.count - first else {
                throw CutError(code: "invalid_export_map", message: "An export segment has no matching input clip.")
            }
            let last = first + segment.sourceClipSeams.count
            for ordinal in first...last {
                let clip = clips[ordinal]
                let from = ordinal == first ? segment.from : max(segment.sourceClipSeams[ordinal - first - 1], segment.from)
                let to = ordinal == last ? segment.to : min(segment.sourceClipSeams[ordinal - first], segment.to)
                let input = from < to ? MulticamRange(from: from, to: to) : nil
                let output = try input.map { range in
                    try MulticamRange(from: segment.outputStart.adding(range.from.subtracting(segment.from)),
                                      to: segment.outputStart.adding(range.to.subtracting(segment.from)))
                }
                occurrences.append(.init(occurrenceNumber: ordinal + 1,
                                         occurrenceID: ids.indices.contains(ordinal) ? ids[ordinal] : nil,
                                         inputNumber: inputNumbers.indices.contains(ordinal) ? inputNumbers[ordinal] : nil,
                                         file: clip.file.path, inputClock: "source",
                                         requestedFrom: clip.from, requestedTo: clip.to,
                                         input: input, output: output, segmentNumber: index + 1, placementID: nil))
            }
        }
        self.occurrences = occurrences
    }

    public init(multicam: MulticamPlan) {
        self.init(multicam: multicam, inputNumbersByAssemblyIndex: nil)
    }

    package init(multicam: MulticamPlan, inputNumbersByAssemblyIndex: [Int: Int]?) {
        var rows: [Occurrence] = []
        var first: MulticamInterval?
        var last: MulticamInterval?
        func finishOccurrence() {
            guard let first, let last else { return }
            let index = first.assemblyIndex
            rows.append(.init(occurrenceNumber: inputNumbersByAssemblyIndex == nil ? index + 1 : rows.count + 1,
                              occurrenceID: nil, inputNumber: inputNumbersByAssemblyIndex?[index],
                              file: nil, inputClock: "group", requestedFrom: nil, requestedTo: nil,
                              input: .init(from: first.group.from, to: last.group.to),
                              output: .init(from: first.output.from, to: last.output.to),
                              segmentNumber: nil, placementID: nil))
        }
        for interval in multicam.intervals {
            // The CLI's mixed join uses the same assembly index for each reuse of an input.
            // A repeated placement restarts its group clock even when it follows itself.
            if let previous = last,
               previous.assemblyIndex != interval.assemblyIndex || previous.group.to != interval.group.from
                   || previous.output.to != interval.output.from {
                finishOccurrence()
                first = nil
            }
            if first == nil { first = interval }
            last = interval
        }
        finishOccurrence()
        occurrences = rows
    }

    init(stills project: CutProject, relativeTo document: URL) throws {
        occurrences = try project.timelineOccurrences().map { occurrence in
            .init(occurrenceNumber: occurrence.index + 1, occurrenceID: occurrence.id,
                  inputNumber: occurrence.index + 1,
                  file: occurrence.file.map { CutProject.mediaURL($0, relativeTo: document).path },
                  inputClock: occurrence.assetID == nil ? project.timelineInputClock.rawValue : "generated",
                  requestedFrom: nil, requestedTo: nil, input: occurrence.input, output: occurrence.output,
                  segmentNumber: nil, placementID: occurrence.assetID == nil ? nil : occurrence.id)
        }
    }
}
