import AppKit
import Combine
import Foundation
import MPCutCore

final class TranscriptWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var count: Int { lock.withLock { total } }

    func increment() { lock.withLock { total += 1 } }
}

@MainActor
final class LiveTranscriptController: ObservableObject {
    private unowned let session: ProjectSession
    private struct IndexedMedia: Equatable, Sendable {
        let identity: SourceIdentity
        let changeTime: SourceIdentity.ChangeTime?
        let indexed: Bool
    }

    private struct AssetSnapshot: Equatable, Sendable {
        let location: URL
        let identity: SourceIdentity
        let changeTime: SourceIdentity.ChangeTime?
    }

    private struct IndexKey: Equatable, Sendable {
        let attachment: TranscriptAttachment
        let revision: TranscriptEditRevision
        let project: CutProject
        let context: URL
        let assetSnapshot: AssetSnapshot?
        let mediaRevision: UInt64?
        let media: [String: IndexedMedia]
    }

    /// Built indexes for the current revision, shared with reviews that build off the main thread.
    private final class IndexShelf: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: IndexKey, index: TranscriptIndex)] = []

        func index(for key: IndexKey) -> TranscriptIndex? {
            lock.withLock { entries.first { $0.key == key }?.index }
        }

        func remember(_ index: TranscriptIndex, for key: IndexKey) {
            lock.withLock {
                entries.removeAll { $0.key.attachment.id == key.attachment.id }
                entries.append((key, index))
                if entries.count > 16 { entries.removeFirst() }
            }
        }

        func keep(_ current: (IndexKey) -> Bool) {
            lock.withLock { entries.removeAll { !current($0.key) } }
        }
    }

    private let indexes = IndexShelf()
    let mcpProjectIndexCache = MCPTranscriptProjectIndexCache()
    private var indexLoads: [String: (key: IndexKey, task: Task<TranscriptIndex, Error>)] = [:]
    /// Index builds started. Tests hold each edit to its rebuild budget with this.
    let indexBuilds = TranscriptWorkCounter()
    private var importedDocument: (asset: TranscriptAsset, context: URL, document: TranscriptDocument)?
    /// Keyed by result ID, which names the stored bytes, so an entry never goes out of date.
    private var lineages: [String: ResultOrigin] = [:]
    private static var active: [UUID: LiveTranscriptController] = [:]
    private let sourceAudition = TranscriptAuditionPanel()
    private var worker: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private var jobDiscovery: (context: URL, handle: String, owner: UUID?, task: Task<Void, Never>)?
    private var jobDocument: URL?
    private var jobOwner: UUID?
    private var jobHandle: String?
    private var publishedResults: [UUID: (preparationID: UUID?, resultIDs: Set<String>)] = [:]
    private var cancellation: EditCancellation?
    private var stopRequested = false
    private var explicitlyCancelled = false
    private var startIntent: (options: TranscriptJobOptions, policy: TranscriptJobPolicy, download: Bool)?
    @Published private(set) var job: TranscriptJobRecord?
    @Published private(set) var jobError: String?
    @Published private(set) var activeJobID: UUID?

    init(session: ProjectSession) {
        self.session = session
        Publishers.CombineLatest3(session.editor.$projectURL, session.multicam.$projectURL, session.$isMulticam)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.documentPathChanged() }
            .store(in: &observers)
    }

    var project: CutProject {
        if session.isMulticam, let multicam = session.multicam.project { return .multicam(multicam) }
        return session.editor.transcriptProject
    }

    var state: ProjectTranscripts {
        session.isMulticam ? session.multicam.transcriptState : session.editor.transcriptState
    }

    var timelineRevision: Int {
        session.isMulticam ? session.multicam.mcpRevision : session.editor.mcpRevision
    }

    func assetContext() throws -> URL {
        try session.isMulticam ? session.multicam.transcriptAssetContext() : session.editor.transcriptAssetContext()
    }

    func attachment(id: String? = nil) throws -> TranscriptAttachment {
        guard let attachment = id.flatMap({ id in state.attachments.first { $0.id == id } })
            ?? (id == nil ? state.attachments.first : nil) else {
            throw CutError(code: "missing_transcript", message: "Choose an attached transcript.")
        }
        return attachment
    }

    func document(attachmentID: String? = nil) throws -> TranscriptDocument {
        try TranscriptStore.decoded(attachment(id: attachmentID).asset, relativeTo: assetContext())
    }

    func index(attachmentID: String? = nil) throws -> TranscriptIndex {
        try buildIndex(for: indexKey(attachmentID: attachmentID))()
    }

    /// The index for the current revision when it is already built.
    func cachedIndex(attachmentID: String? = nil) -> TranscriptIndex? {
        (try? indexKey(attachmentID: attachmentID)).flatMap(indexes.index)
    }

    func indexedTranscript(attachmentID: String? = nil) async throws -> TranscriptIndex {
        let key = try indexKey(attachmentID: attachmentID)
        if let cached = indexes.index(for: key) { return cached }
        let id = key.attachment.id
        let load: Task<TranscriptIndex, Error>
        if let running = indexLoads[id], running.key == key {
            load = running.task
        } else {
            // A build cannot stop midway. One that an edit has superseded finishes before its
            // successor starts, and a successor superseded while it waits never starts.
            let superseded = indexLoads[id]?.task
            superseded?.cancel()
            let build = buildIndex(for: key)
            load = Task.detached(priority: .userInitiated) {
                _ = await superseded?.result
                return try build()
            }
            indexLoads[id] = (key, load)
        }
        let result = await load.result
        if indexLoads[id]?.task == load { indexLoads[id] = nil }
        let index = try result.get()
        try Task.checkCancellation()
        guard try indexKey(attachmentID: attachmentID) == key else {
            throw CutError(code: "stale_transcript", message: "The transcript changed while it was opening.")
        }
        return index
    }

    private func indexKey(attachmentID: String?) throws -> IndexKey {
        let attachment = try attachment(id: attachmentID)
        let media = (session.isMulticam ? session.multicam.media : session.editor.transcriptMedia)
            .mapValues { IndexedMedia(identity: $0.identity, changeTime: $0.identity.changeTime, indexed: $0.hasFullEditIndex) }
        let context = try assetContext()
        let assetSnapshot = TranscriptStore.assetLocation(attachment.asset, relativeTo: context).flatMap { url in
            (try? SourceIdentity(url)).map { AssetSnapshot(location: url, identity: $0, changeTime: $0.changeTime) }
        }
        // An index for an earlier revision or a detached result can never be asked for again.
        let (timeline, transcript) = (timelineRevision, state.revision)
        let attached = Set(state.attachments.map(\.id))
        indexes.keep {
            $0.revision.timelineRevision == timeline && $0.revision.transcriptRevision == transcript
                && attached.contains($0.attachment.id)
        }
        return IndexKey(attachment: attachment, revision: revision(of: attachment), project: project,
                        context: context, assetSnapshot: assetSnapshot,
                        mediaRevision: session.isMulticam ? session.multicam.transcriptMediaRevision : nil,
                        media: media)
    }

    func plan(_ request: TranscriptEditRequest, attachmentID: String? = nil) throws -> TranscriptEditPlan {
        let input = try planAttachments(request, defaultID: attachmentID)
        let primary = try index(attachmentID: input.primary.id)
        let additional = try input.required.map { try index(attachmentID: $0) }
            + input.review.compactMap { try? index(attachmentID: $0) }
        return try sidecarPolicy.run {
            try TranscriptEditPlanner.plan(request, in: primary, project: project,
                                           revision: revision(of: input.primary), relativeTo: assetContext(),
                                           sequenceMedia: session.editor.transcriptMedia, multicamMedia: session.multicam.media,
                                           additionalIndexes: additional)
        }
    }

    private func planAttachments(_ request: TranscriptEditRequest, defaultID: String?) throws
        -> (primary: TranscriptAttachment, required: [String], review: [String]) {
        let ids = request.selections.compactMap(\.attachmentID) + (request.target?.attachmentID.map { [$0] } ?? [])
        let primary = try attachment(id: defaultID ?? ids.first)
        let required = Set(ids).subtracting([primary.id])
        let review: [String]
        switch request.action {
        case .delete, .replace, .tighten, .trimStart, .trimEnd:
            review = state.attachments.map(\.id).filter { $0 != primary.id && !required.contains($0) }
        default:
            review = []
        }
        return (primary, required.sorted(), review)
    }

    @discardableResult
    func apply(_ plan: TranscriptEditPlan) throws -> TranscriptEditCommit {
        let current = try currentRevision(for: plan)
        let commit = try plan.apply(to: project, revision: current)
        guard commit.undo != nil else { return commit }
        try validateSources(for: plan)
        if session.isMulticam, case .multicam(let proposal) = commit.project {
            guard session.multicam.edit(plan.historyAction, { $0 = proposal }) else {
                throw CutError(code: "editor_busy", message: "The multicam edit could not be applied.")
            }
        } else {
            try session.editor.applyTranscriptProject(commit.project, action: plan.historyAction)
        }
        return commit
    }

    func queue(_ plan: TranscriptEditPlan, name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan.action == .queue, !name.isEmpty, let range = plan.selections.first?.range else {
            throw CutError(code: "queue_failed", message: "Review an excerpt and give it a name.")
        }
        try plan.validate(to: project, revision: currentRevision(for: plan))
        try validateSources(for: plan)
        let displayRange = MulticamRange(from: range.from, to: try range.from.adding(plan.duration))
        let excerpt = try TranscriptQueueExcerpt(name: name, project: plan.snapshot, location: assetContext())
        if session.isMulticam, case .multicam(let proposal) = plan.snapshot {
            return try session.multicam.enqueueTranscriptSnapshot(proposal, excerpt: excerpt, range: displayRange)
        }
        return try session.editor.enqueueTranscriptSnapshot(plan.snapshot, excerpt: excerpt, range: displayRange)
    }

    func prepareExcerptSave(_ id: UUID, to destination: URL) throws -> @Sendable () throws -> Void {
        let excerpt = session.isMulticam ? session.multicam.queuedRanges.first(where: { $0.id == id })?.excerpt
            : session.editor.queuedRanges.first(where: { $0.id == id })?.excerpt
        guard let excerpt else {
            throw CutError(code: "queue_excerpt_missing", message: "Choose a queued transcript excerpt.")
        }
        let canSave = session.isMulticam ? session.multicam.canSaveProjectTo : session.editor.canSaveProjectTo
        guard canSave?(destination) != false else {
            throw CutError(code: "project_open", message: "A window already has this project open.")
        }
        return { try excerpt.save(to: destination) }
    }

    func select(_ selection: TranscriptWordSelection, attachmentID: String? = nil) throws -> TranscriptResolvedSelection {
        // An occurrence ID begins with the attachment that produced it.
        let owner = selection.firstOccurrenceID.flatMap { occurrence in
            state.attachments.first { occurrence.hasPrefix("\($0.id.count):\($0.id):") }?.id
        }
        return try TranscriptEditPlanner.select(selection, in: index(attachmentID: selection.attachmentID ?? owner ?? attachmentID))
    }

    @discardableResult
    func mark(_ selection: TranscriptWordSelection, attachmentID: String? = nil) throws -> TranscriptResolvedSelection {
        let result = try select(selection, attachmentID: attachmentID)
        if session.isMulticam {
            guard !session.multicam.isBusy else { throw busyEditor() }
            switch result.space {
            case .currentCut:
                session.multicam.preview.pause()
                session.multicam.seekAssembly(at: result.range.from, scrubbing: false)
                session.multicam.assemblySelection = AudioSpan(from: result.range.from, to: result.range.to)
            case .group, .source:
                let range = try result.space == .group ? result.range : translatedGroupRange(result)
                guard let group = session.multicam.project?.range,
                      group.from <= range.from, range.to <= group.to else { throw unavailableOccurrence() }
                session.multicam.preview.pause()
                session.multicam.setAssemblyPreview(false)
                session.multicam.seekGroup(range.from)
                session.multicam.markIn = range.from
                session.multicam.markOut = range.to
            }
        } else if result.space == .currentCut {
            try session.editor.setTranscriptMarks(result.range)
        } else {
            let index = try index(attachmentID: selection.attachmentID ?? attachmentID)
            let first = try retainedOccurrence(result.first, in: index)
            let last = try retainedOccurrence(result.last, in: index)
            guard first.clipID == last.clipID else {
                throw CutError(code: "ambiguous_transcript_selection", message: "Select the intended occurrence in Current Cut.")
            }
            let from = result.kind == .gap ? first.range.to : first.range.from
            let to = result.kind == .gap ? last.range.from : last.range.to
            let lower = try from.subtracting(selection.leadingPadding ?? .zero)
            let upper = try to.adding(selection.trailingPadding ?? .zero)
            try session.editor.setTranscriptMarks(MulticamRange(from: lower, to: upper))
        }
        return result
    }

    func seek(_ occurrence: TranscriptOccurrence, space: TranscriptSpace, attachmentID: String? = nil) throws {
        guard occurrence.timelineRevision == timelineRevision else {
            throw CutError(code: "stale_transcript_plan", message: "Choose an occurrence in the current timeline revision.")
        }
        if space == .source {
            try auditionSource(occurrence)
            return
        }
        closeSourceAudition()
        if session.isMulticam {
            guard !session.multicam.isBusy else { throw busyEditor() }
            session.multicam.preview.pause()
            if space == .currentCut {
                session.multicam.seekAssembly(at: occurrence.range.from, scrubbing: false)
            } else {
                session.multicam.setAssemblyPreview(false)
                session.multicam.seekGroup(occurrence.range.from)
            }
        } else {
            guard session.editor.canNavigate else { throw busyEditor() }
            session.editor.preview.pause()
            if space == .currentCut {
                session.editor.seek(occurrence.range.from.seconds)
            } else if let retained = try? retainedOccurrence(occurrence, in: index(attachmentID: attachmentID)) {
                session.editor.seek(retained.range.from.seconds)
            } else {
                throw unavailableOccurrence()
            }
        }
    }

    func auditionSource(_ first: TranscriptOccurrence, through last: TranscriptOccurrence? = nil) throws {
        guard first.timelineRevision == timelineRevision,
              last == nil || last?.timelineRevision == timelineRevision else {
            throw CutError(code: "stale_transcript_plan", message: "Choose an occurrence in the current timeline revision.")
        }
        let endpoint = last ?? first
        guard first.attachmentID == endpoint.attachmentID, first.trackID == endpoint.trackID,
              first.sourceID == endpoint.sourceID, first.file == endpoint.file,
              first.streamIndex == endpoint.streamIndex,
              first.bindingStatus != .offline, first.bindingStatus != .changed,
              first.bindingStatus != .bindingMissing else { throw unavailableOccurrence() }
        if session.isMulticam, session.multicam.isBusy { throw busyEditor() }
        let media: MediaInfo
        let clockOffset: RationalTime
        if let source = first.sourceID {
            guard let indexed = session.multicam.media[source] else { throw unavailableOccurrence() }
            media = indexed
            clockOffset = indexed.multicamClockOffset
        } else if let file = first.file {
            let url = try CutProject.checkedMediaURL(file, relativeTo: assetContext())
            media = try session.editor.transcriptMediaInfo(for: url.path)
            clockOffset = media.multicamSourceOffset
        } else {
            throw unavailableOccurrence()
        }
        guard let firstRange = first.sourceRange, let lastRange = endpoint.sourceRange,
              let stream = first.streamIndex else { throw unavailableOccurrence() }
        let presentation = MulticamRange(from: min(firstRange.from, lastRange.from),
                                         to: max(firstRange.to, lastRange.to))
        let clip = try transcriptAuditionRange(media: media, presentation: presentation,
                                               streamIndex: stream, clockOffset: clockOffset,
                                               indexedInPresentationClock: first.sourceID != nil,
                                               includeLead: last != nil)
        session.multicam.preview.pause()
        session.editor.preview.pause()
        sourceAudition.show(clip, streamIndex: stream, parent: session.window?.attachedSheet ?? session.window,
                            autoplay: last != nil, clockOffset: clockOffset)
    }

    func closeSourceAudition() {
        sourceAudition.close()
    }

    nonisolated static func readImport(_ url: URL, format: TranscriptFormat) throws -> TranscriptDocument {
        // A device or pipe would block the editor while it is read.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CutError(code: "invalid_transcript", message: "The transcript input must be a regular file.")
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        return try TranscriptCodec.decode(bytes, format: format)
    }

    @discardableResult
    /// `replacing` names an attachment whose result this import supersedes. It keeps the
    /// attachment ID, and its bindings and import origin when the request supplies none.
    func importTranscript(_ url: URL, format: TranscriptFormat, bindings: [TranscriptBinding] = [],
                          origin: RationalTime? = nil, inferIfEmpty: Bool = true,
                          replacing: String? = nil) throws -> TranscriptAttachment {
        let transcript = try Self.readImport(url, format: format)
        let previous = try replacing.map { try attachment(id: $0) }
        let confirmed = !bindings.isEmpty
        let candidates: [TranscriptBinding]
        if bindings.isEmpty, let previous {
            candidates = previous.bindings
        } else {
            candidates = try bindings.isEmpty && inferIfEmpty ? inferredBindings(transcript) : resolvedBindings(bindings)
        }
        try validateBindings(candidates, document: transcript)
        let context = try assetContext()
        let snapshot = project
        let stamped = bindings.isEmpty && previous != nil
            ? candidates : candidates.map { $0.stamped(in: snapshot, relativeTo: context, confirmed: confirmed) }
        let asset = try store(transcript)
        let attachment = TranscriptAttachment(id: previous?.id ?? UUID().uuidString, asset: asset, bindings: stamped,
                                              importOrigin: origin ?? previous?.importOrigin, fingerprint: nil)
        var next = state
        if let index = next.attachments.firstIndex(where: { $0.id == attachment.id }) {
            next.attachments[index] = attachment
        } else {
            next.attachments.append(attachment)
        }
        try setState(next)
        return attachment
    }

    func attachImportedTranscript(_ transcript: TranscriptDocument, bindings: [TranscriptBinding],
                                  origin: RationalTime?) async throws -> TranscriptAttachment {
        let candidates = try resolvedBindings(bindings)
        try validateBindings(candidates, document: transcript)
        let context = try assetContext()
        let owner = session.mcpHandle
        let snapshot = project
        let draft = session.isMulticam ? session.multicam.projectURL == nil : session.editor.projectURL == nil
        let stamped = candidates.map { $0.stamped(in: snapshot, relativeTo: context, confirmed: !bindings.isEmpty) }
        let worker = Task.detached(priority: .userInitiated) {
            let data = try TranscriptCodec.encode(transcript, format: .json)
            try Task.checkCancellation()
            return try TranscriptStore.put(data, relativeTo: context, draft: draft)
        }
        let asset = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard session.mcpHandle == owner, try assetContext() == context, project == snapshot else {
            throw CutError(code: "stale_transcript", message: "The project changed while the transcript was attaching. Review the bindings again.")
        }
        guard TranscriptStore.assetStatus(asset, relativeTo: context) == .available else {
            throw CutError(code: "missing_transcript", message: "The staged transcript is unavailable. Attach it again.")
        }
        let attachment = TranscriptAttachment(id: UUID().uuidString, asset: asset, bindings: stamped,
                                              importOrigin: origin, fingerprint: nil)
        var next = state
        next.attachments.append(attachment)
        try setState(next)
        importedDocument = (asset, context, transcript)
        return attachment
    }

    func bind(attachmentID: String, bindings: [TranscriptBinding], origin: RationalTime?) throws {
        let transcript = try document(attachmentID: attachmentID)
        let bindings = try resolvedBindings(bindings)
        try validateBindings(bindings, document: transcript)
        var next = state
        guard let i = next.attachments.firstIndex(where: { $0.id == attachmentID }) else {
            throw CutError(code: "missing_transcript", message: "Choose an attached transcript.")
        }
        let context = try assetContext()
        let snapshot = project
        let previous = next.attachments[i]
        next.attachments[i].bindings = bindings.map { binding in
            let prior = previous.bindings.first {
                $0.trackID == binding.trackID && $0.file == binding.file && $0.sourceID == binding.sourceID
                    && $0.streamIndex == binding.streamIndex && $0.channel == binding.channel
            }
            let status = prior?.sourceStatus(in: snapshot, relativeTo: context)
            if var kept = prior, status == .offline {
                // An offline recording cannot be measured again. It keeps the identity and
                // clock it was bound with, so the binding verifies when the file returns.
                kept.offset = binding.offset
                return kept
            }
            if let prior, prior.offset != binding.offset || previous.importOrigin != origin, status == .changed {
                var copy = binding
                copy.sourceFingerprint = prior.sourceFingerprint
                copy.sourceConfirmed = prior.sourceConfirmed
                return copy
            }
            return binding.stamped(in: snapshot, relativeTo: context, confirmed: true)
        }
        next.attachments[i].importOrigin = origin
        try setState(next)
    }

    func recoverAttachment(id: String, from directory: URL) throws {
        let attachment = try attachment(id: id)
        let context = try assetContext()
        let draft = session.isMulticam ? session.multicam.projectURL == nil : session.editor.projectURL == nil
        let asset = try TranscriptStore.recover(attachment.asset, from: directory, relativeTo: context, draft: draft)
        var next = state
        guard let index = next.attachments.firstIndex(where: { $0.id == id }) else {
            throw CutError(code: "missing_transcript", message: "Choose an attached transcript.")
        }
        next.attachments[index].asset = asset
        try setState(next, forceRevision: true)
    }

    func detach(attachmentID: String) throws {
        let removed = try attachment(id: attachmentID)
        if let fingerprint = removed.fingerprint {
            for record in try jobs() where isAttached(record)
                && record.sessions.contains(where: { $0.fingerprint == fingerprint }) {
                try jobStore.markAttached(record.id, expectedPreparationID: record.preparationID)
            }
        }
        var next = state
        next.attachments.removeAll { $0.id == attachmentID }
        try setState(next)
    }

    func setAuthoredRecords(_ records: [TranscriptAuthoredRecord], action: String) throws {
        var next = state
        next.authoring = records
        try setState(next, action: action)
    }

    private func setState(_ next: ProjectTranscripts, action: String? = nil, forceRevision: Bool = false) throws {
        if session.isMulticam {
            try session.multicam.setTranscriptState(next, action: action, forceRevision: forceRevision)
        } else {
            try session.editor.setTranscriptState(next, action: action, forceRevision: forceRevision)
        }
        indexes.keep { _ in false }
        if let importedDocument, !next.attachments.contains(where: { $0.asset == importedDocument.asset }) {
            self.importedDocument = nil
        }
        objectWillChange.send()
    }

    private func store(_ document: TranscriptDocument) throws -> TranscriptAsset {
        let context = try assetContext()
        let draft = session.isMulticam ? session.multicam.projectURL == nil : session.editor.projectURL == nil
        return try TranscriptStore.put(TranscriptCodec.encode(document, format: .json), relativeTo: context, draft: draft)
    }

    private func inferredBindings(_ document: TranscriptDocument) -> [TranscriptBinding] {
        if session.isMulticam, let project = session.multicam.project {
            return document.tracks.compactMap { track in
                let source = project.sources.first { $0.id == track.sourceID || $0.id == track.id }
                    ?? (project.sources.count == 1 && document.tracks.count == 1 ? project.sources.first : nil)
                guard let source else { return nil }
                let audio = session.multicam.media[source.id]?.streams.filter { $0.kind == "audio" } ?? []
                guard let stream = track.streamIndex ?? (audio.count == 1 ? audio.first?.index : nil) else { return nil }
                return TranscriptBinding(trackID: track.id, sourceID: source.id, streamIndex: stream, channel: track.channel)
            }
        }
        let files = Set(session.editor.sequenceClips.map { $0.originalFile ?? $0.file })
        guard files.count == 1, let file = files.first else { return [] }
        let audio = session.editor.transcriptMedia[file]?.streams.filter { $0.kind == "audio" } ?? []
        return document.tracks.compactMap { track in
            guard let stream = track.streamIndex ?? (audio.count == 1 ? audio.first?.index : nil) else { return nil }
            return TranscriptBinding(trackID: track.id, file: file, streamIndex: stream, channel: track.channel,
                                     sequenceClockOrigin: session.editor.transcriptMedia[file]?.multicamSourceOffset,
                                     sequenceStreamOrdinal: audio.firstIndex { $0.index == stream })
        }
    }

    private func resolvedBindings(_ bindings: [TranscriptBinding]) throws -> [TranscriptBinding] {
        let context = try assetContext()
        return try bindings.map { binding in
            guard let file = binding.file else { return binding }
            let resolved = try CutProject.checkedMediaURL(file, relativeTo: context)
            var copy = binding
            copy.file = resolved.path
            if let media = try? session.editor.transcriptMediaInfo(for: resolved.path) {
                copy.sequenceClockOrigin = media.multicamSourceOffset
                copy.sequenceStreamOrdinal = media.streams.filter { $0.kind == "audio" }.firstIndex {
                    $0.index == binding.streamIndex
                }
            }
            return copy
        }
    }

    private func validateBindings(_ bindings: [TranscriptBinding], document: TranscriptDocument) throws {
        let tracks = Set(document.tracks.map(\.id))
        for binding in bindings {
            guard tracks.contains(binding.trackID) else {
                throw CutError(code: "invalid_transcript_binding", message: "Unknown transcript track \(binding.trackID).")
            }
            if session.isMulticam {
                guard let source = binding.sourceID, binding.file == nil,
                      session.multicam.project?.sources.contains(where: { $0.id == source }) == true else {
                    throw CutError(code: "invalid_transcript_binding", message: "Choose a source in this multicam project.")
                }
                try validateStream(binding, media: session.multicam.media[source])
            } else {
                guard let file = binding.file, binding.sourceID == nil,
                      session.editor.sequenceClips.contains(where: { $0.file == file || $0.originalFile == file }) else {
                    throw CutError(code: "invalid_transcript_binding", message: "Choose a media file in this sequence.")
                }
                try validateStream(binding, media: try? session.editor.transcriptMediaInfo(for: file))
            }
        }
    }

    private func validateStream(_ binding: TranscriptBinding, media: MediaInfo?) throws {
        if let media, !media.streams.contains(where: { $0.kind == "audio" && $0.index == binding.streamIndex }) {
            throw CutError(code: "invalid_transcript_binding", message: "Choose an absolute audio stream index for \(binding.trackID).")
        }
    }

    private func retainedOccurrence(_ occurrence: TranscriptOccurrence, in index: TranscriptIndex) throws -> TranscriptOccurrence {
        let matches = index.locate(wordID: occurrence.wordID, space: .currentCut).filter {
            occurrence.trackID == nil || $0.trackID == occurrence.trackID
        }
        guard matches.count <= 1 else {
            throw CutError(code: "ambiguous_transcript_selection", message: "Choose one of the retained occurrences in Current Cut.")
        }
        guard let match = matches.first else { throw unavailableOccurrence() }
        return match
    }

    private func translatedGroupRange(_ selection: TranscriptResolvedSelection) throws -> MulticamRange {
        guard selection.first.trackID == selection.last.trackID, let group = selection.first.groupRange else {
            throw unavailableOccurrence()
        }
        let offset = try group.from.subtracting(selection.first.range.from)
        return MulticamRange(from: try selection.range.from.adding(offset), to: try selection.range.to.adding(offset))
    }

    private func busyEditor() -> CutError {
        CutError(code: "editor_busy", message: "Wait for the active editor operation.")
    }

    private func unavailableOccurrence() -> CutError {
        CutError(code: "unresolved_transcript_location", message: "This word has no location in the active editor.")
    }

    private func revision(of attachment: TranscriptAttachment) -> TranscriptEditRevision {
        .init(timelineRevision: timelineRevision, transcriptRevision: state.revision, resultID: attachment.resultID)
    }

    private func validateSources(for plan: TranscriptEditPlan) throws {
        let context = try assetContext()
        let snapshot = project
        let primary = state.attachments.first(where: { $0.resultID == plan.revision.resultID })?.id
        var tracksByAttachment: [String: [String: TranscriptTrack]] = [:]
        for selection in plan.selections {
            for binding in Set([selection.first.binding, selection.last.binding].compactMap({ $0 })) {
                var status = binding.sourceStatus(in: snapshot, relativeTo: context)
                if status == .changed, let id = selection.attachmentID ?? primary {
                    if tracksByAttachment[id] == nil {
                        let tracks = try document(attachmentID: id).tracks
                        tracksByAttachment[id] = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
                    }
                    if let track = tracksByAttachment[id]?[binding.trackID] {
                        let media = binding.sourceID.flatMap { session.multicam.media[$0] }
                            ?? binding.file.flatMap { session.editor.transcriptMedia[$0] }
                        status = binding.sourceStatus(in: snapshot, relativeTo: context, track: track, indexedMedia: media)
                    }
                }
                switch status {
                case .changed, .offline, .bindingMissing:
                    throw CutError(code: "transcript_binding_unavailable", message: "Relink or rebind \(binding.trackID) before editing this passage.")
                default: continue
                }
            }
        }
    }

    private func currentRevision(for plan: TranscriptEditPlan) throws -> TranscriptEditRevision {
        guard let attachment = state.attachments.first(where: { $0.resultID == plan.revision.resultID }),
              revision(of: attachment) == plan.revision else {
            throw CutError(code: "stale_transcript_plan", message: "The project or transcript changed after the edit was reviewed.")
        }
        return revision(of: attachment)
    }
}

