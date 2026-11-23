import Foundation

public enum MulticamAudioLaneTarget: Codable, Hashable, Sendable {
    case camera(String)
    case recording(MulticamAudioSelection)

    private enum CodingKeys: String, CodingKey {
        case kind, angle = "angle_id", source = "source_id", stream = "audio_stream_index"
    }
    private enum Kind: String, Codable { case camera, recording }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .camera:
            guard !values.contains(.source), !values.contains(.stream) else {
                throw CutError(code: "invalid_multicam_project", message: "Camera lanes only accept an angle ID.")
            }
            self = .camera(try values.decode(String.self, forKey: .angle))
        case .recording:
            guard !values.contains(.angle) else {
                throw CutError(code: "invalid_multicam_project", message: "Recording lanes only accept a source and stream.")
            }
            self = .recording(try .init(source: values.decode(String.self, forKey: .source),
                                        stream: values.decode(Int.self, forKey: .stream)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .camera(let angle):
            try values.encode(Kind.camera, forKey: .kind)
            try values.encode(angle, forKey: .angle)
        case .recording(let selection):
            try values.encode(Kind.recording, forKey: .kind)
            try values.encode(selection.source, forKey: .source)
            try values.encode(selection.stream, forKey: .stream)
        }
    }
}

public struct MulticamAudioLane: Codable, Hashable, Sendable, Identifiable {
    public static let colorSlotCount = 8

    public let id: String
    public var target: MulticamAudioLaneTarget
    public var label: String
    public var colorSlot: Int

    public init(id: String, target: MulticamAudioLaneTarget, label: String, colorSlot: Int) {
        self.id = id
        self.target = target
        self.label = label
        self.colorSlot = colorSlot
    }

    private enum CodingKeys: String, CodingKey { case id, target, label, colorSlot = "color_slot" }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  target: try values.decode(MulticamAudioLaneTarget.self, forKey: .target),
                  label: try values.decode(String.self, forKey: .label),
                  colorSlot: try values.decode(Int.self, forKey: .colorSlot))
    }
}

public struct MulticamAudioReplacement: Codable, Hashable, Sendable, Identifiable {
    public enum Uncovered: String, Codable, Sendable {
        case keepOriginal = "keep_original"
        case leaveUncovered = "leave_uncovered"
    }

    public let id: String
    public let original: MulticamAudioSelection
    public let replacement: MulticamAudioSelection
    public var relativeOffset: RationalTime
    public var uncovered: Uncovered

    public init(id: String, original: MulticamAudioSelection, replacement: MulticamAudioSelection,
                relativeOffset: RationalTime, uncovered: Uncovered) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.relativeOffset = relativeOffset
        self.uncovered = uncovered
    }

    private enum CodingKeys: String, CodingKey {
        case id, original, replacement, relativeOffset = "relative_offset", uncovered
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  original: try values.decode(MulticamAudioSelection.self, forKey: .original),
                  replacement: try values.decode(MulticamAudioSelection.self, forKey: .replacement),
                  relativeOffset: try ProjectField.time(values, .relativeOffset),
                  uncovered: try values.decode(Uncovered.self, forKey: .uncovered))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(original, forKey: .original)
        try values.encode(replacement, forKey: .replacement)
        try values.encode(relativeOffset.description, forKey: .relativeOffset)
        try values.encode(uncovered, forKey: .uncovered)
    }
}

public struct MulticamPlannedAudioLane: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let colorSlot: Int?
    public var spans: [MulticamSpan]
    public var gaps: [MulticamRange]
    /// Routes classed as gaps because their media or stream wasn't available to a partial-index caller.
    public var unavailableSpans: [MulticamSpan]? = nil

    private enum CodingKeys: String, CodingKey {
        case id, label, colorSlot = "color_slot", spans, gaps, unavailableSpans = "unavailable_spans"
    }

    public init(id: String, label: String, colorSlot: Int? = nil, spans: [MulticamSpan], gaps: [MulticamRange] = []) {
        self.id = id
        self.label = label
        self.colorSlot = colorSlot
        self.spans = spans
        self.gaps = gaps
    }
}

extension MulticamProject {
    /// Sources with a direct route independent of any recording's replacement binding.
    public var directAudioSourceIDs: Set<String> {
        var ids = Set(switches.compactMap { $0.audio?.source })
        if let fixedAudio { ids.insert(fixedAudio.source) }
        if case .fixed(let selection) = audio { ids.insert(selection.source) }
        for lane in mixLanes {
            if case .recording(let selection) = lane.target { ids.insert(selection.source) }
        }
        return ids
    }

