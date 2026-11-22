import Combine
import MPCutCore

@MainActor
final class MulticamPauseEdits: ObservableObject {
    struct Review {
        let id: MulticamPauseEdit.ID
        var pause: AudioSpan { id.span }
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

enum MulticamExportProgram { case assembly, group, selection }

struct MulticamRangeSelectionEdits {
    let portions: [AudioSpan?]
    let assemblyExportRanges: [MulticamRange]
    let canSplit: Bool
    let canDelete: Bool
}

extension MulticamEditorModel {
    var displayedMarkIn: RationalTime? { assemblySelection?.from ?? markIn }
    var displayedMarkOut: RationalTime? { assemblySelection?.to ?? markOut }

    func selectGroupRange(_ first: RationalTime, _ last: RationalTime) {
        guard !isBusy, let project else { return }
        let a = rangeEdge(first, within: project.range)
        let b = rangeEdge(last, within: project.range)
        guard assemblySelection != nil || markIn != min(a, b) || markOut != max(a, b) else { return }
        preview.pause()
        markIn = min(a, b)
        markOut = max(a, b)
    }

    private func rangeEdge(_ time: RationalTime, within range: MulticamRange) -> RationalTime {
        if time <= range.from { return range.from }
        if time >= range.to { return range.to }
        let snapped = snappedAnalysisTime(time, within: range, includeEnd: true)
            ?? snappedFrame(time, delta: 0) ?? time
        return min(range.to, max(range.from, snapped))
    }

    nonisolated static func assemblyEnds(for ranges: [MulticamRange]) -> [RationalTime] {
        var end = RationalTime.zero
        return ranges.map { range in
            if let duration = try? range.to.subtracting(range.from), let next = try? end.adding(duration) {
                end = next
            }
            return end
        }
    }

    func selectAssemblyRange(_ first: Double, _ last: Double) {
        guard !isBusy, first.isFinite, last.isFinite, let duration = assemblyRangeEnds.last else { return }
        func edge(_ seconds: Double) -> RationalTime {
            if seconds <= 0 { return .zero }
            if seconds >= duration.seconds { return duration }
            let index = assemblyRangeEnds.lowerBound { $0.seconds > seconds }
            let start = index == 0 ? RationalTime.zero : assemblyRangeEnds[index - 1]
            guard let offset = timelineRationalTime(seconds - start.seconds) else { return start }
            return assemblySelectionEdge(index: index, start: start, offset: offset)
        }
        setAssemblyRangeSelection(edge(first), edge(last))
    }

    func selectAssemblyRange(_ first: RationalTime, _ last: RationalTime) {
        guard !isBusy, let duration = assemblyRangeEnds.last else { return }
        func edge(_ time: RationalTime) -> RationalTime {
            if time <= .zero { return .zero }
            if time >= duration { return duration }
            let index = assemblyRangeEnds.lowerBound { $0 > time }
            let start = index == 0 ? RationalTime.zero : assemblyRangeEnds[index - 1]
            guard let offset = try? time.subtracting(start) else { return start }
            return assemblySelectionEdge(index: index, start: start, offset: offset)
        }
        setAssemblyRangeSelection(edge(first), edge(last))
    }

    private func assemblySelectionEdge(index: Int, start: RationalTime, offset: RationalTime) -> RationalTime {
        let range = ranges[index]
        guard offset != .zero,
              let group = try? range.from.adding(offset),
              let snapped = try? rangeEdge(group, within: range).subtracting(range.from),
              let result = try? start.adding(snapped) else { return start }
        return result
    }

    private func setAssemblyRangeSelection(_ first: RationalTime, _ last: RationalTime) {
        let span = AudioSpan(from: min(first, last), to: max(first, last))
        guard assemblySelection != span else { return }
        preview.pause()
        if markIn != nil { markIn = nil }
        if markOut != nil { markOut = nil }
        assemblySelection = span
        focusAssemblyEdit()
    }

