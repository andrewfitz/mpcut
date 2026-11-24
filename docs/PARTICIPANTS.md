# Edit camera feeds and recorded video calls

Open the recording in MPCut, select **Feeds** to open **Feeds & Participants**, and choose **Scan Participants** at the source you want to analyze. Before you accept a scan, the monitor outlines its detected boxes in orange. Review the boxes and roster before choosing **Accept Geometry**. If a guest returns under another track, select their appearance, set the source-time correction range and link it to the existing participant. Use **Before Reflow** and **After Reflow** to inspect a layout change. Save the project to retain accepted geometry and corrections.

The inspector shows the scan stage and a percentage bar. During scanning the percentage follows the recording’s source time, including stretches skipped by adaptive or sparse sampling. Desktop scans always use adaptive sampling. To check every frame, for example before delivering a redaction, scan from the CLI or MCP with every-frame sampling and accept that scan. A matching saved scan can jump directly to 100% after verification. A fresh scan shows 100% when the geometry is ready for review. Cancel pauses the scan. Resume Scan replays the saved prefix to reconstruct the tracker, so its progress bar starts again at the beginning. For a command-line scan, use `--progress stderr` to watch percentages or `--progress jsonl` for structured events on standard error. Each event reports its phase: `preparing`, `checking_cache`, `scanning`, `finalizing` or `writing_result`, followed by `completed`, `up_to_date`, `paused` or `failed`. The CLI reports 100% after it delivers the scan report.

For a camera multiview burned into one recording, open the same inspector and choose **Automatic Feeds** under **Scan Layout**, then **Scan Feeds**. **Scan Layout** appears when the linked TileTrail build supports feed layouts. Accepted feeds appear in the roster as Feed 1, Feed 2 and so on. Review the detected rectangles at several times and accept the geometry. You can extract a feed, use it as a virtual angle, or apply the same composition and masking tools. A feed can show a stage, an instrument, a slide or another camera. Speaker and microphone bindings are optional. With a bordered picture-in-picture view, extracting the inset gives you that feed. The main view retains the inset pixels that were recorded over it.

For a switcher recording with a known uniform layout, choose **Fixed Feed Grid** and enter columns and rows. Each slot keeps its identity when an operator cuts the camera or the signal goes black. For example, Feed 3 in a 2×2 grid is always the lower-left picture. Use automatic detection when the number or position of the boxes changes.

To extract a guest, choose **Composition and Export**, use a solo shot, and add the participant as its slot. Set the canvas resolution, background, framing and audio. **Fit** keeps the whole crop visible. **Fill** crops the picture to occupy the slot. Choose **Preview** or **Check Export** before **Export Movie**. For a two-camera interview, select a pair shot and add the two synchronized angles in left-to-right order. Choose the audio route separately.

Bind an ISO microphone and a transcript speaker in the participant inspector. The **Bind Audio** and **Bind Transcript Speakers** menus list tracks and speakers whose names match the participant first, ignoring case and accents. A track label can end in ISO, mic or microphone. An ISO requires a corresponding audio source. With only a meeting mix, choose program audio or silence. Transcript mappings apply to the selected attachment, including when the mapped speaker is offscreen. For interchange, **Render Angle Media** writes aligned movies together with a multicam project. Under **Participant Multicam Angles**, turn on **Include Original Gallery** or a **Presentation** angle to render those as angles too.

To find edit points, choose which people to count and which changes matter in the marker inspector. Count people for returns or camera changes. Count slots to detect a replacement in a comparable layout. Set the threshold to any, at least N, or all, then choose **Review Marker Candidates** and seek to each candidate. Changing these rules reuses the saved scan.

For a panel edit, add slots in output order and choose a fixed grid or flow. Fixed slots keep a guest's place during a gap. Flow can compact the layout when an absence is confirmed. In the original gallery, set a participant's treatment to blur or opaque cover to mask their visible appearances. Choose removal to leave a person out of a rebuilt layout. These are picture edits. The audio route controls whose voices the export includes.

For a dialogue edit, use **Review Virtual Angles** and **Take at Playhead** to switch manually. Put the playhead on an Assembly or sequence occurrence of the recording first. The take lasts until the next take or the end of the occurrence. Under **Dialogue Switch Suggestions**, **Suggest Dialogue Switches** uses the bound transcript speakers. Set **Minimum Hold in Seconds**, choose **Overlapping Speech** (**Hold the Shot** or **Favor a Visible Speaker**) and **Offscreen Speaker** (**Hold the Shot**, **Show Original Gallery** or **Show a Visible Reaction**). **Preview** a proposal, then **Accept** or **Dismiss** it. Suggestions are available in the app only.

To take an angle from a script, list the angles with `participants angles list`, then send one angle object, its `project_path` and an `output_time` to `mpcut participants angles take --input take.json --json` with `out_project` or `in_place`. MCP uses `participants_file_angles_take`. Participant and presentation angles become solo shots and the original gallery becomes an original shot. Projects with still inserts or replacements can’t take an angle.

Participant movies use H.264 at the selected canvas size and frame rate. Choose MOV for audio delivery. A silent movie can also use MP4. Sources with still-image inserts or replacements need a separate edit for this renderer. The preview and export use the accepted geometry, including time-scoped corrections.

## Reconcile a relink or rescan

A hardlink shares the original recording's inode and can keep using the accepted geometry without a new scan. A byte-for-byte copy has a different inode. Scan the copy and choose **Review Reconciliation…** in the Feeds inspector. **Confirm Copied Recording** accepts a copy with identical content and **Replace Geometry** accepts changed content. MPCut verifies the full recording's SHA-256 before carrying over the accepted geometry, corrections, appearance pins, masks and bindings. The scan caches the digest for the current source version. Playback uses the recorded source identity without rereading the file to hash it.

