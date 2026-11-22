import CoreFoundation
import Foundation
import MPCutCore

private typealias AnalysisObject = [String: Any]

struct MCPSceneRequest: Equatable {
    let target: String?
    let policy: SceneScanPolicy
    let interval: SceneScanScope?

    init(target: String?, policy: SceneScanPolicy, interval: SceneScanScope? = nil) {
        self.target = target
        self.policy = policy
        self.interval = interval
    }

    var policyName: String {
        switch policy {
        case .resume: return "resume"
        case .restart: return "restart"
        case .reuse: return "reuse"
        }
    }
}

func mcpSceneCoverage(_ coverage: [String: SceneScanProgress]) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(coverage),
          let result = (try? JSONSerialization.jsonObject(with: data)) as? AnalysisObject else { return [:] }
    return result
}

private func unavailable(_ reason: String) -> MCPCommandError {
    MCPCommandError("analysis_unavailable", reason)
}

private func badInput(_ reason: String) -> MCPCommandError {
    MCPCommandError("invalid_arguments", reason)
}

private func number(_ value: Any?, field: String) throws -> Double {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
        throw badInput("Supply a finite number for \(field).")
    }
    return n.doubleValue
}

private func integer(_ value: Any?, field: String, range: ClosedRange<Int>) throws -> Int {
    let raw = try number(value, field: field)
    guard let n = Int(exactly: raw), range.contains(n) else { throw badInput("Invalid \(field).") }
    return n
}

private func page<T>(_ items: [T], _ args: AnalysisObject, transform: (T) -> AnalysisObject) throws -> AnalysisObject {
    let offset = try integer(args["offset"] ?? 0, field: "offset", range: 0...Int.max)
    let limit = try integer(args["limit"] ?? 100, field: "limit", range: 1...500)
    guard offset <= items.count else { throw badInput("Offset exceeds the result count.") }
    let end = offset + min(limit, items.count - offset)
    return ["items": items[offset..<end].map(transform), "offset": offset, "total": items.count]
}

private func span(_ value: AudioSpan) -> AnalysisObject {
    ["from": value.from.description, "to": value.to.description]
}

private func scenePage(_ report: SceneReport, source: String, args: AnalysisObject,
                       interval: (RationalTime, RationalTime)? = nil, staleReason: String? = nil) throws -> AnalysisObject {
    let names = Dictionary(uniqueKeysWithValues: report.views.compactMap { view in view.name.map { (view.view, $0) } })
    let scenes = interval.map { start, end in report.scenes.filter { $0.start < end && $0.end > start } } ?? report.scenes
    var result = try page(scenes, args) { scene in
        var row: AnalysisObject = ["number": scene.number, "from": scene.start.description, "to": scene.end.description,
                                   "view": scene.view, "label": scene.viewLabel]
        row["name"] = names[scene.view]
        return row
    }
    result["source"] = source
    result["clock"] = "source"
    if let staleReason {
        result["stale"] = true
        result["staleReason"] = staleReason
        result["sourceStamp"] = ["bytes": report.sourceStamp.bytes,
                                 "modifiedSeconds": report.sourceStamp.modifiedSeconds,
                                 "modifiedNanoseconds": report.sourceStamp.modifiedNanoseconds]
    }
    return result
}

private func analysisTime(_ args: AnalysisObject, _ key: String, or fallback: Double) throws -> Double {
    guard let supplied = args[key] else { return fallback }
    guard let text = supplied as? String, let value = try? RationalTime(parsing: text) else {
        throw badInput("Supply a rational timestamp for \(key).")
    }
    return value.seconds
}

private struct WaveformWindow {
    let from: Double
    let to: Double
    let columns: Int

    init(_ args: AnalysisObject, duration: RationalTime) throws {
        from = try analysisTime(args, "from", or: 0)
        to = try analysisTime(args, "to", or: duration.seconds)
        guard from >= 0, from < to, to <= duration.seconds else { throw badInput("Choose a window within the source.") }
        columns = try integer(args["columns"] ?? 100, field: "columns", range: 1...2048)
    }