    private var selectionEdits: MulticamRangeSelectionEdits {
        if let rangeSelectionEdits { return rangeSelectionEdits }
        let groupSpan = markedGroupSpan
        var canSplit = false
        var removesMedia = false
        var retainsMedia = false
        // Each entry belongs to its assembly occurrence, including repeated source ranges.
        let portions = ranges.enumerated().map { index, range -> AudioSpan? in
            let source = MulticamSilencePlanner.span(range)
            let selected: AudioSpan?
            if let assemblySelection {
                let start = index == 0 ? RationalTime.zero : assemblyRangeEnds[index - 1]
                let end = assemblyRangeEnds[index]
                selected = MulticamSilencePlanner.intersection(.init(from: start, to: end), assemblySelection)
                    .flatMap { overlap in
                        guard let startOffset = try? overlap.from.subtracting(start),
                              let endOffset = try? overlap.to.subtracting(start),
                              let from = try? range.from.adding(startOffset),
                              let to = try? range.from.adding(endOffset) else { return nil }
                        return AudioSpan(from: from, to: to)
                    }
            } else {
                selected = groupSpan.flatMap { MulticamSilencePlanner.intersection(source, $0) }
            }
            if let selected {
                removesMedia = true
                canSplit = canSplit || selected != source
            }
            retainsMedia = retainsMedia || selected != source
            return selected
        }
        let edits = MulticamRangeSelectionEdits(
            portions: portions,
            assemblyExportRanges: assemblySelection == nil ? [] : portions.compactMap { $0.map(MulticamSilencePlanner.range) },
            canSplit: canSplit, canDelete: removesMedia && retainsMedia
        )
        rangeSelectionEdits = edits
        return edits
    }

    var canSplitSelectedRange: Bool { canActOnRange && selectionEdits.canSplit }
    var canDeleteSelectedRange: Bool { canActOnRange && selectionEdits.canDelete }

    var canActOnRange: Bool {
        guard project != nil, !isBusy else { return false }
        if let assemblySelection { return assemblySelection.from < assemblySelection.to }
        return markedGroupSpan != nil
    }

    var selectedExportRanges: [MulticamRange] {
        if assemblySelection == nil { return markedGroupSpan.map { [MulticamSilencePlanner.range($0)] } ?? [] }
        return selectionEdits.assemblyExportRanges
    }

    func chooseProgramExport() {
        guard project != nil, !isBusy else { return }
        if exportProgram == .selection && !canActOnRange { exportProgram = .assembly }
        exportRequested.toggle()
    }

    func chooseSelectionExport() {
        guard canActOnRange else { return }
        exportProgram = .selection
        exportRequested.toggle()
    }

    func splitSelectedRange() {
        guard canSplitSelectedRange else { return }
        let assemblySpan = assemblySelection
        let pieces = zip(ranges, selectionEdits.portions).enumerated().flatMap { index, pair in
            let (range, selected) = pair
            let edges = [range.from] + [selected?.from, selected?.to].compactMap { $0 }.filter {
                range.from < $0 && $0 < range.to
            } + [range.to]
            return zip(edges, edges.dropFirst()).map { (occurrence: index, span: AudioSpan(from: $0, to: $1)) }
        }
        if replaceRetainedRanges(pieces, action: "Split Selected Range") { assemblySelection = assemblySpan }
    }

    func deleteSelectedRange() {
        guard canDeleteSelectedRange else { return }
        let pieces = zip(ranges, selectionEdits.portions).enumerated().flatMap { index, pair in
            let (range, selected) = pair
            return AudioAnalysis.retained(in: MulticamSilencePlanner.span(range), removing: selected.map { [$0] } ?? [])
                .map { (occurrence: index, span: $0) }
        }
        if replaceRetainedRanges(pieces, action: "Delete Selected Range") { markIn = nil; markOut = nil }
    }

    var markedGroupSpan: AudioSpan? {
        guard let markIn, let markOut, markIn != markOut else { return nil }
        return .init(from: min(markIn, markOut), to: max(markIn, markOut))
    }

    var deleteTitle: String {
        if rangeTool { return "Delete Selected Range" }
        switch editSelection {
        case .group: return "Delete Switch"
        case .assembly: return markIn != nil || markOut != nil ? "Delete Marked Range" : "Delete Assembly Range"
        }
    }

    var canDeleteSelection: Bool {
        if rangeTool { return canDeleteSelectedRange }
        guard let project, !isBusy else { return false }
        switch editSelection {
        case .group:
            guard let at = selectedSwitch else { return false }
            return at != project.range.from && project.switches.contains { $0.at == at }
        case .assembly:
            if markIn != nil || markOut != nil { return canDeleteSelectedRange }
            return ranges.count > 1 && ranges.indices.contains(selectedOccurrence)
        }
    }

    func deleteSelection() {
        guard canDeleteSelection else { return }
        if rangeTool { deleteSelectedRange(); return }
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
        guard let time = occurrenceSplitBoundary(index: index, group: group) else { return nil }
        return (index, time)
    }

    func occurrenceSplitBoundary(index: Int, group: RationalTime) -> RationalTime? {
        guard !isBusy, mapping != nil, ranges.indices.contains(index) else { return nil }
        let range = ranges[index]
        guard range.from < group, group < range.to else { return nil }
        let time = snappedAnalysisTime(group, within: range, includeEnd: true) ?? snappedFrame(group, delta: 0) ?? group
        guard range.from < time, time < range.to else { return nil }
        return time
    }