extension LiveTranscriptController {
    /// What a selection was read from. A correction made in a sheet names it, so a result
    /// replaced or an edit made while the sheet was open cannot receive the old selection.
    func editRevision(attachmentID: String? = nil) throws -> TranscriptEditRevision {
        try revision(of: attachment(id: attachmentID))
    }

    @discardableResult
    func correct(_ change: TranscriptAuthoredChange, selection: TranscriptWordSelection? = nil,
                 attachmentID: String? = nil, expecting: TranscriptEditRevision? = nil) throws -> TranscriptAuthoredRecord {
        try correct(change, selections: selection.map { [$0] } ?? [], attachmentID: attachmentID, expecting: expecting)
    }

    @discardableResult
    func correct(_ change: TranscriptAuthoredChange, selections: [TranscriptWordSelection],
                 attachmentID: String? = nil, expecting: TranscriptEditRevision? = nil) throws -> TranscriptAuthoredRecord {
        let attachment = try attachment(id: attachmentID ?? selections.first?.attachmentID)
        if let expecting, revision(of: attachment) != expecting {
            throw CutError(code: "stale_transcript_plan",
                           message: "The project or transcript changed after this passage was selected. Select it again.")
        }
        // The reader already holds this index for the current revision. Building another
        // for each correction read, hashed and projected the whole result on the main thread.
        let sourceIndex = try index(attachmentID: attachment.id)
        let record = try TranscriptEditorial.makeRecord(change: change, selections: selections, in: sourceIndex)
        try correct(record)
        return record
    }