    func peaks(in waveform: AudioWaveform) -> [Any] {
        let width = (to - from) / Double(columns)
        return (0..<columns).map {
            let next = $0 == columns - 1 ? to : from + width * Double($0 + 1)
            let peak = waveform.peak(from: from + width * Double($0), to: next)
            return peak.map { $0 as Any } ?? NSNull()
        }
    }
}

private func checkAnalysisSource(_ media: MediaInfo) throws {
    guard (try? SourceIdentity(media.url)) == media.identity else {
        throw MCPCommandError("source_changed", "The source changed since indexing. Refresh project media before reading analysis.")
    }
}

@MainActor
extension ProjectSessions {
    func mcpAnalysis(tool: String, arguments args: [String: Any], session: ProjectSession,
                     checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        let read = ["analysis_job_status", "analysis_state", "list_pauses", "list_scenes", "get_waveform_peaks", "get_waveform"]
        let write = ["analysis_job_cancel", "scan_analysis", "cancel_analysis", "refresh_project_media", "configure_silence", "use_room_tone", "rename_view",
                     "review_pause", "set_skip_pauses", "apply_pauses", "save_analysis_sidecars"]
        guard read.contains(tool) || write.contains(tool) else { return nil }
        try checkAccess()
        let editor = session.editor, multi = session.multicam, mc = session.isMulticam
        let source = args["source"] as? String
        let uuid = source.flatMap { UUID(uuidString: $0) }
        func sourceMedia() -> MediaInfo? {
            mc ? source.flatMap(multi.ordinaryAnalysisMedia) : uuid.flatMap { editor.analysisSourceMedia[$0] }
        }
        func storedSceneReport() -> SceneReport? {
            mc ? source.flatMap { multi.analysis.sceneReports[$0] } : uuid.flatMap { editor.sceneReports[$0] }
        }
        func sceneReport() throws -> SceneReport {
            guard let media = sourceMedia() else { throw unavailable("Choose an indexed source from analysis_state.") }
            try checkAnalysisSource(media)
            guard let report = storedSceneReport(), report.sourceStamp == SceneSourceStamp(media: media) else {
                throw unavailable("Scan scenes for this source and read analysis_state.")
            }
            return report
        }
        let reviewOpen = mc ? multi.pauseEdits.review != nil : editor.cutPreview != nil
        let canEdit = session.window?.attachedSheet == nil && !reviewOpen
            && (mc ? (multi.project != nil && !multi.isBusy && multi.notice == nil) : editor.canEdit && !editor.mcpHasActiveTrim)
        switch tool {
        case "analysis_job_status", "analysis_job_cancel":
            let receipt = try mcpAnalysisJobs.lookup(args["job"] as? String, session: session)
            if tool == "analysis_job_cancel" { receipt.cancel() }
            return receipt.snapshot
        case "refresh_project_media":
            if let active = mc ? multi.mcpRefreshReceipt : editor.mcpRefreshReceipt, active.state == "running" {
                throw MCPCommandError("busy", "A project media refresh is running. Read analysis_state for progress.")
            }
            guard session.window?.attachedSheet == nil, !reviewOpen,
                  mc ? multi.canRefreshProjectMedia : editor.canRefreshProjectMedia && !editor.mcpHasActiveTrim else {
                throw unavailable("Project media refresh is unavailable. Inspect analysis_state.")
            }
            let receipt = try mcpAnalysisJobs.reserve(session: session, kind: "refresh")
            let deep = args["deep"] as? Bool ?? false
            if mc {
                multi.refreshProjectMedia(deep: deep, receipt: receipt)
            } else {
                editor.refreshProjectMedia(deep: deep, receipt: receipt)
            }
            return receipt.snapshot
        case "analysis_state":
            var state: AnalysisObject = ["kind": mc ? "multicam" : "sequence",
                                         "minimumPause": mc ? multi.analysis.pauseMinimum : editor.minimumPause,
                                         "leavePause": mc ? multi.preferences.leavePause : editor.leavePause,
                                         "skipPauses": mc ? multi.pauseEdits.skip : editor.skipPauses,
                                         "sceneScanning": mc ? multi.analysis.isScanning(.scenes) : editor.sceneProgress != nil,
                                         "silenceReady": mc ? multi.canApplyPauses : editor.pauseAnalysisReady]
            state["sceneProgress"] = mc ? multi.analysis.sceneProgress : editor.sceneProgress
            state["sceneStatus"] = mc ? multi.analysis.sceneStatus : editor.sceneStatus
            state["sceneCoverage"] = mcpSceneCoverage(mc ? multi.analysis.sceneCoverage : editor.sceneCoverage)
            state["selectedSceneClip"] = mc ? nil : editor.sceneClipID?.uuidString
            state["selectedSceneCamera"] = mc ? multi.selectedSceneCamera : nil
            state["mediaRefreshProgress"] = mc ? multi.mediaRefreshProgress : editor.mediaRefreshProgress
            state["mediaRefreshIssues"] = mc ? multi.mediaRefreshIssues : editor.mediaRefreshIssues
            state["silenceProgress"] = mc ? multi.analysis.silenceProgress : editor.silenceProgress
            state["manualThresholdDB"] = mc ? multi.analysis.pauseThreshold : editor.manualThresholdDB
            state["silenceIssue"] = mc ? multi.analysis.silenceIssue : editor.silenceIssue
            state["status"] = mc ? (multi.analysis.status ?? multi.status) : editor.statusMessage
            state["issue"] = mc ? multi.notice?.message : editor.alert?.message
            let sources = mc ? multi.media : Dictionary(uniqueKeysWithValues: editor.analysisSourceMedia.map { ($0.key.uuidString, $0.value) })
            state["sources"] = try page(sources.keys.sorted(), args) { id in
                let media = sources[id]!
                let indexed = mc ? multi.ordinaryAnalysisMedia(id) != nil : media.hasFullEditIndex
                var row: AnalysisObject = ["source": id, "path": media.url.path, "indexed": indexed,
                                           "audioStreams": media.streams.filter { $0.kind == "audio" }.map(\.index)]
                if !mc, let id = UUID(uuidString: id), let ordinal = editor.sourceAnalysisTracks[id] {
                    row["analysisTrackOrdinal"] = ordinal
                    row["manualThresholdDB"] = editor.analysisThreshold(for: id, track: ordinal)
                }
                return row
            }
            if !mc {
                state["analysisTrackOrdinal"] = editor.playheadAnalysisTrack
                state["followSourceAudio"] = editor.useSavedMonitoringTracks
                state["analysisSource"] = editor.analysisPlayheadSourceID?.uuidString
            }
            return state
        case "list_pauses":
            if mc {
                guard multi.canApplyPauses else { throw unavailable("Complete the program silence scan first.") }
                return try page(multi.multicamPausePlan, args) { pause in
                    ["id": mcpPauseID(pause, revision: session.mcpRevision), "occurrence": pause.id.occurrence, "clock": "group",
                     "range": span(pause.visible), "removal": pause.removal.map { span($0) as Any } ?? NSNull(),
                     "protected": pause.isProtected]
                }
            }
            guard editor.pauseAnalysisReady else { throw unavailable("Complete the sequence silence scan first.") }
            return try page(editor.pausePlan, args) { pause in
                ["id": mcpPauseID(pause, revision: session.mcpRevision), "clock": "sequence",
                 "occurrence": pause.key.source.occurrence.uuidString, "range": span(pause.sequence),
                 "removal": pause.removal.map { span($0) as Any } ?? NSNull(), "protected": pause.isProtected]
            }
        case "list_scenes":
            let includeStale = args["includeStale"] as? Bool ?? false
            let issues = mc ? multi.mediaRefreshIssues : editor.mediaRefreshIssues
            func staleReason(_ id: String) -> String { issues[id] ?? "The recording changed after scene analysis." }
            if let clip = args["clip"] as? String {
                guard !mc, source == nil, let id = UUID(uuidString: clip) else {
                    throw badInput("Choose a sequence clip ID or a source ID.")
                }
                guard let bounds = editor.mcpOccurrence(id) else {
                    throw unavailable("Choose a clip from get_editor_state.")
                }
                let archived = includeStale ? editor.staleSceneReport(clipID: id) : nil
                guard let (sourceID, report) = archived ?? editor.sceneReport(clipID: id) else {
                    throw unavailable("Scan scenes for this clip first.")
                }
                var stale = archived != nil
                if !stale {
                    do {
                        guard let media = editor.analysisSourceMedia[sourceID] else { throw unavailable("The clip’s source is offline.") }
                        try checkAnalysisSource(media)
                        guard report.sourceStamp == SceneSourceStamp(media: media) else {
                            throw unavailable("The clip’s scene analysis is out of date.")
                        }
                    } catch where includeStale {
                        stale = true
                    }
                }
                let source = sourceID.uuidString
                var result = try scenePage(report, source: source, args: args, interval: (bounds.start, bounds.end),
                                           staleReason: stale ? staleReason(source) : nil)
                result["clip"] = id.uuidString
                return result
            }
            let id = (mc ? source : uuid?.uuidString) ?? ""
            if includeStale, let archived = mc ? multi.analysis.staleSceneReports[id] : uuid.flatMap({ editor.staleSceneReports[$0] }) {
                return try scenePage(archived, source: id, args: args, staleReason: staleReason(id))
            }
            let report: SceneReport
            do {
                report = try sceneReport()
            } catch {
                guard includeStale, let previous = storedSceneReport() else { throw error }
                return try scenePage(previous, source: id, args: args, staleReason: staleReason(id))
            }
            return try scenePage(report, source: id, args: args)
        case "get_waveform", "get_waveform_peaks":
            guard let source, let info = sourceMedia(), info.hasFullEditIndex else {
                throw unavailable("Choose an indexed source from analysis_state.")
            }
            let stream = try integer(args["stream"], field: "stream", range: 0...Int(Int32.max))
            guard info.streams.contains(where: { $0.kind == "audio" && $0.index == stream }) else {
                throw badInput("Select an audio stream in this source.")
            }
            let id = mc ? source : uuid?.uuidString ?? source
            if tool == "get_waveform_peaks" {
                try checkAnalysisSource(info)
                let wave = mc ? multi.analysis.completedWaveform(sourceID: id, stream: stream)
                    : uuid.flatMap { editor.audioStore.completedWaveforms(for: $0, media: info)[stream] }
                guard let wave else { throw unavailable("A completed peak waveform for this source and stream is unavailable.") }
                let window = try WaveformWindow(args, duration: wave.duration)
                return ["source": id, "clock": "source", "stream": stream, "fromSeconds": window.from, "toSeconds": window.to,
                        "peaks": window.peaks(in: wave), "binsPerSecond": AudioWaveform.rate]
            }
            let media = try info.extendingToAudioEnd(stream: stream)
            let window = try WaveformWindow(args, duration: media.duration)
            let exclusions = mc ? multi.sidecarExclusions : editor.sidecarExclusions
            let useSidecar = preferences.useAnalysisSidecars && !AnalysisSidecar.isExcluded(media.url, in: exclusions)
            let envelope: AudioEnvelope
            do {
                envelope = try await mcpAnalysisJobs.waveform(owner: session.mcpHandle) { token in
                    try AudioAnalysis.envelope(media, stream: stream, from: window.from, to: window.to, columns: window.columns,
                                               useSidecar: useSidecar, cancelled: { token.isCancelled })
                }
            } catch {
                try checkAccess()
                throw error
            }
            try checkAccess()
            guard let current = sourceMedia(), current.url == info.url,
                  AudioAnalysisCacheKey(media: current, stream: stream) == AudioAnalysisCacheKey(media: info, stream: stream) else {
                throw MCPCommandError("source_changed", "The project's source changed. Refresh analysis_state.")
            }
            return ["source": id, "clock": "source", "stream": stream, "fromSeconds": envelope.from, "toSeconds": envelope.to,
                    "low": envelope.low, "high": envelope.high]
        case "scan_analysis", "cancel_analysis":
            guard let value = args["kind"] as? String, ["scenes", "silence"].contains(value) else {
                throw badInput("Specify scenes or silence.")
            }
            let target: TimelineSnapTarget = value == "scenes" ? .scenes : .silence
            let running = mc ? multi.analysis.isScanning(target) : (target == .scenes ? editor.sceneProgress : editor.silenceProgress) != nil
            if tool == "cancel_analysis" {
                guard running else { return ["status": "idle"] }
                let sceneWorker = mc ? multi.analysis.mcpReceipts[.scenes] : editor.mcpSceneReceipt
                if target == .scenes, let sceneWorker { sceneWorker.cancel() }
                else if mc { multi.cancelAnalysis(target) }
                else if target == .scenes { editor.cancelSceneAnalysis() }
                else { editor.cancelSilenceScan() }
                return ["status": "cancel_requested"]
            }
            var sceneRequest: MCPSceneRequest?
            var clipID: UUID?
            var camera: String?
            if target == .scenes {
                let scope = args["scope"] as? String ?? "all"
                guard ["all", "selected"].contains(scope) else {
                    throw badInput("Specify all or selected scope.")
                }
                let explicit = args["target"] as? String
                if scope == "selected" {
                    if mc { camera = explicit ?? multi.selectedSceneCamera }
                    else if let explicit {
                        guard let parsed = UUID(uuidString: explicit) else { throw badInput("Supply a sequence clip UUID.") }
                        clipID = parsed
                    } else { clipID = editor.sceneClipID }
                    guard clipID != nil || camera != nil else { throw unavailable("Select an eligible clip or camera.") }
                } else if explicit != nil {
                    throw badInput("Use a target only with selected scope.")
                }
                let policy: SceneScanPolicy
                switch args["policy"] as? String ?? "reuse" {
                case "reuse": policy = .reuse
                case "resume": policy = .resume
                case "restart":
                    guard let operationID = args["operationID"] as? String, !operationID.isEmpty else {
                        throw badInput("Supply an operationID for the restart.")
                    }
                    policy = .restart(operationID: operationID)
                default: throw badInput("Specify reuse, resume or restart policy.")
                }
                let bounds = clipID.flatMap(editor.mcpOccurrence)
                let interval = bounds.map { SceneScanScope.range(start: $0.start, end: $0.end) }
                sceneRequest = MCPSceneRequest(target: camera ?? clipID?.uuidString, policy: policy, interval: interval)
            } else if args["scope"] != nil || args["target"] != nil || args["policy"] != nil {
                throw badInput("Scope, target and policy apply to scene scans.")
            }
            let existing = mc ? multi.analysis.mcpReceipts[target] : (target == .scenes ? editor.mcpSceneReceipt : editor.mcpSilenceReceipt)
            if running {
                if let existing, let sceneRequest, let active = existing.sceneRequest,
                   !existing.cancellationRequested, existing.owner.isEmpty || existing.revision == session.mcpRevision {
                    if active == sceneRequest {
                        let subscriber = try mcpAnalysisJobs.reserve(session: session, kind: value)
                        existing.subscribe(subscriber)
                        return subscriber.snapshot
                    }
                    let selectedSource = camera ?? clipID.flatMap(editor.mcpSceneSource(for:))
                    if active.target == nil, active.policy == .reuse, sceneRequest.policy == .reuse,
                       let selected = sceneRequest.target, let selectedSource,
                       let coverage = existing.sceneCoverage?()[selectedSource] {
                        let interval = sceneRequest.interval
                        let withinSource: Bool
                        if case let .range(start, end)? = interval {
                            withinSource = start >= .zero && end > start
                                && (coverage.requestedThrough ?? clipID.flatMap(editor.mcpOccurrence)?.sourceDuration ?? .zero) >= end
                        } else {
                            withinSource = mc
                        }
                        if withinSource {
                            let subscriber = try mcpAnalysisJobs.reserve(session: session, kind: value)
                            existing.subscribe(subscriber, selection: MCPSceneSelection(source: selectedSource, target: selected, interval: interval))
                            return subscriber.snapshot
                        }
                    }
                }
                if let existing, sceneRequest == nil { return existing.snapshot }
                if existing == nil, args["scope"] == nil, args["policy"] == nil {
                    return ["status": "running", "origin": "editor"]
                }
                throw MCPCommandError("busy", "A different scan is running. Read analysis_state for its progress.")
            }
            guard canEdit else { throw unavailable("Finish the current operation or dismiss the editor’s message.") }
            let canStart: Bool
            if sceneRequest != nil {
                canStart = mc ? multi.analysis.canScanScenes(camera: camera) : editor.canScanScenes(clipID: clipID)
            } else {
                canStart = mc ? multi.canScanAnalysis(target) || multi.canApplyPauses : editor.canScanSilence
            }
            guard canStart else { throw unavailable("No eligible sources to scan. Inspect analysis_state or available reports.") }
            let subscriber = try mcpAnalysisJobs.reserve(session: session, kind: value)
            let receipt: MCPAnalysisReceipt
            if let sceneRequest {
                receipt = MCPAnalysisReceipt(owner: session.mcpHandle, revision: session.mcpRevision, kind: value)
                receipt.sceneRequest = sceneRequest
                receipt.subscribe(subscriber)
            } else {
                receipt = subscriber
            }
            if let sceneRequest {
                if mc {
                    multi.analysis.mcpReceipts[.scenes] = receipt
                    multi.analysis.scanScenes(camera: camera, policy: sceneRequest.policy)
                } else {
                    editor.mcpSceneReceipt = receipt
                    editor.scanForScenes(clipID: clipID, policy: sceneRequest.policy)
                }
            } else if mc {
                multi.analysis.mcpReceipts[target] = receipt
                receipt.cancelNative = { [weak multi, weak receipt] in
                    guard let multi, let receipt, multi.analysis.mcpReceipts[target] === receipt else { return }
                    multi.cancelAnalysis(target)
                }
                receipt.nativeProgress = { [weak multi] in multi?.analysis.silenceProgress }
                if multi.canScanAnalysis(target) {
                    multi.scanAnalysis(target)
                } else {
                    multi.analysis.rescanSilence()
                }
            } else {
                editor.mcpSilenceReceipt = receipt
                receipt.cancelNative = { [weak editor, weak receipt] in
                    guard let editor, let receipt, editor.mcpSilenceReceipt === receipt else { return }
                    editor.cancelSilenceScan()
                }
                receipt.nativeProgress = { [weak editor] in editor?.silenceProgress }
                editor.scanForSilence()
            }
            return subscriber.snapshot
        default: break
        }

        guard canEdit || (tool == "review_pause" && reviewOpen) else {
            throw unavailable("Finish the current operation or dismiss the editor’s message.")
        }
        switch tool {
        case "configure_silence":
            try configureAnalysis(args, session: session)
        case "use_room_tone":
            guard mc ? multi.useRoomTone() : editor.useRoomTone() else {
                throw unavailable("Mark a range with measured audio on the selected tracks.")
            }
        case "rename_view":
            guard let name = args["name"] as? String, name.utf8.count <= 1024 else {
                throw badInput("Choose an analyzed source and supply a view name up to 1024 bytes.")
            }
            let report = try sceneReport()
            let view = try integer(args["view"], field: "view", range: 1...Int.max)
            guard let index = report.scenes.firstIndex(where: { $0.view == view }) else { throw unavailable("This view is unavailable.") }
            if mc, let source { multi.analysis.rename(.init(source: source, report: report, index: index), to: name) }
            else if let uuid { editor.setViewName(name, source: uuid, view: view) }
        case "review_pause":
            return try reviewPause(args, session: session)
        case "set_skip_pauses":
            guard let value = args["enabled"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw badInput("Supply a boolean for enabled.")
            }
            if value.boolValue && !(mc ? multi.pauseEdits.skip : editor.skipPauses) {
                let canSkip = mc ? (multi.assemblyPreview ? multi.multicamPausePlan : multi.multicamPausePlan(forPlayback: true)).contains(where: { $0.removal != nil })
                                 : editor.pauseAnalysisReady && editor.shortenedPauseCount > 0
                guard canSkip else { throw unavailable("Scan for pauses first.") }
            }
            if mc { multi.pauseEdits.skip = value.boolValue } else { editor.skipPauses = value.boolValue }
        case "apply_pauses":
            guard let mode = args["mode"] as? String, ["shorten", "queue"].contains(mode) else { throw badInput("Specify shorten or queue.") }
            let queue = mode == "queue"
            let revision = session.mcpRevision
            if mc {
                guard multi.applyMulticamPauses(queueTakes: queue, plan: multi.multicamPausePlan) else {
                    throw unavailable(multi.notice?.message ?? "No removable pauses are available.")
                }
            } else {
                guard editor.applyPauses(queueTakes: queue) else {
                    throw unavailable(editor.alert?.message ?? "No removable pauses are available.")
                }
            }
            let changed = session.mcpRevision != revision
            var result: AnalysisObject = ["mode": mode, "queueCount": mc ? multi.queuedRanges.count : editor.queuedRanges.count,
                                          "changed": changed, "historyRetained": changed && preferences.historyLimit > 0]
            if changed { result["warning"] = mc ? multi.notice?.message : editor.alert?.message }
            return result
        case "save_analysis_sidecars":
            guard mc ? multi.canSaveSidecars : editor.canSaveAnalysisSidecars else { throw unavailable("Wait for source indexing.") }
            let receipt = try mcpAnalysisJobs.reserve(session: session, kind: "sidecars")
            if mc { multi.mcpSidecarReceipt = receipt; multi.saveAnalysisSidecars() }
            else { editor.mcpSidecarReceipt = receipt; editor.saveAnalysisSidecars() }
            if let issue = mc ? multi.notice?.message : editor.alert?.message {
                receipt.finish("failed", detail: ["error": issue])
                if mc { multi.mcpSidecarReceipt = nil } else { editor.mcpSidecarReceipt = nil }
            }
            return receipt.snapshot
        default: return nil
        }
        return ["status": "applied"]
    }
}

