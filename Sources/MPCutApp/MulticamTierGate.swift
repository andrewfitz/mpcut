import AppKit
import MPCutCore

// The question the multicam editor asks when an edit made by hand lowers the tier of the program. The program is
// planned off the main thread, so the tier of an edit arrives after the edit. The question is asked then. The tier
// that arrives is compared with the tier of the program before the first of the edits: the one the badge showed for
// that program, or one found for the question when the edits came before it was known. Cancel returns to that
// program. When moving the cuts that lower the tier to verified times returns the program to its tier, the question
// offers that too.
//
// Nothing is by hand unless it runs inside `byHand`, and only `MulticamEditorModel.edit` is noted there. Remote
// commands, opening, relinking and indexing never run inside it, and undo and redo are not edits, so none of them asks.
// A still edit that one of the editor's panels, drops or image imports commits after its command returned runs inside
// `byHand` at the commit (`performStillEditByHand`). No mark is kept between the command and the commit.

/// What one multicam editor remembers between its edits made by hand and the tier that follows them.
@MainActor
final class MulticamTierGate {
    /// Asks in place of the alert. Tests set it.
    var ask: ((TierPrompt, @escaping (TierPrompt.Choice) -> Void) -> Void)?

    /// A known tier, with the program and the source indexes it was found for.
    private struct Known {
        let tier: FidelityTier
        let factors: [TierFactor]
        let program: MulticamProject
        let generation: UUID
        let media: UInt64
    }

    /// The edits made by hand one after another, with nothing else in between.
    private struct Edits {
        let id = UUID()
        /// The tier of the program before the first of them. Nil until it is found.
        var from: Known?
        /// The project before the first of them.
        let prior: MulticamProject
        let generation: UUID
        var count = 1
        /// The last of them, as history names it.
        var action: String
        /// The program after the last of them.
        var program: MulticamProject
        var revision: Int
        var waitedForSheet = false
    }

    /// What is found off the main actor for a tier that arrived after edits made by hand.
    private struct Comparison: Sendable {
        /// The tier of the program before the edits. Nil when that program had none.
        var from: (tier: FidelityTier, factors: [TierFactor])?
        /// The cuts to move so that the program after the edits has that tier again.
        var moves: [Move]?
    }

    private var known: Known?
    private var edits: Edits?
    private var isAsking = false
    private var comparing: (id: UUID, token: EditCancellation)?

    /// True while a tier that arrived is compared off the main actor. The question, if any, follows.
    var isComparing: Bool { comparing != nil }

    // MARK: Edits made by hand

    private static var armed: (depth: Int, task: Int?) = (0, nil)
    private static var currentTask: Int? { withUnsafeCurrentTask { $0?.hashValue } }

    /// True for an edit made inside `byHand` by the task or event that entered it. A remote command that a nested
    /// run loop lets in while `byHand` runs is another task.
    private static var isByHand: Bool { armed.depth > 0 && armed.task == currentTask }

    /// Runs edits made by hand, so that the editor of each asks when they lower its tier.
    @discardableResult
    static func byHand<Result>(_ edit: () throws -> Result) rethrows -> Result {
        let outer = armed
        armed = (outer.depth + 1, outer.depth == 0 ? currentTask : outer.task)
        defer { armed = outer }
        return try edit()
    }

    /// What the tier is found for: the project without its transcripts, which no export mode reads.
    private static func program(_ project: MulticamProject) -> MulticamProject {
        var program = project
        program.transcripts = .init()
        return program
    }

    /// Notes an edit that changed the project from `previous`. Edits made by hand are kept while they follow one
    /// another. Any other edit forgets them.
    func edited(_ model: MulticamEditorModel, from previous: MulticamProject) {
        guard let project = model.project else { return }
        let before = Self.program(previous), after = Self.program(project)
        guard before != after else { return }
        // Adding or relinking a source is followed by its index, which is not a tier of the same sources.
        guard Self.isByHand, !isAsking, model.preferences.warnBeforeLoweringExportTier,
              before.sources.map(\.id) == after.sources.map(\.id), before.sources.map(\.file) == after.sources.map(\.file) else {
            edits = nil
            return
        }
        let action = model.lastEditAction ?? "Edit"
        if var current = edits, current.program == before, current.generation == model.mcpGeneration {
            current.count += 1
            current.action = action
            current.program = after
            current.revision = model.mcpRevision
            edits = current
        } else {
            // The last known tier is the tier before this edit only when it is the tier of this program. After a
            // remote edit, or before the first tier arrives, it is found when the tier of the edit arrives.
            let from = known.flatMap { $0.program == before && $0.generation == model.mcpGeneration ? $0 : nil }
            edits = Edits(from: from, prior: previous, generation: model.mcpGeneration, action: action, program: after,
                          revision: model.mcpRevision)
        }
    }

