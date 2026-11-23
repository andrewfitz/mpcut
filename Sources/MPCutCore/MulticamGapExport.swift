import Foundation

extension MulticamPlan {
    package var recordingGaps: [MulticamRange] {
        var gaps: [MulticamRange] = []
        for interval in intervals where interval.pictureSourceID == nil {
            if let last = gaps.indices.last, gaps[last].to == interval.output.from {
                gaps[last].to = interval.output.to
            } else {
                gaps.append(interval.output)
            }
        }
        return gaps
    }
}

extension MulticamEngine {
    func validatePicture(_ mapping: MulticamPlan, gaps: [MulticamRange]) throws {
        guard !gaps.isEmpty else {
            return try validateLane(mapping.picture, duration: mapping.duration, kind: "picture")
        }
        // Validate the actual parts before flattening. The renderer derives each
        // recording's input end from its output length.
        var spans: [MulticamSpan] = []
        spans.reserveCapacity(mapping.picture.count + gaps.count)
        var gapIndex = 0
        for picture in mapping.picture {
            while gapIndex < gaps.count, gaps[gapIndex].from < picture.output.from {
                let gap = gaps[gapIndex]
                spans.append(.init(source: "", stream: nil, input: gap, output: gap))
                gapIndex += 1
            }
            spans.append(picture)
        }
        for gap in gaps.dropFirst(gapIndex) {
            spans.append(.init(source: "", stream: nil, input: gap, output: gap))
        }
        try validateLane(spans, duration: mapping.duration, kind: "picture")
    }

    func resolveRecordingGaps(_ mapping: MulticamPlan, sources: [String: URL], container: String,
                              settings: ReencodeSettings) throws -> (plan: StillExportPlan, segments: [ResolvedSegment]) {
        func file(_ id: String) throws -> URL {
            guard let url = sources[id] else {
                throw CutError(code: "missing_source", message: "Source \(id) has no recording.")
            }
            return url
        }

        // Materialize the assembled presentation clock for the still renderer. The
        // public report retains the original group, assembly and recording IDs.
        let picture = try mapping.picture.enumerated().map { index, span -> MulticamSource in
            guard span.input.from >= .zero else {
                throw CutError(code: "uncovered_picture", message: "Source \(span.source) does not cover output \(span.output.from)–\(span.output.to).")
            }
            return try .init(id: "picture-\(index)", file: file(span.source).path,
                             offset: span.output.from.subtracting(span.input.from), coverage: span.output)
        }
        var angle: MulticamSource
        if let first = picture.first {
            angle = first
            angle.additionalRecordings = Array(picture.dropFirst())
        } else {
            guard let id = mapping.intervals.first?.angle, sources[id] != nil else {
                throw CutError(code: "missing_source", message: "The selected camera has no reference recording for the output format.")
            }
            angle = try .init(id: "picture-format", file: file(id).path, offset: mapping.duration,
                              coverage: .init(from: mapping.duration, to: mapping.duration.adding(.init(numerator: 1))))
        }
        let flattened = MulticamProject(referenceAngle: angle.id, range: .init(from: .zero, to: mapping.duration),
                                        angles: [angle], audio: .none, switches: [.init(at: .zero, angle: angle.id)])
        let planned = try StillExportPlanner(cancelled: cancelled).resolve(flattened, tracks: .video,
            mode: .encode, container: container, settings: settings, offerAlternatives: false)
        let pictureSegments = planned.pictures.compactMap { picture -> ResolvedSegment? in
            guard case let .camera(media, input, frames, _) = picture.content else { return nil }
            return .init(file: media.url, from: input.from, to: input.to, outputStart: picture.output.from,
                         tracks: [], sourceOrigin: media.origin,
                         lastVideoFrame: frames.last.map { media.frames[$0].time }, reachesEnd: input.to == media.duration)
        }
        return (planned, pictureSegments)
    }
}
