import Combine
import MPCutCore

@MainActor
final class MulticamPauseEdits: ObservableObject {
    struct Review {
        let pause: AudioSpan
        let plan: MulticamPlan
    }

    @Published var skip = false
    @Published var protected: Set<AudioSpan> = []
    @Published var review: Review?

    func reset() {
        skip = false
        protected = []
        review = nil
    }
}

extension MulticamEditorModel {
    var markedGroupSpan: AudioSpan? {
        guard let markIn, let markOut, markIn != markOut else { return nil }
        return .init(from: min(markIn, markOut), to: max(markIn, markOut))
    }

    var deleteTitle: String {
        switch editSelection {
        case .group: return "Delete Switch"
        case .assembly: return markIn != nil || markOut != nil ? "Delete Marked Range" : "Delete Assembly Range"
        }
    }

    var canDeleteSelection: Bool {
        guard let project, !isBusy else { return false }
        switch editSelection {
        case .group:
            guard let at = selectedSwitch else { return false }
            return at != project.range.from && project.switches.contains { $0.at == at }
        case .assembly:
            if markIn != nil || markOut != nil { return markedGroupSpan != nil }
            return ranges.count > 1 && ranges.indices.contains(selectedOccurrence)
        }
    }

    func deleteSelection() {
        guard canDeleteSelection else { return }
        switch editSelection {
        case .group:
            if let at = selectedSwitch { deleteSwitch(at) }
        case .assembly:
            if markedGroupSpan != nil { removeMarkedRange() }
            else { removeOccurrence() }
        }
    }

    var canCutOccurrence: Bool { occurrenceCut != nil }
    var canTrimOccurrence: Bool { occurrenceCut(useRangeUnderGroupPlayhead: false) != nil }

    var occurrenceCut: (index: Int, time: RationalTime)? {
        occurrenceCut(useRangeUnderGroupPlayhead: true)
    }

    private func occurrenceCut(useRangeUnderGroupPlayhead: Bool) -> (index: Int, time: RationalTime)? {
        guard !isBusy, mapping != nil else { return nil }
        let ranges = ranges
        let output = preview.currentTime()
        let group = groupTime(at: output)
        let preferred = occurrenceIndex(at: output)
        let index: Int
        if assemblyPreview || !useRangeUnderGroupPlayhead {
            guard ranges.indices.contains(preferred) else { return nil }
            index = preferred
        } else {
            let containsPlayhead: (MulticamRange) -> Bool = { $0.from < group && group < $0.to }
            if ranges.indices.contains(preferred), containsPlayhead(ranges[preferred]) {
                index = preferred
            } else if let first = ranges.firstIndex(where: containsPlayhead) {
                index = first
            } else {
                return nil
            }
        }
        let range = ranges[index]
        guard range.from < group, group < range.to else { return nil }
        let time = snappedAnalysisTime(group) ?? snappedFrame(group, delta: 0) ?? group
        guard range.from < time, time < range.to else { return nil }
        return (index, time)
    }

    func trimOccurrence(_ edge: TimelineEdge) {
        guard let (index, at) = occurrenceCut(useRangeUnderGroupPlayhead: false) else { return }
        var revised = ranges
        switch edge {
        case .start: revised[index].from = at
        case .end: revised[index].to = at
        }
        if replaceRetainedRanges(revised) {
            selectedOccurrence = index
            if edge == .start { seekAssemblyOccurrence(index, group: at) }
        }
    }

    func removeMarkedRange() {
        guard !isBusy, let markedGroupSpan else { return }
        let pieces = ranges.enumerated().flatMap { index, original in
            AudioAnalysis.retained(in: MulticamSilencePlanner.span(original), removing: [markedGroupSpan])
                .map { (occurrence: index, span: $0) }
        }
        if replaceRetainedRanges(pieces) {
            markIn = nil
            markOut = nil
        }
    }

    var canApplyPauses: Bool {
        project != nil && !isBusy && analysis.hasSilenceResults(in: pauseAnalysisScope(ranges))
    }

    var multicamPausePlan: [MulticamPauseEdit] {
        multicamPausePlan(forPlayback: false)
    }

    func multicamPausePlan(forPlayback: Bool) -> [MulticamPauseEdit] {
        guard let project, !isBusy else { return [] }
        let ranges = forPlayback && !assemblyPreview ? [project.range] : ranges
        guard analysis.hasSilenceResults(in: pauseAnalysisScope(ranges)) else { return [] }
        return MulticamSilencePlanner.plan(project: project, media: media,
            ranges: ranges,
            silences: analysis.silenceResults, scope: markedGroupSpan,
            minimum: analysis.pauseMinimum, leave: preferences.leavePause, protected: pauseEdits.protected,
            keyframesOnly: analysis.snapTarget == .keyframes)
    }

