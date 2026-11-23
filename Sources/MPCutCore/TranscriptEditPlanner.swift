import Foundation

public enum TranscriptEditPlanner {
    public static func select(_ selection: TranscriptWordSelection, in index: TranscriptIndex) throws -> TranscriptResolvedSelection {
        guard selection.attachmentID == nil || selection.attachmentID == index.attachment?.id else {
            throw transcriptEditError("Open the attachment named by this selection.", code: "unknown_transcript_attachment")
        }
        func locate(_ wordID: String, occurrence: String?, matching first: TranscriptOccurrence? = nil) throws -> TranscriptOccurrence {
            let candidates = index.locate(wordID: wordID, space: selection.space).filter {
                occurrence == nil || occurrence == $0.id
            }
            if occurrence == nil, candidates.count > 1, let first {
                let scoped = candidates.filter {
                    if let clipID = first.clipID { return $0.clipID == clipID }
                    if let assemblyIndex = first.assemblyIndex { return $0.assemblyIndex == assemblyIndex }
                    return selection.space == .source && $0.trackID == first.trackID
                }
                if scoped.count == 1 { return scoped[0] }
            }
            if candidates.count > 1 {
                throw transcriptEditError("Word ‘\(wordID)’ has several locations. Supply an occurrence ID.",
                                          code: "ambiguous_transcript_occurrence")
            }
            guard let word = candidates.first else {
                throw transcriptEditError("Word ‘\(wordID)’ has no matching location in this transcript view.",
                                          code: "unknown_transcript_occurrence")
            }
            return word
        }

        let first = try locate(selection.firstWordID, occurrence: selection.firstOccurrenceID)
        let last: TranscriptOccurrence
        if let lastWordID = selection.lastWordID {
            last = try locate(lastWordID, occurrence: selection.lastOccurrenceID
                              ?? (lastWordID == selection.firstWordID ? selection.firstOccurrenceID : nil), matching: first)
        } else {
            guard selection.lastOccurrenceID == nil else {
                throw transcriptEditError("An end occurrence requires an end word ID.")
            }
            last = first
        }
        if selection.space == .source {
            guard first.trackID != nil, first.trackID == last.trackID, first.sourceRange != nil, last.sourceRange != nil else {
                throw transcriptEditError("A source phrase needs both ends on one identified transcript track.")
            }
        }
        guard first.range.from <= last.range.from else {
            throw transcriptEditError("Select the phrase endpoints in display order.")
        }

        let leading = selection.leadingPadding ?? .zero
        let trailing = selection.trailingPadding ?? .zero
        guard leading >= .zero, trailing >= .zero else {
            throw transcriptEditError("Padding must be nonnegative.")
        }
        let from: RationalTime
        let to: RationalTime
        switch selection.kind {
        case .phrase:
            from = try first.range.from.subtracting(leading)
            to = try max(first.range.to, last.range.to).adding(trailing)
        case .gap:
            guard first.range.to < last.range.from else {
                throw transcriptEditError("The selected words overlap or touch. There is no pause between them.",
                                          code: "no_transcript_gap")
            }
            from = try first.range.to.adding(leading)
            to = try last.range.from.subtracting(trailing)
            guard from < to else {
                throw transcriptEditError("The requested padding leaves no pause to select.", code: "no_transcript_gap")
            }
        }
        var seen = Set<String>()
        let overlapping = index.overlapping(.init(from: from, to: to), space: selection.space).compactMap { word -> String? in
            guard word.id != first.id, word.id != last.id, word.range.to > from,
                  selection.space != .source || word.trackID == first.trackID,
                  seen.insert(word.wordID).inserted else { return nil }
            return word.wordID
        }
        return .init(space: selection.space, kind: selection.kind, range: .init(from: from, to: to),
                     first: first, last: last, overlappingWordIDs: overlapping, attachmentID: index.attachment?.id)
    }

    private struct SpeechKey: Hashable {
        let range: MulticamRange
        let lane: String?
        let attachment: String?
        let source: String?
        let stream: Int?
        let text: String
    }

