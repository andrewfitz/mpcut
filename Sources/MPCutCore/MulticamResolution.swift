import Foundation

/// A working alternative for a multicam program, with the plan that writes it.
public struct MulticamOffer: Sendable {
    /// The alternative in the shape every export reports.
    public let alternative: ExportAlternative
    public let mode: ExportMode
    public let tracks: ExportTracks
    public let container: String
    public let settings: ReencodeSettings
    public let plan: MulticamExportPlan
}

/// The answer of the export rules for one multicam request, in the shape of `ExportResolution`.
public enum MulticamResolution: Sendable {
    /// `applied` is set when `auto` converted the program sound.
    case ready(MulticamExportPlan, applied: ExportAlternative?)
    case unavailable(CutError, offers: [MulticamOffer])

    /// The plan, or the failure carrying its ordered `alternatives`.
    public func get() throws -> MulticamExportPlan {
        switch self {
        case .ready(let plan, _): return plan
        case .unavailable(var issue, let offers):
            if !offers.isEmpty { issue.alternatives = offers.map(\.alternative) }
            throw issue
        }
    }

    public var applied: ExportAlternative? {
        if case .ready(_, let applied) = self { return applied }
        return nil
    }
}

extension MulticamEngine {
    /// One attempt at a program export. `candidate` is true for an alternative, which needs no suggested times.
    typealias ProgramAttempt = (_ output: URL, _ mode: ExportMode, _ tracks: ExportTracks, _ settings: ReencodeSettings,
                                _ candidate: Bool) throws -> MulticamExportPlan

    /// Codes that describe the request, the project or the destination, for which no other export helps.
    static let terminal: Set<String> = ["cancelled", "source_changed", "output_exists", "invalid_output", "invalid_arguments",
                                                "empty_edit", "invalid_range", "invalid_time", "missing_source", "missing_audio",
                                                "probe_failed", "time_overflow"]

    /// Resolves a saved project through the export rules: the plan, or the failure with the alternatives that work.
    package func resolution(_ project: MulticamProject, relativeTo location: URL? = nil, output: URL,
                            mode: ExportMode, tracks: ExportTracks = .all, assembly: [MulticamRange]? = nil,
                            settings: ReencodeSettings = .init(), indexedSources: [String: MediaInfo] = [:]) -> MulticamResolution {
        var indexed = indexedSources
        var prepared: (mapping: MulticamPlan, sources: [String: URL])?
        return resolution(output: output, mode: mode, tracks: tracks, settings: settings) { output, mode, tracks, settings, candidate in
            guard candidate else {
                return try resolve(project, relativeTo: location, output: output, mode: mode, tracks: tracks,
                                   assembly: assembly, settings: settings, media: &indexed)
            }
            if prepared == nil {
                let recordings = project.angles + project.audioSources
                prepared = (try project.plan(ranges: assembly), Dictionary(uniqueKeysWithValues: recordings.map {
                    ($0.id, sourceURL($0, project: project, location: location))
                }))
            }
            return try resolve(prepared!.mapping, sources: prepared!.sources, output: output, mode: mode, tracks: tracks,
                               settings: settings, requireAudio: project.audio != .none || !prepared!.mapping.audio.isEmpty,
                               media: &indexed, adjusting: nil, offerBoundaries: false)
        }
    }

    /// Resolves an assembled request through the export rules.
    package func resolution(_ mapping: MulticamPlan, sources: [String: URL], output: URL, mode: ExportMode,
                            tracks: ExportTracks = .all, settings: ReencodeSettings = .init(), requireAudio: Bool = true,
                            adjusting: MulticamEdgePlanner? = nil) -> MulticamResolution {
        var indexed: [String: MediaInfo] = [:]
        return resolution(output: output, mode: mode, tracks: tracks, settings: settings) { output, mode, tracks, settings, candidate in
            try resolve(mapping, sources: sources, output: output, mode: mode, tracks: tracks, settings: settings,
                        requireAudio: requireAudio, media: &indexed, adjusting: candidate ? nil : adjusting,
                        offerBoundaries: !candidate)
        }
    }