    func correct(_ record: TranscriptAuthoredRecord) throws {
        try record.validate()
        var records = state.authoring
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        let action: String
        switch record.change {
        case .namedSelect: action = "Name Transcript Select"
        case .pauseProtection: action = "Protect Transcript Pause"
        default: action = "Correct Transcript"
        }
        try setAuthoredRecords(records, action: action)
    }
}

extension LiveTranscriptController {
    /// Job folders and shared recognition results that nothing has written for a month can be
    /// staged or recognized again from the media. Nothing else removes them, and each
    /// transcribed recording leaves some behind. A finished result its project has not
    /// attached is kept however old it is.
    nonisolated static func pruneAbandonedWork(olderThan age: TimeInterval = 30 * 86_400) {
        Task.detached(priority: .utility) {
            for directory in [jobsDirectory, TranscriptJobStore.defaultDirectory] {
                _ = try? TranscriptJobStore(directory: directory).prune(olderThan: age)
            }
            TranscriptJobStore.pruneSharedRecognition(olderThan: age)
        }
    }

    nonisolated static var jobsDirectory: URL {
        ProjectDraft.autosaveDirectory.appendingPathComponent(".transcript-jobs", isDirectory: true)
    }

    private var jobStore: TranscriptJobStore {
        // This editor runs the provider itself, which stages audio as each track needs it.
        var store = TranscriptJobStore(directory: Self.jobsDirectory)
        store.stagesAudioForStandaloneProvider = false
        return store
    }

