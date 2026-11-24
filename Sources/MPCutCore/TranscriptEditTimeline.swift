import Foundation

/// A slice keeps the original occurrence and its source-time coordinates so
/// that picture replacements and linked audio follow the same timeline pieces.
enum TranscriptEditSlice {
    case currentCut(MulticamRange)
    case sequence(CutSequenceClip)
    case group(MulticamRange)
}

struct TranscriptEditTimeline {
    struct Item {
        let sequence: StillSequenceItem?
        let multicam: StillAssemblyItem?
        let output: MulticamRange

        var input: MulticamRange {
            if let clip = sequence?.source { return .init(from: clip.from, to: clip.to) }
            return multicam?.group ?? .init(from: .zero, to: output.to - output.from)
        }

        var still: StillInsert? { sequence?.still ?? multicam?.still }

        func inputTime(_ time: RationalTime) throws -> RationalTime {
            try input.from.adding(time.subtracting(output.from))
        }
    }

    let items: [Item]
    let duration: RationalTime
    let sources: [MulticamSource]
    let baseDirectory: URL?

    init(_ project: CutProject, relativeTo projectURL: URL? = nil) throws {
        baseDirectory = projectURL.map(ProjectFile.directory(of:))
        var cursor = RationalTime.zero
        if let sequence = project.sequenceItems {
            items = try sequence.map { item in
                let from = cursor
                switch item {
                case .source(let clip): cursor = try cursor.adding(clip.to.subtracting(clip.from))
                case .still(let still): cursor = try cursor.adding(still.duration)
                }
                return Item(sequence: item, multicam: nil, output: .init(from: from, to: cursor))
            }
        } else if case .multicam(let project) = project {
            items = try (project.assemblyItems ?? [.group(project.range)]).map { item in
                let from = cursor
                switch item {
                case .group(let group, _, _, _): cursor = try cursor.adding(group.to.subtracting(group.from))
                case .still(let still): cursor = try cursor.adding(still.duration)
                }
                return Item(sequence: nil, multicam: item, output: .init(from: from, to: cursor))
            }
        } else {
            throw transcriptEditError("Unsupported timeline.")
        }
        duration = cursor
        if case .multicam(let multicam) = project { sources = multicam.sources } else { sources = [] }
    }

    func slices(_ range: MulticamRange) -> [TranscriptEditSlice] {
        guard range.from < range.to else { return [] }
        return [.currentCut(range)]
    }

    func retaining(before: RationalTime, after: RationalTime) throws -> ([TranscriptEditSlice], [TranscriptEditSlice]) {
        guard before >= .zero, before <= after, after <= duration else {
            throw transcriptEditError("The edit lies outside the current timeline.")
        }
        return (slices(.init(from: .zero, to: before)), slices(.init(from: after, to: duration)))
    }

    func outputItemIndices(overlapping range: MulticamRange) -> Range<Int> {
        let start = items.lowerBound { $0.output.to > range.from }
        let end = items.lowerBound { $0.output.from >= range.to }
        return start..<max(start, end)
    }

