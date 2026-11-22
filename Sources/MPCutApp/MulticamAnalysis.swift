import Combine
import Foundation
import MPCutCore

struct MulticamAnalysisAudioSpan {
    let selection: MulticamAudioSelection
    let group: MulticamRange
    let input: MulticamRange
    let waveform: AudioWaveform?
}

struct MulticamAnalysisSnapshot: Sendable {
    var scenes: SceneReport?
    var waveforms: [Int: AudioWaveform] = [:]
    var silence: [SilenceAnalysisResult] = []
    var edits = EditorMetadataEdits()

    func sections(for media: MediaInfo, cancelled: () -> Bool) throws -> [String: Data] {
        var sections = try AnalysisSidecar.sections(media: media, scenes: scenes, cancelled: cancelled)
        let results = Dictionary(grouping: silence, by: \.stream)
        for stream in Set(waveforms.keys).union(results.keys) {
            let audioMedia = try media.extendingToAudioEnd(stream: stream)
            let wave = waveforms[stream].map { [stream: $0] } ?? [:]
            let audio = try AnalysisSidecar.sections(media: audioMedia, waveforms: wave,
                                                     silence: results[stream] ?? [], cancelled: cancelled)
            sections.merge(audio) { _, track in track }
        }
        return sections
    }

    var metadataUpdates: [String: (Data?) throws -> Data] {
        func updating<Value: Codable>(_ edits: [Int: Value?], seed: [Int: Value] = [:]) -> (Data?) throws -> Data {
            { old in
                try JSONEncoder().encode(EditorMetadataEdits.merged(old, seed: seed, edits: edits))
            }
        }
        var updates: [String: (Data?) throws -> Data] = [:]
        if !edits.names.isEmpty {
            // Writing the current section replaces names restored from an earlier format.
            // Carry those forward when the sidecar has no current section yet.
            let shown = (scenes?.views ?? []).compactMap { view in view.name.map { (view.view, $0) } }
            updates[AnalysisSidecar.viewNameSectionKey] = updating(
                edits.names, seed: Dictionary(shown, uniquingKeysWith: { _, latest in latest }))
        }
        if !edits.thresholds.isEmpty { updates["thresholdOverrides.v1"] = updating(edits.thresholds) }
        return updates
    }
}

@MainActor
final class MulticamAnalysisStore: ObservableObject {
    private enum Job: Hashable {
        case waveform(MulticamAudioSelection)
        case silence(MulticamAudioSelection)
        case savedScenes(String)

        var source: String {
            switch self {
            case .waveform(let route), .silence(let route): route.source
            case .savedScenes(let id): id
            }
        }

        var target: TimelineSnapTarget {
            switch self {
            case .waveform, .savedScenes: .off
            case .silence: .silence
            }
        }
    }

    private struct SourceVersion: Hashable {
        let url: URL
        let identity: SourceIdentity
        let origin: RationalTime
        let duration: RationalTime

        init(_ media: MediaInfo) {
            url = media.url
            identity = media.identity
            origin = media.origin
            duration = media.duration
        }
    }

    private struct SourceTrack: Hashable {
        let version: SourceVersion
        let stream: Int
    }

    let waveformDetail = WaveformEnvelopeStore<MulticamAudioSelection>()
    private var sources: [String: MediaInfo] = [:]
    private var pictureSourceIDs = Set<String>()
    private var sourceVersions: [String: SourceVersion] = [:]
    private var presentationOffsets: [String: RationalTime] = [:]
    private var keyframes: [String: [RationalTime]] = [:]
    private var groupPlan: MulticamPlan?
    var groupIntervals: [MulticamInterval] { groupPlan?.intervals ?? [] }
    private var activeRoutes: [MulticamSilenceRoute] = []
    private var activeSilenceTracks = Set<MulticamAudioSelection>()
    private var selectedSilenceTracks = Set<MulticamAudioSelection>()
    private var routedSceneMarkers: [RationalTime] = []
    private var routedKeyframeMarkers: [RationalTime] = []
    private var routedSilenceMarkers: [RationalTime] = []
    private var groupPauses: [AudioSpan] = []
    private var angleOffsets: [String: RationalTime] = [:]
    private var jobs: [Job: EditCancellation] = [:]
    private let sceneScan = EditorSceneScan()
    private var partialScenes: [String: [RationalTime]] = [:]
    var sceneCache: SceneScanSession { sceneScan.cache }
    var sceneCheckpointRequests: [EditorSceneRequest] { sceneScan.checkpointRequests }
    var sceneCoverage: [String: SceneScanProgress] { sceneScan.coverage }
    func didSaveSceneCheckpoint(_ id: String, progress: SceneScanProgress) {
        sceneScan.didSaveCheckpoint(id, progress: progress)
        publish()
    }
    var sceneStatus: String? { sceneScan.status }
    var scenePaused: Bool { sceneScan.paused }
    var sceneCheckpointSaveFailed: Bool { sceneCoverage.values.contains { $0.persistenceError != nil } }

    func sceneInspectionKey(camera: String?) -> SceneInspectionKey {
        SceneInspectionKey(sceneRequests(camera: camera), readingSidecars: useSidecars, revision: sceneScan.inspectionRevision)
    }

    func inspectSceneChoices(camera: String?) async {
        await sceneScan.inspect(sceneRequests(camera: camera), preference: sidecarPreference)
        if !Task.isCancelled { publish() }
    }

