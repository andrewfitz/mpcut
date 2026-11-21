# Frame editing and export modes

On first launch, the desktop app starts with **Snap To → Off** and **Smart Trim** for video. Change these defaults in **MPCut → Settings… → General**. Standalone audio uses **Lossless Copy**. [Editor settings](USAGE.md#set-editing-and-export-defaults)

## Timeline

Choose **Off**, **Keyframes**, **Scenes**, or **Silence** in the **Snap To** menu beside timeline zoom. Choose the export mode in the export sheet.

- With snapping off, a trim handle lands on the nearest actual source-frame boundary. Use presentation timestamps for variable-frame-rate footage. The preview shows the first retained frame at the left handle and the last retained frame at the right handle. The right boundary is exclusive.
- With **Keyframes** selected, a handle lands on a verified copy-safe boundary for that edge and the current sequence, using the preferred copy container. The preview shows the effective time and picture during the drag. Splits and marked deletions follow the same rule. If linked audio prevents the cut, MPCut identifies the affected track.
- **Scenes** and **Silence** use detected scene changes or pause edges. Video edits follow picture boundaries. On an audio-only timeline, use **Off** or **Silence** with the audio edit clock.
- On video timelines, scrubbing, frame stepping, keyframe stepping, and placing marks are available with any snap target. Changing the target affects subsequent edits. Previously chosen ranges stay where the user placed them. Dragging into faded footage still restores it.

## Export sheet

From an ordinary timeline, press **⌘E** to choose the filename, location, mode, and container. The sheet starts with the movie export mode from Settings and checks the selected container against the entire timeline. Use **File → Export Media As** to open it in a particular mode.

| Mode | Result | Information in the sheet |
| --- | --- | --- |
| Smart Trim | Copies complete sections and encodes the necessary video edges at a source-matched bitrate on supported footage. Copies the entire range when all cuts are safe, including frame-aligned ProRes. | Copied and encoded video duration, with a message when every selected picture needs encoding. |
| Lossless Copy | Copies the retained picture and sound into a compatible container. Use it to remux a whole file. | Duration and container. For an unsafe cut, review the clip, time and verified alternatives when available. |
| Re-encode | Encodes the retained timeline with the selected hardware video encoder. | Video codec, quality, output dimensions, and the planned action for each audio track. |

Changing a mode or cancelling the sheet preserves the edit. If Lossless Copy requires different bounds, choose **Review Cuts** to compare the original and proposed times and total duration change. **Apply to Timeline** makes one undoable edit and returns to the timeline for preview. To keep the original ranges, choose another eligible mode. If Smart Trim reports an unsupported edge or audio join, preflight Re-encode.

The **Video** and **Audio** checkboxes also let you copy just one track type into an eligible container. With audio alone, the **Tracks** picker can select one soundtrack from a multitrack recording. The export queue offers the same track choices for a batch. To swap one soundtrack in a whole movie and preserve its start time, use **File → Replace Source Audio…** or the CLI's `export --replace-audio`. [Track export and replacement](USAGE.md#edit-audio-and-export-tracks)

## Basic conversion settings

| Setting | Supported choices |
| --- | --- |
| Container | MP4, MOV or MKV for H.264 and HEVC. MOV or MKV for ProRes. Copy and Smart Trim support other compatible containers, including WebM. |
| Video | H.264, HEVC or ProRes via VideoToolbox. Availability depends on the Mac, container and source format. |
| Quality | Smaller File, Balanced, High Quality for H.264 and HEVC. Use 422 LT, 422 and 422 HQ for ProRes. |
| Audio | Auto, Copy Original, AAC, PCM. Clear Audio in the desktop export sheet to copy only the picture. Auto copies audio when the edit and destination permit it. The sheet shows which tracks need conversion. |

Conversion starts with MP4, H.264, Balanced and Auto audio. ProRes starts with MOV and the 422 profile. Auto uses PCM when ProRes output needs audio conversion. Preflight checks display orientation, resolution, frame timing, and color against the selected format. It rejects combinations that would discard alpha, such as a transparent source with a ProRes 422 output profile.

## CLI defaults and preflight

| Request | Default mode and boundaries |
| --- | --- |
| Ordinary `export` without an explicit order | Copy at exact boundaries |
| `export --project` or `export --stdin` with multicam project clips | Smart Trim at exact boundaries |
| `export --order`, `bulk`, scene exports | Smart Trim at exact boundaries for video |
| Silence exports | Smart Trim for video. The planner chooses eligible boundaries inside the detected pauses |
| `rearrange` | Smart Trim with nearest boundaries for video |
| Explicit `--tracks audio` or `--tracks video` | Copy the selected streams |
| `export --replace-audio` | Copy a matching track into a new version of the whole source |

Use `mpcut help export --json` for supported combinations and a request template. An export validates the edit and destination before writing. Add `--dry-run --json` to review its resolved ranges, copied and encoded durations, and per-track actions without writing the output. Conversion checks hardware availability on the Mac running the command.

## Multicam exports

Multicam resolves picture and sound separately on the same output clock. A continuous fixed master is checked across each retained range, independent of camera switches. Audio joins still need validation when the soundtrack changes or the assembly jumps in time.

From the CLI, `mpcut export --project interview.multicam.json --output interview.mov --json` validates and writes the saved assembly, or the whole group if there is no assembly. Add `--dry-run` for an optional preflight with the same settings. In a multicam window, press **⌘E** to open the **Export** inspector. Choose **Current assembly** or **Whole group**, then run **Check Export** or go directly to **Export…**. Both choices use the current edit, including unsaved changes. For full conversion in the inspector, run **Check Re-encode** to enable **Export Re-encoded…**. Use **Export Queue** (⇧⌘E) to preflight and export multiple selections to separate numbered files. [Multicam export queue](USAGE.md#queue-multicam-exports-and-replace-the-soundtrack)

| Mode | Requirements for a multicam project |
| --- | --- |
| Smart Trim | The chosen picture boundaries must be exact and the selected video streams compatible. MPCut copies safe ranges and encodes supported video edges as needed. Sound must support copy at its own boundaries. |
| Lossless Copy | At each picture switch, both the outgoing end and incoming start must be copy-safe at the same group time. Choose a new switch time explicitly if preflight suggests one. Real audio joins must also be copy-safe. |
| Re-encode | The selected video streams must fit the conversion planner's compatibility checks. `--audio auto` and `--audio copy` require sound that can be copied. Choose `--audio aac` for AAC in MOV, MP4, or M4V, `--audio pcm` for PCM in MOV or MKV, or `--audio remove` to encode just the picture. |

`--tracks video` checks and copies only picture. `--tracks audio` checks and copies only the project's selected sound. With one track type, omit `--mode` or choose `--mode copy`. Change soundtrack sources in the project. For project cuts, submit revised times explicitly when preflight reports an unsafe boundary. The CLI accepts MOV, MP4, M4V, MKV, or WebM when both tracks are eligible for the container. The desktop inspector offers MOV, MP4, M4V and MKV, with WAV also available for sound-only export. [Multicam CLI examples](USAGE.md#inspect-and-export-a-project-from-the-cli)

The shared integration suite compares packet hashes, decoded samples and picture order, including variable frame rate, rotation, linked audio, and unavailable encoders. [Release checks](../AUDIT.md#reproduce-the-release-checks)