    func project(_ project: CutProject, with slices: [TranscriptEditSlice], adoptingSourceFormat: Bool = false,
                 preservingHiddenStillHandles: Bool = false,
                 onRetainedClip: (_ retainedID: String, _ originalID: String) -> Void = { _, _ in }) throws -> CutProject {
        var usedIDs = Set(project.stillReplacements.map(\.id))
        var reservedIDs = usedIDs.union(items.compactMap { $0.sequence?.source?.id ?? $0.still?.id })
        var sequenceItems: [StillSequenceItem] = []
        var assemblyItems: [StillAssemblyItem] = []
        var retainedFragments: [String: [(clipID: String, from: RationalTime?, to: RationalTime?)]] = [:]
        var nextID = 0

        func uniqueID(_ preferred: String) -> String {
            if usedIDs.insert(preferred).inserted { return preferred }
            while true {
                nextID += 1
                let generated = "\(preferred)-transcript-\(nextID)"
                if reservedIDs.insert(generated).inserted {
                    usedIDs.insert(generated)
                    return generated
                }
            }
        }

        for slice in slices {
            let range: MulticamRange
            switch slice {
            case .sequence(var clip):
                clip.id = uniqueID(clip.id)
                sequenceItems.append(.source(clip))
                continue
            case .group(let group):
                assemblyItems.append(.group(group))
                continue
            case .currentCut(let output):
                range = output
            }
            guard range.from >= .zero, range.from < range.to, range.to <= duration else {
                throw transcriptEditError("The excerpt lies outside the current timeline.")
            }
            let start = items.lowerBound { $0.output.to > range.from }
            for item in items[start...] {
                if item.output.from >= range.to { break }
                let from = max(range.from, item.output.from)
                let to = min(range.to, item.output.to)
                let input = try MulticamRange(from: item.inputTime(from), to: item.inputTime(to))
                if var still = item.still {
                    let length = try input.to.subtracting(input.from)
                    if input.from > .zero {
                        still.duration = input.from
                        _ = try still.frameCount()
                    }
                    still.duration = length
                    _ = try still.frameCount()
                    still.id = uniqueID(still.id)
                    if item.sequence != nil { sequenceItems.append(.still(still)) }
                    else { assemblyItems.append(.still(still)) }
                } else if var clip = item.sequence?.source {
                    let originalID = clip.id
                    clip.id = uniqueID(originalID)
                    // An original trim edge still has its authored source handles. A new
                    // edit edge must stop at the cut so removed coverage cannot reappear.
                    let lower = preservingHiddenStillHandles && input.from == clip.from ? nil : input.from
                    let upper = preservingHiddenStillHandles && input.to == clip.to ? nil : input.to
                    retainedFragments[originalID, default: []].append((clipID: clip.id, from: lower, to: upper))
                    clip.tileLayouts = clip.tileLayouts.compactMap { $0.limited(from: lower, to: upper) }
                    clip.from = input.from
                    clip.to = input.to
                    onRetainedClip(clip.id, originalID)
                    sequenceItems.append(.source(clip))
                } else if let group = item.multicam, let original = group.group {
                    let id = group.occurrenceID.map(uniqueID)
                    let coverage = group.tileLayouts.compactMap { span in
                        span.limited(from: preservingHiddenStillHandles && input.from == original.from ? nil : input.from,
                                     to: preservingHiddenStillHandles && input.to == original.to ? nil : input.to)
                    }
                    assemblyItems.append(.group(input, angle: group.angleOverride, id: id, layouts: coverage))
                }
            }
        }
        var updated = try project.editingStills(sequence: { sequence in
            guard !sequenceItems.isEmpty else { throw transcriptEditError("The edit would empty the sequence.") }
            sequence.items = sequenceItems
            if adoptingSourceFormat && sequence.stillFormat != nil && sequenceItems.contains(where: { $0.source != nil }) {
                sequence.stillFormat = nil
                sequence.programColorPolicy = nil
            }
            sequence.stillReplacements = sequence.stillReplacements.compactMap { replacement in
                guard case .sequence(let fragments) = replacement.coverage else { return nil }
                let retained = fragments.flatMap { original in
                    (retainedFragments[original.clipID] ?? []).compactMap { piece -> StillReplacementFragment? in
                        let from = max(original.range.from, piece.from ?? original.range.from)
                        let to = min(original.range.to, piece.to ?? original.range.to)
                        guard from < to else { return nil }
                        return .init(clipID: piece.clipID, range: .init(from: from, to: to))
                    }
                }
                guard !retained.isEmpty else { return nil }
                var updated = replacement
                updated.coverage = .sequence(retained)
                return updated
            }
        }, multicam: { multicam in
            guard !assemblyItems.isEmpty else { throw transcriptEditError("The edit would empty the assembly.") }
            multicam.assemblyItems = assemblyItems
        })
        updated.transcripts = project.transcripts
        return updated
    }