    func sceneDisposition(camera: String?) -> SceneScanDisposition? {
        let stale = camera.map(refreshStaleScenes.contains) ?? !refreshStaleScenes.isEmpty
        return stale ? .stale : sceneScan.disposition(sceneRequests(camera: camera))
    }

    var mcpReceipts: [TimelineSnapTarget: MCPAnalysisReceipt] = [:]
    private var issues: [Job: String] = [:]
    private var waves: [MulticamAudioSelection: AudioWaveform] = [:]
    private var finishedWaves = Set<MulticamAudioSelection>()
    private var silences: [MulticamAudioSelection: SilenceAnalysisResult] = [:]
    private var pendingSilenceRescans = Set<MulticamAudioSelection>()
    private var roomThresholds: [SourceTrack: Double] = [:]
    private(set) var sceneReports: [String: SceneReport] = [:]
    var refreshStaleScenes = Set<String>()
    private(set) var staleSceneReports: [String: SceneReport] = [:]
    private var refreshStaleSilence = Set<MulticamAudioSelection>()
    private var visibleOnlyWaveforms = Set<MulticamAudioSelection>()
    private var pendingMediaRefresh: [String: MediaRefreshResult] = [:]

    func stageMediaRefresh(_ id: String, result: MediaRefreshResult) {
        pendingMediaRefresh[id] = result
    }

    func hasStaleSilence(_ id: String) -> Bool {
        refreshStaleSilence.contains { $0.source == id }
    }

    private var checkedSavedScenes = Set<String>()
    private var metadata: [String: EditorMetadataEdits] = [:]
    private(set) var metadataWrite: Task<Void, Never>?
    private var metadataWriteID: UUID?
    private var scenes: [String: [RationalTime]] = [:]
    private var useSidecars = true
    private var excludedSources = Set<URL>()
    private let sidecarPreference = SidecarPreference()
    private var requested = Set<TimelineSnapTarget>()
    var changed: (() -> Void)?
    private(set) var snapTarget: TimelineSnapTarget = .off
    private(set) var pauseMinimum = 1.5
    private(set) var pauseThreshold: Double?

    private var inputPauseMinimum: Double {
        MulticamSilencePlanner.inputMinimum(pauseMinimum, routes: activeRoutes)
    }

    var silenceTrackCount: Int { activeSilenceTracks.count }

    var unindexedSilenceSources: Set<String> {
        Set(selectedSilenceTracks.lazy.map(\.source).filter { self.sources[$0] == nil })
    }

    var hasMissingSilenceTrack: Bool {
        selectedSilenceTracks.contains { route in
            guard let source = sources[route.source] else { return false }
            return !source.audio.contains { $0.stream.index == route.stream }
        }
    }

    var silenceIssue: String? {
        for route in activeRoutes {
            if let issue = issues[.silence(route.selection)] { return issue }
        }
        return nil
    }

    func programMicrophone(at time: RationalTime, project: MulticamProject, exclusiveEnd: Bool = false) -> String {
        guard let groupPlan else { return "Unavailable" }
        guard let interval = groupPlan.intervals.last else { return "Unavailable" }
        let atEnd = exclusiveEnd || time == interval.group.to
        let index = groupPlan.intervals.lowerBound { atEnd ? $0.group.to >= time : $0.group.to > time }
        let onAir = groupPlan.intervals.indices.contains(index) ? groupPlan.intervals[index] : interval
        guard let selection = onAir.audio else { return "None routed here" }
        let name = project.sources.first { $0.id == selection.source }?.displayName ?? selection.source
        let track = "\(name) · stream \(selection.stream)"
        let coverage = activeRoutes.lowerBound { atEnd ? $0.group.to >= time : $0.group.to > time }
        guard activeRoutes.indices.contains(coverage),
              activeRoutes[coverage].selection == selection,
              atEnd ? activeRoutes[coverage].group.from < time : activeRoutes[coverage].group.from <= time else {
            return "\(track) · no audio here"
        }
        if let result = silences[selection] {
            let level = result.thresholdDB.formatted(.number.precision(.fractionLength(0...1)))
            return "\(track) · \(level) dBFS threshold"
        }
        return track
    }

    var silenceProgress: Double? {
        let routes = activeSilenceTracks
        let pending = routes.contains { route in
            jobs[.silence(route)] != nil ||
                (requested.contains(.silence) && !complete(.silence(route)) && jobs[.waveform(route)] != nil)
        }
        guard pending, !routes.isEmpty else { return nil }
        let completed = routes.reduce(0.0) { progress, route in
            if silences[route] != nil, !pendingSilenceRescans.contains(route) { return progress + 1 }
            guard let wave = waves[route], wave.duration.seconds > 0 else { return progress }
            let bins = wave.duration.seconds * Double(AudioWaveform.rate)
            return progress + min(0.9, Double(wave.count) / bins * 0.9)
        }
        return completed / Double(routes.count)
    }

    var sceneProgress: Double? { sceneScan.progress }

    var status: String? {
        if sceneProgress != nil { return sceneStatus }
        if silenceProgress != nil { return "Scanning multicam audio for silence…" }
        return silenceIssue ?? waveformIssue ?? sceneStatus
    }

    /// A routed track whose waveform could not be read leaves its lane empty.
    var waveformIssue: String? {
        for route in activeRoutes {
            if let issue = issues[.waveform(route.selection)] { return issue }
        }
        return nil
    }

