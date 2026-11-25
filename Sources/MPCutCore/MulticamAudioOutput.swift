import Foundation

public enum MulticamAudioOutput: String, CaseIterable, Codable, Sendable {
    case separateTracks = "separate_tracks"
    case downmixMono = "downmix_mono"
    case downmixStereo = "downmix_stereo"
}

public struct MulticamExportAudioLane: Encodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let colorSlot: Int?
    public let sourceLaneIDs: [String]
    public let segments: [ResolvedSegment]
    public let action: ReencodeAudio
    public let codec: String
    public let sampleRate: Int
    public let channelLayout: String
    public let generatedSilence: [MulticamRange]
    public let retainedPCM: Bool
    public let warnings: [String]
    /// The rate of a rendered lossy lane and the word length of a rendered PCM, FLAC or ALAC lane, as they are encoded.
    public var bitRate: Int? = nil
    public var bitDepth: Int? = nil
    /// Why `auto` wrote this format, for a rendered lane that keeps its source's compressed format.
    public var reason: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, label, colorSlot, segments, action, codec, sampleRate, channelLayout, generatedSilence, retainedPCM, warnings
        case bitRate, bitDepth, reason
        case sourceLaneIDs = "source_lane_ids"
    }
}

struct MulticamExportSound: Sendable {
    enum Treatment: Sendable {
        case copy(ResolvedEdit)
        case render(MulticamAudioConversionPlan)
        case downmix(MulticamAudioDownmixPlan)
    }

    var report: MulticamExportAudioLane
    let treatment: Treatment

    var edit: ResolvedEdit {
        switch treatment {
        case .copy(let edit): return edit
        case .render(let plan): return plan.edit
        case .downmix(let plan): return plan.edit
        }
    }

    var container: String { edit.container }

    func verifySources(using engine: CutEngine) throws {
        for (file, identity) in edit.identities {
            try engine.verifyIdentity(file, identity: identity)
        }
    }
}

extension MulticamProject {
    package func configuredSelection(for lane: MulticamPlannedAudioLane) -> MulticamAudioSelection? {
        let original: MulticamAudioSelection?
        switch mixLanes.first(where: { $0.id == lane.id })?.target {
        case .camera(let id):
            original = recordings(for: id).lazy.compactMap { source in
                source.audioStream.map { MulticamAudioSelection(source: source.id, stream: $0) }
            }.first
        case .recording(let selection):
            original = selection
        case nil:
            return nil
        }
        guard let original else { return nil }
        return audioReplacements.first(where: { $0.original == original })?.replacement ?? original
    }
}

