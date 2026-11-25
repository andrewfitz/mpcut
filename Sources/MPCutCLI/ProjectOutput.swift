import Foundation
import MPCutCore

struct ProjectOutputOptions {
    enum Operation: String { case read, set }

    let project: String
    let operation: Operation
    private var fields: [String: String] = [:]
    private var ids: [String] = []
    private var inPlace = false

    init(_ operation: Operation, arguments: [String]) throws {
        var tokens = arguments.filter { $0 != "--json" }.makeIterator()
        guard let source = tokens.next(), !source.isEmpty, !source.hasPrefix("--"), !isStandardInput(source) else {
            throw CLIError("invalid_arguments", "Supply a saved project as the first operand.")
        }
        project = source
        self.operation = operation
        let fields: Set<String> = ["--width", "--height", "--frame-rate", "--background", "--audio-mode", "--unresolved-privacy", "--out-project"]
        while let flag = tokens.next() {
            guard operation == .set else { throw CLIError("invalid_arguments", "Unexpected argument " + flag + ".") }
            if flag.hasPrefix("--audio-id=") {
                let id = String(flag.dropFirst("--audio-id=".count))
                guard !id.isEmpty, !id.utf8.contains(0) else {
                    throw CLIError("invalid_arguments", "Supply a nonempty ID for --audio-id.")
                }
                ids.append(id)
                continue
            }
            if flag == "--in-place", !inPlace {
                inPlace = true
                continue
            }
            guard (fields.contains(flag) && self.fields[flag] == nil || flag == "--audio-id"),
                  let value = tokens.next(), !value.isEmpty, !value.hasPrefix("--"), !value.utf8.contains(0) else {
                throw CLIError("invalid_arguments", "Unknown, repeated or incomplete option " + flag + ".")
            }
            if flag == "--audio-id" { ids.append(value) }
            else { self.fields[flag] = value }
        }
        if operation == .set {
            guard inPlace != (self.fields["--out-project"] != nil), self.fields.keys.contains(where: { $0 != "--out-project" }) else {
                throw CLIError("invalid_arguments", "Supply at least one setting and choose --out-project FILE or --in-place.")
            }
            guard ids.isEmpty || self.fields["--audio-mode"] != nil else {
                throw CLIError("invalid_arguments", "Supply --audio-mode with --audio-id.")
            }
        }
    }

    func run(json: Bool, interruption: Interruption) throws {
        let source = try fileURL(project, label: "Project")
        let archive = try CLIProjectMediaArchive(at: source)
        let project = archive.project
        var defaultCanvas = project.projectOutputSettings.canvas
        if !project.hasStoredOutputCanvas {
            let engine = CutEngine(cancelled: { !interruption.isActive }, useSidecar: false, tracks: .video)
            if let canvas = try project.inspectSourceOutputCanvas(relativeTo: source, engine: engine) {
                defaultCanvas = canvas
            }
        }
        let destination = try archive.destination(output: fields["--out-project"], inPlace: inPlace)
        var updated = project
        var changed = false
        if let destination {
            let audio = try fields["--audio-mode"].map { raw in
                guard let mode = ParticipantAudioMode(rawValue: raw) else {
                    throw CLIError("invalid_arguments", "Choose program, silence, lanes, iso or follow for --audio-mode.")
                }
                return ParticipantRenderAudio(mode: mode, ids: ids)
            }
            let privacy = try fields["--unresolved-privacy"].map { raw in
                guard let policy = ParticipantUnresolvedPrivacy(rawValue: raw) else {
                    throw CLIError("invalid_arguments", "Choose stop or cover for --unresolved-privacy.")
                }
                return policy
            }
            updated = try project.settingProjectOutput(width: number("--width"), height: number("--height"),
                                                        frameRate: fields["--frame-rate"].map { try RationalTime(parsing: $0) },
                                                        background: number("--background"), audio: audio, privacy: privacy,
                                                        defaultCanvas: defaultCanvas)
            changed = updated != project
            if changed || !destination.inPlace {
                updated = try archive.save(updated, undo: changed ? archive.undo + [.init(action: "Change Export Settings", project: project)] : archive.undo,
                                     redo: changed ? [] : archive.redo, snapshot: archive.media.mediaSnapshot,
                                     destination: destination, interruption: interruption, beforePublish: {})
            } else {
                try archive.media.diskRevision?.checkCurrent(at: source)
            }
        }
        struct Response: Encodable {
            let ok = true
            let projectPath: String
            let outProject: String?
            let changed: Bool
            let output: ProjectOutputSettingsSnapshot
        }
        try writeJSON(Response(projectPath: source.path, outProject: destination?.url.path, changed: changed,
                               output: .init(project: updated, defaultCanvas: defaultCanvas)),
                      pretty: !json, checkCancellation: destination == nil)
    }

    private func number<T: FixedWidthInteger>(_ key: String) throws -> T? {
        guard let raw = fields[key] else { return nil }
        if let value = T(raw) { return value }
        if key == "--background", raw.hasPrefix("0x"), let value = T(raw.dropFirst(2), radix: 16) { return value }
        throw CLIError("invalid_arguments", "Invalid integer for " + key + ".")
    }
}