    private func publish() {
        for (target, receipt) in mcpReceipts where target != .scenes && !isScanning(target) {
            let error = target == .silence ? silenceIssue ?? waveformIssue : issues.first { $0.key.target == target }?.value
            let candidates = candidates(for: target)
            let completed = candidates.filter(complete)
            let sources = Set(completed.map(\.source)).sorted()
            if let error {
                receipt.finish("failed", detail: ["error": error, "sources": sources])
                mcpReceipts[target] = nil
            } else if !completed.isEmpty, completed.count == candidates.count {
                var detail: [String: Any] = ["sources": sources]
                if target == .silence {
                    let unindexed = unindexedSilenceSources.sorted()
                    if !unindexed.isEmpty { detail["unindexedSources"] = unindexed }
                    if hasMissingSilenceTrack { detail["missingSelectedTrack"] = true }
                }
                receipt.finish("succeeded", detail: detail)
                mcpReceipts[target] = nil
            } else {
                receipt.finish("failed", detail: ["error": "No current analysis report was produced."])
                mcpReceipts[target] = nil
            }
        }
        objectWillChange.send()
        changed?()
    }

    func reset() {
        waveformDetail.update(sources: [:], streams: [:], readSidecars: false, excludedSources: [], preloadAudioOverviews: false)
        for receipt in mcpReceipts.values { receipt.finish("cancelled") }
        mcpReceipts.removeAll()
        for work in jobs.values { work.cancel() }
        jobs = [:]
        sceneScan.reset()
        partialScenes = [:]
        previousSceneCamera = nil
        issues = [:]
        sources = [:]
        pictureSourceIDs = []
        sourceVersions = [:]
        presentationOffsets = [:]
        keyframes = [:]
        groupPlan = nil
        activeRoutes = []
        activeSilenceTracks = []
        selectedSilenceTracks = []
        angleOffsets = [:]
        routedSceneMarkers = []
        routedKeyframeMarkers = []
        routedSilenceMarkers = []
        groupPauses = []
        requested = snapTarget == .silence ? [snapTarget] : []
        waves = [:]
        finishedWaves = []
        silences = [:]
        pendingSilenceRescans = []
        roomThresholds = [:]
        sceneReports = [:]
        staleSceneReports = [:]
        refreshStaleScenes = []
        refreshStaleSilence = []
        visibleOnlyWaveforms = []
        pendingMediaRefresh = [:]
        checkedSavedScenes = []
        metadata = [:]
        scenes = [:]
        pauseThreshold = nil
    }

