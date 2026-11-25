import Foundation
import MPCutCore

// What a planned export leaves behind or encodes, for every place that shows or reports a plan outside the CLI:
// the export sheet, the Export Queue review, the saved Export Result JSON and the MCP results. The sentences are
// the engine's own, the ones `mpcut export` lists under `warnings`.

extension ExportPlan {
    /// The export sheet summary, then what a packet copy leaves behind: cover art, chapters or timecode the chosen
    /// container or track selection cannot hold. `omissions` is `copyOmissions`, which reads file headers, so take it
    /// off the main thread and pass it here.
    func summary(noting omissions: [String]) -> String {
        let text = summary
        return ([text] + omissions.filter { !text.contains($0) }).joined(separator: "\n")
    }

    /// The warnings of the plan as `mpcut export` reports them: those of an encode, then what a copy leaves behind.
    /// Reads file headers for a copy.
    var reportedWarnings: [String] {
        let own = warnings
        return own + copyOmissions.filter { !own.contains($0) }
    }

    /// True for a packet copy of every selected sample, which has nothing to review unless it leaves something behind.
    var isPlainCopy: Bool {
        switch self {
        case .packets(_, let mode, _): return mode == .copy
        case .audio(let plan): return plan.isCopy
        case .conversion: return false
        }
    }

    /// What the Export Queue review shows for one ordinary range: the sheet summary with the omissions of a copy and
    /// the alternative the export rules applied. Nil for a plain copy that keeps everything, which has nothing to add.
    func queueReview(applied: ExportAlternative? = nil, omissions: [String]) -> String? {
        let notes = (applied.map { [$0.label] + $0.warnings } ?? []) + omissions
        if isPlainCopy && notes.isEmpty { return nil }
        return summary(noting: notes)
    }
}

extension ExportAvailability {
    /// What the ready plan of an ordinary export leaves behind. Reads file headers: call it off the main thread.
    var copyOmissions: [String] {
        if case .ready(let plan) = self { return plan.copyOmissions }
        return []
    }
}

enum ExportNotices {
    /// "Copied video: 40.500 s · Encoded video: 1.500 s", with the sentence the export sheet adds when Smart Trim
    /// copies nothing. Nil when no video is encoded.
    static func smartTrimSplit(copied: RationalTime, encoded: RationalTime) -> String? {
        guard encoded > .zero else { return nil }
        let durations = "Copied video: \(ExportRules.seconds(copied.seconds)) · Encoded video: \(ExportRules.seconds(encoded.seconds))"
        return copied == .zero ? durations + "\nSmart Trim needs to re-encode every frame in this selection." : durations
    }

    /// "Encoded audio: 0.075 s of AAC frames at 2 joins." for the AAC frames Smart Trim encodes where ranges meet in a
    /// Matroska output, from the plan's `encoded_audio_edges`. Nil when it encodes none.
    static func encodedAudio(_ edit: ResolvedEdit) -> String? {
        let joins = edit.segments.reduce(0) { $0 + ($1.encodedAudioEdges?.count ?? 0) }
        guard joins > 0 else { return nil }
        return "Encoded audio: \(ExportRules.seconds(edit.encodedAudioDuration.seconds)) of AAC frames at "
            + (joins == 1 ? "1 join." : "\(joins) joins.")
    }

    /// "Smart Trim re-encodes 1.500 s of 42.000 s." for the details of a Lossless tier. Nil when nothing is encoded.
    static func smartTrimShare(encoded: RationalTime, of duration: RationalTime) -> String? {
        guard encoded > .zero else { return nil }
        let name = ExportRules.displayName(mode: .smart)
        if encoded >= duration { return "\(name) re-encodes every frame of this timeline (\(ExportRules.seconds(duration.seconds)))." }
        return "\(name) re-encodes \(ExportRules.seconds(encoded.seconds)) of \(ExportRules.seconds(duration.seconds))."
    }

