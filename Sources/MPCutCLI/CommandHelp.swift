import Foundation
import MPCutCore

/// Both help formats use the same command reference. It travels inside the executable.
struct CommandHelp: Encodable {
    let name: String
    let purpose: String
    let usage: [String]
    let instructions: [String]
    let result: String
    let examples: [String]
    var stdinExample: EditExample? = nil
    var projectTemplate: MulticamProject? = nil

    struct EditExample: Encodable {
        var file = "interview.mov"
        var output: String?
        var outputDirectory: String?
        var clips: [[String: String]]?
        var ranges: [[String: String]]?
        var mode: String?
        var snap: String?
    }

    var text: String {
        var sections = [name + " — " + purpose] + usage.map { "  " + $0 } + [""] + instructions
            + [result, "\nExamples"] + examples.map { "  " + $0 }
        if let projectTemplate {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(projectTemplate) {
                sections += ["\nProject template", String(decoding: data, as: UTF8.self)]
            }
        }
        return sections.joined(separator: "\n")
    }

    static let conventions = [
        "Use mpcut help COMMAND --json to retrieve one command. mpcut COMMAND --help prints its text reference. mpcut help manual prints the complete guide. mpcut --version --json identifies the installed build.",
        "With --stdin, send one UTF-8 JSON object and close stdin. With --json, read one JSON object from stdout and drain stderr separately for progress and diagnostics. Exit 0 means success, 1 an operation failure, 2 a CLI/request error, and 130 cancellation. On failure read error.code and error.message, plus error.segment, error.boundary, error.track or error.nearest when present. A batch that fails during writing can also report completed outputs and failedRange.",
        "Use local paths. Relative input and output paths resolve from the process working directory, including paths inside stdin JSON. Quote spaces in a shell. Pass separate argv entries from code. Use ./ for a filename beginning with a dash. A parent output directory must already exist. Media exports require a new filename.",
        "Times are relative to each source or to the group clock for project clips. Ranges include from and exclude to. Command-line times accept decimal seconds, MM:SS, HH:MM:SS and fractions such as 1001/30000. In edit JSON use strings or exact objects such as {\"numerator\":1001,\"denominator\":30000}. Keep the rational times from inspection through export.",
        "Stream indices are absolute, zero-based media.streams[].index values. Order entries, scene numbers, failedRange and error.segment are one-based. error.segment is the clip's number in the request's clips array, whatever the playback order. For a saved multicam project it is the number of the assembly range, and a project without an assembly has the single range 1. --stream chooses the audio to analyze. --tracks audio --audio-stream INDEX chooses the audio to write.",
        "To render a saved multicam project in one command, run \(projectExportExample). Add --dry-run only if you want to review the plan before writing.",
        "To build an edit from source recordings, use inspect to identify streams and boundaries, then use scenes, silence, waveform or frames to review the material. For single-source image review, use the frames manifest’s clipFrom and clipTo. Assemble the chosen ranges in playback order.",
        "Export, rearrange, bulk, scenes --export-to and silence --output support --dry-run. A dry run checks the actual sources and destination and leaves the output unwritten. Analysis commands save and reuse completed work in FILE.cutdb. Add --no-sidecar to bypass automatic reads and writes.",
        "For unsafe_boundary, inspect error.nearest when present. Submit an acceptable boundary, explicitly allow --snap nearest on an eligible command, or preflight Smart Trim for supported video. For a sound-only edit whose joins cannot be copied, preflight --mode encode, which keeps the source format where it can. In a multicam error, nearest replaces the switch at error.multicam.at, or the from or to edge named by error.multicam.edge. Never move a switch to a time offered for an edge. For unsupported_container, inspect the selected tracks and try a compatible extension. For output_exists use a fresh destination. After source_changed, rescan the recording before replaying a report."
    ]