@MainActor
private func configureAnalysis(_ args: AnalysisObject, session: ProjectSession) throws {
    let editor = session.editor, multi = session.multicam, mc = session.isMulticam
    guard ["trackOrdinal", "minimumPause", "leavePause", "thresholdDB"].contains(where: { args[$0] != nil }) else {
        throw badInput("Supply at least one analysis setting.")
    }
    let track: Int? = try args["trackOrdinal"].map { value in
        guard !mc && !editor.audioTracks.isEmpty else { throw badInput("Only sequences support selecting a track ordinal.") }
        return try integer(value, field: "trackOrdinal", range: 0...(editor.audioTracks.count - 1))
    }
    let minimum = try args["minimumPause"].map { try number($0, field: "minimumPause") }
    let leave = try args["leavePause"].map { try number($0, field: "leavePause") }
    let manual = try args["thresholdDB"].flatMap { $0 is NSNull ? nil : try number($0, field: "thresholdDB") }
    if args["source"] != nil && (mc || args["thresholdDB"] == nil) {
        throw badInput("Choose a source only when setting a sequence threshold.")
    }
    guard minimum.map({ $0 >= 1 / Double(AudioWaveform.rate) && $0 <= 86400 }) ?? true,
          leave.map({ (0...86400).contains($0) }) ?? true, manual.map({ (-120...0).contains($0) }) ?? true else {
        throw badInput("Check pause length, padding and threshold ranges.")
    }
    if mc {
        if minimum != nil || args["thresholdDB"] != nil {
            multi.configureSilenceAnalysis(minimum: minimum ?? multi.analysis.pauseMinimum,
                                           threshold: args["thresholdDB"] == nil ? multi.analysis.pauseThreshold : manual)
        }
        if let leave { multi.preferences.leavePause = leave }
    } else {
        var thresholdSource: UUID?
        if args["thresholdDB"] != nil {
            if let supplied = args["source"] {
                thresholdSource = (supplied as? String).flatMap(UUID.init(uuidString:))
                guard thresholdSource != nil else { throw badInput("Supply a sequence source ID from analysis_state.") }
            } else { thresholdSource = editor.analysisPlayheadSourceID }
            guard let thresholdSource, editor.hasAnalysisTrack(track ?? editor.sourceAnalysisTracks[thresholdSource] ?? editor.analysisTrack, in: thresholdSource) else {
                throw unavailable("The threshold source has no indexed audio on the selected track.")
            }
        }
        if let track { editor.chooseAnalysisTrack(track) }
        if let minimum { editor.minimumPause = minimum }
        if let leave { editor.leavePause = leave }
        if let thresholdSource { editor.setAnalysisThreshold(manual, for: thresholdSource) }
    }
}

