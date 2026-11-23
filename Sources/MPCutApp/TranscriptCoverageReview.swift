import SwiftUI
import MPCutCore

struct TranscriptCoverageReview: View {
    let index: TranscriptIndex
    let space: TranscriptSpace
    let filter: TranscriptFilter
    let sourceLabel: (String) -> String
    let seek: ((RationalTime) -> Void)?

    @State private var report: TranscriptInputCoverageReport?
    @State private var gapOffset = 0
    @State private var trackOffset = 0
    @State private var loading = true
    @State private var error: String?

    private let pageSize = 24

    private struct Request: Equatable {
        let gapOffset: Int
        let trackOffset: Int
    }

    private var request: Request { Request(gapOffset: gapOffset, trackOffset: trackOffset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(space == .source ? "Source presentation clock" : "Synchronized group clock")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("transcript.coverage.clock")
            if loading { ProgressView("Checking coverage…").controlSize(.small) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let report {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        SectionHeading("Input Streams")
                        if report.tracks.total == 0 {
                            Text("No streams match the current filters.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(report.tracks.items.enumerated()), id: \.offset) { entry in
                            trackRow(entry.element)
                        }
                        pageControls("streams", offset: $trackOffset, total: report.tracks.total, next: report.tracks.nextOffset)
                        Divider()
                        SectionHeading("Coverage Gaps")
                        if report.gaps.total == 0 {
                            Text("No timed gaps match the current filters.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(report.gaps.items.enumerated()), id: \.offset) { entry in
                            gapRow(entry.element)
                        }
                        pageControls("gaps", offset: $gapOffset, total: report.gaps.total, next: report.gaps.nextOffset)
                    }
                    .padding(2)
                }
                .frame(minHeight: 120, idealHeight: 340, maxHeight: 420)
                .disabled(loading)
            }
        }
        .task(id: request) { await load(request) }
    }

    private func load(_ request: Request) async {
        loading = true
        error = nil
        let index = index
        let space = space
        let filter = filter
        let pageSize = pageSize
        let worker = Task.detached(priority: .userInitiated) {
            try index.inputCoverage(space: space, filter: filter, offset: request.gapOffset, limit: pageSize,
                                    trackOffset: request.trackOffset, trackLimit: pageSize)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, request == self.request else { return }
            report = result
        } catch {
            guard !Task.isCancelled, request == self.request else { return }
            report = nil
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func trackRow(_ track: TranscriptInputCoverageStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(track.name, value: track.coverage.label)
            if let label = track.laneLabel, let slot = track.laneColorSlot {
                TranscriptLaneChip(label: label, colorSlot: slot)
            }
            let source = track.sourceID.map(sourceLabel) ?? track.file.map(sourceLabel)
            let device = details(source: source, stream: track.streamIndex, channel: track.channel)
            if !device.isEmpty { Text(device).font(.caption).foregroundStyle(.secondary) }
            if let bounds = track.bounds {
                Text(coordinates(bounds)).font(.caption.monospacedDigit()).textSelection(.enabled)
            }
            if let status = track.bindingStatus, status != .available {
                Label(status.label, systemImage: "link.badge.plus").font(.caption).foregroundStyle(.orange)
            }
            if let message = track.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func gapRow(_ gap: TranscriptCoverageGap) -> some View {
        if let seek {
            Button { seek(gap.range.from) } label: { gapLabel(gap) }
                .buttonStyle(.plain)
                .accessibilityHint("Seek to the start of this gap")
        } else {
            gapLabel(gap)
                .textSelection(.enabled)
        }
    }

    private func gapLabel(_ gap: TranscriptCoverageGap) -> some View {
        let track = gap.trackID.flatMap { id in index.document.tracks.first { $0.id == id }?.name }
        let source = gap.sourceID.map(sourceLabel) ?? gap.file.map(sourceLabel)
        let reference = details(source: source ?? track, stream: gap.streamIndex, channel: nil)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(gap.reason.label, systemImage: "waveform")
                if let label = gap.laneLabel, let slot = gap.laneColorSlot {
                    TranscriptLaneChip(label: label, colorSlot: slot)
                }
            }
            Text(coordinates(gap.range)).font(.caption.monospacedDigit())
            if !reference.isEmpty { Text(reference).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pageControls(_ noun: String, offset: Binding<Int>, total: Int, next: Int?) -> some View {
        if total > pageSize {
            HStack {
                Button("Previous \(noun)") { offset.wrappedValue = max(0, offset.wrappedValue - pageSize) }
                    .disabled(offset.wrappedValue == 0)
                    .accessibilityIdentifier("transcript.coverage.\(noun).previous")
                Spacer()
                Text("\(offset.wrappedValue + 1)–\(min(total, offset.wrappedValue + pageSize)) of \(total)")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("Next \(noun)") { if let next { offset.wrappedValue = next } }
                    .disabled(next == nil)
                    .accessibilityIdentifier("transcript.coverage.\(noun).next")
            }
            .controlSize(.small)
        }
    }

    private func coordinates(_ bounds: MulticamRange) -> String {
        "\(bounds.from.description)–\(bounds.to.description) s"
    }

    private func details(source: String?, stream: Int?, channel: Int?) -> String {
        [source, stream.map { "Stream \($0)" }, channel.map { "Channel \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension TranscriptCoverage {
    var label: String {
        switch self {
        case .recognized: "Recognized"
        case .skipped: "Skipped recognition"
        case .failed: "Recognition failed"
        case .coverageOnly: "Camera coverage only"
        }
    }
}

private extension TranscriptBindingStatus {
    var label: String {
        switch self {
        case .available: "Verified media"
        case .unverified: "Unverified media"
        case .offline: "Media offline"
        case .changed: "Media changed"
        case .unbound: "Unbound audio stream"
        case .bindingMissing: "Source removed from project"
        }
    }
}

private extension TranscriptGapReason {
    var label: String {
        switch self {
        case .still: "Still"
        case .silence: "Silence"
        case .unbound: "Unbound audio stream"
        case .skipped: "Skipped recognition"
        case .failed: "Recognition failed"
        case .unavailable: "Audio unavailable"
        case .changed: "Media changed"
        }
    }
}
