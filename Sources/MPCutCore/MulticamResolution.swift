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
    private static let terminal: Set<String> = ["cancelled", "source_changed", "output_exists", "invalid_output", "invalid_arguments",
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
            let sameAudio = variant && candidate.settings.audio == settings.audio
            let request = ExportRequest(clips: [], mode: candidate.mode, tracks: tracks, container: candidate.container,
                                        audio: candidate.settings.audio, codec: candidate.settings.codec,
                                        quality: candidate.settings.quality, movieSettings: mode == .encode)
            let lossless = candidate.rung.rank.encodedScope == 0
            return ExportAlternative(
                id: candidate.rung == .copyOtherContainer || sameAudio ? "\(candidate.rung.rawValue):\(candidate.container)" : candidate.rung.rawValue,
                rung: candidate.rung,
                label: candidate.rung.label(container: candidate.container,
                                            audio: variant || (candidate.rung == .reencode && candidate.settings.audio != .copyOriginal)
                                                ? candidate.settings.audio : nil,
                                            lossless: lossless, source: .multicam),
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
            case .copyOtherContainer:
                for container in ExportRules.multicamListedContainers(tracks: tracks, mode: mode, codec: settings.codec)
                where written(container) == container && container != written(named) {
                    candidates.append(Candidate(rung: rung, mode: mode, container: container, settings: settings))
                }
            case .smartTrim:
                candidates.append(Candidate(rung: rung, mode: .smart, container: named, settings: settings))
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
        return .unavailable(issue, offers: offers)
    }
}