    /// `lines` after `text`, leaving out those `text` already states.
    static func appending(_ lines: [String], to text: String) -> String {
        lines.reduce(text) { $0.contains($1) ? $0 : $0 + "\n" + $1 }
    }

    /// "Smart Trim encoded 2 edges: 41 KB of a 45 KB target, 1 AV1 retry." for the message of a written export:
    /// the bytes the edge encoder produced against the edges' target, from `encoded_edge_results`. Nil when the
    /// export encoded no edge.
    static func encodedEdges(_ results: [EncodedEdgeResult]) -> String? {
        guard !results.isEmpty else { return nil }
        let size = ByteCountFormatter()
        size.countStyle = .file
        let encoded = results.reduce(Int64(0)) { $0 + Int64(clamping: $1.encodedBytes) }
        let target = results.reduce(Int64(0)) { $0 + Int64(clamping: $1.targetBytes) }
        let retries = results.filter(\.retried).count
        let edges = results.count == 1 ? "1 edge" : "\(results.count) edges"
        let retry = retries == 0 ? "" : retries == 1 ? ", 1 AV1 retry" : ", \(retries) AV1 retries"
        return "Smart Trim encoded \(edges): \(size.string(fromByteCount: encoded)) of a \(size.string(fromByteCount: target)) target\(retry)."
    }

    /// `next` as a further sentence of `message`, which may lack its full stop. `message` alone when `next` is nil.
    static func sentence(_ message: String, then next: String?) -> String {
        guard let next else { return message }
        return message + (message.hasSuffix(".") ? " " : ". ") + next
    }

    /// "Clip-001.mov: Smart Trim encoded 1 edge: 41 KB of a 45 KB target." for each written queue range that encoded
    /// an edge, in queue order, for the Export Queue's completion message. A range that encoded none adds nothing.
    static func queueEncodedEdges(_ written: [(output: URL, edges: [EncodedEdgeResult])]) -> [String] {
        written.compactMap { row in encodedEdges(row.edges).map { "\(row.output.lastPathComponent): \($0)" } }
    }
}

extension ExportPlan {
    /// Runs `write`, which writes this plan, and returns what each Smart Trim edge it encoded cost, as
    /// `mpcut export` reports it under `encoded_edge_results`. Empty for any plan but Smart Trim. The edge encoder
    /// keeps one record for the whole process, so an export that runs at the same time can leave edges out.
    func writingEncodedEdges(_ write: () throws -> Void) rethrows -> [EncodedEdgeResult] {
        guard case .packets(let edit, .smart, _) = self else {
            try write()
            return []
        }
        SmartTrimEdgeResults.reset()
        try write()
        return SmartTrimEdgeResults.take(for: edit)
    }
}

// MARK: Export Queue

extension SequenceQueuePlan.Item {
    /// The review of an ordinary range under its file name. Nil for a still range, which has its own summary, and for
    /// a plain copy that keeps everything. Reads file headers for a copy.
    var ordinaryReview: String? {
        guard case .ordinary(let planned) = payload,
              let review = planned.plan.queueReview(applied: planned.applied, omissions: planned.plan.copyOmissions) else { return nil }
        return "\(output.lastPathComponent)\n\(review)"
    }

    /// True for a range the queue plans as an ordinary export.
    var isOrdinary: Bool {
        if case .ordinary = payload { return true }
        return false
    }

    /// The plan of an ordinary range as a remote client reads it. Nil for the ranges reported under their own keys.
    func rangePlan() throws -> [String: Any]? {
        guard case .ordinary(let planned) = payload else { return nil }
        return try MCPRangePlan(destination: output.path, plan: planned.plan, applied: planned.applied).json()
    }
}

