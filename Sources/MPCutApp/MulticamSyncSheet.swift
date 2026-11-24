import MPCutCore
import SwiftUI

extension MulticamEditorModel {
    func replacementSyncSuggestions(for project: MulticamProject, query: MulticamSync.ReplacementRequest,
                                    incoming: MediaInfo) async throws -> MulticamSync.Report {
        let location = projectURL
        var indexed = media
        indexed[query.source.id] = incoming
        let snapshot = indexed
        let useSidecar = useAnalysisSidecars
        let scratch = query.referenceStream.flatMap {
            analysis.completedWaveform(sourceID: query.referenceSourceID, stream: $0)
        }
        let protected = AnalysisSidecar.excludedSources.union(sidecarExclusions).union([incoming.url])
        let task = sidecarWork.detached(priority: .userInitiated) {
            try AnalysisSidecar.$excludedSources.withValue(protected) {
                try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                    try MulticamSync.analyzeReplacement(project, request: query, relativeTo: location,
                                                        indexed: snapshot, useSidecar: useSidecar,
                                                        cachedReferenceWaveform: scratch)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func syncSuggestions(for project: MulticamProject, sourceID: String? = nil,
                         referenceSourceID: String? = nil, waveform: Bool) async throws -> MulticamSync.Report {
        let location = projectURL
        let indexed = media
        let useSidecar = useAnalysisSidecars
        let protected = AnalysisSidecar.excludedSources.union(sidecarExclusions)
        let task = sidecarWork.detached(priority: .userInitiated) {
            try AnalysisSidecar.$excludedSources.withValue(protected) {
                try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                    try MulticamSync.analyze(project, relativeTo: location, indexed: indexed, sourceID: sourceID,
                                             referenceSourceID: referenceSourceID,
                                             waveform: waveform, useSidecar: useSidecar)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct MulticamSyncSheet: View {
    @ObservedObject var model: MulticamEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var waveform = false
    @State private var referenceSourceID: String?
    @State private var running = false
    @State private var request = 0
    @State private var report: MulticamSync.Report?
    @State private var reportRevision: Int?
    @State private var reportGeneration: UUID?
    @State private var reportMediaRevision: UInt64?
    @State private var failure: String?

    var body: some View {
        let reference = model.project?.angles.first(where: { $0.id == model.project?.referenceAngle })
        let recordingID = reference?.recordings.first(where: { $0.id == referenceSourceID })?.id ?? reference?.id
        return EditorSheet(title: "Sync Suggestions",
                           message: reference.map { "Offsets are measured against the reference camera, \($0.displayName)." }
                               ?? "Offsets are measured against the reference camera.") {
            if let reference, reference.recordings.count > 1 {
                InspectorRow("Reference", labelWidth: 88) {
                    Picker("Reference Recording", selection: Binding(
                        get: { recordingID ?? reference.id },
                        set: { referenceSourceID = $0 }
                    )) {
                        ForEach(reference.recordings) { recording in
                            Text(recording.displayName).tag(recording.id)
                        }
                    }
                }
                .disabled(running || model.isBusy)
            }
            HStack(spacing: 10) {
                Toggle("Compare audio waveforms and check drift", isOn: $waveform)
                    .help("Also match the recordings by their sound")
                Spacer(minLength: 0)
                if running { ProgressView().controlSize(.small) }
                Button("Analyze") {
                    report = nil
                    failure = nil
                    running = true
                    request += 1
                }
                .help("Compare the recordings' clocks")
            }
            .disabled(running || model.project == nil || model.isBusy)
            if let failure { IssueLabel(failure) }
            if let report {
                if reportIsStale {
                    IssueLabel("The project or its media changed. Analyze again before applying an offset.")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if report.suggestions.contains(where: { $0.metadataOffset != nil }) {
                            Text("Compare metadata from recordings that shared a clock.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(report.suggestions, id: \.sourceID) { suggestion in
                            row(suggestion)
                            if suggestion.sourceID != report.suggestions.last?.sourceID { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(height: 220)
                .modifier(InsetPanel())
            }
        } actions: {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 560)
        .onChange(of: recordingID) { _, _ in
            report = nil
            failure = nil
        }
        .task(id: request) {
            guard request > 0 else { return }
            defer { running = false }
            guard let project = model.project else { return }
            let revision = model.mcpRevision
            let generation = model.mcpGeneration
            let mediaRevision = model.transcriptMediaRevision
            do {
                let result = try await model.syncSuggestions(for: project, referenceSourceID: recordingID,
                                                             waveform: waveform)
                try Task.checkCancellation()
                report = result
                reportRevision = revision
                reportGeneration = generation
                reportMediaRevision = mediaRevision
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    failure = (error as? CutError)?.message ?? error.localizedDescription
                }
            }
        }
    }

    private var reportIsStale: Bool {
        reportRevision != model.mcpRevision || reportGeneration != model.mcpGeneration ||
            reportMediaRevision != model.transcriptMediaRevision
    }

    private func row(_ suggestion: MulticamSync.Suggestion) -> some View {
        let source = model.project?.sources.first(where: { $0.id == suggestion.sourceID })?.displayName ?? suggestion.sourceID
        return VStack(alignment: .leading, spacing: 4) {
            Text(source)
                .font(.callout.weight(.semibold))
            Text("Current offset: \(suggestion.currentOffset.description) s")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let offset = suggestion.metadataOffset {
                proposal(suggestion, source: source, offset: offset,
                         label: suggestion.stamp?.kind == .broadcastWave ? "Broadcast Wave" : "Timecode")
            }
            if let issue = suggestion.metadataIssue {
                Text(issue).foregroundStyle(.secondary)
            }
            if let offset = suggestion.waveformOffset {
                proposal(suggestion, source: source, offset: offset, label: "Waveform")
                if let drift = suggestion.drift {
                    let first = suggestion.matches.first?.referenceTime.description ?? ""
                    let last = suggestion.matches.last?.referenceTime.description ?? ""
                    Text("Offset change: \(drift.description) s from \(first) s to \(last) s on the reference clock.")
                } else {
                    Text("Drift unavailable. Two matches at least 30 s apart are needed.")
                        .foregroundStyle(.secondary)
                }
            } else if let issue = suggestion.waveformIssue {
                Text(issue).foregroundStyle(.secondary)
            }
        }
    }

    private func proposal(_ suggestion: MulticamSync.Suggestion, source: String, offset: RationalTime,
                          label: String) -> some View {
        HStack {
            Text("\(label): \(offset.description) s")
                .monospacedDigit()
            Spacer(minLength: 8)
            Button("Apply \(label) Offset") {
                guard !reportIsStale, !model.isBusy,
                      model.project?.audioReplacements.contains(where: { $0.replacement.source == suggestion.sourceID }) != true else { return }
                if model.byHand({ model.updateSource(suggestion.sourceID) { $0.offset = offset } }) {
                    dismiss()
                } else {
                    failure = model.notice?.message ?? "Unable to apply the offset."
                }
            }
            .controlSize(.small)
            .disabled(reportIsStale || model.isBusy || offset == suggestion.currentOffset)
            .accessibilityLabel("Apply \(label) offset to \(source)")
        }
    }
}
