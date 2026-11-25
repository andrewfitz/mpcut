# Edit camera feeds and recorded video calls

Open the recording and select **Tiles**. Choose **Video Call**, **Camera Multiview** or **Even Grid**, then select **Find Tiles**. A tile is a visible box. A feed is the person, camera or share shown in one or more boxes over the recording. **Check Tiles** shows both the number of feeds detected and the highest number of tiles visible at once.

Check names and thumbnails before selecting **Use These Tiles**. Use **Merge Into** on a card to combine two detections of the same feed. If the boxes themselves are wrong, start with **Correct Grid…** for the affected span. Expected counts are review aids. A mismatch leaves the detections intact. Turn on **Use a Gallery Hint** when a video call follows a known gallery grid for some of the recording. You can also choose **Draw Tiles by Hand**. **Even Grid** and hand drawing are available in a build without automatic detection.

The inspector shows the scan stage and a percentage bar. During scanning the percentage follows the recording’s source time, including stretches skipped by adaptive or sparse sampling. For frame-by-frame verification before a redacted delivery, choose **Scan Options → Every Frame** in the inspector or request every-frame sampling through the CLI or MCP. Review outstanding identity issues before accepting the result. A matching saved scan can jump directly to 100% after verification. A fresh scan shows 100% when the geometry is ready for review. Cancel pauses the scan. **Resume Find Tiles** continues a paused scan. A saved scan that uses decoded replay rebuilds the tracker from the start and shows that work in the progress bar. For a command-line scan, use `--progress stderr` to watch percentages or `--progress jsonl` for structured events on standard error. Each event reports its phase: `preparing`, `checking_cache`, `scanning`, `finalizing` or `writing_result`, followed by `completed`, `up_to_date`, `paused` or `failed`. The CLI reports 100% after it delivers the scan report.

