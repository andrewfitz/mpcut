import Darwin
import Foundation
import MPCutCore

/// Accept only the fields for the selected edit. Source times are exact CLI time strings.
private struct EditFields {
    let values: [String: Any]

    func check(_ keys: String...) throws {
        if let key = Set(values.keys).subtracting(keys).sorted().first {
            throw CLIError("invalid_arguments", "Unexpected project edit field " + key)
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String, !value.isEmpty else {
            throw CLIError("invalid_arguments", "Supply a nonempty string for " + key)
        }
        return value
    }

    func time(_ key: String) throws -> RationalTime { try RationalTime(parsing: string(key)) }

    func decode<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard let value = values[key], JSONSerialization.isValidJSONObject(value) else {
            throw CLIError("invalid_arguments", "Supply " + key)
        }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    func stream(_ key: String) throws -> Int {
        try index(key, count: Int.max)
    }

    func index(_ key: String, count: Int) throws -> Int {
        guard let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let index = Int(number.stringValue), (0..<count).contains(index) else {
            throw CLIError("invalid_arguments", "Supply a zero-based item index for " + key)
        }
        return index
    }
}

struct ProjectMutationReceipt: Encodable {
    let ok = true
    let projectPath: String
    let operationCount: Int
}

private func requireNewProject(_ destination: URL) throws {
    var entry = stat()
    guard lstat(destination.path, &entry) != 0 else {
        throw CutError(code: "output_exists", message: "Choose a new project destination.")
    }
}

/// Rebase timeline history and copy its shared transcript attachments once.
func saveEditedProject(_ candidate: CutProject, source: URL, destination: URL, action: String,
                       original: CutProject?, undo: [CutHistoryState], redo: [CutHistoryState],
                       mediaSnapshot: ProjectMediaSnapshot,
                       interruption: Interruption, validateSources: () throws -> Void = {}) throws {
    var paths: [String: String] = [:]
    func rebase(_ project: CutProject) throws -> CutProject {
        try interruption.check()
        return try project.rebased(from: source, to: destination, paths: &paths)
    }
    func copyState(_ state: CutHistoryState) throws -> CutHistoryState {
        try interruption.check()
        return try state.rebased(from: source, to: destination, paths: &paths)
    }
    try requireNewProject(destination)
    let project = try rebase(candidate)
    var old = undo
    var next = redo
    if let original, original != candidate {
        old.append(.init(action: action, project: original))
        next = []
    }
    do {
        try project.saveNewCopy(to: destination, copyingTranscriptsFrom: source,
                                undo: old.map(copyState), redo: next.map(copyState),
                                mediaSnapshot: mediaSnapshot.rebased(from: source, to: destination),
                                beforePublish: validateSources, check: interruption.check)
    } catch let error as CutError where error.code == "destination_exists" {
        throw CutError(code: "output_exists", message: "Choose a new project destination.")
    }
}

func authorProject(data: Data, creating: Bool, interruption: Interruption) throws -> ProjectMutationReceipt {
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil,
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw CLIError("invalid_json", "Supply one UTF-8 project edit object with unique keys.")
    }
    if let issue = jsonInputIssue(data, integerNumbersOnly: true) {
        throw CLIError("invalid_json", "The request " + issue + ".")
    }
    let fields = EditFields(values: object)
    let destination = try fileURL(fields.string("out_project"), label: "Output project")
    guard destination.pathExtension.lowercased() == "cut" else { throw CLIError("invalid_arguments", "Choose a .cut destination.") }
    guard let operations = object["operations"] as? [[String: Any]] else {
        throw CLIError("invalid_arguments", "Supply an operations array in execution order.")
    }
    try requireNewProject(destination)
    let location: URL
    var original: CutProject?
    var undo: [CutHistoryState] = [], redo: [CutHistoryState] = []
    var project: CutProject
    var mediaSnapshot = ProjectMediaSnapshot.empty
    // Authoring publishes only the project. Avoid analysis writes beside referenced media.
    let engine = CutEngine(cancelled: { !interruption.isActive }, useSidecar: false)
    var summaries: [URL: MediaInfo] = [:]
    var inspected: [URL: MediaInfo] = [:]
    var snapshots: [URL: SourceIdentity] = [:]
    func remember(_ media: MediaInfo, at url: URL) throws -> MediaInfo {
        if let first = snapshots[url], !first.matchesSnapshot(media.identity) {
            throw CutError(code: "source_changed", message: "The source changed during project authoring: " + url.path)
        }
        snapshots[url] = media.identity
        inspected[url] = media
        return media
    }
    func inspect(_ url: URL) throws -> MediaInfo {
        if let media = summaries[url] { return media }
        let media = try remember(engine.inspectSummary(url), at: url)
        summaries[url] = media
        return media
    }
    func inspectMulticam(_ url: URL) throws -> MediaInfo {
        try remember(engine.inspectMulticamSource(url), at: url)
    }
    if creating {
        location = destination
        switch try fields.string("kind") {
        case "sequence":
            try fields.check("kind", "out_project", "operations")
            project = .sequence([])
        case "multicam":
            try fields.check("kind", "out_project", "operations", "angles", "group_end")
            guard let rows = object["angles"] as? [[String: Any]], !rows.isEmpty else {
                throw CLIError("invalid_arguments", "Supply at least one camera in angles.")
            }
            let cameras = try rows.map { row -> MulticamSource in
                let camera = EditFields(values: row)
                try camera.check("id", "file", "offset", "audio_stream_index")
                let file = try fileURL(camera.string("file"), label: "Camera")
                let info = try inspect(file)
                guard info.hasVideo else { throw CLIError("no_video", "Camera requires video.") }
                let stream = try row["audio_stream_index"].map { _ in try camera.stream("audio_stream_index") }
                if let stream, !info.streams.contains(where: { $0.index == stream && $0.kind == "audio" }) {
                    throw CLIError("invalid_target", "Choose an available absolute camera audio stream index.")
                }
                return try .init(id: camera.string("id"), file: file.path,
                                 offset: row["offset"] == nil ? .zero : camera.time("offset"),
                                 audioStream: stream)
            }
            project = try .multicam(.init(referenceAngle: cameras[0].id, range: .init(from: .zero, to: fields.time("group_end")),
                                          angles: cameras, audio: .follow, switches: [.init(at: .zero, angle: cameras[0].id)]))
        default: throw CLIError("invalid_arguments", "Choose sequence or multicam.")
        }
    } else {
        try fields.check("project_path", "out_project", "operations")
        location = try fileURL(fields.string("project_path"), label: "Project")
        let loaded = try CutProject.loadEditorDocument(from: location, limit: CutProject.maximumHistorySteps)
        try loaded.media.validateDestination(destination, relativeTo: location)
        original = loaded.project
        project = loaded.project
        undo = loaded.undo
        redo = loaded.redo
        mediaSnapshot = loaded.media.mediaSnapshot
    }
    try project.validate()
    var index = operations.startIndex
    while index < operations.endIndex {
        try interruption.check()
        let edit = EditFields(values: operations[index])
        let action = try edit.string("action")
        if case .multicam(var multicam) = project {
            try editMulticam(&multicam, action: action, edit: edit, inspect: inspectMulticam, location: location)
            project = .multicam(multicam)
        } else if action == "append" {
            // Validate consecutive appends in one timeline pass.
            project = try project.editingStills(sequence: { sequence in
                var ids = Set(sequence.items.compactMap { $0.source?.id })
                while index < operations.endIndex, operations[index]["action"] as? String == "append" {
                    try interruption.check()
                    let clip = try appendClip(EditFields(values: operations[index]), inspect: inspect)
                    guard ids.insert(clip.id).inserted else {
                        throw CutError(code: "invalid_cut_project", message: "Clip IDs must be nonempty and unique")
                    }
                    sequence.items.append(.source(clip))
                    index += 1
                }
            }, multicam: { _ in })
            continue
        } else {
            project = try editSequence(project, action: action, edit: edit, inspect: inspect, location: location)
        }
        index += 1
    }
    let editedPaths = Set(([project] + [original].compactMap { $0 }).flatMap { $0.mediaPaths.map(\.1) })
    let newEntries = editedPaths.compactMap { path in
        inspected[CutProject.mediaURL(path, relativeTo: location)].map { (path: path, media: $0) }
    }
    try saveEditedProject(project, source: location, destination: destination, action: "Edit Timeline", original: original,
                          undo: undo, redo: redo, mediaSnapshot: mediaSnapshot.merging(media: newEntries),
                          interruption: interruption) {
        for (url, snapshot) in snapshots {
            try interruption.check()
            guard snapshot.isCurrentSnapshot(at: url) else {
                throw CutError(code: "source_changed", message: "The source changed during project authoring: " + url.path)
            }
        }
    }
    return .init(projectPath: destination.path, operationCount: operations.count)
}

