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
    guard let data = try? MCPSchemas.encodeResult(coverage),
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
    guard let n = value.flatMap(mcpInteger), range.contains(n) else { throw badInput("Invalid \(field).") }
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
    result["source_id"] = source
    result["clock"] = "source"
    result["report_id"] = report.reviewID(scope: interval.map { .range(start: $0.0, end: $0.1) } ?? .fullSource)
    if let staleReason {
        result["stale"] = true
        result["stale_reason"] = staleReason
        result["source_stamp"] = ["bytes": report.sourceStamp.bytes,
                                 "modified_seconds": report.sourceStamp.modifiedSeconds,
                                 "modified_nanoseconds": report.sourceStamp.modifiedNanoseconds]
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
        from = try analysisTime(args, "source_from", or: 0)
        to = try analysisTime(args, "source_to", or: duration.seconds)
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
        let read = ["analysis_job_status_read", "analysis_editor_state_read", "silence_editor_pauses_list", "silence_editor_take_candidates_list", "scenes_editor_boundaries_list", "waveform_editor_peaks_read", "waveform_editor_envelope_read"]
        let write = ["analysis_job_cancel", "scenes_editor_scan", "silence_editor_scan", "scenes_editor_scan_cancel", "silence_editor_scan_cancel", "project_editor_media_refresh", "silence_editor_track_select", "silence_editor_threshold_set", "silence_threshold_calibrate_from_marks", "scenes_view_rename",
                     "silence_editor_pause_review", "silence_editor_take_boundary_edit", "timeline_editor_join_preview", "playback_pause_skipping_set", "silence_editor_pauses_shorten", "silence_editor_takes_queue", "analysis_editor_sidecars_save"]
        guard read.contains(tool) || write.contains(tool) else { return nil }
        try checkAccess()
        let editor = session.editor, multi = session.multicam, mc = session.isMulticam
        let source = args["source_id"] as? String
        let uuid = source.flatMap { UUID(uuidString: $0) }
        func sourceMedia() -> MediaInfo? {
            mc ? source.flatMap(multi.ordinaryAnalysisMedia) : uuid.flatMap { editor.analysisSourceMedia[$0] }
        }
        func storedSceneReport() -> SceneReport? {
            mc ? source.flatMap { multi.analysis.sceneReports[$0] } : uuid.flatMap { editor.sceneReports[$0] }
        }
        func sceneReport() throws -> SceneReport {
            guard let media = sourceMedia() else { throw unavailable("Choose an indexed source from analysis_editor_state_read.") }
            try checkAnalysisSource(media)
            guard let report = storedSceneReport(), report.sourceStamp == SceneSourceStamp(media: media) else {
                throw unavailable("Scan scenes for this source and read analysis_editor_state_read.")
            }
            return report
        }
        let reviewOpen = mc ? multi.pauseEdits.review != nil : editor.cutPreview != nil
        let canEdit = session.window?.attachedSheet == nil && !reviewOpen
            && (mc ? (multi.project != nil && !multi.isBusy && multi.notice == nil) : editor.canEdit && !editor.mcpHasActiveTrim)
        switch tool {
        case "analysis_job_status_read", "analysis_job_cancel":
            let receipt = try mcpAnalysisJobs.lookup(args["job_id"] as? String, session: session)
            if tool == "analysis_job_cancel" { receipt.cancel() }
            return receipt.snapshot
        case "project_editor_media_refresh":
            if let active = mc ? multi.mcpRefreshReceipt : editor.mcpRefreshReceipt, active.state == "running" {
                throw MCPCommandError("busy", "A project media refresh is running. Read analysis_editor_state_read for progress.")
            }
            guard session.window?.attachedSheet == nil, !reviewOpen,
                  mc ? multi.canRefreshProjectMedia : editor.canRefreshProjectMedia && !editor.mcpHasActiveTrim else {
                throw unavailable("Project media refresh is unavailable. Inspect analysis_editor_state_read.")
            }
            let receipt = try mcpAnalysisJobs.reserve(session: session, kind: "refresh")
            receipt.completionDetail = { [weak session] in
                guard let session, let rows = try? session.mcpMediaStatusSnapshot() else { return [:] }
                return ["media": rows]
            }
            let deep = args["deep"] as? Bool ?? false
            if mc {
                multi.refreshProjectMedia(deep: deep, receipt: receipt)
            } else {
                editor.refreshProjectMedia(deep: deep, receipt: receipt)
            }
            return receipt.snapshot
        case "analysis_editor_state_read":
            var state: AnalysisObject = ["kind": mc ? "multicam" : "sequence",
                                         "silence_max_blip_seconds": mc ? multi.analysis.maxBlip : editor.preferences.maxBlip,
                                         "silence_min_pause_seconds": mc ? multi.analysis.pauseMinimum : editor.minimumPause,
                                         "silence_padding_per_side_seconds": mc ? multi.preferences.padding : editor.padding,
                                         "skip_pauses": mc ? multi.pauseEdits.skip : editor.skipPauses,
                                         "scene_scanning": mc ? multi.analysis.isScanning(.scenes) : editor.sceneProgress != nil,
                                         "silence_ready": mc ? multi.canApplyPauses : editor.pauseAnalysisReady]
            state["scene_progress"] = mc ? multi.analysis.sceneProgress : editor.sceneProgress
            state["scene_status"] = mc ? multi.analysis.sceneStatus : editor.sceneStatus
            state["scene_coverage"] = mcpSceneCoverage(mc ? multi.analysis.sceneCoverage : editor.sceneCoverage)
            state["selected_scene_clip"] = mc ? nil : editor.sceneClipID?.uuidString
            state["selected_scene_camera"] = mc ? multi.selectedSceneCamera : nil
            state["media_refresh_progress"] = mc ? multi.mediaRefreshProgress : editor.mediaRefreshProgress
            state["media_refresh_issues"] = mc ? multi.mediaRefreshIssues : editor.mediaRefreshIssues
            state["silence_progress"] = mc ? multi.analysis.silenceProgress : editor.silenceProgress
            state["manual_threshold_db"] = mc ? multi.analysis.pauseThreshold : editor.manualThresholdDB
            state["silence_issue"] = mc ? multi.analysis.silenceIssue : editor.silenceIssue
            state["status"] = mc ? (multi.analysis.status ?? multi.status) : editor.statusMessage
            state["issue"] = mc ? multi.notice?.message : editor.alert?.message
            let sources = mc ? multi.media : Dictionary(uniqueKeysWithValues: editor.analysisSourceMedia.map { ($0.key.uuidString, $0.value) })
            state["sources"] = try page(sources.keys.sorted(), args) { id in
                let media = sources[id]!
                let indexed = mc ? multi.ordinaryAnalysisMedia(id) != nil : media.hasFullEditIndex
                var row: AnalysisObject = ["source_id": id, "path": media.url.path, "indexed": indexed,
                                           "audio_stream_indices": media.streams.filter { $0.kind == "audio" }.map(\.index)]
                if !mc, let id = UUID(uuidString: id), let ordinal = editor.sourceAnalysisTracks[id] {
                    row["analysis_track_ordinal"] = ordinal
                    row["manual_threshold_db"] = editor.analysisThreshold(for: id, track: ordinal)
                }
                return row
            }
            if !mc {
                state["analysis_track_ordinal"] = editor.playheadAnalysisTrack
                state["follow_source_audio"] = editor.useSavedMonitoringTracks
                state["analysis_source_id"] = editor.analysisPlayheadSourceID?.uuidString
            }
            return state
        case "silence_editor_pauses_list":
            if mc {
                guard multi.canApplyPauses else { throw unavailable("Complete the program silence scan first.") }
                return try page(multi.multicamPausePlan, args) { pause in
                    ["id": mcpPauseID(pause, revision: session.mcpPauseListingRevision), "occurrence": pause.id.occurrence, "clock": "group",
                     "range": span(pause.visible), "removal": pause.removal.map { span($0) as Any } ?? NSNull(),
                     "protected": pause.isProtected, "retained_seconds": pause.retainedSeconds,
                     "requested_retained_seconds": pause.requestedRetainedSeconds.map { $0 as Any } ?? NSNull()]
                }
            }
            guard editor.pauseAnalysisReady else { throw unavailable("Complete the sequence silence scan first.") }
            return try page(editor.pausePlan, args) { pause in
                ["id": mcpPauseID(pause, revision: session.mcpPauseListingRevision), "clock": "sequence",
                 "occurrence": pause.key.source.occurrence.uuidString, "range": span(pause.sequence),
                 "removal": pause.removal.map { span($0) as Any } ?? NSNull(), "protected": pause.isProtected,
                 "retained_seconds": pause.retainedSeconds,
                 "requested_retained_seconds": pause.requestedRetainedSeconds.map { $0 as Any } ?? NSNull()]
            }
        case "silence_editor_take_candidates_list":
            guard mc ? multi.canApplyPauses : editor.pauseAnalysisReady else { throw unavailable("Complete the silence scan first.") }
            let candidates = mc ? multi.multicamTakeCandidates(plan: multi.multicamPausePlan) : editor.takeCandidates
            var result = try page(candidates, args) { candidate in
                ["range": span(candidate.range), "manual_start": candidate.hasManualStart]
            }
            result["clock"] = mc ? "assembly" : "sequence"
            return result
        case "scenes_editor_boundaries_list":
            let includeStale = args["include_stale"] as? Bool ?? false
            let issues = mc ? multi.mediaRefreshIssues : editor.mediaRefreshIssues
            func staleReason(_ id: String) -> String { issues[id] ?? "The recording changed after scene analysis." }
            if let clip = args["clip_id"] as? String {
                guard !mc, source == nil, let id = UUID(uuidString: clip) else {
                    throw badInput("Choose a sequence clip ID or a source ID.")
                }
                guard let bounds = editor.mcpOccurrence(id) else {
                    throw unavailable("Choose a clip from project_editor_state_read.")
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
                result["clip_id"] = id.uuidString
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
        case "waveform_editor_envelope_read", "waveform_editor_peaks_read":
            guard let source, let info = sourceMedia(), info.hasFullEditIndex else {
                throw unavailable("Choose an indexed source from analysis_editor_state_read.")
            }
            let stream = try integer(args["audio_stream_index"], field: "audio_stream_index", range: 0...Int(Int32.max))
            guard info.streams.contains(where: { $0.kind == "audio" && $0.index == stream }) else {
                throw badInput("Select an audio stream in this source.")
            }
            let id = mc ? source : uuid?.uuidString ?? source
            if tool == "waveform_editor_peaks_read" {
                try checkAnalysisSource(info)
                let wave = mc ? multi.analysis.completedWaveform(sourceID: id, stream: stream)
                    : uuid.flatMap { editor.audioStore.completedWaveforms(for: $0, media: info)[stream] }
                guard let wave else { throw unavailable("A completed peak waveform for this source and stream is unavailable.") }
                let window = try WaveformWindow(args, duration: wave.duration)
                return ["source_id": id, "clock": "source", "audio_stream_index": stream, "source_from_seconds": window.from, "source_to_seconds": window.to,
                        "peaks": window.peaks(in: wave), "bins_per_second": AudioWaveform.rate]
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
                throw MCPCommandError("source_changed", "The project's source changed. Refresh analysis_editor_state_read.")
            }
            return ["source_id": id, "clock": "source", "audio_stream_index": stream, "source_from_seconds": envelope.from, "source_to_seconds": envelope.to,
                    "low": envelope.low, "high": envelope.high]
        case "scenes_editor_scan", "silence_editor_scan", "scenes_editor_scan_cancel", "silence_editor_scan_cancel":
            let value = tool.hasPrefix("scenes_") ? "scenes" : "silence"
            let target: TimelineSnapTarget = value == "scenes" ? .scenes : .silence
            let running = mc ? multi.analysis.isScanning(target) : (target == .scenes ? editor.sceneProgress : editor.silenceProgress) != nil
            if tool.hasSuffix("_cancel") {
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
                    if let issue = clipID.flatMap(editor.mcpClipMediaIssue) {
                        throw MCPCommandError("source_needs_review", issue)
                    }
                } else if explicit != nil {
                    throw badInput("Use a target only with selected scope.")
                }
                let policy: SceneScanPolicy
                switch args["policy"] as? String ?? "reuse" {
                case "reuse": policy = .reuse
                case "resume": policy = .resume
                case "restart":
                    guard let operationID = args["operation_id"] as? String, !operationID.isEmpty else {
                        throw badInput("Supply an operation_id for the restart.")
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
                throw MCPCommandError("busy", "A different scan is running. Read analysis_editor_state_read for its progress.")
            }
            guard canEdit else { throw unavailable("Finish the current operation or dismiss the editor’s message.") }
            let canStart: Bool
            if sceneRequest != nil {
                canStart = mc ? multi.analysis.canScanScenes(camera: camera) : editor.canScanScenes(clipID: clipID)
            } else {
                canStart = mc ? multi.canScanAnalysis(target) || multi.canApplyPauses : editor.canScanSilence
            }
            guard canStart else { throw unavailable("No eligible sources to scan. Inspect analysis_editor_state_read or available reports.") }
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

        guard canEdit || (tool == "silence_editor_pause_review" && reviewOpen) else {
            throw unavailable("Finish the current operation or dismiss the editor’s message.")
        }
        switch tool {
        case "silence_editor_track_select":
            guard !mc, !editor.audioTracks.isEmpty else { throw badInput("Select an audio track in an open sequence.") }
            let ordinal = try integer(args["track_ordinal"], field: "track_ordinal", range: 0...(editor.audioTracks.count - 1))
            editor.chooseAnalysisTrack(ordinal)
        case "silence_editor_threshold_set":
            try setAnalysisThreshold(args, session: session)
        case "silence_threshold_calibrate_from_marks":
            guard mc ? multi.useRoomTone() : editor.useRoomTone() else {
                throw unavailable("Mark a range with measured audio on the selected tracks.")
            }
        case "scenes_view_rename":
            guard let name = args["name"] as? String, name.utf8.count <= 1024,
                  let reportID = args["report_id"] as? String else {
                throw badInput("Supply a full-source scene report ID and a view name up to 1024 bytes.")
            }
            let report = try sceneReport()
            guard report.coversFullSource, report.reviewID() == reportID else {
                throw MCPCommandError("stale_scene_report", "Read the full-source scene boundaries and use their report ID.")
            }
            let view = try integer(args["view"], field: "view", range: 1...Int.max)
            guard let index = report.scenes.firstIndex(where: { $0.view == view }) else { throw unavailable("This view is unavailable.") }
            let applied: Bool
            if mc, let source { applied = multi.analysis.rename(.init(source: source, report: report, index: index), to: name) }
            else if let uuid { applied = editor.setViewName(name, source: uuid, view: view) }
            else { applied = false }
            guard applied else { throw unavailable("Could not save the scene view name for this recording.") }
        case "silence_editor_pause_review":
            return try reviewPause(args, session: session)
        case "timeline_editor_join_preview":
            let clock: String
            let position: RationalTime
            let targets = ["before_clip_id", "before_occurrence", "switch_time"].filter { args[$0] != nil }
            guard targets.count == 1 else { throw badInput("Specify one join target.") }
            if mc, let switchTime = args["switch_time"] as? String {
                let requested = try RationalTime(parsing: switchTime)
                guard multi.previewMulticamSwitch(at: requested), let join = multi.pauseEdits.review?.position else {
                    throw unavailable("Choose an existing switch inside the group.")
                }
                clock = "group"
                position = join
            } else if mc, args["before_occurrence"] != nil {
                let index = try integer(args["before_occurrence"], field: "before_occurrence", range: 0...Int.max)
                guard multi.previewMulticamAssemblyJoin(before: index), let join = multi.pauseEdits.review?.position else {
                    throw unavailable("Choose the assembly occurrence on the right side of an existing join.")
                }
                clock = "assembly"
                position = join
            } else if !mc, let id = args["before_clip_id"] as? String,
                      editor.previewExistingJoin(beforeTimelineItem: id), let cut = editor.cutPreview {
                clock = "sequence"
                position = cut.position
            } else {
                throw badInput("Choose a sequence clip ID, multicam assembly index, or multicam switch time in its project.")
            }
            return ["review_open": true, "position": position.description, "clock": clock]
        case "silence_editor_take_boundary_edit":
            guard let exact = args["position"] as? String, let action = args["action"] as? String else {
                throw badInput("Supply a position and a take-boundary action.")
            }
            let position = try RationalTime(parsing: exact)
            let changed: Bool
            if mc { changed = multi.editMulticamTakeBoundary(at: position, add: action == "add") }
            else {
                changed = action == "add" ? editor.addTakeBoundary(at: position.seconds)
                    : editor.removeTakeBoundary(at: position)
            }
            guard changed else { throw unavailable("Choose an interior cut point or a manual start from the take candidates.") }
            return ["total": mc ? multi.multicamTakeCandidates(plan: multi.multicamPausePlan).count : editor.takeCandidates.count]
        case "playback_pause_skipping_set":
            guard let value = args["enabled"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw badInput("Supply a boolean for enabled.")
            }
            if value.boolValue && !(mc ? multi.pauseEdits.skip : editor.skipPauses) {
                let canSkip = mc ? (multi.assemblyPreview ? multi.multicamPausePlan : multi.multicamPausePlan(forPlayback: true)).contains(where: { $0.removal != nil })
                                 : editor.pauseAnalysisReady && editor.shortenedPauseCount > 0
                guard canSkip else { throw unavailable("Scan for pauses first.") }
            }
            if mc { multi.pauseEdits.skip = value.boolValue } else { editor.skipPauses = value.boolValue }
        case "silence_editor_pauses_shorten", "silence_editor_takes_queue":
            let mode = tool == "silence_editor_takes_queue" ? "queue" : "shorten"
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
            var result: AnalysisObject = ["mode": mode, "queue_count": mc ? multi.queuedRanges.count : editor.queuedRanges.count,
                                          "changed": changed, "history_retained": changed && preferences.historyLimit > 0]
            if changed { result["warning"] = mc ? multi.notice?.message : editor.alert?.message }
            return result
        case "analysis_editor_sidecars_save":
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
private func setAnalysisThreshold(_ args: AnalysisObject, session: ProjectSession) throws {
    guard let value = args["silence_threshold_db"] else { throw badInput("Supply a silence threshold or null for automatic detection.") }
    let threshold = value is NSNull ? nil : try number(value, field: "silence_threshold_db")
    guard threshold.map({ (-120...0).contains($0) }) ?? true else { throw badInput("Choose a threshold between −120 and 0 dBFS.") }
    if session.isMulticam {
        guard args["source_id"] == nil else { throw badInput("Choose a source only for a sequence threshold.") }
        session.multicam.configureSilenceAnalysis(minimum: session.multicam.analysis.pauseMinimum, threshold: threshold)
    } else {
        let editor = session.editor
        let source: UUID?
        if let supplied = args["source_id"] {
            guard let id = (supplied as? String).flatMap(UUID.init(uuidString:)) else { throw badInput("Supply a sequence source ID.") }
            source = id
        } else { source = editor.analysisPlayheadSourceID }
        guard let source, editor.hasAnalysisTrack(editor.sourceAnalysisTracks[source] ?? editor.analysisTrack, in: source) else {
            throw unavailable("The threshold source has no indexed audio on the selected track.")
        }
        editor.setAnalysisThreshold(threshold, for: source)
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
    let before = session.mcpRevision, listing = session.mcpPauseListingRevision
    defer {
        if session.mcpRevision != before {
            session.mcpPauseReviewRevision = (session.mcpHandle, session.mcpRevision, listing)
        }
    }
    if action == "done" {
        if mc { multi.pauseEdits.review = nil } else { editor.cutPreview = nil }
    } else if ["next_cut", "keep_and_advance"].contains(action) {
        guard !mc && editor.cutPreview?.pauseKey != nil else { throw unavailable("Open a sequence cut preview first.") }
        editor.advanceCutPreview(keepingCurrent: action == "keep_and_advance")
    } else {
        guard ["seek", "preview", "protect", "unprotect", "set_retained", "reset_retained"].contains(action), let id = args["pause"] as? String else {
            throw badInput("Supply a pause ID from silence_editor_pauses_list and a review action.")
        }
        if mc {
            guard let pause = multi.multicamPausePlan.first(where: { mcpPauseID($0, revision: session.mcpPauseListingRevision) == id }) else {
                throw unavailable("Refresh silence_editor_pauses_list.")
            }
            if action == "set_retained" || action == "reset_retained" {
                let seconds = action == "set_retained" ? try number(args["retained_seconds"], field: "retained_seconds") : nil
                guard multi.pauseEdits.review == nil, multi.setPauseRetainedDuration(seconds, for: pause) else {
                    throw badInput("Close the preview and supply a nonnegative retained duration for the detected pause.")
                }
                return pauseRetainedReceipt(multi.multicamPausePlan.first(where: { $0.id == pause.id })
                    .map { ($0.retainedSeconds, $0.requestedRetainedSeconds) })
            }
            if let review = multi.pauseEdits.review {
                guard action == "protect", review.id == pause.id else {
                    throw unavailable("Close the current cut preview first.")
                }
                guard multi.setPauseProtection(true, for: pause) else {
                    throw unavailable("The pause could not be protected. Finish the current operation and verify its source audio.")
                }
                multi.pauseEdits.review = nil
                return ["review_open": false]
            }
            if action == "preview" {
                multi.reviewMulticamPause(pause)
                guard multi.pauseEdits.review != nil else { throw unavailable("This join cannot be previewed.") }
            } else if action == "seek" { multi.seekMulticamPause(pause) }
            else if !multi.setPauseProtection(action == "protect", for: pause) {
                throw unavailable("The pause protection could not be changed. Verify its source audio and refresh the pause list.")
            }
        } else {
            guard editor.cutPreview == nil, editor.pauseAnalysisReady,
                  let pause = editor.pausePlan.first(where: { mcpPauseID($0, revision: session.mcpPauseListingRevision) == id }) else {
                throw unavailable("Close the cut preview and refresh silence_editor_pauses_list.")
            }
            if action == "set_retained" || action == "reset_retained" {
                let seconds = action == "set_retained" ? try number(args["retained_seconds"], field: "retained_seconds") : nil
                guard editor.setPauseRetainedDuration(seconds, for: pause.key) else {
                    throw badInput("Supply a nonnegative retained duration for the detected pause.")
                }
                return pauseRetainedReceipt(editor.pausePlan.first(where: { $0.key == pause.key })
                    .map { ($0.retainedSeconds, $0.requestedRetainedSeconds) })
            }
            editor.seek(pause.sequence.from.seconds)
            guard editor.currentPause.map({ mcpPauseID($0, revision: session.mcpPauseListingRevision) }) == id else {
                throw unavailable("Refresh the pause selection.")
            }
            if action == "preview" {
                editor.previewCurrentCut()
                guard editor.cutPreview != nil else { throw unavailable("This join cannot be previewed.") }
            } else if action != "seek", pause.isProtected != (action == "protect"), !editor.protectCurrentPause() {
                throw unavailable("The pause protection could not be changed. Verify its source audio and refresh the pause list.")
            }
        }
    }
    return ["review_open": mc ? multi.pauseEdits.review != nil : editor.cutPreview != nil]
}

private func pauseRetainedReceipt(_ durations: (retained: Double, requested: Double?)?) -> AnalysisObject {
    // Removing the review can merge or remove the old pause.
    guard let durations else { return ["review_open": false] }
    return ["review_open": false, "retained_seconds": durations.retained,
            "requested_retained_seconds": durations.requested.map { $0 as Any } ?? NSNull()]
}
