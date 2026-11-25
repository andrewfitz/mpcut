import MPCutCore
import SwiftUI

struct MulticamTrackReplacementView: View {
    @ObservedObject var model: MulticamEditorModel
    let original: MulticamAudioSelection?
    let onClose: () -> Void

    @State private var incoming: MulticamEditorModel.SourceDraft?
    @State private var incomingStream: Int?
    @State private var reference: Reference?
    private struct Reference: Hashable {
        let source: String
        let stream: Int?
    }
    @State private var referencePoint = ""
    @State private var incomingPoint = ""
    @State private var offset: RationalTime?
    @State private var alignedReferenceIdentity: SourceIdentity?
    @State private var uncovered: MulticamAudioReplacement.Uncovered?
    @State private var suggestion: MulticamSync.Suggestion?
    @State private var evidenceIdentity: SourceIdentity?
    @State private var issue: String?
    @State private var request: UUID?
    @State private var audition = TranscriptAuditionPanel()

    init(model: MulticamEditorModel, original: MulticamAudioSelection?,
         incoming: MulticamEditorModel.SourceDraft? = nil, incomingStream: Int? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.original = original
        self.onClose = onClose
        let saved = model.project?.audioReplacements.first { $0.original == original }
        let draft = incoming ?? saved.flatMap { binding in
            model.project?.audioSources.first { $0.id == binding.replacement.source }.flatMap { source in
                model.media[source.id].map {
                    MulticamEditorModel.SourceDraft(source: source, media: $0,
                                                   ordinaryMedia: model.ordinaryAnalysisMedia(source.id))
                }
            }
        }
        _incoming = State(initialValue: draft)
        _incomingStream = State(initialValue: incomingStream ?? saved?.replacement.stream ?? draft?.source.audioStream)
        _reference = State(initialValue: original.map { .init(source: $0.source, stream: $0.stream) })
        _offset = State(initialValue: draft == nil ? nil : saved?.relativeOffset)
        _alignedReferenceIdentity = State(initialValue: original.flatMap { model.media[$0.source]?.identity })
        _uncovered = State(initialValue: saved?.uncovered)
    }