    // MARK: The tier that follows

    /// Receives the tier of the program once it is current. Asks when the edits made by hand lowered it.
    func settled(_ model: MulticamEditorModel) {
        guard model.tierIsCurrent, let project = model.project, let state = model.tierState else { return }
        switch state {
        // Not a tier: the check was cancelled, or a source is being indexed, is missing or changed on disk.
        case .checking: return
        case .unavailable(let issue) where issue.code == "missing_source" || issue.factor == .sourceChanged: return
        default: break
        }
        // A comparison with an earlier tier is superseded by this one.
        comparing?.token.cancel()
        comparing = nil
        let made = edits
        edits = nil
        known = state.tier.map {
            Known(tier: $0, factors: state.factors, program: Self.program(project), generation: model.mcpGeneration,
                  media: model.transcriptMediaRevision)
        }
        // Undo, redo or a remote edit since the last edit by hand: the tier is no longer theirs.
        guard var made, canAsk(made, in: model) else { return }
        // A tier found with other source indexes is not compared with this one. It is found again.
        if made.from?.media != model.transcriptMediaRevision { made.from = nil }
        if let from = made.from, !Self.lowers(state, from.tier) { return }
        if ask == nil {
            guard let window = model.window, window.isVisible else { return }
            if window.attachedSheet != nil {
                // The sheet an edit was made from is still closing. One that stays up is the user's next task.
                guard !made.waitedForSheet else { return }
                made.waitedForSheet = true
                edits = made
                Task { [weak self, weak model] in
                    try? await Task.sleep(for: .milliseconds(600))
                    if let self, let model { self.settled(model) }
                }
                return
            }
        }
        compare(made, with: state, in: model)
    }

    /// True when `tier` is lower than `from`. No tier at all is lower than any.
    nonisolated private static func lowers(_ state: TierState, _ from: FidelityTier) -> Bool {
        state.tier.map { $0 < from } ?? true
    }

    /// True while `made` are the last changes to the project and the editor is free to ask about them.
    private func canAsk(_ made: Edits, in model: MulticamEditorModel) -> Bool {
        !isAsking && made.generation == model.mcpGeneration && made.revision == model.mcpRevision
            && model.preferences.warnBeforeLoweringExportTier && !model.isBusy && model.setup.isEmpty && model.notice == nil
    }

    /// Finds off the main actor what the question needs, as `refreshTier` finds the tier: the tier of the program
    /// before the edits when it is not known, and the cuts to move. Edits made by hand meanwhile join `made`, and
    /// the tier of the last of them decides.
    private func compare(_ made: Edits, with state: TierState, in model: MulticamEditorModel) {
        let id = UUID(), token = EditCancellation()
        comparing = (id, token)
        edits = made
        let indexed = model.media.filter { $0.value.hasFullEditIndex }
        let media = model.transcriptMediaRevision, checked = model.tierGeneration
        let prior = Self.program(made.prior), program = made.program
        let from = made.from.map { (tier: $0.tier, factors: $0.factors) }
        let context = model.sidecarWork
        Task { [weak self, weak model] in
            let found = await context.detached(priority: .utility) {
                Self.comparison(of: program, state, with: prior, from: from, indexed: indexed, cancelled: { token.isCancelled })
            }.value
            guard let self, let model, self.comparing?.id == id else { return }
            self.comparing = nil
            // Any other edit meanwhile forgot them.
            guard var current = self.edits, current.id == made.id else { return }
            if current.from == nil, let from = found.from {
                current.from = Known(tier: from.tier, factors: from.factors, program: prior, generation: made.generation, media: media)
                self.edits = current
            }
            // Edited again by hand, undone or indexed anew meanwhile: the tier of that program is still to come.
            guard current.revision == made.revision, model.tierIsCurrent, model.tierGeneration == checked else { return }
            self.edits = nil
            guard let from = current.from, Self.lowers(state, from.tier), self.canAsk(current, in: model) else { return }
            self.question(current, from: from, to: state, moves: found.moves, in: model)
        }
    }