private func appendClip(_ edit: EditFields, inspect: (URL) throws -> MediaInfo) throws -> CutSequenceClip {
    try edit.check("action", "id", "file", "from", "to")
    let file = try fileURL(edit.string("file"), label: "Clip")
    let media = try inspect(file)
    let from = try edit.values["from"] == nil ? .zero : edit.time("from")
    let to = try edit.values["to"] == nil ? media.duration : edit.time("to")
    guard to <= media.duration else { throw CLIError("invalid_range", "Clip extends beyond the source.") }
    let clip = try CutSequenceClip(id: edit.string("id"), file: file.path, from: from, to: to)
    try CutProject.sequence([clip]).validate()
    return clip
}

private func editSequence(_ project: CutProject, action: String, edit: EditFields,
                          inspect: (URL) throws -> MediaInfo, location: URL) throws -> CutProject {
    switch action {
    case "source_select_save":
        try edit.check("action", "id", "name", "file", "from", "to")
        let file = try fileURL(edit.string("file"), label: "Source select")
        let range = try SequenceSourceRange(file: file.path, from: edit.time("from"), to: edit.time("to"))
        _ = try range.resolve(relativeTo: location, inspect: inspect)
        return try project.settingSourceSelect(.init(id: edit.string("id"), name: edit.string("name"), range: range))
    case "source_select_remove":
        try edit.check("action", "id")
        return try project.removingSourceSelect(id: edit.string("id"))
    case "source_ranges_apply":
        try edit.check("action", "from", "to", "ranges")
        guard let rows = edit.values["ranges"] as? [[String: Any]] else {
            throw CLIError("invalid_arguments", "Supply source ranges in insertion order.")
        }
        let ranges = try rows.map { row in
            try SequenceSourceRange.request(row, selects: project.sourceSelects) {
                try fileURL($0, label: "Source range").path
            }
        }
        return try project.applyingSourceRanges(ranges, from: edit.time("from"), to: edit.time("to"),
                                               relativeTo: location, inspect: inspect)
    case "move":
        try edit.check("action", "id", "index")
        let id = try edit.string("id")
        return try project.editingStills(sequence: { sequence in
            guard let from = sequence.items.firstIndex(where: { $0.source?.id == id }) else {
                throw CLIError("invalid_target", "Unknown clip " + id)
            }
            let index = try edit.index("index", count: sequence.items.count)
            let item = sequence.items.remove(at: from)
            sequence.items.insert(item, at: index)
        }, multicam: { _ in })
    case "trim":
        try edit.check("action", "id", "from", "to")
        let id = try edit.string("id"), to = try edit.time("to")
        guard let clip = project.sequenceClips?.first(where: { $0.id == id }),
              try inspect(CutProject.checkedMediaURL(clip.file, relativeTo: location)).duration >= to else {
            throw CLIError("invalid_range", "Choose a known clip and an end within its source.")
        }
        return try project.trimmingSequenceClip(id: id, from: edit.time("from"), to: to)
    case "split":
        try edit.check("action", "id", "at", "new_id")
        return try project.splittingSequenceClip(id: edit.string("id"), at: edit.time("at"), newID: edit.string("new_id"))
    case "remove":
        try edit.check("action", "id")
        return try project.removingSequenceClip(id: edit.string("id"))
    default: throw CLIError("invalid_arguments", "Unknown sequence action " + action)
    }
}