    var body: some View {
        let currentCoverage = coverage
        EditorSheet(title: original == nil ? "Align Program Audio" : "Replace Track Audio",
                    message: "Choose the original and incoming streams, then match the same sound in both recordings.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    streamControls
                    alignmentControls
                    if let suggestion, evidenceIdentity == referenceIdentity { evidence(suggestion) }
                    if let offset { confirmation(offset, coverage: currentCoverage) }
                    if let issue { IssueLabel(issue) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, idealHeight: 435)
        } actions: {
            Button("Choose Recording…") {
                model.chooseExternalSoundtrack(onFailure: { issue = $0 }) { draft in
                    let prepared = preparedDraft(draft)
                    incoming = prepared
                    incomingStream = prepared.source.audioStream
                    invalidate()
                }
            }
            .disabled(model.isBusy)
            Spacer()
            Button("Cancel") {
                if model.isBusy { model.cancel() }
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button("Apply", action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply(with: currentCoverage))
        }
        .frame(width: 580)
        .onAppear {
            if reference == nil {
                let choices = referenceChoices
                let preferred = model.project?.angles.first { $0.id == model.project?.referenceAngle }
                reference = choices.first { $0.source == preferred?.id && $0.stream == preferred?.audioStream }
                    ?? choices.first { $0.source == preferred?.id } ?? choices.first
            }
            if original == nil, let incoming { self.incoming = preparedDraft(incoming) }
        }
        .onChange(of: model.mcpRevision) { _, _ in invalidate() }
        .onChange(of: referenceIdentity) { _, _ in invalidate() }
        .onDisappear { audition.close() }
        .task(id: request) {
            guard request != nil else { return }
            await analyze()
        }
    }

    private var streamControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scratch stream", selection: Binding(get: { reference }, set: { choice in
                guard choice != reference else { return }
                invalidate()
                reference = choice
            })) {
                Text("Choose a camera recording").tag(nil as Reference?)
                ForEach(referenceChoices, id: \.self) { choice in
                    Text(streamLabel(choice)).tag(Optional(choice))
                }
            }
            if let incoming {
                Text("Incoming · \(incoming.source.displayName)")
                Picker("Incoming stream", selection: Binding(get: { incomingStream }, set: { stream in
                    guard stream != incomingStream else { return }
                    invalidate()
                    incomingStream = stream
                })) {
                    ForEach(incoming.media.audio.map(\.stream), id: \.index) { stream in
                        Text(stream.exportLabel).tag(Optional(stream.index))
                    }
                }
            }
            if model.isBusy { ProgressView("Indexing recording…").controlSize(.small) }
        }
    }

    private var alignmentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Analyze Sync") {
                    issue = nil
                    suggestion = nil
                    request = UUID()
                }
                .disabled(!hasPair || request != nil)
                .help("With both points entered, search within 30 seconds of their alignment.")
                if request != nil { ProgressView().controlSize(.small) }
            }
            HStack {
                TextField("Scratch point (s)", text: $referencePoint)
                    .accessibilityLabel("Scratch point in seconds")
                Button("Audition Scratch") { listen(incoming: false) }
                    .disabled(!hasPair || referenceTrack == nil)
            }
            HStack {
                TextField("Incoming point (s)", text: $incomingPoint)
                    .accessibilityLabel("Incoming point in seconds")
                Button("Audition Incoming") { listen(incoming: true) }
                    .disabled(!hasPair)
            }
            Button("Align These Points") {
                do {
                    guard let anchor = try manualOffset() else {
                        throw CutError(code: "invalid_time", message: "Enter one time in seconds for each recording.")
                    }
                    offset = anchor
                    alignedReferenceIdentity = referenceIdentity
                    uncovered = nil
                    issue = nil
                } catch { issue = error.localizedDescription }
            }
            .disabled(!hasPair)
        }
    }

    private func evidence(_ proposal: MulticamSync.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let metadata = proposal.metadataOffset {
                Button(proposal.stamp?.kind == .broadcastWave ? "Use Broadcast Wave Alignment" : "Use Timecode Alignment") {
                    select(groupOffset: metadata)
                }
            }
            if let message = proposal.metadataIssue { Text(message).foregroundStyle(.secondary) }
            if let waveform = proposal.waveformOffset {
                Button("Use Waveform Alignment") {
                    select(groupOffset: waveform)
                    if let match = proposal.matches.first, let relative = offset,
                       let paired = try? match.referenceTime.subtracting(relative) {
                        referencePoint = match.referenceTime.description
                        incomingPoint = paired.description
                    }
                }
                if let first = proposal.matches.first, let last = proposal.matches.last,
                   let referenceSource {
                    matchPosition("First match", match: first, referenceOffset: referenceSource.offset)
                    if last.referenceTime != first.referenceTime {
                        matchPosition("Last match", match: last, referenceOffset: referenceSource.offset)
                    }
                }
                if let drift = proposal.drift {
                    if abs(drift.seconds) > MulticamSync.waveformResolution.seconds {
                        Text("Measured drift · \(drift.description) s from first to last match. Apply uses a fixed offset.")
                    } else {
                        Text("First and last matches agree within \(MulticamSync.waveformResolution.description) s.")
                    }
                } else {
                    Text("Drift unmeasured. The waveform did not yield two independent matches.")
                }
            } else if let message = proposal.waveformIssue {
                Text("\(message) Align a point in each recording to continue.")
            }
        }
        .font(.callout)
    }

    private func matchPosition(_ title: String, match: MulticamSync.Match, referenceOffset: RationalTime) -> some View {
        let groupTime = try? match.referenceTime.adding(referenceOffset)
        let incomingTime = groupTime.flatMap { try? $0.subtracting(match.offset) }
        let residual = offset.flatMap { try? match.offset.subtracting(referenceOffset).subtracting($0) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(title) · scratch \(match.referenceTime.description) s · incoming \(incomingTime?.description ?? "—") s")
            if let residual { Text("Residual at selected alignment · \(residual.description) s").foregroundStyle(.secondary) }
        }
    }

    private func confirmation(_ offset: RationalTime, coverage: MulticamSync.ReplacementCoverage?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Incoming zero on scratch clock · \(offset.description) s")
                Spacer()
                Button("−1 sample") { step(by: -1) }
                Button("+1 sample") { step(by: 1) }
            }
            Button("Audition Aligned Incoming") { listenAligned() }
                .disabled(coverage?.overlap.isEmpty != false)
            if suggestion?.drift == nil { Text("Drift unmeasured.").foregroundStyle(.secondary) }
            if let coverage {
                Text("Incoming start–end · \(coverage.incoming.from.description)–\(coverage.incoming.to.description) s")
                Text("Overlap · \(describe(coverage.overlap))")
                if !coverage.uncovered.isEmpty {
                    Text("Uncovered · \(describe(coverage.uncovered))")
                    if original != nil {
                        Picker("Uncovered audio", selection: $uncovered) {
                            Text("Choose how to handle gaps").tag(nil as MulticamAudioReplacement.Uncovered?)
                            Text("Keep original audio").tag(Optional(MulticamAudioReplacement.Uncovered.keepOriginal))
                            Text("Leave uncovered").tag(Optional(MulticamAudioReplacement.Uncovered.leaveUncovered))
                        }
                    } else {
                        Text("Program replacement needs continuous coverage across the cut.")
                    }
                }
            }
        }
        .font(.callout)
    }

    private var referenceChoices: [Reference] {
        let recordings = (model.project?.pictureSources ?? []).filter { original == nil || $0.id == original?.source }
        return recordings.flatMap { source -> [Reference] in
            guard let media = model.media[source.id] else { return [] }
            if original == nil, media.audio.isEmpty { return [Reference(source: source.id, stream: nil)] }
            return media.audio.map { Reference(source: source.id, stream: $0.stream.index) }
        }
    }

    private func streamLabel(_ selection: Reference) -> String {
        let source = model.project?.pictureSources.first { $0.id == selection.source }
        let name = source?.displayName ?? selection.source
        guard let index = selection.stream else { return "\(name) · Picture clock" }
        let stream = model.media[selection.source]?.audio.first { $0.stream.index == index }?.stream
        return "\(name) · \(stream?.exportLabel ?? "Stream \(index)")"
    }

    private var referenceIdentity: SourceIdentity? {
        reference.flatMap { model.media[$0.source]?.identity }
    }

    private var referenceSource: MulticamSource? {
        model.project?.pictureSources.first { $0.id == reference?.source }
    }

    private var referenceTrack: AudioIndex? {
        guard let reference else { return nil }
        return model.media[reference.source]?.audio.first { $0.stream.index == reference.stream }
    }

    private var incomingTrack: AudioIndex? {
        incoming?.media.audio.first { $0.stream.index == incomingStream }
    }

    private var hasPair: Bool {
        let hasPictureClock = original == nil && reference?.stream == nil &&
            reference.flatMap { model.media[$0.source] } != nil
        let hasReference = referenceTrack != nil || hasPictureClock
        return hasReference && incomingTrack != nil && !model.isBusy
    }

    private func usedRanges() throws -> [MulticamRange] {
        guard let reference, let project = model.project else { return [] }
        return try MulticamSync.usedReferenceRanges(project: project, referenceSourceID: reference.source,
                                                    referenceStream: reference.stream, program: original == nil)
    }

    private var coverage: MulticamSync.ReplacementCoverage? {
        guard let incomingTrack, let offset else { return nil }
        return try? MulticamSync.replacementCoverage(in: usedRanges(), track: incomingTrack, relativeOffset: offset)
    }

    private func canApply(with coverage: MulticamSync.ReplacementCoverage?) -> Bool {
        guard hasPair, request == nil, let reference,
              let alignedReferenceIdentity, alignedReferenceIdentity == model.media[reference.source]?.identity,
              let coverage else { return false }
        return coverage.uncovered.isEmpty || (original != nil && uncovered != nil)
    }

    private func describe(_ ranges: [MulticamRange]) -> String {
        ranges.isEmpty ? "None" : ranges.map { "\($0.from)–\($0.to) s" }.joined(separator: ", ")
    }

    private func invalidate() {
        request = nil
        offset = nil
        alignedReferenceIdentity = nil
        uncovered = nil
        suggestion = nil
        evidenceIdentity = nil
        issue = nil
        referencePoint = ""
        incomingPoint = ""
        audition.close()
    }

    private func preparedDraft(_ draft: MulticamEditorModel.SourceDraft) -> MulticamEditorModel.SourceDraft {
        guard let project = model.project else { return draft }
        let bound = Set(project.audioReplacements.map(\.replacement.source))
        if original != nil, let reusable = project.audioSources.first(where: {
            bound.contains($0.id) && URL(fileURLWithPath: $0.file).standardizedFileURL == draft.media.url.standardizedFileURL
        }) {
            return .init(source: reusable, media: draft.media, ordinaryMedia: draft.ordinaryMedia)
        }
        guard project.sources.contains(where: { $0.id == draft.id }) else { return draft }
        var source = draft.source
        source.id = ProjectIdentifier.make(avoiding: project.sources.map(\.id))
        source.offset = .zero
        source.coverage = nil
        source.additionalRecordings = []
        return .init(source: source, media: draft.media, ordinaryMedia: draft.ordinaryMedia)
    }

    private func manualOffset() throws -> RationalTime? {
        guard !referencePoint.isEmpty || !incomingPoint.isEmpty else { return nil }
        let scratch = try RationalTime(parsing: referencePoint.trimmingCharacters(in: .whitespaces))
        let replacement = try RationalTime(parsing: incomingPoint.trimmingCharacters(in: .whitespaces))
        guard let reference, let referenceMedia = model.media[reference.source],
              scratch >= (referenceTrack?.start ?? .zero),
              scratch < (referenceTrack?.end ?? referenceMedia.duration),
              let incomingTrack, incomingTrack.start <= replacement, replacement < incomingTrack.end else {
            throw CutError(code: "invalid_time", message: "The paired points must lie within the selected streams.")
        }
        return try scratch.subtracting(replacement)
    }

    private func select(groupOffset: RationalTime) {
        guard let referenceSource, let referenceIdentity, evidenceIdentity == referenceIdentity else { return }
        do {
            offset = try groupOffset.subtracting(referenceSource.offset)
            alignedReferenceIdentity = referenceIdentity
            uncovered = nil
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    private func step(by samples: Int64) {
        guard let offset, let rate = incomingTrack?.stream.sampleRate, rate > 0 else { return }
        do { self.offset = try offset.adding(.init(numerator: samples, denominator: Int64(rate))) }
        catch { issue = error.localizedDescription }
    }

    private func listen(incoming listenIncoming: Bool) {
        guard let reference, let incoming, let incomingStream else { return }
        guard let stream = listenIncoming ? incomingStream : reference.stream else { return }
        let info = listenIncoming ? incoming.media : model.media[reference.source]
        let point = listenIncoming ? incomingPoint : referencePoint
        guard let info else { return }
        do {
            let parsed = point.isEmpty ? nil : try RationalTime(parsing: point)
            try AnalysisSidecar(media: info).checkSource()
            let clip = try replacementAuditionClip(media: info, stream: stream, point: parsed)
            showAudition(clip, stream: stream)
        } catch { issue = error.localizedDescription }
    }

    private func listenAligned() {
        guard let incoming, let incomingStream, let offset, let overlap = coverage?.overlap.first else { return }
        do {
            let point = referencePoint.isEmpty ? overlap.from : try RationalTime(parsing: referencePoint)
            try AnalysisSidecar(media: incoming.media).checkSource()
            let clip = try replacementAuditionClip(media: incoming.media, stream: incomingStream,
                                                   point: point, relativeOffset: offset)
            showAudition(clip, stream: incomingStream)
        } catch { issue = error.localizedDescription }
    }

    private func showAudition(_ clip: PreviewRange, stream: Int) {
        audition.show(clip, streamIndex: stream, parent: model.window?.attachedSheet ?? model.window,
                      autoplay: true, clockOffset: .zero, preferences: model.preferences)
    }

    private func analyze() async {
        guard let project = model.project, let reference, let incoming, let incomingStream,
              let request else { return }
        defer { if self.request == request { self.request = nil } }
        let revision = model.mcpRevision
        let mediaRevision = model.transcriptMediaRevision
        let identity = referenceIdentity
        do {
            let query = try MulticamSync.ReplacementRequest(referenceSourceID: reference.source,
                                                            referenceStream: reference.stream, source: incoming.source,
                                                            stream: incomingStream, seed: manualOffset() ?? offset,
                                                            referenceRanges: usedRanges())
            let result = try await model.replacementSyncSuggestions(for: project, query: query, incoming: incoming.media)
            try Task.checkCancellation()
            guard self.request == request, revision == model.mcpRevision,
                  mediaRevision == model.transcriptMediaRevision, self.reference == reference,
                  self.incoming?.id == incoming.id, self.incomingStream == incomingStream,
                  result.referenceAudioStream == reference.stream,
                  let proposal = result.suggestions.first else { return }
            suggestion = proposal
            evidenceIdentity = identity
        } catch is CancellationError {
        } catch {
            guard self.request == request else { return }
            issue = (error as? CutError)?.message ?? error.localizedDescription
        }
    }

    private func apply() {
        guard canApply(with: coverage), let project = model.project,
              let reference, let incoming, let incomingStream, let incomingTrack, let offset else { return }
        let selection = MulticamAudioSelection(source: incoming.id, stream: incomingStream)
        do {
            let applied: Bool
            if original != nil, let referenceStream = reference.stream {
                applied = model.byHand {
                    model.replaceTrackAudio(.init(source: reference.source, stream: referenceStream),
                                            with: selection, external: incoming, relativeOffset: offset,
                                            uncovered: uncovered ?? .leaveUncovered)
                }
            } else {
                guard let referenceMedia = model.media[reference.source],
                      try SourceIdentity(referenceMedia.url) == referenceMedia.identity else {
                    throw CutError(code: "source_changed", message: "The scratch recording changed. Choose the source again.")
                }
                let groupOffset = try MulticamSync.confirmedProgramOffset(project: project, referenceSourceID: reference.source,
                                                                           track: incomingTrack, relativeOffset: offset)
                applied = model.byHand {
                    model.replaceProgramAudio(with: selection, external: incoming, confirmedOffset: groupOffset)
                }
            }
            if applied { onClose() }
            else { issue = model.notice?.message ?? "Unable to replace audio." }
        } catch { issue = error.localizedDescription }
    }
}

/// Convert scratch-local time to incoming-local time before choosing the exact stream.
func replacementAuditionClip(media: MediaInfo, stream: Int, point: RationalTime?,
                             relativeOffset: RationalTime = .zero) throws -> PreviewRange {
    let audio = media.streams.filter { $0.kind == "audio" }
    guard let track = media.audio.first(where: { $0.stream.index == stream }),
          let ordinal = audio.firstIndex(where: { $0.index == stream }) else {
        throw CutError(code: "missing_audio_stream", message: "The selected stream is unavailable.")
    }
    let audiblePoint = try point?.subtracting(relativeOffset) ?? track.start
    guard audiblePoint >= track.start, audiblePoint < track.end else {
        throw CutError(code: "invalid_time", message: "Choose an audition point inside the selected stream.")
    }
    let from = try max(track.start, audiblePoint.subtracting(.init(numerator: 1, denominator: 2)))
    let end = try min(track.end, audiblePoint.adding(.init(numerator: 3, denominator: 2)))
    var clip = PreviewRange(media: media, from: from, to: end)
    clip.isAudioOnly = true
    clip.assetClockOrigin = media.origin
    clip.audioOrigin = media.origin
    clip.audioTrack = ordinal
    return clip
}