    nonisolated private static func comparison(of program: MulticamProject, _ state: TierState, with prior: MulticamProject,
                                               from known: (tier: FidelityTier, factors: [TierFactor])?,
                                               indexed: [String: MediaInfo], cancelled: @escaping @Sendable () -> Bool) -> Comparison {
        let engine = MulticamEngine(cancelled: cancelled)
        var found = Comparison(from: known)
        if found.from == nil {
            // As `refreshTier` plans: a program whose sources are not all indexed is not planned.
            let placed = ((try? CutProject.multicam(prior).exportPlacementScope()) ?? ExportPlacementScope.none) != .none
            guard placed || prior.sources.allSatisfy({ indexed[$0.id] != nil }) else { return found }
            let before = engine.tier(prior, indexedSources: indexed)
            guard let tier = before.tier else { return found }
            found.from = (tier, before.factors)
        }
        guard let tier = found.from?.tier, lowers(state, tier) else { return found }
        found.moves = nearest(program, state, reaching: tier, otherThan: prior, engine: engine, indexed: indexed)
        return found
    }

    private func question(_ made: Edits, from: Known, to state: TierState, moves: [Move]?, in model: MulticamEditorModel) {
        if ask == nil {
            guard let window = model.window, window.isVisible, window.attachedSheet == nil else { return }
        }
        let before = Set(from.factors.map(\.message))
        let added = state.factors.filter { !before.contains($0.message) }
        let prompt = TierPrompt(action: made.action, from: from.tier, to: state, factors: added.isEmpty ? state.factors : added,
                                nearest: nil, soundOnly: false, applied: made.count, moves: moves,
                                describe: model.namingSources(model.project),
                                movements: moves?.map { $0.movement(in: made.program, media: model.media) } ?? [])
        isAsking = true
        let answer: (TierPrompt.Choice) -> Void = { [weak self, weak model] choice in
            guard let self, let model else { return }
            // What the answer changes is not an edit made by hand.
            defer { self.isAsking = false }
            if choice.dontAskAgain { model.preferences.warnBeforeLoweringExportTier = false }
            switch choice.answer {
            case .proceed: break
            case .cancel: self.undo(made, in: model)
            case .nearest: self.move(moves ?? [], after: made, in: model)
            }
        }
        if let ask { ask(prompt, answer) } else { TierPrompt.present(prompt, in: model.window, answer: answer) }
    }

    /// Returns the project to what it was before `made`, when they are still the last changes to it.
    private func undo(_ made: Edits, in model: MulticamEditorModel) {
        guard made.generation == model.mcpGeneration, made.revision == model.mcpRevision, !model.isBusy,
              let project = model.project else { return }
        let target = model.historyCursor - made.count
        if model.undoStack.indices.contains(target), Self.program(model.undoStack[target].project) == Self.program(made.prior) {
            model.moveToHistoryState(target)
            return
        }
        // History is off or no longer holds the edits. The project before them is restored as an edit of its own.
        var restored = made.prior
        var transcripts = project.transcripts
        if transcripts.authoring != restored.transcripts.authoring {
            transcripts.authoring = restored.transcripts.authoring
            guard (try? transcripts.advanceRevision()) != nil else { return }
        }
        restored.transcripts = transcripts
        model.edit("Undo " + made.action) { $0 = restored }
    }

    // MARK: The nearest verified times

    /// A cut moved to a verified time: a switch, or one edge of an assembly range.
    enum Move: Equatable, Sendable {
        case switchAt(RationalTime, to: RationalTime)
        case edge(MulticamEdge, to: RationalTime)

        /// The move of the cut `factor` names to the verified time nearest to it that `project` can take.
        init?(_ factor: TierFactor, in project: MulticamProject) {
            let times = factor.nearest ?? []
            if let at = factor.switchAt {
                guard at != project.range.from, project.switches.contains(where: { $0.at == at }) else { return nil }
                let free = times.filter { time in
                    time > project.range.from && time < project.range.to && !project.switches.contains { $0.at == time }
                }
                guard let to = Self.closest(free, to: at) else { return nil }
                self = .switchAt(at, to: to)
            } else if let edge = factor.edge {
                let items = project.assemblyItems ?? [.group(project.range)]
                guard items.indices.contains(edge.range - 1), let range = items[edge.range - 1].group else { return nil }
                let suggestion = MulticamEdgeSuggestion(edge: edge, times: times)
                guard let to = Self.closest(times.filter { suggestion.moving(range, to: $0) != nil }, to: edge.at) else { return nil }
                self = .edge(edge, to: to)
            } else {
                return nil
            }
        }

