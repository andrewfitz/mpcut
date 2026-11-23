import Foundation
import MPCutCore

// Exercise the same archive loader as ProjectSessions without opening a window.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let clock = ContinuousClock()
let start = clock.now
let loaded = try CutProject.loadEditorDocument(from: url, limit: 50)
let duration = start.duration(to: clock.now).components
let sources = loaded.media.absoluteSources(relativeTo: url).keys
    .filter { URL(fileURLWithPath: $0).pathExtension == "mov" }
    .map { URL(fileURLWithPath: $0).lastPathComponent }
    .sorted()
let receipt: [String: Any] = [
    "archiveSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
    "attachmentCount": loaded.project.transcripts.attachments.count,
    "authoringCount": loaded.project.transcripts.authoring.count,
    "undoActions": loaded.undo.map(\.action),
    "undoAuthoringCounts": loaded.undo.map { $0.project.transcripts.authoring.count },
    "redoActions": loaded.redo.map(\.action),
    "mediaFiles": sources
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: receipt))