    func resolution(output: URL, mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
                    attempt: ProgramAttempt) -> MulticamResolution {
        struct Candidate {
            let rung: ExportRung
            var mode: ExportMode
            var container: String
            var settings: ReencodeSettings
        }
        func failure(_ error: Error) -> CutError {
            error as? CutError ?? CutError(code: "export_failed", message: error.localizedDescription)
        }
        func with(_ audio: ReencodeAudio) -> ReencodeSettings {
            ReencodeSettings(codec: settings.codec, quality: settings.quality, audio: audio)
        }
        func written(_ container: String) -> String { ExportRules.multicamMuxContainer(container) }

        let cell = ExportRules.cell(source: .multicam, tracks: tracks, mode: mode)
        if let refusal = cell.refusal { return .unavailable(refusal, offers: []) }
        let named = output.pathExtension.lowercased()
        let stand = output.deletingLastPathComponent().appendingPathComponent(".mpcut-check-\(UUID().uuidString)", isDirectory: false)

        func alternative(_ candidate: Candidate, plan: MulticamExportPlan) -> ExportAlternative {
            // A re-encode offered for a re-encode names its container and audio action.
            let variant = candidate.rung == .reencode && mode == .encode
            let request = ExportRequest(clips: [], mode: candidate.mode, tracks: tracks, container: candidate.container,
                                        audio: candidate.settings.audio, codec: candidate.settings.codec,
                                        quality: candidate.settings.quality, movieSettings: mode == .encode)
            let lossless = candidate.rung.rank.encodedScope == 0
            let smartOtherContainer = candidate.rung == .smartTrim && candidate.container != named
            let label = candidate.rung.label(container: candidate.container,
                                             audio: variant || (candidate.rung == .reencode && candidate.settings.audio != .copyOriginal)
                                                 ? candidate.settings.audio : nil,
                                             lossless: lossless, source: .multicam)
            return ExportAlternative(
                id: candidate.rung == .copyOtherContainer || variant || smartOtherContainer ? "\(candidate.rung.rawValue):\(candidate.container)" : candidate.rung.rawValue,
                rung: candidate.rung,
                label: smartOtherContainer ? "\(label) in \(ExportRules.containerDisplayName(candidate.container))" : label,
                mode: candidate.mode, tracks: tracks, container: candidate.container,
                audio: candidate.mode == .encode ? candidate.settings.audio : plan.audioAction, codec: nil, bitRate: nil, quality: nil,
                lossless: lossless, warnings: plan.warnings, arguments: ExportRules.arguments(for: request), clips: nil)
        }
        /// A re-encode offered for a copy keeps the sound when its copy is exact and otherwise converts it, in this order.
        func conversions(of candidate: Candidate) -> [Candidate] {
            guard candidate.rung == .reencode, mode != .encode else { return [] }
            return ExportRules.automaticAudio(codec: settings.codec, container: candidate.container, source: .multicam).map { audio in
                var next = candidate
                next.settings = with(audio)
                return next
            }
        }
        func planned(_ candidate: Candidate, at destination: URL) -> MulticamExportPlan? {
            for choice in [candidate] + conversions(of: candidate) {
                if cancelled?() == true { return nil }
                if let plan = try? attempt(destination, choice.mode, tracks, choice.settings, true) { return plan }
            }
            return nil
        }

        let issue: CutError
        do {
            return .ready(try attempt(output, mode, tracks, settings, false), applied: nil)
        } catch {
            issue = failure(error)
        }
        guard !Self.terminal.contains(issue.code) else { return .unavailable(issue, offers: []) }

        // The routed program sound is never converted unasked: the conversions below are offered, not applied.
        var candidates: [Candidate] = []
        for rung in cell.rungs {
            switch rung {
            case .copyOtherContainer, .smartTrim:
                let alternativeMode: ExportMode = rung == .copyOtherContainer ? .copy : .smart
                let sameContainer = rung == .smartTrim && mode == .copy ? [named] : []
                let containers = sameContainer + ExportRules.multicamListedContainers(tracks: tracks, mode: alternativeMode, codec: settings.codec)
                    .filter { written($0) == $0 && $0 != written(named) }
                for container in containers {
                    candidates.append(Candidate(rung: rung, mode: alternativeMode, container: container, settings: settings))
                }
            case .convertPCM, .convertAAC:
                guard mode == .encode, ExportRules.multicamAudio(settings.audio) == .copyOriginal else { continue }
                let audio: ReencodeAudio = rung == .convertPCM ? .pcm : .aac
                let fits = ExportRules.reencodeContainers(for: audio, source: .multicam, codec: settings.codec)
                guard let container = fits.contains(named) ? named : fits.first else { continue }
                candidates.append(Candidate(rung: rung, mode: .encode, container: container, settings: with(audio)))
            case .reencode where mode == .encode:
                // The same audio action in the other containers that carry it.
                for container in ExportRules.reencodeContainers(for: settings.audio, source: .multicam, codec: settings.codec)
                where written(container) == container && container != written(named) {
                    candidates.append(Candidate(rung: rung, mode: .encode, container: container, settings: settings))
                }
            case .reencode:
                let all = ExportRules.multicamReencodeContainers(settings.codec)
                guard let container = all.contains(named) ? named : all.first else { continue }
                candidates.append(Candidate(rung: rung, mode: .encode, container: container, settings: with(.copyOriginal)))
            default:
                continue
            }
        }

        var offers: [MulticamOffer] = []
        for candidate in candidates {
            if cancelled?() == true { break }
            if candidate.rung == .smartTrim, candidate.container != named,
               offers.contains(where: { ($0.container == named && $0.mode == .smart)
                   || ($0.container == candidate.container && $0.mode == .copy) }) {
                continue
            }
            // An alternative in the requested container is planned for the requested destination.
            let destination = candidate.container == named ? output : stand.appendingPathExtension(candidate.container)
            guard let plan = planned(candidate, at: destination) else { continue }
            var offered = candidate
            if let action = plan.audioAction, candidate.mode == .encode, action != candidate.settings.audio {
                offered.settings = with(action)
            }
            offers.append(MulticamOffer(alternative: alternative(offered, plan: plan), mode: offered.mode, tracks: tracks,
                                        container: offered.container, settings: offered.settings, plan: plan))
        }
        // A picture-only or sound-only program is written as a copy, and its row of the rules offers another container
        // only. When no container takes the cut either, there is nothing to offer, so the refusal says what does help:
        // the verified times it lists, and the export of picture and sound together when that one plans.
        if offers.isEmpty, tracks != .all, issue.code == "unsafe_boundary" || issue.code == "invalid_frame_boundary" {
            let together = [ExportMode.smart, .encode].first { other in
                guard cancelled?() != true, ExportRules.cell(source: .multicam, tracks: .all, mode: other).isAllowed else { return false }
                let fits = other == .encode ? ExportRules.multicamReencodeContainers(settings.codec) : ExportRules.multicamContainers
                guard let container = fits.contains(named) ? named : fits.first else { return false }
                let actions = other == .encode
                    ? [ReencodeAudio.copyOriginal] + ExportRules.automaticAudio(codec: settings.codec, container: container, source: .multicam)
                    : [settings.audio]
                return actions.contains { (try? attempt(stand.appendingPathExtension(container), other, .all, with($0), true)) != nil }
            }
            let advice = ExportRules.multicamSingleTypeAdvice(tracks: tracks, hasNearest: !(issue.nearest ?? []).isEmpty, together: together)
            var advised = CutError(code: issue.code, message: issue.message + " " + advice, segment: issue.segment, boundary: issue.boundary,
                                   nearest: issue.nearest, track: issue.track, multicam: issue.multicam, placementIDs: issue.placementIDs)
            advised.stillBoundaryAdjustments = issue.stillBoundaryAdjustments
            advised.reason = issue.reason
            return .unavailable(advised, offers: [])
        }
        return .unavailable(issue, offers: offers)
    }
}
