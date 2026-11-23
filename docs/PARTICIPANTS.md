# Edit a recorded video call

Open the recording in MPCut, select **Participants**, and choose **Scan Participants** at the source you want to analyze. Review the boxes and roster before choosing **Accept Geometry**. If a guest returns under another track, select their appearance, set the source-time correction range and link it to the existing participant. Use **Before Reflow** and **After Reflow** to inspect a layout change. Save the project to retain accepted geometry and corrections.

To extract a guest, choose **Composition and Export**, use a solo shot, and add the participant as its slot. Set the canvas resolution, background, framing and audio. **Fit** keeps the whole crop visible. **Fill** crops the picture to occupy the slot. Choose **Preview** or **Check Export** before **Export Movie**. For a two-camera interview, select a pair shot and add the two synchronized angles in left-to-right order. Choose the audio route separately.

Bind an ISO microphone and a transcript speaker in the participant inspector. An ISO requires a corresponding audio source. With only a meeting mix, choose program audio or silence. Transcript mappings apply to the selected attachment, including when the mapped speaker is offscreen. For interchange, **Render Angle Media** writes aligned movies together with a multicam project.

## Source analysis from the command line

A TileTrail-enabled build can save a source scan and query its markers independently. Use a new destination for the scan.

```sh
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

Sparse analysis is intended for exploratory review. Check all appearances, including a second thumbnail and its nameplate, before delivering a redaction. The renderer reports unresolved coverage and can use an opaque cover for the affected frames. A wrong identity or missed detection can still expose someone. Inspect the delivered picture.