    private func pauseAnalysisScope(_ ranges: [MulticamRange]) -> [MulticamRange] {
        guard let markedGroupSpan else { return ranges }
        return ranges.compactMap { range in
            MulticamSilencePlanner.intersection(MulticamSilencePlanner.span(range), markedGroupSpan)
                .map(MulticamSilencePlanner.range)
        }
    }

    func seekMulticamPause(_ pause: MulticamPauseEdit) {
        guard !isBusy, ranges.indices.contains(pause.id.occurrence),
              ranges[pause.id.occurrence].contains(pause.visible.from) else { return }
        preview.pause()
        if !assemblyPreview { setAssemblyPreview(true) }
        focusAssemblyEdit()
        seekAssemblyOccurrence(pause.id.occurrence, group: pause.visible.from)
    }

    @discardableResult
    func applyMulticamPauses(queueTakes: Bool, plan: [MulticamPauseEdit]) -> Bool {
        guard canApplyPauses, plan.contains(where: { $0.removal != nil }) else { return false }
        let pieces = MulticamSilencePlanner.retainedOccurrences(ranges, pauses: plan,
                                                                scope: queueTakes ? markedGroupSpan : nil)
        guard !pieces.isEmpty else {
            notice = Notice(title: "No media to keep", message: "Increase the time left in each pause or keep a pause.")
            return false
        }
        if queueTakes {
            return enqueueRanges(pieces.map { MulticamSilencePlanner.range($0.span) })
        }
        guard replaceRetainedRanges(pieces) else { return false }
        setAssemblyPreview(true)
        return true
    }

    /// Replaces the assembly with what is left of each occurrence. In Assembly
    /// preview the cut shifts output time, so the playhead returns to the group
    /// time it showed in the occurrence it was in, or to the edit point when
    /// that content was removed.
    @discardableResult
    private func replaceRetainedRanges(_ pieces: [(occurrence: Int, span: AudioSpan)]) -> Bool {
        let output = preview.currentTime()
        let playhead = assemblyPreview ? (occurrence: occurrenceIndex(at: output), group: groupTime(at: output)) : nil
        let revised = pieces.map { MulticamSilencePlanner.range($0.span) }
        guard replaceRetainedRanges(revised) else { return false }
        guard assemblyPreview, let playhead, let mapping else { return true }
        let same = pieces.indices.filter { pieces[$0].occurrence == playhead.occurrence }
        if let index = same.first(where: { revised[$0].contains(playhead.group) }) {
            seekAssemblyOccurrence(index, group: playhead.group)
        } else if let index = same.first(where: { revised[$0].from >= playhead.group })
                    ?? pieces.indices.first(where: { pieces[$0].occurrence > playhead.occurrence }) {
            seekAssemblyOccurrence(index, group: revised[index].from)
        } else {
            selectedOccurrence = max(0, revised.count - 1)
            preview.seek(to: mapping.duration)
        }
        return true
    }

    @discardableResult
    private func replaceRetainedRanges(_ revised: [MulticamRange]) -> Bool {
        guard revised != ranges else { return false }
        guard !revised.isEmpty else {
            notice = Notice(title: "No media to keep", message: "Keep at least one range in the assembly.")
            return false
        }
        preview.pause()
        guard edit({ $0.assembly = revised }) else { return false }
        focusAssemblyEdit()
        return true
    }

    func reviewMulticamPause(_ pause: MulticamPauseEdit) {
        guard let project, let cut = pause.removal, ranges.indices.contains(pause.id.occurrence) else { return }
        let context = RationalTime(numerator: 3, denominator: 4)
        guard let from = try? cut.from.subtracting(context),
              let to = try? cut.to.adding(context),
              let window = MulticamSilencePlanner.intersection(.init(from: from, to: to),
                                                            MulticamSilencePlanner.span(ranges[pause.id.occurrence])) else { return }
        let kept = AudioAnalysis.retained(in: window, removing: [cut]).map(MulticamSilencePlanner.range)
        guard !kept.isEmpty, let plan = try? project.plan(ranges: kept) else { return }
        preview.pause()
        pauseEdits.review = .init(pause: pause.id.span, plan: plan)
    }
}