    private var existingDocument: URL? {
        let url = session.isMulticam ? (session.multicam.projectURL ?? session.multicam.draft.url)
            : (session.editor.projectURL ?? session.editor.draft.url)
        return url?.resolvingSymlinksInPath().standardizedFileURL
    }

    private func owns(_ record: TranscriptJobRecord, document: URL) -> Bool {
        guard record.documentID == document.path, let owner = record.documentIdentity else { return false }
        if let identity = state.documentID { return owner == identity }
        let disk = try? SourceIdentity(document)
        return disk != nil && record.documentDiskFingerprint == disk?.transcriptFingerprint
    }

    private func adoptJobOwner(_ identity: UUID) throws {
        guard state.documentID != identity else { return }
        var next = state
        next.documentID = identity
        try setState(next)
    }

    private func claimRenamedJobs(_ owner: UUID, document: URL) throws {
        let paths = Set(try jobStore.list(documentIdentity: owner).map(\.documentID))
        for path in paths where path != document.path {
            let old = URL(fileURLWithPath: path)
            // Save As is migrated explicitly. Only claim an old locator after a move
            // if no other on-disk copy of this document still occupies it.
            if let project = try? CutProject.load(from: old), project.transcripts.documentID == owner { continue }
            try jobStore.rebindDocument(from: path, to: document.path, documentIdentity: owner)
        }
    }