    func update(project: MulticamProject, media: [String: MediaInfo], ordinary: [String: MediaInfo], useSidecars: Bool,
                excludedSources: Set<URL> = [], reviewStreams: [URL: Set<Int>] = [:],
                reviewPicture: Set<URL> = []) {
        let refreshes = pendingMediaRefresh
        pendingMediaRefresh.removeAll()
        let next = ordinary.mapValues(SourceVersion.init)
        let offsets = media.mapValues(\.multicamClockOffset)
        let changedSources = next != sourceVersions || offsets != presentationOffsets || !refreshes.isEmpty
        let nextPlan = try? project.plan(ranges: [project.range])
        if (changedSources || groupPlan != nextPlan), mcpReceipts[.silence] != nil { cancel(.silence) }
        let sidecarPolicyChanged = self.useSidecars != useSidecars || self.excludedSources != excludedSources
        if sidecarPolicyChanged {
            sceneScan.invalidateInspection()
            for id in Array(jobs.keys) { cancelJob(id) }
            issues = [:]
            checkedSavedScenes = []
        }
        self.useSidecars = useSidecars
        self.excludedSources = excludedSources
        sidecarPreference.enabled = useSidecars
        sidecarPreference.setExclusions(excludedSources)
        for id in Set(sourceVersions.keys).union(next.keys).union(refreshes.keys)
            where sourceVersions[id] != next[id] || presentationOffsets[id] != offsets[id] || refreshes[id] != nil {
            if let result = refreshes[id] {
                for task in Array(jobs.keys) where task.source == id { cancelJob(task) }
                issues = issues.filter { $0.key.source != id }
                invalidateSceneScan(for: id)
                if result.scenesPreserved, let info = ordinary[id], let report = sceneReports[id] {
                    sceneReports[id] = report.forRefreshedMedia(info)
                    refreshStaleScenes.remove(id)
                    let offset = offsets[id] ?? .zero
                    scenes[id] = report.scenes.compactMap { try? $0.start.adding(offset) }
                } else {
                    if let report = sceneReports.removeValue(forKey: id) {
                        staleSceneReports[id] = report
                        refreshStaleScenes.insert(id)
                    }
                    scenes[id] = nil
                    checkedSavedScenes.remove(id)
                }
                let preserved = ordinary[id] != nil ? result.preservedAudioStreams : []
                if let version = sourceVersions[id] {
                    roomThresholds = roomThresholds.filter { $0.key.version != version || preserved.contains($0.key.stream) }
                }
                let routes = Set(waves.keys).union(silences.keys).union(activeSilenceTracks).filter { $0.source == id }
                for route in routes {
                    let replacement = try? ordinary[id]?.extendingToAudioEnd(stream: route.stream)
                    waveformDetail.refresh(route, media: replacement, preserving: preserved, visibleOnly: true)
                    if !preserved.contains(route.stream) {
                        if silences.removeValue(forKey: route) != nil { refreshStaleSilence.insert(route) }
                        waves[route] = nil
                        finishedWaves.remove(route)
                    } else if let replacement {
                        waves[route] = waves[route]?.forRefreshedMedia(replacement, stream: route.stream)
                        silences[route] = silences[route]?.forRefreshedMedia(replacement)
                        if let old = sourceVersions[id], let updated = next[id],
                           let threshold = roomThresholds[.init(version: old, stream: route.stream)] {
                            roomThresholds[.init(version: updated, stream: route.stream)] = threshold
                        }
                    }
                    visibleOnlyWaveforms.insert(route)
                }
                keyframes[id] = media[id]?.frames.lazy.filter(\.keyframe).map(\.time)
                continue
            }
            for task in Array(jobs.keys) where task.source == id { cancelJob(task) }
            issues = issues.filter { $0.key.source != id }
            waves = waves.filter { $0.key.source != id }
            finishedWaves = finishedWaves.filter { $0.source != id }
            silences = silences.filter { $0.key.source != id }
            invalidateSceneScan(for: id)
            sceneReports[id] = nil
            checkedSavedScenes.remove(id)
            metadata[id] = nil
            scenes[id] = nil
            keyframes[id] = media[id]?.frames.lazy.filter(\.keyframe).map(\.time)
        }
        let versions = Set(next.values)
        roomThresholds = roomThresholds.filter { versions.contains($0.key.version) }
        sourceVersions = next
        sources = ordinary
        pictureSourceIDs = Set(project.angles.compactMap { angle in
            guard let media = ordinary[angle.id], !reviewPicture.contains(media.url) else { return nil }
            return angle.id
        })
        sceneScan.pruneCheckpoints(keeping: Array(ordinary.values))
        presentationOffsets = offsets
        let nextAngles = Dictionary(uniqueKeysWithValues: project.angles.map { ($0.id, $0.offset) })
        let routesChanged = groupPlan != nextPlan || changedSources || angleOffsets != nextAngles
        if routesChanged {
            let oldMinimum = inputPauseMinimum
            groupPlan = nextPlan
            activeRoutes = MulticamSilencePlanner.routes(plan: groupPlan, project: project, media: media).filter { route in
                guard let url = media[route.selection.source]?.url else { return false }
                return reviewStreams[url]?.contains(route.selection.stream) != true
            }
            activeSilenceTracks = Set(activeRoutes.map(\.selection))
            visibleOnlyWaveforms.formUnion(activeSilenceTracks.filter { refreshes[$0.source] != nil })
            pendingSilenceRescans.formIntersection(activeSilenceTracks)
            selectedSilenceTracks = Set(groupPlan?.intervals.compactMap(\.audio) ?? [])
            if refreshes.isEmpty, oldMinimum != inputPauseMinimum {
                if !silences.isEmpty { requested.insert(.silence) }
                invalidateSilenceResults()
            }
            angleOffsets = nextAngles
            routedSceneMarkers = routedPictureMarkers(scenes)
            routedKeyframeMarkers = routedPictureMarkers(keyframes)
            updatePauses()
        }
        if routesChanged || sidecarPolicyChanged {
            var routedMedia: [MulticamAudioSelection: MediaInfo] = [:]
            for route in activeSilenceTracks {
                routedMedia[route] = try? ordinary[route.source]?.extendingToAudioEnd(stream: route.stream)
            }
            let streams = Dictionary(uniqueKeysWithValues: routedMedia.keys.map { ($0, $0.stream) })
            waveformDetail.update(sources: routedMedia, streams: streams, readSidecars: useSidecars,
                                  excludedSources: excludedSources, preloadAudioOverviews: false)
        }
        for job in Array(jobs.keys) {
            switch job {
            case .waveform(let route), .silence(let route):
                if !activeSilenceTracks.contains(route) { cancelJob(job) }
            default: break
            }
        }
        schedule()
    }

    func threshold(for route: MulticamAudioSelection) -> Double? {
        pauseThreshold ?? roomThreshold(for: route)
    }

    private func sourceTrack(for route: MulticamAudioSelection) -> SourceTrack? {
        sourceVersions[route.source].map { SourceTrack(version: $0, stream: route.stream) }
    }

    private func roomThreshold(for route: MulticamAudioSelection) -> Double? {
        sourceTrack(for: route).flatMap { roomThresholds[$0] }
    }

    func waveform(sourceID: String, stream: Int) -> AudioWaveform? {
        waves[MulticamAudioSelection(source: sourceID, stream: stream)]
    }

    func completedWaveform(sourceID: String, stream: Int) -> AudioWaveform? {
        let route = MulticamAudioSelection(source: sourceID, stream: stream)
        return finishedWaves.contains(route) ? waves[route] : nil
    }

    func sourceScenes(_ id: String) -> [RationalTime] { scenes[id] ?? partialScenes[id] ?? [] }

    struct ScenePosition {
        let source: String
        let report: SceneReport
        let index: Int

        var view: Int { report.scenes[index].view }
        var defaultName: String { "View \(SceneView.label(for: view))" }
        var name: String? { report.views.first { $0.view == view }?.name }
    }

    func currentScene(at groupTime: RationalTime, project: MulticamProject) -> ScenePosition? {
        guard let angle = project.selection(at: groupTime)?.angle else { return nil }
        return currentScene(at: groupTime, angle: angle, exclusiveEnd: false)
    }