        private static func closest(_ times: [RationalTime], to at: RationalTime) -> RationalTime? {
            times.filter { $0 != at }.min { a, b in
                let (x, y) = (abs(a.seconds - at.seconds), abs(b.seconds - at.seconds))
                return x == y ? a < b : x < y
            }
        }

        func movement(in project: MulticamProject, media: [String: MediaInfo]) -> TierPrompt.CutMovement {
            func frameCount(for angle: String, between a: RationalTime, and b: RationalTime) -> Int? {
                let start = min(a, b), end = max(a, b)
                guard let source = project.pictureSource(for: angle, at: start),
                      project.pictureSource(for: angle, at: end, exclusiveEnd: true)?.id == source.id,
                      let from = try? start.subtracting(source.offset), let to = try? end.subtracting(source.offset) else { return nil }
                return TierPrompt.CutMovement.indexedFrameCount(from: from, to: to, in: media[source.id])
            }

            switch self {
            case .switchAt(let at, let to):
                let before = project.switches.last { $0.at < at }?.angle
                let after = project.switches.first { $0.at == at }?.angle
                let outgoing = before.flatMap { frameCount(for: $0, between: at, and: to) }
                let incoming = after.flatMap { frameCount(for: $0, between: at, and: to) }
                return .init(label: "Switch", requested: at, resolved: to, frameCount: outgoing == incoming ? outgoing : nil)
            case .edge(let edge, let to):
                let item = (project.assemblyItems ?? [.group(project.range)])[edge.range - 1]
                let lower = min(edge.at, to), upper = max(edge.at, to)
                let angle = project.selection(at: lower)?.angle
                let changesAngle = project.switches.contains { $0.at > lower && $0.at < upper && $0.angle != angle }
                let fixedAngle = item.angleOverride ?? (changesAngle ? nil : angle)
                let frames = fixedAngle.flatMap { frameCount(for: $0, between: edge.at, and: to) }
                let isStart = edge.boundary == "from"
                return .init(label: "Range \(edge.range) \(isStart ? "In" : "Out")", requested: edge.at, resolved: to,
                             frameCount: frames, edge: isStart ? .start : .end)
            }
        }

        /// As history names it.
        var action: String {
            switch self {
            case .switchAt: return "Move Switch"
            case .edge: return "Move Range Edge"
            }
        }

        /// True when this moved the cut `factor` names.
        func moved(_ factor: TierFactor) -> Bool {
            switch self {
            case .switchAt(let at, _): return factor.switchAt == at
            case .edge(let edge, _): return factor.edge.map { $0.range == edge.range && $0.boundary == edge.boundary } ?? false
            }
        }

        /// This move and `next` as one, when `next` moves the same cut on from where this left it.
        func followed(by next: Move) -> Move? {
            switch (self, next) {
            case (.switchAt(let at, let to), .switchAt(let from, let further)) where from == to:
                return .switchAt(at, to: further)
            case (.edge(let edge, let to), .edge(let from, let further))
                where from.range == edge.range && from.boundary == edge.boundary && from.at == to:
                return .edge(edge, to: further)
            default: return nil
            }
        }

        /// Moves the cut as `moveSwitch` and `applyEdgeSuggestion` move it, on a project that is planned off the main
        /// actor before the move is offered. False when the cut is no longer where it was found.
        func apply(to project: inout MulticamProject) -> Bool {
            switch self {
            case .switchAt(let at, let to):
                guard let index = project.switches.firstIndex(where: { $0.at == at }),
                      !project.switches.contains(where: { $0.at == to }) else { return false }
                project.switches[index].at = to
                project.switches.sort { $0.at < $1.at }
            case .edge(let edge, let to):
                var items = project.assemblyItems ?? [.group(project.range)]
                guard items.indices.contains(edge.range - 1), let range = items[edge.range - 1].group,
                      let moved = MulticamEdgeSuggestion(edge: edge, times: [to]).moving(range, to: to) else { return false }
                items[edge.range - 1] = items[edge.range - 1].trimmingGroup(to: moved)
                project.assemblyItems = items
            }
            return true
        }
    }

    /// How many times the program is planned again to find the cuts to move. A mode names one cut at a time.
    nonisolated private static let moveLimit = 6

