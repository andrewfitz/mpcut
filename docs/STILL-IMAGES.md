# Edit still images in MPCut

Use **Replace Picture…** to show a photo over an interview or a multicam program while the underlying sound continues. Use **Insert Still…** to add a title, card, or photo for a separate duration. An insert moves later material forward and adds silence on the existing audio tracks.

MPCut reads static JPEG, PNG, TIFF, WebP, HEIC/HEIF, AVIF, and JPEG XL through the macOS image decoder. It uses the image’s orientation and embedded color information when present. Animated and multi-image files are rejected. Image files remain linked by path in the saved project. Keep them with the recordings when moving or sharing the project.

On a PQ or HLG timeline, MPCut maps SDR artwork to the program’s diffuse white (203 cd/m² by default). Tagged HDR artwork can retain highlights above that level. For supported gain-map images, the HDR rendition combines the base image with its gain map. The project’s color settings govern export regardless of which display you use to edit.

## Place and edit an image in the app

1. For **Replace Picture…**, mark the beginning and end with **I** and **O**, then choose **Sequence → Replace Picture…** (⇧⌘R). In multicam, mark the range on the **Group** timeline. Its replacement follows group time through every retained occurrence in the assembly, including repeats.
2. For **Insert Still…**, position the playhead and choose **Sequence → Insert Still…** (⇧⌘I). In multicam, use the **Assembly** timeline to target an exact occurrence. Enter a duration and frame rate in the dialog. For constant-frame-rate output, choose a duration containing a whole number of frames. Variable-frame-rate output can end a card with a shorter final sample. You can also drop image files onto the timeline.
3. Open the timeline’s **Stills** menu, choose the placement, and select **Framing…**. **Fit** shows the whole selected image area with the background filling any exposed space. **Fill** scales up to cover the canvas and crops around the center. Use the normalized crop fields to select a different image area. X and Y are measured from the left and top of the oriented image. The background also fills transparent areas.
4. Use **Move…**, **Change Duration…**, or **Duplicate** in the placement menu for inserted cards. **Delete** reveals the original picture for a replacement and closes the gap for an insert. **Relink Image…** locates the same image for all uses, including those in retained undo and redo states. To use a different image, choose **Replace Source File…** in Project Media and review the framing before applying. Save with **File → Save Project**.

To start with images alone, use **Insert Still…** in an empty project window or drop an image there. Set the canvas dimensions, rate, codec, container, and color in **Still Timeline Format**. The format supplies the video settings for the new project. For a still-only project, use MOV for ProRes and HEVC or ProRes for PQ or HLG.

Choose **View → Show Video Monitor** to review the program on a separate display. Right-click the monitor for **Clean Feed**, **Toggle Full Screen**, and display selection when multiple screens are available. Right-click either viewer to toggle **Force SDR Preview** for that surface. The editor viewer and monitor show their own display status as **SDR**, **SDR preview**, **HDR · PQ**, or **HDR · HLG** when resolved. An HDR program can preview in SDR on one screen while the other uses extended dynamic range. Review JPEGs use an SDR rendition. At a multicam switch or a covered camera frame, choose the program picture to capture the still or an explicit camera angle to inspect the recording.

## Pair a cover image with a recording

Drop an audio file onto an image-only timeline, or choose **Attach Soundtrack…** from the **Stills** toolbar menu or **Add Soundtrack** in the status bar, to add its soundtrack. The same menus can **Replace Soundtrack…** or **Remove Soundtrack** later. Removing the recording keeps the picture duration. Drag the right edge of a still to change how long it stays on screen. Later slides move with the edit, and the recording keeps playing from its original start. If the picture ends first, the export stops there. If the picture runs longer than the recording, the remaining picture plays in silence. Export normally to store each visible hold as one video sample.

The right edge snaps to the recording’s exact end when you drag it within half a video frame, even if the last audio sample falls between frames. To shorten a selected still at the playhead, choose **Trim End to Playhead**. You can also use **Fit Image to Soundtrack** in the **Stills** menu for a single image or **Change Duration…** to enter a precise length.

```sh
mpcut still project create --out-project cover.cut --image cover.png \
  --width 1920 --height 1080 --rate 30 \
  --soundtrack recording.wav --fit-soundtrack --json

mpcut export project render --project cover.cut --output cover.mov --json
```

