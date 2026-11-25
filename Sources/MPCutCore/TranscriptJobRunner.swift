import Darwin
import Foundation

extension TranscriptJobStore {
    /// Called only by an explicit provider action. Prepared CLI handoffs and
    /// imports never discover or invoke the helper.
    public func run(_ id: UUID, helper: URL? = nil, download: Bool = false,
                    interrupted: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping (TranscriptJobRecord) -> Void = { _ in }) throws -> TranscriptJobRecord {
        let token = UUID()
        let record = try claimRun(id, token: token)
        guard record.ownerToken == token else { return record }
        return try SidecarLocations.$projectURL.withValue(SidecarLocations.projectURL ?? record.sidecarProjectURL) {
            try runClaimed(record, token: token, helper: helper, download: download, interrupted: interrupted, progress: progress)
        }
    }

    private func runClaimed(_ initial: TranscriptJobRecord, token: UUID, helper: URL?, download: Bool,
                            interrupted: @escaping @Sendable () -> Bool,
                            progress: @escaping (TranscriptJobRecord) -> Void) throws -> TranscriptJobRecord {
        var record = initial
        let id = record.id
        let jobResults = resultDirectory(id)
        progress(record)

        let poll = TranscriptJobPoll(record: recordURL(id))
        let cancelled: @Sendable () -> Bool = {
            if Task.isCancelled || interrupted() { return true }
            return poll.isStopped {
                guard let current = try? read(id) else { return true }
                return current.ownerToken != token || current.state != .running
            }
        }
        func change(_ modify: (inout TranscriptJobRecord) -> Void) throws {
            record = try update(id) {
                guard $0.ownerToken == token, $0.state == .running else { throw CancellationError() }
                modify(&$0)
            }
        }
        func started(_ pid: Int32) throws { try change { $0.helperPID = pid } }
        do {
            var stamps: [URL: SourceIdentity] = [:]
            for track in record.sessions.flatMap(\.tracks) where stamps[track.file] == nil && track.unavailable == nil {
                if cancelled() { throw CancellationError() }
                stamps[track.file] = try? SourceIdentity(track.file)
            }
            func changedTrack(in session: TranscriptJobSession) -> TranscriptJobTrack? {
                session.tracks.first { track in
                    if track.unavailable != nil { return !track.sourceIsCurrent }
                    guard let stamp = stamps[track.file], track.sourceStamp?.matchesSnapshot(stamp) == true,
                          track.sourceChangeTime.map({ $0 == stamp.transcriptJobChangeTime }) ?? true else { return true }
                    return !stamp.isCurrentSnapshot(at: track.file)
                }
            }
            let changedTracks = record.sessions.map(changedTrack)
            if changedTracks.allSatisfy({ $0 != nil }), let changed = changedTracks.first ?? nil {
                record = try finishRun(id, token: token, state: .stale,
                                       message: "Media changed for \(changed.name). Retry with the current project.")
                progress(record)
                return record
            }
            let command = TranscriptProviderCommand(helper: try helper ?? Self.helperURL(), directory: record.workingDirectory)
            let helperSnapshot = try? SourceIdentity(command.helper)
            let settings = try command.settings(for: record.options, cancelled: cancelled, started: started)
            let selected = record.sessions.flatMap(\.tracks).filter(\.recognize)
            let wanted = record.sessions.indices.filter { changedTracks[$0] == nil }
                .flatMap { record.sessions[$0].tracks }.filter { $0.recognize && $0.unavailable == nil }
            let identifiers = Set(wanted.filter { settings.issue(for: $0) == nil }.flatMap(settings.modelIDs(for:)))
            let evidenceWarning = "Some streams lack complete content evidence. Their recognition stays in this job."
            if wanted.contains(where: { !$0.hasReusableEvidence }) && !record.warnings.contains(evidenceWarning) {
                try change { $0.warnings.append(evidenceWarning) }
            }
            let revisions = try settings.revisions(for: identifiers, using: command, download: download,
                                                   stall: providerStallLimit, cancelled: cancelled, started: started)
            try change { $0.helperPID = nil }
            var keys: [String: String] = [:]
            var caches: [String: TranscriptRecognitionCache] = [:]
            for track in wanted {
                if let key = settings.key(for: track, revisions: revisions) {
                    keys[track.id] = key
                    if track.hasReusableEvidence {
                        caches[track.id] = .init(key: key, evidence: track.evidence,
                                                 providerExchangeVersion: settings.sharedExchangeVersion)
                    }
                }
            }

            // Keep the shared claims through publication of the whole session.
            let claims = TranscriptRecognitionClaims()
            defer { withExtendedLifetime(claims) {} }
            do {
                try claims.acquire(Set(caches.values.map(\.claimID)), cancelled: cancelled)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                caches.removeAll()
                try change { $0.warnings.append(error.localizedDescription) }
            }

            // The provider reads a reused result and its levels at the paths the manifest names.
            try restoreArtifacts(record)
            var allValid = true
            var failures = false
            var outputCount = 0
            var recognizedCount = 0
            for sessionIndex in record.sessions.indices {
                if cancelled() { throw CancellationError() }
                var session = record.sessions[sessionIndex]
                if let changed = changedTracks[sessionIndex] ?? changedTrack(in: session) {
                    allValid = false
                    try change { $0.message = "Media changed for \(changed.name). Retry with the current project." }
                    continue
                }
                let policy = record.policy
                try preserveHandoff(session, jobID: record.id)
                var activityHits = Set<String>()
                var blockedErrors: [String: String] = [:]
                for trackIndex in session.tracks.indices {
                    if cancelled() { throw CancellationError() }
                    var track = session.tracks[trackIndex]
                    guard let stamp = stamps[track.file], let stream = track.streamIndex else { continue }
                    if !track.recognize {
                        if try prepareActivity(track, stream: stream, stamp: stamp,
                                               reuse: policy != .restart, cancelled: cancelled) {
                            activityHits.insert(track.id)
                        } else {
                            do {
                                try ensureStagedAudio(&track, stream: stream, stamp: stamp, cancelled: cancelled)
                            } catch {
                                if cancelled() { throw CancellationError() }
                                blockedErrors[track.id] = error.localizedDescription
                                track.state = .failed
                                track.message = error.localizedDescription
                            }
                            session.tracks[trackIndex] = track
                        }
                        continue
                    }
                    guard let result = track.result else { continue }
                    let key = keys[track.id]
                    let scope = settings.settingsKey(for: track)
                    let candidate = key ?? (scope != nil && scope == track.recognitionSettingsKey ? track.recognitionKey : nil)
                    if policy != .restart, let candidate,
                       let prior = TranscriptRecognitionCache.Artifacts(job: result, activity: track.activity),
                       prior.belongs(to: track),
                       prior.matches(key: candidate, evidence: track.evidence, needsActivity: track.activity != nil) {
                        track.recognitionKey = candidate
                        track.recognitionSettingsKey = scope
                        track.state = .recognized
                    } else if policy != .restart, let candidate,
                              let hit = TranscriptRecognitionCache.readPreserved(
                                track: track, key: candidate, in: jobResults, cancelled: cancelled
                              ) ?? caches[track.id]?.read(cancelled: cancelled), hit.belongs(to: track),
                              track.activity == nil || hit.activity != nil {
                        try TranscriptRecognitionCache.preserve(track: track, in: jobResults, cancelled: cancelled)
                        try hit.write(result: result, activity: track.activity)
                        track.recognitionKey = candidate
                        track.recognitionSettingsKey = scope
                        track.state = .cached
                    } else {
                        let missing = settings.modelIDs(for: track).filter { revisions[$0] == nil }.sorted()
                        let modelIssue = missing.isEmpty ? nil :
                            "Transcriberrr needs \(missing.joined(separator: ", ")). Install the model or explicitly allow its download."
                        if let message = settings.issue(for: track) ?? modelIssue {
                            blockedErrors[track.id] = message
                            track.state = .failed
                            track.message = message
                            session.tracks[trackIndex] = track
                            continue
                        }
                        try TranscriptRecognitionCache.preserve(track: track, in: jobResults, cancelled: cancelled)
                        track.recognitionKey = key
                        track.recognitionSettingsKey = scope
                        track.state = .staged
                        if FileManager.default.fileExists(atPath: result.path) {
                            try FileManager.default.removeItem(at: result)
                        }
                        try? FileManager.default.removeItem(at: TranscriptJobArtifact.packedURL(result))
                        do {
                            try ensureStagedAudio(&track, stream: stream, stamp: stamp, cancelled: cancelled)
                        } catch {
                            if cancelled() { throw CancellationError() }
                            blockedErrors[track.id] = error.localizedDescription
                            track.state = .failed
                            track.message = error.localizedDescription
                        }
                    }
                    session.tracks[trackIndex] = track
                }
                try change { $0.sessions[sessionIndex] = session }

                let requested = session.tracks.filter(\.recognize)
                let eligible = requested.filter { $0.unavailable == nil && blockedErrors[$0.id] == nil }
                let pending = eligible.filter { $0.state != .cached && $0.state != .recognized }
                try writeManifest(session, job: record, reuseActivity: activityHits, blockedErrors: blockedErrors,
                                  diarizationOverride: settings.diarize)
                // Remove an older terminal result before submitting. An interrupted
                // subprocess can publish track artifacts, but its old result cannot
                // qualify as the completion of this attempt.
                if FileManager.default.fileExists(atPath: session.output.path) {
                    try FileManager.default.removeItem(at: session.output)
                }
                var arguments = ["session", "--manifest", "-", "--jsonl"]
                if pending.isEmpty && !session.tracks.contains(where: {
                    !$0.recognize && $0.unavailable == nil && $0.streamIndex != nil && !activityHits.contains($0.id)
                }) { arguments.append("--reconcile-only") }
                arguments.append(download && settings.engine.model_source == "macos" && !pending.isEmpty ? "--download" : "--offline")
                let jobID = record.id
                var terminal: TranscriptProviderEvent?
                do {
                    if !requested.isEmpty && eligible.isEmpty {
                        let detail = requested.compactMap { blockedErrors[$0.id] ?? $0.unavailable }
                            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            .joined(separator: "\n")
                        throw jobError("transcript_recognition_failed", detail)
                    }
                    let response = try command.run(arguments, input: session.manifest, stall: providerStallLimit,
                                                   cancelled: cancelled, started: started) { event in
                        guard event.schema_version == 1, UUID(uuidString: event.job_id) == jobID,
                              event.fingerprint == session.fingerprint else { return }
                        if event.event == "session_finished" {
                            terminal = event
                            return
                        }
                        guard let trackID = event.track_id,
                              let trackIndex = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                        switch event.event {
                        case "track_finished":
                            let state = TranscriptJobTrackState(rawValue: event.status) ?? .failed
                            let cached = session.tracks[trackIndex].state == .cached && state == .recognized
                            session.tracks[trackIndex].state = cached ? .cached : state
                            session.tracks[trackIndex].message = event.error ?? event.warning
                        case "track_progress":
                            let percent = event.progress.map { " \(Int(max(0, min(1, $0)) * 100))%" } ?? ""
                            session.tracks[trackIndex].message = event.phase.map { $0 + percent }
                        default:
                            return
                        }
                        let warnings = record.warnings
                        try change {
                            $0.sessions[sessionIndex] = session
                            $0.warnings = warnings
                        }
                        progress(record)
                    }
                    let usedModels = Set(pending.flatMap(settings.modelIDs(for:)))
                    let confirmed: [String: String]
                    do {
                        confirmed = try settings.revisions(for: usedModels, using: command, download: false,
                                                           cancelled: cancelled, started: started)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        confirmed = [:]
                    }
                    let helperChanged = helperSnapshot?.isCurrentSnapshot(at: command.helper) == false
                    if helperChanged || usedModels.contains(where: { confirmed[$0] != revisions[$0] }) {
                        let changed = helperChanged ? "The Transcriberrr helper changed" : "A Transcriberrr model changed"
                        let affected = Set(pending.map(\.id))
                        for index in session.tracks.indices where affected.contains(session.tracks[index].id) {
                            let track = session.tracks[index]
                            if let result = track.result { TranscriptJobArtifact.remove(result) }
                            session.tracks[index].recognitionKey = nil
                            session.tracks[index].recognitionSettingsKey = nil
                            session.tracks[index].state = .failed
                            session.tracks[index].message = "\(changed) during transcription."
                        }
                        try? FileManager.default.removeItem(at: session.output)
                        try change { $0.sessions[sessionIndex] = session }
                        throw jobError("stale_transcript_job", "\(changed) during transcription. Retry this job.")
                    }
                    for track in session.tracks where track.state == .recognized {
                        cacheTrack(track, cache: caches[track.id], cancelled: cancelled, warnings: &record.warnings)
                    }
                    if let error = terminal?.error, response.exitStatus != 0 {
                        throw jobError("transcript_provider_failed", error)
                    }
                    try response.check()
                    let output = try validatedSessionOutput(session, jobID: jobID, stamps: stamps, blockedErrors: blockedErrors)
                    guard ["completed", "partial"].contains(terminal?.status) else {
                        throw jobError("invalid_transcript_result", "Transcriberrr did not report completion of the submitted session.")
                    }
                    for index in session.tracks.indices {
                        let input = session.tracks[index]
                        let returned = output.tracks[index]
                        if returned.coverage == .recognized {
                            if input.state != .cached && input.state != .recognized {
                                session.tracks[index].state = .recognized
                                cacheTrack(input, cache: caches[input.id], cancelled: cancelled, warnings: &record.warnings)
                            }
                        } else {
                            session.tracks[index].state = TranscriptJobTrackState(rawValue: returned.coverage.rawValue) ?? .failed
                        }
                        session.tracks[index].message = returned.error ?? returned.warning
                    }
                    let recognized = output.tracks.filter { $0.coverage == .recognized }.count
                    if (!requested.isEmpty && recognized == 0) || output.tracks.allSatisfy({ $0.coverage == .failed }) {
                        let detail = output.tracks.compactMap(\.error).first ?? "No selected track completed recognition."
                        throw jobError("transcript_recognition_failed", detail)
                    }
                    session.resultSHA256 = try saveResult(output, jobID: jobID)
                    recognizedCount += recognized
                    failures = failures || output.tracks.contains { $0.coverage == .failed }
                    outputCount += 1
                    let warnings = record.warnings
                    try change {
                        $0.sessions[sessionIndex] = session
                        $0.helperPID = nil
                        $0.warnings = warnings
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CutError where error.code == "transcript_job_storage" {
                    // Keep the provider's original output in place until a verified copy exists.
                    throw error
                } catch let error as CutError where error.code == "stale_transcript_job" {
                    allValid = false
                    try change {
                        $0.message = error.message
                        $0.helperPID = nil
                    }
                } catch {
                    failures = true
                    // A provider can write a complete handoff and then fail its final
                    // protocol step. Preserve that result before cleaning up the attempt.
                    try preserveHandoff(session, jobID: jobID)
                    try? FileManager.default.removeItem(at: session.output)
                    let detail = (error as? CutError)?.message ?? error.localizedDescription
                    for index in session.tracks.indices
                    where session.tracks[index].recognize && [.pending, .staged].contains(session.tracks[index].state) {
                        session.tracks[index].state = .failed
                        session.tracks[index].message = detail
                    }
                    try change {
                        $0.message = detail
                        $0.sessions[sessionIndex] = session
                        $0.helperPID = nil
                    }
                }
                progress(record)
            }
            if cancelled() { throw CancellationError() }
            let next: TranscriptJobState
            if !allValid { next = .stale }
            else if outputCount == 0 || (!selected.isEmpty && recognizedCount == 0) { next = .failed }
            else if failures { next = .partial }
            else { next = .completed }
            record = try finishRun(id, token: token, state: next)
            progress(record)
            return record
        } catch where error is CancellationError || cancelled() {
            record = try finishRun(id, token: token, state: .interrupted)
            progress(record)
            return record
        } catch {
            let detail = (error as? CutError)?.message ?? error.localizedDescription
            record = try finishRun(id, token: token, state: .failed, message: detail)
            progress(record)
            throw error
        }
    }

    private func finishRun(_ id: UUID, token: UUID, state: TranscriptJobState,
                           message: String? = nil) throws -> TranscriptJobRecord {
        try update(id) {
            guard $0.ownerToken == token else { return }
            if $0.state == .running {
                $0.state = state
                if let message { $0.message = message }
            }
            // Any other outcome can be retried, and keeps the audio that retry would read.
            if [.completed, .cancelled].contains($0.state) { removeStagedAudio($0) } else { removeFinishedAudio($0) }
            $0.ownerToken = nil
            $0.ownerPID = nil
            $0.helperPID = nil
        }
    }

    private func ensureStagedAudio(_ track: inout TranscriptJobTrack, stream: Int, stamp: SourceIdentity,
                                   cancelled: @escaping @Sendable () -> Bool) throws {
        guard let audio = track.audio else {
            throw jobError("transcript_extraction_failed", "No PCM staging path is available for \(track.name).")
        }
        if let snapshot = track.stagedAudioSnapshot, snapshot.path == audio.path, snapshot.isCurrent { return }
        let engine = CutEngine(cancelled: cancelled)
        let media = try engine.inspectMulticamSource(track.file)
        guard stamp.isCurrentSnapshot(at: track.file) else {
            throw jobError("stale_transcript_job", "Media changed for \(track.name).")
        }
        let extraction = try engine.extractTranscriptAudio(media, stream: stream, channel: track.channel,
                                                           to: audio, cancelled: cancelled)
        track.downmixChannel = extraction.downmixFallbackChannel
        guard let snapshot = TranscriptExternalCacheDescriptor.Snapshot(audio) else {
            throw jobError("transcript_extraction_failed", "Could not verify the staged PCM for \(track.name).")
        }
        track.stagedAudioSnapshot = snapshot
    }

    private func cacheTrack(_ track: TranscriptJobTrack, cache: TranscriptRecognitionCache?,
                            cancelled: @escaping @Sendable () -> Bool, warnings: inout [String]) {
        guard !cancelled(), track.sourceIsCurrent, let cache, let result = track.result,
              let artifacts = TranscriptRecognitionCache.Artifacts(job: result, activity: track.activity),
              artifacts.belongs(to: track),
              artifacts.matches(key: cache.key, evidence: cache.evidence, needsActivity: track.activity != nil) else { return }
        do {
            try cache.save(artifacts, cancelled: cancelled)
        } catch {
            let warning = "Could not share recognition for \(track.name). The job will retain its track result."
            if !warnings.contains(warning) { warnings.append(warning) }
        }
    }

    private func prepareActivity(_ track: TranscriptJobTrack, stream: Int, stamp: SourceIdentity, reuse: Bool,
                                 cancelled: () -> Bool) throws -> Bool {
        guard let activity = track.activity else { return false }
        if reuse, let existing = TranscriptJobArtifact.read(activity),
           TranscriptRecognitionCache.Artifacts.matchesActivity(existing, evidence: track.evidence) { return true }
        if FileManager.default.fileExists(atPath: activity.path) { try FileManager.default.removeItem(at: activity) }
        try? FileManager.default.removeItem(at: TranscriptJobArtifact.packedURL(activity))
        guard reuse, track.hasReusableEvidence else { return false }
        let sidecar = AnalysisSidecar(source: track.file, identity: stamp)
        let key = TranscriptActivityKey(stream: stream, channel: track.stagedChannel)
        if let saved = sidecar.readTranscriptActivity(key, cancelled: cancelled),
           TranscriptRecognitionCache.Artifacts.matchesActivity(saved, evidence: track.evidence) {
            try saved.write(to: activity, options: .atomic)
            return true
        }
        return false
    }

    func validatedSessionOutput(_ session: TranscriptJobSession, jobID: UUID,
                                stamps: [URL: SourceIdentity]? = nil,
                                blockedErrors: [String: String] = [:]) throws -> TranscriptDocument {
        var output = try session.transcript(from: Data(contentsOf: session.output, options: .mappedIfSafe))
        guard output.clock == .session, output.jobID.flatMap(UUID.init(uuidString:)) == jobID,
              output.fingerprint == session.fingerprint,
              Set(output.tracks.map(\.id)) == Set(session.tracks.map(\.id)) else {
            throw jobError("invalid_transcript_result", "The helper output does not match the submitted session.")
        }
        let returned = Dictionary(uniqueKeysWithValues: output.tracks.map { ($0.id, $0) })
        output.tracks = try session.tracks.map { input in
            guard let track = returned[input.id], track.streamIndex == input.streamIndex, track.channel == input.channel,
                  track.origin == input.origin, track.sessionStart == input.sessionStart, track.sourceID == input.sourceID,
                  track.role.rawValue == input.role, track.streamEvidence == .string(input.evidence),
                  input.acceptsCoverage(track.coverage, blocked: blockedErrors[input.id] != nil) else {
                throw jobError("invalid_transcript_result", "The helper returned different bindings for \(input.name).")
            }
            let isCurrent = stamps?[input.file]?.isCurrentSnapshot(at: input.file) ?? input.sourceIsCurrent
            guard isCurrent else {
                throw jobError("stale_transcript_job", "Media changed for \(input.name). Retry with the current project.")
            }
            return track
        }
        return output
    }
}
