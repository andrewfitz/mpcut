import AppKit
import MPCutCore

extension MulticamEditorModel {
    private var currentScene: MulticamAnalysisStore.ScenePosition? {
        let output = preview.currentTime()
        guard let interval = interval(at: output) else { return nil }
        return analysis.currentScene(at: groupTime(at: output), angle: interval.angle,
                                     exclusiveEnd: output == mapping?.duration)
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
        prompt.informativeText = "All matching scenes from this camera will use the new name. Clear the field to restore the default."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
        field.toolTip = "Enter view name"
        field.placeholderString = scene.defaultName
        field.stringValue = scene.name ?? ""
        field.setAccessibilityLabel("View name")
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Save").toolTip = "Save view name"
        prompt.addButton(withTitle: "Cancel").toolTip = "Cancel rename"
        prompt.window.initialFirstResponder = field
        prompt.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            self?.analysis.rename(scene, to: field.stringValue)
        }
    }

    var canUseRoomTone: Bool {
        !isBusy && analysis.canUseRoomTone(in: selectedExportRanges)
    }

    @discardableResult
    func useRoomTone() -> Bool {
        guard !isBusy, analysis.useRoomTone(in: selectedExportRanges) else { return false }
        markIn = nil
        markOut = nil
        assemblySelection = nil
        return true
    }

    var selectedSceneCamera: String? {
        guard let marker = selectedSwitch else { return nil }
        return project?.switches.first(where: { $0.at == marker })?.angle
    }

    func confirmSceneRestart(camera: String? = nil, paused: Bool, repeatPrevious: Bool = false) {
        guard !isBusy, let window else { return }
        let prompt = NSAlert()
        prompt.messageText = paused ? "Restart scene analysis?" : "Scan for scenes again?"
        prompt.informativeText = "MPCut will start a new analysis for this footage."
        prompt.addButton(withTitle: paused ? "Restart" : "Scan Again").toolTip = "Restart scene scan"
        prompt.addButton(withTitle: "Cancel").toolTip = "Keep existing scene analysis"
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.isBusy else { return }
            let policy = SceneScanPolicy.restart(operationID: UUID().uuidString)
            if repeatPrevious {
                self.analysis.repeatSceneScan(policy: policy)
            } else {
                self.analysis.scanScenes(camera: camera, policy: policy)
            }
        }
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
        if assemblyPreview, output == mapping?.duration { return group }
        return snappedAnalysisTime(group, within: activeAnalysisOccurrence(containing: group, at: output)) ?? group
    }

    func activeAnalysisOccurrence(containing time: RationalTime, at output: RationalTime? = nil) -> MulticamRange? {
        guard assemblyPreview else { return nil }
        let index = occurrenceIndex(at: output ?? preview.currentTime())
        guard let range = assemblyRange(at: index) else { return nil }
        return range.contains(time) ? range : nil
    }

    func snappedAnalysisTime(_ time: RationalTime, excludingGroupEdges: Bool = false,
                             within scope: MulticamRange? = nil, includeEnd: Bool = false) -> RationalTime? {
        let target = analysis.snapTarget
        guard target != .off, let project else { return nil }
        let markers = analysis.markers(target, project: project, media: media)
        let first = scope.map { scope in markers.lowerBound { $0 >= scope.from } }
            ?? (excludingGroupEdges ? markers.lowerBound { $0 > project.range.from } : markers.startIndex)
        let end = scope.map { scope in markers.lowerBound { includeEnd ? $0 > scope.to : $0 >= scope.to } }
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
        if let cached = analysisNavigationAvailability[target] { return cached }
        let markers = analysis.markers(target, project: project, media: media)
        let available = !markers.isEmpty && mapping.intervals.contains { interval in
            let first = markers.lowerBound { $0 >= interval.group.from }
            return first < markers.count && (markers[first] < interval.group.to ||
                (markers[first] == interval.group.to && interval.output.to == mapping.duration))
        }
        analysisNavigationAvailability[target] = available
        return available
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
