import Foundation

/// Public command paths. Each path selects its operation before any option or request is read.
enum CommandPath {
    static let transcript: [String: TranscriptCLI.Operation] = [
        "transcript provider capabilities": .capabilities, "transcript tracks list": .tracks,
        "transcript job run": .runJob, "transcript job prepare": .prepareSession, "transcript job status": .status, "transcript job cancel": .cancel,
        "transcript job retry": .retry, "transcript attachment import": .import, "transcript attachment inspect": .inspect,
        "transcript attachment bind": .bind, "transcript attachment detach": .detach, "transcript words read": .read,
        "transcript words search": .search, "transcript words locate": .locate, "transcript words compare": .compare,
        "transcript script align": .alignScript, "transcript words suggest": .suggest, "transcript words correct": .correct,
        "transcript words select": .select, "transcript edit plan": .plan, "transcript edit apply": .apply,
        "transcript excerpt queue": .queue, "transcript export": .export
    ]
    static let participants: [String: ParticipantCLI.Operation] = [
        "participants scan": .scan, "participants markers build": .markers, "participants project inspect": .inspect,
        "participants project accept": .accept, "participants project apply": .apply, "participants render plan": .plan,
        "participants render export": .render, "participants angles list": .angles,
        "participants angles plan": .planAngles, "participants angles render": .renderAngles
    ]
    static let stills: [String: StillOptions.Operation] = [
        "timeline gap insert": .add, "still picture replace": .add, "still placement insert": .add,
        "still placement list": .list, "still placement update": .update, "still placement remove": .remove,
        "still asset relink": .relink, "timeline clips space": .space
    ]
    static let paths = Set([
        "project create", "project edit", "multicam switch coverage", "project convert", "project resolve import", "project resolve export", "analysis sidecar inspect",
        "analysis sidecar build", "still project create", "silence shorten", "silence scan", "silence plan", "silence export",
        "scenes scan", "scenes export", "project media refresh", "multicam sync suggest", "waveform envelope read", "review frames export",
        "timeline range map", "history compare", "media inspect", "project inspect", "export ranges separate", "export project render",
        "export clips join", "export soundtrack replace", "export ranges join"
    ]).union(transcript.keys).union(stills.keys).union(participants.keys)

    static func match(_ tokens: [String]) -> String? {
        for count in [3, 2] where tokens.count >= count {
            let candidate = tokens.prefix(count).joined(separator: " ")
            if paths.contains(candidate), candidate.split(separator: " ").count == count { return candidate }
        }
        return nil
    }
}