    public var defaultMixLanes: [MulticamAudioLane] {
        angles.filter { $0.recordings.contains { $0.audioStream != nil } }.enumerated().map { index, angle in
            let filename = URL(fileURLWithPath: angle.file).deletingPathExtension().lastPathComponent
            let label = angle.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? filename
            return .init(id: "camera:\(angle.id)", target: .camera(angle.id), label: label.isEmpty ? angle.id : label,
                         colorSlot: index % MulticamAudioLane.colorSlotCount)
        }
    }

    public func requiredAudioSelections(for plan: MulticamPlan) -> Set<MulticamAudioSelection> {
        plan.requiredAudioSelections(replacements: audioReplacements)
    }

    /// Resolve a project's planned routes against indexed stream extents and replacement bindings.
    public func resolveAudioLanes(plan: MulticamPlan, indexedSources: [String: MediaInfo],
                                  assumeUnindexedCoverage: Bool = false,
                                  unavailableAsGap: Bool = false) throws -> [MulticamPlannedAudioLane] {
        return try plan.resolveAudioLanes(indexedSources: indexedSources, assumeUnindexedCoverage: assumeUnindexedCoverage,
                                          unavailableAsGap: unavailableAsGap, bindings: audioReplacements)
    }
}

extension MulticamPlan {
    func requiredAudioSelections(replacements: [MulticamAudioReplacement]) -> Set<MulticamAudioSelection> {
        let originals = Set(audioLanes.flatMap(\.spans).compactMap { span in
            span.stream.map { MulticamAudioSelection(source: span.source, stream: $0) }
        })
        var required = originals
        for binding in replacements where originals.contains(binding.original) {
            if binding.uncovered == .leaveUncovered { required.remove(binding.original) }
            required.insert(binding.replacement)
        }
        return required
    }

    public func resolveAudioLanes(indexedSources: [String: MediaInfo],
                                  assumeUnindexedCoverage: Bool = false,
                                  unavailableAsGap: Bool = false) throws -> [MulticamPlannedAudioLane] {
        try resolveAudioLanes(indexedSources: indexedSources, assumeUnindexedCoverage: assumeUnindexedCoverage,
                              unavailableAsGap: unavailableAsGap, bindings: joinedAudioReplacements)
    }

