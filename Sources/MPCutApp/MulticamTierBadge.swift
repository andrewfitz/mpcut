import MPCutCore
import SwiftUI

// The tier badge of the multicam editor. The tier comes from MulticamEngine.tier, which asks the engine for each
// mode of the export rules in order. The editor shows the badge and does not ask before an edit lowers it:
// `MulticamEditorModel.edit` applies a change at once and returns whether it did, and the program is planned off
// the main thread, so there is no single point where an edit could wait for an answer.

extension MulticamEditorModel {
    /// The tier a caller may rely on: nil while it is being checked.
    var settledTier: FidelityTier? { tierIsCurrent ? tierState?.tier : nil }

    /// Checks the tier of the saved program as it is now, off the main actor. A result for a program that has since
    /// changed is dropped.
    func refreshTier() {
        tierGeneration += 1
        tierToken?.cancel()
        tierToken = nil
        guard let project else {
            tierIsCurrent = true
            if tierState != nil { tierState = nil }
            return
        }
        let indexed = media.filter { $0.value.hasFullEditIndex }
        let document = CutProject.multicam(project)
        let hasStills = ((try? document.exportPlacementScope()) ?? ExportPlacementScope.none) != .none
        // A source that cannot be read stops every mode. One that is still being indexed is not planned yet.
        if !hasStills, let missing = project.sources.first(where: { indexed[$0.id] == nil }) {
            tierIsCurrent = true
            if let issue = sourceIssues[missing.id] ?? sourceIndexIssues[missing.id] {
                tierState = .unavailable(CutError(code: "missing_source", message: "\(missing.displayName) — \(issue)"))
            } else {
                tierState = .checking
            }
            return
        }
        let generation = tierGeneration, token = EditCancellation()
        tierToken = token
        tierIsCurrent = false
        if tierState == nil { tierState = .checking }
        Task { [weak self] in
            // Edits arrive in bursts while a switch is dragged. Only the program that stays is planned.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.tierGeneration == generation, !token.isCancelled else { return }
            let state = await Task.detached(priority: .utility) {
                MulticamEngine(cancelled: { token.isCancelled }).tier(project, indexedSources: indexed)
            }.value
            guard self.tierGeneration == generation, !token.isCancelled else { return }
            self.tierToken = nil
            self.tierIsCurrent = true
            self.tierState = state
        }
    }

    /// Selects the assembly range a factor belongs to.
    func goToTierFactor(_ factor: TierFactor) {
        guard !isBusy, let number = factor.segment, assemblyItems.indices.contains(number - 1) else { return }
        selectAssemblyOccurrence(number - 1)
    }
}

/// The badge in the multicam status bar: the tier of the saved program, and what lowers it.
struct MulticamTierBadge: View {
    @ObservedObject var model: MulticamEditorModel

    var body: some View {
        if let state = model.tierState {
            TierBadge(state: state, help: Self.help(state)) { dismiss in
                TierDetails(state: state, summary: Self.summary(state), title: { $0 == 0 ? "Program" : "Range \($0)" },
                            segmentName: "range", canGo: !model.isBusy, go: { factor in
                    model.goToTierFactor(factor)
                    dismiss()
                }) { EmptyView() }
            }
        }
    }

    static func help(_ state: TierState) -> String {
        switch state {
        case .checking: return "Checking export options…"
        case .known(let tier, let factors, _, _):
            let description = factors.contains(where: { $0.id == .placementPicture })
                ? TierFactorID.placementPicture.summary : ExportRules.summary(tier: tier, source: .multicam)
            return description + " Click for details."
        case .unavailable(let issue): return ExportRules.displayMessage(issue.message)
        }
    }

    static func summary(_ state: TierState) -> String {
        switch state {
        case .checking: return "Checking export options…"
        case .known(let tier, let factors, let container, _):
            let mode = ExportRules.cell(source: .multicam, tracks: .all, mode: ExportRules.bestMode(for: tier, source: .multicam)).displayName
            let description = factors.contains(where: { $0.id == .placementPicture })
                ? TierFactorID.placementPicture.summary : ExportRules.summary(tier: tier, source: .multicam)
            return description + " Use \(mode) to export video and audio as .\(container)."
        case .unavailable(let issue): return ExportRules.displayMessage(issue.message)
        }
    }
}

extension MulticamEditorModel {
    /// The tier of the program as a remote client reads it, in the shape `EditorModel.tierReport` and
    /// `mpcut inspect --project` use. Nil without a project. `current` is false while a newer program is being checked.
    var tierReport: [String: Any]? {
        guard let state = tierState else { return nil }
        var report: [String: Any] = ["name": state.name, "current": tierIsCurrent]
        switch state {
        case .checking: report["id"] = "checking"
        case .unavailable: report["id"] = "unavailable"
        case .known(let tier, _, let container, let warnings):
            report["id"] = tier.rawValue
            report["mode"] = ExportRules.bestMode(for: tier, source: .multicam).rawValue
            report["container"] = container
            report["warnings"] = warnings
        }
        report["factors"] = state.factors.map { factor -> [String: Any] in
            var entry: [String: Any] = ["id": factor.id.rawValue, "message": factor.message]
            if let forces = factor.forces { entry["forces"] = forces.rawValue }
            if let segment = factor.segment { entry["segment"] = segment }
            if let boundary = factor.boundary { entry["boundary"] = boundary }
            if let track = factor.track { entry["track"] = track }
            if let nearest = factor.nearest { entry["nearest"] = nearest.map(\.description) }
            return entry
        }
        return report
    }
}
