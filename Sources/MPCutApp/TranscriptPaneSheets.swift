import AppKit
import SwiftUI
import MPCutCore

@MainActor
struct TranscriptPaneSheet: Identifiable {
    let id = UUID()
    let title: String
    let content: AnyView
    let contentHasActions: Bool
    let actionTitle: String?
    let actionIdentifier: String
    let action: (() throws -> Void)?

    init<Content: View>(_ title: String, actionTitle: String? = nil, actionIdentifier: String = "transcript.confirm",
                        contentHasActions: Bool = false, action: (() throws -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = AnyView(content())
        self.contentHasActions = contentHasActions
        self.actionTitle = actionTitle
        self.actionIdentifier = actionIdentifier
        self.action = action
    }
}

struct TranscriptPaneSheetView: View {
    let sheet: TranscriptPaneSheet
    let dismiss: () -> Void
    @State private var error: String?

    var body: some View {
        // The layout of `EditorSheet`, with an action that can fail in place.
        VStack(alignment: .leading, spacing: 16) {
            Text(sheet.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            sheet.content
            if let error {
                IssueLabel(error).accessibilityIdentifier("transcript.error")
            }
            if !sheet.contentHasActions {
                HStack(spacing: 10) {
                    Spacer()
                    Button(sheet.action == nil ? "Done" : "Cancel", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                    if let action = sheet.action, let title = sheet.actionTitle {
                        Button(title) {
                            do { try action() } catch { self.error = error.localizedDescription }
                        }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier(sheet.actionIdentifier)
                    }
                }
            }
        }
        .padding(EditorMetrics.sheetPadding)
        .frame(minWidth: 425, idealWidth: 500, maxWidth: 625)
    }
}

struct TranscriptBindingChoice: Identifiable, Hashable {
    let sourceID: String?
    let file: String?
    let streamIndex: Int
    let label: String

    var id: Self { self }

    func bind(track: TranscriptTrack, offset: RationalTime) -> TranscriptBinding {
        TranscriptBinding(trackID: track.id, sourceID: sourceID, file: file, streamIndex: streamIndex,
                          channel: track.channel, offset: offset)
    }
}

struct TranscriptBindingsForm: View {
    let tracks: [TranscriptTrack]
    let choices: [TranscriptBindingChoice]
    let applyTitle: String
    let apply: ([TranscriptBinding], RationalTime?) async throws -> Void
    @State private var selected: [String: TranscriptBindingChoice]
    /// The stream a track is already bound to when its recording is offline or still opening.
    private let unavailable: [String: TranscriptBindingChoice]
    @State private var offsets: [String: String]
    @State private var origin: String
    @State private var error: String?
    @State private var commitTask: Task<Void, Never>?

    init(tracks: [TranscriptTrack], choices: [TranscriptBindingChoice], bindings: [TranscriptBinding],
         origin: RationalTime?, applyTitle: String,
         apply: @escaping ([TranscriptBinding], RationalTime?) async throws -> Void) {
        self.tracks = tracks
        self.choices = choices
        self.applyTitle = applyTitle
        self.apply = apply
        _origin = State(initialValue: origin?.description ?? "")
        _offsets = State(initialValue: Dictionary(uniqueKeysWithValues: bindings.map { ($0.trackID, $0.offset.description) }))
        var selected: [String: TranscriptBindingChoice] = [:]
        var unavailable: [String: TranscriptBindingChoice] = [:]
        for track in tracks {
            if let existing = bindings.first(where: { $0.trackID == track.id }) {
                selected[track.id] = choices.first {
                    $0.sourceID == existing.sourceID && $0.file == existing.file && $0.streamIndex == existing.streamIndex
                }
                if selected[track.id] == nil {
                    // Applying the sheet must not unbind a track whose recording cannot be listed.
                    let name = existing.sourceID ?? existing.file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Recording"
                    let kept = TranscriptBindingChoice(sourceID: existing.sourceID, file: existing.file,
                                                       streamIndex: existing.streamIndex,
                                                       label: "\(name), stream \(existing.streamIndex) (unavailable)")
                    unavailable[track.id] = kept
                    selected[track.id] = kept
                }
            } else {
                let inferred = choices.filter {
                    (track.sourceID == nil || track.sourceID == $0.sourceID)
                        && (track.streamIndex == nil || track.streamIndex == $0.streamIndex)
                }
                if inferred.count == 1 { selected[track.id] = inferred.first }
            }
        }
        self.unavailable = unavailable
        _selected = State(initialValue: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the project audio stream for each transcript track.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(tracks, id: \.id) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(track.name) {
                                Menu {
                                    bindingOption("Unbound", track: track, choice: nil)
                                    if let kept = unavailable[track.id] {
                                        bindingOption(kept.label, track: track, choice: kept)
                                    }
                                    if !choices.isEmpty { Divider() }
                                    ForEach(choices) { choice in
                                        bindingOption(choice.label, track: track, choice: choice)
                                    }
                                } label: {
                                    Text(selected[track.id]?.label ?? "Unbound")
                                }
                                .accessibilityLabel(track.name)
                                .accessibilityValue(selected[track.id]?.label ?? "Unbound")
                                .accessibilityIdentifier("transcript.binding.stream.\(track.id)")
                            }
                            if selected[track.id] != nil {
                                TextField("Track offset (seconds)", text: Binding(
                                    get: { offsets[track.id, default: "0"] },
                                    set: { offsets[track.id] = $0 }
                                ))
                                .accessibilityIdentifier("transcript.binding.offset.\(track.id)")
                            }
                        }
                    }
                }
                .padding(1)
            }
            .frame(minHeight: 75, idealHeight: min(275, CGFloat(tracks.count) * 58), maxHeight: 275)
            TextField("Cue origin in source time (optional)", text: $origin)
                .accessibilityIdentifier("transcript.binding.origin")
            Text("Leave the cue origin empty if it is unknown. MPCut will mark assumed cue times as approximate.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                IssueLabel(error).accessibilityIdentifier("transcript.binding.error")
            }
            HStack {
                if commitTask != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button(applyTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("transcript.binding.apply")
            }
        }
        .disabled(commitTask != nil)
        .onDisappear { commitTask?.cancel() }
    }