When supplying hand-reviewed geometry with `participants project apply`, keep the reviewed recording at its project path. MPCut records its identity on the first import and retains it across later mask or roster edits. Older hand-authored projects may lack a recording identity. Review those bounds against the current recording before applying them.

For changed picture content, review the affected people, appearance pins, presentation slots, masks and bindings before accepting the replacement. The replacement keeps the existing roster and bindings and brings in new tracks without assigning them to old people. Link the replacement appearances to the relevant roster entries, then choose **Confirm Reviewed Coverage…** for each affected person on that source. `participants project accept` refuses a scan whose identity, feed layout or digest differs from the source’s accepted geometry, so reconcile those in the app. While a masked person is pending review, a privacy export stops or covers the affected frames according to the plan. Undo restores the prior accepted geometry and corrections.

## Source analysis from the command line

A TileTrail-enabled build can save a source scan and query its markers independently. Use a new destination for the scan. `--feed-layout` accepts `auto` or a grid such as `2x2` with up to 64 feeds. Without it, the scan uses the meeting profile.

```sh
mpcut participants scan --file multiview.mov --feed-layout auto --output feeds.json --json
mpcut participants scan --file switcher.mov --feed-layout 2x2 --output angles.json --json
mpcut participants scan --file gallery.mov --include-scenes --output gallery-scan.json --json
mpcut participants markers build --analysis-file gallery-scan.json --json
mpcut help participants --json
```

To use the results in an existing project, select its gallery source ID. This example assumes a multicam project with a source named `gallery`.

```sh
mpcut participants project accept --project interview.cut --source-id gallery \
    --analysis-file gallery-scan.json --out-project reviewed.cut
mpcut participants project inspect --project reviewed.cut --json
```

After saving a composition on the reviewed project, inspect and render it with:

```sh
mpcut participants render plan --project reviewed.cut --json
mpcut participants render export --project reviewed.cut --output interview-two-up.mov --json
```

A scan uses adaptive sampling unless you choose another mode. It analyzes each keyframe and asks TileTrail whether every region continues from the last analyzed frame: the same appearances and identities, no event, and bounds within the tolerance of a move or resize. If so, the frames in between are skipped and that stretch is recorded as inferred coverage. If not, MPCut decodes the stretch and analyzes every frame in it, so a change is placed on its exact frame and that stretch is verified.

A stretch can be skipped when it starts and ends on an H.264 IDR picture, an HEVC random access picture with no leading pictures, or a frame of an intra-only codec, lasts at most three seconds, and its packets cover the whole interval. Zoom writes a keyframe every 2.4 seconds. Recordings with longer keyframe intervals, other codecs and combined scene scans are analyzed frame by frame. A change that appears and fully reverts between two analyzed keyframes is not seen. Inferred coverage is not verified coverage: a redaction render covers or stops on it. Run `--sampling every-frame` when you need every frame checked.

Measured with an optimized build on an Apple M4 Max that was busy with other work, on two real 1080p Zoom recordings:

| Recording | Every frame, before | Adaptive | Every frame, now | Sparse, now |
| --- | ---: | ---: | ---: | ---: |
| 2 h 1 min, two layout changes | about 10 min | 1.4 to 1.9 s | 53 to 58 s | 52 s |
| 2 h 30 min, frequent changes | about 16 min | 4 to 5.5 s | about 90 s | |

The first “before” figure is projected from 90-second runs of the previous reader in an optimized build (15% scanned with Metal measurement, 18% on the CPU). A complete run in a debug build under heavier load took 808 seconds, and 950 seconds for the second recording. The adaptive scan of the first recording reports the same events on the same frames as the every-frame scan.

One reader serves every mode, including combined scene scans, which return the same scene report as before. H.264 pictures up to 1920×1088 decode in software on several threads. Ten minutes of the first recording decoded in 3.2 seconds that way and in 27.7 seconds through the hardware decoder. The pictures are converted exactly as the hardware decoder's were. Other pictures use the hardware decoder as before. Peak memory for the adaptive scans was 0.4 to 0.5 GB.

With TileTrail 0.4.1, meeting analysis keeps a video tile it has seen for eight frames in a row through detections that briefly cut it into pieces or merge it with its neighbours, while the picture in its bounds still matches and for at most three seconds. A dark band or a straight edge in someone's room used to read as a gutter for a few frames, and each such frame ended the appearance and started new tracks. On the first recording an every-frame scan went from 6 tracks and 25 events to 2 tracks and the 7 events of its two real layout changes. On the second it went from 1,838 tracks and 7,137 events to 416 and 2,279. Scans saved by earlier builds are rebuilt.

A skipped stretch is never decoded, so damage inside it goes unnoticed: an adaptive scan can complete where an every-frame scan of the same file reports incomplete coverage.

A long every-frame report can exceed 100 MB. With `--output`, add `--summary` (`summary` in a JSON or MCP request) to receive the scan's state, counts, coverage and resume point in place of a second copy of the report.

Sparse analysis is intended for exploratory review. Check all appearances, including a second thumbnail and its nameplate, before delivering a redaction. The renderer reports unresolved coverage and can use an opaque cover for the affected frames. A wrong identity or missed detection can still expose someone. Inspect the delivered picture.

The [verification report](VIDEO-CHAT-VERIFICATION.md) describes the public recording samples and the checks on delivered audio and picture.