    func currentScene(at groupTime: RationalTime, angle: String, exclusiveEnd: Bool) -> ScenePosition? {
        guard let offset = angleOffsets[angle],
              let report = sceneReports[angle], let markers = scenes[angle],
              let local = try? groupTime.subtracting(offset) else { return nil }
        let index = markers.lowerBound { exclusiveEnd ? $0 >= local : $0 > local } - 1
        guard report.scenes.indices.contains(index), index < markers.count,
              let end = try? report.scenes[index].end.adding(presentationOffsets[angle] ?? .zero),
              exclusiveEnd ? local <= end : local < end else { return nil }
        return ScenePosition(source: angle, report: report, index: index)
    }

    func rename(_ scene: ScenePosition, to text: String) {
        guard let report = sceneReports[scene.source], report.sourceStamp == scene.report.sourceStamp,
              report.file == scene.report.file else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : trimmed
        guard report.views.first(where: { $0.view == scene.view })?.name != name else { return }
        sceneReports[scene.source]?.setViewName(name, for: scene.view)
        if let media = sources[scene.source] { sceneScan.cache.setViewName(name, view: scene.view, for: media) }
        persistMetadata(scene.source, edits: EditorMetadataEdits(names: [scene.view: name]))
        publish()
    }

    func soundtrack(in visible: MulticamRange) -> [MulticamAnalysisAudioSpan] {
        let first = activeRoutes.lowerBound { $0.group.to > visible.from }
        let end = activeRoutes.lowerBound { $0.group.from >= visible.to }
        return activeRoutes[first..<end].map { route in
            MulticamAnalysisAudioSpan(selection: route.selection, group: route.group, input: route.input, waveform: waves[route.selection])
        }
    }

    func snapshot(for media: MediaInfo) -> MulticamAnalysisSnapshot {
        let version = SourceVersion(media)
        var snapshot = MulticamAnalysisSnapshot()
        for (id, candidate) in sourceVersions where candidate == version {
            snapshot.scenes = snapshot.scenes ?? sceneReports[id]
            for route in finishedWaves where route.source == id { snapshot.waveforms[route.stream] = waves[route] }
            snapshot.silence += silences.filter { $0.key.source == id }.map(\.value)
            if let edits = metadata[id] {
                snapshot.edits.names.merge(edits.names) { _, latest in latest }
                snapshot.edits.thresholds.merge(edits.thresholds) { _, latest in latest }
            }
        }
        return snapshot
    }

    func didSave(_ snapshot: MulticamAnalysisSnapshot, for media: MediaInfo) {
        let version = SourceVersion(media)
        for (id, candidate) in sourceVersions where candidate == version {
            metadata[id]?.discardSaved(snapshot.edits)
        }
    }

    func canScan(_ target: TimelineSnapTarget) -> Bool {
        guard !isScanning(target) else { return false }
        if target == .scenes { return sceneRequests(camera: nil).contains { sceneReports[$0.id] == nil } }
        if target == .silence, waveformIssue != nil { return true }
        return candidates(for: target).contains { sources[$0.source] != nil && !complete($0) }
    }

    func isScanning(_ target: TimelineSnapTarget) -> Bool {
        if target == .silence { return silenceProgress != nil }
        if target == .scenes { return sceneProgress != nil }
        return jobs.keys.contains { $0.target == target }
    }

    func scan(_ target: TimelineSnapTarget) {
        if target == .scenes {
            scanScenes()
            return
        }
        guard target == .silence else { return }
        issues = issues.filter { issue in
            // A silence scan reads the same tracks, so it also retries their waveforms.
            if case .waveform = issue.key { return target != .silence }
            return issue.key.target != target
        }
        visibleOnlyWaveforms.subtract(activeSilenceTracks)
        requested.insert(target)
        schedule()
        publish()
    }

    func canScanScenes(camera: String?) -> Bool {
        !isScanning(.scenes) && !sceneRequests(camera: camera).isEmpty
    }

    private func sceneRequests(camera: String?) -> [EditorSceneRequest] {
        let ids = camera.map { [$0] } ?? pictureSourceIDs.sorted()
        return ids.compactMap { id in
            guard pictureSourceIDs.contains(id), let media = sources[id], media.hasVideo else { return nil }
            return EditorSceneRequest(id: id, media: media)
        }
    }

    func scanScenes(camera: String? = nil, policy: SceneScanPolicy = .reuse) {
        guard canScanScenes(camera: camera) else { return }
        runSceneRequests(sceneRequests(camera: camera), camera: camera, policy: policy)
    }

    private var previousSceneCamera: String?

    func repeatSceneScan(policy: SceneScanPolicy) {
        guard !isScanning(.scenes) else { return }
        if sceneScan.requests.isEmpty {
            scanScenes(policy: policy)
        } else {
            runSceneRequests(sceneScan.requests, camera: previousSceneCamera, policy: policy)
        }
    }

    private func runSceneRequests(_ requests: [EditorSceneRequest], camera: String?, policy: SceneScanPolicy) {
        guard !requests.isEmpty else { return }
        previousSceneCamera = camera
        for request in requests { cancelJob(.savedScenes(request.id)) }
        let receipt = mcpReceipts[.scenes] ?? MCPAnalysisReceipt(owner: "", revision: 0, kind: "scenes")
        mcpReceipts[.scenes] = receipt
        receipt.sceneRequest = MCPSceneRequest(target: camera, policy: policy)
        receipt.nativeProgress = { [weak self] in self?.sceneProgress }
        receipt.sceneCoverage = { [weak self] in self?.sceneCoverage ?? [:] }
        receipt.cancelNative = { [weak self] in self?.cancel(.scenes) }
        sceneScan.start(requests, policy: policy, preference: sidecarPreference,
                        receipt: receipt, update: { [weak self] in
            guard let self else { return }
            if self.sceneScan.progress == nil {
                if self.mcpReceipts[.scenes] === receipt { self.mcpReceipts[.scenes] = nil }
                self.schedule()
            }
            self.publish()
        }, markers: { [weak self] request, batch, reset, _ in
            guard let self, self.sceneReports[request.id] == nil else { return }
            let offset = self.presentationOffsets[request.id] ?? .zero
            if reset { self.partialScenes[request.id] = nil }
            self.partialScenes[request.id, default: []].append(contentsOf: batch.compactMap { try? $0.time.adding(offset) })
        }, report: { [weak self] request, report, state in
            guard let self, state != .upToDate || self.sceneReports[request.id] == nil else { return }
            self.installSceneReport(report, for: request.id)
        })
    }

