import MPCutCore
import SwiftUI

struct MulticamPauseControls: View {
    @ObservedObject private var model: MulticamEditorModel
    @ObservedObject private var edits: MulticamPauseEdits
    @Environment(\.dismiss) private var dismiss

    init(model: MulticamEditorModel) {
        self.model = model
        edits = model.pauseEdits
    }

    var body: some View {
        let pauses = model.multicamPausePlan
        let cuts = pauses.compactMap(\.removal)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Detection")
            MulticamProgramMicrophone(model: model, preview: model.preview)
            Toggle("Manual threshold for all routed tracks", isOn: Binding(
                get: { model.analysis.pauseThreshold != nil },
                set: { model.configureSilenceAnalysis(minimum: model.analysis.pauseMinimum, threshold: $0 ? -45 : nil) }
            ))
                .help("Use one manual threshold")
            if let threshold = model.analysis.pauseThreshold {
                PauseSetting(label: "Quiet below", unit: "dBFS", value: Binding(
                    get: { model.analysis.pauseThreshold ?? threshold },
                    set: { model.configureSilenceAnalysis(minimum: model.analysis.pauseMinimum, threshold: $0) }
                ), minimum: -120, maximum: 0, step: 1)
            }
            PauseSetting(label: "Minimum pause", unit: "s", value: Binding(
                get: { model.analysis.pauseMinimum },
                set: { model.configureSilenceAnalysis(minimum: $0, threshold: model.analysis.pauseThreshold) }
            ), minimum: 1.0 / Double(AudioWaveform.rate), step: 0.1)
            PauseSetting(label: "Leave per pause", unit: "s", value: Binding(
                get: { model.preferences.leavePause }, set: { model.preferences.leavePause = $0 }
            ), minimum: 0, step: 0.1)
            Button("Use Marked Room Tone") { model.useRoomTone() }
                .disabled(!model.canUseRoomTone)
                .help("Measure marked room tone")
            Divider().padding(.vertical, 2)
            SectionHeading("Pauses")
            if let progress = model.analysis.silenceProgress {
                ProgressView(value: progress) {
                    Text("Scanning program audio… \(progressPercent(progress))").font(.callout).monospacedDigit()
                }
                Button("Cancel Scan") { model.cancelAnalysis(.silence) }
                    .help("Cancel silence scan")
            } else {
                let issue = model.analysis.silenceIssue
                if let issue { IssueLabel(issue) }
                if model.canApplyPauses {
                    Text(summary(pauses: pauses, cuts: cuts)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if issue == nil, !model.analysis.unindexedSilenceSources.isEmpty {
                    if let issue = model.analysis.unindexedSilenceSources.sorted()
                        .compactMap({ model.sourceIssues[$0] ?? model.sourceIndexIssues[$0] }).first {
                        IssueLabel(issue)
                    } else {
                        Text("Indexing the selected audio tracks…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if issue == nil, model.analysis.hasMissingSilenceTrack {
                    IssueLabel("A selected microphone stream is unavailable. Check Sources or Switch.")
                } else if issue == nil, model.analysis.silenceTrackCount == 0 {
                    Text("Choose a microphone in Sources or Switch to scan for pauses.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.canScanAnalysis(.silence) {
                    Button(issue == nil ? "Scan for Silence" : "Retry Silence Scan") {
                        model.scanAnalysis(.silence)
                    }
                    .help(issue == nil ? "Find silent sections" : "Retry silence scan")
                } else if model.canApplyPauses {
                    Button("Rescan Silence") { model.analysis.rescanSilence() }
                        .help("Run a fresh silence scan")
                }
            }
            MulticamPauseNavigation(model: model, preview: model.preview, pauses: pauses) { pause in
                dismiss()
                Task { @MainActor in
                    await Task.yield()
                    model.reviewMulticamPause(pause)
                }
            }
            Toggle("Skip pauses during playback", isOn: $edits.skip)
                .disabled(!edits.skip && !(model.assemblyPreview ? pauses : model.multicamPausePlan(forPlayback: true))
                    .contains { $0.removal != nil })
                    .help("Skip pauses in preview")
            Divider().padding(.vertical, 2)
            HStack {
                Button("Queue Takes") {
                    if model.applyMulticamPauses(queueTakes: true, plan: pauses) { dismiss() }
                }
                .help("Queue audible takes")
                Spacer()
                Button("Shorten Pauses") {
                    if model.applyMulticamPauses(queueTakes: false, plan: pauses) { dismiss() }
                }
                    .buttonStyle(.borderedProminent)
                    .help("Shorten assembly pauses")
            }.disabled(cuts.isEmpty)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func summary(pauses: [MulticamPauseEdit], cuts: [AudioSpan]) -> String {
        let scope = model.markedGroupSpan != nil || model.assemblySelection != nil ? "marked range" : "assembly"
        if pauses.isEmpty { return "No qualifying pauses in the \(scope)." }
        let seconds = cuts.reduce(0) { $0 + $1.to.seconds - $1.from.seconds }
        return "\(cuts.count) of \(pauses.count) pauses · \(seconds.formatted(.number.precision(.fractionLength(1)))) s shorter"
    }
}

private struct MulticamProgramMicrophone: View {
    let model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview

    var body: some View {
        if let project = model.project {
            let track = model.analysis.programMicrophone(at: model.groupTime(at: preview.time), project: project,
                                                         exclusiveEnd: preview.time == preview.duration)
            let count = model.analysis.silenceTrackCount
            Text("Program microphone: \(track)")
                .font(.callout).lineLimit(2).help(track)
            if count > 1 {
                Text("Scans \(count) routed tracks across the group.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MulticamPauseNavigation: View {
    let model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview
    let pauses: [MulticamPauseEdit]
    let openReview: (MulticamPauseEdit) -> Void

    var body: some View {
        let index = model.occurrenceIndex(at: preview.time)
        let group = model.groupTime(at: preview.time)
        let current = pauses.first { $0.id.occurrence == index && $0.visible.from <= group && group < $0.visible.to }
        HStack(spacing: 8) {
            ControlGroup {
                Button("Previous", systemImage: "chevron.left") { step(-1, occurrence: index, group: group) }
                    .help("Jump to previous pause")
                Button("Next", systemImage: "chevron.right") { step(1, occurrence: index, group: group) }
                    .help("Jump to next pause")
            }
            .fixedSize()
            Button("Preview Cut") {
                if let current { openReview(current) }
            }.disabled(current?.removal == nil)
                .help("Preview shortened pause")
            Spacer(minLength: 0)
            keepButton(current)
        }.disabled(pauses.isEmpty)
    }

    private func keepButton(_ current: MulticamPauseEdit?) -> some View {
        Button(current?.isProtected == true ? "Shorten This Pause" : "Keep This Pause") {
            guard let current else { return }
            model.setPauseProtection(!current.isProtected, for: current)
        }.disabled(current == nil)
            .help(current?.isProtected == true ? "Shorten selected pause" : "Protect selected pause")
    }

    private func step(_ direction: Int, occurrence: Int, group: RationalTime) {
        let next: MulticamPauseEdit?
        if direction > 0 {
            next = pauses.first { $0.id.occurrence > occurrence
                || ($0.id.occurrence == occurrence && $0.visible.from > group) } ?? pauses.first
        } else {
            next = pauses.last { $0.id.occurrence < occurrence
                || ($0.id.occurrence == occurrence && $0.visible.from < group) } ?? pauses.last
        }
        guard let next else { return }
        model.seekMulticamPause(next)
    }
}

struct MulticamPausePlayback: ViewModifier {
    @ObservedObject private var model: MulticamEditorModel
    @ObservedObject private var edits: MulticamPauseEdits

    init(model: MulticamEditorModel) {
        self.model = model
        edits = model.pauseEdits
    }

    func body(content: Content) -> some View {
        let plan = edits.skip ? model.multicamPausePlan(forPlayback: true) : []
        content
            .onReceive(model.preview.$time) { _ in
                guard !plan.isEmpty else { return }
                Task { @MainActor in
                    model.skipMulticamPause(plan)
                }
            }
            .sheet(isPresented: Binding(get: { edits.review != nil }, set: { if !$0 { edits.review = nil } })) {
                if let review = edits.review { MulticamCutReview(model: model, review: review) }
            }
    }
}

private struct MulticamCutReview: View {
    let model: MulticamEditorModel
    let review: MulticamPauseEdits.Review
    @StateObject private var preview = MulticamPreview()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditorSheet(title: "Preview Cut", message: "Listen to the cut with the shorter pause.") {
            MulticamPreviewView(preview: preview).frame(width: 480, height: 270).background(.black)
                .modifier(InsetPanel())
            if let message = preview.issue { IssueLabel(message) }
        } actions: {
            CutPreviewPlayButton(isPlaying: preview.isPlaying, toggle: preview.togglePlayback)
            Button("Keep This Pause") {
                model.pauseEdits.protected.insert(review.pause)
                dismiss()
            }
            .help("Keep pause at full length")
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                .help("Close pause preview")
        }
        .onAppear {
            preview.volume = model.preview.volume
            preview.isMuted = model.preview.isMuted
            preview.configure(plan: review.plan, media: model.media)
            preview.togglePlayback()
        }
        .onDisappear { preview.reset() }
    }
}
