import Foundation
import MPCutCore

enum ProjectAnalysisEdit {
    case protect(SilenceOptions)
    case roomTone(project: String, destination: String, clock: String, span: AudioSpan)
    case sceneName(project: String, destination: String, source: String, reportID: String, view: Int, name: String?)

    var project: String? {
        switch self {
        case .protect(let options): options.project
        case .roomTone(let project, _, _, _), .sceneName(let project, _, _, _, _, _): project
        }
    }

    init(path: String, arguments: [String]) throws {
        func invalid(_ message: String) -> CLIError { CLIError("invalid_arguments", message) }
        if path == "silence pause protect" {
            let options = try SilenceOptions(arguments)
            guard options.project != nil, options.outProject != nil, !options.protectedPauses.isEmpty,
                  options.output == nil, options.pausesFile == nil,
                  options.retainedPauseSeconds.isEmpty, options.takeBoundaries.isEmpty else {
                throw invalid("Supply --project FILE --out-project NEW.cut --protect-pause ID with the settings used to scan.")
            }
            self = .protect(options)
            return
        }
        let roomTone = path == "silence room-tone calibrate"
        let fields = roomTone ? ["--clock", "--from", "--to"] : ["--source", "--report-id", "--view", "--name"]
        var values: [String: String] = [:]
        var rest = arguments.filter { $0 != "--json" }.makeIterator()
        while let flag = rest.next() {
            if !roomTone, flag.hasPrefix("--name="), values["--name"] == nil {
                values["--name"] = String(flag.dropFirst("--name=".count))
                continue
            }
            guard (fields + ["--project", "--out-project"]).contains(flag),
                  values[flag] == nil, let value = rest.next() else {
                throw invalid("Unknown, duplicate or incomplete option \(flag).")
            }
            values[flag] = value
        }
        guard let project = values["--project"], let destination = values["--out-project"] else {
            throw invalid("Supply --project FILE --out-project NEW.cut.")
        }
        if roomTone {
            guard let from = values["--from"], let to = values["--to"],
                  let clock = values["--clock"], ["group", "assembly"].contains(clock) else {
                throw invalid("Supply --clock group|assembly --from TIME --to TIME.")
            }
            let span = try AudioSpan(from: RationalTime(parsing: from), to: RationalTime(parsing: to))
            guard span.to > span.from else { throw invalid("The room-tone end must follow its start.") }
            self = .roomTone(project: project, destination: destination, clock: clock, span: span)
        } else {
            guard let source = values["--source"], !source.isEmpty, let reportID = values["--report-id"],
                  reportID.utf8.count == 64, let rawView = values["--view"],
                  let view = Int(rawView), view > 0, let rawName = values["--name"], rawName.utf8.count <= 1024 else {
                throw invalid("Supply --source MEDIA --report-id ID --view ID --name NAME. An empty name restores the default.")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .sceneName(project: project, destination: destination, source: source, reportID: reportID, view: view,
                              name: name.isEmpty ? nil : name)
        }
    }
}

struct RoomToneCalibration {
    let annotations: ProjectAnalysisAnnotations
    let thresholds: [ProjectSilenceReport.Threshold]
    let media: [String: MediaInfo]

    init(_ project: MulticamProject, at location: URL, clock: String, span: AudioSpan,
         cancelled: @escaping @Sendable () -> Bool) throws {
        let mapping: MulticamPlan
        if clock == "group" {
            guard span.from >= project.range.from, span.to <= project.range.to else {
                throw CLIError("invalid_range", "Choose a room-tone range within the multicam group.")
            }
            mapping = try project.plan(ranges: [MulticamSilencePlanner.range(span)])
        } else {
            mapping = try project.plan()
            guard span.from >= .zero, span.to <= mapping.duration else {
                throw CLIError("invalid_range", "Choose a room-tone range within the assembly.")
            }
        }
        let portions: [(occurrence: Int, group: AudioSpan)] = try mapping.intervals.compactMap { interval in
            if clock == "group" {
                return (interval.assemblyIndex, MulticamSilencePlanner.span(interval.group))
            }
            guard let overlap = MulticamSilencePlanner.intersection(span, MulticamSilencePlanner.span(interval.output)) else { return nil }
            let offset = try interval.group.from.subtracting(interval.output.from)
            return (interval.assemblyIndex, try AudioSpan(from: overlap.from.adding(offset), to: overlap.to.adding(offset)))
        }
        if clock == "assembly" {
            let duration = try portions.reduce(RationalTime.zero) { duration, portion in
                try duration.adding(portion.group.to.subtracting(portion.group.from))
            }
            guard duration == (try span.to.subtracting(span.from)) else {
                throw CLIError("invalid_range", "The room-tone range crosses a still card.")
            }
        }
        let inputs = try MulticamAnalysisInputs(project, at: location, mapping: mapping, cancelled: cancelled)
        struct Track: Hashable { let file: URL; let stream: Int }
        var tracksBySelection: [MulticamAudioSelection: Track] = [:]
        var peakByTrack: [Track: Float] = [:]
        var waves: [Track: AudioWaveform] = [:]
        for (occurrence, group) in portions {
            for route in inputs.routing[occurrence]?.routes ?? [] {
                guard MulticamSilencePlanner.intersection(group, MulticamSilencePlanner.span(route.group)) != nil,
                      let file = inputs.files[route.selection.source], let original = inputs.indexed[file]?.ordinary else { continue }
                let stream = route.selection.stream
                let track = Track(file: file, stream: stream)
                let wave: AudioWaveform
                if let cached = waves[track] {
                    wave = cached
                } else {
                    let audio = try original.extendingToAudioEnd(stream: stream)
                    wave = try AudioAnalysis.scan(audio, stream: stream, useSidecar: AnalysisSidecar.readsEnabled, cancelled: cancelled)
                    waves[track] = wave
                }
                guard let peak = route.roomTonePeak(in: group, waveform: wave) else {
                    throw CutError(code: "no_audio", message: "Could not measure the routed audio inside the room-tone range.")
                }
                tracksBySelection[route.selection] = track
                peakByTrack[track] = max(peak, peakByTrack[track] ?? 0)
            }
        }
        guard !peakByTrack.isEmpty else {
            throw CutError(code: "no_audio", message: "The room-tone range contains no routed audio.")
        }

        var updated = project.analysisAnnotations.mappingPaths { CutProject.mediaURL($0, relativeTo: location).path }
        updated.multicamThresholdDB = nil
        let levels = peakByTrack.mapValues(AudioAnalysis.roomToneThresholdDB(forPeak:))
        for (track, level) in levels.sorted(by: { ($0.key.file.path, $0.key.stream) < ($1.key.file.path, $1.key.stream) }) {
            guard let info = inputs.indexed[track.file]?.ordinary,
                  updated.setThreshold(level, for: info, stream: track.stream) else {
                throw CutError(code: "analysis_unavailable", message: "Could not verify the measured recording.")
            }
        }
        thresholds = tracksBySelection.keys.sorted { ($0.source, $0.stream) < ($1.source, $1.stream) }.compactMap { selection in
            guard let track = tracksBySelection[selection], let level = levels[track] else { return nil }
            return .init(source: selection.source, file: track.file.path, stream: track.stream, thresholdDB: level)
        }
        annotations = updated.mappingPaths { CutProject.relativeMediaPath($0, to: location) }
        media = inputs.media
    }
}