extension MulticamEngine {
    func resolveAudioOutput(_ mapping: MulticamPlan, resolvedLanes lanes: [MulticamPlannedAudioLane], project: MulticamProject?, sources: [String: MediaInfo],
                            container: String, output: MulticamAudioOutput, action: ReencodeAudio,
                            offerBoundaries: Bool, mode: ExportMode, wantPicture: Bool,
                            settings: ReencodeSettings) throws -> [MulticamExportSound] {
        let codecs = ExportRules.multicamRenderedAudioActions(container: container)
        if output != .separateTracks {
            guard action != .copyOriginal else {
                throw CutError(code: "unsupported_audio", message: "Downmix requires rendered audio. Choose Auto, AAC, or PCM.")
            }
            let codec = try renderedCodecs(action, available: codecs, container: container)[0]
            let channels = output == .downmixMono ? 1 : 2
            let spans = try lanes.map { try conversionSpans($0, sources: sources, duration: mapping.duration) }
            let mix = try resolveDownmixedSound(spans, duration: mapping.duration, container: container, action: codec,
                                                channels: channels) { issue, lane, index in
                try self.conversionIssue(issue, at: spans[lane][index].output, lane: lanes[lane], mapping: mapping)
            }
            let layout = channels == 1 ? "mono" : "stereo"
            let report = MulticamExportAudioLane(id: output.rawValue, label: channels == 1 ? "Mono downmix" : "Stereo downmix",
                colorSlot: nil, sourceLaneIDs: lanes.map(\.id), segments: mix.lanes.compactMap { $0 }.flatMap { $0.edit.segments }, action: codec,
                codec: codec == .aac ? "aac" : "pcm_f32le", sampleRate: mix.sampleRate, channelLayout: layout,
                generatedSilence: commonGaps(lanes, duration: mapping.duration), retainedPCM: false, warnings: mix.warnings,
                bitRate: mix.output.writtenBitRate, bitDepth: mix.output.writtenBitDepth)
            return [.init(report: report, treatment: .downmix(mix))]
        }

        if lanes.count > 1 && !["mov", "mp4", "m4a", "mkv", "mka", "webm"].contains(container) {
            throw CutError(code: "unsupported_container",
                           message: "\(container.uppercased()) carries one audio track. Choose a downmix or a container that carries separate tracks.")
        }
        if lanes.count > 1 { try MulticamMux(cancelled: cancelled).check(container: container) }

        return try zip(mapping.audioLanes, lanes).map { original, lane in
            var copyFailure: CutError?
            if action == .copyOriginal || action == .auto {
                let copySpans = try coalescingPhysicalSound(copySpansPreservingLeadingPCM(original: original, lane: lane,
                    project: project, sources: sources, container: container, bindings: mapping.joinedAudioReplacements))
                do {
                    if let gap = MulticamPlan.uncovered(in: .init(from: .zero, to: mapping.duration), sound: copySpans).first {
                        let code = original.gaps.contains(gap) && !mapping.isMix ? "missing_audio" : "uncovered_audio"
                        let issue = CutError(code: code,
                            message: "The selected soundtrack needs generated silence.")
                        throw try conversionIssue(issue, at: gap, lane: lane, mapping: mapping, original: original)
                    }
                    try validateLane(copySpans, duration: mapping.duration, kind: lane.label)
                    let copy = try resolveSound(mapping, sources: sources, container: container, spans: copySpans, laneID: lane.id)
                    guard let first = copySpans.first,
                          let stream = sources[first.source]?.audio.first(where: { $0.stream.index == first.stream })?.stream else {
                        throw CutError(code: "missing_audio", message: "The selected audio stream is unavailable.")
                    }
                    let report = MulticamExportAudioLane(id: lane.id, label: lane.label, colorSlot: lane.colorSlot,
                        sourceLaneIDs: [lane.id], segments: copy.segments, action: .copyOriginal, codec: stream.codec,
                        sampleRate: stream.sampleRate, channelLayout: stream.canonicalChannelLayout,
                        generatedSilence: [], retainedPCM: false,
                        warnings: copy.audioJoinNotes.map { "Audio lane \(lane.label): \($0)" })
                    return .init(report: report, treatment: .copy(copy))
                } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                    copyFailure = issue
                    if action == .copyOriginal {
                        guard offerBoundaries, issue.code == "unsafe_boundary", issue.multicam?.at != nil,
                              let segment = issue.segment, copySpans.indices.contains(segment - 1),
                              let field = issue.boundary else { throw issue }
                        let span = copySpans[segment - 1]
                        let seam = field == "from" ? span.output.from : span.output.to
                        let hasPictureSwitch = wantPicture && mapping.picture.dropLast().contains { $0.output.to == seam }
                        let candidateAudio: (MulticamPlan) throws -> Void = { candidate in
                            try validateCandidateAudio(candidate, project: project, sources: sources, container: container,
                                                       output: output, action: action, useAudio: true)
                        }
                        let offered = try hasPictureSwitch
                            ? pictureAlternatives(at: seam, mapping: mapping, media: sources, mode: mode, container: container,
                                settings: settings,
                                replanning: markerPlanner(project), validatesCandidate: candidateAudio)
                            : soundOnlyAlternatives(at: seam, mapping: mapping, media: sources, container: container,
                                spans: copySpans, replanning: markerPlanner(project), validatesCandidate: candidateAudio)
                        throw CutError(code: issue.code, message: issue.message, segment: issue.segment, boundary: issue.boundary,
                                       nearest: offered, track: issue.track, multicam: issue.multicam, laneID: lane.id).because(issue.reason)
                    }
                }
            }
            let spans = try conversionSpans(lane, sources: sources, duration: mapping.duration)
            let format = lane.spans.isEmpty
                ? silenceFormat(for: original, mapping: mapping, project: project, sources: sources)
                : nil
            let PCM = action == .auto && !lane.gaps.isEmpty
                ? try StillSoundPlanner(cancelled: cancelled).resolveRetainedPCM(spans, duration: mapping.duration,
                                                                                container: container, format: format)
                : nil
            if let PCM {
                do {
                    return try renderedLane(lane, plan: PCM, retained: true, warning: "Retained PCM samples + generated silence.")
                } catch let issue as CutError {
                    throw try conversionIssue(issue, at: .init(from: .zero, to: mapping.duration), lane: lane, mapping: mapping)
                }
            }
            // Auto keeps the lane's own compressed format where the container and the helper allow.
            if action == .auto, let kept = sourceFormatPlan(spans, duration: mapping.duration,
                                                            container: container, source: .multicam,
                                                            silenceFormat: format, contextual: { issue, index in
                                                                try self.conversionIssue(issue, at: spans[index].output, lane: lane, mapping: mapping)
                                                            }) {
                var plan = kept.plan
                plan.verifiesSampleRange = container != "mkv"
                var rendered = try renderedLane(lane, plan: plan, retained: false, warning: copyFailure?.message)
                rendered.report.reason = kept.note
                return rendered
            }
            let choices: [ReencodeAudio]
            do {
                choices = try renderedCodecs(action, available: codecs, container: container)
            } catch let issue as CutError {
                if let copyFailure { throw copyFailure }
                throw try conversionIssue(issue, at: .init(from: .zero, to: mapping.duration), lane: lane, mapping: mapping)
            }
            var failed: CutError?
            for codec in choices {
                do {
                    var plan = try resolveConvertedSound(spans, duration: mapping.duration, container: container,
                                                         action: codec, allowsSilence: true, silenceFormat: format) { issue, index in
                        try conversionIssue(issue, at: spans[index].output, lane: lane, mapping: mapping)
                    }
                    plan.verifiesSampleRange = container != "mkv"
                    if container == "m4a" { plan.muxer = "ipod" }
                    if container == "wave" { plan.muxer = "wav" }
                    return try renderedLane(lane, plan: plan, retained: false, warning: copyFailure?.message)
                } catch let issue as CutError where issue.code != "cancelled" && issue.code != "source_changed" {
                    failed = try issue.laneID == nil
                        ? conversionIssue(issue, at: .init(from: .zero, to: mapping.duration), lane: lane, mapping: mapping) : issue
                }
            }
            throw failed ?? CutError(code: "unsupported_audio", message: "No rendered codec is available.", laneID: lane.id)
        }
    }

    func validateCandidateAudio(_ mapping: MulticamPlan, project: MulticamProject?, sources: [String: MediaInfo],
                                container: String, output: MulticamAudioOutput, action: ReencodeAudio,
                                useAudio: Bool) throws {
        guard useAudio else { return }
        let resolvedLanes = try project?.resolveAudioLanes(plan: mapping, indexedSources: sources)
            ?? mapping.resolveAudioLanes(indexedSources: sources)
        _ = try resolveAudioOutput(mapping, resolvedLanes: resolvedLanes, project: project, sources: sources, container: container, output: output,
                                   action: action, offerBoundaries: false, mode: .smart, wantPicture: false, settings: .init())
    }

    /// A wholly unavailable lane still has a selected format when its configured stream is indexed.
    private func silenceFormat(for lane: MulticamPlannedAudioLane, mapping: MulticamPlan, project: MulticamProject?,
                               sources: [String: MediaInfo]) -> ConvertedSoundFormat? {
        var selected = lane.spans.compactMap { span in
            span.stream.map { MulticamAudioSelection(source: span.source, stream: $0) }
        }
        let bindings = project?.audioReplacements ?? mapping.joinedAudioReplacements
        selected = selected.map { original in
            bindings.first(where: { $0.original == original })?.replacement ?? original
        }
        if let fallback = project?.configuredSelection(for: lane) ?? mapping.joinedAudioSelections[lane.id] {
            selected.append(fallback)
        }
        for selection in selected {
            if let media = sources[selection.source],
               let audio = media.audio.first(where: { $0.stream.index == selection.stream }) {
                return .init(media: media, audio: audio)
            }
        }
        return nil
    }

    private func renderedCodecs(_ action: ReencodeAudio, available: [ReencodeAudio],
                                container: String) throws -> [ReencodeAudio] {
        if action == .auto && !available.isEmpty { return available }
        if available.contains(action) { return [action] }
        throw CutError(code: "unsupported_audio",
                       message: "\(container.uppercased()) cannot write the selected rendered audio.")
    }

    func copySpansPreservingLeadingPCM(original: MulticamPlannedAudioLane, lane: MulticamPlannedAudioLane,
                                               project: MulticamProject?, sources: [String: MediaInfo],
                                               container: String, bindings: [MulticamAudioReplacement] = []) throws -> [MulticamSpan] {
        guard container == "mov", var first = lane.spans.first, let planned = original.spans.first,
              let stream = planned.stream, planned.output.from == .zero,
              let firstStream = first.stream,
              let track = sources[first.source]?.audio.first(where: { $0.stream.index == firstStream }),
              track.hasDeclaredPCMStart, first.input.from == track.start,
              lane.gaps.first == .init(from: .zero, to: first.output.from) else { return lane.spans }
        let originalSelection = MulticamAudioSelection(source: planned.source, stream: stream)
        let binding = (project?.audioReplacements ?? bindings).first { $0.original == originalSelection }
        let activeSelection = binding?.replacement ?? originalSelection
        let sourceStart = try planned.input.from.subtracting(binding?.relativeOffset ?? .zero)
        guard first.source == activeSelection.source, firstStream == activeSelection.stream,
              first.replacementBindingID == binding?.id, sourceStart >= .zero,
              try first.input.from.subtracting(sourceStart) == first.output.from else { return lane.spans }
        first.input.from = sourceStart
        first.output.from = .zero
        return [first] + lane.spans.dropFirst()
    }

    private func coalescingPhysicalSound(_ spans: [MulticamSpan]) -> [MulticamSpan] {
        var merged: [MulticamSpan] = []
        for span in spans {
            if let index = merged.indices.last, merged[index].source == span.source,
               merged[index].stream == span.stream, merged[index].input.to == span.input.from,
               merged[index].output.to == span.output.from {
                merged[index].input.to = span.input.to
                merged[index].output.to = span.output.to
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func conversionSpans(_ lane: MulticamPlannedAudioLane, sources: [String: MediaInfo],
                                 duration: RationalTime) throws -> [ConvertedSoundSpan] {
        var output: [ConvertedSoundSpan] = []
        var end = RationalTime.zero
        func silence(until next: RationalTime) {
            if end < next {
                let gap = MulticamRange(from: end, to: next)
                output.append(.init(media: nil, stream: nil, input: gap, output: gap))
            }
        }
        for span in coalescingPhysicalSound(lane.spans) {
            guard end <= span.output.from, span.output.from < span.output.to, span.output.to <= duration else {
                throw CutError(code: "invalid_range", message: "Lane \(lane.label) has overlapping or out-of-range audio spans.", laneID: lane.id)
            }
            silence(until: span.output.from)
            output.append(.init(media: sources[span.source], stream: span.stream, input: span.input, output: span.output))
            end = span.output.to
        }
        silence(until: duration)
        return output
    }

    func conversionIssue(_ issue: CutError, at output: MulticamRange, lane: MulticamPlannedAudioLane,
                         mapping: MulticamPlan, original: MulticamPlannedAudioLane? = nil) throws -> CutError {
        if issue.code == "cancelled" || issue.code == "source_changed" { return issue }
        let overlap = (original?.spans ?? lane.spans).first { $0.output.from <= output.from && output.from < $0.output.to }
        let picture = mapping.picture.first { $0.output.from <= output.from && output.from < $0.output.to }
        let nearby = overlap ?? (issue.code == "missing_audio" ? picture : nil) ?? lane.spans.first
        let from = try (overlap ?? (issue.code == "missing_audio" ? picture : nil)).map { try $0.input.from.adding(output.from.subtracting($0.output.from)) } ?? .zero
        let to = try from.adding(output.to.subtracting(output.from))
        let span = MulticamSpan(source: nearby?.source ?? "", stream: nearby?.stream, input: .init(from: from, to: to), output: output)
        let contextualized = try contextual(issue, span: span, mapping: mapping, index: issue.segment ?? 1, laneID: lane.id)
        let location = nearby.map { span in
            let stream = span.stream.map { " stream \($0)" } ?? ""
            return ", source \(span.source)\(stream)"
        } ?? ""
        return CutError(code: issue.code, message: "Audio lane \(lane.label) (\(lane.id))\(location), output \(output.from)–\(output.to): \(issue.message)",
                        segment: contextualized.segment, boundary: issue.boundary, nearest: contextualized.nearest,
                        track: contextualized.track, multicam: contextualized.multicam, laneID: lane.id).because(issue.reason)
    }

    private func renderedLane(_ lane: MulticamPlannedAudioLane, plan: MulticamAudioConversionPlan,
                              retained: Bool, warning: String?) throws -> MulticamExportSound {
        let codec = plan.writtenCodec
        if plan.action == .pcm && ["wav", "wave"].contains(plan.edit.container) {
            let bytesPerSample = (plan.writtenBitDepth ?? 32) / 8
            let frames = try plan.edit.duration.roundedToSamples(plan.sampleRate)
            guard frames <= 0xFFFF_F000 / (Int64(plan.channels) * Int64(bytesPerSample)) else {
                throw CutError(code: "unsupported_container", message: "This PCM audio exceeds the 4 GB limit of WAV. Choose CAF.")
            }
        }
        let report = MulticamExportAudioLane(id: lane.id, label: lane.label, colorSlot: lane.colorSlot,
            sourceLaneIDs: [lane.id], segments: plan.edit.segments, action: plan.action, codec: codec,
            sampleRate: plan.sampleRate, channelLayout: plan.layout, generatedSilence: lane.gaps,
            retainedPCM: retained, warnings: [warning].compactMap { $0 } + plan.warnings,
            bitRate: plan.writtenBitRate, bitDepth: plan.writtenBitDepth)
        return .init(report: report, treatment: .render(plan))
    }

    private func commonGaps(_ lanes: [MulticamPlannedAudioLane], duration: RationalTime) -> [MulticamRange] {
        var intersection: [MulticamRange] = [.init(from: .zero, to: duration)]
        for lane in lanes {
            intersection = intersection.flatMap { current in
                lane.gaps.compactMap { gap in
                    let from = max(current.from, gap.from)
                    let to = min(current.to, gap.to)
                    return from < to ? .init(from: from, to: to) : nil
                }
            }
        }
        return intersection
    }

    func writeSound(_ sound: MulticamExportSound, to destination: URL,
                    progress: (@Sendable (Double) -> Void)?) throws {
        switch sound.treatment {
        case .copy(let edit):
            try CutEngine(cancelled: cancelled).export(edit, to: destination, audioOnly: true,
                                                        programAudio: edit.container != "flac") { fraction in
                progress?(fraction)
                return true
            }
        case .render(let plan): try writeConvertedSound(plan, to: destination, progress: progress)
        case .downmix(let plan): try writeConvertedSound(plan, to: destination, progress: progress)
        }
    }
}