private func mcpPauseID(_ pause: TimelinePause, revision: Int) -> String {
    "\(revision):\(pause.key.source.occurrence.uuidString):\(pause.key.source.track):\(pause.key.span.from):\(pause.key.span.to):\(pause.sequence.from):\(pause.sequence.to)"
}

private func mcpPauseID(_ pause: MulticamPauseEdit, revision: Int) -> String {
    "\(revision):\(pause.id.occurrence):\(pause.id.span.from):\(pause.id.span.to):\(pause.visible.from):\(pause.visible.to)"
}

@MainActor
private func reviewPause(_ args: AnalysisObject, session: ProjectSession) throws -> AnalysisObject {
    guard let action = args["action"] as? String else { throw badInput("Specify a review action.") }
    let editor = session.editor, multi = session.multicam, mc = session.isMulticam
    if action == "done" {
        if mc { multi.pauseEdits.review = nil } else { editor.cutPreview = nil }
    } else if ["nextCut", "keepAndAdvance"].contains(action) {
        guard !mc && editor.cutPreview != nil else { throw unavailable("Open a sequence cut preview first.") }
        editor.advanceCutPreview(keepingCurrent: action == "keepAndAdvance")
    } else {
        guard ["seek", "preview", "protect", "unprotect"].contains(action), let id = args["pause"] as? String else {
            throw badInput("Supply a pause ID from list_pauses and a review action.")
        }
        if mc {
            guard let pause = multi.multicamPausePlan.first(where: { mcpPauseID($0, revision: session.mcpRevision) == id }) else {
                throw unavailable("Refresh list_pauses.")
            }
            if let review = multi.pauseEdits.review {
                guard action == "protect", review.id == pause.id else {
                    throw unavailable("Close the current cut preview first.")
                }
                multi.setPauseProtection(true, for: pause)
                multi.pauseEdits.review = nil
                return ["reviewOpen": false]
            }
            if action == "preview" {
                multi.reviewMulticamPause(pause)
                guard multi.pauseEdits.review != nil else { throw unavailable("This join cannot be previewed.") }
            } else if action == "seek" { multi.seekMulticamPause(pause) }
            else { multi.setPauseProtection(action == "protect", for: pause) }
        } else {
            guard editor.cutPreview == nil, editor.pauseAnalysisReady,
                  let pause = editor.pausePlan.first(where: { mcpPauseID($0, revision: session.mcpRevision) == id }) else {
                throw unavailable("Close the cut preview and refresh list_pauses.")
            }
            editor.seek(pause.sequence.from.seconds)
            guard editor.currentPause.map({ mcpPauseID($0, revision: session.mcpRevision) }) == id else {
                throw unavailable("Refresh the pause selection.")
            }
            if action == "preview" {
                editor.previewCurrentCut()
                guard editor.cutPreview != nil else { throw unavailable("This join cannot be previewed.") }
            } else if action != "seek" && pause.isProtected != (action == "protect") { editor.protectCurrentPause() }
        }
    }
    return ["reviewOpen": mc ? multi.pauseEdits.review != nil : editor.cutPreview != nil]
}