    fileprivate func resolveAudioLanes(indexedSources: [String: MediaInfo], assumeUnindexedCoverage: Bool,
                                       unavailableAsGap: Bool,
                                       bindings: [MulticamAudioReplacement]) throws -> [MulticamPlannedAudioLane] {
        let replacements = Dictionary(bindings.map { ($0.original, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let tracks = indexedSources.mapValues { Dictionary(uniqueKeysWithValues: $0.audio.map { ($0.stream.index, $0) }) }
        return try audioLanes.map { lane in
            var resolved = MulticamPlannedAudioLane(id: lane.id, label: lane.label, colorSlot: lane.colorSlot,
                                                    spans: [], gaps: lane.gaps)
            func audibleParts(_ span: MulticamSpan) throws -> [MulticamSpan] {
                if assumeUnindexedCoverage, span.stream != nil, tracks[span.source] == nil { return [span] }
                guard let stream = span.stream, let track = tracks[span.source]?[stream] else {
                    if unavailableAsGap {
                        if resolved.unavailableSpans == nil { resolved.unavailableSpans = [] }
                        resolved.unavailableSpans?.append(span)
                        return []
                    }
                    let group = try? MulticamEngine().groupRange(span, in: self)
                    let diagnostic = group.map {
                        MulticamDiagnostic(source: span.source, group: $0, sourceTime: span.input, output: span.output,
                                           at: nil, edge: nil, laneID: lane.id)
                    }
                    let streamLabel = span.stream.map { " stream \($0)" } ?? ""
                    throw CutError(code: "missing_audio",
                                   message: "Lane ‘\(lane.label)’ needs source ‘\(span.source)’\(streamLabel) at output \(span.output.from)–\(span.output.to).",
                                   track: span.stream, multicam: diagnostic, laneID: lane.id)
                }
                return try Self.audibleParts(of: span, track: track)
            }
            func routedParts(_ span: MulticamSpan) throws -> [MulticamSpan] {
                guard let stream = span.stream,
                      let binding = replacements[.init(source: span.source, stream: stream)] else {
                    return try audibleParts(span)
                }

                // The replacement uses the original recording clock shifted by
                // the binding, independent of the replacement source's offset.
                let replacement = try MulticamSpan(source: binding.replacement.source, stream: binding.replacement.stream,
                    input: .init(from: span.input.from.subtracting(binding.relativeOffset),
                                 to: span.input.to.subtracting(binding.relativeOffset)),
                    output: span.output, replacementBindingID: binding.id)
                var sound = try audibleParts(replacement)
                if binding.uncovered == .keepOriginal, tracks[replacement.source]?[binding.replacement.stream] != nil {
                    for gap in Self.uncovered(in: span.output, sound: sound) {
                        let fallback = try MulticamSpan(source: span.source, stream: stream, input: .init(
                            from: span.input.from.adding(gap.from.subtracting(span.output.from)),
                            to: span.input.from.adding(gap.to.subtracting(span.output.from))), output: gap)
                        sound += try audibleParts(fallback)
                    }
                    sound.sort { $0.output.from < $1.output.from }
                }
                return sound
            }
            for span in lane.spans {
                let sound = try routedParts(span)
                for part in sound { part.appendCoalescing(to: &resolved.spans) }
                resolved.gaps.append(contentsOf: Self.uncovered(in: span.output, sound: sound))
            }
            resolved.gaps = resolved.gaps.sorted { $0.from < $1.from }.reduce(into: []) { gaps, next in
                if let last = gaps.indices.last, gaps[last].to >= next.from {
                    gaps[last].to = max(gaps[last].to, next.to)
                } else {
                    gaps.append(next)
                }
            }
            return resolved
        }
    }

    package static func audibleParts(of span: MulticamSpan, track: AudioIndex) throws -> [MulticamSpan] {
        let extent = MulticamRange(from: max(span.input.from, track.start), to: min(span.input.to, track.end))
        guard extent.from < extent.to else { return [] }
        let gaps = track.stream.isPCM ? track.pcmGaps : try packetHoles(in: extent, track: track)
        var input = extent.from
        var parts: [MulticamRange] = []
        for gap in gaps where gap.to > input && gap.from < extent.to {
            if input < gap.from { parts.append(.init(from: input, to: gap.from)) }
            input = max(input, gap.to)
        }
        if input < extent.to { parts.append(.init(from: input, to: extent.to)) }
        return try parts.map { part in
            try .init(source: span.source, stream: span.stream, input: part,
                      output: .init(from: span.output.from.adding(part.from.subtracting(span.input.from)),
                                    to: span.output.from.adding(part.to.subtracting(span.input.from))),
                      replacementBindingID: span.replacementBindingID)
        }
    }

    private static func packetHoles(in extent: MulticamRange, track: AudioIndex) throws -> [MulticamRange] {
        // Existing AAC presentation edits are part of the source clock and can
        // be copied as edits. Packet timestamp holes need generated samples.
        let packets = track.packets
        guard track.presentationEdits.isEmpty, packets.count > 1, track.stream.sampleRate > 0 else { return [] }
        let period = RationalTime(numerator: 1, denominator: Int64(track.stream.sampleRate))
        let tolerance = track.stream.timeBase > period ? try track.stream.timeBase.adding(period) : .zero
        let first = max(0, packets.lowerBound { $0.time >= extent.from } - 1)
        let last = min(packets.count, packets.lowerBound { $0.time >= extent.to } + 1)
        guard first < last else { return [] }
        var gaps: [MulticamRange] = []
        var coveredTo: RationalTime?
        for packet in packets[first..<last] where packet.duration > .zero {
            if let previous = coveredTo, packet.time > previous, try packet.time.subtracting(previous) > tolerance {
                gaps.append(.init(from: previous, to: packet.time))
            }
            let end = try packet.time.adding(packet.duration)
            coveredTo = max(coveredTo ?? end, end)
        }
        return gaps
    }

    static func uncovered(in range: MulticamRange, sound: [MulticamSpan]) -> [MulticamRange] {
        var cursor = range.from
        var gaps: [MulticamRange] = []
        for span in sound {
            if cursor < span.output.from { gaps.append(.init(from: cursor, to: span.output.from)) }
            cursor = max(cursor, span.output.to)
        }
        if cursor < range.to { gaps.append(.init(from: cursor, to: range.to)) }
        return gaps
    }
}