    private func installSceneReport(_ report: SceneReport, for id: String) {
        checkedSavedScenes.insert(id)
        refreshStaleScenes.remove(id)
        partialScenes[id] = nil
        sceneReports[id] = report
        let offset = presentationOffsets[id] ?? .zero
        scenes[id] = report.scenes.compactMap { try? $0.start.adding(offset) }
        routedSceneMarkers = routedPictureMarkers(scenes)
    }

    func invalidateSceneScan(for id: String) {
        sceneScan.invalidateInspection()
        cancelJob(.savedScenes(id))
        checkedSavedScenes.remove(id)
        partialScenes[id] = nil
        if sceneScan.requests.contains(where: { $0.id == id }) {
            mcpReceipts.removeValue(forKey: .scenes)?.finish("cancelled")
            sceneScan.reset(preservingCheckpoints: true)
            previousSceneCamera = nil
        }
    }

    func rescanSilence() {
        guard !isScanning(.silence), !activeSilenceTracks.isEmpty else { return }
        pendingSilenceRescans = activeSilenceTracks
        scan(.silence)
    }

    func cancelSceneAnalysisFromEditor() {
        mcpReceipts[.scenes]?.cancelFromEditor()
    }

    func cancel(_ target: TimelineSnapTarget) {
        if target == .scenes {
            sceneScan.cancel()
            publish()
            return
        }
        mcpReceipts.removeValue(forKey: target)?.finish("cancelled")
        requested.remove(target)
        if target == .silence { pendingSilenceRescans.removeAll() }
        for job in Array(jobs.keys) where job.target == target { cancelJob(job) }
        publish()
    }

    func setSnap(_ target: TimelineSnapTarget) {
        snapTarget = target
        if target == .silence {
            requested.insert(target)
            schedule()
        }
        publish()
    }

    func configureSilence(minimum: Double, threshold: Double?) {
        guard minimum.isFinite, minimum > 0, threshold.map({ (-120...0).contains($0) }) ?? true,
              minimum != pauseMinimum || threshold != pauseThreshold else { return }
        let oldMinimum = inputPauseMinimum
        pauseMinimum = minimum
        if oldMinimum != inputPauseMinimum || pauseThreshold != threshold {
            if mcpReceipts[.silence] != nil { cancel(.silence) }
            if activeSilenceTracks.contains(where: { silences[$0] != nil }) { requested.insert(.silence) }
            invalidateSilenceResults()
        }
        pauseThreshold = threshold
        updatePauses()
        schedule()
        publish()
    }

    private func invalidateSilenceResults() {
        for job in Array(jobs.keys) where job.target == .silence { cancelJob(job) }
        issues = issues.filter { $0.key.target != .silence }
        silences = [:]
    }

    private func roomTonePeaks(in ranges: [MulticamRange]) -> [SourceTrack: (source: String, peak: Float)]? {
        var peaks: [SourceTrack: (source: String, peak: Float)] = [:]
        for range in ranges {
            guard range.from < range.to else { continue }
            let firstInterval = groupIntervals.lowerBound { $0.group.to > range.from }
            let lastInterval = groupIntervals.lowerBound { $0.group.from >= range.to }
            guard groupIntervals[firstInterval..<lastInterval].compactMap(\.audio).allSatisfy({ route in
                sources[route.source]?.audio.contains { $0.stream.index == route.stream } == true
            }) else { return nil }
            let first = activeRoutes.lowerBound { $0.group.to > range.from }
            let end = activeRoutes.lowerBound { $0.group.from >= range.to }
            for route in activeRoutes[first..<end] {
                guard finishedWaves.contains(route.selection), let track = sourceTrack(for: route.selection),
                      let from = try? max(range.from, route.group.from).subtracting(route.offset),
                      let to = try? min(range.to, route.group.to).subtracting(route.offset),
                      let peak = waves[route.selection]?.peak(from: from.seconds, to: to.seconds) else { return nil }
                if peak >= (peaks[track]?.peak ?? 0) { peaks[track] = (route.selection.source, peak) }
            }
        }
        return peaks.isEmpty ? nil : peaks
    }

    func canUseRoomTone(in ranges: [MulticamRange]) -> Bool { roomTonePeaks(in: ranges) != nil }

    @discardableResult
    func useRoomTone(in scope: MulticamRange) -> Bool { useRoomTone(in: [scope]) }