    /// The cuts to move so that `program` reaches `tier`. Every cut that keeps it lower goes to the verified time
    /// nearest to it, as the file editor moves every cut of a timeline. Nil when one of them cannot move, when the
    /// program still plans lower, or when the moves return the program to `prior`, which Cancel does.
    nonisolated private static func nearest(_ program: MulticamProject, _ state: TierState, reaching tier: FidelityTier,
                                            otherThan prior: MulticamProject, engine: MulticamEngine,
                                            indexed: [String: MediaInfo]) -> [Move]? {
        var candidate = program, state = state, moves: [Move] = [], steps: [Move] = []
        for _ in 0..<moveLimit {
            let lowering = state.factors.filter { factor in factor.forces.map { $0 < tier } ?? true }
            guard !lowering.isEmpty else { return nil }
            var round: [Move] = []
            for factor in lowering where !round.contains(where: { $0.moved(factor) }) {
                // Two modes can stop at one cut. It moves once.
                guard let move = Move(factor, in: candidate), move.apply(to: &candidate) else { return nil }
                round.append(move)
            }
            steps += round
            for move in round {
                // A cut that a later mode moves on is one move.
                if let index = moves.firstIndex(where: { $0.followed(by: move) != nil }), let joined = moves[index].followed(by: move) {
                    moves[index] = joined
                } else {
                    moves.append(move)
                }
            }
            guard (try? candidate.plan()) != nil, (try? candidate.groupIntervals()) != nil else { return nil }
            state = engine.tier(candidate, indexedSources: indexed)
            guard let reached = state.tier, reached >= tier else { continue }
            guard played(candidate) != played(prior) else { return nil }
            // Each edge moved on its own. Two ranges that were joined must still be, or pictures would drop or repeat.
            guard seams(program).isSubset(of: seams(candidate)) else { return nil }
            // The moves are offered when they lead to the program the tier was found for, and the steps otherwise.
            var joined = program
            return moves.allSatisfy({ $0.apply(to: &joined) }) && joined == candidate ? moves : steps
        }
        return nil
    }

    /// The positions in the assembly where a range ends at the group time at which the next one starts.
    nonisolated private static func seams(_ program: MulticamProject) -> Set<Int> {
        let items = program.assemblyItems ?? []
        return Set(items.indices.dropLast().filter { index in
            guard let before = items[index].group, let after = items[index + 1].group else { return false }
            return before.to == after.from
        })
    }

    /// The program with its assembly written out. A program without one plays its whole group.
    nonisolated private static func played(_ program: MulticamProject) -> MulticamProject {
        var program = program
        if program.assemblyItems == nil { program.assemblyItems = [.group(program.range)] }
        return program
    }

    /// Moves the cuts as one edit, when `made` are still the last changes to the project. It answers the question,
    /// so it asks nothing.
    private func move(_ moves: [Move], after made: Edits, in model: MulticamEditorModel) {
        guard made.generation == model.mcpGeneration, made.revision == model.mcpRevision, !model.isBusy,
              let first = moves.first else { return }
        model.preview.pause()
        if moves.count == 1, case .switchAt(let at, let to) = first { return model.moveSwitch(at, to: to) }
        let selected = model.selectedSwitch, revision = model.mcpRevision
        // All of the cuts move or none does: the tier was found for the program with every one of them moved.
        guard model.edit(moves.count == 1 ? first.action : "Move Cuts to Verified Times", { project in
            var moved = project
            if moves.allSatisfy({ $0.apply(to: &moved) }) { project = moved }
        }), model.mcpRevision != revision else { return }
        // The switch the inspector showed is the one that moved.
        for case .switchAt(let at, let to) in moves where at == selected { model.selectedSwitch = to }
    }
}

extension MulticamEditorModel {
    /// Rewrites a planner message so that it names each source of `project` instead of giving its id.
    func namingSources(_ project: MulticamProject?) -> (String) -> String {
        let names = (project?.sources ?? []).map { ($0.id, $0.displayName) }
        return { message in
            names.reduce(message) { text, source in
                text.replacingOccurrences(of: "Source \(source.0) ", with: "Source \(source.1) ")
                    .replacingOccurrences(of: "Angle \(source.0) ", with: "Angle \(source.1) ")
            }
        }
    }

    /// Runs an edit made by hand, so that the editor asks when it lowers the tier.
    @discardableResult
    func byHand<Result>(_ edit: () throws -> Result) rethrows -> Result {
        try MulticamTierGate.byHand(edit)
    }

    /// A still edit that a panel, a drop or an image import of the editor commits after its command returned. Only a
    /// person reaches those, so it is made by hand. A remote command commits through `performStillEdit`.
    @discardableResult
    func performStillEditByHand(_ action: String, _ change: (CutProject) throws -> CutProject) -> Bool {
        byHand { performStillEdit(action, change) }
    }
}