    private func bindingOption(_ title: String, track: TranscriptTrack, choice: TranscriptBindingChoice?) -> some View {
        Button {
            selected[track.id] = choice
        } label: {
            if selected[track.id] == choice {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func commit() {
        guard commitTask == nil else { return }
        error = nil
        do {
            let parsed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
            let bindings = try tracks.compactMap { track -> TranscriptBinding? in
                guard let choice = selected[track.id] else { return nil }
                return choice.bind(track: track, offset: try RationalTime(parsing: offsets[track.id, default: "0"]))
            }
            let parsedOrigin = try parsed.isEmpty ? nil : RationalTime(parsing: parsed)
            commitTask = Task { @MainActor in
                defer { commitTask = nil }
                do { try await apply(bindings, parsedOrigin) }
                catch is CancellationError {}
                catch { self.error = error.localizedDescription }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TranscriptReviewPassage {
    let attachment: String?
    let space: TranscriptSpace
    let range: MulticamRange
    let adjacent: [String]
    let waveform: [Double]
}

struct TranscriptEditReview: View {
    let plan: TranscriptEditPlan
    let passages: [TranscriptReviewPassage]
    let attachmentNames: [String: String]
    let occurrenceLabels: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if plan.action == .queue {
                    readout("Excerpt duration", plan.duration)
                } else {
                    readout("Current duration", plan.previousDuration)
                    readout("Proposed duration", plan.duration)
                    LabeledContent("Export tier") {
                        Text("\(plan.previousTier?.name ?? "Unavailable") → \(plan.tier?.name ?? "Unavailable")")
                    }
                }
                if let requested = plan.requestedRetainedDuration { readout("Requested pause", requested) }
                if let retained = plan.retainedDuration { readout("Achievable pause", retained) }
                ForEach(Array(passages.enumerated()), id: \.offset) { item in
                    let passage = item.element
                    VStack(alignment: .leading, spacing: 4) {
                        Text(passage.attachment ?? "Selected dialogue").font(.headline)
                        LabeledContent(passage.space.label, value: span(passage.range))
                        if !passage.adjacent.isEmpty {
                            Text(passage.adjacent.joined(separator: " · ")).textSelection(.enabled)
                        }
                        if !passage.waveform.isEmpty {
                            TranscriptActivityStrip(levels: passage.waveform)
                                .frame(height: 34)
                            Text("Audio activity").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(Array(plan.boundaries.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        let boundary = item.element
                        Text(boundary.attachmentID.flatMap { attachmentNames[$0] } ?? boundary.space.label)
                            .font(.headline)
                        readout("Requested boundary", boundary.requested)
                        readout("Resolved boundary", boundary.resolved)
                        let alternatives = boundary.copySafeAlternatives.map {
                            timelineTime($0.seconds, milliseconds: true)
                        }.joined(separator: ", ")
                        LabeledContent("Copy-safe alternatives", value: alternatives.isEmpty ? "Unavailable" : alternatives)
                        if boundary.unindexed == true {
                            Label("The recording could not be indexed, so this boundary keeps the requested time.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                if !plan.affectedSpeech.isEmpty {
                    SectionHeading("Speech affected by removal")
                    ForEach(plan.affectedSpeech) { word in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(word.text).textSelection(.enabled)
                                if let label = word.laneLabel, let slot = word.laneColorSlot {
                                    TranscriptLaneChip(label: label, colorSlot: slot)
                                }
                            }
                            Text(["Current Cut " + span(word.range), word.speakerName ?? word.speakerID,
                                  word.attachmentID.flatMap { attachmentNames[$0] },
                                  word.routedStreamIndex.map { "Stream \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.unavailableEvidenceAttachmentIDs.isEmpty {
                    let missing = plan.unavailableEvidenceAttachmentIDs.map { attachmentNames[$0] ?? $0 }
                    Label("Speech evidence unavailable for " + missing.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle").font(.caption)
                }
                if plan.action == .switchAngle {
                    SectionHeading("Current Cut occurrences affected")
                    if occurrenceLabels.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        ForEach(occurrenceLabels, id: \.self) { label in Text(label) }
                    }
                } else if !occurrenceLabels.isEmpty {
                    Text("\(occurrenceLabels.count) affected occurrences").font(.caption)
                }
                if let tier = plan.tier {
                    ForEach(tier.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                }
            }
            .padding(2)
        }
        .frame(minHeight: 125, idealHeight: 310, maxHeight: 420)
    }

    private func span(_ range: MulticamRange) -> String {
        timelineTime(range.from.seconds, milliseconds: true) + "–" + timelineTime(range.to.seconds, milliseconds: true)
    }

    private func readout(_ title: String, _ time: RationalTime) -> some View {
        LabeledContent(title) { Text(timelineTime(time.seconds, milliseconds: true)).monospacedDigit() }
    }
}

private struct TranscriptActivityStrip: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let unit = size.width / CGFloat(max(1, levels.count))
            let peak = max(levels.max() ?? 0, 0.001)
            var path = Path()
            for (index, level) in levels.enumerated() {
                let height = max(1, size.height * CGFloat(level / peak))
                let bar = CGRect(x: CGFloat(index) * unit, y: (size.height - height) / 2,
                                 width: max(0.5, unit - 0.5), height: height)
                path.addRect(bar)
            }
            context.fill(path, with: .color(.accentColor))
        }
        .accessibilityLabel("Recorded audio activity")
    }
}

struct TranscriptAngleChoice: Identifiable {
    let id: String
    let label: String
}

struct TranscriptEditOptionsForm: View {
    let action: TranscriptEditRequest.Action
    let queueName: String
    var startAngles: [TranscriptAngleChoice] = []
    var endAngles: [TranscriptAngleChoice] = []
    let commit: (String, RationalTime?, RationalTime?, RationalTime?, Int?, Int?, TranscriptEditRequest.BoundaryPolicy,
                 TranscriptEditRequest.Edge, TranscriptWordSelection.Kind, String?) async throws -> Void
    @State private var name = ""
    @State private var leading = ""
    @State private var trailing = ""
    @State private var retained = "0.20"
    @State private var startNudge = ""
    @State private var endNudge = ""
    @State private var reviewTask: Task<Void, Never>?
    @State private var boundary = TranscriptEditRequest.BoundaryPolicy.nearestFrame
    @State private var edge = TranscriptEditRequest.Edge.start
    @State private var angleID: String?
    @State private var kind = TranscriptWordSelection.Kind.phrase
    @State private var error: String?

    private var angles: [TranscriptAngleChoice] { edge == .start ? startAngles : endAngles }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if action == .queue {
                TextField("Excerpt name", text: $name)
                    .accessibilityIdentifier("transcript.queue.name")
                    .onAppear { if name.isEmpty { name = queueName } }
            }
            if action == .tighten {
                TextField("Pause to keep (seconds)", text: $retained)
                    .accessibilityIdentifier("transcript.pause.retained")
            } else if [.split, .switchAngle, .trimStart, .trimEnd].contains(action) {
                Picker("Word edge", selection: $edge) {
                    Text("Start of selection").tag(TranscriptEditRequest.Edge.start)
                    Text("End of selection").tag(TranscriptEditRequest.Edge.end)
                }
            } else {
                HStack {
                    TextField("Leading padding (seconds)", text: $leading)
                    TextField("Trailing padding (seconds)", text: $trailing)
                }
            }
            if action == .switchAngle {
                if angles.isEmpty {
                    Text("No camera has picture at this word edge.").foregroundStyle(.secondary)
                } else {
                    Picker("Camera and source time", selection: $angleID) {
                        Text("Choose a camera").tag(nil as String?)
                        ForEach(angles) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    .accessibilityIdentifier("transcript.switchAngle.camera")
                }
            }
            HStack {
                if ![.split, .switchAngle, .trimStart, .trimEnd].contains(action) || edge == .start {
                    TextField("Start nudge (frames)", text: $startNudge)
                        .accessibilityIdentifier("transcript.frameNudge.start")
                }
                if ![.split, .switchAngle, .trimStart, .trimEnd].contains(action) || edge == .end {
                    TextField("End nudge (frames)", text: $endNudge)
                        .accessibilityIdentifier("transcript.frameNudge.end")
                }
            }
            if action == .delete {
                Picker("Selection", selection: $kind) {
                    Text("Words and internal pauses").tag(TranscriptWordSelection.Kind.phrase)
                    Text("Gap between the selected words").tag(TranscriptWordSelection.Kind.gap)
                }
            }
            TranscriptBoundaryMenu(policy: $boundary)
            if let error { IssueLabel(error) }
            HStack {
                Spacer()
                if reviewTask != nil { ProgressView().controlSize(.small) }
                Button("Review Edit") {
                    reviewTask = Task {
                        defer { reviewTask = nil }
                        do {
                            func time(_ text: String) throws -> RationalTime? {
                                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                return try value.isEmpty ? nil : RationalTime(parsing: value)
                            }
                            func nudge(_ text: String) throws -> Int? {
                                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if value.isEmpty { return nil }
                                guard let frames = Int(value) else {
                                    throw CutError(code: "invalid_frame_nudge", message: "Enter whole numbers in the frame nudge fields.")
                                }
                                return frames
                            }
                            let edgeOnly = [.split, .switchAngle, .trimStart, .trimEnd].contains(action)
                            let start = !edgeOnly || edge == .start ? try nudge(startNudge) : nil
                            let end = !edgeOnly || edge == .end ? try nudge(endNudge) : nil
                            try await commit(name, time(leading), time(trailing), action == .tighten ? time(retained) : nil, start, end,
                                             boundary, edge, action == .tighten ? .gap : kind, angleID)
                        } catch is CancellationError {
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .accessibilityIdentifier("transcript.reviewEdit")
                .keyboardShortcut(.defaultAction)
                .disabled(reviewTask != nil
                          || (action == .queue && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                          || (action == .switchAngle && !angles.contains { $0.id == angleID }))
            }
        }
        .onAppear { if action == .trimEnd { edge = .end } }
        .onChange(of: edge) { _, _ in
            if !angles.contains(where: { $0.id == angleID }) { angleID = nil }
        }
        .onDisappear { reviewTask?.cancel() }
    }
}

struct TranscriptTextForm: View {
    let label: String
    let commit: (String) throws -> Void
    @State private var value: String
    @State private var error: String?

    init(label: String, initial: String, commit: @escaping (String) throws -> Void) {
        self.label = label
        self.commit = commit
        _value = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(label, text: $value, axis: .vertical)
                .lineLimit(1...5)
                .accessibilityIdentifier("transcript.correction.text")
            if let error { IssueLabel(error) }
            HStack {
                Spacer()
                Button("Save") {
                    do { try commit(value) } catch { self.error = error.localizedDescription }
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("transcript.correction.save")
            }
        }
    }
}

struct TranscriptExportForm: View {
    let isMulticam: Bool
    let tracks: [TranscriptTrack]
    let export: (TranscriptFormat, TranscriptSpace, String?) -> Void
    @State private var trackID: String?
    let captions: Bool
    let privacyWarning: String?
    @State private var format: TranscriptFormat
    @State private var space: TranscriptSpace

    init(space: TranscriptSpace, isMulticam: Bool, captions: Bool, tracks: [TranscriptTrack], privacyWarning: String?,
         export: @escaping (TranscriptFormat, TranscriptSpace, String?) -> Void) {
        self.isMulticam = isMulticam
        self.privacyWarning = privacyWarning
        self.captions = captions
        self.tracks = tracks
        _trackID = State(initialValue: tracks.first?.id)
        _format = State(initialValue: captions ? .srt : .json)
        self.export = export
        _space = State(initialValue: space)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let privacyWarning {
                Label(privacyWarning, systemImage: "exclamationmark.triangle")
            }
            Picker("Clock", selection: $space) {
                ForEach(TranscriptSpace.allCases.filter { isMulticam || $0 != .group }, id: \.self) { clock in
                    Text(clock.label).tag(clock)
                }
            }
            if captions {
                if space == .source && tracks.count > 1 {
                    Picker("Recording track", selection: $trackID) {
                        ForEach(tracks, id: \.id) { track in Text(track.name).tag(Optional(track.id)) }
                    }
                }
                Text("SubRip (.srt) for DaVinci Resolve, Final Cut Pro, and Premiere Pro.")
                Text("Use Current Cut for the edited video or Source for the original recording.")
                    .font(.caption)
            } else {
                Picker("Format", selection: $format) {
                    Text("Native JSON").tag(TranscriptFormat.json)
                    Text("Readable text").tag(TranscriptFormat.text)
                    Text("SubRip (.srt)").tag(TranscriptFormat.srt)
                    Text("WebVTT (.vtt)").tag(TranscriptFormat.vtt)
                }
            }
            HStack {
                Spacer()
                Button("Choose Destination…") { export(format, space, captions && space == .source && tracks.count > 1 ? trackID : nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct TranscriptAuditionTransport: View {
    @ObservedObject var preview: SequencePreview
    let sourceStart: Double
    let sourceEnd: Double

    var body: some View {
        HStack {
            Button(preview.isPlaying ? "Pause" : "Play", systemImage: preview.isPlaying ? "pause.fill" : "play.fill") {
                preview.togglePlayback()
            }
            let position = timelineTime(sourceStart + preview.time, milliseconds: true)
            let end = timelineTime(sourceEnd, milliseconds: true)
            Text("\(position) / \(end)").monospacedDigit().accessibilityLabel("Source time \(position), end \(end)")
            Spacer()
        }
    }
}

func transcriptAuditionRange(media: MediaInfo, presentation: MulticamRange, streamIndex: Int,
                             clockOffset: RationalTime, indexedInPresentationClock: Bool,
                             includeLead: Bool) throws -> PreviewRange {
    let duration = indexedInPresentationClock ? media.duration : try media.duration.adding(clockOffset)
    let audio = media.streams.filter { $0.kind == "audio" }
    guard let ordinal = audio.firstIndex(where: { $0.index == streamIndex }),
          presentation.from >= .zero, presentation.from < duration else {
        throw CutError(code: "unresolved_transcript_location", message: "The word lies outside its source audio.")
    }
    let from = includeLead ? max(.zero, try presentation.from.subtracting(.init(numerator: 3, denominator: 4))) : presentation.from
    let to = min(duration, try presentation.to.adding(.init(numerator: 5, denominator: 4)))
    guard from < to else {
        throw CutError(code: "unresolved_transcript_location", message: "The passage lies outside its source audio.")
    }
    let needsPresentationAudio = clockOffset > .zero && (from < clockOffset || !media.hasVideo)
    let adjustment = needsPresentationAudio ? RationalTime.zero : clockOffset
    var clip = try PreviewRange(media: media, from: from.subtracting(adjustment), to: to.subtracting(adjustment))
    if needsPresentationAudio {
        clip.isAudioOnly = true
        clip.assetClockOrigin = .zero
        clip.audioOrigin = .zero
    }
    clip.audioTrack = ordinal
    return clip
}

@MainActor
final class TranscriptAuditionPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var preview: SequencePreview?
    private var content: NSHostingController<TranscriptSourceAudition>?
    private var startup: Task<Void, Never>?
    private var retarget: Task<Void, Never>?

    func show(_ clip: PreviewRange, streamIndex: Int, parent: NSWindow?, autoplay: Bool, clockOffset: RationalTime) {
        let sourceStart = clip.start + (clip.assetClockOrigin == nil ? clockOffset.seconds : 0)
        let title = "Source Context · \(clip.url.lastPathComponent) · Stream \(streamIndex)"
        startup?.cancel()
        startup = nil
        retarget?.cancel()
        retarget = nil
        // Stepping through Source words asks for a passage at key-repeat rate. The open panel
        // and its player move to it. Closing and rebuilding both for every word holds up the reader.
        if let panel, let preview, let content, content.rootView.clip.isAudioOnly == clip.isAudioOnly, panel.parent === parent {
            panel.title = title
            let move = {
                preview.update([clip], at: 0)
                content.rootView = TranscriptSourceAudition(clip: clip, preview: preview, sourceStart: sourceStart)
            }
            if autoplay {
                move()
                play(preview)
            } else {
                preview.pause()
                // Only the passage the selection rests on is opened.
                retarget = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                    move()
                    self?.retarget = nil
                }
            }
            return
        }
        close()
        let preview = SequencePreview()
        preview.update([clip], at: 0)
        self.preview = preview
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: clip.isAudioOnly ? 65 : 340),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = title
        panel.delegate = self
        let content = NSHostingController(rootView: TranscriptSourceAudition(clip: clip, preview: preview,
                                                                             sourceStart: sourceStart))
        panel.contentViewController = content
        self.content = content
        self.panel = panel
        if let parent {
            let frame = parent.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - 45))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        panel.orderFront(nil)
        if autoplay { play(preview) }
    }

    private func play(_ preview: SequencePreview) {
        startup = Task { [weak preview] in
            let deadline = ContinuousClock.now + .seconds(5)
            while let preview, preview.issue == nil, !Task.isCancelled {
                if preview.readyForTransport {
                    if !preview.isPlaying && preview.time == 0 { preview.togglePlayback() }
                    return
                }
                guard ContinuousClock.now < deadline else { return }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    func close() {
        retarget?.cancel()
        retarget = nil
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel, closing === panel else { return }
        startup?.cancel()
        startup = nil
        retarget?.cancel()
        retarget = nil
        preview?.update([], at: 0)
        preview = nil
        closing.parent?.removeChildWindow(closing)
        closing.contentViewController = nil
        content = nil
        panel = nil
    }
}

private struct TranscriptSourceAudition: View {
    let clip: PreviewRange
    @ObservedObject var preview: SequencePreview
    let sourceStart: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !clip.isAudioOnly {
                PreviewView(preview: preview)
                    .frame(width: 480, height: 270)
                    .background(.black)
            }
            TranscriptAuditionTransport(preview: preview, sourceStart: sourceStart,
                                        sourceEnd: sourceStart + clip.end - clip.start)
            if let issue = preview.issue {
                Text(issue).foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(10)
    }
}

struct TranscriptBoundaryMenu: View {
    @Binding var policy: TranscriptEditRequest.BoundaryPolicy

    var body: some View {
        LabeledContent("Boundary policy") {
            Menu {
                option(.nearestFrame)
                option(.copySafe)
                option(.exact)
            } label: {
                Text(title(policy))
            }
            .accessibilityLabel("Boundary policy")
            .accessibilityValue(title(policy))
            .accessibilityIdentifier("transcript.boundaryPolicy")
        }
    }

    private func option(_ choice: TranscriptEditRequest.BoundaryPolicy) -> some View {
        Button {
            policy = choice
        } label: {
            if policy == choice { Label(title(choice), systemImage: "checkmark") }
            else { Text(title(choice)) }
        }
    }

    private func title(_ choice: TranscriptEditRequest.BoundaryPolicy) -> String {
        switch choice {
        case .nearestFrame: "Nearest media frame"
        case .copySafe: "Copy-safe boundary"
        case .exact: "Exact requested time"
        }
    }
}
