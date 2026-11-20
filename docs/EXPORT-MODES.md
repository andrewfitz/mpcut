# Frame editing and export modes

Proposed design for the next MPCut update. A new GUI session starts with **Snap to Keyframes** off and **Smart Trim** selected for export.

## Timeline

Put one **Snap to Keyframes** checkbox beside timeline zoom. Put the three export modes in the export sheet. Each control has one job.

- With snapping off, a trim handle lands on the nearest actual source-frame boundary. Use presentation timestamps for variable-frame-rate footage. The preview shows the first retained frame at the left handle and the last retained frame at the right handle. The right boundary is exclusive.
- With snapping on, a handle lands on a verified copy-safe boundary for that edge and the current sequence, using the preferred copy container. Show the effective time and picture during the drag. Apply the same rule when committing a split or marked deletion. If a linked audio track prevents a cut, identify the affected track.
- Scrubbing, frame stepping, keyframe stepping, and placing marks remain available in either state. Changing the checkbox affects subsequent edits. Previously chosen ranges stay where the user placed them. Dragging into faded footage still restores it.

## Export sheet

Use one native save sheet with filename, location, mode, and container. Remember the last explicit choice within the open session. Recheck availability for the selected container and the entire timeline.

| Mode | Result | Information in the sheet |
| --- | --- | --- |
| Smart Trim | Copy complete sections. Encode the necessary video edges at a source-matched bitrate on supported footage. Copy the entire range when all cuts are safe, including frame-aligned ProRes. | Show copied duration and encoded duration. If a short selection needs every frame encoded, show that before export. |
| Lossless Copy | Copy the retained picture and sound into a compatible container. This is also the whole-file remux path. | Show the duration and container. If a cut is unsafe, identify its clip, time and nearest verified alternatives. |
| Re-encode | Encode the complete retained video timeline with the selected hardware encoder. Audio follows the displayed audio setting. | Show the codec, quality, effective audio choice, and output dimensions. |

Changing a mode or cancelling the sheet preserves the edit. If Lossless Copy requires different bounds, offer **Review Cuts** with the original and proposed times and total duration change. **Apply to Timeline** makes one undoable edit and returns to the timeline for preview. The user can also keep their cuts and select any eligible mode. If Smart Trim cannot handle a particular edge or audio join, name the reason and offer Re-encode explicitly.

## Basic conversion settings

| Setting | Proposed first version |
| --- | --- |
| Container | MP4, MOV, MKV for conversion. Copy and Smart Trim retain the existing compatible containers, including WebM. |
| Video | H.264, HEVC, ProRes via VideoToolbox. Offer combinations verified for the selected Mac, output container and source format. |
| Quality | Smaller File, Balanced, High Quality for H.264 and HEVC. Use 422 LT, 422 and 422 HQ for ProRes. |
| Audio | Auto, Copy Original, AAC, PCM, Remove Audio. Auto prefers exact copying. Otherwise it shows the chosen conversion before export. Preserve linked tracks, channel layouts and sync. |

Default to MP4, H.264, Balanced and Auto audio for ordinary SDR footage. Selecting ProRes suggests MOV, ProRes 422 and PCM when audio needs conversion. Carry through display orientation, resolution, frame timing and color where the selected combination can represent them. Flag incompatible choices such as an alpha source with a 422 output profile. Keep the existing compatible-clip timeline and RAW exclusion.

## Implementation and acceptance

1. Store the ordered source ranges at frame precision. Today the editor validates ordinary handle drags and imports through the copy planner. Split basic timeline validity from mode-specific export eligibility, so a playable clip can be edited for conversion even when a packet-copy join is impossible.
2. Extend the shared preflight to report the effective mode, ranges, copied and encoded durations, and per-track actions or reasons. Reuse the existing copy and Smart Trim writers. The GUI defaults to Smart Trim. Existing CLI commands keep the copy-only default, `--smart-trim` remains an alias, and explicit `--mode copy|smart|encode` works with dry runs and JSON.
3. Bundle the arm64 FFmpeg executable and capabilities needed for conversion. The current shipping build contains media libraries and selected edge encoders. Pass structured arguments directly to the helper. Honor exact ordered ranges, feed the video encoder once across the assembled sequence, and support progress, cancellation and staged output. Check actual hardware encoder availability before starting.
4. On a long-GOP clip, drag to 3.000 s between safe points at 0 and 5 s. Verify both handles, preview, split, delete and undo with snapping off and on. Open and cancel each export mode and compare the saved frame bounds. With Smart Trim, hash the copied middle. With Lossless Copy, hash retained packets. With Re-encode, verify first and last pictures, total frames, A/V sync and orientation. Include a VFR clip, rotated footage, ProRes, a discontinuous audio join, and a Mac or configuration lacking the selected encoder.