    private struct SidecarPolicy: Sendable {
        let reads: Bool
        let writes: Bool
        let excluded: Set<URL>

        func run<T>(_ work: () throws -> T) rethrows -> T {
            try AnalysisSidecar.$excludedSources.withValue(excluded) {
                try AnalysisSidecar.$readsEnabled.withValue(reads) {
                    try AnalysisSidecar.$automaticWritesEnabled.withValue(writes) { try work() }
                }
            }
        }
    }

    private var sidecarPolicy: SidecarPolicy {
        let excluded = session.isMulticam ? session.multicam.sidecarExclusions : session.editor.sidecarExclusions
        let reads = session.isMulticam ? session.multicam.useAnalysisSidecars : session.editor.useAnalysisSidecars
        let protected = session.isMulticam ? session.multicam.protectedMediaPaths : session.editor.mcpOutputProtectedMedia
        let candidates = (project.sequenceClips ?? []).flatMap { [$0.file, $0.originalFile].compactMap { $0 } }
            .map { URL(fileURLWithPath: $0) }
        return .init(reads: reads && AnalysisSidecar.readsEnabled,
                     writes: reads && AnalysisSidecar.automaticWritesEnabled,
                     excluded: excluded.union(AnalysisSidecar.excludedSources)
                        .union(CutProject.sidecarExclusions(absoluteSources: protected, candidates: candidates)))
    }

    func capabilities(opening: ((String) -> Void)? = nil) async throws -> Data {
        let helper = try TranscriptJobStore.helperURL()
        if let opening, ProcessInfo.processInfo.environment["MPCUT_TRANSCRIBERRR_HELPER"] == nil {
            let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.transcriberrr.app")
                .contains { $0.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path && !$0.isTerminated }
            if !running {
                opening("Opening Transcriberrr…")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
            }
            opening("Loading transcription engines…")
        }
        try Task.checkCancellation()
        let data = try await Task.detached(priority: .userInitiated) {
            try TranscriptJobStore.capabilities(helper: helper)
        }.value
        try Task.checkCancellation()
        return data
    }