private func editMulticam(_ project: inout MulticamProject, action: String, edit: EditFields,
                          inspect: (URL) throws -> MediaInfo, location: URL) throws {
    func requireAudioStream(_ selection: MulticamAudioSelection) throws {
        guard let source = project.sources.first(where: { $0.id == selection.source }),
              try inspect(CutProject.checkedMediaURL(source.file, relativeTo: location))
                  .audio.contains(where: { $0.stream.index == selection.stream }) else {
            throw CLIError("invalid_target", "Choose an available recording and absolute audio stream index.")
        }
    }

    switch action {
    case "audio_set":
        let mode = try edit.string("mode")
        if mode == "replace" {
            try edit.check("action", "mode", "path", "replacement_source_id", "replacement_stream_index",
                           "reference_source_id", "relative_offset")
            let path = try fileURL(edit.string("path"), label: "Program replacement")
            let id = try edit.string("replacement_source_id")
            let stream = try edit.stream("replacement_stream_index")
            guard !project.sources.contains(where: { $0.id == id }),
                  let track = try inspect(path).audio.first(where: { $0.stream.index == stream }) else {
                throw CLIError("invalid_target", "Choose a new source ID and an available program replacement stream.")
            }
            let offset = try MulticamSync.confirmedProgramOffset(project: project,
                referenceSourceID: edit.string("reference_source_id"), track: track, relativeOffset: edit.time("relative_offset"))
            project.audioSources.append(.init(id: id, file: path.path, offset: offset, audioStream: stream))
            project.audio = .fixed(.init(source: id, stream: stream))
            for index in project.switches.indices { project.switches[index].audio = nil }
            return try project.validate()
        }
        try edit.check("action", "mode", "source_id", "audio_stream_index")
        if mode != "fixed", edit.values["source_id"] != nil || edit.values["audio_stream_index"] != nil {
            throw CLIError("invalid_arguments", "Source and stream select Fixed audio.")
        }
        switch mode {
        case "fixed":
            let selection: MulticamAudioSelection
            if edit.values["source_id"] != nil || edit.values["audio_stream_index"] != nil {
                selection = try .init(source: edit.string("source_id"), stream: edit.stream("audio_stream_index"))
            } else if let saved = project.fixedAudio {
                selection = saved
            } else {
                throw CLIError("invalid_arguments", "Supply a Fixed source and stream.")
            }
            try requireAudioStream(selection)
            project.audio = .fixed(selection)
        case "mix":
            if project.mixLanes.isEmpty { project.mixLanes = project.defaultMixLanes }
            project.audio = .mix
        case "follow": project.audio = .follow
        case "none": project.audio = .none
        default: throw CLIError("invalid_arguments", "Choose fixed, follow, none, mix or replace.")
        }
        return try project.validate()
    case "mix_lanes_set":
        try edit.check("action", "lanes")
        let lanes = try edit.decode("lanes", as: [MulticamAudioLane].self)
        for lane in lanes {
            if case .recording(let selection) = lane.target { try requireAudioStream(selection) }
        }
        project.mixLanes = lanes
        return try project.validate()
    case "audio_replacement_set":
        try edit.check("action", "id", "original", "replacement", "path", "replacement_stream_index",
                       "replacement_source_id", "relative_offset", "uncovered")
        let original = try edit.decode("original", as: MulticamAudioSelection.self)
        try requireAudioStream(original)
        let replacement: MulticamAudioSelection
        if edit.values["replacement"] != nil {
            guard edit.values["path"] == nil, edit.values["replacement_stream_index"] == nil,
                  edit.values["replacement_source_id"] == nil else {
                throw CLIError("invalid_arguments", "Choose an existing replacement selection or import a path and stream.")
            }
            replacement = try edit.decode("replacement", as: MulticamAudioSelection.self)
            try requireAudioStream(replacement)
        } else {
            let path = try fileURL(edit.string("path"), label: "Replacement")
            let sourceID = try edit.string("replacement_source_id")
            let stream = try edit.stream("replacement_stream_index")
            guard !project.sources.contains(where: { $0.id == sourceID }),
                  try inspect(path).audio.contains(where: { $0.stream.index == stream }) else {
                throw CLIError("invalid_target", "Choose a new replacement source ID and an available absolute audio stream index.")
            }
            project.audioSources.append(.init(id: sourceID, file: path.path, audioStream: stream))
            replacement = .init(source: sourceID, stream: stream)
        }
        let id = try edit.string("id")
        let relativeOffset = try edit.time("relative_offset")
        let binding: MulticamAudioReplacement
        switch try edit.string("uncovered") {
        case "keep_original":
            binding = .init(id: id, original: original, replacement: replacement,
                            relativeOffset: relativeOffset, uncovered: .keepOriginal)
        case "leave_uncovered":
            binding = .init(id: id, original: original, replacement: replacement,
                            relativeOffset: relativeOffset, uncovered: .leaveUncovered)
        default: throw CLIError("invalid_arguments", "Choose keep_original or leave_uncovered.")
        }
        if let index = project.audioReplacements.firstIndex(where: { $0.id == id }) {
            project.audioReplacements[index] = binding
        } else {
            project.audioReplacements.append(binding)
        }
        return try project.validate()
    case "audio_replacement_remove":
        try edit.check("action", "id")
        let id = try edit.string("id")
        guard let index = project.audioReplacements.firstIndex(where: { $0.id == id }) else {
            throw CLIError("invalid_target", "Unknown replacement binding.")
        }
        project.audioReplacements.remove(at: index)
        return try project.validate()
    default: break
    }
    if action == "add_recording" {
        try edit.check("action", "angle_id", "path", "group_start")
        let angle = try edit.string("angle_id")
        guard let primary = project.angles.first(where: { $0.id == angle }) else {
            throw CLIError("invalid_target", "Choose a known camera angle.")
        }
        let path = try fileURL(edit.string("path"), label: "Camera recording")
        let first = try primary.coverage == nil
            ? inspect(CutProject.checkedMediaURL(primary.file, relativeTo: location)) : nil
        try project.addRecording(id: ProjectIdentifier.make(avoiding: project.sources.map(\.id)), media: inspect(path), to: angle,
                                 at: edit.time("group_start"), primaryMedia: first)
        return
    }
    if action == "switch_set" || action == "switch_remove" {
        let at = try edit.time("at")
        if action == "switch_set" {
            try edit.check("action", "at", "angle_id")
            let angle = try edit.string("angle_id")
            let index = project.switches.lowerBound { $0.at >= at }
            if index < project.switches.count, project.switches[index].at == at {
                project.switches[index].angle = angle
            } else {
                project.switches.insert(.init(at: at, angle: angle), at: index)
            }
        } else {
            try edit.check("action", "at")
            guard let index = project.switches.firstIndex(where: { $0.at == at }), index > 0 else {
                throw CLIError("invalid_target", "Choose an existing switch after the opening switch.")
            }
            project.switches.remove(at: index)
        }
        try project.validate()
        return
    }
    var items = project.assemblyItems ?? [.group(project.range)]
    switch action {
    case "append", "trim":
        if action == "append" { try edit.check("action", "from", "to") }
        else { try edit.check("action", "index", "from", "to") }
        let range = try MulticamRange(from: edit.time("from"), to: edit.time("to"))
        if action == "append" { items.append(.group(range)) }
        else {
            let index = try edit.index("index", count: items.count)
            guard items[index].group != nil else { throw CLIError("invalid_target", "Choose a group occurrence.") }
            items[index] = .group(range, angle: items[index].angleOverride)
        }
    case "remove":
        try edit.check("action", "index")
        let index = try edit.index("index", count: items.count)
        if let still = items[index].still, items.count > 1 {
            let updated = try CutProject.multicam(project).removingStill(id: still.id)
            if case .multicam(let multicam) = updated { project = multicam }
            return
        }
        items.remove(at: index)
    case "move":
        try edit.check("action", "index", "to_index")
        let destination = try edit.index("to_index", count: items.count)
        let item = items.remove(at: try edit.index("index", count: items.count))
        items.insert(item, at: destination)
    case "split":
        try edit.check("action", "index", "at")
        let index = try edit.index("index", count: items.count), at = try edit.time("at")
        guard let range = items[index].group, range.from < at, at < range.to else {
            throw CLIError("invalid_range", "Split inside the selected group occurrence.")
        }
        let angle = items[index].angleOverride
        items.replaceSubrange(index...index, with: [
            .group(.init(from: range.from, to: at), angle: angle),
            .group(.init(from: at, to: range.to), angle: angle)
        ])
    case "angle_set", "angle_clear":
        if action == "angle_set" { try edit.check("action", "index", "angle_id") }
        else { try edit.check("action", "index") }
        let index = try edit.index("index", count: items.count)
        guard let range = items[index].group else { throw CLIError("invalid_target", "Choose a group occurrence.") }
        let angle = action == "angle_set" ? try edit.string("angle_id") : nil
        guard angle != items[index].angleOverride else { return }
        items[index] = .group(range, angle: angle)
    default: throw CLIError("invalid_arguments", "Unknown multicam action " + action)
    }
    guard !items.isEmpty else { throw CLIError("empty_edit", "Retain at least one assembly item.") }
    if items != (project.assemblyItems ?? [.group(project.range)]) {
        project.assemblyItems = items
        try project.validate()
    }
}