    private static func distinctSpeech(_ words: [TranscriptOccurrence]) -> [TranscriptOccurrence] {
        var seen = Set<SpeechKey>()
        // Prefer direct routed recognition when another attachment has inferred
        // the same word at the same output location. Different lanes survive.
        let preferred = words.filter { $0.audibility != .inferred } + words.filter { $0.audibility == .inferred }
        return preferred.filter { word in
            let source = word.routedSourceID ?? word.clipID ?? word.file ?? word.sourceID
            let stream = word.routedStreamIndex ?? word.sequenceStreamOrdinal ?? word.streamIndex
            let wording = TranscriptIndex.tokens(word.originalText).joined(separator: " ")
            return seen.insert(.init(range: word.range, lane: word.laneID,
                                     attachment: word.laneID == nil ? nil : word.attachmentID,
                                     source: source, stream: stream,
                                     text: wording.isEmpty ? word.originalText : wording)).inserted
        }.sorted {
            if $0.range.from != $1.range.from { return $0.range.from < $1.range.from }
            return $0.id < $1.id
        }
    }

    public static func plan(_ request: TranscriptEditRequest, in index: TranscriptIndex, project: CutProject,
                            revision: TranscriptEditRevision, relativeTo projectURL: URL? = nil,
                            sequenceMedia: [String: MediaInfo] = [:],
                            multicamMedia: [String: MediaInfo] = [:],
                            additionalIndexes: [TranscriptIndex] = []) throws -> TranscriptEditPlan {
        guard index.timelineRevision == revision.timelineRevision,
              project.transcripts.revision == revision.transcriptRevision,
              project.transcripts.attachments.contains(where: { $0.resultID == revision.resultID }) else {
            throw transcriptEditError("Reload the current project and transcript revisions before planning.",
                                      code: "stale_transcript_plan")
        }
        guard let attachment = index.attachment, attachment.resultID == revision.resultID,
              project.transcripts.attachments.contains(attachment) else {
            throw transcriptEditError("The index does not match the current transcript attachment.",
                                      code: "stale_transcript_plan")
        }
        var indexes = [attachment.id: index]
        for additional in additionalIndexes {
            guard additional.timelineRevision == revision.timelineRevision, let binding = additional.attachment,
                  project.transcripts.attachments.contains(binding) else {
                throw transcriptEditError("A selection uses an attachment or index that has changed.",
                                          code: "stale_transcript_plan")
            }
            if indexes[binding.id] == nil { indexes[binding.id] = additional }
        }
        func resolve(_ selection: TranscriptWordSelection) throws -> TranscriptResolvedSelection {
            let id = selection.attachmentID ?? attachment.id
            guard let selectedIndex = indexes[id] else {
                throw transcriptEditError("Attachment ‘\(id)’ is unavailable for this selection.",
                                          code: "unknown_transcript_attachment")
            }
            return try select(selection, in: selectedIndex)
        }
        let timeline = try TranscriptEditTimeline(project, relativeTo: projectURL)
        let preflight = TranscriptBoundaryResolver(project: project, timeline: timeline, projectURL: projectURL,
                                                   sequenceMedia: sequenceMedia, multicamMedia: multicamMedia)
        let selected = try request.selections.map(resolve)
        guard let first = selected.first else { throw transcriptEditError("Select at least one word or gap.") }
        let target = try request.target.map(resolve)
        let resolvedSelections = selected + [target].compactMap { $0 }
        guard !resolvedSelections.flatMap({ [$0.first, $0.last] }).contains(where: {
            $0.bindingStatus == .changed || $0.bindingStatus == .bindingMissing
        }) else {
            throw transcriptEditError("Relink or rebind the recordings before planning this passage.",
                                      code: "transcript_binding_unavailable")
        }
        let usedIDs = Set(resolvedSelections.compactMap(\.attachmentID)).union([attachment.id])
        let attachmentResults = indexes.compactMapValues { item in
            item.attachment.flatMap { request.action.reviewsRemovedSpeech || usedIDs.contains($0.id) ? $0.resultID : nil }
        }
        let firstIndex = first.attachmentID.flatMap { indexes[$0] } ?? index
        let action: String
        let updated: CutProject
        var retained: RationalTime?
        var removals: [MulticamRange] = []
        let orderedIndexes = [index] + indexes.keys.sorted().filter { $0 != attachment.id }.compactMap { indexes[$0] }
        func overlappingSpeech(_ range: MulticamRange) -> [TranscriptOccurrence] {
            orderedIndexes.flatMap { $0.overlapping(range, space: .currentCut) }
        }
        let startNudge = request.startFrameNudge ?? 0
        let endNudge = request.endFrameNudge ?? 0
        guard (-10_000...10_000).contains(startNudge), (-10_000...10_000).contains(endNudge) else {
            throw transcriptEditError("Frame nudges must be within 10,000 frames.")
        }

        func edge(_ time: RationalTime, starting: Bool, preferredClip: String? = nil, nudge: Int = 0,
                  within safe: MulticamRange? = nil) throws -> RationalTime {
            try preflight.resolve(time, starting: starting, policy: request.boundaryPolicy,
                                  preferredClip: preferredClip, nudge: nudge, within: safe)
        }

        func output(_ selection: TranscriptResolvedSelection, allowRepeats: Bool = false) throws -> [MulticamRange] {
            let ranges = try timeline.outputRanges(for: selection)
            guard !ranges.isEmpty else {
                throw transcriptEditError("This selection has no retained occurrence in the current cut.")
            }
            guard allowRepeats || ranges.count == 1 else {
                throw transcriptEditError("This selection affects multiple occurrences. Select one in Current Cut.",
                                          code: "ambiguous_transcript_occurrence")
            }
            return ranges
        }

        func reviewedOutput(_ range: MulticamRange, deleting: Bool = false,
                            within safe: MulticamRange? = nil) throws -> MulticamRange {
            _ = try edge(range.from, starting: !deleting, nudge: startNudge, within: safe)
            _ = try edge(range.to, starting: deleting, nudge: endNudge, within: safe)
            return try preflight.latestRange(policy: request.boundaryPolicy)
        }

        func orderedSlices(_ passages: [TranscriptResolvedSelection]) throws -> [TranscriptEditSlice] {
            try passages.flatMap { passage -> [TranscriptEditSlice] in
                if passage.space == .source, project.sequenceItems != nil {
                    let source = try preflight.sequenceExcerpt(passage, policy: request.boundaryPolicy,
                                                               startNudge: startNudge, endNudge: endNudge)
                    return [.sequence(source)]
                }
                if passage.space != .currentCut, case .multicam(let multicam) = project {
                    let group = try preflight.groupExcerpt(passage, policy: request.boundaryPolicy,
                                                           startNudge: startNudge, endNudge: endNudge)
                    // Encode the group range as a native slice so a take outside the assembly can be restored.
                    guard group.from >= multicam.range.from, group.to <= multicam.range.to else {
                        throw transcriptEditError("The chosen passage extends outside the synchronized group.")
                    }
                    return [.group(group)]
                }
                let range = try output(passage)[0]
                return timeline.slices(try reviewedOutput(range))
            }
        }

        switch request.action {
        case .queue, .assemble:
            action = request.action == .queue ? "Queue Transcript Excerpt" : "Assemble Transcript Selects"
            updated = try timeline.project(project, with: orderedSlices(selected))
        case .insert, .replace:
            let destination: MulticamRange
            if request.action == .replace {
                guard let target else { throw transcriptEditError("Select a destination to replace.") }
                destination = try reviewedOutput(output(target)[0], deleting: true)
                removals = [destination]
            } else {
                guard let position = request.position else { throw transcriptEditError("Supply an insertion position in Current Cut.") }
                let resolved = try edge(position, starting: true, nudge: startNudge)
                destination = .init(from: resolved, to: resolved)
            }
            action = request.action == .insert ? "Insert Transcript Selects" : "Replace with Transcript Selects"
            let (prefix, suffix) = try timeline.retaining(before: destination.from, after: destination.to)
            updated = try timeline.project(project, with: prefix + (try orderedSlices(selected)) + suffix)
        case .delete:
            action = "Delete Transcript Range"
            removals = try selected.flatMap { selection in
                try output(selection, allowRepeats: selection.space != .currentCut)
                    .map { try reviewedOutput($0, deleting: true) }
            }.sorted { $0.from < $1.from }
            var cursor = RationalTime.zero
            var kept: [TranscriptEditSlice] = []
            for range in removals {
                kept += timeline.slices(.init(from: cursor, to: range.from))
                cursor = max(cursor, range.to)
            }
            kept += timeline.slices(.init(from: cursor, to: timeline.duration))
            updated = try timeline.project(project, with: kept)
        case .tighten:
            action = "Tighten Transcript Gap"
            guard selected.count == 1, first.kind == .gap, let duration = request.retainedDuration, duration >= .zero else {
                throw transcriptEditError("Choose one gap and a nonnegative retained duration.")
            }
            let protections = project.transcripts.authoring.filter {
                if case .pauseProtection = $0.change { return true }
                return false
            }
            if !protections.isEmpty {
                let sourceWords = firstIndex.indexes[.source]?.words ?? []
                let named = TranscriptEditorial.review(records: protections, sourceWords: sourceWords, attachmentID: firstIndex.attachment?.id)
                if let protection = named.first(where: { item in
                    guard item.anchors.count == 2, item.anchors.allSatisfy({ $0.status == .resolved }) else { return false }
                    // The pause is the same pause on whichever microphone the selection resolved to.
                    // Group picks one observing track and Current Cut the routed one.
                    let endpoints = Set(item.anchors.flatMap(\.words).map(\.wordID))
                    return endpoints.contains(first.first.wordID) && endpoints.contains(first.last.wordID)
                }), case .pauseProtection(let name) = protection.change {
                    throw transcriptEditError("Pause ‘\(name)’ is protected.", code: "protected_transcript_gap")
                }
            }
            guard first.overlappingWordIDs.isEmpty else {
                throw transcriptEditError("Other speech occurs in this gap. Review it as a dialogue edit.",
                                          code: "transcript_gap_contains_speech")
            }
            if first.space == .currentCut,
               first.first.clipID != first.last.clipID || first.first.assemblyIndex != first.last.assemblyIndex {
                throw transcriptEditError("Choose both gap endpoints in the same retained occurrence.")
            }
            let gap = try output(first)[0]
            if !overlappingSpeech(gap).isEmpty {
                throw transcriptEditError("Program audio contains speech in this gap. Review it as a dialogue edit.",
                                          code: "transcript_gap_contains_speech")
            }
            if case .multicam(let multicam) = project, multicam.audio == .mix {
                let coverage = TranscriptProjectIndex.mergeCoverage(orderedIndexes.map(\.gaps))
                let incomplete = Set(coverage.compactMap { entry -> String? in
                    switch entry.reason {
                    case .still, .silence: return nil
                    case .unbound, .skipped, .failed, .unavailable, .changed:
                        guard entry.range.from < gap.to, gap.from < entry.range.to else { return nil }
                        return entry.laneLabel
                    }
                })
                if !incomplete.isEmpty {
                    throw transcriptEditError("Load transcript evidence for \(incomplete.sorted().joined(separator: ", ")) before tightening this gap.",
                                              code: "transcript_gap_evidence_unavailable")
                }
            }
            let initial = try gap.to.subtracting(gap.from)
            guard duration <= initial else { throw transcriptEditError("The requested pause is longer than the selected gap.") }
            if duration == initial {
                updated = project
                retained = initial
            } else {
                let start = try gap.from.adding(duration)
                let removal = try reviewedOutput(.init(from: start, to: gap.to), deleting: true, within: gap)
                guard removal.from >= gap.from, removal.to <= gap.to else {
                    throw transcriptEditError("The reviewed boundaries would cut into neighboring speech.",
                                              code: "transcript_gap_contains_speech")
                }
                removals = [removal]
                let (prefix, suffix) = try timeline.retaining(before: removal.from, after: removal.to)
                retained = try initial.subtracting(removal.to.subtracting(removal.from))
                updated = try timeline.project(project, with: prefix + suffix)
            }
        case .split, .trimStart, .trimEnd:
            guard selected.count == 1 else { throw transcriptEditError("Choose one word or phrase for the boundary.") }
            let range = try output(first)[0]
            let time = request.edge == .start ? range.from : range.to
            let word = request.edge == .start ? first.first : first.last
            let item = try preflight.item(at: time, starting: request.edge == .start, clipID: word.clipID,
                                          assemblyIndex: first.space == .currentCut ? word.assemblyIndex : nil)
            let boundary = try edge(time, starting: request.action == .trimStart,
                                    preferredClip: item.sequence?.source?.id,
                                    nudge: request.edge == .start ? startNudge : endNudge)
            if request.action == .trimStart, boundary == item.output.from {
                action = "Trim Start to Transcript Word"
                updated = project
                break
            }
            if request.action == .trimEnd, boundary == item.output.to {
                action = "Trim End to Transcript Word"
                updated = project
                break
            }
            guard boundary > item.output.from, boundary < item.output.to else {
                throw transcriptEditError("Choose a boundary inside the selected occurrence.")
            }
            switch request.action {
            case .split:
                action = "Split at Transcript Word"
                let (prefix, suffix) = try timeline.retaining(before: boundary, after: boundary)
                updated = try timeline.project(project, with: prefix + suffix)
            case .trimStart:
                action = "Trim Start to Transcript Word"
                removals = [.init(from: item.output.from, to: boundary)]
                let (prefix, suffix) = try timeline.retaining(before: item.output.from, after: boundary)
                updated = try timeline.project(project, with: prefix + suffix)
            default:
                action = "Trim End to Transcript Word"
                removals = [.init(from: boundary, to: item.output.to)]
                let (prefix, suffix) = try timeline.retaining(before: boundary, after: item.output.to)
                updated = try timeline.project(project, with: prefix + suffix)
            }
        case .switchAngle:
            action = "Switch Camera at Transcript Word"
            guard selected.count == 1, let angle = request.angleID else {
                throw transcriptEditError("Select one word and specify a camera angle.")
            }
            updated = try preflight.switchAngle(angle, selection: first, edge: request.edge, policy: request.boundaryPolicy,
                                               nudge: request.edge == .start ? startNudge : endNudge)
        }
        let unavailableEvidence = try timeline.unavailableEvidence(in: removals, project: project, indexed: Set(indexes.keys), multicamMedia: multicamMedia)
        if request.action == .tighten, !unavailableEvidence.isEmpty {
            let ids = unavailableEvidence.joined(separator: ", ")
            throw transcriptEditError("Load the transcript evidence (\(ids)) before tightening this gap.",
                                      code: "transcript_gap_evidence_unavailable")
        }
        let speakerNames = indexes.mapValues { Dictionary(uniqueKeysWithValues: $0.speakers.map { ($0.id, $0.name) }) }
        let affectedSpeech = Self.distinctSpeech(removals.flatMap(overlappingSpeech)).map { word in
            var result = word
            if let attachment = word.attachmentID, let speaker = word.speakerID {
                result.speakerName = speakerNames[attachment]?[speaker]
            }
            return result
        }
        let previousTier = preflight.tier(of: project)
        let resultingTier = updated == project ? previousTier : preflight.tier(of: updated)
        if let resultingTier, resultingTier.id == "unavailable",
           let previousTier, previousTier.id != "unavailable" {
            let factor = resultingTier.factors.first
            throw CutError(code: "transcript_edit_unrenderable",
                           message: factor?.message ?? "The edited program cannot be exported. Choose a different boundary.",
                           segment: factor?.segment, boundary: factor?.boundary, nearest: factor?.nearest, track: factor?.track)
        }
        if request.boundaryPolicy == .copySafe, resultingTier?.mode != .copy {
            let message: String
            if let tier = resultingTier, tier.mode != nil {
                message = "These cuts require \(tier.name). Review a Nearest Frame plan or choose different copy-safe boundaries."
            } else {
                message = "The edited program has no verified stream-copy plan."
            }
            throw transcriptEditError(message, code: "transcript_copy_boundary_unavailable")
        }
        let affected = try preflight.affectedOccurrences(resolvedSelections, updated: updated, action: request.action)
        let boundaries = preflight.boundaries.map { boundary in
            var impact = boundary
            let begin = min(boundary.requested, boundary.resolved)
            let end = max(boundary.requested, boundary.resolved)
            var seen = Set<String>()
            if begin != end {
                let applicable: [TranscriptIndex]
                if let id = boundary.attachmentID, let scoped = indexes[id] {
                    applicable = [scoped]
                } else {
                    applicable = indexes.keys.sorted().compactMap { indexes[$0] }
                }
                impact.affectedWordIDs = applicable.flatMap { $0.overlapping(.init(from: begin, to: end), space: boundary.space) }
                    .compactMap { word in seen.insert(word.wordID).inserted ? word.wordID : nil }
            }
            return impact
        }
        return .init(revision: revision, attachmentResults: attachmentResults, action: request.action, historyAction: action, name: request.name,
                     selections: selected, boundaries: boundaries, affectedOccurrences: affected,
                     affectedSpeech: affectedSpeech, unavailableEvidenceAttachmentIDs: unavailableEvidence,
                     previousDuration: timeline.duration, duration: try TranscriptEditTimeline(updated).duration,
                     requestedRetainedDuration: request.retainedDuration, retainedDuration: retained,
                     previousTier: previousTier, tier: resultingTier, snapshot: updated, original: project)
    }
}
