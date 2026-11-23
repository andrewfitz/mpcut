import Foundation
import MPCutCore

extension EditorModel {
    func stillReviewTime(in plan: StillTimelinePlan) -> RationalTime {
        if playhead == plan.duration.seconds { return plan.duration }
        // Compare against the displayed boundaries before converting to an exact program time.
        let index = plan.spans.lowerBound { $0.output.to.seconds > playhead }
        guard plan.spans.indices.contains(index) else { return plan.duration }
        let range = plan.spans[index].output
        if playhead <= range.from.seconds { return range.from }
        let scale: Int64 = 1_000_000_000
        guard let ticks = Int64(exactly: (playhead * Double(scale)).rounded()) else { return range.from }
        let approximate = RationalTime(numerator: ticks, denominator: scale)
        if approximate < range.to { return max(range.from, approximate) }
        let previous = try? range.to.subtracting(RationalTime(numerator: 1, denominator: scale))
        return max(range.from, previous ?? range.from)
    }

    func stillFrameAtPlayhead() throws -> StillReviewFrame? {
        let project = stillProject
        guard project.hasReviewStills else { return nil }
        let plan = try project.resolveStills()
        guard let index = plan.pictureIndex(at: stillReviewTime(in: plan)),
              let placement = plan.spans[index].placementID else { return nil }
        return try project.stillReviewFrame(placementID: placement, interval: plan.spans[index].output,
                                            document: projectURL, canvas: stillReviewCanvas)
    }
}

extension MulticamEditorModel {
    var stillReviewCanvas: MediaInfo? {
        mapping?.picture.lazy.compactMap { self.media[$0.source] }.first(where: \.hasVideo)
            ?? media.sorted { $0.key < $1.key }.lazy.map(\.value).first(where: \.hasVideo)
    }

    func stillReviewContext(clock: String, time: RationalTime?, resolvedPlan: StillTimelinePlan? = nil) throws
        -> (project: CutProject, plan: StillTimelinePlan, index: Int, time: RationalTime) {
        guard var project else { throw MCPCommandError("no_frame", "Open a multicam project.") }
        let at: RationalTime
        switch clock {
        case "group":
            project.assemblyItems = nil
            if let time {
                guard project.range.contains(time) else {
                    throw MCPCommandError("invalid_target", "Choose a time within the multicam group.")
                }
                at = try time.subtracting(project.range.from)
            } else {
                at = preview.currentTime()
            }
        case "assembly":
            at = time ?? preview.currentTime()
        default:
            throw MCPCommandError("invalid_target", "Choose group or assembly time.")
        }
        let snapshot = CutProject.multicam(project)
        let plan = try resolvedPlan ?? snapshot.resolveStills()
        guard let index = plan.pictureIndex(at: at) else {
            throw MCPCommandError("no_frame", "No program picture covers this position.")
        }
        return (snapshot, plan, index, at)
    }

    func stillFrameAtPlayhead() throws -> StillReviewFrame? {
        guard let project = stillPreviewProject, project.hasReviewStills else { return nil }
        let context = try stillReviewContext(clock: assemblyPreview ? "assembly" : "group", time: nil)
        let span = context.plan.spans[context.index]
        guard let placement = span.placementID else { return nil }
        return try project.stillReviewFrame(placementID: placement, interval: span.output,
                                            document: projectURL, canvas: stillReviewCanvas)
    }
}