You can save and close a project during review. The `.cut` carries the scan, feed names and grid corrections for the selected picture source. Reopen the project to finish the review, even after clearing its cutcaches. To hand the review to a script or an agent, read the pending choices for that source, stage the complete revised choices object, then accept using the token for the choices you approved. [Worked CLI example](CLI.md#review-pending-tiles)

For a multiview burned into one recording, **Camera Multiview** finds changing boxes. With a known switcher grid, **Even Grid** follows positions. For example, Feed 3 in a 2×2 grid is always the lower-left picture, including after the operator switches that input. In a bordered picture-in-picture view, the main view still contains the inset pixels that were recorded over it.

Use **Source** on the monitor to see the untreated recording and correct tiles. Select a tile to open its editing controls. To apply a correction between marks, set both marks inside the same occurrence of the recording and choose **Marked Range**. Choose **Output** to see the edited picture.

## Lay out and treat the picture

Use **Layout** in the Tiles panel to choose **Original**, **Solo**, **Side by Side** or **Grid**. Under **Choose Feeds and Cameras** you can mix feeds and camera angles in the same layout. Clear the selection and add cells in the order you want them to appear. For a sequence, a layout belongs to its clip and follows that clip when it moves. In multicam, a layout can apply on the group clock or to the occurrence in Assembly preview. Mark a range to limit the edit. Choose **Original** to clear a clip or group layout or override the group layout for one assembly occurrence.

Use the treatment menu on a feed for **Blur**, **Cover** or **Remove**. The treatment follows the feed across tiles and clips, including when a second tile shows the same feed. It also applies in **Original**. The shared mix and transcript can still include a treated feed's voice. Changes to layouts and treatments take effect immediately and can be undone.

Use a tile's editing controls to assign its feed, select **Prefer This Tile** for overlapping appearances, or correct the bounds. **Swap With…** exchanges two visible feeds in the current arrangement. **Mark as Screen Share** assigns a feed to a presentation tile so you can name and edit it.

## Cut between feeds

Choose **Use Feeds as Multicam Angles** to switch among feeds without rendering intermediate movies. In a multicam project, use the normal Switch lane and Take controls. To cut from a transcript, choose **Link Transcript Voices…**, map each voice to an angle, then choose **Propose Switches**. Review proposals at their timestamps and accept the cuts you want.

Bind microphones and transcript voices through **Mic** and **Voice** in the Tiles panel when the project has eligible audio or a transcript. The menus show name matches first. An ISO microphone requires a corresponding audio source. A transcript voice binding can drive suggestions or transcript filtering.

Use **Needs a Look** to jump to unresolved tile assignments or recording changes. Use **Layout Change Filters** to review changes the scan reports. Count feeds for returns or camera changes, or slots for a replacement in a comparable layout. Changing the filter reuses the scan.

## Export synchronized feed movies

Choose **Export ISOs…** in **Tiles**. Review the included feeds and any reported issues. Size and frame rate default to the source. Export the full recording or set both marks inside one occurrence and choose **Marked Range**. **Fit** preserves the crop within the chosen canvas and **Fill** fills the frame. The synchronized feeds share a start and duration. **Gap Color** controls the picture when a feed is offscreen.

Use **Create Delivery Folder…** for the first run, or **Resume Existing Delivery…** after an interruption. The completed delivery includes the synchronized movies, a manifest and an MPCut multicam project. Choose **Verify Delivery** after an export, or **File → Verify ISO Delivery…** in any editor window, to check that the files still match the manifest. The shared mix can contain voices from treated or excluded feeds. Clear **Include shared mix** if you want to leave that audio out.

The manifest reports the selected source range and how many picture decode passes the current run used. The renderer batches crops to limit the memory used by encoder input buffers, so larger canvases can require more passes. A run that reuses every movie reports zero picture passes.

The same workflow is available from a recording or a saved project with `mpcut tiles export-isos`. [CLI examples](CLI.md#edit-camera-feeds-and-recorded-calls)

## Reconcile a relink or rescan

A hardlink shares the original recording's inode and can keep using the accepted geometry without a new scan. A byte-for-byte copy has a different inode. Scan the copy and choose **Review Changed Recording…** in the Tiles panel. **Confirm Copied Recording** accepts a copy with identical content and **Replace Geometry** accepts changed content. MPCut verifies the full recording's SHA-256 before carrying over the accepted geometry, corrections, appearance pins, masks and bindings. The scan caches the digest for the current source version. Playback uses the recorded source identity without rereading the file to hash it.

When supplying hand-reviewed geometry with `participants project apply`, keep the reviewed recording at its project path. MPCut records its identity on the first import and retains it across later mask or roster edits. Older hand-authored projects may lack a recording identity. Review those bounds against the current recording before applying them.

For changed picture content, review the affected people, appearance pins, presentation slots, masks and bindings before accepting the replacement. The replacement keeps the existing roster and bindings and brings in new tracks without assigning them to old people. Link the replacement appearances to the relevant roster entries, then choose **Confirm Reviewed Coverage…** for each affected person on that source. `participants project accept` refuses a scan whose identity, feed layout or digest differs from the source’s accepted geometry, so review the replacement in the editor or use `tiles reconcile` or `tiles_file_reconcile`. Inspect the reported changes, then supply the returned review token when applying the replacement. While a masked person is pending review, a privacy export stops or covers the affected frames according to the plan. Undo restores the prior accepted geometry and corrections.

A confirmation clears review uncertainty where a treated feed has a current linked tile. Resolve unknown coverage and any unassigned tile or name label that overlaps the output before publishing. Changes to geometry, assignments, appearance preferences or the treatment expire the associated confirmation.

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

For a legacy project with a saved participant composition, inspect and render it with:

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

With meeting detector revision 7, TileTrail places the tiles of a Zoom gallery and of the cameras beside a share from the shape of the layout. A gallery is rows of equal 16:9 tiles centered on black with the last row centered. The cameras beside a share form a column of 16:9 tiles at the right edge, however narrow a very wide recording draws it, or a block two tiles wide. A dark room that reads as matte, a shelf that reads as a gutter, a shared desktop with a dark wallpaper and an avatar card with dark sides no longer cut a tile into pieces. A live room lit in one warm hue no longer flickers between video and camera off. A 16:9 call window recorded inside a wider or taller frame is one tile, whatever bars its own picture has.

On 46 two-hour Zoom recordings, 45 of three to four people and one of ten people in 4K, adaptive scans went from 25,074 feed tracks and 106,103 events to 298 and 1,880. The ten-person scan took about six minutes, down from ten. Tile boxes were compared at 0.90 overlap with boxes from a separate full-resolution labeler, spot-checked by eye, on 588 frames sampled evenly through those recordings: 494 frames had every tile right before and all 588 after. On 26 earlier recordings of up to 14 people, 208 of 208 sampled frames were right, up from 119. A fresh sample of 104 frames from those recordings, drawn after all the changes, was 104 of 104, up from 61. On 66 frames from 11 recordings of the same series that no part of this work looked at, all 66 were right, up from 44. Scans saved by earlier builds are rebuilt.

A newcomer who resembles someone still on screen is no longer marked for review, and the one tile Zoom paints on a recording's first frame is read as a tile. A feed shown in another tile of the same kind at that moment is no longer offered as a possible match, since it cannot be this tile's feed. A tile is still marked when it resembles someone who has left, often the same person returning under a new feed, and MPCut also asks for review wherever the scan lists another possible feed for a tile it has assigned.

**Needs a Look** shows one row for each tile that needs a feed, with the number of places in the recording where it waits for one. **Same Feed** or **Different Feed** settles every place at once: **Same Feed** folds the scan's own feed for the tile into the earlier feed and links the whole tile to it, so the person keeps one feed. **Different Feed** keeps the tile on its own feed. On those 46 recordings, 15 pass straight to a one-step ISO export. The other 31 need between one and 27 such decisions, 142 in all, and 12 of them need only one. From the command line, settle a whole `group_id` from `tiles inspect --issues` with `tiles link` and no `--from` or `--to`, after `tiles feeds merge` for the same person. [CLI examples](CLI.md#edit-camera-feeds-and-recorded-calls)

A MOV or MP4 cut between frames can contain a discarded preroll picture and declare a fractional tail beyond its last displayed picture. An export can also store one more sample than it presents, when its edit ends on that last sample. A scan that reads every presented sample completes and can be accepted. The tail has unknown coverage and no tile boxes.

A skipped stretch is never decoded, so damage inside it goes unnoticed: an adaptive scan can complete where an every-frame scan of the same file reports incomplete coverage.

A long every-frame report can exceed 100 MB. With `--output`, `tiles scan` prints only the scan's state, counts, coverage and issues. For `participants scan`, add `--summary` (`summary` in a JSON or MCP request) to receive the state, counts, coverage and resume point in place of a second copy of the report.

Sparse analysis is intended for exploratory review. Check all appearances, including a second thumbnail and its nameplate, before delivering a redaction. The renderer reports unresolved coverage and can use an opaque cover for the affected frames. A wrong identity or missed detection can still expose someone. Inspect the delivered picture.

The [verification report](VIDEO-CHAT-VERIFICATION.md) describes the public recording samples and the checks on delivered audio and picture.