For an existing still-only project, use `mpcut still soundtrack attach --project cover.cut --soundtrack recording.wav --in-place`. Add `--audio-stream INDEX` to choose an absolute stream index. The default is the first audio track. Pass `--from` or `--to` for exact source times on audio sample boundaries. Use `still soundtrack fit` to fit the single image later, or `still soundtrack detach` to remove the recording and keep the picture duration. For MCP, use `still_file_project_create` or the `still_editor_soundtrack_attach`, `still_editor_soundtrack_fit`, and `still_editor_soundtrack_detach` tools. Attach also accepts `fit_soundtrack: true` to fit in the same edit. [MCP tool reference](MCP-REFERENCE.md)

## Leave space between clips

Choose **Sequence → Space Clips…** and pick **Fixed Duration** to set the pause in seconds, or **Source Timing** to keep the elapsed time between consecutive ranges. The command applies across the sequence or multicam assembly. Camera switches within an assembled range stay together. The timeline shows empty space, and the viewer displays the chosen color during that interval. Black is the default. Fixed spacing also works between still pictures.

Applying spacing again updates the existing internal gaps. Set the duration to zero to close them. Leading and trailing gaps are preserved. The entire change takes one Undo. Use **Insert Color Gap…** to put a single pause at the playhead, or open its entry in the Stills menu to change its duration or color.

```sh
mpcut timeline clips space --project edit.cut --duration 2 --background '#FFFFFF' --in-place
mpcut timeline clips space --project edit.cut --source-timing --in-place
mpcut timeline gap insert --project edit.cut --clock sequence --at 8 --duration 2 --in-place
```

Each pause adds silence, using the same sound rules as still inserts. Colors are chosen in sRGB. Export converts them to the program color space, with white at the configured diffuse white for PQ and HLG. Native projects store the gap independently of external image files.

To keep the elapsed time between selections from one recording, use `--space-clips source`. For example, these two ranges produce seven seconds of camera picture, five seconds of black, then 45 seconds of camera picture. The first selected frame starts the 57-second output.

```sh
mpcut export clips join --clip interview.mov --from 10:03 --to 10:10 \
  --clip interview.mov --from 10:15 --to 11:00 \
  --space-clips source --output spaced.mov
```

Use `--space-clips 2` for a two-second pause between every pair, including clips from different recordings. Omit the option to join ordinary trimmed clips directly. On a saved project, `mpcut export project render --project edit.cut --space-clips 2 --output spaced.mov` applies spacing to that export. To save the spacing in the project, use **Space Clips…** or `mpcut timeline clips space`.

Source timing requires chronological, nonoverlapping ranges on a common clock. In multicam that clock is group time. A spacing export generates the color frames and, by default, requires every retained camera frame to copy. Use `--dry-run --json` to check the selected boundaries and sound tracks before writing. When a camera cut falls inside a dependent group of frames, move it to a copy-safe boundary. An incompatible compressed soundtrack may require an explicit audio conversion.

For an open project, call MCP’s `timeline_clips_space` with `source_timing: true` or a `duration` such as `"2"`. Supply the project, its current revision and an operation ID. The whole edit takes one Undo. For a file export, pass `"space_clips": "source"` or `"space_clips": "2"` to `export_file_project_render` or `export_file_clips_join`. This applies the spacing to the exported movie and leaves the saved edit intact.

When sampling a frame from a Smart Trim HEVC MOV with FFmpeg, use output-side seeking (`ffmpeg -i movie.mov -ss TIME …`). In testing, input-side fast seeking into a generated span could select the wrong HEVC sample description. Linear decoding and native macOS seeking produced the expected picture.

## Edit a saved project from the CLI

Run `mpcut help still placement insert` or `mpcut help still placement insert --json` for command and flag discovery. Sequence positions count from the start of the edited timeline. Multicam replacements use group time and multicam inserts use assembly time. Replace ranges are half-open. Use integer seconds, exact decimals, or exact fractions such as `1001/30000`.

```sh
# Cover sequence seconds 8 through 12 while retaining the soundtrack.
mpcut still picture replace --project interview.cut --image photo.png \
  --clock sequence --from 8 --to 12 --out-project covered.cut --json

# Insert a 60-frame title at the start of the sequence.
mpcut still placement insert --project covered.cut --image title.png \
  --clock sequence --at 0 --frames 60 --rate 30 --out-project titled.cut --json

mpcut still placement list --project titled.cut --json
```