    // Every mode, track, codec, preset, audio action and container listing below comes from ExportRules.
    private static let tracks = ExportRules.tracksUsage + " [--audio-stream INDEX]"
    private static func mode(_ entry: ExportEntryPoint) -> String { ExportRules.modeUsage(entry) }
    private static func settings(_ entry: ExportEntryPoint) -> String {
        "\(mode(entry)) \(ExportRules.snapUsage) \(ExportRules.encodeUsage)"
    }
    private static let encoding = ExportRules.encodeSettingsHelp + " " + ExportRules.helpSummary + " A sound-only conversion refuses video and quality settings, selects one audio track, places cuts on its sample clock and reports codec, bitRate or quality, and bitDepth in audioActions."
    private static let projectUsage = "\(mode(.cliProject)) \(ExportRules.tracksUsage) \(ExportRules.encodeUsage)"
    private static let selection = "The default selection is all. Explicit audio or video selection uses stream copy, except that export and bulk convert an audio selection with --mode encode. --audio-stream requires --tracks audio. Export, rearrange and bulk also accept --audio-only and --video-only. WAV suits compatible PCM and M4A suits AAC. Edited FLAC uses MKA. Copy cuts depend on codec, container, and decoder history."
    private static let exportResult = "Read output, container, mode and duration. For video, copiedDuration and encodedDuration split the selected time into copied and encoded pictures. An audio-only copy reports its retained duration in copiedDuration, and an audio conversion in encodedDuration. A sound-only encode request that could copy exactly reports mode copy. For an ordinary edit, read segments in playback order. Each segment includes source from/to, outputStart, tracks and trackActions. Smart edges include encodedEdges. Conversion reports include audioActions and warnings where applicable."
    private static let projectExportExample = "mpcut export --project edit.cut --output finished.mov --json"
    private static let projectSilenceExample = "mpcut silence --project edit.cut --min-pause 1.5 --leave 0.4 --json"
    private static let projectExportResult = "Multicam export and its optional dry run report the playback intervals in plan, resolved source paths in sources, track actions and encoded edges in picture and audio, and the video durations in copiedVideoDuration and encodedVideoDuration."
    private static let multicamTemplate = MulticamProject(
        referenceAngle: "wide", range: MulticamRange(from: .zero, to: RationalTime(numerator: 4)),
        angles: [.init(id: "wide", file: "wide.mov"), .init(id: "close", file: "close.mov")],
        audio: .fixed(.init(source: "wide", stream: 1)),
        switches: [.init(at: .zero, angle: "wide"), .init(at: RationalTime(numerator: 2), angle: "close")]
    )