    @discardableResult
    func useRoomTone(in ranges: [MulticamRange]) -> Bool {
        guard let peaks = roomTonePeaks(in: ranges) else { return false }
        if mcpReceipts[.silence] != nil { cancel(.silence) }
        for (track, measurement) in peaks {
            let threshold = AudioAnalysis.roomToneThresholdDB(forPeak: measurement.peak)
            roomThresholds[track] = threshold
            persistMetadata(measurement.source, edits: EditorMetadataEdits(thresholds: [track.stream: threshold]))
        }
        for route in activeSilenceTracks where sourceTrack(for: route).map({ peaks[$0] != nil }) == true {
            cancelJob(.silence(route))
            silences[route] = nil
        }
        if pauseThreshold != nil { configureSilence(minimum: pauseMinimum, threshold: nil) }
        updatePauses()
        scan(.silence)
        return true
    }

    private func candidates(for target: TimelineSnapTarget) -> [Job] {
        switch target {
        case .off: return activeSilenceTracks.subtracting(visibleOnlyWaveforms).map(Job.waveform)
        case .silence: return activeSilenceTracks.map(Job.silence)
        case .scenes, .keyframes: return []
        }
    }

    private func complete(_ job: Job) -> Bool {
        switch job {
        case .waveform(let route): return finishedWaves.contains(route)
        case .silence(let route): return silences[route] != nil && !pendingSilenceRescans.contains(route)
        case .savedScenes(let id): return checkedSavedScenes.contains(id) || sceneReports[id] != nil
        }
    }

    private func schedule() {
        for target in [.off, .silence] as [TimelineSnapTarget] where target == .off || requested.contains(target) {
            for job in candidates(for: target) where jobs[job] == nil && issues[job] == nil && !complete(job) {
                guard let media = sources[job.source] else { continue }
                if case .silence(let route) = job,
                   jobs[.waveform(route)] != nil || visibleOnlyWaveforms.contains(route) { continue }
                start(job, media: media)
            }
        }
        if useSidecars {
            for (id, media) in sources where pictureSourceIDs.contains(id) && media.hasVideo && sidecarPreference.permits(media.url)
                && !refreshStaleScenes.contains(id) && !isScanning(.scenes) {
                let job = Job.savedScenes(id)
                if jobs[job] == nil, issues[job] == nil, !complete(job) { start(job, media: media) }
            }
        }
    }

    private func cancelJob(_ job: Job) {
        jobs.removeValue(forKey: job)?.cancel()
        if case .waveform(let route) = job, !finishedWaves.contains(route) { waves[route] = nil }
    }

    private enum Result: Sendable {
        case waveform(AudioWaveform, SilenceAnalysisResult?)
        case silence(SilenceAnalysisResult)
        case scenes(SceneReport?)
    }

    private func persistMetadata(_ id: String, edits: EditorMetadataEdits) {
        metadata[id, default: EditorMetadataEdits()].update(edits, saved: false)
        guard useSidecars, let media = sources[id], sidecarPreference.permits(media.url),
              let version = sourceVersions[id] else { return }
        let previous = metadataWrite
        let snapshot = MulticamAnalysisSnapshot(scenes: sceneReports[id], edits: edits)
        let write = Task.detached(priority: .utility) { [sidecarPreference] in
            await previous?.value
            do {
                try AnalysisSidecar(media: media).save([:], updating: snapshot.metadataUpdates,
                                                     cancelled: { !sidecarPreference.permits(media.url) })
                return true
            } catch {
                return false
            }
        }
        let writeID = UUID()
        metadataWriteID = writeID
        metadataWrite = Task { [weak self] in
            let saved = await write.value
            guard let self else { return }
            if saved, self.sourceVersions[id] == version { self.metadata[id]?.discardSaved(edits) }
            if self.metadataWriteID == writeID {
                self.metadataWrite = nil
                self.metadataWriteID = nil
            }
        }
    }