    /// Whether a helper is installed and can run a session. Preparation extracts every
    /// recording's audio, which a missing or outdated helper would leave staged for nothing.
    func checkHelper() async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try TranscriptJobStore.capabilities(helper: TranscriptJobStore.helperURL())
        }.value
    }

    func tracks(options: TranscriptJobOptions = .init()) async throws -> [TranscriptJobTrack] {
        let project = project
        let policy = sidecarPolicy
        return try await Task.detached(priority: .userInitiated) {
            try policy.run { try TranscriptJobPlan.inventory(project: project, options: options).flatMap(\.tracks) }
        }.value
    }

    func jobs() throws -> [TranscriptJobRecord] {
        if let old = jobDocument { migrateJob(old.path) }
        guard let url = existingDocument else { return [] }
        if let owner = state.documentID { try claimRenamedJobs(owner, document: url) }
        return try jobStore.list(documentID: url.path).filter { owns($0, document: url) }
            .sorted { jobOrder($0) > jobOrder($1) }
    }

    func isAttached(_ record: TranscriptJobRecord) -> Bool {
        if let expected = publishedResults[record.id], expected.preparationID == record.preparationID {
            return !expected.resultIDs.isEmpty && expected.resultIDs.isSubset(of: Set(state.attachments.map(\.resultID)))
        }
        return record.attached && state.attachments.contains { attachment in
            record.sessions.contains { $0.fingerprint == attachment.fingerprint }
        }
    }

    func status(_ id: UUID) throws -> TranscriptJobRecord {
        if let old = jobDocument { migrateJob(old.path) }
        let record = try jobStore.status(id)
        if let document = existingDocument, owns(record, document: document) { return record }
        if activeJobID == id, session.mcpHandle == jobHandle, let jobOwner, record.documentIdentity == jobOwner {
            return record
        }
        throw wrongJob()
    }

    @discardableResult
    func start(options: TranscriptJobOptions = .init(), operationID: UUID = UUID(),
               policy: TranscriptJobPolicy = .reuse, download: Bool = false) throws -> UUID {
        if activeJobID == operationID {
            if let startIntent, startIntent.options != options || startIntent.policy != policy || startIntent.download != download {
                throw operationConflict()
            }
            return operationID
        }
        if let record = try? jobStore.status(operationID) {
            _ = try status(record.id)
            guard record.options == options, (record.requestedPolicy ?? record.policy) == policy,
                  (record.requestedDownload ?? false) == download else { throw operationConflict() }
            return record.id
        }
        guard project.sequenceClips?.isEmpty != true else {
            throw CutError(code: "transcript_job_unavailable", message: "Add a media source before transcribing this project.")
        }
        let context = try assetContext().resolvingSymlinksInPath().standardizedFileURL
        let diskFingerprint = try? SourceIdentity(context).transcriptFingerprint
        let owner = try state.documentID ?? jobs().first?.documentIdentity ?? UUID()
        try adoptJobOwner(owner)
        let project = project
        let store = jobStore
        try launch(id: operationID, context: context, download: download) { token, progress in
            try store.prepare(project: project, documentID: context.path, relativeTo: context,
                              documentIdentity: owner, documentDiskFingerprint: diskFingerprint, options: options,
                              operationID: operationID, policy: policy, download: download,
                              cancelled: { token.isCancelled }, progress: progress)
        }
        startIntent = (options, policy, download)
        return operationID
    }

    @discardableResult
    func cancel(_ id: UUID) throws -> TranscriptJobRecord {
        if activeJobID == id, (try? jobStore.status(id)) == nil {
            explicitlyCancelled = true
            stopRequested = true
            cancellation?.cancel()
        }
        let record = try status(id)
        var cancelled = try jobStore.cancel(record.id)
        if (cancelled.state == .completed || cancelled.state == .partial), !isAttached(cancelled) {
            cancelled = try jobStore.cancelPendingAttachment(id, expectedPreparationID: cancelled.preparationID)
        }
        if activeJobID == id {
            explicitlyCancelled = true
            stopRequested = true
            cancellation?.cancel()
            job = cancelled
        } else if job?.id == id {
            job = cancelled
            if activeJobID == nil, cancelled.state == .cancelled { stopRequested = true }
        }
        return cancelled
    }

    @discardableResult
    func reconcile(attachmentID: String, download: Bool = false) throws -> UUID {
        let transcript = try document(attachmentID: attachmentID)
        guard let id = transcript.jobID.flatMap(UUID.init(uuidString:)),
              let record = try? status(id) else {
            throw CutError(code: "transcript_reconcile_unavailable",
                           message: "The attached transcript has no recognition job to reconcile.")
        }
        try retry(record.id, download: download)
        return record.id
    }

    func retry(_ id: UUID, download: Bool = false) throws {
        let record = try status(id)
        if let owner = record.documentIdentity { try adoptJobOwner(owner) }
        let context = try assetContext().resolvingSymlinksInPath().standardizedFileURL
        let store = jobStore
        let project = project
        try launch(id: id, context: context, download: download) { token, progress in
            try store.retry(id, project: project, relativeTo: context, cancelled: { token.isCancelled }, progress: progress)
        }
    }

    private func launch(id: UUID, context: URL, download: Bool,
                        preparation: @escaping @Sendable (EditCancellation, (TranscriptJobRecord) -> Void) throws -> TranscriptJobRecord) throws {
        guard activeJobID == nil else {
            throw CutError(code: "transcript_job_busy", message: "Wait for the active transcript job or cancel it first.")
        }
        guard Self.active[id] == nil else { throw operationConflict() }
        cancelJobDiscovery()
        let store = jobStore
        let initialSidecars = sidecarPolicy
        let token = EditCancellation()
        cancellation = token
        activeJobID = id
        publishedResults[id] = nil
        job = nil
        jobError = nil
        jobDocument = context
        jobOwner = state.documentID
        jobHandle = session.mcpHandle
        stopRequested = false
        explicitlyCancelled = false
        Self.active[id] = self
        let session = session
        worker = Task { [self, session] in
            defer {
                Self.active[id] = nil
                worker = nil
                activeJobID = nil
                cancellation = nil
                startIntent = nil
            }
            do {
                let publish: @Sendable (TranscriptJobRecord) -> Void = { [weak self] record in
                    Task { @MainActor in
                        guard let self, self.activeJobID == id, !self.stopRequested,
                              self.job.map({ $0.updatedAt <= record.updatedAt }) ?? true else { return }
                        self.job = record
                    }
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    // Ask the helper before any audio is extracted for it.
                    _ = try TranscriptJobStore.capabilities(helper: TranscriptJobStore.helperURL())
                    if token.isCancelled { throw CancellationError() }
                    return try initialSidecars.run { try preparation(token, publish) }
                }.value
                if stopRequested {
                    job = try explicitlyCancelled ? store.cancel(prepared.id) : store.interrupt(prepared.id)
                    return
                }
                migrateJob(prepared.documentID)
                for attempt in 0...3 {
                    guard !stopRequested else { return }
                    let sidecars = sidecarPolicy
                    let result = try await Task.detached(priority: .userInitiated) {
                        try sidecars.run { try store.run(prepared.id, download: download, progress: publish) }
                    }.value
                    job = result
                    guard !stopRequested, session.mcpHandle == jobHandle else { return }
                    if result.state == .completed || result.state == .partial {
                        do {
                            try await attach(result)
                            return
                        } catch let issue as CutError where issue.code == "stale_transcript_job" {
                            if attempt == 3 { throw issue }
                        }
                    } else if result.state != .stale {
                        return
                    }
                    guard attempt < 3, !stopRequested, session.mcpHandle == jobHandle,
                          let context = existingDocument else { return }
                    let current = project
                    let retrySidecars = sidecarPolicy
                    job = try await Task.detached(priority: .userInitiated) {
                        try retrySidecars.run {
                            try store.retry(result.id, project: current, relativeTo: context,
                                            cancelled: { token.isCancelled }, progress: publish)
                        }
                    }.value
                }
            } catch {
                if explicitlyCancelled { _ = try? store.cancel(id) }
                job = (try? store.status(id)) ?? job
                if !stopRequested { jobError = error.localizedDescription }
            }
        }
    }

    private func documentPathChanged() {
        closeSourceAudition()
        guard let context = existingDocument else {
            cancelJobDiscovery()
            return
        }
        let handle = session.mcpHandle
        var owner = state.documentID
        let previousDiscovery = jobDiscovery
        if previousDiscovery?.context == context, previousDiscovery?.handle == handle, previousDiscovery?.owner == owner {
            return
        }
        cancelJobDiscovery()
        let previousContext = jobDocument
        let sameDocument = jobHandle == handle
        if let old = previousContext, old != context, sameDocument { migrateJob(old.path) }
        guard activeJobID == nil else { return }
        if !sameDocument {
            if job != nil { job = nil }
            if jobError != nil { jobError = nil }
        }
        let store = jobStore
        // Save As can happen before the first discovery finishes. Its old file
        // intentionally still exists, so it is distinct from a Finder rename.
        if let previousDiscovery, previousDiscovery.handle == handle, previousDiscovery.context != context {
            do {
                let old = previousDiscovery.context
                if owner == nil {
                    let prior = try store.list(documentID: old.path).first { owns($0, document: old) }
                    if let identity = prior?.documentIdentity {
                        try adoptJobOwner(identity)
                        owner = identity
                    }
                }
                if let owner { try store.rebindDocument(from: old.path, to: context.path, documentIdentity: owner) }
            } catch { jobError = error.localizedDescription }
        }
        let task = Task { [weak self, weak session, owner] in
            guard !Task.isCancelled else { return }
            let discovery = Task.detached(priority: .utility) {
                try store.matchingRecords(documentID: context.path, documentIdentity: owner)
            }
            let result = await withTaskCancellationHandler {
                await discovery.result
            } onCancel: {
                discovery.cancel()
            }
            guard let self, let session, !Task.isCancelled else { return }
            jobDiscovery = nil
            guard activeJobID == nil, session.mcpHandle == handle, existingDocument == context else { return }
            guard owner == state.documentID else {
                documentPathChanged()
                return
            }
            recoverJobs(result, context: context, owner: owner, handle: handle,
                        isNewDocument: !sameDocument || previousContext != context)
        }
        jobDiscovery = (context, handle, owner, task)
    }

    private func cancelJobDiscovery() {
        jobDiscovery?.task.cancel()
        jobDiscovery = nil
    }

    private func recoverJobs(_ discovery: Result<[TranscriptJobRecord], Error>, context: URL, owner: UUID?,
                             handle: String, isNewDocument: Bool) {
        jobDocument = context
        let sameDocument = jobHandle == handle
        jobHandle = handle
        do {
            let candidates = try discovery.get()
            let records: [TranscriptJobRecord]
            if let owner, candidates.contains(where: { $0.documentIdentity == owner && $0.documentID != context.path }) {
                records = try jobs()
            } else {
                records = candidates.compactMap { try? jobStore.status($0.id) }
                    .filter { $0.documentID == context.path && owns($0, document: context) }
                    .sorted { jobOrder($0) == jobOrder($1) ? $0.updatedAt > $1.updatedAt : jobOrder($0) > jobOrder($1) }
            }
            jobOwner = state.documentID ?? records.first?.documentIdentity
            if let jobOwner { try adoptJobOwner(jobOwner) }
            if isNewDocument {
                job = records.first
                jobError = nil
            }
            if !sameDocument { stopRequested = false }
            let completed = records.reversed().filter { !$0.attached && ($0.state == .completed || $0.state == .partial) }
            if completed.contains(where: { publishedResults[$0.id] != nil }),
               let saved = try? CutProject.load(from: context) {
                for record in completed {
                    try acknowledge(record.id, ifPersistedIn: saved)
                }
            }
            guard isNewDocument, let latest = records.first else { return }
            guard !completed.isEmpty || latest.state == .stale else { return }
            Task { [weak session] in
                guard let session else { return }
                var needsReconciliation = !latest.attached && latest.state == .stale
                for record in completed {
                    guard !stopRequested, session.mcpHandle == handle, activeJobID == nil else { return }
                    guard (try? jobStore.status(record.id).attached) == false else { continue }
                    do {
                        try await attach(record)
                    } catch let issue as CutError where issue.code == "stale_transcript_job" {
                        if record.id == latest.id { needsReconciliation = true }
                    } catch {
                        if record.id == latest.id, !stopRequested { jobError = error.localizedDescription }
                    }
                }
                guard needsReconciliation, !stopRequested, session.mcpHandle == handle, activeJobID == nil else { return }
                do { try retry(latest.id) }
                catch { jobError = error.localizedDescription }
            }
        } catch { jobError = error.localizedDescription }
    }

    private func migrateJob(_ old: String) {
        guard let context = existingDocument, old != context.path, jobHandle == session.mcpHandle,
              let jobOwner else { return }
        do {
            try jobStore.rebindDocument(from: old, to: context.path, documentIdentity: jobOwner)
            jobDocument = context
        } catch { jobError = error.localizedDescription }
    }

    private func attach(_ record: TranscriptJobRecord) async throws {
        let store = jobStore
        let snapshot = project
        let revision = timelineRevision
        let transcriptRevision = state.revision
        let context = existingDocument
        let sidecars = sidecarPolicy
        let assets = try? assetContext()
        let generated = state.attachments.filter { $0.fingerprint != nil }
        let known = lineages
        // A result holds hours of words. Verifying the new one and reading which job made
        // each attached one both stay off the main thread, where playback is running.
        let (outputs, origins) = try await Task.detached(priority: .userInitiated) {
            let outputs = try sidecars.run { try store.verifiedDocuments(record.id, project: snapshot, relativeTo: context) }
            var origins: [String: ResultOrigin] = [:]
            for attachment in generated {
                if let origin = known[attachment.resultID] {
                    origins[attachment.resultID] = origin
                } else if let assets, let document = try? TranscriptStore.decoded(attachment.asset, relativeTo: assets) {
                    origins[attachment.resultID] = ResultOrigin(document)
                }
            }
            return (outputs, origins)
        }.value
        guard !stopRequested, existingDocument != nil, session.mcpHandle == jobHandle else { return }
        // A timeline-only edit can arrive during verification. Reverify against the new snapshot.
        guard revision == timelineRevision, transcriptRevision == state.revision else {
            return try await attach(record)
        }
        lineages = origins
        func verified() throws -> TranscriptJobRecord {
            let verifiedRecord = try store.status(record.id)
            guard let document = existingDocument, owns(verifiedRecord, document: document),
                  verifiedRecord.state == .completed || verifiedRecord.state == .partial,
                  verifiedRecord.preparationID == record.preparationID,
                  outputs.allSatisfy({ $0.preparationID == verifiedRecord.preparationID }),
                  verifiedRecord.sessions.map(\.fingerprint) == record.sessions.map(\.fingerprint) else {
                throw CutError(code: "stale_transcript_job", message: "The transcription job changed after verification.")
            }
            return verifiedRecord
        }
        var verifiedRecord = try verified()
        var accepted: [(transcript: TranscriptDocument, bindings: [TranscriptBinding], prior: String?)] = []
        var hadUsableSession = false
        let byOutput = Dictionary(uniqueKeysWithValues: verifiedRecord.sessions.map { ($0.output, $0) })
        let attached = attachmentLineages()
        for output in outputs {
            let transcript = output.document
            guard let jobSession = byOutput[output.url] else {
                throw CutError(code: "invalid_transcript_result", message: "The provider returned an unexpected session.")
            }
            let requestedTracks = Set(jobSession.tracks.filter(\.recognize).map(\.id))
            guard requestedTracks.isEmpty || transcript.tracks.contains(where: {
                $0.coverage == .recognized && requestedTracks.contains($0.id)
            }) else { continue }
            hadUsableSession = true
            let bindings = jobSession.bindings
            let scope = TranscriptJobScope(bindings, requested: requestedTracks)
            let prior = attached.first { $0.jobID == record.id && $0.scope == scope }
                ?? attached.first { $0.jobID == record.id && (session.isMulticam || $0.scope.sources == scope.sources) }
                ?? attached.first { !scope.streams.isEmpty && $0.scope == scope }
            if let prior, prior.jobID != record.id {
                if let priorRecord = try? store.status(prior.jobID) {
                    if jobOrder(priorRecord) > jobOrder(record) { continue }
                } else if activeJobID != record.id {
                    // A recovered job cannot establish that it supersedes this saved attachment.
                    continue
                }
            }
            accepted.append((transcript, bindings, prior?.attachmentID))
        }
        guard hadUsableSession else {
            throw CutError(code: "transcript_job_unavailable", message: "No audio track in this job completed transcription.")
        }
        guard !accepted.isEmpty else { return }
        let destination = try assetContext()
        let draft = session.isMulticam ? session.multicam.projectURL == nil : session.editor.projectURL == nil
        let documents = accepted.map(\.transcript)
        let stored = try await Task.detached(priority: .userInitiated) {
            try documents.map {
                try TranscriptStore.put(TranscriptCodec.encode($0, format: .json), relativeTo: destination, draft: draft)
            }
        }.value
        // Writing the results takes time. Everything checked before it is checked again.
        guard !stopRequested, existingDocument != nil, session.mcpHandle == jobHandle else { return }
        guard revision == timelineRevision, transcriptRevision == state.revision, (try? assetContext()) == destination else {
            return try await attach(record)
        }
        verifiedRecord = try verified()
        var next = state
        var resultIDs = Set<String>()
        for (result, asset) in zip(accepted, stored) {
            let existing = result.prior.flatMap { prior in next.attachments.firstIndex { $0.id == prior } }
            resultIDs.insert(asset.sha256)
            lineages[asset.sha256] = ResultOrigin(result.transcript)
            if let existing, next.attachments[existing].resultID == asset.sha256 { continue }
            let attachment = TranscriptAttachment(id: existing.map { next.attachments[$0].id } ?? UUID().uuidString,
                                                  asset: asset, bindings: result.bindings,
                                                  fingerprint: result.transcript.fingerprint)
            if let existing { next.attachments[existing] = attachment }
            else { next.attachments.append(attachment) }
            // The reader opens this result next. It need not decode what was just encoded.
            importedDocument = (asset, destination, result.transcript)
        }
        let verifiedOutputs = Set(outputs.map(\.url))
        let verifiedTracks = verifiedRecord.sessions.filter { verifiedOutputs.contains($0.output) }.flatMap(\.tracks)
        guard verifiedTracks.allSatisfy(\.sourceIsCurrent) else {
            throw CutError(code: "stale_transcript_job", message: "A recording changed while the transcript result was attaching.")
        }
        try setState(next)
        publishedResults[record.id] = (verifiedRecord.preparationID, resultIDs)
        if let context = existingDocument, let saved = try? CutProject.load(from: context) {
            try acknowledge(record.id, ifPersistedIn: saved)
        }
    }

    private func acknowledge(_ id: UUID, ifPersistedIn project: CutProject) throws {
        guard let expected = publishedResults[id], !expected.resultIDs.isEmpty,
              expected.resultIDs.isSubset(of: Set(project.transcripts.attachments.map(\.resultID))) else { return }
        try jobStore.markAttached(id, expectedPreparationID: expected.preparationID)
        publishedResults[id] = nil
    }

    private struct TranscriptJobScope: Equatable {
        struct Stream: Hashable {
            let location: String
            let index: Int
            let channel: Int?
        }

        let streams: Set<Stream>
        let sources: Set<String>

        init(_ bindings: [TranscriptBinding], requested: Set<String>) {
            func location(_ binding: TranscriptBinding) -> String {
                binding.sourceID ?? binding.file ?? binding.trackID
            }
            streams = Set(bindings.filter { requested.contains($0.trackID) }.map {
                Stream(location: location($0), index: $0.streamIndex, channel: $0.channel)
            })
            sources = Set(bindings.map(location))
        }
    }

    private struct AttachmentLineage {
        let attachmentID: String
        let jobID: UUID
        let scope: TranscriptJobScope
    }

    /// The job that produced a stored result and the tracks it was asked to recognize.
    private struct ResultOrigin: Sendable {
        let jobID: UUID?
        let requested: Set<String>

        init(_ document: TranscriptDocument) {
            jobID = document.jobID.flatMap(UUID.init(uuidString:))
            requested = Set(document.tracks.filter { $0.coverage == .recognized || $0.coverage == .failed }.map(\.id))
        }
    }

    private func attachmentLineages() -> [AttachmentLineage] {
        state.attachments.compactMap { attachment in
            guard attachment.fingerprint != nil, let origin = lineages[attachment.resultID],
                  let jobID = origin.jobID else { return nil }
            return AttachmentLineage(attachmentID: attachment.id, jobID: jobID,
                                     scope: TranscriptJobScope(attachment.bindings, requested: origin.requested))
        }
    }

    private func jobOrder(_ record: TranscriptJobRecord) -> Date {
        record.createdAt ?? record.updatedAt
    }

    private func operationConflict() -> CutError {
        CutError(code: "transcript_operation_conflict", message: "This operation ID belongs to another transcript request.")
    }

    private func wrongJob() -> CutError {
        CutError(code: "transcript_job_not_found", message: "Choose a transcript job belonging to this document.")
    }

    func prepareForWindowEnd(preservingDraft: Bool = false) {
        closeSourceAudition()
        cancelJobDiscovery()
        indexes.keep { _ in false }
        indexLoads.values.forEach { $0.task.cancel() }
        indexLoads.removeAll()
        guard let context = existingDocument else { return }
        TranscriptStore.releaseDecoded(relativeTo: context)
        if let old = jobDocument, old != context, !ProjectDraft.isManaged(context) {
            migrateJob(old.path)
        }
        guard ProjectDraft.isManaged(context), !preservingDraft else {
            // This window is the job's only owner. A helper left running after it closes could
            // not be cancelled, watched or attached from the reopened project. Stop it and leave
            // the record resumable, as quitting does. Finished tracks are reused on retry.
            if let id = activeJobID {
                stopRequested = true
                cancellation?.cancel()
                _ = try? jobStore.interrupt(id)
            }
            return
        }
        stopRequested = true
        cancellation?.cancel()
        let store = jobStore
        if let id = activeJobID { _ = try? store.cancel(id) }
        if let pending = worker {
            Task {
                await pending.value
                try? store.discard(documentID: context.path)
            }
        } else {
            try? store.discard(documentID: context.path)
        }
    }

    static var hasActiveJobs: Bool { !active.isEmpty }

    static func interruptActiveJobs() async {
        let running = Array(active.values)
        for controller in running {
            controller.stopRequested = true
            controller.cancellation?.cancel()
            if let id = controller.activeJobID { _ = try? controller.jobStore.interrupt(id) }
        }
        for controller in running { await controller.worker?.value }
    }
}

