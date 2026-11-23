import Foundation

// The timeline tier of a multicam program. Like a file timeline's it is found by asking the planner, here
// MulticamEngine, for each mode of ExportRules.tierSteps in order, with picture and sound and exact cuts.

extension MulticamEngine {
    /// One attempt at the program for the tier: a destination that names the container, a mode and its settings.
    typealias TierAttempt = (_ output: URL, _ mode: ExportMode, _ settings: ReencodeSettings) throws -> MulticamExportPlan

    /// The tier of a saved project, or of `assembly` when given. `indexedSources` holds the indexes the caller has.
    /// `preferredContainer` is used when the program plans in it, otherwise the first listed container that plans.
    public func tier(_ project: MulticamProject, relativeTo location: URL? = nil, assembly: [MulticamRange]? = nil,
                     indexedSources: [String: MediaInfo] = [:], preferredContainer: String? = nil) -> TierState {
        if project.participants.render != nil {
            guard assembly == nil else { return .unavailable(ParticipantProjectExport.unsupported("A range export")) }
            return ParticipantProjectExport.tier(.multicam(project), relativeTo: location,
                                                 preferredContainer: preferredContainer, cancelled: cancelled)
        }
        var snapshot = project
        if let assembly { snapshot.assemblyItems = assembly.map { .group($0) } }
        let document = CutProject.multicam(snapshot)
        if !document.stillInserts.isEmpty || !document.stillReplacements.isEmpty {
            do {
                if try document.exportPlacementScope() != .none {
                    return StillExportPlanner(cancelled: cancelled).tier(document, relativeTo: location,
                                                                      preferredContainer: preferredContainer)
                }
            } catch let issue as CutError {
                return .unavailable(issue)
            } catch {
                return .unavailable(CutError(code: "export_failed", message: error.localizedDescription))
            }
        }
        var indexed = indexedSources
        return tier(preferredContainer: preferredContainer) { output, mode, settings in
            try resolve(project, relativeTo: location, output: output, mode: mode, tracks: .all,
                        assembly: assembly, settings: settings, media: &indexed)
        }
    }

    /// The tier of an assembled request.
    package func tier(_ mapping: MulticamPlan, sources: [String: URL], requireAudio: Bool = true,
                      adjusting: MulticamEdgePlanner? = nil) -> TierState {
        var indexed: [String: MediaInfo] = [:]
        return tier(preferredContainer: nil) { output, mode, settings in
            try resolve(mapping, sources: sources, output: output, mode: mode, tracks: .all, settings: settings,
                        requireAudio: requireAudio, media: &indexed, adjusting: adjusting, offerBoundaries: true)
        }
    }

    func tier(preferredContainer: String?, attempt: TierAttempt) -> TierState {
        // Nothing is written. The destination only names the container.
        let stand = FileManager.default.temporaryDirectory.appendingPathComponent(".mpcut-tier-\(UUID().uuidString)", isDirectory: false)
        let steps = ExportRules.tierSteps(source: .multicam)
        var factors: [TierFactor] = []
        var first: CutError?
        var last = CutError(code: "export_failed", message: "No export mode is available.")
        for (position, step) in steps.enumerated() {
            let next = position + 1 < steps.count ? steps[position + 1].tier : nil
            let cell = ExportRules.cell(source: .multicam, tracks: .all, mode: step.mode)
            // A container written as another one, such as M4V, is asked once.
            var containers = (cell.containers ?? ExportRules.multicamContainers).filter { ExportRules.multicamMuxContainer($0) == $0 }
            if let preferredContainer = preferredContainer.map({ ExportRules.multicamMuxContainer($0.lowercased()) }),
               containers.contains(preferredContainer) {
                containers.removeAll { $0 == preferredContainer }
                containers.insert(preferredContainer, at: 0)
            }
            var failure: CutError?
            for container in containers {
                // A re-encode keeps the program sound when its copy is exact and otherwise converts it.
                let sound: [ReencodeAudio] = step.mode == .encode
                    ? [.copyOriginal] + ExportRules.automaticAudio(codec: ExportRules.defaultCodec, container: container, source: .multicam)
                    : [.copyOriginal]
                for audio in sound {
                    if cancelled?() == true { return .checking }
                    do {
                        let plan = try attempt(stand.appendingPathExtension(container), step.mode,
                                               ReencodeSettings(codec: ExportRules.defaultCodec, quality: nil, audio: audio))
                        return .known(tier: step.tier, factors: factors, container: plan.container, warnings: plan.warnings)
                    } catch let issue as CutError {
                        if issue.code == "cancelled" { return .checking }
                        // The project, a source or the request itself is at fault. No mode helps.
                        if Self.terminal.contains(issue.code) { return .unavailable(issue) }
                        if step.mode == .encode, issue.code == "helper_unavailable" || issue.code == "encoder_unavailable" {
                            // The helper is asked at export. Everything about the program itself was checked before it.
                            return .known(tier: step.tier, factors: factors, container: container, warnings: [issue.message])
                        }
                        if failure == nil { failure = issue }
                    } catch {
                        if failure == nil { failure = CutError(code: "export_failed", message: error.localizedDescription) }
                    }
                }
            }
            guard let failure else { continue }
            last = failure
            if first == nil { first = failure }
            let factor = TierFactor(failure, forces: next)
            // A later mode that stops at the same cut is the stronger statement about it.
            factors.removeAll { $0.id == factor.id && $0.segment == factor.segment && $0.boundary == factor.boundary }
            factors.append(factor)
        }
        return .unavailable(first.flatMap { $0.factor.effect == .unavailable && $0.factor != .writerOther ? $0 : nil } ?? last)
    }
}

extension TierState {
    /// The tier as programs read it, for a source kind whose cuts a command does not move: a multicam program.
    public func summary(source: ExportSourceKind) -> TierSummary {
        switch self {
        case .checking:
            return TierSummary(id: "checking", name: name, mode: nil, container: nil, factors: [], raise: [], warnings: [])
        case .unavailable:
            return TierSummary(id: "unavailable", name: name, mode: nil, container: nil, factors: factors, raise: [], warnings: [])
        case .known(let tier, let factors, let container, let warnings):
            return TierSummary(id: tier.rawValue, name: name, mode: ExportRules.bestMode(for: tier, source: source),
                               container: container, factors: factors, raise: [], warnings: warnings)
        }
    }
}
