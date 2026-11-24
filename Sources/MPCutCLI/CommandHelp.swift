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
        var file: String? = "interview.mov"
        var projectPath: String?
        var replaceAudio: String?
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
        "With --stdin, send one UTF-8 JSON object and close stdin. With --json, read one JSON object from stdout and drain stderr separately for progress and diagnostics. Exit 0 means success, 1 an operation failure, 2 a CLI/request error, 3 a Tiles ISO delivery awaiting review, and 130 cancellation. On failure read error.code and error.message, plus error.segment, error.boundary, error.track or error.nearest when present. A batch that fails during writing can also report completed outputs and failed_range.",
        "Use local paths. Relative input and output paths resolve from the process working directory, including paths inside stdin JSON. Quote spaces in a shell. Pass separate argv entries from code. Use ./ for a filename beginning with a dash. A parent output directory must already exist. Media exports require a new filename.",
        "Times are relative to each source or to the group clock for project clips. Ranges include from and exclude to. Command-line times accept decimal seconds, MM:SS, HH:MM:SS and fractions such as 1001/30000. In edit JSON use strings or exact objects such as {\"numerator\":1001,\"denominator\":30000}. Keep the rational times from inspection through export.",
        "Stream indices are absolute, zero-based media.streams[].index values. Order entries, scene numbers, failed_range and error.segment are one-based. error.segment is the clip's number in the request's clips array, whatever the playback order. For a saved multicam project it is the number of the assembly range, and a project without an assembly has the single range 1. --stream chooses the audio to analyze. --tracks audio --audio-stream INDEX chooses the audio to write.",
        "To render a saved multicam project in one command, run \(projectExportExample). Add --dry-run only if you want to review the plan before writing.",
        "To build an edit from source recordings, use media inspect to identify streams and boundaries, then use scenes scan, silence scan, waveform envelope read or review frames export. For single-source image review, use the frames manifest’s clip_from and clip_to. Assemble the chosen ranges in playback order.",
        "Use --dry-run with export commands and scenes export to preflight media output. For pauses, use silence plan. A dry run checks the actual sources and destination and leaves the output unwritten. Analysis commands save and reuse completed work in FILE.cutdb. Add --no-sidecar to bypass automatic reads and writes.",
        "For unsafe_boundary, inspect error.nearest when present. Submit an acceptable boundary, explicitly allow --snap nearest on an eligible command, or preflight Smart Trim for supported video. For a sound-only edit whose joins cannot be copied, preflight --mode encode, which keeps the source format where it can. In a multicam error, nearest replaces the switch at error.multicam.switch_group_time, or the from or to edge named by error.multicam.edge. Never move a switch to a time offered for an edge. For unsupported_container, inspect the selected tracks and try a compatible extension. For output_exists use a fresh destination. After source_changed, rescan the recording before replaying a report."
    ]

    // Every mode, track, codec, preset, audio action and container listing below comes from ExportRules.
    private static let tracks = ExportRules.tracksUsage + " [--audio-stream INDEX]"
    private static func mode(_ entry: ExportEntryPoint) -> String { ExportRules.modeUsage(entry) }
    private static func settings(_ entry: ExportEntryPoint) -> String {
        "\(mode(entry)) \(ExportRules.snapUsage) \(ExportRules.encodeUsage)"
    }
    private static let encoding = ExportRules.encodeSettingsHelp + " " + ExportRules.helpSummary + " A sound-only conversion refuses video and quality settings, selects one audio track, places cuts on its sample clock and reports codec, bit_rate or quality, and bit_depth in audio_actions."
    private static let multicamAudioDeliveryUsage = "[--audio-output separate_tracks|downmix_mono|downmix_stereo]"
    private static let projectUsage = "\(mode(.cliProject)) \(ExportRules.tracksUsage) \(ExportRules.encodeUsage) \(multicamAudioDeliveryUsage) [--require-camera-copy]"
    private static let selection = "The default selection is all. Explicit audio or video selection uses stream copy, except that export clips join and export ranges separate convert an audio selection with --mode encode. --audio-stream requires --tracks audio. WAV suits compatible PCM and M4A suits AAC. Edited FLAC uses MKA. Copy cuts depend on codec, container, and decoder history."
    private static let exportResult = "Read output, container, mode and duration. For video, copied_duration and encoded_duration split the selected time into copied and encoded pictures. An audio-only copy reports its retained duration in copied_duration, and an audio conversion in encoded_duration. A sound-only encode request that could copy exactly reports mode copy. For an ordinary edit, read segments in playback order. Each segment includes source from/to, output_start, tracks and track_actions. Smart edges include encoded_edges. Conversion reports include audio_actions and warnings where applicable. Where provided, cut_map.occurrences preserves individual timeline uses, including repeats and adjacent uses in one render segment."
    private static let projectExportExample = "mpcut export project render --project edit.cut --output finished.mov --json"
    private static let spacingUsage = "[--space-clips source|DURATION]"
    private static let projectSilenceExample = "mpcut silence scan --project edit.cut --min-pause-seconds 1.5 --padding-per-side-seconds 0.2 --json"
    private static let projectExportResult = "Visible stills use Smart Trim when mode is omitted. With Smart Trim, --audio aac or --audio pcm requests audio conversion where needed. --require-camera-copy permits generated stills and requires all retained camera picture to copy. A still export reports copied_camera_duration, encoded_camera_duration, generated_still_duration and per-track sound actions. Multicam export and its optional dry run report the playback intervals in plan, resolved source paths in sources, track actions and encoded edges in picture and audio, and the video durations in copied_video_duration and encoded_video_duration."
    private static let multicamTemplate = MulticamProject(
        referenceAngle: "wide", range: MulticamRange(from: .zero, to: RationalTime(numerator: 4)),
        angles: [.init(id: "wide", file: "wide.mov"), .init(id: "close", file: "close.mov")],
        audio: .fixed(.init(source: "wide", stream: 1)),
        switches: [.init(at: .zero, angle: "wide"), .init(at: RationalTime(numerator: 2), angle: "close")]
    )

    private static let families: [CommandHelp] = [
        .init(name: "help", purpose: "Discover commands and their inputs, outputs and examples.",
              usage: ["mpcut help [COMMAND|manual] [--json]", "mpcut COMMAND --help [--json]", "mpcut --help [--json]"],
              instructions: ["Global JSON includes the full command reference keyed by command name. Request one topic for a smaller response. Use help manual for the offline guide and command reference.",
                             "To render a saved multicam project, use \(projectExportExample)."],
              result: "Global fields include version, commands, conventions, usage, export_modes, export_tracks, video_codecs, qualities, audio_options and snap_options.",
              examples: ["mpcut help --json", "mpcut help export --json"]),
        .init(name: "--version", purpose: "Identify the installed CLI.",
              usage: ["mpcut --version [--json]"], instructions: [],
              result: "Plain output is the version string. JSON has a version field.", examples: ["mpcut --version --json"]),
        .init(name: "tiles", purpose: "Find tiles, review feeds, edit layouts and deliver synchronized ISOs.",
              usage: ([TilesCLI.Operation.exportISOs] + TilesCLI.Operation.allCases.filter { $0 != .exportISOs }).map { "mpcut tiles \($0.rawValue) \($0.helpUsage) [--json]" },
              instructions: ["Inspect, preview and recording edits use source time. Multicam group and occurrence layouts use group time. A project with multiple scanned recordings requires --source-id. Project edits require --out-project or --in-place.",
                             "Preview writes untreated source pixels with tile annotations. Add --progress stderr or jsonl to report progress on standard error."],
              result: "Read the command's JSON result for source, tile and feed information or the generated artifacts. ISO export returns exit code 3 when review is required.",
              examples: TilesCLI.Operation.allCases.map { "mpcut tiles \($0.rawValue) \($0.helpExample) --json" }),
        .init(name: "participants", purpose: "Scan gallery recordings, edit participant tracks and render participant shots.",
              usage: ["mpcut participants scan --file MEDIA [--backend auto|cpu-only|gpu-required] [--sampling adaptive|every-frame|sparse] [--feed-layout auto|COLSxROWS] [--include-scenes] [--no-sidecar] [--output SCAN.json [--summary]] [--resume-file SCAN.json] [--progress none|stderr|jsonl] [--json]",
                      "mpcut participants markers build --analysis-file SCAN.json [--json]",
                      "mpcut participants project inspect --project PROJECT.cut [--json]",
                      "mpcut participants project accept --project PROJECT.cut --source-id ID --analysis-file SCAN.json (--out-project FILE | --in-place) [--json]",
                      "mpcut participants project apply --project PROJECT.cut --participants-file EDIT.json (--out-project FILE | --in-place) [--json]",
                      "mpcut participants render plan --project PROJECT.cut [--output MOVIE] [--json]",
                      "mpcut participants render export --project PROJECT.cut --output MOVIE [--json]",
                      "mpcut participants angles list (--stdin | --input REQUEST.json) [--json]",
                      "mpcut participants angles take (--stdin | --input REQUEST.json) [--json]",
                      "mpcut participants angles plan (--stdin | --input REQUEST.json) [--json]",
                      "mpcut participants angles render (--stdin | --input REQUEST.json) [--json]"],
              instructions: ["Requests use project_path for a saved project and file for a recording. Project accept imports reviewed analysis into a saved source. Project apply replaces the accepted participant edit with the participants object or the object at participants_file. Choose out_project or in_place for either command.",
                             "For generic video feeds, set --feed-layout auto or a fixed grid such as --feed-layout 2x2 (feed_layout in JSON). Fixed grids can contain up to 64 feeds. Meeting analysis is the default.",
                             "With --output, add --summary to print the saved scan's state, counts and coverage in place of a second copy of the report. Save a scan of up to 1 GiB with --output to accept it or build markers later. A cancelled scan exits 130 and reports any partial analysis. An incomplete scan exits 1 and retains its coverage and backend diagnostics. Supply the partial file to --resume-file to replay the verified prefix using the saved configuration.",
                             "A minimal render request contains a project_path and a plan such as {\"canvas\":{\"width\":1280,\"height\":720},\"shots\":[{\"layout\":\"solo\",\"slots\":[{\"id\":\"guest\"}]}]}. Use layout pair with two ordered slots. Add audio mode program to keep the source program mix or iso with one participant ID to select a bound microphone.",
                             "Marker rules can be changed against a saved scan. Supply a rule in the JSON request to choose the unit, threshold, event kinds, roster and settling window.",
                             "Render plan reports the intended picture, coverage and sound before writing. Render plan and render export accept an optional plan in the JSON request. Without it they use the project’s saved render plan.",
                             "Angle requests take source_id and an exact range with from and to. Choose participant_ids, include_original and/or presentation_ids. Both angle plan and angle render take canvas and optional audio routing. Angle render also takes output_directory. The output directory must be new.",
                             "Angle take takes a virtual angle object returned by angle list, an exact output_time timestamp and either out_project or in_place. It authors a timed picture decision."],
              result: "Scan returns observations and coverage. Project inspection returns the accepted participant edit. Angle export creates aligned movies and multicam.cut.",
              examples: ["mpcut participants scan --file gallery.mov --backend cpu-only --output gallery.json --json",
                         "mpcut participants markers build --analysis-file gallery.json --json",
                         "mpcut participants project inspect --project interview.cut --json",
                         "mpcut participants project accept --project interview.cut --source-id gallery.mov --analysis-file gallery.json --out-project reviewed.cut --json",
                         "mpcut participants project apply --input participant-edit.json --json",
                         "mpcut participants render plan --project interview.cut --json",
                         "mpcut participants render export --project interview.cut --output interview.mov --json",
                         "mpcut participants angles list --input angles.json --json",
                         "mpcut participants angles take --input angle-take.json --json",
                         "mpcut participants angles plan --input angle-plan.json --json",
                         "mpcut participants angles render --input angle-delivery.json --json"]),
        .init(name: "transcript", purpose: "Prepare Transcriberrr sessions and edit from attached transcripts.",
              usage: ["mpcut transcript provider capabilities [--json]",
                      "mpcut transcript tracks list (--project FILE | --file MEDIA) [--lane-id ID] [--json]",
                      "mpcut transcript job prepare (--project FILE | --file MEDIA) [--job-directory DIR] [--selected-tracks ID,ID] [--engine NAME] [--model NAME] [--language CODE] [--expected-speakers N] [--diarization] [--progress none|stderr|jsonl] [--policy reuse|resume|restart] [--operation-id UUID] [--json]",
                      "mpcut transcript job run --job-id UUID [--job-directory DIR] [--download] [--json]",
                      "mpcut transcript job status --job-id UUID [--job-directory DIR] [--json]",
                      "mpcut transcript job cancel --job-id UUID [--job-directory DIR] [--json]",
                      "mpcut transcript job retry --job-id UUID [--job-directory DIR] [--project FILE] [--json]",
                      "mpcut transcript attachment import --project FILE (--transcript FILE | --job-id UUID [--job-directory DIR]) [--format json|srt|vtt] [--attachment-id ID] [--source-id ID] [--audio-stream-index INDEX] [--origin TIME] (--out-project FILE | --in-place) [--json]",
                      "mpcut transcript attachment import --file MEDIA (--transcript FILE | --job-id UUID) [--audio-stream-index INDEX] [--channel INDEX] (--output FILE.json | --out-project FILE.cut) [--json]",
                      "mpcut transcript attachment inspect (--project FILE | --transcript FILE) [--attachment-id ID] [--track-id ID] [--lane-id ID] [--offset N] [--limit N] [--json]",
                      "mpcut transcript attachment bind --project FILE [--attachment-id ID] [--track-id ID] [--source-id ID | --file MEDIA] [--audio-stream-index INDEX] [--origin TIME] (--out-project FILE | --in-place) [--json]",
                      "mpcut transcript attachment detach --project FILE [--attachment-id ID] (--out-project FILE | --in-place) [--json]",
                      "mpcut transcript words read --project FILE [--attachment-id ID] [--space source|group|current_cut] [--lane-id ID] [--occurrence-id ID] [--offset N] [--limit N] [--json]",
                      "mpcut transcript words search --project FILE [--attachment-id ID] [--space source|group|current_cut] [--lane-id ID] --query TEXT [--offset N] [--limit N] [--json]",
                      "mpcut transcript words locate --project FILE [--attachment-id ID] [--space source|group|current_cut] [--lane-id ID] --word-id ID [--occurrence-id ID] [--offset N] [--limit N] [--json]",
                      "mpcut transcript words compare --project FILE [--attachment-id ID] [--space SPACE] --query TEXT [--context-words N] [--offset N] [--limit N] [--json]",
                      "mpcut transcript script align --project FILE [--attachment-id ID] [--space SPACE] --script-file FILE [--offset N] [--limit N] [--json]",
                      "mpcut transcript words suggest --project FILE [--attachment-id ID] [--space SPACE] [--filler-terms WORD,WORD] [--offset N] [--limit N] [--json]",
                      "mpcut transcript words select --project FILE --first-word-id ID [--last-word-id ID] [--space SPACE] [--first-occurrence-id ID] [--json]",
                      "mpcut transcript edit plan --project FILE --action ACTION --first-word-id ID [--last-word-id ID] [--space SPACE] [--first-occurrence-id ID] [--last-occurrence-id ID] [--output FILE] [--json]",
                      "mpcut transcript edit apply --project FILE --plan-file FILE (--out-project FILE | --in-place) [--json]",
                      "mpcut transcript excerpt queue --project FILE --name TEXT --first-word-id ID [--last-word-id ID] [--out-project FILE] [--json]",
                      "mpcut transcript export --project FILE [--attachment-id ID] [--space SPACE] [--captions] [--format json|text|srt|vtt] [--output FILE] [--json]",
                      "mpcut transcript words correct --input REQUEST.json [--json]"],
              instructions: [
                  "Run tracks to inventory the source streams. transcript job prepare writes staged 16 kHz audio and manifest paths, then returns. Use transcript job run with its job ID or launch the reported Transcriberrr command separately, then import the result or import by job ID. Use MPCUT_TRANSCRIBERRR_HELPER to identify a local executable and an explicit Transcriberrr download option when a model needs installation.",
                  "Transcript file commands accept one JSON request on stdin or by --input, with options as snake_case fields. Examples include project_path, file, transcript, attachment_id, job_id, job_directory, space, audio_stream_index, limit, out_project, and in_place. Use true for Boolean options and arrays for selected_tracks and filler_terms. With flag input, use --transcript - to read an imported transcript on stdin.",
                  "Read, search, and locate return items, total, and next_offset. Pass next_offset as the next request's offset. Reads and exports cover all attached sessions unless you choose --attachment-id ID. A word ID reused in several sessions returns each match with its attachment and occurrence ID. Read and search accept --speaker-id, --source-id, --track-id, --lane-id, --assembly-index, --clip-id, and --include-inferred. Determine the occurrence ID before editing a repeated passage.",
                  "For a compound edit, pass request with action and selections. Each selection uses first_word_id, optional last_word_id, space, first_occurrence_id, last_occurrence_id, and kind (phrase or gap). Supply attachment_id on each selection when using more than one attached result. Save a plan and apply that exact review before changing the project. Queue writes a named editable project snapshot beside the input project unless out_project is supplied. Render it with mpcut export project render --project.",
                  "Use correct with a JSON change and a selection for span changes. A change is a single typed object, for example {\"rename_speaker\":{\"speaker_id\":\"speaker-0\",\"name\":\"Guest\"}}. Use named_select to save a word range or supply a complete record with multiple anchors. Give the correction a record_id (--record-id ID) to make it safe to send again: a repeat with the same ID finds the saved record and changes nothing.",
                  "To tell Transcriberrr which tracks are personal microphones, pass transcript job prepare a JSON request whose options hold engine, model, language, expected_speakers, diarization, selected_tracks, and track_options. track_options maps a track ID from tracks to {\"role\":\"isolated_mic\",\"speaker\":\"Guest\"}, {\"role\":\"mixed_audio\"}, or an audio channel. A track without a role is treated as mixed audio. Naming the microphones keeps each speaker's words on their own microphone and gives anyone without one a speaker of their own.",
                  "Nested selection, request, and bindings JSON take time strings such as \"1/4\" or \"0.25\" and the space names source, group, or current_cut. Read and search also accept --file to keep one sequence recording."
              ],
              result: "A project mutation reports the output project. Review output contains timeline and transcript revisions, result identity, resolved and copy-safe boundaries, duration, export tiers and affected speech across attachments.",
              examples: ["mpcut transcript job prepare --project interview.cut --job-directory ./jobs --json",
                         "mpcut transcript attachment import --project interview.cut --transcript captions.vtt --in-place --json",
                         "mpcut transcript words search --project interview.cut --query 'expected benefit' --space current_cut --json",
                         "mpcut transcript edit plan --project interview.cut --action delete --first-word-id word-0 --output review.json --json",
                         "mpcut transcript edit apply --project interview.cut --plan-file review.json --out-project reviewed.cut --json",
                         "mpcut transcript words correct --input correction.json --json",
                         "mpcut transcript export --project interview.cut --captions --space current_cut --output captions.srt"]),
        .init(name: "project authoring", purpose: "Create or edit a saved timeline in a new .cut file.",
              usage: ["mpcut project create (--input REQUEST.json | --stdin) [--json]", "mpcut project edit (--input REQUEST.json | --stdin) [--json]"],
              instructions: ["Supply out_project and an ordered operations array. Create takes kind sequence or multicam. Edit takes project_path. For sequence use append, trim, split, move or remove with clip id. Save named source intervals with source_select_save and remove them with source_select_remove. Apply an ordered ranges array with source_ranges_apply. Use equal sequence from and to times to insert, or choose a nonempty interval to replace. Multicam uses assembly indices and also accepts switch_set, switch_remove, angle_set, angle_clear and add_recording. add_recording takes angle_id, path and group_start. See docs/HEADLESS.md for the request fields."],
              result: "Returns project_path and operation_count.", examples: ["mpcut project create --input rough-cut.json --json", "mpcut project edit --input changes.json --json"]),
        .init(name: "still", purpose: "Edit still images in saved sequence and multicam projects.",
              usage: ["mpcut timeline clips space --project FILE (--source-timing | --duration TIME | --frames COUNT --rate FPS) [--background #RRGGBB] [--rate FPS] (--out-project FILE | --in-place) [--json]",
                      "mpcut still project create --out-project FILE (--image FILE | --gap) [--background #RRGGBB] --width N --height N --rate FPS [--codec h264|hevc|prores|jpeg] [--container mov|mp4|m4v|mkv] [--color sdr|pq|hlg] [--soundtrack FILE [--audio-stream INDEX] [--from TIME] [--to TIME]] (--duration TIME | --frames COUNT | --fit-soundtrack) [--json]",
                      "mpcut still soundtrack attach --project FILE --soundtrack FILE [--audio-stream INDEX] [--from TIME] [--to TIME] [--fit-soundtrack] (--out-project FILE | --in-place) [--json]",
                      "mpcut still soundtrack fit --project FILE (--out-project FILE | --in-place) [--json]",
                      "mpcut still soundtrack detach --project FILE (--out-project FILE | --in-place) [--json]",
                      "mpcut still picture replace --project FILE (--image FILE | --asset ID) --clock sequence|group --from TIME --to TIME (--out-project FILE | --in-place) [--json]",
                      "mpcut still placement insert --project FILE (--image FILE | --asset ID) [--background #RRGGBB] --clock sequence|assembly --at TIME (--duration TIME | --frames COUNT --rate FPS) [--rate FPS] (--out-project FILE | --in-place) [--json]",
                      "mpcut still placement list --project FILE [--placement ID] [--json]",
                      "mpcut timeline gap insert --project FILE --clock sequence|assembly --at TIME (--duration TIME | --frames COUNT --rate FPS) (--out-project FILE | --in-place) [--json]",
                      "mpcut still placement update --project FILE --placement ID [--asset ID] [--at TIME] [--duration TIME | --frames COUNT --rate FPS] (--out-project FILE | --in-place) [--json]",
                      "mpcut still placement update --project FILE --placement ID [--clock sequence|source|group] [--fragment-index N] [--at TIME | --from TIME --to TIME] [--duplicate-id ID] (--out-project FILE | --in-place) [--json]",
                      "mpcut still placement update --project FILE --placement ID --fragment-index N --detach-id ID (--out-project FILE | --in-place) [--json]",
                      "mpcut still asset relink --project FILE --asset ID --image FILE (--out-project FILE | --in-place) [--json]",
                      "mpcut still placement remove --project FILE --placement ID (--out-project FILE | --in-place) [--json]"],
              instructions: ["Attach places a recording at program zero in a still-only project. Supply exact source times on audio sample boundaries to use a portion. Fit stretches the single image to the selected recording's audible extent. Detach keeps the current picture timing.",
                             "Replace Picture keeps the underlying sound and duration. Insert Still adds time and silence on the existing audio tracks.",
                             "Space Clips sets gaps between consecutive clips. --source-timing measures each gap from the preceding clip's source end to the next clip's source start. Use chronological ranges from the same file or multicam group. --duration 0 clears gaps between clips.",
                             "Add and update accept --fit fit|fill, --crop-x, --crop-y, --crop-width, --crop-height, and --background #RRGGBB. Crop coordinates are normalized. Use --color sdr|pq|hlg for an explicit program color interpretation.",
                             "Use --project - to read a project from stdin. A mutation from stdin requires a named --out-project.",
                             "The bundled user guide in mpcut help manual links to docs/STILL-IMAGES.md."],
              result: "Reports asset and placement IDs, offline status, authored and visible ranges, and the typed document under timeline.",
              examples: ["mpcut still picture replace --project edit.cut --image photo.png --clock sequence --from 8 --to 12 --out-project covered.cut --json",
                         "mpcut timeline clips space --project edit.cut --source-timing --in-place --json",
                         "mpcut still placement insert --project multicam.cut --image title.png --clock assembly --at 0 --frames 60 --rate 30 --in-place --json"]),
        .init(name: "multicam sync suggest", purpose: "Read sync offset and drift evidence for a multicam project.",
              usage: ["mpcut multicam sync suggest --project FILE [--source-id ID] [--reference-source-id ID] [--metadata-only] [--json]",
                      "mpcut multicam sync suggest --project FILE --reference-source-id ID --reference-stream INDEX --replacement FILE --replacement-stream INDEX [--seed TIME] [--metadata-only] [--json]",
                      "mpcut multicam sync suggest --project FILE --reference-source-id ID --replacement FILE --replacement-stream INDEX --program [--reference-stream INDEX] [--seed TIME] [--metadata-only] [--json]"],
              instructions: ["By default, the primary recording on the reference camera supplies the sync clock.",
                             "Use --reference-source-id to select another recording on that camera, or --metadata-only to skip waveform analysis.",
                             "For track replacement, choose any camera recording and the two absolute stream indices. The optional seed is a rational offset relative to the camera recording.",
                             "Use --program to review coverage across the program. Omit --reference-stream for a video-only reference. Apply the confirmed offset with project edit, using audio_set with mode replace."],
              result: "Returns available metadata offsets, waveform offsets and drift observations. Replacement sync also returns the suggested offsets relative to the camera recording.",
              examples: ["mpcut multicam sync suggest --project interview.cut --json"]),
        .init(name: "multicam switch coverage", purpose: "Review picture and routed audio coverage before taking a camera.",
              usage: ["mpcut multicam switch coverage (--input REQUEST.json | --stdin) [--json]"],
              instructions: ["JSON request fields: project_path, angle_id, group_time (exact rational seconds)."],
              result: "Returns the proposed group interval and coverage status with exact missing ranges for each lane.",
              examples: ["mpcut multicam switch coverage --input proposal.json --json"]),
        .init(name: "timeline range map", purpose: "Map a saved timeline range between media and output clocks.",
              usage: ["mpcut timeline range map --project FILE --space source|sequence|group|assembly --from TIME --to TIME [--file FILE] [--occurrence-index N] [--json]"],
              instructions: ["Ranges include the start and exclude the end. The optional zero-based occurrence index limits matches to one item. For sequence projects, --file selects a source recording."],
              result: "Returns exact clipped input and output ranges in timeline order, including repeated occurrences.",
              examples: ["mpcut timeline range map --project interview.cut --space source --from 4 --to 7 --file interview.mov --json"]),
        .init(name: "history compare", purpose: "Compare the timelines of two saved project revisions.",
              usage: ["mpcut history compare --before-project FILE --project FILE [--json]"],
              instructions: ["Pass the older saved revision to --before-project and the current saved revision to --project."],
              result: "Returns added, removed and modified occurrences, with before and after ranges and project-level changes.",
              examples: ["mpcut history compare --before-project review.cut --project current.cut --json"]),
        .init(name: "project inspect", purpose: "Read a saved project and inspect its timeline.",
              usage: ["mpcut project inspect --project FILE [--json]"],
              instructions: ["Pass the saved project path, or use --project - to supply its JSON on stdin."],
              result: "Sequence results include clips, sources and duration. For multicam, read group_intervals, inspection.sources and inspection.issues. Projects with stills report their linked assets and visible placements.",
              examples: ["mpcut project inspect --project interview.cut --json"]),
        .init(name: "media inspect", purpose: "Inspect a still image, media stream, frame index, or audio packet list.",
              usage: ["mpcut media inspect [--json] \(tracks) [--keyframes | --frames | --audio-packets [--stream INDEX]] [--from TIME] [--to TIME] [--] FILE"],
              instructions: ["Inspect an image without range or stream options to read its dimensions, color information, and HDR rendition. A bare video or audio inspection returns media metadata. --frames returns every indexed picture. --keyframes returns keyframe markers and verified video start points. --audio-packets defaults to the selected output audio stream, otherwise the first audio stream. --from and --to limit a picture or packet query to a half-open window.",
                             "Use media.frames[].time for a cut and the next picture time for its exclusive end. can_start and can_end describe the picture. A dry run checks linked tracks and the full edit. PCM indexes may summarize contiguous packets."],
              result: "Use the top-level file as an input path for subsequent commands or edit JSON. Read media.has_video, media.duration, media.origin, media.streams, media.frames and, when requested, media.audio_packets. Read copy.eligible, copy.reason and copy.containers before selecting a destination. preview is unchecked. " + ExportRules.tierReportingHelp + " It is the tier of the whole source, or of the range between --from and --to.",
              examples: ["mpcut media inspect --json interview.mov", "mpcut media inspect --json --frames --from 2 --to 3 interview.mov", "mpcut media inspect --json --audio-packets --stream 1 --from 2 --to 3 interview.mov"]),
        .init(name: "convert", purpose: "Convert editable projects between MPCut, Resolve, Premiere Pro, and Final Cut Pro.",
              usage: ["mpcut project convert INPUT [--to cut|resolve|premiere|fcp] --output NEW_PROJECT [--allow-loss [--flatten-multicam]] [--json]"],
              instructions: ["The input and output filename extensions select the adapters. --to additionally checks the desired format. MPCut documents use .cut, Resolve uses .drp or .drt, Premiere Pro uses .prproj, and Final Cut Pro uses .fcpbundle or its .fcpxml and .fcpxmld interchange formats. Native operations may require the editing application. Keep referenced media available.",
                             "Conversion reports unsupported timeline features. Use --allow-loss to authorize the approximations the adapter describes. Give the output a fresh path.",
                             "To flatten a multicam edit into selected picture and sound clips in Premiere Pro, use --allow-loss --flatten-multicam with a .prproj output. Flattening discards alternate angles."],
              result: "Read input, output and warnings[] on success. See error.code and error.message on failure.",
              examples: ["mpcut project convert interview.cut --to resolve --output interview.drp",
                         "mpcut project convert interview.fcpxml --output imported.cut --json",
                         "mpcut project convert cutaway.cut --to premiere --output cutaway.prproj"]),
        .init(name: "project document print", purpose: "Print expanded project JSON as readable text.",
              usage: ["mpcut project document print FILE", "mpcut project document print -"],
              instructions: ["Expands the saved reference table. Use the result for schema validation. Pass - to read standard input."],
              result: "The expanded project document on standard output.",
              examples: ["mpcut project document print interview.cut", "mpcut project document print - < interview.cut"]),
        .init(name: "project merge", purpose: "Merge two branches of a project file for Git.",
              usage: ["mpcut project merge BASE OURS THEIRS"],
              instructions: ["Merges the edits of OURS and THEIRS, which both started from BASE, and replaces OURS with the result. Clips and other edit fields are merged line by line. Recordings in the media snapshot are merged by path. Undo history is left out, since steps from two branches cannot be combined.",
                             "Register it once in a clone with git config merge.mpcut.driver \"mpcut project merge %O %A %B\" and add the line *.cut merge=mpcut to .gitattributes. Git then runs it for every project it merges.",
                             "When both branches changed the same lines, OURS is left as plain project JSON with Git conflict markers around them and the command exits with status 1. Resolve the marked lines and the file opens. Status 1 also reports a merge MPCut cannot open, such as one with the same clip ID twice. OURS then holds the merged text to correct."],
              result: "OURS holds the merged project. Exit status 1 reports conflicting edits.",
              examples: ["mpcut project merge base.cut interview.cut theirs.cut"]),
        .init(name: "resolve", purpose: "Export a saved project as an editable DaVinci Resolve timeline.",
              usage: ["mpcut project resolve export (--project PROJECT --output FILE.fcpxml | --clips LIST --output FILE.fcpxml | --input REQUEST.json | --stdin) [--json]",
                      "mpcut project resolve import (--project PROJECT --output FILE.fcpxml | --clips LIST --output FILE.fcpxml | --input REQUEST.json | --stdin) [--json]"],
              instructions: ["Source paths resolve relative to the project. Use --project - for stdin. Use --stdin for an ordinary file edit with output, clips, order and optional replacement audio. A project with still edits requires media export to preserve those pictures. Keep source media and any exported Audio or Sources directories available. The import command opens the timeline in the current Resolve project using local scripting."],
              result: "JSON reports output and whether Resolve opened the timeline.",
              examples: ["mpcut project resolve import --project interview.cut --output interview.fcpxml"]),
        .init(name: "multicam", purpose: "Create, inspect, review and export a multicam project.",
              usage: ["mpcut help multicam [--json]",
                      "mpcut export project render --project PROJECT --output FILE \(projectUsage) [--dry-run] [--json]",
                      "mpcut project inspect --project PROJECT [--json]",
                      "mpcut multicam sync suggest --project PROJECT [--source-id ID] [--reference-source-id ID] [--metadata-only] [--json]",
                      "mpcut silence plan --project PROJECT [--output FILE] [--json]",
                      "mpcut review frames export --project PROJECT [--clock sequence|assembly|group] --at TIME --output NEW_DIRECTORY [--json]",
                      "mpcut export clips join --stdin --json [--dry-run]"],
              instructions: [
                  "Export a saved project directly with \(projectExportExample). Add --dry-run for an optional preview of the plan.",
                  "Use \(projectSilenceExample) to find pauses in the routed program audio in assembly order. Use help silence for settings, report fields and export examples.",
                  "Copy the project template below, or extract project_template from the JSON help. Save that object as edit.cut and edit the filenames, stream choices and timestamps. Project source paths resolve from the project's directory. Paths in stdin requests resolve from the working directory. --project - reads the project itself from standard input, up to 64 MB, and then resolves its relative source paths from the working directory.",
                  "Stable source IDs identify the reference angle, switches and microphones. Each offset places source time zero on the group clock. The switch at the start is required. Later switches must be strictly increasing and precede the group end. Ranges include their start and exclude their end.",
                  #"For a fixed camera microphone use "audio":{"mode":"fixed","source_id":"wide","audio_stream_index":1}. For a separate recorder add "audio_sources":[{"id":"lav","file":"lav.wav","offset":"0"}] and select "audio":{"mode":"fixed","source_id":"lav","audio_stream_index":0}. When editing the template by hand, clear the previous fixed_audio field so the active Fixed selection becomes the saved choice."#,
                  #"For camera microphones use "audio":{"mode":"follow"} and set each angle's audio_stream_index to its absolute index. For a per-switch override use {"group_time":"2","angle_id":"close","audio":{"source_id":"wide","audio_stream_index":1}}. A later switch without an override resumes the project policy."#,
                  "For simultaneous microphones, use project edit with audio_set in Mix mode. Set lane order and labels with mix_lanes_set. Use audio_replacement_set to bind an aligned replacement to a camera stream.",
                  "Use --audio-output to choose separate tracks or a rendered mono or stereo downmix. Use --audio copy, auto, aac, pcm or remove independently of picture mode. Dry runs report audio_lanes in delivery order.",
                  #"For a silent project use "audio":{"mode":"none"}, which selects no default microphone. A switch override still routes its microphone, so a project in this mode must either leave every switch without an override or give an override to every switch in the exported ranges. Otherwise inspect lists missing_audio for each uncovered interval, and export and its dry run fail with the same code. For an existing project, --tracks video exports picture only."#,
                  #"Direct export uses the saved assembly or the whole range. To save a rearrangement in the project, add "assembly":[{"from":"2","to":"4"},{"from":"0","to":"1"}] in playback order. A project clip on stdin uses the original group clock with omitted endpoints defaulting to the group edges. Ordered requests can include project and file clips. File clips in such a request select the first audio track when present."#,
                  ExportRules.modeHelp(.cliProject) + " " + ExportRules.multicamHelpSummary + " Select microphones through the project audio policy. Project switch times are validated exactly. Adjust the project or request explicitly to use a suggested time."
              ],
              result: "Inspect reports group_intervals, source coverage and inspection.issues. " + projectExportResult + " Each inspection issue and export error gives the one-based assembly range in segment and the affected interval in multicam. On an unsafe cut, inspect the error for the affected source, track, boundary and any nearby valid time. When multicam.switch_group_time is present, nearest holds group times for the switch at that instant. When multicam.edge is present, nearest holds group times for the from or to boundary of assembly range edge.range_number, or of that clip in an edit request, where a file clip uses its own source clock. A project without an assembly has one range covering the group, so save the adjusted range as its assembly. Every time in nearest is a valid cut for all selected streams at that boundary. Moving a boundary shifts later output times, so another unsafe boundary can be reported on the next run.",
              examples: [#"mpcut help multicam --json | jq '.project_template' > edit.cut"#,
                         "mpcut project inspect --project edit.cut --json",
                         projectSilenceExample,
                         "mpcut review frames export --project edit.cut --at 1 --at 3 --output review --json",
                         projectExportExample,
                         #"printf '%s' '{"clips":[{"project_path":"edit.cut","from":"2","to":"4"}],"output":"answer.mov"}' | mpcut export clips join --stdin --json"#],
              projectTemplate: multicamTemplate),
        .init(name: "waveform", purpose: "Read a signed amplitude envelope for a track or time window.",
              usage: ["mpcut waveform envelope read [--json] [--stream INDEX] [--from TIME] [--to TIME] [--columns N] [--] FILE"],
              instructions: ["Defaults to the whole source, first audio track and 1,024 columns. Choose 1–65,536 equal-width columns. Bound a detail request to the region under review."],
              result: "stream, sample_rate and columns identify the data. envelope.from and envelope.to are seconds. For column i, envelope.low[i] and envelope.high[i] are the minimum and maximum signed amplitudes across the selected track’s channels.",
              examples: ["mpcut waveform envelope read --json --from 2 --to 2.1 --columns 1024 narration.wav"]),
        .init(name: "silence", purpose: "Find quiet intervals, preview the plan, or export retained takes as one file.",
              usage: ["mpcut silence shorten --project FILE --out-project NEW.cut [--protect-pause ID] [--retain-pause ID=SECONDS] [--json]",
                      "mpcut silence scan (FILE | --project PROJECT) [--threshold-db DB] [--min-pause-seconds SEC] [--max-blip-seconds SEC] [--padding-per-side-seconds SEC] [--json]",
                      "mpcut silence scan --project PROJECT [--retain-pause ID=SECONDS] [--take-boundary TIME] [--json]",
                      "mpcut silence plan (FILE | --project PROJECT | --stdin | --input REPORT.json) [--output FILE] [--pauses-file LIST] [--threshold-db DB] [--min-pause-seconds SEC] [--max-blip-seconds SEC] [--padding-per-side-seconds SEC] [--json]",
                      "mpcut silence export FILE --output FILE \(mode(.cliSilence)) \(tracks) [--threshold-db DB] [--min-pause-seconds SEC] [--max-blip-seconds SEC] [--padding-per-side-seconds SEC] [--json]",
                      "mpcut silence plan --project PROJECT --output FILE \(mode(.cliSilence)) [--audio auto|copy|aac|pcm|remove] \(multicamAudioDeliveryUsage) [--json]",
                      "mpcut silence export --project PROJECT --output FILE \(mode(.cliSilence)) [--audio auto|copy|aac|pcm|remove] \(multicamAudioDeliveryUsage) [--threshold-db DB] [--min-pause-seconds SEC] [--max-blip-seconds SEC] [--padding-per-side-seconds SEC] [--json]",
                      "mpcut silence export (--stdin | --input REPORT.json) --output FILE \(mode(.cliSilence)) \(tracks) [--pauses-file LIST] [--padding-per-side-seconds SEC] [--json]"],
              instructions: ["The detector calibrates per recording and track and joins quiet stretches around sounds up to --max-blip-seconds seconds long (0–1, default 0.06, 0 disables). Each sound needs 0.16 s of quiet on both sides. --threshold-db overrides it (-120 to 0 dBFS). --min-pause-seconds is positive and defaults to 1.5 s. --padding-per-side-seconds is how much silence to keep on each side of a cut, default 0.2 s. --waveform adds 1–8192 peak-dBFS columns.",
                             "For a single file, --stdin accepts a saved report. Keep its file, source_stamp and duration. Remove entries from pauses to protect them or change --padding-per-side-seconds on replay. Use a new scan to change detector settings. \(ExportRules.modeHelp(.cliSilence)) Detection uses --stream when supplied, then --audio-stream, then the first audio track. A replay uses the saved detection stream and clips saved pauses to the selected output duration.",
                             "For a saved sequence, scan reports source and sequence pause ranges by occurrence. Pass --protect-pause ID to keep selected pauses and use silence shorten --out-project NEW.cut to save the retained timeline. For a sequence or multicam project, repeat --retain-pause ID=SECONDS to set the requested total retained silence per pause. In a project scan or plan without output, repeat --take-boundary TIME to divide retained takes on the original sequence or assembly clock.",
                             "Mix pauses require simultaneous quiet on all routed lanes. For multicam outputs, --audio and --audio-output set delivery independently of picture mode and preserve the lanes used for pause detection.",
                             "For multicam, the saved assembly and its routed soundtrack drive detection. With --output, error.segment and error.multicam.edge.range_number number the report's retained clips entries, and an unavailable export lists in error.alternatives the containers and the other mode that this command can write them with. The whole group is used when the project has no assembly. Each routed track uses its saved threshold when available and otherwise calibrates automatically. --threshold-db overrides all routed thresholds. --no-sidecar bypasses saved settings and cached analysis. \(ExportRules.displayName(mode: ExportRules.defaultMode(for: .multicam))) is the default. --mode copy plans cuts around keyframe boundaries. Use silence export --output to write retained ranges. Use silence plan --output to check the destination and cut plan. Stream, track, waveform and stdin options are for single-file silence workflows."],
              result: "Read threshold_mode, max_blip_seconds, pauses, removals, clips, removed_duration and skipped_pauses. clips are the retained ranges. Single-file reports include threshold_db and an optional waveform_peak_dbfs, where a null bin has no observed audio. Project reports include thresholds with source_id, file, audio_stream_index and threshold_db. In each project interval, assembly_index identifies the zero-based occurrence, group gives the group range and output gives its range on the original assembly clock. Inserted stills are retained and cards reports their original and shortened output intervals. Project reports with --output include preflight or still_preflight on the shortened output clock.",
              examples: ["mpcut silence scan --json --min-pause-seconds 2 --max-blip-seconds 0.30 --padding-per-side-seconds 0.2 interview.mov > pauses.json",
                         "mpcut silence plan --stdin --json --dry-run --output shortened.mov < pauses.json",
                         "mpcut silence export --stdin --json --output shortened.mov < pauses.json",
                         projectSilenceExample + " > project-pauses.json",
                         projectSilenceExample + " --output shortened-program.mov --dry-run",
                         projectSilenceExample + " --output shortened-program.mov"]),
        .init(name: "scenes", purpose: "Detect hard cuts, identify recurring views, or export clips by scene or view.",
              usage: ["mpcut scenes scan [--json] [--from TIME --to TIME] [--policy reuse|resume|restart] [--operation-id ID] [--progress none|stderr|jsonl] [--] FILE",
                      "mpcut scenes scan --project PROJECT [--all-sources | --clip-id ID | --camera-id ID] [--policy reuse|resume|restart] [--operation-id ID] [--progress none|stderr|jsonl] [--json]",
                      "mpcut scenes export [--json] [--scenes-file LIST] --export-to DIRECTORY [--group-by scene|view] [--subfolder NAME] [--base-name NAME] [--container EXT] \(tracks) [--dry-run] [--] FILE",
                      "mpcut scenes export (--stdin | --input REPORT.json) [--scenes-file LIST] [--json] --export-to DIRECTORY [--group-by scene|view] [--subfolder NAME] [--base-name NAME] [--container EXT] \(tracks) [--dry-run]"],
              instructions: ["A file range uses the source clock. Project scans default to all referenced video sources. Use a stable clip ID to scan that occurrence's source interval or a camera ID to scan that camera's recording.",
                             "Reuse is the default. It returns a current report or resumes an unfinished scan. Use --policy resume to continue a replacement or --policy restart to rescan the scope. A restart takes an optional operation ID for retries. Progress goes to stderr in text or JSON Lines. Ctrl-C returns exit 130 with the coverage saved so far.",
                             "A data-only scan writes the report to stdout. Save it and pass it unchanged on stdin for export, or keep a subset of its scenes in source order. The output directory must already exist. Default grouping writes one file per scene. view joins each view’s scenes in source order. " + ExportRules.modeHelp(.cliScenes) + " A scene that cannot be written lists error.alternatives, each with the clips to pass to export."],
              result: "File reports include scenes[] with number, start, end, start_pts, view and view_label. views[] lists scene numbers per view. A project scan returns sources[] with one outcome per video recording. Batch exports include scene_numbers and an export plan.",
              examples: ["mpcut scenes scan --json interview.mov > scenes.json", "mkdir -p shots", "mpcut scenes export --stdin --json --export-to shots --group-by view --dry-run < scenes.json"]),
        .init(name: "refresh", purpose: "Verify the media referenced by a saved project and refresh its indexes.",
              usage: ["mpcut project media refresh --project PROJECT [--deep] [--progress none|stderr|jsonl] [--no-sidecar] [--json]"],
              instructions: ["The default checks file identity and reindexes changed media. --deep verifies the contents even when file identity matches. Progress goes to stderr and the saved project is read-only."],
              result: "Read sources[] for each recording's refresh state, preserved analyses and references that need review.",
              examples: ["mpcut project media refresh --project edit.cut --json", "mpcut project media refresh --project edit.cut --deep --progress stderr"]),
        .init(name: "project media", purpose: "List, locate, relink or replace files referenced by a saved project.",
              usage: ["mpcut project media list PROJECT [--include-history] [--json]",
                      "mpcut project media relink PROJECT (--from OLD --to NEW | --map-prefix OLD=NEW) (--out-project FILE | --in-place) [--json]",
                      "mpcut project media locate PROJECT --folder DIR [--include-history] [--apply-matches (--out-project FILE | --in-place)] [--json]",
                      "mpcut project media replace PROJECT --source PATH --with FILE [--use-id ID] [--conform trim|keep] [--allow-loss | --loss remove|keep-offline] [--clock source-relative|source-timecode] [--stream-map OLD=NEW ...] [--reset-crop] [--replacement-offset TIME] [--shared-time-of-day] [--transcript keep-unverified|retranscribe] [--resync timecode|waveform] [--out-project FILE | --in-place] [--json]"],
              instructions: ["Use a stored project path or an absolute path for an existing media reference. New file and folder arguments resolve from the working directory.",
                             "Relink changes the location across the current edit and retained history. Repeat --from and --to for multiple pairs, or repeat --map-prefix for multiple folder roots. Locate searches recursively. --apply-matches applies unique verified and matched candidates. Add --include-history to list or locate paths used only in retained undo and redo states.",
                             "Replace previews the impact when you omit the destination. Choose --out-project FILE or --in-place to apply. For entirely out-of-range uses, --allow-loss removes them with trim or retains them offline with keep. Use --loss for an explicit choice. Read affected_use_ids and candidate_audio_streams to choose a single use or map absolute audio stream indices."],
              result: "Read sources[] for inventory, search and mapping results. Replace returns report. A successful write supplies out_project.",
              examples: ["mpcut project media list edit.cut --json",
                         "mpcut project media relink edit.cut --from camera.mov --to relocated/camera.mov --out-project relinked.cut",
                         "mpcut project media locate edit.cut --folder /Volumes/Archive --json",
                         "mpcut project media replace edit.cut --source camera.mov --with alternate.mov --json"]),
        .init(name: "frames", purpose: "Export JPEGs, or lossless PNG or TIFF frames with --format, and exact timestamps for source or multicam review.",
              usage: ["mpcut review frames export [--json] --output NEW_DIRECTORY [--preset review|full] [--format jpeg|png|tiff] [--at TIME ...] [--at-file LIST] [--] FILE",
                      "mpcut review frames export [--json] --output NEW_DIRECTORY [--select scenes|non-silent] [--sample first|midpoint] [--limit N] [--preset review|full] [--format jpeg|png|tiff] [--stream INDEX] [--threshold-db DB] [--min-pause-seconds SEC] [--] FILE",
                      "mpcut review frames export [--json] --project PROJECT [--clock sequence|assembly|group] --at TIME [--at TIME ...] --output NEW_DIRECTORY [--preset review|full] [--format jpeg|png|tiff]"],
              instructions: ["Default is a review JPEG at each scene midpoint. Review fits the long edge within 640 pixels at quality 0.62. Full uses display resolution at quality 0.95. --limit is positive and spreads images across the ranges. Supply one --at per explicit source time, without --select, --sample or --limit. Audio options apply only to non-silent ranges. Their defaults match silence detection. Both the JPEGs and manifest.json go into a new directory.",
                             "For a multicam project with tile processing, the default is the assembly clock. Both assembly and group clocks sample one rendered program frame per time. Other multicam projects default to the group clock, which returns a row for every angle, including coverage gaps. Use --clock assembly for the edited program and still placements. A sequence project uses the sequence clock."],
              result: "The stdout manifest matches manifest.json. frames[].file names a JPEG inside output_directory. Actual picture time and source PTS appear in frame_time and frame_pts where available. Single-source rows give clip_from and clip_to as frame-aligned export bounds, with range_number, scene_number and view_label where applicable. Angle-comparison rows give group_time, angle_id, source_time and availability in request order, then project angle order. Available rows give group_coverage, the half-open interval where that picture is visible on the group clock. See angles[] for the source path, offset, original timestamp origin, time base and source errors. Rendered Tiles rows report frame_time on the selected program clock and any applied privacy_issues.",
              examples: ["mpcut review frames export --json --select scenes --limit 12 --output overview interview.mov",
                         "mpcut review frames export --json --preset full --at 3/2 --output detail interview.mov",
                         "mpcut review frames export --json --project interview.cut --at 3/2 --at 3 --output angle-review",
                         "mpcut review frames export --json --preset full --format png --at 3/2 --output master-frame interview.mov"]),
        .init(name: "sidecar", purpose: "Save reusable analysis in the configured location or inspect available caches.",
              usage: ["mpcut analysis sidecar build [--json] [--project PROJECT] [--only index,scenes,audio | --only-file LIST] [--stream INDEX] [--min-pause-seconds SEC] [--threshold-db DB] [--] FILE",
                      "mpcut analysis sidecar inspect [--json] [--project PROJECT] [--] FILE"],
              instructions: ["Default save merges the complete editing index, scenes when video is present, and audio analyses for every audio track. Standalone audio saves a signed overview too. --only accepts a comma-separated subset. --stream and detector options apply when saving audio. The GUI can also save displayed filmstrip tiles, labels and settings.",
                             "Settings → Analysis selects next to media (FILE.cutdb), the project folder, or one shared cache disk. Supply --project PROJECT for project-folder writes. Inspection searches all known locations and is read-only. --no-sidecar disables automatic sidecar reads and writes on ordinary queries and can force fresh analysis for a save. Sidecar inspection requires sidecar access."],
              result: "Read sidecar, read_location, read_locations, write_location, status and inventory (has_index, has_scenes, waveform_streams, optional envelope_streams, silence settings and thumbnail_count). Status also includes source generations, stale reasons when available, and persisted scene attempts. saved lists sections written by a save.",
              examples: ["mpcut analysis sidecar build --json interview.mov", "mpcut analysis sidecar inspect --json interview.mov", "mpcut --no-sidecar scenes scan --json interview.mov"]),
        .init(name: "export", purpose: "Render a sequence or multicam project, join an ordered edit, remux selected tracks, convert video, or replace a soundtrack.",
              usage: ["mpcut export clips join [--json] [--dry-run] \(settings(.cliExport)) \(tracks) \(spacingUsage) --output FILE --clip FILE [--from TIME] [--to TIME] [--ranges LIST] [--clip FILE ...] [--order LIST]",
                      "mpcut export clips join --clips LIST --output FILE [--order-file LIST] \(spacingUsage) [--dry-run] [--json]",
                      "mpcut export clips join --input REQUEST.json [--dry-run] [--json]",
                      "mpcut export clips join --json --stdin [--dry-run] \(settings(.cliExport)) \(tracks) \(spacingUsage) [--order LIST]",
                      "mpcut export project render --project FILE --output FILE [--json] [--dry-run] \(projectUsage) \(spacingUsage) [--still-timing cadence|held] [--container EXT]",
                      "mpcut export project render (--input REQUEST.json [--json] | --stdin --json) [--dry-run]",
                      "mpcut export soundtrack replace [--json] [--dry-run] --clip MOVIE --replace-audio AUDIO [--replace-track INDEX] [--replacement-stream INDEX] --output FILE",
                      "mpcut export soundtrack replace (--input REQUEST.json [--json] | --stdin --json) [--dry-run]"],
              instructions: ["Run \(projectExportExample) to render the saved assembly or entire project range in a single call. Multicam defaults to \(ExportRules.displayName(mode: ExportRules.defaultMode(for: .multicam))) and uses exact boundaries. Use --dry-run to preview a plan whenever you want to check it before writing.",
                             "For still exports, --still-timing held writes one independently decodable sample per visible hold. Use cadence for regular frame timing. Smart Trim and Re-encode support explicit --video codec and --audio alac, flac or pcm when compatible with the container. Use --container to require a destination extension. JSON requests use still_timing and container. Dry runs report the planned format and sample counts. Completed still exports also report output_bytes.",
                             "Projects with a saved participant composition default to Re-encode. Export the current assembly as balanced H.264 in MOV, or use MP4 for silent picture. Dry runs report participant privacy coverage.",
                             "--ranges accepts CSV or JSON for the preceding clip. Use time for split points or from,to for ordered keep ranges. Times are relative to the clip in-point. Headers are optional.",
                             "--from and --to belong to the preceding --clip. Omitted edges use the source edges. \(ExportRules.modeHelp(.cliExport)) Boundaries are exact unless snap says otherwise. An explicit one-based --order can omit or repeat clips. --snap nearest authorizes changing cut times for eligible copy/smart edits.",
                             "--space-clips source fills forward gaps with black and silence. Select chronological ranges from the same file or multicam group. --space-clips DURATION sets the same gap between every pair of consecutive clips. Use 0 to remove gaps between clips in a saved project. Spacing is applied in playback order and leaves the saved project unchanged. For generated gaps, the default Smart Trim export requires all retained camera picture to copy. Use --mode encode to allow re-encoding it. Constant-rate footage needs gap durations aligned to the frame cadence.",
                             selection, encoding,
                             "For --stdin supply output and either a saved project path under project_path or a nonempty clips array. A saved project request also accepts require_camera_copy. Each clip accepts file or project_path, plus from and to. Top-level file supplies the default source for file clips. Optional top-level keys are order, mode, snap, video, quality, audio, tracks, audio_stream, replace_audio, replace_track, replacement_stream and space_clips. Flag values and JSON fields must agree. Keys must be unique. Use an output extension to choose the container.",
                             "Use project clips on stdin to select ranges on the original multicam group clock. Those clips include visible Replace Picture edits on that clock. To render the saved assembly with Insert Still edits, use the top-level project_path field or the --project flag. See help multicam for the project template and audio policies.",
                             "Replacement substitutes a matching-duration external track in the source before any cuts or joins. The first audio track in each file is the default. --replace-track and --replacement-stream take absolute indices. Keep all source tracks and use copy mode. --replace-audio binds to the first input source, including repeated and trimmed uses. On stdin each file clip can specify replace_audio, replace_track and replacement_stream to bind other sources. Timing, container and decoder priming must permit the substitution.",
                             "For whole-source replacement, dry-run checks the plan and muxer. Actual export verifies the written tracks before publishing. Ranged replacement also prepares temporary lossless working copies during dry-run to resolve the final cut boundaries."],
              result: exportResult + " " + projectExportResult + " For whole-source substitution read replacement.target_stream, replacement.replacement_stream and replacement.replacement_codec in place of segments.",
              examples: ["mpcut export clips join --json --mode smart --snap nearest --dry-run --output select.mov --clip interview.mov --from 1 --to 3",
                         "mpcut export clips join --space-clips source --clip interview.mov --from 10:03 --to 10:10 --clip interview.mov --from 10:35 --to 10:38 --output spaced.mov --dry-run",
                         #"printf '%s' '{"file":"interview.mov","clips":[{"from":"1","to":"2"},{"from":"3","to":"4"}],"order":[2,1],"snap":"nearest","output":"assembly.mov"}' | mpcut export clips join --stdin --json --dry-run"#,
                         "mpcut export clips join --json --tracks audio --audio-stream 1 --clip interview.mov --output dialogue.m4a",
                         "mpcut export clips join --json --tracks video --clip interview.mov --output picture.mov",
                         "mpcut export clips join --json --mode encode --clip talk.mp3 --from 1 --to 5 --clip talk.mp3 --from 9 --to 12 --output talk-edit.mp3 --dry-run",
                         "mpcut export soundtrack replace --json --replace-audio processed.wav --replace-track 1 --clip interview.mov --output new-mix.mov --dry-run",
                         "mpcut export clips join --json --mode encode --video hevc --quality balanced --audio auto --clip interview.mov --output encoded.mp4 --dry-run"],
              stdinExample: EditExample(output: "assembly.mov", clips: [[:]], mode: "copy")),
        .init(name: "rearrange", purpose: "Select, reorder or repeat ranges from one recording in a single output.",
              usage: ["mpcut export ranges join [--json] [--dry-run] [--snap exact|nearest] \(tracks) FILE --output FILE (--ranges LIST | 'FROM-TO,FROM-TO')"],
              instructions: ["Supply --ranges LIST.csv or LIST.json, or inline FROM-TO pairs. The ranges define playback order. " + ExportRules.modeHelp(.cliRearrange) + " Video cuts snap to the nearest boundary by default. For multiple sources or another mode use export clips join. " + selection],
              result: exportResult, examples: ["mpcut export ranges join --json interview.mov --output reordered.mov '3-4,1-2' --dry-run"]),
        .init(name: "bulk", purpose: "Write separate numbered files for timestamp ranges from one recording.",
              usage: ["mpcut export ranges separate SOURCE --ranges LIST --output DIRECTORY [--subfolder NAME] [--base-name NAME] [--container EXT] [--dry-run] [--json] \(settings(.cliBulk)) \(tracks)",
                      "mpcut export ranges separate --input REQUEST.json [--dry-run] [--json]",
                      "mpcut export ranges separate --stdin --json [--dry-run] \(settings(.cliBulk)) \(tracks)"],
              instructions: ["Send file, output_directory and a nonempty ranges array on stdin. Each range requires from and to. Optional keys are container (extension without a dot), mode, snap, video, quality, audio, tracks and audio_stream. The destination directory must already exist. Input array order controls numbering. Optional subfolder and base_name strings (flags --subfolder and --base-name) create paths like Review/Interview-001.mov. Dry-run previews paths without creating the subfolder.",
                             ExportRules.modeHelp(.cliBulk) + " Boundaries are exact unless snap says otherwise. All ranges and destinations are checked before writing. A runtime failure may leave completed files. " + selection, encoding],
              result: "Read outputs[] for each export plan. On a mid-batch failure, outputs lists completed items. Inspect failed_range and error before retrying.",
              examples: ["mkdir -p clips", #"printf '%s' '{"file":"interview.mov","output_directory":"clips","snap":"nearest","ranges":[{"from":"1","to":"2"},{"from":"3","to":"4"}]}' | mpcut export ranges separate --stdin --json --dry-run"#],
              stdinExample: EditExample(outputDirectory: "clips", ranges: [["from": "1", "to": "2"]], mode: "smart", snap: "nearest"))
    ]

    static let commands: [CommandHelp] = {
        var topics = families.filter { ["help", "--version", "multicam", "participants", "tiles"].contains($0.name) }
        for path in CommandPath.paths.sorted() {
            let prefix = "mpcut " + path
            guard let family = families.first(where: {
                $0.name != "multicam" && $0.usage.contains { $0 == prefix || $0.hasPrefix(prefix + " ") }
            }) else { preconditionFailure("Missing command reference for " + path) }
            var usage = family.usage.filter { $0 == prefix || $0.hasPrefix(prefix + " ") }
            if CommandPath.transcript[path] != nil || CommandPath.participants[path] != nil || CommandPath.tiles[path] != nil {
                let requestUsage = prefix + " (--stdin | --input REQUEST.json) [--json]"
                if !usage.contains(requestUsage) { usage.append(requestUsage) }
            }
            var examples = family.examples.filter { $0.contains(prefix + " ") }
            if let options = exampleOptions[path] { examples.append(prefix + " " + options) }
            let template: EditExample?
            switch path {
            case "export project render":
                template = EditExample(file: nil, projectPath: "edit.cut", output: "finished.mov")
            case "export soundtrack replace":
                template = EditExample(replaceAudio: "new-mix.wav", output: "replaced.mov", clips: [[:]], mode: "copy")
            default:
                template = family.stdinExample
            }
            var instructions = family.instructions
            if path == "tiles accept" {
                instructions.append("Supply a scan, revised count hints, or --clear-count-hints. A hint edit without a scan preserves the accepted tiles and feed IDs.")
                examples.append("mpcut tiles accept --project reviewed.cut --clear-count-hints --in-place")
            }
            topics.append(.init(name: path, purpose: purposes[path] ?? family.purpose, usage: usage,
                                instructions: instructions, result: family.result,
                                examples: examples, stdinExample: template))
        }
        return topics
    }()

    private static let exampleOptions = [
        "export project render": "--project interview.cut --output interview.mov --dry-run",
        "project resolve export": "--project interview.cut --output interview.fcpxml",
        "silence shorten": "--project interview.cut --out-project shortened.cut --json",
        "still asset relink": "--project interview.cut --asset photo --image relocated.png --out-project relinked.cut",
        "still placement list": "--project interview.cut",
        "still placement remove": "--project interview.cut --placement title --out-project edited.cut",
        "still placement update": "--project interview.cut --placement title --duration 3 --out-project title.cut",
        "still project create": "--image photo.png --width 1920 --height 1080 --rate 30 --codec h264 --container mov --duration 2 --out-project still.cut",
        "still soundtrack attach": "--project cover.cut --soundtrack recording.wav --fit-soundtrack --in-place",
        "still soundtrack fit": "--project cover.cut --in-place",
        "still soundtrack detach": "--project cover.cut --out-project silent.cut",
        "timeline gap insert": "--project interview.cut --clock sequence --at 1 --duration 2 --out-project gap.cut",
        "transcript attachment bind": "--project interview.cut --attachment-id session --track-id mic --source-id camera --audio-stream-index 1 --out-project bound.cut",
        "transcript attachment detach": "--project interview.cut --attachment-id session --out-project detached.cut",
        "transcript attachment inspect": "--project interview.cut --attachment-id session",
        "transcript excerpt queue": "--project interview.cut --first-word-id word-0 --name opening --out-project opening.cut",
        "transcript job cancel": "--job-id 8764D90A-1612-4129-B353-AD54BF7AA763",
        "transcript job retry": "--project interview.cut --job-id 8764D90A-1612-4129-B353-AD54BF7AA763",
        "transcript job run": "--job-id 8764D90A-1612-4129-B353-AD54BF7AA763 --job-directory ./jobs --json",
        "transcript job status": "--job-id 8764D90A-1612-4129-B353-AD54BF7AA763",
        "transcript provider capabilities": "--json",
        "transcript script align": "--project interview.cut --script-file script.txt",
        "transcript tracks list": "--project interview.cut",
        "transcript words compare": "--project interview.cut --query introduction",
        "transcript words locate": "--project interview.cut --word-id word-0",
        "transcript words read": "--project interview.cut --limit 20",
        "transcript words select": "--project interview.cut --first-word-id word-0 --last-word-id word-4",
        "transcript words suggest": "--project interview.cut --filler-terms um,uh"
    ]

    private static let purposes = [
        "project media list": "Report project media paths, availability and uses.",
        "project media locate": "Search a folder recursively for missing project media.",
        "project media relink": "Update the location of project media across current and retained edits.",
        "project media replace": "Preview or apply a different recording or image.",
        "silence scan": "Detect quiet intervals in a file or project soundtrack.",
        "silence plan": "Calculate retained ranges and optionally preflight a proposed output.",
        "silence export": "Render retained ranges to a new media file.",
        "scenes scan": "Detect scene boundaries and recurring views.",
        "scenes export": "Write grouped footage from scene ranges.",
        "project resolve export": "Write an editable Resolve timeline.",
        "project resolve import": "Write the timeline and import it into the current Resolve project.",
        "analysis sidecar inspect": "Read the inventory of cached analysis.",
        "analysis sidecar build": "Compute analysis and save it in the configured location.",
        "export project render": "Render a saved project to media.",
        "export clips join": "Write ordered clips to a single media file.",
        "export soundtrack replace": "Write media using a replacement soundtrack."
    ]

    static func topic(_ name: String) throws -> CommandHelp {
        if let entry = commands.first(where: { $0.name == name }) { return entry }
        let matches = commands.filter { $0.name.hasPrefix(name + " ") }
        guard !matches.isEmpty else {
            throw CLIError("invalid_arguments", "Unknown help topic '\(name)'. Use mpcut help to list commands.")
        }
        return .init(name: name, purpose: "Command family", usage: matches.flatMap(\.usage),
                     instructions: matches.map { $0.name + " — " + $0.purpose }, result: "Choose a command path to see its output fields.",
                     examples: matches.flatMap(\.examples))
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
            case "multicam", "participants", "tiles": invocation = "help " + command.name
            default: invocation = command.name
            }
            return "  \(invocation)  —  \(command.purpose)"
        }
        return (["MPCut " + Arguments.version, "Usage: mpcut COMMAND [OPTIONS]", ""] + list
            + ["", "Agent workflow"] + conventions).joined(separator: "\n")
    }
}
