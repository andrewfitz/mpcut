import MPCutCore
import SwiftUI

struct PauseControls: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var openPreviewOnDismiss = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Detection")
            if editor.playheadAudioTracks.count > 1 {
                InspectorRow("Analyze track", labelWidth: 96) {
                    Picker("Analyze track", selection: Binding<Int?>(
                        get: { editor.audioMonitoringTrack },
                        set: { track in
                            if let track { editor.chooseAnalysisTrack(track) }
                            else { editor.monitorSourceAudio() }
                        }
                    )) {
                        Text("Follow Source Audio").tag(nil as Int?)
                        ForEach(Array(editor.playheadAudioTracks.enumerated()), id: \.offset) { index, stream in
                            Text("Track \(index + 1) · \(stream.audioFormatLabel)").tag(Optional(index))
                        }
                    }
                    .help("Choose track to analyze")
                }
            }
            if let note = editor.audioTrackFallbackNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let source = editor.pauseSourceLabel {
                Text(source).font(.callout).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(source)
            }
            HStack {
                Toggle("Automatic threshold", isOn: Binding(
                    get: { editor.manualThresholdDB == nil },
                    set: { automatic in editor.manualThresholdDB = automatic ? nil : editor.effectiveThresholdDB }
                ))
                .disabled(editor.effectiveThresholdDB == nil)
                .help("Estimate silence threshold")
                if editor.manualThresholdDB == nil {
                    Spacer()
                    if let level = editor.effectiveThresholdDB {
                        Text("\(level.formatted(.number.precision(.fractionLength(0...1)))) dBFS").monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Quiet below \(level) dBFS")
                    }
                }
            }
            if let manual = editor.manualThresholdDB {
                PauseSetting(label: "Quiet below", unit: "dBFS",
                             value: Binding(get: { editor.manualThresholdDB ?? manual }, set: { editor.manualThresholdDB = $0 }),
                             minimum: -120, maximum: 0, step: 1)
            }
            PauseSetting(label: "Minimum pause", unit: "s", value: $editor.minimumPause,
                         minimum: 1.0 / Double(AudioWaveform.rate), step: 0.1)
            PauseSetting(label: "Leave per pause", unit: "s", value: $editor.leavePause, minimum: 0, step: 0.1)
            Button("Use Marked Room Tone") { editor.useRoomTone() }
                .disabled(!editor.canUseRoomTone)
                .help("Measure marked room tone")
            Divider().padding(.vertical, 2)
            SectionHeading("Pauses")
            if let progress = editor.silenceProgress {
                ProgressView(value: progress) {
                    Text("Finding silence… \(progressPercent(progress))").font(.callout).monospacedDigit()
                }
                Button("Cancel Scan", action: editor.cancelSilenceScan)
                    .help("Cancel silence scan")
            } else if let issue = editor.silenceIssue {
                IssueLabel(issue)
                Button("Retry Silence Scan", action: editor.scanForSilence).disabled(!editor.canScanSilence)
                    .help("Retry silence scan")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    if editor.pauseAnalysisReady {
                        Text(summary).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(editor.pauseAnalysisReady ? "Rescan" : "Scan for Silence", action: editor.scanForSilence)
                        .disabled(!editor.canScanSilence)
                        .accessibilityLabel(editor.pauseAnalysisReady ? "Rescan Silence" : "Scan for Silence")
                        .help("Find silent sections")
                }
            }
            HStack(spacing: 8) {
                ControlGroup {
                    Button("Previous", systemImage: "chevron.left") { editor.stepPause(-1) }
                        .help("Previous pause (⌃⌥←)")
                    Button("Next", systemImage: "chevron.right") { editor.stepPause(1) }
                        .help("Next pause (⌃⌥→)")
                }
                .fixedSize()
                Button("Preview Cut") {
                    openPreviewOnDismiss = true
                    dismiss()
                }
                    .disabled(!editor.canPreviewCurrentCut)
                    .help("Preview shortened pause")
                Spacer(minLength: 0)
                Button(editor.currentPause?.isProtected == true ? "Shorten This Pause" : "Keep This Pause",
                       action: editor.protectCurrentPause)
                    .disabled(editor.currentPause == nil)
                    .help(editor.currentPause?.isProtected == true ? "Shorten selected pause" : "Protect selected pause")
            }.disabled(!editor.pauseAnalysisReady || editor.pausePlan.isEmpty)
            Toggle("Skip pauses during playback", isOn: $editor.skipPauses)
                .disabled(!editor.pauseAnalysisReady || editor.pausePlan.isEmpty)
                .help("Skip pauses in preview")
            Divider().padding(.vertical, 2)
            HStack {
                Button("Queue Takes") { editor.applyPauses(queueTakes: true); dismiss() }
                    .help("Queue audible takes")
                Spacer()
                Button("Shorten Pauses") { editor.byHand { _ = editor.applyPauses(queueTakes: false) }; dismiss() }
                    .buttonStyle(.borderedProminent)
                    .help("Shorten timeline pauses")
            }.disabled(!editor.pauseAnalysisReady || editor.shortenedPauseCount == 0)
        }
        .padding(16)
        .frame(width: 360)
        .onDisappear {
            guard openPreviewOnDismiss else { return }
            Task { @MainActor in
                await Task.yield()
                editor.previewCurrentCut()
            }
        }
    }

    private var summary: String {
        let scope = editor.hasPauseMarks ? "marked range" : "timeline"
        if editor.pausePlan.isEmpty { return "No qualifying pauses in the \(scope)." }
        return "\(editor.shortenedPauseCount) of \(editor.pausePlan.count) pauses · \(String(format: "%.1f", editor.removedPauseSeconds)) s shorter (\(scope))"
    }
}

