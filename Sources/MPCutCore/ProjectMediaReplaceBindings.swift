import Foundation

extension ReplaceEdit {
    /// Keep the original evidence when changing the path. A different recording
    /// leaves the decision available for review, while an identical copy verifies.
    func rebindAnalysis(in revised: inout CutProject) throws {
        var annotations = revised.analysisAnnotations
        guard !annotations.isEmpty else { return }
        func files(_ state: CutProject) -> [String: String] {
            if case .multicam(let group) = state {
                return Dictionary(uniqueKeysWithValues: group.sources.map { ($0.id, $0.file) })
            }
            var result = Dictionary((state.sequenceClips ?? []).map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
            if let track = state.stillSoundtrack { result[track.id] = track.file }
            if case .stillSequence(let sequence) = state {
                if let reference = sequence.stillAudioReference { result[reference.id] = reference.file }
                for select in sequence.sourceSelects { result[select.id] = select.range.file }
            }
            return result
        }
        let original = files(project), current = files(revised)
        let changed = Set(original.keys.filter { id in
            original[id].map(sameSource) == true && original[id] != destination && current[id] == destination
        })
        guard !changed.isEmpty else { return }
        let keepsOriginal = current.values.contains { $0 != destination && sameSource($0) }
        let conflict = CutError(code: "conflicting_analysis_annotations",
                                message: "Both recordings have different saved analysis decisions for the same stream. Resolve the conflicting decision before replacing the recording.")
        let scenes = annotations.scenes.filter { $0.file != destination && sameSource($0.file) }
        let levels = annotations.silence.filter { $0.file != destination && sameSource($0.file) }
        if !keepsOriginal {
            annotations.scenes.removeAll { $0.file != destination && sameSource($0.file) }
            annotations.silence.removeAll { $0.file != destination && sameSource($0.file) }
        }
        for var scene in scenes {
            scene.file = destination
            if let other = annotations.scenes.first(where: { $0.file == destination && $0.sourceEvidence == scene.sourceEvidence }) {
                guard other.views == scene.views && other.scenes == scene.scenes else { throw conflict }
            } else { annotations.scenes.append(scene) }
        }
        for var level in levels {
            level.file = destination
            if let other = annotations.silence.first(where: { $0.file == destination && $0.sourceEvidence == level.sourceEvidence }) {
                guard other.thresholdDB == level.thresholdDB else { throw conflict }
            } else { annotations.silence.append(level) }
        }
        annotations.pauseReviews = annotations.pauseReviews.map { row in
            var moved = row
            for index in row.sources.indices {
                let input = row.sources[index]
                if sameSource(input.file) && (!keepsOriginal || (input.sourceID ?? row.occurrenceID).map(changed.contains) == true) {
                    moved.sources[index].file = destination
                }
            }
            return moved
        }
        revised.analysisAnnotations = annotations
    }

    func reviseParticipants(_ participants: inout ParticipantProject, id: String, newID: String,
                            preserveOriginal: Bool) throws {
        guard let media else { return }
        if !preserveOriginal, let index = participants.pendingReviews.firstIndex(where: { $0.sourceID == id }) {
            // A replacement can make evidence stale, but the original review remains recoverable.
            if id != newID, participants.pendingReviews.contains(where: { $0.sourceID == newID }) {
                throw invalidParticipantProject("Both recordings have pending tile reviews. Resolve a review before replacing the recording.")
            }
            participants.pendingReviews[index].sourceID = newID
            participants.pendingReviews[index].file = destination
        }
        let existing = participants.sources.first { $0.sourceID == id }
        let existingDestination = id != newID ? participants.sources.first { $0.sourceID == newID } : nil
        let redactions = participants.effectiveRedactions
        let legacy = participants.render?.redactions ?? []
        let legacyScope = redactions.contains(where: legacy.contains)
        let roster = Set(participants.people.map(\.id))
        let treated = Set(redactions.map(\.participantID))
        func knownFeeds(_ source: ParticipantSourceGeometry) -> Set<String> {
            Set(source.appearances.compactMap(\.participantID)).union(source.historicalParticipantIDs ?? [])
                .union(source.unresolvedParticipantIDs).intersection(roster)
        }
        func scope(_ source: ParticipantSourceGeometry) -> Set<String> {
            if legacyScope || source.appearances.contains(where: \.hasUnresolvedIdentity)
                || (source.appearances.isEmpty && source.analysisIdentity == nil) { return roster }
            return knownFeeds(source)
        }
        if !preserveOriginal, id != newID {
            participants.render = participants.render?.mapSourcePaths { $0 == id ? newID : $0 }
        }
        guard existing != nil || legacyScope else {
            remapParticipantAudio(&participants, id: id, newID: newID, preserveOriginal: preserveOriginal)
            return
        }

        let previousDigest = existing?.sourceContentSHA256
        if previousDigest != nil || existingDestination?.sourceContentSHA256 != nil, candidateDigest == nil {
            candidateDigest = try participantSourceDigest(candidate, identity: identity, cancelled: cancelled)
        }
        let destinationIsCurrent = existingDestination?.sourceContentSHA256 != nil
            && existingDestination?.sourceContentSHA256 == candidateDigest
        let compatibleLayout = existingDestination.map {
            ($0.feedLayout ?? .meeting) == (existing?.feedLayout ?? .meeting)
        } ?? true
        let copied = compatibleLayout && previousDigest != nil && previousDigest == candidateDigest
        var replacement = existing ?? .init(sourceID: newID)
        replacement.sourceID = newID
        replacement.confirmations = nil
        replacement.sourceStamp = SceneSourceStamp(media: media)
        replacement.sourceInode = identity.inode

        let oldOverrides = participants.appearanceOverrides.filter { $0.sourceID == id }
        if copied, id != newID, !preserveOriginal {
            for index in participants.people.indices where participants.people[index].legacyPresentation?.sourceID == id {
                participants.people[index].legacyPresentation?.sourceID = newID
            }
        }
        if !copied {
            // The destination may already have its own accepted review, used by
            // other clips. Only invalidate geometry that lacks content proof.
            let geometry = [existing, destinationIsCurrent ? nil : existingDestination].compactMap { $0 }
            let affected = legacyScope ? roster : geometry.reduce(into: Set<String>()) { $0.formUnion(scope($1)) }
            let history = geometry.reduce(into: Set<String>()) { $0.formUnion(knownFeeds($1)) }
            replacement.scanEvents = []
            replacement.countHints = nil
            replacement.layoutCapacityRanges = nil
            replacement.analysisIdentity = nil
            replacement.sourceContentSHA256 = nil
            replacement.appearances = []
            replacement.coverage = []
            replacement.historicalParticipantIDs = history.isEmpty ? nil : history.sorted()
            replacement.unresolvedParticipantIDs = affected.sorted()
            report.participantIDs = Set(report.participantIDs + affected).sorted()
            report.affectedRedactionIDs = Set(report.affectedRedactionIDs).union(affected.intersection(treated)).sorted()
            report.warnings.append("Participant geometry and privacy treatments require review before participant export.")

            let removed = Set(geometry.flatMap { $0.appearances.map(\.id) })
            report.removedAppearanceIDs = Set(report.removedAppearanceIDs).union(removed).sorted()
            let slots = participants.render?.shots.flatMap(\.slots) ?? []
            report.affectedParticipantSlotIDs = Set(report.affectedParticipantSlotIDs + slots.filter {
                ($0.target == .camera && ($0.id == id || $0.id == newID)) ||
                    ($0.target == .presentation && removed.contains($0.id))
            }.map(\.id)).sorted()
            report.affectedParticipantBindingIDs = Set(report.affectedParticipantBindingIDs + participants.people.filter {
                affected.contains($0.id) && ($0.audio != nil || !$0.speakers.isEmpty)
            }.map(\.id)).sorted()
        }
        if !preserveOriginal {
            participants.appearanceOverrides.removeAll { $0.sourceID == id }
            participants.sources.removeAll { $0.sourceID == id }
        }
        if destinationIsCurrent, let index = participants.sources.firstIndex(where: { $0.sourceID == newID }) {
            var current = participants.sources[index]
            let history = Set(current.historicalParticipantIDs ?? []).union(knownFeeds(replacement))
            current.historicalParticipantIDs = history.isEmpty ? nil : history.sorted()
            var unresolved = Set(current.unresolvedParticipantIDs).union(replacement.unresolvedParticipantIDs)
            if copied && (current.appearances != replacement.appearances || current.coverage != replacement.coverage) {
                let affected = scope(replacement)
                unresolved.formUnion(affected)
                report.participantIDs = Set(report.participantIDs).union(affected).sorted()
                report.affectedRedactionIDs = Set(report.affectedRedactionIDs).union(affected.intersection(treated)).sorted()
                report.warnings.append("The destination has a different tile review for the same recording. Resolve the conflicting assignments before participant export.")
            }
            current.unresolvedParticipantIDs = unresolved.sorted()
            current.sourceStamp = replacement.sourceStamp
            current.sourceInode = replacement.sourceInode
            current.confirmations = nil
            participants.sources[index] = current
        } else {
            participants.sources.removeAll { $0.sourceID == newID }
            participants.appearanceOverrides.removeAll { $0.sourceID == newID }
            participants.sources.append(replacement)
            if copied {
                report.warnings.append("Accepted participant geometry is retained for the identical recording and feed layout.")
                participants.appearanceOverrides += oldOverrides.map {
                    var copy = $0
                    copy.sourceID = newID
                    return copy
                }
            }
        }
        remapParticipantAudio(&participants, id: id, newID: newID, preserveOriginal: preserveOriginal)
    }

    private func remapParticipantAudio(_ participants: inout ParticipantProject, id: String, newID: String,
                                       preserveOriginal: Bool) {
        guard !preserveOriginal else { return }
        if case .multicam = project { return }
        for index in participants.people.indices {
            guard let selection = participants.people[index].audio?.selection, selection.source == id else { continue }
            participants.people[index].audio?.selection = .init(source: newID, stream: mapStream(selection.stream))
            report.warnings.append("Review participant audio bindings for the replaced recording.")
        }
    }

    func replaceTranscripts(_ revised: CutProject) throws -> ProjectTranscripts {
        let transcripts = revised.transcripts
        var result = transcripts
        guard let media, !transcripts.isEmpty else { return result }
        let selected = Set(uses.map(\.id))
        let multicamSources: Set<String>
        if case .multicam(let multicam) = revised {
            multicamSources = Set(multicam.sources.map(\.id))
        } else {
            multicamSources = []
        }
        var sequenceClips = revised.sequenceClips ?? []
        if case .stillSequence(let sequence) = revised, let reference = sequence.stillAudioReference {
            sequenceClips.append(reference)
        }
        if let soundtrack = revised.stillSoundtrack { sequenceClips.append(soundtrack) }
        let retainsOldPath = oldURL.path != candidate.path && sequenceClips.contains { sameSource($0.file) }
        let replacedSequenceUse = sequenceClips.contains { selected.contains($0.id) && $0.file == destination }

        func replace(_ binding: TranscriptBinding, owner: String, attachmentID: String) -> TranscriptBinding {
            let affects: Bool
            if let id = binding.sourceID {
                affects = multicamSources.contains(id) && offsets[id] != nil
            } else if let file = binding.file, sameSource(file) {
                affects = selectedID == nil || selected.contains(owner) || selected.contains("\(attachmentID)/\(binding.trackID)")
                    || (!retainsOldPath && replacedSequenceUse)
            } else {
                affects = false
            }
            guard affects else { return binding }
            var copy = binding
            let previousFingerprint = previousEntry?.sourceFingerprint
                ?? oldMedia?.identity.transcriptFingerprint
            // Unverified replacement bindings cannot enable pause protection.
            copy.sourceFingerprint = binding.sourceFingerprint ?? previousFingerprint ?? String(repeating: "0", count: 64)
            if options.transcript == .retranscribe,
               copy.sourceFingerprint == media.identity.transcriptFingerprint {
                copy.sourceFingerprint = String(repeating: "0", count: 64)
            }
            copy.sourceConfirmed = false
            copy.streamIndex = mapStream(binding.streamIndex, channel: binding.channel)
            copy.sequenceStreamOrdinal = binding.sequenceStreamOrdinal.map { ordinal in
                audio.firstIndex { $0.index == copy.streamIndex } ?? ordinal
            }
            if binding.file != nil { copy.file = destination }
            if binding.sequenceClockOrigin != nil { copy.sequenceClockOrigin = media.origin }
            return copy
        }
        for index in result.attachments.indices {
            let attachment = result.attachments[index]
            let bindings = attachment.bindings.map {
                replace($0, owner: "\(attachment.id)/\($0.trackID)", attachmentID: attachment.id)
            }
            if bindings != attachment.bindings {
                result.attachments[index].bindings = bindings
                report.affectedTranscriptIDs.append(attachment.id)
            }
        }
        result.authoring = result.authoring.map { record in
            func change(_ anchor: TranscriptAnchor, index: String) -> TranscriptAnchor {
                var copy = anchor
                copy.binding = replace(anchor.binding, owner: "\(record.id)/\(index)/\(anchor.binding.trackID)",
                                       attachmentID: record.attachmentID)
                return copy
            }
            let updated = TranscriptAuthoredRecord(id: record.id, attachmentID: record.attachmentID, change: record.change,
                anchors: record.anchors.enumerated().map { change($0.element, index: String($0.offset)) },
                speakerReference: record.speakerReference.map { change($0, index: "speaker") })
            if updated != record { report.affectedTranscriptIDs.append(record.attachmentID) }
            return updated
        }
        if result != transcripts {
            try result.advanceRevision()
            report.affectedTranscriptIDs = Set(report.affectedTranscriptIDs).sorted()
            report.warnings.append(options.transcript == .retranscribe
                ? "Re-transcribe the affected tracks to replace the previous words."
                : "Existing transcript words are retained as unverified.")
        }
        return result
    }
}