func multicamSwitchCoverage(data: Data, useSidecar: Bool, interruption: Interruption) throws -> MulticamSwitchCoverage {
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil,
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw CLIError("invalid_arguments", "Supply a UTF-8 JSON object.")
    }
    if let issue = jsonInputIssue(data) { throw CLIError("invalid_arguments", "The request " + issue + ".") }
    let fields = EditFields(values: object)
    try fields.check("project_path", "group_time", "angle_id")
    let location = try fileURL(fields.string("project_path"), label: "Project")
    let document = try CutProjectMedia.load(from: location, multicam: true)
    guard case .multicam(let project) = document.project else {
        throw CLIError("expected_multicam", "Choose a saved multicam project.")
    }
    let time = try fields.time("group_time")
    let angle = try fields.string("angle_id")
    let plan = try project.proposedSwitch(at: time, angle: angle).plan
    let needed = Set(plan.picture.map(\.source)).union(project.requiredAudioSelections(for: plan).map(\.source))
    let engine = CutEngine(cancelled: { !interruption.isActive }, useSidecar: useSidecar)
    var media: [String: MediaInfo] = [:]
    var inspected: [URL: MediaInfo] = [:]
    var unavailable = Set<URL>()
    try SidecarLocations.$projectURL.withValue(location) {
        let protected = AnalysisSidecar.excludedSources.union(document.sidecarExclusions(relativeTo: location))
        try AnalysisSidecar.$excludedSources.withValue(protected) {
            try AnalysisSidecar.$automaticWritesEnabled.withValue(false) {
                for source in project.sources where needed.contains(source.id) {
                    try interruption.check()
                    guard let url = try? CutProject.checkedMediaURL(source.file, relativeTo: location) else { continue }
                    if let info = inspected[url] {
                        media[source.id] = info
                    } else if !unavailable.contains(url) {
                        if let info = try? engine.inspectMulticamSource(url) {
                            inspected[url] = info
                            media[source.id] = info
                        } else {
                            unavailable.insert(url)
                        }
                    }
                }
            }
        }
    }
    try interruption.check()
    return try project.switchCoverage(at: time, angle: angle, media: media)
}