    private func start(_ job: Job, media: MediaInfo) {
        let token = EditCancellation()
        jobs[job] = token
        let endWork = mcpReceipts[job.target]?.cleanup.begin()
        let useSidecars = useSidecars && sidecarPreference.permits(media.url)
        let minimum = inputPauseMinimum
        let threshold = pauseThreshold
        let cached: AudioWaveform?
        let roomThreshold: Double?
        let rescan: Bool
        if case .silence(let route) = job {
            cached = waves[route]
            roomThreshold = self.roomThreshold(for: route)
            rescan = pendingSilenceRescans.contains(route)
        } else if case .waveform(let route) = job {
            cached = nil
            roomThreshold = self.roomThreshold(for: route)
            rescan = false
        } else {
            cached = nil
            roomThreshold = nil
            rescan = false
        }
        EditorAnalysisQueues.scans.addOperation { [weak self] in
            defer {
                if let endWork { DispatchQueue.main.async { endWork() } }
            }
            guard !token.isCancelled else { return }
            func level(for route: MulticamAudioSelection) -> Double? {
                if let value = threshold ?? roomThreshold { return value }
                guard useSidecars else { return nil }
                return MulticamSilencePlanner.savedThreshold(for: media, stream: route.stream,
                                                            cancelled: { token.isCancelled })
            }
            let result = Swift.Result { () throws -> Result in
                switch job {
                case .waveform(let route):
                    let audioMedia = try media.extendingToAudioEnd(stream: route.stream)
                    let wave = try AudioAnalysis.scan(audioMedia, stream: route.stream, useSidecar: useSidecars,
                        cancelled: { token.isCancelled }) { partial in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.jobs[job] === token else { return }
                                self.waves[route] = partial
                                self.publish()
                            }
                        }
                    let level = level(for: route)
                    var saved = useSidecars ? AnalysisSidecar(media: audioMedia).silence(for: audioMedia, stream: route.stream,
                        thresholdDB: level, minimum: minimum, cancelled: { token.isCancelled }) : nil
                    if saved?.hasRouting == false {
                        saved = try AudioAnalysis.silence(audioMedia, stream: route.stream, thresholdDB: level,
                            minimum: minimum, waveform: wave, requireRouting: true, cancelled: { token.isCancelled })
                    }
                    return .waveform(wave, saved)
                case .silence(let route):
                    let audioMedia = try media.extendingToAudioEnd(stream: route.stream)
                    let detection = try AudioAnalysis.silence(audioMedia, stream: route.stream, thresholdDB: level(for: route),
                        minimum: minimum, waveform: cached, useSidecar: useSidecars && !rescan, requireRouting: true,
                        cancelled: { token.isCancelled })
                    if useSidecars && rescan {
                        let sections = try AnalysisSidecar.sections(media: audioMedia, silence: [detection],
                                                                     cancelled: { token.isCancelled })
                        AnalysisSidecar(media: audioMedia).saveAutomatically(sections, cancelled: { token.isCancelled })
                    }
                    return .silence(detection)
                case .savedScenes:
                    return .scenes(SceneAnalysis.lookup(media, useSidecar: useSidecars)?.report)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.jobs[job] === token else { return }
                self.jobs[job] = nil
                switch (job, result) {
                case (.waveform(let route), .success(.waveform(let waveform, let savedSilence))):
                    self.waves[route] = waveform
                    self.finishedWaves.insert(route)
                    if threshold == self.pauseThreshold, minimum == self.inputPauseMinimum,
                       roomThreshold == self.roomThreshold(for: route), let savedSilence {
                        self.silences[route] = savedSilence
                        self.updatePauses()
                    }
                case (.silence(let route), .success(.silence(let silence))):
                    self.silences[route] = silence
                    self.refreshStaleSilence.remove(route)
                    self.pendingSilenceRescans.remove(route)
                    self.updatePauses()
                case (.savedScenes(let id), .success(.scenes(let report))):
                    self.checkedSavedScenes.insert(id)
                    if let report { self.installSceneReport(report, for: id) }
                case (_, .failure(let error)): self.issues[job] = error.localizedDescription
                default: break
                }
                self.schedule()
                self.publish()
            }
        }
    }
}

extension MulticamAnalysisStore {
    var silenceResults: [MulticamAudioSelection: SilenceAnalysisResult] { silences }

    func hasSilenceResults(project: MulticamProject, media: [String: MediaInfo]) -> Bool {
        // A valid selected track can have no samples in a route's time window.
        !activeSilenceTracks.isEmpty && activeSilenceTracks.allSatisfy { silences[$0] != nil }
            && unindexedSilenceSources.isEmpty && !hasMissingSilenceTrack
    }

    func hasSilenceResults(in ranges: [MulticamRange]) -> Bool {
        func overlaps(_ group: MulticamRange) -> Bool {
            ranges.contains { $0.from < group.to && group.from < $0.to }
        }
        let selected = Set(groupIntervals.lazy.filter { overlaps($0.group) }.compactMap(\.audio))
        guard selected.allSatisfy({ route in
            sources[route.source]?.audio.contains { $0.stream.index == route.stream } == true
        }) else { return false }
        let covered = Set(activeRoutes.lazy.filter { overlaps($0.group) }.map(\.selection))
        return !covered.isEmpty && covered.allSatisfy { silences[$0] != nil }
    }

    func routedPauses(project: MulticamProject, media: [String: MediaInfo]) -> [AudioSpan] {
        groupPauses
    }

    private func updatePauses() {
        groupPauses = MulticamSilencePlanner.routedPauses(activeRoutes, silences: silences)
        routedSilenceMarkers = groupPauses.lazy.filter { ($0.to - $0.from).seconds >= self.pauseMinimum }
            .flatMap { [$0.from, $0.to] }
    }

    func markers(_ target: TimelineSnapTarget, project: MulticamProject, media: [String: MediaInfo]) -> [RationalTime] {
        switch target {
        case .off: return []
        case .silence: return routedSilenceMarkers
        case .scenes: return routedSceneMarkers
        case .keyframes: return routedKeyframeMarkers
        }
    }

    private func routedPictureMarkers(_ times: [String: [RationalTime]]) -> [RationalTime] {
        var result: [RationalTime] = []
        for span in groupPlan?.picture ?? [] {
            guard let offset = angleOffsets[span.source], let sourceTimes = times[span.source] else { continue }
            let lower = sourceTimes.lowerBound { $0 >= span.input.from }
            let upper = sourceTimes.lowerBound { $0 >= span.input.to }
            result.append(contentsOf: sourceTimes[lower..<upper].compactMap { try? $0.adding(offset) })
        }
        return result
    }

    static func outputMarkers(_ group: [RationalTime], in plan: MulticamPlan) -> [RationalTime] {
        var result: [RationalTime] = []
        for interval in plan.intervals {
            let lower = group.lowerBound { $0 >= interval.group.from }
            let upper = group.lowerBound { $0 >= interval.group.to }
            for time in group[lower..<upper] {
                guard let elapsed = try? time.subtracting(interval.group.from),
                      let output = try? interval.output.from.adding(elapsed) else { continue }
                result.append(output)
            }
            // A silence ending exactly at an occurrence edge remains a boundary there.
            if interval.output.to == plan.duration,
               upper < group.count, group[upper] == interval.group.to {
                result.append(interval.output.to)
            }
        }
        return result
    }
}