extension SequenceQueuePlan {
    /// Writes one range and returns what each Smart Trim edge of an ordinary range cost, as `mpcut export ranges separate`
    /// reports it under `encoded_edge_results`. The edge encoder keeps one record for the whole process, so the edges are
    /// taken right after this range's write, before the next range starts. Empty for a still or picture range.
    func writeReportingEdges(_ item: Item, progress: @escaping @Sendable (Double) -> Bool) throws -> [EncodedEdgeResult] {
        guard case .ordinary(let planned) = item.payload else {
            try write(item, progress: progress)
            return []
        }
        return try planned.plan.writingEncodedEdges { try write(item, progress: progress) }
    }

    /// The review the Export Queue shows before it asks for a folder, in queue order. `others` holds the summaries of
    /// the ranges that are not ordinary exports, in their order. Nil when no range has anything to review.
    func review(interleaving others: [String]) -> String? {
        var rest = others.makeIterator()
        var summaries: [String] = []
        for item in items {
            if item.isOrdinary {
                if let review = item.ordinaryReview { summaries.append(review) }
            } else if let next = rest.next() {
                summaries.append(next)
            }
        }
        while let next = rest.next() { summaries.append(next) }
        return summaries.isEmpty ? nil : summaries.joined(separator: "\n\n")
    }
}

extension MulticamExportPlan {
    /// How much video Smart Trim copies and encodes, when it encodes any. Nil for a copy, a full re-encode and sound alone.
    var smartTrimSplit: String? {
        guard mode == .smart, tracks != .audio else { return nil }
        return ExportNotices.smartTrimSplit(copied: copiedVideoDuration, encoded: encodedVideoDuration)
    }

    /// The warnings of the plan as `mpcut export` reports them for a multicam program: those of the encode and the
    /// sound, then what the program leaves out of its sources, such as the chapters of a camera other than the
    /// reference angle or chapters the container cannot hold.
    var reportedWarnings: [String] {
        warnings + copyOmissions.filter { !warnings.contains($0) }
    }

    /// What the multicam export sheet reviews before it writes: how much video Smart Trim encodes, the audio
    /// delivery, and the warnings of the plan with what it leaves out.
    var deliveryReview: String {
        ExportNotices.appending(reportedWarnings, to: [smartTrimSplit, audioDeliverySummary].compactMap { $0 }.joined(separator: "\n"))
    }

    /// The top-level fields an MCP plan or render result adds for a multicam program, beside `plan` and `cut_map`:
    /// `warnings` with what it leaves out, as `mpcut export` lists them, when there are any. `plan.warnings` keeps
    /// the encoded plan's own.
    var mcpNotes: [String: Any] {
        let reported = reportedWarnings
        return reported.isEmpty ? [:] : ["warnings": reported]
    }

    /// The plan as the saved Export Result JSON states it: the encoded plan, with what the program leaves out
    /// after its own warnings under `warnings`, as for an ordinary export.
    var resultPlan: MulticamResultPlan { MulticamResultPlan(plan: self) }
}

/// A multicam plan for the saved Export Result JSON. `warnings` adds what the program leaves out of its sources.
struct MulticamResultPlan: Encodable {
    let plan: MulticamExportPlan

    private enum CodingKeys: String, CodingKey { case warnings }

    func encode(to encoder: Encoder) throws {
        try plan.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(plan.reportedWarnings, forKey: .warnings)
    }
}

extension MulticamBulkExport.Item {
    /// The review of one multicam range: how much video Smart Trim copies and encodes, the audio delivery, and the
    /// warnings of the plan with what it leaves out.
    var review: String {
        guard case .multicam(let plan) = payload else { return audioDeliverySummary }
        let delivery = [plan.smartTrimSplit, audioDeliverySummary].compactMap { $0 }.joined(separator: "\n")
        return ExportNotices.appending(plan.reportedWarnings, to: delivery)
    }
}

// MARK: MCP

