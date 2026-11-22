# Edit still images in MPCut

Use **Replace Picture…** to show a photo over an interview or a multicam program while the underlying sound continues. Use **Insert Still…** to add a title, card, or photo for a separate duration. An insert moves later material forward and adds silence on the existing audio tracks.

MPCut reads static JPEG, PNG, TIFF, WebP, HEIC/HEIF, AVIF, and JPEG XL through the macOS image decoder. It uses the image’s orientation and embedded color information when present. Animated and multi-image files are rejected. Image files remain linked by path in the saved project. Keep them with the recordings when moving or sharing the project.

On a PQ or HLG timeline, MPCut maps SDR artwork to the program’s diffuse white (203 cd/m² by default). Tagged HDR artwork can retain highlights above that level. For supported gain-map images, the HDR rendition combines the base image with its gain map. The project’s color settings govern export regardless of which display you use to edit.

## Place and edit an image in the app

1. For **Replace Picture…**, mark the beginning and end with **I** and **O**, then choose **Sequence → Replace Picture…** (⇧⌘R). In multicam, mark the range on the **Group** timeline. Its replacement follows group time through every retained occurrence in the assembly, including repeats.
2. For **Insert Still…**, position the playhead and choose **Sequence → Insert Still…** (⇧⌘I). In multicam, use the **Assembly** timeline to target an exact occurrence. Enter a duration and frame rate in the dialog. For constant-frame-rate output, choose a duration containing a whole number of frames. Variable-frame-rate output can end a card with a shorter final sample. You can also drop image files onto the timeline.
3. Open the timeline’s **Stills** menu, choose the placement, and select **Framing…**. **Fit** shows the whole selected image area with the background filling any exposed space. **Fill** scales up to cover the canvas and crops around the center. Use the normalized crop fields to select a different image area. X and Y are measured from the left and top of the oriented image. The background also fills transparent areas.
4. Use **Move…**, **Change Duration…**, or **Duplicate** in the placement menu for inserted cards. **Delete** reveals the original picture for a replacement and closes the gap for an insert. **Relink Image…** changes the file for every placement using that asset. Use ordinary undo and redo and save with **File → Save Project**.

To start with images alone, use **Insert Still…** in an empty project window or drop an image there. Set the canvas dimensions, rate, codec, container, and color in **Still Timeline Format**. The format supplies the video settings for the new project. For a still-only project, use MOV for ProRes and HEVC or ProRes for PQ or HLG.

Choose **View → Show Video Monitor** to review the program on a separate display. Right-click the monitor for **Clean Feed**, **Toggle Full Screen**, and display selection when multiple screens are available. Right-click either viewer to toggle **Force SDR Preview** for that surface. The editor viewer and monitor show their own display status as **SDR**, **SDR preview**, **HDR · PQ**, or **HDR · HLG** when resolved. An HDR program can preview in SDR on one screen while the other uses extended dynamic range. Review JPEGs use an SDR rendition. At a multicam switch or a covered camera frame, choose the program picture to capture the still or an explicit camera angle to inspect the recording.

## Edit a saved project from the CLI

Run `mpcut help still` or `mpcut help still --json` for command and flag discovery. Sequence positions count from the start of the edited timeline. Multicam replacements use group time and multicam inserts use assembly time. Replace ranges are half-open. Use integer seconds, exact decimals, or exact fractions such as `1001/30000`.

```sh
# Cover sequence seconds 8 through 12 while retaining the soundtrack.
mpcut still add --project interview.cut --image photo.png --replace \
  --clock sequence --from 8 --to 12 --out-project covered.cut --json

# Insert a 60-frame title at the start of the sequence.
mpcut still add --project covered.cut --image title.png --insert \
  --clock sequence --at 0 --frames 60 --rate 30 --out-project titled.cut --json

mpcut still list --project titled.cut --json
```

The list reports stable placement and asset IDs, authored coverage, and visible occurrences. Use the placement ID with `still update` or `still remove`. Use the asset ID with `still relink` or reuse it with `still add --asset ID`. Set framing with `--fit fit|fill`, the four `--crop-*` flags, or `--background '#RRGGBB'`. Choose `--out-project FILE` or `--in-place` for an edit. With `--project -`, read the project on stdin and provide a named destination for an edit.

```sh
mpcut still create --out-project cards.cut --image title.png \
  --width 1920 --height 1080 --rate 30000/1001 --frames 60 \
  --codec h264 --container mp4 --color sdr --json

mpcut export --project cards.cut --output cards.mp4 --dry-run --json
```

For an open desktop project, use MCP’s `list_stills`, `add_still`, `update_still`, `relink_still`, and `remove_still`. Mutations use the current project revision and an operation ID. MCP uses frame interval for `cadence`, while the CLI uses frames per second for `--rate`. [MCP tool reference](MCP-REFERENCE.md) · [Project format](CUT-FORMAT.md#version-2)

## Export the program

Replacement stills follow the presentation timestamps and sample durations of the covered footage, including variable-rate footage. For a variable-rate insert, specify a cadence. The last sample may be shorter when the selected MOV-family clock can represent the exact end time.

A saved project with visible stills defaults to **Smart Trim** for picture export. Smart Trim generates the still frames and can copy eligible camera samples. A return to long-GOP camera footage may require encoding its edge. Select **Preserve camera picture** in the export sheet or use `--require-camera-copy` in the CLI to require every retained camera sample to copy while allowing generated still frames. Review any offered boundary change before applying it. **Lossless Copy** requires all selected media packets to be copied.

Smart Trim can add digital silence to compatible PCM tracks and preserve the retained samples in their original PCM format. If copied sound cannot represent an inserted silence or join, preflight reports the affected tracks. Smart Trim can use an explicit `--audio aac` or `--audio pcm` request where supported. **Re-encode** offers a full conversion when compatible with the chosen output. Use a dry run to inspect the actual export plan and its copied camera, encoded camera, generated still, and sound actions before writing. [Export modes](EXPORT-MODES.md) · [Export rules](EXPORT-RULES.md)

A still-bearing picture-and-sound export refuses source timecode and other ancillary tracks when it cannot preserve them on the new program clock. Choose video only or audio only if you want to omit those tracks. The ordinary export path continues to use its existing timecode rules.

Project conversion depends on the destination. Final Cut Pro can map eligible JPEG, PNG, and TIFF inserts with standard Fit or Fill framing. A multicam assembly needs a retained camera range for that mapping. Conversion reports placement IDs when a destination cannot represent an edit. If you accept a loss report, an omitted replacement reveals its original picture and an omitted insert removes its duration and silence. Use media export to deliver the rendered result. [Project conversion](../README.md#convert-projects)
