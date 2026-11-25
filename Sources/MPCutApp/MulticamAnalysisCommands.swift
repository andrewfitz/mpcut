import AppKit
import MPCutCore

extension MulticamEditorModel {
    private var currentScene: MulticamAnalysisStore.ScenePosition? {
        let output = preview.currentTime()
        guard let source = interval(at: output)?.pictureSourceID else { return nil }
        return analysis.currentScene(at: groupTime(at: output), angle: source,
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

    /// Restarting a paused scan discards its progress, so that always asks. Scanning finished scenes again asks
    /// while Settings → General → Confirm before scanning scenes again is on.
    func confirmSceneRestart(camera: String? = nil, paused: Bool, repeatPrevious: Bool = false) {
        guard !isBusy else { return }
        let restart = { [weak self] in
            guard let self, !self.isBusy else { return }
            let policy = SceneScanPolicy.restart(operationID: UUID().uuidString)
            if repeatPrevious {
                self.analysis.repeatSceneScan(policy: policy)
            } else {
                self.analysis.scanScenes(camera: camera, policy: policy)
            }
        }
        if !paused, !preferences.asks(.sceneRescan) { return restart() }
        guard let window else { return }
        let prompt = NSAlert()
        prompt.messageText = paused ? "Restart scene analysis?" : "Scan for scenes again?"
        prompt.informativeText = "MPCut will start a new analysis for this footage."
        prompt.addButton(withTitle: paused ? "Restart" : "Scan Again").toolTip = "Restart scene scan"
        prompt.addButton(withTitle: "Cancel").toolTip = "Keep existing scene analysis"
        if !paused {
            prompt.showsSuppressionButton = true
            prompt.suppressionButton?.title = "Don’t ask again"
            prompt.suppressionButton?.toolTip = "Scan scenes again without asking"
        }
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // Cancelling changes nothing, including the preference.
            if prompt.suppressionButton?.state == .on, !paused { self?.preferences.suppress(.sceneRescan) }
            restart()
        }
    }

    func canScanAnalysis(_ target: TimelineSnapTarget) -> Bool { !isBusy && analysis.canScan(target) }

    func scanAnalysis(_ target: TimelineSnapTarget) {
        guard !isBusy else { return }
        analysis.scan(target)
    }

    func cancelAnalysis(_ target: TimelineSnapTarget) {
        analysis.dropAutomaticScans(target)
        analysis.cancel(target)
    }

    /// Settings → Media & Analysis: recordings just added to the project are scanned for scenes or pauses. Off keeps
    /// scans on request only.
    func requestAutomaticScans(for ids: Set<String>) {
        let scenes = preferences.autoScanScenes, pauses = preferences.autoScanSilence
        guard !ids.isEmpty, scenes || pauses else { return }
        analysis.requestAutomaticScans(of: ids, scenes: scenes, pauses: pauses)
    }

    func configureSilenceAnalysis(minimum: Double, threshold: Double?) {
        guard minimum.isFinite, minimum >= 1 / Double(AudioWaveform.rate),
              threshold.map({ (-120...0).contains($0) }) ?? true else { return }
        if let project, project.analysisAnnotations.multicamThresholdDB != threshold {
            guard edit("Set Silence Threshold", { $0.analysisAnnotations.multicamThresholdDB = threshold }) else { return }
        }
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
        let scope = activeAnalysisOccurrence(containing: group, at: output)
        let angle = scope == nil ? nil : assemblyItems[occurrenceIndex(at: output)].angleOverride
        return snappedAnalysisTime(group, within: scope, pictureAngle: angle) ?? group
    }

    func activeAnalysisOccurrence(containing time: RationalTime, at output: RationalTime? = nil) -> MulticamRange? {
        guard assemblyPreview else { return nil }
        let index = occurrenceIndex(at: output ?? preview.currentTime())
        guard let range = assemblyRange(at: index) else { return nil }
        return range.contains(time) ? range : nil
    }

    func snappedAnalysisTime(_ time: RationalTime, excludingGroupEdges: Bool = false,
                             within scope: MulticamRange? = nil, includeEnd: Bool = false,
                             pictureAngle: String? = nil) -> RationalTime? {
        let target = analysis.snapTarget
        guard target != .off, let project else { return nil }
        let markers: [RationalTime]
        if let pictureAngle, target == .scenes || target == .keyframes {
            markers = analysis.pictureSnapMarkers(target, angle: pictureAngle, project: project,
                                                  near: time, within: scope ?? project.range, includeEnd: includeEnd)
        } else {
            markers = analysis.markers(target, project: project, media: media)
        }
        let first = scope.map { scope in markers.lowerBound { $0 >= scope.from } }
            ?? (excludingGroupEdges ? markers.lowerBound { $0 > project.range.from } : markers.startIndex)
        let end = scope.map { scope in markers.lowerBound { includeEnd ? $0 > scope.to : $0 >= scope.to } }
            ?? (excludingGroupEdges ? markers.lowerBound { $0 >= project.range.to } : markers.endIndex)
        guard first < end else { return nil }
        let eligible = markers[first..<end]
        let next = eligible.lowerBound { $0 >= time }
        guard let previous = next > first ? markers[next - 1] : nil else { return eligible.first }
        guard next < end else { return previous }
        let nextTime = markers[next]
        return time.seconds - previous.seconds <= nextTime.seconds - time.seconds ? previous : nextTime
    }

    private func analysisNavigationMarkers(_ target: TimelineSnapTarget) -> [RationalTime] {
        guard let project, let mapping else { return [] }
        if target == .scenes || target == .keyframes {
            return analysis.pictureOutputMarkers(target, in: mapping)
        }
        let markers = analysis.markers(target, project: project, media: media)
        return MulticamAnalysisStore.outputMarkers(markers, in: mapping)
    }

    func canStepAnalysis(_ target: TimelineSnapTarget) -> Bool {
        guard !isBusy, let project, let mapping else { return false }
        if let cached = analysisNavigationAvailability[target] { return cached }
        if target == .scenes || target == .keyframes {
            let available = analysis.hasPictureMarker(target, in: mapping)
            analysisNavigationAvailability[target] = available
            return available
        }
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