/// One ordinary range of a queue export as `export_queue_plan` and `export_queue_render` report it under `range_plans`.
struct MCPRangePlan: Encodable {
    let destination: String
    let mode: ExportMode
    let tracks: ExportTracks
    let container: String
    let duration: RationalTime
    /// How the picture of the range is written. Absent for a sound-only range.
    let copiedVideoDuration: RationalTime?
    let encodedVideoDuration: RationalTime?
    /// What is written for each converted audio track. Absent for a copy.
    let audioActions: [ReencodeAudioAction]?
    /// The alternative the export rules applied, when `audio: auto` could not copy.
    let applied: String?
    let warnings: [String]
    let summary: String

    init(destination: String, plan: ExportPlan, applied alternative: ExportAlternative? = nil) {
        self.destination = destination
        mode = plan.mode
        container = plan.edit.container
        duration = plan.edit.duration
        applied = alternative?.label
        let reported = plan.reportedWarnings
        warnings = (alternative?.warnings.filter { !reported.contains($0) } ?? []) + reported
        summary = plan.summary
        switch plan {
        case .packets(let edit, let mode, let tracks):
            self.tracks = tracks
            let picture = tracks != .audio && edit.segments.contains { $0.tracks.contains { $0.kind == "video" } }
            copiedVideoDuration = picture ? try? edit.copiedVideoDuration(for: mode) : nil
            encodedVideoDuration = picture ? try? edit.encodedVideoDuration(for: mode) : nil
            audioActions = nil
        case .conversion(let conversion):
            tracks = .all
            copiedVideoDuration = .zero
            encodedVideoDuration = conversion.edit.duration
            audioActions = conversion.audioActions
        case .audio(let audio):
            tracks = .audio
            copiedVideoDuration = nil
            encodedVideoDuration = nil
            audioActions = audio.isCopy ? nil : audio.actions
        }
    }

    func json() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(self)) as? [String: Any] else {
            throw MCPCommandError("export_failed", "The range plan could not be reported.")
        }
        return object
    }
}

extension EditorModel {
    /// How much of the timeline Smart Trim encodes, for the details of a Lossless tier: "Smart Trim re-encodes
    /// 1.500 s of 42.000 s." The tier itself carries no durations, so this is one planning pass, made when the
    /// details open. Nil for any other tier, for a timeline without picture or with stills, and while an edit is pending.
    func smartTrimShare() async -> String? {
        guard tierIsCurrent, case .known(.lossless, _, let container, _)? = tierState, !isAudioOnly,
              stillProject.participants.render == nil, (try? stillProject.exportPlacementScope()) == ExportPlacementScope.none,
              let input = try? mcpExportInput(selection: false) else { return nil }
        let useSidecar = useAnalysisSidecars, excluded = sidecarExclusions
        let clips = input.clips, media = input.media
        return await sidecarWork.detached(priority: .utility) { () -> String? in
            AnalysisSidecar.$excludedSources.withValue(excluded) {
                let request = ExportRequest(clips: clips, mode: .smart, container: container)
                let planner = ExportPlanner(cancelled: { Task.isCancelled }, useSidecar: useSidecar)
                guard case .ready(.packets(let edit, .smart, _), _, _) = planner.resolve(request, media: media),
                      let encoded = try? edit.encodedVideoDuration(for: .smart) else { return nil }
                return ExportNotices.smartTrimShare(encoded: encoded, of: edit.duration)
            }
        }.value
    }
}

extension ExportPlan {
    /// The top-level fields an MCP plan or render result adds for an ordinary export, beside `plan` and `cut_map`:
    /// `warnings` when the plan reports any, so a plain copy that keeps everything has no such field, as in the CLI,
    /// and `audio_actions` for the tracks of a movie re-encode, where a sound-only conversion already reports them.
    func mcpNotes() throws -> [String: Any] {
        var notes: [String: Any] = [:]
        let reported = reportedWarnings
        if !reported.isEmpty { notes["warnings"] = reported }
        if case .conversion(let conversion) = self {
            notes["audio_actions"] = try JSONSerialization.jsonObject(with: MCPSchemas.encodeResult(conversion.audioActions))
        }
        return notes
    }
}