    func trimOccurrence(_ edge: TimelineEdge) {
        guard let (index, at) = occurrenceCut(useRangeUnderGroupPlayhead: false) else { return }
        var revised = ranges
        switch edge {
        case .start: revised[index].from = at
        case .end: revised[index].to = at
        }
        if replaceRetainedRanges(revised, action: "Trim Assembly Range") {
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
        if replaceRetainedRanges(pieces, action: "Delete Marked Range") {
            markIn = nil
            markOut = nil
        }
    }

    var canApplyPauses: Bool {
        project != nil && !isBusy && analysis.hasSilenceResults(in: pauseAnalysisScope(ranges, occurrenceScopes: selectedPauseOccurrences))
    }

    private var selectedPauseOccurrences: [AudioSpan?]? { assemblySelection.map { _ in selectionEdits.portions } }

    var multicamPausePlan: [MulticamPauseEdit] {
        multicamPausePlan(forPlayback: false)
    }

    func multicamPausePlan(forPlayback: Bool) -> [MulticamPauseEdit] {
        guard let project, !isBusy else { return [] }
        let groupPlayback = forPlayback && !assemblyPreview
        let ranges = groupPlayback ? [project.range] : ranges
        let occurrenceScopes = groupPlayback ? nil : selectedPauseOccurrences
        guard analysis.hasSilenceResults(in: pauseAnalysisScope(ranges, occurrenceScopes: occurrenceScopes)) else { return [] }
        return MulticamSilencePlanner.plan(project: project, media: media,
            ranges: ranges,
            silences: analysis.silenceResults, scope: markedGroupSpan,
            minimum: analysis.pauseMinimum, leave: preferences.leavePause, protected: pauseEdits.protected,
            keyframesOnly: analysis.snapTarget == .keyframes, occurrenceScopes: occurrenceScopes)
    }

    private func pauseAnalysisScope(_ ranges: [MulticamRange], occurrenceScopes: [AudioSpan?]?) -> [MulticamRange] {
        if let occurrenceScopes { return occurrenceScopes.compactMap { $0.map(MulticamSilencePlanner.range) } }
        guard let markedGroupSpan else { return ranges }
        return ranges.compactMap { range in
            MulticamSilencePlanner.intersection(MulticamSilencePlanner.span(range), markedGroupSpan)
                .map(MulticamSilencePlanner.range)
        }
    }

    func setPauseProtection(_ keep: Bool, for pause: MulticamPauseEdit) {
        if keep {
            pauseEdits.protected.insert(pause.id.span)
        } else {
            pauseEdits.protected = pauseEdits.protected.filter {
                MulticamSilencePlanner.intersection($0, pause.id.span) == nil
            }
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
                                                                scope: queueTakes ? markedGroupSpan : nil,
                                                                occurrenceScopes: queueTakes ? selectedPauseOccurrences : nil)
        guard !pieces.isEmpty else {
            notice = Notice(title: "No media to keep", message: "Increase the time left in each pause or keep a pause.")
            return false
        }
        if queueTakes {
            return enqueueRanges(pieces.map { MulticamSilencePlanner.range($0.span) })
        }
        guard replaceRetainedRanges(pieces, action: "Remove Pauses") else { return false }
        setAssemblyPreview(true)
        return true
    }

    /// Replaces the assembly with what is left of each occurrence. In Assembly
    /// preview the cut shifts output time, so the playhead returns to the group
    /// time it showed in the occurrence it was in, or to the edit point when
    /// that content was removed.
    @discardableResult
    private func replaceRetainedRanges(_ pieces: [(occurrence: Int, span: AudioSpan)], action: String) -> Bool {
        let output = preview.currentTime()
        let playhead = assemblyPreview ? (occurrence: occurrenceIndex(at: output), group: groupTime(at: output)) : nil
        let revised = pieces.map { MulticamSilencePlanner.range($0.span) }
        guard replaceRetainedRanges(revised, action: action) else { return false }
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
    private func replaceRetainedRanges(_ revised: [MulticamRange], action: String) -> Bool {
        guard revised != ranges else { return false }
        guard !revised.isEmpty else {
            notice = Notice(title: "No media to keep", message: "Keep at least one range in the assembly.")
            return false
        }
        preview.pause()
        guard edit(action, { $0.assembly = revised }) else { return false }
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
        pauseEdits.review = .init(id: pause.id, plan: plan)
    }
}