extension LiveTranscriptController {
    func prepareIndex(attachmentID: String? = nil) throws -> @Sendable () throws -> TranscriptIndex {
        try buildIndex(for: indexKey(attachmentID: attachmentID))
    }

    func prepareCoverageIndex(attachmentID: String? = nil) throws -> @Sendable () throws -> TranscriptIndex {
        let key = try indexKey(attachmentID: attachmentID)
        if let index = indexes.index(for: key) { return { index } }
        return buildIndex(for: key, spaces: [])
    }

    private func buildIndex(for key: IndexKey, spaces: Set<TranscriptSpace> = Set(TranscriptSpace.allCases))
        -> @Sendable () throws -> TranscriptIndex {
        let sequenceMedia = session.editor.transcriptMedia
        let multicamMedia = session.multicam.media
        let records = state.authoring
        let staged = importedDocument.flatMap {
            $0.asset == key.attachment.asset && $0.context == key.context ? $0.document : nil
        }
        let builds = indexBuilds
        // A review sheet asks for every attachment's index each time it opens. Whoever builds
        // one leaves it for the next reader of the same revision.
        let shelf = spaces.count == TranscriptSpace.allCases.count ? indexes : nil
        return {
            if let built = shelf?.index(for: key) { return built }
            try Task.checkCancellation()
            builds.increment()
            // The document just imported is already decoded. Its stored copy is still verified.
            let document = try TranscriptStore.decoded(key.attachment.asset, relativeTo: key.context, known: staged)
            try Task.checkCancellation()
            let index: TranscriptIndex
            if case .multicam = key.project {
                // Source, Group and Current Cut each take about a third of a multicam build, so
                // they are built side by side. A sequence spends nearly all of it on Current Cut.
                index = try .concurrent(document: document, attachment: key.attachment,
                                        project: key.project, projectURL: key.context,
                                        sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                        timelineRevision: key.revision.timelineRevision,
                                        records: records, spaces: spaces)
            } else {
                index = try TranscriptIndex(document: document, attachment: key.attachment,
                                            project: key.project, projectURL: key.context,
                                            sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                            timelineRevision: key.revision.timelineRevision, records: records, spaces: spaces)
            }
            try Task.checkCancellation()
            shelf?.remember(index, for: key)
            return index
        }
    }