struct PauseSetting: View {
    let label: String
    let unit: String
    @Binding var value: Double
    let minimum: Double
    var maximum = Double.greatestFiniteMagnitude
    let step: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            Spacer()
            TextField(label, value: Binding(get: { value }, set: setValue),
                      format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
                .accessibilityLabel("\(label) in \(unit)")
                .help("Enter \(label.lowercased())")
            Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Stepper(label, onIncrement: { setValue(value + step) }, onDecrement: { setValue(value - step) })
                .labelsHidden()
                .help("Adjust \(label.lowercased())")
        }
    }

    private func setValue(_ newValue: Double) {
        guard newValue.isFinite else { return }
        // The field and stepper use the same hundredth-second precision.
        let scaled = newValue * 100
        let rounded = scaled.isFinite ? scaled.rounded() / 100 : newValue
        value = min(max(rounded, minimum), maximum)
    }
}

struct CutPreviewSheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var preview = SequencePreview()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditorSheet(title: "Preview Cut", message: "Listen to the cut with the shorter pause.") {
            Group {
                if let ranges = editor.cutPreview?.ranges, !ranges.isEmpty, ranges.allSatisfy(\.isAudioOnly) {
                    CutWaveformPreview(editor: editor, ranges: ranges, playhead: preview.time)
                        .frame(width: 480, height: 150)
                        .accessibilityLabel("Audio cut preview")
                } else {
                    PreviewView(preview: preview).frame(width: 480, height: 270).background(.black)
                }
            }
            .modifier(InsetPanel())
            if let message = preview.issue ?? preview.audioWarning { IssueLabel(message) }
        } actions: {
            CutPreviewPlayButton(isPlaying: preview.isPlaying, toggle: preview.togglePlayback)
            Button("Keep This Pause") { editor.advanceCutPreview(keepingCurrent: true) }
                .help("Keep pause and advance")
            Button("Next Cut") { editor.advanceCutPreview(keepingCurrent: false) }
                .disabled(editor.shortenedPauseCount < 2)
                .help("Preview next cut")
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                .help("Close cut preview")
        }
        .task(id: editor.cutPreview?.position) {
            guard let cut = editor.cutPreview else { return }
            preview.volume = editor.preview.volume
            preview.isMuted = editor.preview.isMuted
            preview.update(cut.ranges, at: 0)
            while !Task.isCancelled && preview.issue == nil && !preview.isPlaying {
                preview.togglePlayback()
                if !preview.isPlaying { try? await Task.sleep(for: .milliseconds(40)) }
            }
        }
        .onDisappear { preview.update([], at: 0) }
    }
}

/// The title changes with playback, so the button keeps one width.
struct CutPreviewPlayButton: View {
    let isPlaying: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                .frame(minWidth: 58)
        }
        .accessibilityLabel(isPlaying ? "Pause" : "Play Preview")
        .help(isPlaying ? "Pause cut preview" : "Play cut preview")
    }
}
