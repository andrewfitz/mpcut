# Frame editing and export modes

On first launch, the desktop app starts with **Snap To → Off** and **Smart Trim** for video. Change these defaults in **MPCut → Settings… → General**. Standalone audio uses **Lossless Copy**. [Editor settings](USAGE.md#set-editing-and-export-defaults)

## Timeline

Choose **Off**, **Keyframes**, **Scenes**, or **Silence** in the **Snap To** menu beside timeline zoom. Choose the export mode in the export sheet.

- With snapping off, a trim handle lands on the nearest actual source-frame boundary. Use presentation timestamps for variable-frame-rate footage. The preview shows the first retained frame at the left handle and the last retained frame at the right handle. The right boundary is exclusive.
- With **Keyframes** selected, a handle lands on a verified copy-safe boundary for that edge and the current sequence, using the preferred copy container. The preview shows the effective time and picture during the drag. Splits and marked deletions follow the same rule. If linked audio prevents the cut, MPCut identifies the affected track.
- **Scenes** and **Silence** use detected scene changes or pause edges. Video edits follow picture boundaries. On an audio-only timeline, use **Off** or **Silence** with the audio edit clock.
- On video timelines, scrubbing, frame stepping, keyframe stepping, and placing marks are available with any snap target. Changing the target affects subsequent edits. Previously chosen ranges stay where the user placed them. Dragging into faded footage still restores it.

## Export sheet

From an ordinary timeline, press **⌘E** to choose the filename, location, mode, and container. The sheet uses the preferred movie export mode when the timeline supports it. It checks the selected container against the timeline being exported. Use **File → Export Media As** to open it in a particular mode.

| Mode | Result | Information in the sheet |
| --- | --- | --- |
| Smart Trim | Copies complete sections and encodes the necessary video edges at a source-matched bitrate on supported footage. Copies the entire range when all cuts are safe, including frame-aligned ProRes. | Copied and encoded video duration, with a message when every selected picture needs encoding. |
| Lossless Copy | Copies the retained picture and sound into a compatible container. Use it to remux a whole file. | Duration and container. For an unsafe cut, review the clip, time and verified alternatives when available. |
| Re-encode | Encodes the retained timeline with the selected hardware video encoder. | Video codec, quality, output dimensions, and the planned action for each audio track. |

Changing a mode or cancelling the sheet preserves the edit. If Lossless Copy requires different bounds, choose **Review Cuts** to compare the original and proposed times and total duration change. **Apply to Timeline** makes one undoable edit and returns to the timeline for preview. To keep the original ranges, choose another eligible mode. When a mode is unavailable, the sheet offers the first working alternative as a button and lists further choices under **More Alternatives**. The CLI reports the same alternatives in the same order in `error.alternatives`. For the complete list of containers, audio actions and alternatives by source type, see [Export rules](EXPORT-RULES.md).

With audio alone, **Mode** offers **Lossless Copy** and **Convert Audio**. Convert Audio decodes the kept ranges to the sample and writes MP3, AAC, FLAC, Opus or PCM. MP3 and AAC keep the source sample rate, channels and bit rate where the source states one. Opus is written at 48 kHz in mono, stereo or a surround layout Opus defines (3.0, quad, 5.0, 5.1, 6.1 or 7.1), at the customary bit rate nearest the average of an Opus source. A soundtrack inside a movie is matched by the size of its own packets. FLAC and PCM from a lossless source return the same samples. For ordinary footage, selecting only video uses Lossless Copy. With visible stills, use Smart Trim or Re-encode to generate those frames.

Use the **Video** and **Audio** checkboxes to select the track types to export. Select audio alone to copy or convert the soundtrack of a movie. With audio alone, the **Tracks** picker can select one soundtrack from a multitrack recording. The export queue offers the same track choices for a batch. To swap one soundtrack in a whole movie and preserve its start time, use **File → Replace Source Audio…** or the CLI's `export soundtrack replace --replace-audio`. [Track export and replacement](USAGE.md#edit-audio-and-export-tracks)

## Basic conversion settings

| Setting | Supported choices |
| --- | --- |
| Container | MP4, MOV or MKV for H.264 and HEVC. MOV or MKV for ProRes. Copy and Smart Trim support other compatible containers, including WebM. |
| Video | H.264, HEVC or ProRes via VideoToolbox. Availability depends on the Mac, container and source format. |
| Quality | Smaller File, Balanced, High Quality for H.264 and HEVC. Use 422 LT, 422 and 422 HQ for ProRes. |
| Audio | Auto, Copy Original, AAC, PCM, Remove Audio. Use Remove Audio to re-encode the picture without a soundtrack. Auto copies audio when the edit and destination permit it. The sheet shows which tracks need conversion. |

Conversion starts with MP4, H.264, Balanced and Auto audio. ProRes starts with MOV and the 422 profile. Auto uses PCM when ProRes output needs audio conversion. Preflight checks display orientation, resolution, frame timing, and color against the selected format. It rejects combinations that would discard alpha, such as a transparent source with a ProRes 422 output profile.

For a sequence of clips with different codecs, resolutions, orientations, or audio layouts, use Re-encode. It fits each picture to the first clip’s display size, retains each frame’s timing, and converts the sound to a common format. Clips that mix SDR with HDR, or PQ with HLG, require separate exports. [Mixed timelines](EXPORT-RULES.md#mixed-timelines)

## CLI defaults and preflight

| Request | Default mode and boundaries |
| --- | --- |
| `export clips join`, with or without `--order` | Smart Trim at exact boundaries for video. Lossless Copy for audio-only recordings. |
| `export project render --project` or `export clips join --stdin` with multicam project clips | Smart Trim at exact boundaries |
| `export ranges separate`, scene exports | Smart Trim at exact boundaries for video |
| Silence exports | Smart Trim for video. The planner chooses eligible boundaries inside the detected pauses |
| `export ranges join` | Smart Trim with nearest boundaries for video |
| Explicit `--tracks audio` or `--tracks video` | Copy the selected streams by default for ordinary footage. Use `--tracks audio --mode encode` to convert a movie soundtrack. |
| `export soundtrack replace --replace-audio` | Copy a matching track into a new version of the whole source |

Use `mpcut help export clips join --json` for supported combinations and a request template. An export validates the edit and destination before writing. Add `--dry-run --json` to review its resolved ranges, copied and encoded durations, and per-track actions without writing the output. Conversion checks hardware availability on the Mac running the command.

## Multicam exports

Multicam resolves picture and sound separately on the same output clock. Preflight checks each audio lane across every retained range. A picture switch inside a continuous sound span creates no audio boundary. A recording rollover, a replacement join or an assembly jump can create an audio boundary that must be checked.

When an angle contains separate recordings, a selected interval between them can render as timed black in Re-encode mode with MOV, MP4 or M4V. The result lists `generated_picture_gaps` in output time. Copy and Smart Trim report `recording_gap_requires_encoding`.

From the CLI, `mpcut export project render --project interview.cut --output interview.mov --json` validates and writes the saved assembly, or the whole group if there is no assembly. Add `--dry-run` for a preflight with the same settings. With `--stdin`, a top-level `project_path` renders the saved assembly, including still inserts. Project entries in a `clips` array select ranges on the original group clock and carry visible picture replacements.

In a multicam window, press **⌘E** to open the **Export** inspector. Choose **Current assembly**, **Whole group**, or **Selected range**, then run **Check Export** or go directly to **Export…**. The inspector uses the current edit, including unsaved changes. For full conversion of a program without visible stills, run **Check Re-encode** to enable **Export Re-encoded…**. With visible stills, choose **Re-encode** in **Mode**, then use **Check Export** or **Export…**. Use **Export Queue** (⇧⌘E) to preflight and export multiple selections to separate numbered files. [Multicam export queue](USAGE.md#queue-multicam-exports-and-replace-the-soundtrack)

| Mode | Requirements for a multicam project |
| --- | --- |
| Smart Trim | The chosen picture boundaries must be exact and the selected video streams compatible. MPCut copies safe ranges and encodes supported video edges as needed. |
| Lossless Copy | At each picture switch, both the outgoing end and incoming start must be copy-safe at the same group time. Choose a new switch time explicitly if preflight suggests one. |
| Re-encode | The selected video streams must meet the conversion planner’s compatibility checks. |

**Audio output** defaults to **Separate tracks**. It delivers each selected lane as a separately selectable track. **Downmix to mono** and **Downmix to stereo** average the lanes into one rendered track. Players typically select only one of the separate tracks for playback. Use a downmix to deliver the combined preview sound.

With separate tracks, **Copy** checks each lane’s codec and actual sound boundaries. **Auto** chooses copy or an eligible render treatment for each lane. Dry run reports the treatment and identifies ranges that require generated silence. Explicit **AAC** or **PCM** renders all selected sound in that codec, and **Remove audio** omits sound. MOV supports rendered AAC or PCM. MP4 and M4V support rendered AAC. MKV supports rendered PCM. WebM requires audio streams eligible for copy.

`--tracks video` selects picture only. `--tracks audio` selects sound only. [Visible stills](EXPORT-RULES.md#visible-still-placements) have their own track rules. Multicam CLI requests use exact cuts. When preflight reports an unsafe boundary, review its suggested group times and apply the chosen time to the project or request before exporting. Picture export supports MOV, MP4, M4V, MKV or WebM when the selected tracks are eligible for the container. Single-track containers require a one-track delivery. [Multicam CLI examples](CLI.md#choose-a-mode-container-and-tracks)

The shared integration suite compares packet hashes, decoded samples and picture order, including variable frame rate, rotation, linked audio, and unavailable encoders. [Release checks](../AUDIT.md#reproduce-the-release-checks)

## Save the export result and cut map

In a sequence or multicam media save dialog, select **Save Export Result JSON** to write the render plan and cut map beside the movie or soundtrack. For example, exporting `Assembly.mov` writes `Assembly.mov.export.json`. Choose a different media name if the result file already exists.

Successful CLI project and clip-join JSON exports and live MCP project export jobs include `cut_map` alongside their resolved plan or segments. A successful dry run includes the same map without writing media. The map keeps repeated occurrences distinct and identifies saved sequence clips by ID. Multiple occurrences can point to the same one-based render segment when adjacent source ranges share decoder state. Their individual source and output ranges still show where the timeline was split. Multicam assembly ranges use group time and retain their order. A still insert appears as its own generated occurrence. The still render plan gives the picture replacement coverage. Times are exact rational seconds with exclusive ends.
