import Foundation

enum ParticipantRenderSound {
    static func resolve(_ project: CutProject, document: URL, timeline: StillTimelinePlan,
                        audio: ParticipantRenderAudio, cancelled: (@Sendable () -> Bool)?) throws -> StillSoundPlan {
        if audio.mode == .silence {
            return .init(actions: [], treatments: [], container: "mov")
        }
        try project.validate()
        let planner = StillSoundPlanner(cancelled: cancelled)
        let binding: ParticipantAudioBinding?
        if audio.mode == .iso {
            guard let id = audio.ids.first, let selected = project.participants.audioBinding(for: id) else {
                throw missing("The selected participant has no isolated microphone binding.")
            }
            binding = selected
        } else {
            binding = nil
        }
        switch project {
        case .multicam(var multicam):
            switch audio.mode {
            case .program, .silence: break
            case .iso:
                guard let binding else { throw missing("The selected participant has no isolated microphone binding.") }
                try apply(binding, to: &multicam)
            case .lanes:
                try selectLanes(audio.ids, in: &multicam)
            case .follow:
                guard let angle = audio.ids.first,
                      multicam.recordings(for: angle).contains(where: { $0.audioStream != nil }) else {
                    throw missing("The selected camera has no configured microphone.")
                }
                multicam.audio = .follow
                multicam.switches = [.init(at: .zero, angle: angle)]
            }
            let output: MulticamAudioOutput = audio.mode == .program && multicam.audio == .mix
                ? .downmixStereo : .separateTracks
            return try planner.resolve(.multicam(multicam), relativeTo: document, timeline: timeline,
                                       tracks: .all, audioStream: nil, mode: .encode, audio: .pcm,
                                       container: "mov", audioOutput: output)
        case .sequence, .stillSequence:
            switch audio.mode {
            case .program:
                return try planner.resolve(project, relativeTo: document, timeline: timeline,
                                           tracks: .all, audioStream: nil, mode: .encode, audio: .pcm,
                                           container: "mov", audioOutput: .downmixStereo)
            case .iso:
                guard let selection = binding?.selection else {
                    throw missing("A sequence ISO needs a source and stream binding.")
                }
                return try resolveSequenceISO(project, document: document, timeline: timeline,
                                              selection: selection, cancelled: cancelled)
            case .lanes, .follow:
                throw missing("Lane and camera audio routing require a multicam project.")
            case .silence:
                return .init(actions: [], treatments: [], container: "mov")
            }
        }
    }

    private static func resolveSequenceISO(_ project: CutProject, document: URL, timeline: StillTimelinePlan,
                                           selection: MulticamAudioSelection,
                                           cancelled: (@Sendable () -> Bool)?) throws -> StillSoundPlan {
        let clips = Dictionary(uniqueKeysWithValues: (project.sequenceClips ?? []).map { ($0.id, $0) })
        let file = try CutProject.checkedMediaURL(selection.source, relativeTo: document)
        let media = try CutEngine(cancelled: cancelled).inspect(file)
        let matchingFiles = Set(clips.values.map(\.file)).filter { path in
            guard let candidate = try? CutProject.checkedMediaURL(path, relativeTo: document) else { return false }
            return file == candidate || (try? SourceIdentity(candidate)) == media.identity
        }
        guard !matchingFiles.isEmpty else {
            throw missing("Place a microphone from a separate recording on a synced multicam audio source.")
        }
        guard let index = media.audio.first(where: { $0.stream.index == selection.stream }) else {
            throw missing("The participant's source has no matching microphone stream.")
        }
        let coverage = try index.audibleBounds(origin: media.origin)
        var spans: [ConvertedSoundSpan] = []
        func appendSilence(from: RationalTime, to: RationalTime) {
            guard from < to else { return }
            let range = MulticamRange(from: from, to: to)
            spans.append(.init(media: nil, stream: nil, input: range, output: range))
        }
        for span in timeline.spans {
            guard case .source(let id, let range) = span.origin, let clip = clips[id],
                  matchingFiles.contains(clip.file) else {
                appendSilence(from: span.output.from, to: span.output.to)
                continue
            }
            let from = max(range.from, coverage.lowerBound)
            let to = min(range.to, coverage.upperBound)
            guard from < to else {
                appendSilence(from: span.output.from, to: span.output.to)
                continue
            }
            let output = try MulticamRange(from: span.output.from.adding(from.subtracting(range.from)),
                                           to: span.output.from.adding(to.subtracting(range.from)))
            appendSilence(from: span.output.from, to: output.from)
            spans.append(.init(media: media, stream: selection.stream, input: .init(from: from, to: to), output: output))
            appendSilence(from: output.to, to: span.output.to)
        }
        let plan = try MulticamEngine(cancelled: cancelled).resolveConvertedSound(
            spans, duration: timeline.duration, container: "mov", action: .pcm, allowsSilence: true,
            silenceFormat: .init(media: media, audio: index)) { error, _ in error }
        let action = StillSoundAction(ordinal: 0, laneID: MulticamPlan.programAudioLaneID, label: "Participant ISO",
                                      codec: plan.floatingPoint ? "pcm_f32le" : "pcm_s32le",
                                      sampleRate: plan.sampleRate, channelLayout: plan.layout, audio: .pcm,
                                      originalStreams: [selection.stream], sources: spans.compactMap { span in
                                          guard span.media != nil else { return nil }
                                          return .init(file: file, stream: selection.stream, input: span.input, output: span.output)
                                      }, warnings: plan.warnings, generatedSilence: spans.filter { $0.media == nil }.map(\.output))
        return .init(actions: [action], treatments: [.convert(plan)], container: "mov")
    }

    static func apply(_ binding: ParticipantAudioBinding, to project: inout MulticamProject) throws {
        guard (binding.laneID == nil) != (binding.selection == nil) else {
            throw missing("Select one audio lane or one source stream.")
        }
        if let lane = binding.laneID {
            try selectLanes([lane], in: &project)
        } else if let selection = binding.selection {
            guard project.sources.contains(where: { $0.id == selection.source }),
                  (0...Int(Int32.max)).contains(selection.stream) else {
                throw missing("The selected microphone source or stream is unavailable.")
            }
            let replacements = project.audioReplacements.indices.filter {
                project.audioReplacements[$0].replacement == selection
            }
            guard replacements.count <= 1 else {
                throw missing("This microphone has more than one sync placement. Select its audio lane.")
            }
            for index in project.switches.indices { project.switches[index].audio = nil }
            if let index = replacements.first {
                // Keep the replacement's synced placement and fill uncovered time with silence.
                project.audioReplacements[index].uncovered = .leaveUncovered
                project.audio = .fixed(project.audioReplacements[index].original)
            } else {
                // A physical stream binding selects that microphone even when
                // program audio substitutes a different recording for it.
                project.audioReplacements.removeAll { $0.original == selection }
                project.audio = .fixed(selection)
            }
        } else {
            throw missing("The selected microphone binding is empty.")
        }
    }

    private static func selectLanes(_ ids: [String], in project: inout MulticamProject) throws {
        let lanes = project.mixLanes.filter { ids.contains($0.id) }
        guard !ids.isEmpty, lanes.count == ids.count else {
            throw missing("One or more selected microphone lanes are unavailable.")
        }
        project.mixLanes = lanes
        project.audio = .mix
    }

    private static func missing(_ message: String) -> CutError { .init(code: "missing_audio", message: message) }
}