The list reports stable placement and asset IDs, authored coverage, and visible occurrences. Use the placement ID with `still update` or `still remove`. Use the asset ID with `still relink` or reuse it with `still add --asset ID`. Set framing with `--fit fit|fill`, the four `--crop-*` flags, or `--background '#RRGGBB'`. Choose `--out-project FILE` or `--in-place` for an edit. With `--project -`, read the project on stdin and provide a named destination for an edit.

```sh
mpcut still project create --out-project cards.cut --image title.png \
  --width 1920 --height 1080 --rate 30000/1001 --frames 60 \
  --codec h264 --container mp4 --color sdr --json

mpcut export project render --project cards.cut --output cards.mp4 --dry-run --json
```

For an open desktop project, use MCP’s `still_editor_placements_list`, `still_editor_placement_insert`, `still_editor_picture_replace`, `timeline_gap_insert`, `still_editor_placement_update`, `still_editor_asset_relink`, and `still_editor_placement_remove`. Mutations use the current project revision and an operation ID. MCP uses frame interval for `cadence`, while the CLI uses frames per second for `--rate`. [MCP tool reference](MCP-REFERENCE.md) · [Project format](CUT-FORMAT.md)

## Export the program

**One frame per still** writes one independently decodable sample per visible hold. It defaults on for an image project with a soundtrack or an insert with an exact duration that isn’t a whole number of frames. Turn it on for an existing edit in the export sheet, the Export Queue or the multicam Export inspector, or pass `--still-timing held` to the CLI and `still_timing: "held"` to MCP. With cadence timing, replacements follow the covered footage’s presentation timestamps and inserts use their authored cadence. A selection starting inside a hold begins with a new sample at output zero.

A saved project with visible stills defaults to **Smart Trim** for picture export. Smart Trim generates the still frames and can copy eligible camera samples. A return to long-GOP camera footage may require encoding its edge. Select **Require Camera Video Copy** in the export sheet or multicam Export inspector or use `--require-camera-copy` in the CLI to require every retained camera sample to copy while allowing generated still frames. Review any offered boundary change before applying it. **Lossless Copy** requires all selected media packets to be copied.

Smart Trim can add digital silence to compatible PCM tracks and preserve the retained samples in their original PCM format. If copied sound cannot represent an inserted silence or join, preflight reports the affected tracks. Smart Trim can use an explicit `--audio aac`, `pcm`, `alac` or `flac` request where supported. **Re-encode** offers a full conversion when compatible with the chosen output. Use a dry run to inspect the actual export plan and its copied camera, encoded camera, generated still, and sound actions before writing. [Export modes](EXPORT-MODES.md) · [Export rules](EXPORT-RULES.md)

For lossless audio delivery, use ALAC or PCM in MOV, ALAC or FLAC in MP4 and M4V, and FLAC in MKV. JPEG picture uses PCM in MOV. ALAC conversion is available only for exports with visible stills. ALAC and FLAC keep integer samples up to 24 bits in layouts from mono to 7.1. For floating-point or 32-bit sources, choose PCM in MOV, which keeps the source precision. Lossy sources are decoded to 16- or 24-bit PCM before lossless encoding, and the plan reports a warning. Fractional cuts align to whole source samples without resampling. H.264 and JPEG use SDR. HEVC supports SDR, PQ and HLG in each container. ProRes supports those color policies in MOV and MKV.

A still-only project keeps its saved defaults when an export chooses another codec or container. For example, render the same cover as MP4 with `mpcut export project render --project cover.cut --output cover.mp4 --video hevc --audio flac`. An explicit `--container` must match the file extension. In MCP project exports, set `container` and use `video` in the file tool or `codec` in the live editor tool. The CLI dry run reports `generated_video_sample_count`, `written_picture_duration`, `video_codec` and per-track sound actions. A completed CLI render also reports `output_bytes`.

A still-bearing picture-and-sound export refuses source timecode and other ancillary tracks when it cannot preserve them on the new program clock. Choose video only or audio only if you want to omit those tracks. Check the selected tracks in preflight before writing the movie.

Project conversion depends on the destination. Final Cut Pro can map eligible JPEG, PNG, and TIFF inserts with standard Fit or Fill framing. A multicam assembly needs a retained camera range for that mapping. Conversion reports placement IDs when a destination cannot represent an edit. If you accept a loss report, an omitted replacement reveals its original picture and an omitted insert removes its duration and silence. Use media export to deliver the rendered result. [Project conversion](../README.md#convert-projects)
