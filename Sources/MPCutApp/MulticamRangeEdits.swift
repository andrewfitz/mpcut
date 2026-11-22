import Combine
import Foundation
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

    nonisolated static func assemblyEnds(for items: [StillAssemblyItem]) -> [RationalTime] {
        var end = RationalTime.zero
        return items.map { item in
            let duration: RationalTime?
            switch item {
            case .group(let range): duration = try? range.to.subtracting(range.from)
            case .still(let still): duration = still.duration
            }
            if let duration, let next = try? end.adding(duration) { end = next }
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
        if let still = assemblyStill(at: index),
           let snapped = stillFrameBoundary(offset, cadence: still.cadence, nearest: true),
           let result = try? start.adding(snapped) { return result }
        guard let range = assemblyRange(at: index), offset != .zero,
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
        var retainsMedia = assemblyItems.contains { $0.still != nil }
        // Each entry belongs to its assembly occurrence, including repeated source ranges.
        let portions = assemblyItems.indices.map { index -> AudioSpan? in
            guard let range = assemblyRange(at: index) else { return nil }
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

    var canSplitSelectedRange: Bool {
        guard canActOnRange else { return false }
        if assemblySelectionIncludesStill, let selection = assemblySelection {
            return [selection.from, selection.to].contains { edge in
                .zero < edge && edge < (assemblyRangeEnds.last ?? .zero) && !assemblyRangeEnds.contains(edge)
            }
        }
        return selectionEdits.canSplit
    }
    var canDeleteSelectedRange: Bool {
        guard canActOnRange else { return false }
        if assemblySelectionIncludesStill, let selection = assemblySelection, let end = assemblyRangeEnds.last {
            return selection.from > .zero || selection.to < end
        }
        return selectionEdits.canDelete
    }

    var canActOnRange: Bool {
        guard project != nil, !isBusy else { return false }
        if let assemblySelection { return assemblySelection.from < assemblySelection.to }
        return markedGroupSpan != nil
    }

    var selectedExportRanges: [MulticamRange] {
        if assemblySelectionIncludesStill { return [] }
        if assemblySelection == nil { return markedGroupSpan.map { [MulticamSilencePlanner.range($0)] } ?? [] }
        return selectionEdits.assemblyExportRanges
    }

    var assemblySelectionIncludesStill: Bool {
        guard let selection = assemblySelection else { return false }
        return assemblyItems.indices.contains { index in
            assemblyStill(at: index) != nil && selection.from < assemblyRangeEnds[index]
                && assemblyStart(at: index) < selection.to
        }
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
        if assemblySelectionIncludesStill {
            editTypedSelection(delete: false)
            return
        }
        let assemblySpan = assemblySelection
        let pieces = assemblyGroupIndices.flatMap { index -> [(occurrence: Int, span: AudioSpan)] in
            guard let range = assemblyRange(at: index) else { return [] }
            let selected = selectionEdits.portions[index]
            let edges = [range.from] + [selected?.from, selected?.to].compactMap { $0 }.filter {
                range.from < $0 && $0 < range.to
            } + [range.to]
            return zip(edges, edges.dropFirst()).map { (occurrence: index, span: AudioSpan(from: $0, to: $1)) }
        }
        if replaceRetainedRanges(pieces, action: "Split Selected Range") { assemblySelection = assemblySpan }
    }

    func deleteSelectedRange() {
        guard canDeleteSelectedRange else { return }
        if assemblySelectionIncludesStill {
            editTypedSelection(delete: true)
            return
        }
        let pieces = assemblyGroupIndices.flatMap { index -> [(occurrence: Int, span: AudioSpan)] in
            guard let range = assemblyRange(at: index) else { return [] }
            let selected = selectionEdits.portions[index]
            return AudioAnalysis.retained(in: MulticamSilencePlanner.span(range), removing: selected.map { [$0] } ?? [])
                .map { (occurrence: index, span: $0) }
        }
        if replaceRetainedRanges(pieces, action: "Delete Selected Range") { markIn = nil; markOut = nil }
    }

    private func editTypedSelection(delete: Bool) {
        guard let project, let span = assemblySelection, let end = assemblyRangeEnds.last else { return }
        var pieces = [MulticamRange(from: .zero, to: span.from)]
        if !delete { pieces.append(.init(from: span.from, to: span.to)) }
        pieces.append(.init(from: span.to, to: end))
        do {
            var used = Set<String>()
            var items: [StillAssemblyItem] = []
            for piece in pieces where piece.from < piece.to {
                let slice = try project.assemblySelection(piece)
                for item in slice.assemblyItems ?? [] {
                    if var insert = item.still, !used.insert(insert.id).inserted {
                        insert.id = UUID().uuidString
                        items.append(.still(insert))
                    } else {
                        items.append(item)
                    }
                }
            }
            guard !items.isEmpty else { return }
            preview.pause()
            if edit(delete ? "Delete Selected Range" : "Split Selected Range", { $0.assemblyItems = items }) {
                focusAssemblyEdit()
                if delete {
                    seekAssembly(at: span.from, scrubbing: false)
                } else {
                    assemblySelection = span
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    var markedGroupSpan: AudioSpan? {
        guard let markIn, let markOut, markIn != markOut else { return nil }
        return .init(from: min(markIn, markOut), to: max(markIn, markOut))
    }

    var deleteTitle: String {
        if rangeTool { return "Delete Selected Range" }
        switch editSelection {
        case .group: return "Delete Switch"
        case .assembly:
            if markIn != nil || markOut != nil { return "Delete Marked Range" }
            return assemblyStill(at: selectedOccurrence) == nil ? "Delete Assembly Range" : "Delete Still"
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
            return assemblyStill(at: selectedOccurrence) != nil
                || (assemblyItems.count > 1 && assemblyItems.indices.contains(selectedOccurrence))
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

    var canCutOccurrence: Bool { !isBusy && (occurrenceCut != nil || assemblyStillCut(at: preview.currentTime()) != nil) }
    var canTrimOccurrence: Bool { occurrenceCut(useRangeUnderGroupPlayhead: false) != nil }

    var occurrenceCut: (index: Int, time: RationalTime)? {
        occurrenceCut(useRangeUnderGroupPlayhead: true)
    }

    private func occurrenceCut(useRangeUnderGroupPlayhead: Bool) -> (index: Int, time: RationalTime)? {
        guard !isBusy, mapping != nil else { return nil }
        let output = preview.currentTime()
        let group = groupTime(at: output)
        let preferred = occurrenceIndex(at: output)
        let index: Int
        if assemblyPreview || !useRangeUnderGroupPlayhead {
            guard assemblyRange(at: preferred) != nil else { return nil }
            index = preferred
        } else {
            let containsPlayhead: (Int) -> Bool = { index in
                guard let range = self.assemblyRange(at: index) else { return false }
                return range.from < group && group < range.to
            }
            if containsPlayhead(preferred) { index = preferred }
            else if let first = assemblyGroupIndices.first(where: containsPlayhead) { index = first }
            else { return nil }
        }
        guard let time = occurrenceSplitBoundary(index: index, group: group) else { return nil }
        return (index, time)
    }

    func occurrenceSplitBoundary(index: Int, group: RationalTime) -> RationalTime? {
        guard !isBusy, mapping != nil, let range = assemblyRange(at: index) else { return nil }
        guard range.from < group, group < range.to else { return nil }
        let time = snappedAnalysisTime(group, within: range, includeEnd: true) ?? snappedFrame(group, delta: 0) ?? group
        guard range.from < time, time < range.to else { return nil }
        return time
    }

    func trimOccurrence(_ edge: TimelineEdge) {
        guard let (index, at) = occurrenceCut(useRangeUnderGroupPlayhead: false) else { return }
        guard let range = assemblyRange(at: index) else { return }
        preview.pause()
        changeOccurrence(index, from: edge == .start ? at : range.from, to: edge == .end ? at : range.to)
        if edge == .start { seekAssemblyOccurrence(index, group: at) }
    }

    func removeMarkedRange() {
        guard !isBusy, let markedGroupSpan else { return }
        let pieces = assemblyGroupIndices.flatMap { index -> [(occurrence: Int, span: AudioSpan)] in
            guard let original = assemblyRange(at: index) else { return [] }
            return AudioAnalysis.retained(in: MulticamSilencePlanner.span(original), removing: [markedGroupSpan])
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

    private var selectedPauseOccurrences: [AudioSpan?]? {
        assemblySelection.map { _ in assemblyGroupIndices.map { selectionEdits.portions[$0] } }
    }

    var multicamPausePlan: [MulticamPauseEdit] {
        multicamPausePlan(forPlayback: false)
    }

    func multicamPausePlan(forPlayback: Bool) -> [MulticamPauseEdit] {
        guard let project, !isBusy else { return [] }
        let groupPlayback = forPlayback && !assemblyPreview
        let ranges = groupPlayback ? [project.range] : ranges
        let occurrenceScopes = groupPlayback ? nil : selectedPauseOccurrences
        guard analysis.hasSilenceResults(in: pauseAnalysisScope(ranges, occurrenceScopes: occurrenceScopes)) else { return [] }
        let result = MulticamSilencePlanner.plan(project: project, media: media,
            ranges: ranges,
            silences: analysis.silenceResults, scope: markedGroupSpan,
            minimum: analysis.pauseMinimum, leave: preferences.leavePause, protected: pauseEdits.protected,
            keyframesOnly: analysis.snapTarget == .keyframes, occurrenceScopes: occurrenceScopes,
            assemblyIndices: groupPlayback ? nil : assemblyGroupIndices)
        guard !groupPlayback else { return result }
        let indices = assemblyGroupIndices
        return result.map { pause in
            .init(id: .init(occurrence: indices[pause.id.occurrence], span: pause.id.span),
                  visible: pause.visible, removal: pause.removal, isProtected: pause.isProtected)
        }
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
        guard !isBusy, assemblyRange(at: pause.id.occurrence)?.contains(pause.visible.from) == true else { return }
        preview.pause()
        if !assemblyPreview { setAssemblyPreview(true) }
        focusAssemblyEdit()
        seekAssemblyOccurrence(pause.id.occurrence, group: pause.visible.from)
    }

    @discardableResult
    func applyMulticamPauses(queueTakes: Bool, plan: [MulticamPauseEdit]) -> Bool {
        guard canApplyPauses, plan.contains(where: { $0.removal != nil }) else { return false }
        let indices = assemblyGroupIndices
        let positions = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($1, $0) })
        let groupPauses = plan.compactMap { pause -> MulticamPauseEdit? in
            guard let index = positions[pause.id.occurrence] else { return nil }
            return .init(id: .init(occurrence: index, span: pause.id.span), visible: pause.visible,
                         removal: pause.removal, isProtected: pause.isProtected)
        }
        let pieces = MulticamSilencePlanner.retainedOccurrences(ranges, pauses: groupPauses,
                                                                scope: queueTakes ? markedGroupSpan : nil,
                                                                occurrenceScopes: queueTakes ? selectedPauseOccurrences : nil)
        let retained = pieces.map { (occurrence: indices[$0.occurrence], span: $0.span) }
        if queueTakes { return enqueuePauseTakes(retained) }
        guard !retained.isEmpty || assemblyItems.contains(where: { $0.still != nil }) else {
            notice = Notice(title: "No media to keep", message: "Increase the time left in each pause or keep a pause.")
            return false
        }
        guard replaceRetainedRanges(retained, action: "Remove Pauses") else { return false }
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
        let byOccurrence = Dictionary(grouping: pieces, by: \.occurrence)
        var revised: [StillAssemblyItem] = []
        var origin: [Int] = []
        for (index, item) in assemblyItems.enumerated() {
            let items: [StillAssemblyItem]
            switch item {
            case .still: items = [item]
            case .group: items = (byOccurrence[index] ?? []).map { .group(MulticamSilencePlanner.range($0.span)) }
            }
            revised.append(contentsOf: items)
            origin.append(contentsOf: Array(repeating: index, count: items.count))
        }
        guard revised != assemblyItems else { return false }
        guard !revised.isEmpty else {
            notice = Notice(title: "No media to keep", message: "Keep at least one item in the assembly.")
            return false
        }
        preview.pause()
        guard edit(action, { $0.assemblyItems = revised }) else { return false }
        focusAssemblyEdit()
        guard assemblyPreview, let playhead, let mapping else { return true }
        let same = origin.indices.filter { origin[$0] == playhead.occurrence }
        if let index = same.first(where: { assemblyRange(at: $0)?.contains(playhead.group) == true }) {
            seekAssemblyOccurrence(index, group: playhead.group)
        } else if let index = same.first(where: { assemblyStill(at: $0) != nil || (assemblyRange(at: $0)?.from ?? .zero) >= playhead.group })
                    ?? origin.indices.first(where: { origin[$0] > playhead.occurrence }) {
            seekAssembly(at: assemblyStart(at: index), scrubbing: false)
        } else {
            selectedOccurrence = max(0, revised.count - 1)
            preview.seek(to: mapping.duration)
        }
        return true
    }

    func reviewMulticamPause(_ pause: MulticamPauseEdit) {
        guard let project, let cut = pause.removal, let original = assemblyRange(at: pause.id.occurrence) else { return }
        let context = RationalTime(numerator: 3, denominator: 4)
        guard let from = try? cut.from.subtracting(context),
              let to = try? cut.to.adding(context),
              let window = MulticamSilencePlanner.intersection(.init(from: from, to: to),
                                                            MulticamSilencePlanner.span(original)) else { return }
        let kept = AudioAnalysis.retained(in: window, removing: [cut]).map(MulticamSilencePlanner.range)
        guard !kept.isEmpty, let plan = try? project.plan(ranges: kept) else { return }
        preview.pause()
        pauseEdits.review = .init(id: pause.id, plan: plan)
    }
}