    /// A missing attachment matters only if one of its bindings can be routed
    /// in the removed output. Still cards and unrelated recordings add no risk.
    func unavailableEvidence(in ranges: [MulticamRange], project: CutProject,
                             indexed: Set<String>, multicamMedia: [String: MediaInfo]) throws -> [String] {
        guard !ranges.isEmpty else { return [] }
        let missing = project.transcripts.attachments.filter { !indexed.contains($0.id) && !$0.bindings.isEmpty }
        guard !missing.isEmpty else { return [] }
        func overlaps(_ span: MulticamRange) -> Bool {
            ranges.contains { $0.from < span.to && span.from < $0.to }
        }
        if case .multicam(let multicam) = project {
            let plan = try multicam.plan()
            let lanes = try multicam.resolveAudioLanes(plan: plan, indexedSources: multicamMedia,
                                                      assumeUnindexedCoverage: true, unavailableAsGap: true)
            let routed = lanes.flatMap(\.spans).filter { overlaps($0.output) }
            let bindings = Dictionary(uniqueKeysWithValues: try multicam.transcriptReplacementPlacements().map {
                ($0.trackID, $0.bindingID)
            })
            return missing.filter { attachment in
                attachment.bindings.contains { binding in
                    let replacement = TranscriptJobPlan.replacementTrackIdentity(binding.trackID).flatMap { bindings[$0] }
                    return routed.contains {
                        $0.source == binding.sourceID && ($0.stream == nil || $0.stream == binding.streamIndex)
                            && $0.replacementBindingID == replacement
                    }
                }
            }.map(\.id).sorted()
        }
        let clips = items.filter { overlaps($0.output) }.compactMap { $0.sequence?.source }
        return missing.filter { attachment in
            attachment.bindings.contains { binding in
                guard let file = binding.file else { return false }
                let recording = identity(file)
                return clips.contains { clip in
                    let current = identity(clip.file)
                    if recording == current { return true }
                    guard let original = clip.originalFile, identity(original) == recording else { return false }
                    let replaced = Set(clip.replacementNames.keys).union(clip.audioTrack.map { [$0] } ?? [])
                    return !replaced.isEmpty && (binding.sequenceStreamOrdinal.map { !replaced.contains($0) } ?? true)
                }
            }
        }.map(\.id).sorted()
    }

    private func identity(_ path: String) -> String {
        guard let baseDirectory else { return path }
        return ProjectFile.sourceURL(file: path, in: baseDirectory).resolvingSymlinksInPath().path
    }

    func outputRanges(for selection: TranscriptResolvedSelection) throws -> [MulticamRange] {
        if selection.space == .currentCut { return [selection.range] }
        if selection.space == .group || items.first?.multicam != nil {
            let group: MulticamRange
            if selection.space == .group { group = selection.range }
            else {
                guard let sourceID = selection.first.sourceID,
                      let source = sources.first(where: { $0.id == sourceID }) else {
                    throw transcriptEditError("This source has no synchronized group location.")
                }
                let offset = try selection.first.groupRange?.from.subtracting(selection.first.range.from)
                group = try selection.range.editShifted(by: offset ?? source.offset)
            }
            return try items.compactMap { item in
                guard let occurrence = item.multicam?.group else { return nil }
                let from = max(group.from, occurrence.from)
                let to = min(group.to, occurrence.to)
                guard from < to else { return nil }
                return try MulticamRange(from: from, to: to).editShifted(by: item.output.from.subtracting(occurrence.from))
            }
        }
        guard let file = selection.first.file, let range = selection.first.sequenceSourceRange else {
            throw transcriptEditError("This source has no sequence binding.")
        }
        let source = try selection.range.editShifted(by: range.from.subtracting(selection.first.range.from))
        let selectedFile = identity(file)
        return try items.compactMap { item in
            guard let clip = item.sequence?.source else { return nil }
            let from = max(source.from, clip.from)
            let to = min(source.to, clip.to)
            guard from < to,
                  identity(clip.originalFile ?? clip.file) == selectedFile
                    || (clip.originalFile != nil && identity(clip.file) == selectedFile) else { return nil }
            return try MulticamRange(from: from, to: to).editShifted(by: item.output.from.subtracting(clip.from))
        }
    }
}

extension MulticamRange {
    func editShifted(by delta: RationalTime) throws -> Self {
        try .init(from: from.adding(delta), to: to.adding(delta))
    }
}