    func preparePlan(_ request: TranscriptEditRequest, attachmentID: String? = nil,
                     index: TranscriptIndex? = nil) throws -> @Sendable () throws -> TranscriptEditPlan {
        let review = try preparePlanReview(request, attachmentID: attachmentID, index: index)
        return { try review().plan }
    }

    func preparePlanReview(_ request: TranscriptEditRequest, attachmentID: String? = nil,
                           index: TranscriptIndex? = nil) throws
        -> @Sendable () throws -> (plan: TranscriptEditPlan, evidence: [String: TranscriptIndex]) {
        let input = try planAttachments(request, defaultID: attachmentID)
        let attachment = input.primary
        let revision = revision(of: attachment)
        let project = project
        let context = try assetContext()
        let sequenceMedia = session.editor.transcriptMedia
        let multicamMedia = session.multicam.media
        let build = try prepareIndex(attachmentID: attachment.id)
        let additional = try input.required.map { try prepareIndex(attachmentID: $0) }
        let evidence = input.review.compactMap { try? prepareIndex(attachmentID: $0) }
        let matchingIndex = index.flatMap {
            $0.attachment == attachment && $0.timelineRevision == revision.timelineRevision
                && $0.transcriptRevision == revision.transcriptRevision ? $0 : nil
        }
        let sidecars = sidecarPolicy
        return {
            try sidecars.run {
                let primary = try matchingIndex ?? build()
                let supporting = try additional.map { try $0() }
                try Task.checkCancellation()
                let plan = try TranscriptEditPlanner.plan(request, in: primary, project: project,
                                                          revision: revision, relativeTo: context,
                                                          sequenceMedia: sequenceMedia, multicamMedia: multicamMedia,
                                                          additionalIndexes: supporting + evidence.compactMap { try? $0() })
                let scoped = Dictionary(uniqueKeysWithValues: ([primary] + supporting).compactMap { item in
                    item.attachment.map { ($0.id, item) }
                })
                return (plan, scoped)
            }
        }
    }

    func prepareExport(format: TranscriptFormat, space: TranscriptSpace,
                       attachmentID: String? = nil) throws -> @Sendable () throws -> Data {
        let build = try prepareIndex(attachmentID: attachmentID)
        return { try TranscriptCodec.encode(build(), space: space, format: format) }
    }

}
