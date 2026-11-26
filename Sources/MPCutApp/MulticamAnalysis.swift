import Combine
import Foundation
import MPCutCore

struct MulticamAnalysisAudioSpan {
    let laneID: String?
    let selection: MulticamAudioSelection
    let group: MulticamRange
    let input: MulticamRange
    let waveform: AudioWaveform?
}

struct MulticamAnalysisSnapshot: Sendable {
    var scenes: SceneReport?
    var waveforms: [Int: AudioWaveform] = [:]
    var silence: [SilenceAnalysisResult] = []

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
        let changeTime: SourceIdentity.ChangeTime?
        let origin: RationalTime
        let duration: RationalTime

        init(_ media: MediaInfo) {
            url = media.url
            identity = media.identity
            changeTime = media.identity.changeTime
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
    private var recordingsByCamera: [String: [String]] = [:]
    private var sourceVersions: [String: SourceVersion] = [:]
    private var presentationOffsets: [String: RationalTime] = [:]
    private var keyframes: [String: [RationalTime]] = [:]
    private var groupPlan: MulticamPlan?
    var groupIntervals: [MulticamInterval] { groupPlan?.intervals ?? [] }
    private var audioRouting = MulticamSilenceRouting()
    private var replacements: [MulticamAudioReplacement] = []
    private var routeIssue: String?
    private var routeReviewStreams: [URL: Set<Int>] = [:]
    private var routeIndexedSources: Set<String> = []
    var groupAudioLanes: [MulticamPlannedAudioLane] { audioRouting.lanes }
    private var activeRoutes: [MulticamSilenceRoute] { audioRouting.routes }
    // Prefix maxima keep the route lookup ordered when lane ends overlap.
    private var routeEndBounds: [RationalTime] = []

    private var activeSilenceTracks = Set<MulticamAudioSelection>()
    private var selectedSilenceTracks = Set<MulticamAudioSelection>()
    private var routedSceneMarkers: [RationalTime] = []
    private var tileSceneTimes: [String: [RationalTime]] = [:]
    private var routedTileSceneMarkers: [RationalTime] = []
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
        let requests = sceneRequests(camera: camera)
        let disposition = sceneScan.disposition(requests)
        if case .partial = disposition { return disposition }
        let stale = requests.contains { refreshStaleScenes.contains($0.id) }
        return stale ? .stale : disposition
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
    private var verifiedRelinks: [String: (candidate: ProjectMediaCandidate, originalStamp: SceneSourceStamp)] = [:]

    func carryVerifiedRelink(_ id: String, to candidate: ProjectMediaCandidate, original: MediaInfo) {
        verifiedRelinks[id] = (candidate, SceneSourceStamp(media: original))
    }

    func stageMediaRefresh(_ id: String, result: MediaRefreshResult) {
        pendingMediaRefresh[id] = result
    }

    func hasStaleSilence(_ id: String) -> Bool {
        refreshStaleSilence.contains { $0.source == id }
    }

    private var checkedSavedScenes = Set<String>()
    private var annotations = ProjectAnalysisAnnotations()
    var saveAnnotations: ((ProjectAnalysisAnnotations, String) -> Bool)?
    private var scenes: [String: [RationalTime]] = [:]
    private var useSidecars = true
    private var excludedSources = Set<URL>()
    private let sidecarPreference = SidecarPreference()
    private var requested = Set<TimelineSnapTarget>()
    /// Recordings added to the project whose automatic scene or pause scan has not started. Each starts once, when
    /// its media arrives. Cancelling a scan drops the ones still waiting, so a later update never starts them.
    private var automaticSceneScans = Set<String>()
    private var automaticPauseScans = Set<String>()
    /// The routes an automatic pause scan reads, while one runs: the routed sound of recordings just added. Nil while no
    /// scan runs and for a scan the editor, an agent or Snap to Silence started, which reads every routed track. When
    /// these routes finish the request ends, so a later routing change scans nothing on its own.
    private var automaticPauseRoutes: Set<MulticamAudioSelection>?
    var changed: (() -> Void)?
    private(set) var snapTarget: TimelineSnapTarget = .off
    var maxBlip = AudioWaveform.defaultMaxBlip {
        didSet {
            updatePauses()
            publish()
        }
    }
    private(set) var pauseMinimum = 1.5
    private(set) var pauseThreshold: Double?

    private var inputPauseMinimum: Double {
        MulticamSilencePlanner.inputMinimum(pauseMinimum, routes: activeRoutes)
    }

    private func routes(in range: MulticamRange) -> [MulticamSilenceRoute] {
        guard range.from < range.to else { return [] }
        let first = routeEndBounds.lowerBound { $0 > range.from }
        let end = activeRoutes.lowerBound { $0.group.from >= range.to }
        return activeRoutes[first..<end].filter { $0.group.to > range.from }
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
        if let routeIssue { return routeIssue }
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
        let first = routeEndBounds.lowerBound { atEnd ? $0 >= time : $0 > time }
        let end = activeRoutes.lowerBound { atEnd ? $0.group.from >= time : $0.group.from > time }
        let audible = activeRoutes[first..<end].filter {
            atEnd ? $0.group.to >= time : $0.group.to > time
        }
        if project.audio == .mix {
            let activeIDs = Set(audible.compactMap(\.laneID))
            let labels = groupAudioLanes.filter { activeIDs.contains($0.id) }.map(\.label)
            return labels.isEmpty ? "No audio here" : labels.joined(separator: " · ")
        }
        guard let selection = audible.first?.selection ?? onAir.audio else { return "None routed here" }
        let name = project.sources.first { $0.id == selection.source }?.displayName ?? selection.source
        let track = "\(name) · stream \(selection.stream)"
        guard !audible.isEmpty else { return "\(track) · no audio here" }
        if let result = silences[selection] {
            let level = result.thresholdDB.formatted(.number.precision(.fractionLength(0...1)))
            return "\(track) · \(level) dBFS threshold"
        }
        return track
    }

    /// The routes the pause scan reads: every routed track, or only those of a running automatic scan.
    private var scannedSilenceTracks: Set<MulticamAudioSelection> {
        automaticPauseRoutes.map { activeSilenceTracks.intersection($0) } ?? activeSilenceTracks
    }

    var silenceProgress: Double? {
        let routes = scannedSilenceTracks
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
        recordingsByCamera = [:]
        sourceVersions = [:]
        presentationOffsets = [:]
        keyframes = [:]
        groupPlan = nil
        audioRouting = .init()
        routeEndBounds = []
        replacements = []
        routeIssue = nil
        routeReviewStreams = [:]
        routeIndexedSources = []
        activeSilenceTracks = []
        selectedSilenceTracks = []
        angleOffsets = [:]
        routedSceneMarkers = []
        tileSceneTimes = [:]
        routedTileSceneMarkers = []
        routedKeyframeMarkers = []
        routedSilenceMarkers = []
        groupPauses = []
        requested = snapTarget == .silence ? [snapTarget] : []
        automaticSceneScans = []
        automaticPauseScans = []
        automaticPauseRoutes = nil
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
        verifiedRelinks = [:]
        checkedSavedScenes = []
        annotations = .init()
        scenes = [:]
        pauseThreshold = nil
    }

    func update(project: MulticamProject, media: [String: MediaInfo], ordinary: [String: MediaInfo], useSidecars: Bool,
                excludedSources: Set<URL> = [], reviewStreams: [URL: Set<Int>] = [:],
                reviewPicture: Set<URL> = []) {
        let refreshes = pendingMediaRefresh
        pendingMediaRefresh.removeAll()
        var next = ordinary.mapValues(SourceVersion.init)
        var offsets = media.mapValues(\.multicamClockOffset)
        var verifiedStamps: [String: SceneSourceStamp] = [:]
        if !verifiedRelinks.isEmpty {
            let files = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0.file) })
            for (id, relocation) in verifiedRelinks {
                guard files[id] == relocation.candidate.url.path else {
                    verifiedRelinks[id] = nil
                    continue
                }
                if let info = ordinary[id], info.url == relocation.candidate.url, info.hasFullEditIndex {
                    if relocation.candidate.matchesGeneration(of: info) { verifiedStamps[id] = relocation.originalStamp }
                    verifiedRelinks[id] = nil
                } else {
                    // The newly linked source may publish a header before its edit index.
                    // Keep old analysis dormant until the verified generation is indexed.
                    next[id] = sourceVersions[id]
                    offsets[id] = presentationOffsets[id]
                }
            }
        }
        let changedSources = next != sourceVersions || offsets != presentationOffsets || !refreshes.isEmpty || !verifiedStamps.isEmpty
        let nextPlan = try? project.plan(ranges: [project.range])
        let indexedSources = Set(media.compactMap { $0.value.hasFullEditIndex ? $0.key : nil })
        let changedRouting = groupPlan != nextPlan || replacements != project.audioReplacements
            || routeReviewStreams != reviewStreams || routeIndexedSources != indexedSources
        if (changedSources || changedRouting), mcpReceipts[.silence] != nil { cancel(.silence) }
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
        for id in Set(sourceVersions.keys).union(next.keys).union(refreshes.keys).union(verifiedStamps.keys)
            where sourceVersions[id] != next[id] || presentationOffsets[id] != offsets[id] || refreshes[id] != nil || verifiedStamps[id] != nil {
            if refreshes[id] != nil || verifiedStamps[id] != nil {
                for task in Array(jobs.keys) where task.source == id { cancelJob(task) }
                issues = issues.filter { $0.key.source != id }
                invalidateSceneScan(for: id)
                let result = refreshes[id]
                let report: SceneReport?
                if let stamp = verifiedStamps[id] {
                    report = [sceneReports[id], staleSceneReports[id]].compactMap { $0 }.first { $0.sourceStamp == stamp }
                } else {
                    report = sceneReports[id]
                }
                if result?.scenesPreserved ?? true, let info = ordinary[id], let report {
                    sceneReports[id] = report.forRefreshedMedia(info)
                    refreshStaleScenes.remove(id)
                    if verifiedStamps[id] != nil { staleSceneReports[id] = nil }
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
                let preserved = ordinary[id].map { media in
                    result?.preservedAudioStreams ?? Set(media.audio.map(\.stream.index))
                } ?? []
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
            scenes[id] = nil
            keyframes[id] = media[id]?.frames.lazy.filter(\.keyframe).map(\.time)
        }
        let annotationChange = annotations != project.analysisAnnotations
        annotations = project.analysisAnnotations
        let versions = Set(next.values)
        roomThresholds = roomThresholds.filter { versions.contains($0.key.version) }
        sourceVersions = next
        sources = ordinary
        recordingsByCamera = Dictionary(uniqueKeysWithValues: project.angles.map { ($0.id, $0.recordings.map(\.id)) })
        pictureSourceIDs = Set(project.pictureSources.compactMap { angle in
            guard let media = ordinary[angle.id], !reviewPicture.contains(media.url) else { return nil }
            return angle.id
        })
        sceneScan.pruneCheckpoints(keeping: Array(ordinary.values))
        presentationOffsets = offsets
        if changedSources || annotationChange {
            var thresholds: [SourceTrack: Double] = [:]
            for (id, info) in ordinary {
                if let reviewed = annotations.scene(for: info) {
                    if sceneReports[id] != reviewed { installSceneReport(reviewed, for: id) }
                } else if var report = sceneReports[id], report.views.contains(where: { $0.name != nil }) {
                    for view in report.views { report.setViewName(nil, for: view.view) }
                    installSceneReport(report, for: id)
                }
                if annotations.needsSceneReview(for: info) {
                    refreshStaleScenes.insert(id)
                }
                for stream in info.audio {
                    let level = annotations.threshold(for: info, stream: stream.stream.index)
                    thresholds[.init(version: .init(info), stream: stream.stream.index)] = level
                    if level == nil && annotations.silence.contains(where: { $0.file == info.url.path && $0.stream == stream.stream.index }) {
                        refreshStaleSilence.insert(.init(source: id, stream: stream.stream.index))
                    }
                }
            }
            if thresholds != roomThresholds || pauseThreshold != annotations.multicamThresholdDB {
                if !silences.isEmpty { requestSilenceAgain() }
                invalidateSilenceResults()
                roomThresholds = thresholds
                pauseThreshold = annotations.multicamThresholdDB
                updatePauses()
            }
        }
        let nextAngles = Dictionary(uniqueKeysWithValues: project.pictureSources.map { ($0.id, $0.offset) })
        let routesChanged = changedRouting || changedSources || angleOffsets != nextAngles
        if routesChanged {
            let oldMinimum = inputPauseMinimum
            groupPlan = nextPlan
            replacements = project.audioReplacements
            routeReviewStreams = reviewStreams
            routeIndexedSources = indexedSources
            routeIssue = nil
            do {
                audioRouting = try MulticamSilencePlanner.routing(plan: groupPlan, project: project, media: media,
                                                                  assumeUnindexedCoverage: true)[0] ?? .init()
            } catch {
                audioRouting = .init()
                audioRouting.selections = groupPlan.map { project.requiredAudioSelections(for: $0) } ?? []
                routeIssue = (error as? CutError)?.message ?? error.localizedDescription
            }
            let underReview = Set(audioRouting.selections.filter { route in
                guard let url = media[route.source]?.url else { return false }
                return reviewStreams[url]?.contains(route.stream) == true
            })
            let blockedRoutes = audioRouting.routes.filter { underReview.contains($0.selection) }
            audioRouting.unindexed += blockedRoutes.map(\.group)
            audioRouting.routes.removeAll { underReview.contains($0.selection) }
            var latestEnd = RationalTime.zero
            routeEndBounds = activeRoutes.map { route in
                latestEnd = max(latestEnd, route.group.to)
                return latestEnd
            }
            activeSilenceTracks = Set(activeRoutes.map(\.selection))
            visibleOnlyWaveforms.formUnion(activeSilenceTracks.filter { refreshes[$0.source] != nil })
            pendingSilenceRescans.formIntersection(activeSilenceTracks)
            selectedSilenceTracks = audioRouting.selections
            if refreshes.isEmpty, oldMinimum != inputPauseMinimum {
                if !silences.isEmpty { requestSilenceAgain() }
                invalidateSilenceResults()
            }
            angleOffsets = nextAngles
            routedSceneMarkers = routedPictureMarkers(scenes)
            routedKeyframeMarkers = routedPictureMarkers(keyframes)
            updatePauses()
        }
        let changesByRecording = Dictionary(project.participants.sources.map { ($0.sourceID, $0.layoutChangeTimes) },
                                            uniquingKeysWith: { first, _ in first })
        let nextTileSceneTimes = Dictionary(project.pictureSources.compactMap { source -> (String, [RationalTime])? in
            let id = source.id
            let recording = source.feedAngle?.sourceID ?? id
            guard pictureSourceIDs.contains(id), let changes = changesByRecording[recording],
                  !changes.isEmpty else { return nil }
            let shift = offsets[id] ?? offsets[recording] ?? .zero
            return (id, changes.compactMap { try? $0.adding(shift) })
        }, uniquingKeysWith: { first, _ in first })
        if routesChanged || tileSceneTimes != nextTileSceneTimes {
            tileSceneTimes = nextTileSceneTimes
            routedTileSceneMarkers = routedPictureMarkers(tileSceneTimes).compactMap { try? $0.adding(project.range.from) }
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
        startAutomaticScans()
    }

    /// Settings → Media & Analysis: scan the recordings just added to the project for scenes, pauses or both.
    func requestAutomaticScans(of ids: Set<String>, scenes: Bool, pauses: Bool) {
        if scenes { automaticSceneScans.formUnion(ids) }
        if pauses { automaticPauseScans.formUnion(ids) }
        startAutomaticScans()
    }

    /// The editor or an agent stopped a scan. Recordings still waiting for that automatic scan stay unscanned.
    func dropAutomaticScans(_ target: TimelineSnapTarget) {
        switch target {
        case .scenes: automaticSceneScans.removeAll()
        case .silence: automaticPauseScans.removeAll()
        case .off, .playhead, .keyframes: break
        }
    }

    var hasAutomaticScansWaiting: Bool { !automaticSceneScans.isEmpty || !automaticPauseScans.isEmpty }

    private func startAutomaticScans() {
        let pauses = automaticPauseScans.filter { sources[$0] != nil }
        if !pauses.isEmpty {
            automaticPauseScans.subtract(pauses)
            // The pause scan reads the program's routed microphones of these recordings only, never a recording already
            // in the project, so a scan the editor cancelled stays cancelled.
            let routes = activeSilenceTracks.filter { pauses.contains($0.source) }
            if !routes.isEmpty { scanAutomatically(routes) }
        }
        guard !isScanning(.scenes) else { return }
        let scenes = automaticSceneScans.filter { sources[$0] != nil }
        guard !scenes.isEmpty else { return }
        automaticSceneScans.subtract(scenes)
        let requests = scenes.sorted().compactMap { id -> EditorSceneRequest? in
            guard pictureSourceIDs.contains(id), let media = sources[id], media.hasVideo, sceneReports[id] == nil else { return nil }
            return EditorSceneRequest(id: id, media: media)
        }
        runSceneRequests(requests, camera: nil, policy: .reuse)
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

    func sourceScenes(_ id: String) -> [RationalTime] {
        mergedSceneTimes(scenes[id] ?? partialScenes[id] ?? [], tileSceneTimes[id] ?? [])
    }

    private func mergedSceneTimes(_ visual: [RationalTime], _ tiles: [RationalTime]) -> [RationalTime] {
        guard !tiles.isEmpty else { return visual }
        return Array(Set(visual + tiles)).sorted()
    }

    struct ScenePosition {
        let source: String
        let report: SceneReport
        let index: Int

        var view: Int { report.scenes[index].view }
        var defaultName: String { "View \(SceneView.label(for: view))" }
        var name: String? { report.views.first { $0.view == view }?.name }
    }

    func currentScene(at groupTime: RationalTime, project: MulticamProject) -> ScenePosition? {
        guard let angle = project.selection(at: groupTime)?.angle,
              let source = project.pictureSource(for: angle, at: groupTime) else { return nil }
        return currentScene(at: groupTime, angle: source.id, exclusiveEnd: false)
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

    @discardableResult
    func rename(_ scene: ScenePosition, to text: String) -> Bool {
        guard let report = sceneReports[scene.source], report.sourceStamp == scene.report.sourceStamp,
              report.file == scene.report.file,
              let view = report.views.first(where: { $0.view == scene.view }),
              view.sceneNumbers == scene.report.views.first(where: { $0.view == scene.view })?.sceneNumbers else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : trimmed
        guard view.name != name else { return true }
        var reviewed = report
        reviewed.setViewName(name, for: scene.view)
        var next = annotations
        guard let media = sources[scene.source], next.setScene(reviewed, for: media) else { return false }
        guard saveAnnotations?(next, "Rename Scene View") != false else { return false }
        annotations = next
        if let stored = next.scene(for: media) { reviewed = stored }
        installSceneReport(reviewed, for: scene.source)
        publish()
        return true
    }

    func soundtrack(in visible: MulticamRange) -> [MulticamAnalysisAudioSpan] {
        routes(in: visible).map { route in
            MulticamAnalysisAudioSpan(laneID: route.laneID, selection: route.selection, group: route.group,
                                      input: route.input, waveform: waves[route.selection])
        }
    }

    func snapshot(for media: MediaInfo) -> MulticamAnalysisSnapshot {
        let version = SourceVersion(media)
        var snapshot = MulticamAnalysisSnapshot()
        for (id, candidate) in sourceVersions where candidate == version {
            snapshot.scenes = snapshot.scenes ?? sceneReports[id]
            for route in finishedWaves where route.source == id { snapshot.waveforms[route.stream] = waves[route] }
            snapshot.silence += silences.filter { $0.key.source == id }.map(\.value)
        }
        return snapshot
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
        // The menu command, an agent and room tone read every routed track.
        automaticPauseRoutes = nil
        requested.insert(target)
        schedule()
        publish()
    }

    /// Asks for the pause scan again after a change invalidated its results. A running automatic scan keeps to its own
    /// routes and the routes that had results; otherwise every routed track is read, as before.
    private func requestSilenceAgain() {
        if automaticPauseRoutes != nil { automaticPauseRoutes?.formUnion(silences.keys) }
        requested.insert(.silence)
    }

    /// The automatic pause scan of recordings just added: only their routed tracks.
    private func scanAutomatically(_ routes: Set<MulticamAudioSelection>) {
        if requested.contains(.silence) {
            // A scan the editor started, or Snap to Silence, already reads every routed track.
            guard automaticPauseRoutes != nil else { return }
            automaticPauseRoutes?.formUnion(routes)
        } else {
            automaticPauseRoutes = routes
        }
        issues = issues.filter { issue in
            switch issue.key {
            case .waveform(let route), .silence(let route): return !routes.contains(route)
            default: return true
            }
        }
        visibleOnlyWaveforms.subtract(routes)
        requested.insert(.silence)
        schedule()
        publish()
    }

    /// Ends an automatic pause scan once each of its routes has results or an issue. The request goes with it, so a
    /// later routing change starts nothing.
    private func finishAutomaticPauseScan() {
        guard let scope = automaticPauseRoutes else { return }
        let routes = activeSilenceTracks.intersection(scope)
        let done = routes.allSatisfy { route in
            jobs[.silence(route)] == nil && jobs[.waveform(route)] == nil
                && (complete(.silence(route)) || issues[.silence(route)] != nil || issues[.waveform(route)] != nil)
        }
        guard done else { return }
        automaticPauseRoutes = nil
        if snapTarget != .silence { requested.remove(.silence) }
    }

    func canScanScenes(camera: String?) -> Bool {
        !isScanning(.scenes) && !sceneRequests(camera: camera).isEmpty
    }

    private func sceneRequests(camera: String?) -> [EditorSceneRequest] {
        let ids = camera.map { recordingsByCamera[$0] ?? [$0] } ?? pictureSourceIDs.sorted()
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
        receipt.cancelNative = { [weak self] in
            self?.dropAutomaticScans(.scenes)
            self?.cancel(.scenes)
        }
        sceneScan.start(requests, policy: policy, preference: sidecarPreference,
                        receipt: receipt, update: { [weak self] in
            guard let self else { return }
            if self.sceneScan.progress == nil {
                if self.mcpReceipts[.scenes] === receipt { self.mcpReceipts[.scenes] = nil }
                self.schedule()
                // A recording added during the scan waits for it to finish.
                if !self.automaticSceneScans.isEmpty {
                    Task { @MainActor [weak self] in self?.startAutomaticScans() }
                }
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
        if let media = sources[id], let saved = annotations.scene(for: media), saved != report {
            if saved.scenes != report.scenes { refreshStaleScenes.insert(id) }
            return
        }
        checkedSavedScenes.insert(id)
        if let media = sources[id], annotations.needsSceneReview(for: media) { refreshStaleScenes.insert(id) }
        else { refreshStaleScenes.remove(id) }
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

    func discardClearedAnalysis(for ids: Set<String>, whole: Bool) {
        for job in Array(jobs.keys) where ids.contains(job.source) { cancelJob(job) }
        for id in ids {
            invalidateSceneScan(for: id)
            if let media = sources[id], let report = annotations.scene(for: media) {
                installSceneReport(report, for: id)
            } else {
                sceneReports[id] = nil
                scenes[id] = nil
            }
            staleSceneReports[id] = nil
        }
        let routes = Set(waves.keys).union(silences.keys).union(activeSilenceTracks).filter { ids.contains($0.source) }
        for route in routes {
            waves[route] = nil
            silences[route] = nil
            finishedWaves.remove(route)
            pendingSilenceRescans.remove(route)
            visibleOnlyWaveforms.insert(route)
            waveformDetail.refresh(route, media: sources[route.source], preserving: [], visibleOnly: true)
        }
        routedSceneMarkers = routedPictureMarkers(scenes)
        updatePauses()
        publish()
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
        if target == .silence {
            pendingSilenceRescans.removeAll()
            automaticPauseRoutes = nil
        }
        for job in Array(jobs.keys) where job.target == target { cancelJob(job) }
        publish()
    }

    func setSnap(_ target: TimelineSnapTarget) {
        snapTarget = target
        if target == .silence {
            // Snap to Silence reads every routed track.
            automaticPauseRoutes = nil
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
            if activeSilenceTracks.contains(where: { silences[$0] != nil }) { requestSilenceAgain() }
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
            guard silenceRoutesAvailable(in: [range]) else { return nil }
            for route in routes(in: range) {
                guard finishedWaves.contains(route.selection), let track = sourceTrack(for: route.selection),
                      let wave = waves[route.selection],
                      let peak = route.roomTonePeak(in: MulticamSilencePlanner.span(range), waveform: wave) else { return nil }
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
        var next = annotations
        next.multicamThresholdDB = nil
        for (track, measurement) in peaks {
            let threshold = AudioAnalysis.roomToneThresholdDB(forPeak: measurement.peak)
            guard let media = sources[measurement.source], next.setThreshold(threshold, for: media, stream: track.stream) else { return false }
        }
        guard saveAnnotations?(next, "Set Room Tone") != false else { return false }
        annotations = next
        if mcpReceipts[.silence] != nil { cancel(.silence) }
        for (track, measurement) in peaks {
            roomThresholds[track] = AudioAnalysis.roomToneThresholdDB(forPeak: measurement.peak)
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
        case .silence: return scannedSilenceTracks.map(Job.silence)
        case .playhead, .scenes, .keyframes: return []
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
        finishAutomaticPauseScan()
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

    private func start(_ job: Job, media: MediaInfo) {
        let token = EditCancellation()
        jobs[job] = token
        let endWork = mcpReceipts[job.target]?.cleanup.begin()
        let useSidecars = useSidecars && sidecarPreference.permits(media.url)
        let media = useSidecars ? media.pinningSidecarWrites() : media
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
            // A rename can change ctime without changing the recording. Reinspect only at job startup;
            // the decoder, published waveform and sidecar keep the resulting live snapshot.
            var input = media
            func checkedInput(for route: MulticamAudioSelection) throws -> MediaInfo {
                if let current = try? SourceIdentity(media.url), current == media.identity,
                   !current.matchesSnapshot(media.identity) {
                    let refresh = try MediaRefresh.check(media.url, previous: media, verification: .deep, persist: false,
                                                         cancelled: { token.isCancelled })
                    guard let fresh = refresh.media, fresh.identity.matchesSnapshot(current),
                          refresh.preservedAudioStreams.contains(route.stream), !refresh.reviewStreams.contains(route.stream) else {
                        throw CutError(code: "source_changed", message: "The audio source changed since inspection.")
                    }
                    input = media.multicamClockOffset > .zero ? try CutEngine(useSidecar: false).multicamClock(fresh) : fresh
                }
                return try input.extendingToAudioEnd(stream: route.stream)
            }
            let result = Swift.Result { () throws -> Result in
                switch job {
                case .waveform(let route):
                    let audioMedia = try checkedInput(for: route)
                    let wave = try AudioAnalysis.scan(audioMedia, stream: route.stream, useSidecar: useSidecars,
                        cancelled: { token.isCancelled }) { partial in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.jobs[job] === token, audioMedia.identity.isCurrentSnapshot(at: audioMedia.url) else { return }
                                self.waves[route] = partial
                                self.publish()
                            }
                        }
                    let level = threshold ?? roomThreshold
                    let saved = useSidecars ? AnalysisSidecar(media: audioMedia).silence(for: audioMedia, stream: route.stream,
                        thresholdDB: level, minimum: minimum, cancelled: { token.isCancelled }) : nil
                    return .waveform(wave, saved)
                case .silence(let route):
                    let audioMedia = try checkedInput(for: route)
                    let detection = try AudioAnalysis.silence(audioMedia, stream: route.stream, thresholdDB: threshold ?? roomThreshold,
                        minimum: minimum, waveform: cached, useSidecar: useSidecars && !rescan,
                        cancelled: { token.isCancelled })
                    if useSidecars && rescan {
                        AnalysisSidecar(media: audioMedia).saveAutomatically(
                            try AnalysisSidecar.sections(media: audioMedia, silence: [detection], cancelled: { token.isCancelled }),
                            cancelled: { token.isCancelled })
                    }
                    return .silence(detection)
                case .savedScenes:
                    return .scenes(SceneAnalysis.lookup(media, useSidecar: useSidecars, includePartial: false)?.report)
                }
            }
            let inspected = input
            DispatchQueue.main.async { [weak self] in
                guard let self, self.jobs[job] === token else { return }
                self.jobs[job] = nil
                let publishable = result.flatMap { value -> Swift.Result<Result, Error> in
                    if case .scenes = value { return .success(value) }
                    guard inspected.identity.isCurrentSnapshot(at: inspected.url) else {
                        return .failure(CutError(code: "source_changed", message: "The audio source changed during analysis."))
                    }
                    return .success(value)
                }
                switch (job, publishable) {
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
                    if !self.annotations.needsThresholdReview(for: inspected, stream: route.stream) {
                        self.refreshStaleSilence.remove(route)
                    }
                    self.pendingSilenceRescans.remove(route)
                    self.updatePauses()
                case (.savedScenes(let id), .success(.scenes(let report))):
                    self.checkedSavedScenes.insert(id)
                    if let report { self.installSceneReport(report, for: id) }
                case (_, .failure(let error)):
                    if case .waveform(let route) = job { self.waves[route] = nil }
                    self.issues[job] = error.localizedDescription
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
        !activeSilenceTracks.isEmpty && activeSilenceTracks.allSatisfy { complete(.silence($0)) }
            && audioRouting.unindexed.isEmpty && routeIssue == nil && unindexedSilenceSources.isEmpty && !hasMissingSilenceTrack
    }

    private func silenceRoutesAvailable(in ranges: [MulticamRange]) -> Bool {
        routeIssue == nil && !audioRouting.unindexed.contains { missing in
            ranges.contains { $0.from < missing.to && missing.from < $0.to }
        }
    }

    func hasSilenceResults(in ranges: [MulticamRange]) -> Bool {
        guard silenceRoutesAvailable(in: ranges) else { return false }
        let covered = Set(ranges.flatMap { routes(in: $0).map(\.selection) })
        return !covered.isEmpty && covered.allSatisfy { complete(.silence($0)) }
    }

    func routedPauses(project: MulticamProject, media: [String: MediaInfo]) -> [AudioSpan] {
        groupPauses
    }

    private func updatePauses() {
        groupPauses = silences.isEmpty ? [] : audioRouting.pauses(silences: silences, maxBlip: maxBlip)
        routedSilenceMarkers = groupPauses.lazy.filter { ($0.to - $0.from).seconds >= self.pauseMinimum }
            .flatMap { [$0.from, $0.to] }
    }

    func markers(_ target: TimelineSnapTarget, project: MulticamProject, media: [String: MediaInfo]) -> [RationalTime] {
        switch target {
        case .off: return []
        case .silence: return routedSilenceMarkers
        case .scenes: return mergedSceneTimes(routedSceneMarkers, routedTileSceneMarkers)
        case .playhead: return []
        case .keyframes: return routedKeyframeMarkers
        }
    }

    func pictureSnapMarkers(_ target: TimelineSnapTarget, angle: String, project: MulticamProject,
                            near time: RationalTime, within range: MulticamRange, includeEnd: Bool) -> [RationalTime] {
        return project.recordings(for: angle).flatMap { recording -> [RationalTime] in
            let coverageEnd = min(project.range.to, recording.coverage?.to ?? project.range.to)
            let inclusive = includeEnd && range.to < coverageEnd
            guard pictureSourceIDs.contains(recording.id),
                  let requested = try? time.subtracting(recording.offset),
                  let lower = try? max(project.range.from, range.from, recording.coverage?.from ?? range.from).subtracting(recording.offset),
                  let upper = try? min(range.to, coverageEnd).subtracting(recording.offset)
            else { return [] }
            let local = target == .scenes
                ? mergedSceneTimes(scenes[recording.id] ?? [], tileSceneTimes[recording.id] ?? [])
                : keyframes[recording.id] ?? []
            let first = local.lowerBound { $0 >= lower }
            let last = local.lowerBound { inclusive ? $0 > upper : $0 >= upper }
            guard first < last else { return [] }
            let next = local[first..<last].lowerBound { $0 >= requested }
            return [next - 1, next].filter { first <= $0 && $0 < last }.compactMap { index in
                try? local[index].adding(recording.offset)
            }
        }.sorted()
    }

    private func routedPictureMarkers(_ times: [String: [RationalTime]]) -> [RationalTime] {
        pictureMarkers(times, in: groupPlan?.picture ?? [])
    }

    func pictureOutputMarkers(_ target: TimelineSnapTarget, in plan: MulticamPlan) -> [RationalTime] {
        switch target {
        case .scenes:
            return mergedSceneTimes(pictureMarkers(scenes, in: plan.picture), pictureMarkers(tileSceneTimes, in: plan.picture))
        case .keyframes: return pictureMarkers(keyframes, in: plan.picture)
        default: return []
        }
    }

    func hasPictureMarker(_ target: TimelineSnapTarget, in plan: MulticamPlan) -> Bool {
        func containsMarker(_ times: [String: [RationalTime]]) -> Bool {
            plan.picture.contains { span in
                guard pictureSourceIDs.contains(span.source), let local = times[span.source] else { return false }
                let index = local.lowerBound { $0 >= span.input.from }
                return index < local.count && local[index] < span.input.to
            }
        }
        if target == .scenes { return containsMarker(scenes) || containsMarker(tileSceneTimes) }
        return containsMarker(keyframes)
    }

    private func pictureMarkers(_ times: [String: [RationalTime]], in spans: [MulticamSpan]) -> [RationalTime] {
        var result: [RationalTime] = []
        for span in spans {
            guard pictureSourceIDs.contains(span.source), let sourceTimes = times[span.source],
                  let offset = try? span.output.from.subtracting(span.input.from) else { continue }
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
