import AppKit
import MPCutCore

extension MulticamEditorModel {
    private var currentScene: MulticamAnalysisStore.ScenePosition? {
        guard let project else { return nil }
        return analysis.currentScene(at: currentGroupTime(), project: project)
    }

    var currentSceneLabel: String? {
        guard let scene = currentScene else { return nil }
        return "Scene \(scene.index + 1)/\(scene.report.scenes.count) · \(scene.name ?? scene.defaultName)"
    }

    var canRenameCurrentView: Bool { !isBusy && currentScene != nil }

    func renameCurrentView() {
        guard !isBusy, let scene = currentScene, let window else { return }
        preview.pause()
        let prompt = NSAlert()
        prompt.messageText = "Rename \(scene.defaultName)"
        prompt.informativeText = "The name applies to every matching scene in this camera. Leave it blank to restore the default."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
        field.placeholderString = scene.defaultName
        field.stringValue = scene.name ?? ""
        field.setAccessibilityLabel("View name")
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Save")
        prompt.addButton(withTitle: "Cancel")
        prompt.window.initialFirstResponder = field
        prompt.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            self?.analysis.rename(scene, to: field.stringValue)
        }
    }

    private var roomToneScope: MulticamRange? {
        markedGroupSpan.map { MulticamRange(from: $0.from, to: $0.to) }
    }

    var canUseRoomTone: Bool {
        guard !isBusy, let roomToneScope else { return false }
        return analysis.canUseRoomTone(in: roomToneScope)
    }

    func useRoomTone() {
        guard !isBusy, let roomToneScope, analysis.useRoomTone(in: roomToneScope) else { return }
        markIn = nil
        markOut = nil
    }

    func canScanAnalysis(_ target: TimelineSnapTarget) -> Bool { !isBusy && analysis.canScan(target) }

    func scanAnalysis(_ target: TimelineSnapTarget) {
        guard !isBusy else { return }
        analysis.scan(target)
    }

    func cancelAnalysis(_ target: TimelineSnapTarget) { analysis.cancel(target) }

    func configureSilenceAnalysis(minimum: Double, threshold: Double?) {
        guard minimum.isFinite, minimum >= 1 / Double(AudioWaveform.rate),
              threshold.map({ (-120...0).contains($0) }) ?? true else { return }
        analysis.configureSilence(minimum: minimum, threshold: threshold)
        preferences.minimumPause = minimum
    }

    func setAnalysisSnap(_ target: TimelineSnapTarget) {
        preferences.snapTarget = target
    }

    func markAnalysisTime() -> RationalTime {
        let output = preview.currentTime()
        let group = groupTime(at: output)
        return snappedAnalysisTime(group, within: activeAnalysisOccurrence(containing: group, at: output)) ?? group
    }

    func activeAnalysisOccurrence(containing time: RationalTime, at output: RationalTime? = nil) -> MulticamRange? {
        guard assemblyPreview else { return nil }
        let index = occurrenceIndex(at: output ?? preview.currentTime())
        let ranges = ranges
        guard ranges.indices.contains(index) else { return nil }
        let range = ranges[index]
        return range.contains(time) ? range : nil
    }

    func snappedAnalysisTime(_ time: RationalTime, excludingGroupEdges: Bool = false,
                             within scope: MulticamRange? = nil) -> RationalTime? {
        let target = analysis.snapTarget
        guard target != .off, let project else { return nil }
        let markers = analysis.markers(target, project: project, media: media)
        let first = scope.map { scope in markers.lowerBound { $0 >= scope.from } }
            ?? (excludingGroupEdges ? markers.lowerBound { $0 > project.range.from } : markers.startIndex)
        let end = scope.map { scope in markers.lowerBound { $0 >= scope.to } }
            ?? (excludingGroupEdges ? markers.lowerBound { $0 >= project.range.to } : markers.endIndex)
        let eligible = markers[first..<end]
        let next = eligible.lowerBound { $0 >= time }
        guard let previous = next > first ? markers[next - 1] : nil else { return eligible.first }
        guard next < end else { return previous }
        let nextTime = markers[next]
        return time.seconds - previous.seconds <= nextTime.seconds - time.seconds ? previous : nextTime
    }

    private func analysisNavigationMarkers(_ target: TimelineSnapTarget) -> [RationalTime] {
        guard let project, let mapping else { return [] }
        let markers = analysis.markers(target, project: project, media: media)
        return MulticamAnalysisStore.outputMarkers(markers, in: mapping)
    }

    func canStepAnalysis(_ target: TimelineSnapTarget) -> Bool {
        guard !isBusy, let project, let mapping else { return false }
        let markers = analysis.markers(target, project: project, media: media)
        return mapping.intervals.contains { interval in
            let first = markers.lowerBound { $0 >= interval.group.from }
            return first < markers.count && (markers[first] < interval.group.to ||
                (markers[first] == interval.group.to && interval.output.to == mapping.duration))
        }
    }

    func stepAnalysis(_ target: TimelineSnapTarget, direction: Int) {
        guard !isBusy, direction != 0 else { return }
        let markers = analysisNavigationMarkers(target)
        let elapsed = preview.currentTime().seconds
        let index = direction > 0 ? markers.lowerBound { $0.seconds > elapsed + 1e-8 }
            : markers.lowerBound { $0.seconds >= elapsed - 1e-8 } - 1
        guard markers.indices.contains(index) else { return }
        let at = markers[index]
        preview.pause()
        if assemblyPreview, let interval = mapping?.intervals.first(where: { $0.output.contains(at) }) ?? mapping?.intervals.last {
            selectedOccurrence = interval.assemblyIndex
        }
        preview.seek(to: at)
    }
}