    static let commands: [CommandHelp] = [
        .init(name: "help", purpose: "Discover commands and their inputs, outputs and examples.",
              usage: ["mpcut help [COMMAND|manual] [--json]", "mpcut COMMAND --help [--json]", "mpcut --help [--json]"],
              instructions: ["Global JSON includes the full command reference keyed by command name. Request one topic for a smaller response. Use help manual for the offline guide and command reference.",
                             "To render a saved multicam project, use \(projectExportExample)."],
              result: "Global fields include version, commands, conventions, usage, exportModes, exportTracks, videoCodecs, qualities, audioOptions and snapOptions.",
              examples: ["mpcut help --json", "mpcut help export --json"]),
        .init(name: "version", purpose: "Identify the installed CLI.",
              usage: ["mpcut --version [--json]"], instructions: [],
              result: "Plain output is the version string. JSON has a version field.", examples: ["mpcut --version --json"]),
        .init(name: "inspect", purpose: "Inspect a .cut project or identify media streams, frames, and audio packets.",
              usage: ["mpcut inspect [--json] \(tracks) [--keyframes | --frames | --audio-packets [--stream INDEX]] [--from TIME] [--to TIME] [--] FILE",
                      "mpcut inspect --project FILE [--json]"],
              instructions: ["For a sequence project, inspect reports ordered clips, resolved source paths by clip ID and total duration. A multicam project reports angles and group intervals. A bare media inspection returns media metadata. --frames returns every indexed picture. --keyframes returns keyframe markers and verified video start points. --audio-packets defaults to the selected output audio stream, otherwise the first audio stream. --from and --to limit a picture or packet query to a half-open window.",
                             "Use media.frames[].time for a cut and the next picture time for its exclusive end. canStart and canEnd describe the picture. A dry run checks linked tracks and the full edit. PCM indexes may summarize contiguous packets."],
              result: "Use the top-level file as an input path for subsequent commands or edit JSON. Read media.hasVideo, media.duration, media.origin, media.streams, media.frames and, when requested, media.audioPackets. Read copy.eligible, copy.reason and copy.containers before selecting a destination. preview is unchecked.",
              examples: ["mpcut inspect --json interview.mov", "mpcut inspect --json --frames --from 2 --to 3 interview.mov", "mpcut inspect --json --audio-packets --stream 1 --from 2 --to 3 interview.mov", "mpcut inspect --project interview.cut --json"]),
        .init(name: "convert", purpose: "Convert editable projects between MPCut, Resolve, Premiere Pro, and Final Cut Pro.",
              usage: ["mpcut convert INPUT [--to cut|resolve|premiere|fcp] --output NEW_PROJECT [--allow-loss [--flatten-multicam]] [--json]"],
              instructions: ["The input and output filename extensions select the adapters. --to additionally checks the desired format. MPCut documents use .cut, Resolve uses .drp or .drt, Premiere Pro uses .prproj, and Final Cut Pro uses .fcpbundle or its .fcpxml and .fcpxmld interchange formats. Native operations may require the editing application. Keep referenced media available.",
                             "Conversion reports unsupported timeline features. Use --allow-loss to authorize the approximations the adapter describes. Give the output a fresh path.",
                             "To flatten a multicam edit into selected picture and sound clips in Premiere Pro, use --allow-loss --flatten-multicam with a .prproj output. Flattening discards alternate angles."],
              result: "Read input, output and warnings[] on success. See error.code and error.message on failure.",
              examples: ["mpcut convert interview.cut --to resolve --output interview.drp",
                         "mpcut convert interview.fcpxml --output imported.cut --json",
                         "mpcut convert cutaway.cut --to premiere --output cutaway.prproj"]),
        .init(name: "resolve", purpose: "Export a saved project as an editable DaVinci Resolve timeline.",
              usage: ["mpcut resolve --project PROJECT --output FILE.fcpxml [--open] [--json]", "mpcut resolve --input REQUEST.json [--open] [--json]", "mpcut resolve --clips LIST --output FILE.fcpxml [--open] [--json]", "mpcut resolve --stdin [--open] [--json]"],
              instructions: ["Source paths resolve relative to the project. Use --project - for stdin. Use --stdin for an ordinary file edit with output, clips, order and optional replacement audio. Keep source media and any exported Audio or Sources directories available. --open imports into the current Resolve project using local scripting."],
              result: "JSON reports output and whether Resolve opened the timeline.",
              examples: ["mpcut resolve --project interview.cut --output interview.fcpxml --open"]),
        .init(name: "multicam", purpose: "Create, inspect, review and export a multicam project.",
              usage: ["mpcut help multicam [--json]",
                      "mpcut export --project PROJECT --output FILE \(projectUsage) [--dry-run] [--json]",
                      "mpcut inspect --project PROJECT [--json]",
                      "mpcut silence --project PROJECT [--output FILE [--dry-run]] [--json]",
                      "mpcut frames --project PROJECT --at GROUP_TIME --output NEW_DIRECTORY [--json]",
                      "mpcut export --stdin --json [--dry-run]"],
              instructions: [
                  "Export a saved project directly with \(projectExportExample). Add --dry-run for an optional preview of the plan.",
                  "Use \(projectSilenceExample) to find pauses in the routed program audio in assembly order. Use help silence for settings, report fields and export examples.",
                  "Copy the project template below, or extract projectTemplate from the JSON help. Save that object as edit.cut and edit the filenames, stream choices and timestamps. Project source paths resolve from the project's directory. Paths in stdin requests resolve from the working directory. --project - reads the project itself from standard input, up to 64 MB, and then resolves its relative source paths from the working directory.",
                  "Stable source IDs identify the reference angle, switches and microphones. Each offset places source time zero on the group clock. The switch at the start is required. Later switches must be strictly increasing and precede the group end. Ranges include their start and exclude their end.",
                  #"For a fixed camera microphone use "audio":{"mode":"fixed","source":"wide","stream":1}. For a separate recorder add "audioSources":[{"id":"lav","file":"lav.wav","offset":"0"}] and select "audio":{"mode":"fixed","source":"lav","stream":0}."#,
                  #"For camera microphones use "audio":{"mode":"follow"} and set each angle's audioStream to its absolute index. For a per-switch override use {"at":"2","angle":"close","audio":{"source":"wide","stream":1}}. A later switch without an override resumes the project policy."#,
                  #"For a silent project use "audio":{"mode":"none"}, which selects no default microphone. A switch override still routes its microphone, so a project in this mode must either leave every switch without an override or give an override to every switch in the exported ranges. Otherwise inspect lists missing_audio for each uncovered interval, and export and its dry run fail with the same code. For an existing project, --tracks video exports picture only."#,
                  #"Direct export uses the saved assembly or the whole range. To save a rearrangement in the project, add "assembly":[{"from":"2","to":"4"},{"from":"0","to":"1"}] in playback order. A project clip on stdin uses the original group clock with omitted endpoints defaulting to the group edges. Ordered requests can include project and file clips. File clips in such a request select the first audio track when present."#,
                  ExportRules.modeHelp(.cliProject) + " " + ExportRules.multicamHelpSummary + " Select microphones through the project audio policy. Project switch times are validated exactly. Adjust the project or request explicitly to use a suggested time."
              ],
              result: "Inspect reports groupIntervals, source coverage and inspection.issues. " + projectExportResult + " Each inspection issue and export error gives the one-based assembly range in segment and the affected interval in multicam. On an unsafe cut, inspect the error for the affected source, track, boundary and any nearby valid time. When multicam.at is present, nearest holds group times for the switch at that instant. When multicam.edge is present, nearest holds group times for the from or to boundary of assembly range edge.range, or of that clip in an edit request, where a file clip uses its own source clock. A project without an assembly has one range covering the group, so save the adjusted range as its assembly. Every time in nearest is a valid cut for all selected streams at that boundary. Moving a boundary shifts later output times, so another unsafe boundary can be reported on the next run.",
              examples: [#"mpcut help multicam --json | jq '.projectTemplate' > edit.cut"#,
                         "mpcut inspect --project edit.cut --json",
                         projectSilenceExample,
                         "mpcut frames --project edit.cut --at 1 --at 3 --output review --json",
                         projectExportExample,
                         #"printf '%s' '{"clips":[{"project":"edit.cut","from":"2","to":"4"}],"output":"answer.mov"}' | mpcut export --stdin --json"#],
              projectTemplate: multicamTemplate),
        .init(name: "waveform", purpose: "Read a signed amplitude envelope for a track or time window.",
              usage: ["mpcut waveform [--json] [--stream INDEX] [--from TIME] [--to TIME] [--columns N] [--] FILE"],
              instructions: ["Defaults to the whole source, first audio track and 1,024 columns. Choose 1–65,536 equal-width columns. Bound a detail request to the region under review."],
              result: "stream, sampleRate and columns identify the data. envelope.from and envelope.to are seconds. For column i, envelope.low[i] and envelope.high[i] are the minimum and maximum signed amplitudes across the selected track’s channels.",
              examples: ["mpcut waveform --json --from 2 --to 2.1 --columns 1024 narration.wav"]),
        .init(name: "silence", purpose: "Find quiet intervals, preview the plan, or export retained takes as one file.",
              usage: ["mpcut silence [--json] [--pauses-file LIST] [--threshold-db DB] [--min-pause SEC] [--leave SEC] [--stream INDEX] [--waveform N] \(tracks) \(mode(.cliSilence)) [--output FILE [--dry-run]] [--] FILE",
                      "mpcut silence (--stdin | --input REPORT.json) [--pauses-file LIST] [--json] [--leave SEC] \(tracks) \(mode(.cliSilence)) [--output FILE [--dry-run]]",
                      "mpcut silence --project PROJECT [--json] [--threshold-db DB] [--min-pause SEC] [--leave SEC] \(mode(.cliSilence)) [--output FILE [--dry-run]] [--no-sidecar]"],
              instructions: ["The detector calibrates per recording and track and bridges isolated noise blips. --threshold-db overrides it (-120 to 0 dBFS). --min-pause is positive and defaults to 1.5 s. --leave is the total nonnegative padding per pause, split between its edges, default 0.4 s. --waveform adds 1–8192 peak-dBFS columns.",
                             "For a single file, --stdin accepts a saved report. Keep its file, sourceStamp and duration. Remove entries from pauses to protect them or change --leave on replay. Use a new scan to change detector settings. \(ExportRules.modeHelp(.cliSilence)) Detection uses --stream when supplied, then --audio-stream, then the first audio track. A replay uses the saved detection stream and clips saved pauses to the selected output duration.",
                             "With --project, the saved assembly and its routed soundtrack drive detection. With --output, error.segment and error.multicam.edge.range number the report's retained clips entries. The whole group is used when the project has no assembly. Each routed track uses its saved threshold when available and otherwise calibrates automatically. --threshold-db overrides all routed thresholds. --no-sidecar bypasses saved settings and cached analysis. \(ExportRules.displayName(mode: ExportRules.defaultMode(for: .multicam))) is the default. --mode copy plans cuts around keyframe boundaries. Add --output to render the retained ranges or add --dry-run to check the export plan before writing. Stream, track, waveform and stdin options are for single-file silence workflows."],
              result: "Read thresholdMode, pauses, removals, clips, removedDuration and skippedPauses. clips are the retained ranges. Single-file reports include thresholdDB and an optional waveformPeakDBFS, where a null bin has no observed audio. Project reports include thresholds with source, file, absolute stream index and thresholdDB. In each project interval, assemblyIndex identifies the zero-based occurrence, group gives the group range and output gives its range on the original assembly clock. Project reports with --output also include preflight on the shortened output clock.",
              examples: ["mpcut silence --json --min-pause 2 --leave 0.4 interview.mov > pauses.json",
                         "mpcut silence --stdin --json --dry-run --output shortened.mov < pauses.json",
                         "mpcut silence --stdin --json --output shortened.mov < pauses.json",
                         projectSilenceExample + " > project-pauses.json",
                         projectSilenceExample + " --output shortened-program.mov --dry-run",
                         projectSilenceExample + " --output shortened-program.mov"]),
        .init(name: "scenes", purpose: "Detect hard cuts, identify recurring views, or export clips by scene or view.",
              usage: ["mpcut scenes [--json] [--] FILE",
                      "mpcut scenes [--json] [--scenes-file LIST] --export-to DIRECTORY [--group-by scene|view] [--subfolder NAME] [--base-name NAME] [--container EXT] \(tracks) [--dry-run] [--] FILE",
                      "mpcut scenes (--stdin | --input REPORT.json) [--scenes-file LIST] [--json] --export-to DIRECTORY [--group-by scene|view] [--subfolder NAME] [--base-name NAME] [--container EXT] \(tracks) [--dry-run]"],
              instructions: ["A data-only scan writes the report to stdout. Save it and pass it unchanged on stdin for export, or keep a subset of its scenes in source order. The output directory must already exist. Default grouping writes one file per scene. view joins each view’s scenes in source order. " + ExportRules.modeHelp(.cliScenes) + " A scene that cannot be written lists error.alternatives, each with the clips to pass to export."],
              result: "scenes[] includes number, start, end, startPTS, view and viewLabel. views[] lists scene numbers per view. Batch outputs include sceneNumbers and an export plan.",
              examples: ["mpcut scenes --json interview.mov > scenes.json", "mkdir -p shots", "mpcut scenes --stdin --json --export-to shots --group-by view --dry-run < scenes.json"]),
        .init(name: "frames", purpose: "Export JPEGs and exact timestamps for source or multicam review.",
              usage: ["mpcut frames [--json] --output NEW_DIRECTORY [--preset review|full] [--at TIME ...] [--at-file LIST] [--] FILE",
                      "mpcut frames [--json] --output NEW_DIRECTORY [--select scenes|non-silent] [--sample first|midpoint] [--limit N] [--preset review|full] [--stream INDEX] [--threshold-db DB] [--min-pause SEC] [--] FILE",
                      "mpcut frames [--json] --project PROJECT --at GROUP_TIME [--at GROUP_TIME ...] --output NEW_DIRECTORY [--preset review|full]"],
              instructions: ["Default is a review JPEG at each scene midpoint. Review fits the long edge within 640 pixels at quality 0.62. Full uses display resolution at quality 0.95. --limit is positive and spreads images across the ranges. Supply one --at per explicit source time, without --select, --sample or --limit. Audio options apply only to non-silent ranges. Their defaults match silence detection. Both the JPEGs and manifest.json go into a new directory.",
                             "With --project, each --at addresses the original group clock inside the project’s half-open group range. Every request returns a row for every angle, including coverage gaps and unavailable sources."],
              result: "The stdout manifest matches manifest.json. frames[].file names a JPEG inside outputDirectory. Actual picture time and PTS appear in frameTime and framePTS. Single-source rows give clipFrom and clipTo as frame-aligned export bounds, with rangeNumber, sceneNumber and viewLabel where applicable. Project rows give groupTime, angleID, sourceTime and availability in request order, then project angle order. Available rows give groupCoverage, the half-open interval where that picture is visible on the group clock. See angles[] for the source path, offset, original timestamp origin, time base and source errors.",
              examples: ["mpcut frames --json --select scenes --limit 12 --output overview interview.mov",
                         "mpcut frames --json --preset full --at 3/2 --output detail interview.mov",
                         "mpcut frames --json --project interview.cut --at 3/2 --at 3 --output angle-review"]),
        .init(name: "sidecar", purpose: "Save reusable analysis beside a source or inspect the saved inventory.",
              usage: ["mpcut sidecar [--json] [--only index,scenes,audio | --only-file LIST] [--stream INDEX] [--min-pause SEC] [--threshold-db DB] [--] FILE",
                      "mpcut sidecar --status [--json] [--] FILE"],
              instructions: ["Default save merges the complete editing index, scenes when video is present, and audio analyses for every audio track. Standalone audio saves a signed overview too. --only accepts a comma-separated subset. --stream and detector options apply when saving audio. The GUI can also save displayed filmstrip tiles, labels and settings.",
                             "The companion is FILE.cutdb. A status query is read-only. --no-sidecar disables automatic sidecar reads and writes on ordinary queries and can force fresh analysis for a save. It conflicts with --status."],
              result: "Read sidecar, status and inventory (hasIndex, hasScenes, waveformStreams, optional envelopeStreams, silence settings and thumbnailCount). saved lists sections written by a save.",
              examples: ["mpcut sidecar --json interview.mov", "mpcut sidecar --status --json interview.mov", "mpcut --no-sidecar scenes --json interview.mov"]),
        .init(name: "export", purpose: "Render a sequence or multicam project, join an ordered edit, remux selected tracks, convert video, or replace a soundtrack.",
              usage: ["mpcut export [--json] [--dry-run] \(settings(.cliExport)) \(tracks) --output FILE --clip FILE [--from TIME] [--to TIME] [--ranges LIST | --csv FILE] [--clip FILE ...] [--order LIST]",
                      "mpcut export --clips LIST --output FILE [--order-file LIST] [--dry-run] [--json]",
                      "mpcut export --input REQUEST.json [--dry-run] [--json]",
                      "mpcut export --json --stdin [--dry-run] \(settings(.cliExport)) \(tracks) [--order LIST]",
                      "mpcut export --project FILE --output FILE [--json] [--dry-run] \(projectUsage)",
                      "mpcut export [--json] [--dry-run] --clip MOVIE --replace-audio AUDIO [--replace-track INDEX] [--replacement-stream INDEX] --output FILE"],
              instructions: ["Run \(projectExportExample) to render the saved assembly or entire project range in a single call. Multicam defaults to \(ExportRules.displayName(mode: ExportRules.defaultMode(for: .multicam))) and uses exact boundaries. Use --dry-run to preview a plan whenever you want to check it before writing.",
                             "--csv applies to the preceding clip. Use time for split points or from,to for ordered keep ranges. Times are relative to the clip in-point. Headers are optional.",
                             "--from and --to belong to the preceding --clip. Omitted edges use the source edges. For ordinary edits the default is copy and exact boundaries. An explicit one-based --order defaults to smart, and can omit or repeat clips. --smart-trim aliases --mode smart. --snap nearest authorizes changing cut times for eligible copy/smart edits.",
                             selection, encoding,
                             "For --stdin supply output and a nonempty clips array. Each clip accepts file or project, plus from and to. Top-level file supplies the default source for file clips. Optional top-level keys are order, mode, snap, video, quality, audio, tracks, audioStream, replaceAudio, replaceTrack and replacementStream. Flag values and JSON fields must agree. Keys must be unique. Use an output extension to choose the container.",
                             "Use project clips on stdin to select explicit ranges on the original group clock or mix project clips with ordinary files. See help multicam for the project template and audio policies.",
                             "Replacement substitutes a matching-duration external track in the source before any cuts or joins. The first audio track in each file is the default. --replace-track and --replacement-stream take absolute indices. Keep both track types and use copy mode. --replace-audio binds to the first input source, including repeated and trimmed uses. On stdin each file clip can specify replaceAudio, replaceTrack and replacementStream to bind other sources. Timing, container and decoder priming must permit the substitution.",
                             "For whole-source replacement, dry-run checks the plan and muxer. Actual export verifies the written tracks before publishing. Ranged replacement also prepares temporary lossless working copies during dry-run to resolve the final cut boundaries."],
              result: exportResult + " " + projectExportResult + " For whole-source substitution read replacement.targetStream, replacement.replacementStream and replacement.replacementCodec in place of segments.",
              examples: ["mpcut export --json --mode smart --snap nearest --dry-run --output select.mov --clip interview.mov --from 1 --to 3",
                         #"printf '%s' '{"file":"interview.mov","clips":[{"from":"1","to":"2"},{"from":"3","to":"4"}],"order":[2,1],"snap":"nearest","output":"assembly.mov"}' | mpcut export --stdin --json --dry-run"#,
                         "mpcut export --json --tracks audio --audio-stream 1 --clip interview.mov --output dialogue.m4a",
                         "mpcut export --json --tracks video --clip interview.mov --output picture.mov",
                         "mpcut export --json --mode encode --clip talk.mp3 --from 1 --to 5 --clip talk.mp3 --from 9 --to 12 --output talk-edit.mp3 --dry-run",
                         "mpcut export --json --replace-audio processed.wav --replace-track 1 --clip interview.mov --output new-mix.mov --dry-run",
                         "mpcut export --json --mode encode --video hevc --quality balanced --audio auto --clip interview.mov --output encoded.mp4 --dry-run"],
              stdinExample: EditExample(output: "assembly.mov", clips: [[:]], mode: "copy")),
        .init(name: "rearrange", purpose: "Select, reorder or repeat ranges from one recording in a single output.",
              usage: ["mpcut rearrange [--json] [--dry-run] [--snap exact|nearest] \(tracks) FILE --output FILE (--ranges LIST | 'FROM-TO,FROM-TO')"],
              instructions: ["Supply --ranges LIST.csv or LIST.json, a positional list file, or inline FROM-TO pairs. The ranges define playback order. " + ExportRules.modeHelp(.cliRearrange) + " Video cuts snap to the nearest boundary by default. For multiple sources or another mode use export. " + selection],
              result: exportResult, examples: ["mpcut rearrange --json interview.mov --output reordered.mov '3-4,1-2' --dry-run"]),
        .init(name: "bulk", purpose: "Write separate numbered files for timestamp ranges from one recording.",
              usage: ["mpcut bulk SOURCE --ranges LIST --output DIRECTORY [--subfolder NAME] [--base-name NAME] [--container EXT] [--dry-run] [--json] \(settings(.cliBulk)) \(tracks)",
                      "mpcut bulk --input REQUEST.json [--dry-run] [--json]",
                      "mpcut bulk --stdin --json [--dry-run] \(settings(.cliBulk)) \(tracks)"],
              instructions: ["Send file, outputDirectory and a nonempty ranges array on stdin. Each range requires from and to. Optional keys are container (extension without a dot), mode, snap, video, quality, audio, tracks and audioStream. The destination directory must already exist. With --ranges, --output-directory is an alias for --output. Input array order controls numbering. Optional subfolder and baseName strings (flags --subfolder and --base-name) create paths like Review/Interview-001.mov. Dry-run previews paths without creating the subfolder.",
                             ExportRules.modeHelp(.cliBulk) + " Boundaries are exact unless snap says otherwise. All ranges and destinations are checked before writing. A runtime failure may leave completed files. " + selection, encoding],
              result: "Read outputs[] for each export plan. On a mid-batch failure, outputs lists completed items. Inspect failedRange and error before retrying.",
              examples: ["mkdir -p clips", #"printf '%s' '{"file":"interview.mov","outputDirectory":"clips","snap":"nearest","ranges":[{"from":"1","to":"2"},{"from":"3","to":"4"}]}' | mpcut bulk --stdin --json --dry-run"#],
              stdinExample: EditExample(outputDirectory: "clips", ranges: [["from": "1", "to": "2"]], mode: "smart", snap: "nearest"))
    ]

    static func topic(_ name: String) throws -> CommandHelp {
        let key = name == "--version" ? "version" : name
        guard let command = commands.first(where: { $0.name == key }) else {
            throw CLIError("invalid_arguments", "Unknown help topic '\(name)'. Use mpcut help to list commands.")
        }
        return command
    }

    static var manual: String {
        let reference = commands.map(\.text).joined(separator: "\n\n")
        if let executable = Bundle.main.executableURL {
            let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            let guide = contents.appendingPathComponent("Resources/Documentation/docs/USAGE.md")
            if contents.lastPathComponent == "Contents", let text = try? String(contentsOf: guide, encoding: .utf8) {
                return text + "\n\n## CLI command reference\n\n" + reference
            }
        }
        return overview + "\n\n" + reference
    }

    static var synopsis: String {
        commands.flatMap(\.usage).joined(separator: "\n")
    }

    static var overview: String {
        let list = commands.map { command in
            let invocation: String
            switch command.name {
            case "version": invocation = "--version"
            case "multicam": invocation = "help multicam"
            default: invocation = command.name
            }
            return "  \(invocation)  —  \(command.purpose)"
        }
        return (["MPCut " + Arguments.version, "Usage: mpcut COMMAND [OPTIONS]", ""] + list
            + ["", "Agent workflow"] + conventions).joined(separator: "\n")
    }
}
