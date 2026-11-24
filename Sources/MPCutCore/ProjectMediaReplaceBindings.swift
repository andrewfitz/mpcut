import Foundation

extension ReplaceEdit {
    func reviseParticipants(_ participants: inout ParticipantProject, id: String, newID: String,
                            preserveOriginal: Bool) throws {
        guard let media else { return }
        let existing = participants.sources.first { $0.sourceID == id }
        let existingDestination = id != newID ? participants.sources.first { $0.sourceID == newID } : nil
        let redacted = participants.render?.redactions.map(\.participantID) ?? []
        if !preserveOriginal, id != newID {
            participants.render = participants.render?.mapSourcePaths { $0 == id ? newID : $0 }
        }
        guard existing != nil || existingDestination != nil || !redacted.isEmpty else {
            remapParticipantAudio(&participants, id: id, newID: newID, preserveOriginal: preserveOriginal)
            return
        }

        let previousDigest = existing?.sourceContentSHA256
        if previousDigest != nil, candidateDigest == nil {
            candidateDigest = try participantSourceDigest(candidate, identity: identity, cancelled: cancelled)
        }
        let compatibleLayout = existingDestination.map {
            ($0.feedLayout ?? .meeting) == (existing?.feedLayout ?? .meeting)
        } ?? true
        let copied = compatibleLayout && previousDigest != nil && previousDigest == candidateDigest
        var replacement = existing ?? .init(sourceID: newID)
        replacement.sourceID = newID
        replacement.sourceStamp = SceneSourceStamp(media: media)
        replacement.sourceInode = identity.inode

        let oldOverrides = participants.appearanceOverrides.filter { $0.sourceID == id }
        if copied {
            report.warnings.append("Accepted participant geometry is retained for the identical recording and feed layout.")
        } else {
            let affected = participants.people.map(\.id)
            replacement.analysisIdentity = nil
            replacement.sourceContentSHA256 = nil
            replacement.appearances = []
            replacement.coverage = []
            replacement.unresolvedParticipantIDs = affected.sorted()
            report.participantIDs = Set(report.participantIDs + affected).sorted()
            report.affectedRedactionIDs = Set(report.affectedRedactionIDs + redacted).sorted()
            report.warnings.append("Participant geometry and privacy treatments require review before participant export.")

            let removed = Set(existing?.appearances.map(\.id) ?? [])
                .union(existingDestination?.appearances.map(\.id) ?? [])
            report.removedAppearanceIDs = Set(report.removedAppearanceIDs).union(removed).sorted()
            let slots = participants.render?.shots.flatMap(\.slots) ?? []
            report.affectedParticipantSlotIDs = Set(report.affectedParticipantSlotIDs + slots.filter {
                ($0.target == .camera && ($0.id == id || $0.id == newID)) ||
                    ($0.target == .presentation && removed.contains($0.id))
            }.map(\.id)).sorted()
            report.affectedParticipantBindingIDs = Set(report.affectedParticipantBindingIDs + participants.people.filter {
                $0.audio != nil || !$0.speakers.isEmpty
            }.map(\.id)).sorted()
        }
        if !preserveOriginal {
            participants.appearanceOverrides.removeAll { $0.sourceID == id }
            participants.sources.removeAll { $0.sourceID == id }
        }
        let destinationIsCurrent = existingDestination?.sourceContentSHA256 == candidateDigest
            && existingDestination?.sourceContentSHA256 != nil
        if copied, destinationIsCurrent, let index = participants.sources.firstIndex(where: { $0.sourceID == newID }) {
            participants.sources[index].sourceStamp = replacement.sourceStamp
            participants.sources[index].sourceInode = replacement.sourceInode
        } else {
            participants.sources.removeAll { $0.sourceID == newID }
            participants.appearanceOverrides.removeAll { $0.sourceID == newID }
            participants.sources.append(replacement)
            if copied {
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
        guard id != newID, !preserveOriginal else { return }
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
