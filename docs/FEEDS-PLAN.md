# Tiles: one picture pipeline and tile edits that follow the clip

Written November 23, 2026, this plan records the starting state and the target design for the desktop app, CLI, MCP and TileTrail. Its descriptions of the earlier participant interface and command surface are historical. It replaces the interface and storage decisions listed in [What this overturns](#what-this-overturns-and-what-it-keeps). For current usage, see the [Tiles editing guide](PARTICIPANTS.md). The [stage 0 design record](FEEDS-STAGE-0.md) carries the format and delivery contract and links the fixture evidence.

## Requirements

These were decided during planning and are the acceptance criteria for every stage.

1. **No Save step.** A change to a feed, a layout or a treatment applies to the project immediately, with undo, like a cut or a camera switch.
2. **One picture pipeline.** Crop, move, scale and blur run on the GPU in one place. The monitor, the timeline thumbnails and every export show its result. There is no separate renderer with its own rules.
3. **Tile edits follow the footage.** Trimming, splitting, moving or reordering a clip carries its tile edits with it. A different video placed beside it is unaffected.
4. **Every use case is covered.** A video call with separate microphones is one route through the feature. It does not shape the design.
5. **Three optional levels.** Edit a recording in place, edit it like any clip, or turn its feeds into multicam angles. No level requires the next.
6. **One privacy rule.** Every output of the edit that can show a hidden feed applies the same check. Review views of the untreated source are the stated exception. See [Privacy](#privacy).
7. **One contract on every surface.** Each operation exists in the app, the CLI and MCP with the same names, the same core call and the same checks. Stages 1 and 2 are led by the CLI and file tools. From stage 3 a stage ships the app, the CLI and the editor tools together. See [One contract](#one-contract-app-cli-and-mcp).
8. **One command, and useful parts.** A user can point MPCut at a recording and export every source in one command. Scanning, inspecting a moment, correcting an assignment, rendering one ISO and verifying a delivery each work on their own.
9. **Cutting between feeds needs no export.** Feeds are used as multicam angles straight from the recording. Rendering a movie per feed is a separate, optional delivery.

## What the feature is for

One recording contains several pictures: a call gallery, a switcher multiview, a picture-in-picture. Each of those pictures, followed over time, is a **feed**. It can be a person, a camera, a slide or a stage.

| Use case | Route | What else it needs |
| --- | --- | --- |
| Extract one person or feed | Find tiles, export that feed | Nothing |
| Export every feed as its own ISO | `mpcut tiles export-isos`, or Export ISOs in the app | From a raw recording the audio is the shared mix. An ISO microphone from a separate file needs a multicam project, where it can be synced. |
| Hide or blur someone | Treatment on the feed | Checked footage for that recording. See [Privacy](#privacy). |
| Reorder or remove tiles inside the original picture | Arranged layout on the clip | Nothing |
| Side by side or grid | Layout on the clip | Two ordinary cameras need a multicam project; a sequence clip has one file |
| Move the recording after another video | Ordinary clip editing | Nothing; tile edits travel with the clip |
| Cut between people or cameras | Use Feeds as Multicam Angles, then the switch lane, with nothing rendered. Until that ships, the multicam project Export ISOs writes. | Nothing |
| Cut by who is talking | The same, plus a transcript | A transcript voice attached to the feed |
| Camera multiview, switcher grid, picture-in-picture | Find tiles automatically or as an even grid, then any route above | No people, microphones or voices |
| Video call with separate microphones and transcript editing | Find tiles, attach microphone and voice, then transcript and switch lane | A multicam project, and linking by name where names agree |
| Video call recorded in speaker view | Not designed yet. See [Not covered](#not-covered-or-to-be-measured). | |
| Find the moments the layout changed | `mpcut tiles inspect`, and among the scene markers from stage 4 | Nothing |
| Hand off to another editor | Export feeds as files with a project | Nothing |

## What is wrong today

- **The panel follows the data pipeline.** Its sections are Source Analysis, Roster and Source Geometry. Every outcome is behind one button, **Composition and Export…**, at the bottom. At the default window size the multicam inspector shows about 265 points of a panel that runs to about 600 with a person selected.
- **About fifteen internal nouns.** Geometry, appearance, coverage, reflow, reconciliation, presentation, slot, shot, occurrence, group clock, virtual angle and bind all appear as labels. The feature is called Feeds, Feeds & Participants, Participants and Participant Composition in different places.
- **Unstated preconditions.** The playhead must rest on a source picture, a person must be selected, a box must be picked, the scan layout must match the last scan, and some actions need the Assembly preview. The panel does not say which one is unmet.
- **Accepting without review.** A scan ends with a count of detected appearances and **Accept Geometry**. Nothing shows who was found, and accepted entries are named Participant N or Feed N.
- **Scan results are held in view state.** Switching inspector tabs discards an unaccepted scan. Layout Change Markers are drawn only under that scan, so they are missing after the project is reopened until the recording is scanned again.
- **Time is typed as seconds in three places.** The feature does not read Mark In and Mark Out, and the timeline shows no tile information.
- **The composition sheet is a second editor inside a modal.** It holds canvas, shots, soundtrack, masks, multicam angles and dialogue suggestions. Its preview is 112 points tall and manual. **Take at Playhead** is inside it, and the playhead cannot be moved while it is open.
- **A draft and a project-wide mode.** Edits stay in the sheet until **Save Composition**, except that Take at Playhead and accepting a dialogue proposal save the whole draft as a side effect. Once saved, the composition changes the rest of the project: current-frame export, JPEG frame export, selection export and queued range exports are refused, and movie export must re-encode. The export tier and the refusal messages name the saved composition. The monitor, the timeline and the panel do not show that one is active, and no control in the editor removes it.
- **A separate renderer.** The monitor always shows the source picture. The layout is drawn by its own renderer, which accepts only balanced H.264 and refuses projects with still inserts or replacements.
- **Layouts do not follow the footage.** In a sequence project a timed layout change is stored against output time, and the project's default layout applies to every clip. Reordering clips leaves the change behind, and a second video takes the first one's layout.
- **Three unconnected identities.** A person's box, microphone and transcript voice are bound by hand in three menus. Transcript jobs keep their own record of call participants and their microphone tracks.
- **A build without the analyzer offers little.** Boxes can be drawn by hand, but the panel leads with a disabled scan button and a sentence that names the analyzer library.
- **Hiding someone mostly blanks the picture.** The privacy check passes only footage analysed frame by frame, and it tests the whole frame whichever tile the output shows. The rest is blanked or stops the export. See [Privacy](#privacy).
- **Exporting every source takes several hand-run steps.** A script scans, accepts the scan into a project it had to create, lists IDs, writes a render request as JSON and renders each angle in a separate full pass. The scan report the CLI can import is capped at 1 GiB.
- **Detection breaks on a dense gallery.** The synthetic test behind the CLI proposal had 25 real tiles on screen and 40 distinct sources. Both tested sampling modes reported 64 boxes per sampled frame and 164 identities. This plan did not re-measure that result.

## Model

**Tile and feed.** There are two levels, and every control belongs to one of them.

- A **tile** is a visible rectangle followed over a stretch of source time. Its box can move or resize. Counting tiles at one instant gives the number of visible boxes, including a stage view and thumbnail of the same source.
- A **feed** is the unique thing being followed: one person, one camera or one screen share. It has many tiles over time as it moves, resizes, leaves and returns. It can have two tiles at once, such as a stage view and a thumbnail, and none while offscreen. The number of feeds is how many distinct people or cameras the recording contains.

Two parts of this differ from the code today and are format changes. A screen share is stored as a tile with no feed, so it cannot be named, hidden or exported like one. And feeds are one list for the whole project, not one list per recording, so the same person can appear in two recordings. That stays: a feed belongs to the project, counts are reported per recording, and commands name the recording when a project has more than one.

If Alice appears on the stage and in a thumbnail, that is two tiles showing one feed. Correcting the thumbnail's box changes that tile. Blurring Alice covers both. Exporting Alice produces one synchronized movie. If she goes offscreen her feed persists, and a correctly linked return continues in the same movie.

Tiles are stored against the recording in source time, as they are today. A scan produces tiles and a first guess at which feed each belongs to. Checking and fixing is correcting those links: merging two feeds that are one person, splitting one that is two, or moving a tile to the right feed.

In an even switcher grid the feed is the position. The lower-left cell stays the same feed when the operator cuts its camera or it goes black. In a call or an automatic multiview the feed follows the content as it moves between positions.

| Level | What belongs to it |
| --- | --- |
| Tile | Its box, its time range, which feed it shows, whether it is a screen share |
| Feed | Name, microphone, transcript voice, treatment, use as an angle, which tile to prefer when two are visible |

**Identifiers.** A `tile_id` names one tile and is today's appearance ID. It stays the same while the box moves or resizes, and splitting a tile creates a new one. A `feed_id` names one feed and is today's participant ID. A tile waiting to be assigned has a box and a time range and no `feed_id`. Accepting a scan generates these IDs at random today, so scanning the same recording twice gives different IDs. IDs are stable within one project, and a second run takes the saved project, not the recording. Every surface reports two counts under their own labels: tiles visible at an instant, and feeds in the recording.

**Attachments.** A feed can have a name, a microphone and a transcript voice. All three are optional. Nothing downstream requires them, and the controls for microphone and voice appear only when the project has separate audio or a transcript.

**Treatment.** None, blur, cover or remove. It belongs to the feed and applies to every clip cut from that recording, in every layout, and to every tile of that feed, including a stage view and a thumbnail visible at once. This is today's rule and it stays.

**Layout.** What the frame shows for a stretch of footage. It belongs to the clip and is stored against the clip's own time, so it moves with the clip.

| Layout | Shows |
| --- | --- |
| Original | The recording untouched. Choosing it removes the layout from the clip. |
| Arranged | The recording's own tile positions, with feeds swapped between tiles or tiles left empty. Works at any gallery size. New. |
| Solo | One feed |
| Side by side | Two feeds, or two cameras in a multicam project |
| Grid | Several feeds, or cameras in a multicam project, in even cells |

A layout and its contents are chosen in one action, such as **Solo: Host**, because a layout with nothing in it is not a valid project state.

**Feed angle.** A multicam angle whose picture is a feed of another source. It is created by an explicit command and is the only thing level three adds.

**Showing one feed.** Solo is a layout in both kinds of project. In a multicam project it shows one feed of whichever camera the switch lane has selected, which is what Take at Playhead does today. When feed angles arrive in stage 5, switching to a feed's angle replaces Solo there, and converting turns Solo segments into switches. Until then there is one way to show one feed: a Solo layout.

### The three levels

1. **Edit in place.** The recording stays an ordinary clip. Hide, blur, swap or remove tiles inside its own picture.
2. **Edit like any clip.** Trim it, split it or move it after another video. Layouts and treatments travel with it.
3. **Turn feeds into multicam angles.** Choose **Use Feeds as Multicam Angles** on the clip. Nothing is rendered. The switch lane, Take, the transcript reader and export then treat each feed as a camera, and edits made at levels one and two carry over. Export ISOs is the separate, optional route that renders one movie per feed and writes a multicam project of them, for handing files to someone else.

## Interface

### The panel finds, checks and fixes

The panel shows one state at a time and names the recording it is working on. A project with several recordings that have tiles gets a recording picker at the top.

**Find.** Shown when the recording has no tiles yet.

```
What is in this recording?
[ Video call ]   [ Camera multiview ]   [ Even grid  2 × 2 ▾ ]
                  Find Tiles             or draw them myself
```

A video call can take a gallery hint, such as 5 × 5, which helps locate boxes while that gallery layout is visible. It is different from the even grid: with the hint a feed follows its content from cell to cell, and in the even grid the cell is the feed. A build without the analyzer offers only the even grid and drawing by hand.

**Check.** Replaces Accept Geometry. One card per detected feed with a thumbnail, an editable name, time on screen and a checkbox. Dragging one card onto another merges two detections of the same person. The pending result is stored, so it survives a tab switch or a relaunch.

```
3 feeds in this recording · at most 3 tiles visible at once
[thumb]  Host           on screen 52:10    ☑
[thumb]  Guest          on screen 48:02    ☑
[thumb]  Screen share                      ☑
                               Use These Tiles
```

The editor can enter how many feeds and how many visible tiles they expect. A mismatch is shown as a warning to review. It never creates or discards a detection to force the numbers to match.

When the boxes themselves are wrong, the editor corrects the grid for the affected stretch before touching identities. If the detector split 25 real tiles into dozens of smaller boxes, one grid correction fixes all of them.

**Fix.** The steady state.

```
gallery.mov ▾
FEEDS
[thumb]  Host    speaking     Mic ▾   Voice ▾   Hide ▾
[thumb]  Guest   offscreen    Mic ▾   Voice ▾   Hide ▾
NEEDS A LOOK (3)
  12:04   unnamed box
  31:40   layout changed
  gallery.mov was replaced
```

Each row under Needs a Look moves the playhead and opens the fix on the picture. The list holds unassigned boxes, unchecked stretches, layout changes and a changed source file. The project stores the first two and detects the last today. Layout changes are not stored; they are added to the project when a scan is accepted. It is the same list `mpcut tiles inspect --issues` returns, and a project saved by a command that ended in `needs_review` opens here with its issues listed.

An ambiguous return is reviewed side by side: the last frame before the departure beside the first frame after the return, with Same Feed, Different Feed and Leave Unresolved.

### On the picture

- **Click a tile** for Hide, Blur, Swap With…, Remove, Solo and Rename.
- **Click a box that is wrong** for handles and a popover: which feed it is, whether it is a screen share, whether to use this box when the feed is visible twice, and how far the fix applies. The choices for extent are from here on, until the next layout change, the whole recording, or the marked range.
- **Drag inside a layout cell** to reframe it. This replaces the two anchor sliders.
- **Source and Output** toggle on the monitor. Output shows the result. Source shows the recording with its boxes, which is where boxes are fixed.
- **Every drag has a keyboard and menu equivalent.** Merging cards, reframing a cell and moving a span edge replace sliders, typed values and menus that work from the keyboard today.

### On the timeline

- **A badge on the clip** when it has tile edits.
- **A layout lane** under the clip, or under Switches in a multicam project. Each segment names what the frame shows. It is cut with marks like any other lane.
- **A feed lane**, collapsed by default. One thin row per feed shows when it is on screen, with layout-change ticks and unverified stretches hatched. Dragging a span edge replaces typed seconds.
- **In a multicam project** the lane shows timed layouts on the group clock in Group view. In Assembly view it also shows the overrides that apply to a single occurrence, so the precedence between the two is visible.

### Where outputs live

| Outcome | Place |
| --- | --- |
| Cut between feeds | Switch lane and Take, after the feeds are angles |
| Proposed cuts from the transcript | Shown on the switch lane, accepted or deleted there |
| Side by side, grid, arranged | Layout lane and the monitor |
| One feed or every feed as an ISO, with a project and a manifest | Export ISOs, the same operation as `mpcut tiles export-isos` |
| Layout changes as cut points | Scene markers, with Previous Scene, Next Scene and Snap To |
| Output size and frame rate | Export settings |

### Words

| Today | Planned |
| --- | --- |
| Feeds, as the name of the panel and toolbar button | Tiles |
| Participant, Roster | Feed. One that is a person is shown by name. |
| Appearance | Tile |
| Geometry | A tile's box |
| Source Analysis, Scan Participants, Scan Feeds | Find Tiles |
| Accept Geometry | Use These Tiles |
| Reflow | Layout change |
| Coverage: verified, inferred, unknown | Checked, inferred, unknown |
| Reconciliation | The recording changed |
| Presentation | Screen share |
| Bind Audio, Bind Transcript Speakers | Mic, Voice |
| Composition, shot, slot | Layout, cell |
| Virtual angle | Feed angle |
| Render Angle Media… | Export ISOs |
| Participant ISO, as an audio choice | ISO microphone |
| TileTrail, in interface text | Not named |

**Decided names.** A **tile** is the visible square and a **feed** is the thing followed over time. An **ISO** is one feed's own synchronized movie, and an **ISO microphone** is its isolated audio. The feature, the panel and its toolbar button are called **Tiles**, and the CLI namespace is `mpcut tiles`. Identifiers are `tile_id` and `feed_id`. Status text names both levels, for example "25 tiles visible at 12:04 · 40 feeds in this recording". The `mpcut participants` commands and their JSON fields stay compatible for scripts. See [One contract](#one-contract-app-cli-and-mcp).

Feed replaced the earlier working name tile-unique. It is a noun, the app and its guide already use it for the thing a tile shows, and an ISO is an isolated feed. The TileTrail library uses feed in its own code for the boxes of a grid, which is closer to a tile; that naming is internal to the library.

### Both editors

The sequence sidebar and the multicam inspector host the same panel. Choosing Tiles in the multicam inspector switches it to the full-height panel.

## What each existing control becomes

This table covers the app's controls. The commands and tools that sit behind them are covered under [One contract](#one-contract-app-cli-and-mcp).

| Control | Outcome |
| --- | --- |
| Scan Layout picker and scan button | The three choices in Find |
| "Source 0 s · Verified coverage" | Removed; Needs a Look replaces it |
| Accept Geometry | The Check step |
| Review Reconciliation… | A row under Needs a Look, shown when the recording changed |
| Confirm Reviewed Coverage… | Kept for a replaced recording, and as the explicit override that clears unchecked footage for a hidden feed. See [Privacy](#privacy). |
| Roster and rename field | The feed list, renamed in place |
| Previous and Next Appearance, Next Uncertain, Before, After and Next Reflow | Removed; the feed lane and Needs a Look replace them |
| Bind Audio, Bind Transcript Speakers | Mic and Voice on the row; a single unambiguous name match is applied automatically and can be undone |
| Draw Box, Redraw Box, New Box, Apply Bounds, Discard Box | On the picture, from stage 6. Kept until then. |
| Link Appearance, Split Here, Mark Presentation, Use This Appearance | The box popover, from stage 6. Kept until then. |
| Typed From and To seconds, in three places | Marks, span edges and the extent choices |
| Layout Change Markers rule builder | The list is available whenever a scan exists; the rules sit behind a filter |
| Canvas width, height, frame rate | Export settings, as presets with a custom entry |
| Shots, timed shots, clock, current occurrence only | The layout lane |
| Participant Masks, Unresolved Coverage | Hide on the feed row, and the export check |
| Soundtrack | The project's audio controls, with a feed's microphone as a choice |
| Save Composition, Check Export, Preview | Removed. Changes commit as they are made, the check runs on its own, and the monitor is the preview. |
| Review Virtual Angles, Take at Playhead | Kept, moved into the panel, until Use Feeds as Multicam Angles and the ordinary Take replace them in stage 5 |
| Suggest Dialogue Switches | Proposed cuts on the switch lane for multicam projects from stage 2. The existing tool is kept until stage 5. |
| Render Angle Media… | Export ISOs, with a plan to review, a manifest and a verify step |

## Engine

### The picture pipeline

The pipeline is one interface that every consumer calls. Its inputs are a set of decoded frames keyed by source, the clip and time, and the output size, frame rate and colour. Its output is one frame. It applies treatments first and layout second.

The crop, scale, blur and compositing code exists and is written in Core Image. It is built for export: it decodes through a software path, renders at the canvas frame rate, and writes sRGB RGBA8. Each consumer needs more than a call to it.

| Consumer | Today | What it must add |
| --- | --- | --- |
| Monitor | Shows the decoder's own pixel buffer. It maps the buffer only to bring HDR to an SDR display. | A pixel buffer in and a pixel buffer out at playback rate, HDR kept intact, and several sources decoded at once for a multicam layout that combines cameras. |
| Timeline thumbnails | Cached per source by time and size. | A cache key that includes the clip's layout and treatments, or no caching for treated clips. |
| Movie export | A separate renderer, balanced H.264 only, that refuses still inserts and replacements. | The ordinary export engines render layouts and treatments. The review counted about thirty places that branch on a saved composition today. |
| Current-frame, JPEG, selection and queued exports, and automation review frames | Refused when a composition is saved. | The same call, with the privacy gate. |
| Frame timing | Output is resampled to the canvas frame rate. | A stated rule for variable-frame-rate sources, so an ISO stays aligned with its source. |

An export that copies streams without re-encoding cannot apply a layout or a treatment, and says so at the point of export.

Several feeds cut from one recording can share one decode of each frame, which the compositor already does within one output. Writing many movies from one pass over the source is new work.

### Privacy

Hiding someone is the one place where a mistake exposes a person. This section replaces the rule the feature has today, because today's rule cannot be extended as it stands.

**What the gate does today**

- **Only footage analysed frame by frame counts as verified.** The default adaptive scan marks the stable stretches it skips as inferred, and the desktop app always scans adaptively. Inferred footage does not pass. This is intended and documented: a verified redaction needs a frame-by-frame scan, which the CLI offers as `--sampling every-frame` and the panel has no control for.
- **The gate tests the whole source frame.** If any feed in the project has a treatment, a frame is covered or the export stops when that frame is unverified or contains an unassigned box. It does not look at which tile the output shows.
- **A recording with no scan counts as unverified.**
- **Every angle inherits every treatment in the project.**
- **The single-frame renderer covers silently.** It returns a blank frame with no error and no report.

**What follows from that**

- Hiding or blurring someone on a default scan blanks most of the output, or stops the export, depending on the stop-or-cover setting.
- Every angle inherits every treatment, so one hidden feed blanks or stops the unchecked stretches of every other person's ISO as well.
- A second, unscanned video in the same project is covered once anyone is hidden.
- Checked footage with a treatment exports correctly today, and the tests check the covered pixels. That keeps working.

**The rule this plan proposes**

Points 1, 2, 4 and 5 go beyond what is recorded under [Decided](#decided). They came from the second review and are listed under [Open decisions](#open-decisions) until confirmed. This rule has been rewritten after each review, so it is not trusted until it passes the private-delivery fixture.

1. **Scope by recording.** The gate applies to every recording that could show a treated feed. That means a recording where any tile is or ever was linked to that feed, one with tiles waiting to be assigned, and one that was replaced on disk and not yet re-checked. Removing the last link does not switch the gate off. A recording that was never scanned passes, as decided, and the guarantee says so in plain words: hiding someone protects the recordings that were scanned, where that person was recognised as that feed. The same person detected as a separate feed in another recording is not hidden until the two are merged. The app lists any unscanned recordings whenever a feed is hidden.
2. **Scope by what the output shows.** An output of the whole picture needs every stretch of the hidden feed checked. An output of one crop, such as a Solo, a cell or an ISO, passes on a checked frame when no unassigned tile overlaps the crop and any part of a treated feed's tile inside the crop has its treatment applied. On an inferred or unknown frame the positions are not known, so a crop is gated exactly like the whole picture.
3. **Three states, not two.** Footage is checked, inferred or unknown. The words table keeps all three.
4. **Checking has two parts.** A frame-by-frame pass over the recording removes the doubt that a stretch was skipped. It does not show that a box is linked to the right feed: a confident wrong link survives every frame. So the test is made frame by frame: a frame counts as checked when the pass observed it and it lies outside every open issue for that recording, such as a return, an unassigned tile or an ambiguous match under Needs a Look. The pass must keep the editor's reviewed links; today a rescan can discard them when tracks stop matching.
5. **A confirmation is tied to what was reviewed.** The editor's override records the recording, the scan it was made against, the feed and the range. A later edit to that feed's tiles, a rescan or a replaced recording cancels it.
6. **Never silent.** A gated output either stops with the timestamp or covers the frame and reports it.
7. **Treatments before layout**, on the source picture, as today.

The pass is cheap: the scan work in progress reports about a minute for a frame-by-frame scan of a two-hour call in an optimized build, against a few seconds for the adaptive one. Two details are for stage 0. A recording accepted from one kind of scan asks for reconciliation when it is scanned again the other way, and the scan file records an adaptive scan as every-frame with mixed coverage, so the pass has to be told apart from the first scan.

**No path shows untreated pixels by accident**

- **Output playback never falls back to the source.** If the pipeline cannot keep up, the monitor drops frames or shows the cover. It does not show the untreated recording under an Output label.
- **Source review is asked for by name.** The Source view, the Check cards, `mpcut tiles preview` and a review frame of a single camera angle all show untreated pixels. Each is a separate, labelled request. The automation tool that returns a camera angle's frame today does so even when a composition is saved; it becomes a source review like the others.
- **One decision for every export.** From the moment treatments are stored outside the composition, every export path asks one shared question: does this output render the treatment, or refuse? The test is "this project has a layout or a treatment", not "a composition is saved". Without that, an export that only checks for a saved composition would write the untreated picture.

**Who gets an ISO is separate from how they look**

A treatment says how a feed looks wherever it appears. Which feeds get their own ISO is chosen in the export, with `--all`, `--feed-id` or an exclusion. So one person can be left out of the ISOs and blurred in the full gallery in the same delivery.

| Case | Result |
| --- | --- |
| A feed excluded from the export | No ISO, no ISO microphone, listed in the manifest as withheld |
| A feed with cover or remove | `--all` skips it and lists it as withheld, and the run still succeeds. Naming it with `--feed-id` is refused, since a covered ISO is an empty movie. |
| A feed with blur, selected for an ISO | Written blurred |
| Another feed's ISO whose crop overlaps a treated feed's tile | The treatment is applied to those pixels |
| The full gallery with one feed blurred | Exports where that feed is checked; stops or covers elsewhere |

**Every output, not only the picture**

| Output | Rule |
| --- | --- |
| Movie, frame, JPEG sequence, review frame | Gated as above |
| Timeline thumbnails | Output thumbnails are kept apart from source thumbnails. A change to a treatment, a link, a box or a confirmation discards the output ones, in memory and on disk. |
| Shared meeting mix | Still carries a hidden person's voice. The export warns and records it in the manifest, and offers to leave the mix out. |
| ISO microphone of a withheld feed | Not written |
| Manifest and filenames | A withheld feed is listed by ID, without its display name |
| Delivered `multicam.cut` | Carries no name for a withheld feed |
| Transcript and caption exports | A picture treatment does not remove words. The export warns. |
| Source review views | Untreated by design. Labelled, asked for by name, and never written into a delivery folder. |

A name drawn outside its tile is not covered. Accepted scans carry no label box today, so a treatment covers the tile and nothing beside it.

### Project format

Every stored addition is designed once, in stage 0. Every participant type rejects unknown keys today, so a project that uses a new field does not open in an older build.

| Stored addition | Needed by |
| --- | --- |
| Count hints and review status | ISO export |
| Feed IDs that survive a second run | ISO export. Accepting a scan generates random IDs today. |
| Grid corrections for a stretch | Detection |
| Layout-change events, stored when a scan is accepted | Needs a Look and `tiles inspect` on a project. The project stores tiles and coverage today, not the detector's events. |
| Pending scan | The Check step |
| Treatments on the feed, outside any layout | Hide and blur without a composition. They are a field of the composition today. |
| A screen share as a feed | The model. A screen share is a tile with no feed today, addressed by tile ID, and it cannot take a treatment. |
| Layouts anchored to the clip | Requirement 3. In a sequence project, stored with a clip ID and a range in that clip's source time, as still replacements are. A split divides the layout between the two clips and a duplicate copies it, as the still edits already do. |
| A reading of old timed shots | Old projects and old scripts. A timed shot on output time becomes a clip layout, and the old commands still see it as a timed shot. |
| A stable key for a multicam occurrence override | Requirement 3. The override is keyed by position in the assembly today, so reordering leaves it behind. |
| The arranged layout, and grids beyond four cells | Reorder and remove in place |
| Feed angles | Multicam angles with nothing rendered |
| A recorded confirmation per feed | Privacy, as the override that clears unchecked footage |
| One record per person shared with transcript tracks | Linking microphone and voice |
| One output-format setting | The layout canvas and the still-timeline format are separate today, and export refuses a project that sets both. |

The additions ship in two steps: a small one with ISO export and detection, and the main one with the live layout. Stage 0 fixes the whole design before either ships.

Existing projects keep opening, as the working tree reads older schemas today. A saved composition is converted: its default layout becomes a layout on each clip of that recording. This departs from the app-wide naming plan, which says old native documents will not open.

## One contract: app, CLI and MCP

A user should be able to point MPCut at a recording and export every source in one command. An editor or agent should also be able to scan once, inspect a particular moment, correct an assignment, render one ISO, or verify an existing delivery, each on its own. The one-shot command, the separate commands and the app all call the same underlying operations, with the same names, IDs, checks and reports.

The commands below are proposed syntax. The installed CLI uses `mpcut participants` today. Those commands and their JSON fields stay compatible for scripts. That is an exception to the [app-wide naming plan](APP-NAMING-PLAN.md), which deletes retired names.

Compatible has a boundary. The old commands keep working for everything they can express today. The old JSON cannot describe a layout on one clip, an arranged layout, a grid of more than four cells or a screen share that is a feed, so an old command meeting one of those in a project reports it clearly and changes nothing.

Compatibility has a cost after the main format step. That step moves treatments out of the composition and replaces timed shots with clip layouts, so the stored shape no longer matches the old JSON. The old commands then work through a translation: a project that uses only what the old shape can express is read and written as the old JSON, and anything else is reported. That translation is extra code to build, test and keep.

MCP follows the CLI. Each command has a file tool for media or a saved project and, from stage 3, an editor tool for the open project, including its unsaved revision. Their names come from the command, so `mpcut tiles link` is `tiles_file_link` and `tiles_editor_link`. An editor tool that changes the project takes the project handle and revision and adds one undo step. One that only reads adds none. A job that finishes later, such as a scan, checks the revision again before it commits, so it cannot attach to a state the user has since undone.

### One-shot ISO export

```sh
mpcut tiles export-isos meeting.mp4 --output ISOs
```

For a recording where the operator knows roughly what to expect:

```sh
mpcut tiles export-isos meeting.mp4 --output ISOs \
  --expected-feeds 40 --max-visible-tiles 25
```

For a project already reviewed in MPCut:

```sh
mpcut tiles export-isos reviewed.cut --output ISOs
```

- **From a raw recording** the command determines the duration, scans, builds the feed list, checks for issues, plans the outputs and renders.
- **From a reviewed project** it starts from the saved boxes, assignments, preferences and audio bindings.
- **Neither route needs** `jq`, a manually created project, a list of every ID or hand-authored render JSON.
- **The two count hints are optional checks.** If MPCut sees 64 boxes where the operator gave a maximum of 25, it keeps the scan, reports the first affected timestamp and prints the command to inspect it. An expected total of 40 never causes the tracker to merge or discard detections to reach 40.
- **Unattended runs finish when the checks pass.** When an issue needs a decision, the command saves a reviewable project and returns `needs_review` with timestamps. `--on-uncertain blank` is for jobs where the operator prefers blank intervals and a report. Running again after review picks up the corrections. The second run works from the saved review project, since a fresh scan of the recording would produce new IDs. Whether the same command on the recording finds that project by itself is settled in the contract below.
- **A hidden feed** is never written unhidden. `--all` skips a covered or removed feed and lists it as withheld. See the table under [Privacy](#privacy).
- **Audio from a raw recording is the shared mix.** The command has no way to take separate microphone files or sync them. An ISO microphone comes from a reviewed multicam project that has it bound.
- **In the app** the same operation is **Export ISOs**. A project saved by a `needs_review` run opens in the app like any project. Its issues are read with `mpcut tiles inspect --issues` at first and are listed under Needs a Look from stage 3.

**The `needs_review` contract** is written in stage 0, before the command ships. It has to say:

- which findings count as needing a decision, given that a default scan always has inferred stretches and often has unassigned boxes;
- whether any movies are written before the status is returned;
- where the review project is saved, and that the second run takes that project;
- how `--on-uncertain blank` relates to today's stop-or-cover choice, which blanks the whole frame;
- which issues have a timestamp and which are warnings about the whole recording, since 39 feeds found against 40 expected has no first bad moment;
- the command that resolves or acknowledges each kind of issue;
- the JSON shape, the exit code, and how an MCP file job reports the status, since the job runner reports every exit code other than 0 and 130 as failed today;
- where the count hints are stored, so the app shows the same warning.

### Building blocks

Each command produces something useful on its own. The stage is when it reaches the CLI and the file tools. The app column names where the same operation lives once the panel is rebuilt in stage 3. Until then the existing panel covers what it already can, and Export ISOs is the one app addition in stage 1.

Feeds are one list for the whole project today. A command that reads or changes tiles takes `--source-id` when the project has more than one scanned recording, and reports its counts for that recording.

| Proposed command | Independent use | In the app | Today | Stage |
| --- | --- | --- | --- | --- |
| `mpcut tiles scan` | Analyze a recording and save a reusable scan. Expose sampling, backend, layout hints and progress. When saving to a file, return a small result with the path, counts and coverage. | Find | `participants scan`, which already has sampling, backend, progress and resume | 1 |
| `mpcut tiles inspect` | Query visible tiles at `--at TIME`, appearances and gaps over a range, layout changes, or `--issues`. Accept a raw scan or a reviewed project. The project view includes corrections. | Panel, lanes and Needs a Look | `participants project inspect` for a project only, with no issue list; `participants markers build` for layout changes | 1 |
| `mpcut tiles preview` | Write an annotated source frame, or a before and after image for an issue. Useful for a broken box, a gallery rearrangement or a possible return. | Monitor Source view and the return review | App only | 1 |
| `mpcut tiles link` | Assign a `tile_id` to a `feed_id`. A source-time range lets a correction apply to part of a tile's recorded span. | Box popover | Whole-object `participants project apply` | 1 |
| `mpcut tiles feeds list`, `inspect` | List distinct feeds, or inspect one across the recording with its simultaneous tiles, offscreen gaps, mic and transcript voice. | Feed rows and lane | Inside `participants project inspect` | 1 |
| `mpcut tiles feeds rename`, `mic`, `voice`, `treatment`, `prefer` | Change one property without replacing the whole project document. `prefer` chooses the tile to use during an overlap. `treatment` controls hide or blur across that feed's appearances. | Row menus and tile menu | Whole-object `participants project apply` | 1; `treatment` in 3, once treatments are stored outside the composition |
| `mpcut tiles angles plan` | Select `--all` or repeat `--feed-id ID`. Preview filenames, duration, resolution, gaps, unresolved assignments, audio routing and estimated output size. Save an executable plan. | Export ISOs, review step | `participants angles plan`, from a request file | 1 |
| `mpcut tiles angles render` | Render a saved plan, all selected feeds, or one. Support cancellation, progress and resume. | Export ISOs | `participants angles render`, one full pass per angle, files named `angle-N.mov` | 1; one pass in 4 |
| `mpcut tiles angles verify` | Check an existing delivery against its manifest for missing or stale files, duration and start-time mismatches, and unexpected audio tracks. | Export ISOs, after rendering | None | 1 |
| `mpcut tiles export-isos` | Run the full workflow from a recording or a reviewed project with sensible defaults. | Export ISOs | None; the steps are run by hand | 1 |

Investigating one bad layout takes two commands:

```sh
mpcut tiles inspect meeting.json --issues --json
mpcut tiles preview meeting.json --at 00:32:10 --output gallery.png
```

Exporting one reviewed feed:

```sh
mpcut tiles angles plan --project reviewed.cut \
  --feed-id u017 --output alice.plan.json

mpcut tiles angles render --plan alice.plan.json --output Alice-ISO
```

Here `u017` stands for a feed ID. Today's IDs are long random strings, so a short form is part of the stage 0 design.

A saved plan is directly executable and identifies the source and the project revision it was built from. An editor can inspect exactly what will render, and an agent can detect that a plan has become stale.

### Operations the app side adds

The app plan needs these as well. They follow the same style and are also proposed syntax.

| Proposed command | Use | In the app | Today | Stage |
| --- | --- | --- | --- | --- |
| `mpcut tiles feeds merge`, `split` | Merge mistaken duplicates, or split a mistaken match. Each is one undoable change with a report of conflicts. A merged feed keeps the stricter treatment, a split never unhides a branch, and both cancel earlier confirmations. | Check, and the return review | Whole-object `participants project apply` | 1 |
| `mpcut tiles grid correct` | Correct the grid for an affected stretch so the boxes are right before identities are repaired. Links, preferences and treatments already made on the old boxes are carried to the new ones where they correspond, and reported where they do not. | Check | None | 2 |
| `mpcut tiles accept` | Take a scan into a project | Check, Use These Tiles | `participants project accept` | 1. The same operation, which from this stage also stores layout changes and the count hints |
| `mpcut tiles reconcile` | Report what a replaced recording changes, and apply the reviewed result | Needs a Look | App only | 3 |
| `mpcut tiles feeds confirm` | Record that one feed was reviewed | Needs a Look | App only | 3 |
| `mpcut tiles layout set`, `list` | Set what the frame shows on a clip, with `--clip-id` and a source-time range | Monitor and layout lane | A render plan inside `participants project apply` | 3 |
| Composed frame | See the result at a time | Monitor | Existing frame export and review frames, which refuse a saved composition today | 3 |
| `mpcut tiles angles use` | Use feeds as multicam angles in the current project, with no rendering | Use Feeds as Multicam Angles | `participants angles list` and `angles take` | 5 |
| `mpcut tiles switches propose` | Propose cuts from the transcript. A proposal names the project revision it was made for and is accepted with the ordinary switch edit. | Switch lane | App only | 2, on rendered angles |
| `mpcut tiles box add`, `box set`, `tile split`, `tile screen-share` | Draw a box, correct its bounds, split a tile at a time, or mark a tile as a screen share | Box popover | Whole-object `participants project apply`; the app's box controls | 6 |

**Two ways to get angles.** `angles render` and `export-isos` write movies and a `multicam.cut`, which is an MPCut project. Another editor takes the movies, or the project through MPCut's interchange export. `angles use` makes angles inside the current project from the feeds themselves, with nothing rendered, and needs the format change.

### Flag differences from the existing CLI

The proposal's syntax differed from the installed commands in the places below. Each is decided as the last column says, and the examples in this plan use the decided form.

| Proposed | Existing | Decided |
| --- | --- | --- |
| `--out` | `--output` | Use `--output` |
| Positional input, such as `meeting.mp4` or `meeting.scan` | `--file`, `--project`, `--analysis-file`; `export ranges separate SOURCE` already takes a positional | Keep the positional for `export-isos`, `inspect` and `preview`, and accept the flags too |
| `--at TIME` | The naming convention asks a time to name its clock | Keep `--at` and define it as source time; write `source_time` in JSON |
| `--feed ID` | `--source-id` | Use `--feed-id` and `--tile-id` |
| `--gallery-grid 5x5` | `--feed-layout auto\|COLSxROWS`. Leaving it out means a meeting, `auto` means an automatic multiview, and a size means a fixed switcher grid. | Add `--gallery-grid` as a hint for a meeting, and leave `--feed-layout` as it is |
| `tiles scan` returns a small result when saving to a file | `participants scan` prints the whole scan to standard output after writing the file | The small result is for `tiles scan` only; the old command keeps its output |
| Positional input on `tiles` commands | The participant parser rejects any positional argument | The parser changes for the commands that take one |
| Repeated `--feed ID` | A repeated option is an error | Allow `--feed-id` to repeat on the `tiles` commands |
| A scan saved as `meeting.scan` | A saved scan must be a new `.json` file | Keep `.json` |
| `tiles link`, `feeds rename` and the other edits, with no destination shown | Every command that changes a project requires `--out-project FILE` or `--in-place` | Require the same on every `tiles` command that changes a project |
| `angles plan` and `angles render` with flags | The angle commands take only a JSON request through `--stdin` or `--input`, and the request must give a range and a canvas | Accept flags and a request file. Default the range to the full recording, and the canvas to the source size and frame rate. |
| A separate `plan` step | Exports elsewhere use `--dry-run` | Keep `plan`, since its output is an executable file, and accept `--dry-run` on `export-isos` |
| `--size` with no frame rate | The canvas defaults to 1920 × 1080 at 30 | Add a frame-rate option and default it to the source rate |
| `--at TIME` on a project | The still commands already pair `--at` with `--clock` | Accept `--clock source` for the same meaning |

`--progress jsonl` exists on `participants scan` as `none|stderr|jsonl`. Angle rendering does not accept it today, so it is added there.

### Export defaults and outputs

Default to the full recording duration, a shared start time, fit framing, black offscreen gaps and visible camera-off cards. Expose `--size`, `--fit fit|fill`, `--gap-color` and `--camera-off keep|blank`. Use the feed's preferred tile when several are visible.

For a one-hour recording with 40 selected feeds, the folder contains:

| Output | Contents |
| --- | --- |
| 40 synchronized movies | One full-hour movie per selected feed. Recognizable filenames, with stable IDs to tell duplicate names apart. Offscreen time is preserved so every movie stays aligned. |
| `meeting-mix.mov` | One copy of the shared meeting audio, when available and selected. |
| `multicam.cut` | A project with the rendered movies aligned and named as multicam angles. |
| Delivery manifest | Filename, feed ID, display name, visible and uncertain intervals, mic and transcript bindings, settings and render status. |

A bound ISO microphone can continue while its feed is offscreen. If only mixed audio exists, deliver the shared mix and identify which movies lack an isolated mic. A transcript voice binding supports highlighting and editing and cannot produce isolated audio.

### Detection and review

- **A gallery hint is different from a fixed switcher grid.** A proposed `--gallery-grid 5x5` helps locate boxes while that gallery layout is visible. Alice's feed follows her if she moves from cell 4 to cell 19. In fixed-grid mode, cell 4 keeps its identity when a switcher routes a different camera into it. Both are useful.
- **Correct a bad layout once.** If a detector splits 25 real tiles into dozens of smaller boxes, the editor corrects the grid for the affected stretch. That fixes the geometry before anyone repairs identities built on it.
- **Review ambiguous returns side by side.** Show the last frame before departure and the first frame after return, with Same feed, Different feed and Leave unresolved. Support merging mistaken duplicates, splitting mistaken matches, and relinking a tile over a selected time range.
- **Test whose picture it is, not only the count.** The synthetic test behind this proposal had 25 genuine tiles on screen and 40 distinct sources. Both tested sampling modes reported 64 boxes per sampled frame and 164 identities. Acceptance testing checks whose picture appears before and after moves, departures and returns. A correct final count can still hide swapped identities.

### Long jobs

- **Progress.** Show scan percentage, render percentage, completed angles out of the total, and an estimate of time remaining when one can be made. Use a terminal progress bar for people and `--progress jsonl` on stderr for agents. Standard output is reserved for the command result.
- **Resume.** Checkpoint scans incrementally and reuse completed, verified movies. If a correction moves a tile from Alice to Bob, invalidate every movie it affects and keep the rest. That is not always two: if Alice is hidden, a tile newly linked to her changes the mask in any other feed's movie whose crop includes it. Refuse to overwrite unrelated files.
- **Resume needs a new delivery folder.** Angle rendering today refuses an existing folder, renders into a hidden staging folder that is deleted on any failure, and moves it into place at the end. Nothing survives an interrupted run. Stage 0 designs the folder: what a partial one contains, what the manifest records per movie to decide whether it is still valid (source identity, tile boxes, every treatment that falls inside its crop, the checked state, canvas, audio binding and preferences), that partial files stay hidden until the final manifest lists them, and how the must-be-new rule changes. A paused scan today resumes by replaying the decoded prefix to rebuild the tracker, so incremental checkpoints are also new.
- **Scale.** Remove the one-shot workflow's dependency on importing a single scan JSON, which the CLI caps at 1 GiB today. The adaptive scan's output is reported to be about fifteen times smaller than a frame-by-frame one, which eases the cap and does not remove it. Share source decoding across crops so that exporting 40 synchronized movies reads the source in one pass. Forty encoders at once need bounded buffering and a check of free disk space first: at source size, a two-hour call is 80 hours of movie. A saved project is also capped at 64 MiB, so the review project for a long, dense call has to be shown to fit.
- **Automation.** Provide versioned `--json` results, stable IDs, documented exit codes, and examples under each command's `--help`. Distinguish success, failure, interruption and `needs_review`. Include artifact paths, issue timestamps and the suggested next command. The CLI documents 0, 1, 2 and 130 today, so `needs_review` needs its own code.

### TileTrail and MPCut

TileTrail owns rectangle detection, source-time tracking, layout interpretation and the evidence for possible matches. A generic `tiletrail scan` and `tiletrail inspect` use the same Rust analysis and scan format that MPCut consumes. A compatible standalone scan can be imported into MPCut without decoding and analyzing the recording again.

Two things stand between that and today's code. TileTrail is a library with no decoder and no command-line program: the caller feeds it frames, and the video chat plan keeps decoding out of it. And MPCut does not import the detector's output directly. It wraps it with the recording's identity and checks that identity against the project's media, and adaptive sampling, pause and resume, and the cache all live on the MPCut side. A standalone `tiletrail scan` therefore needs a decoder of its own. Its output must record which file it came from, with the stream, time origin, display transform and sampling, so that MPCut can check that record against the recording. Stamping the identity at import would only show which file is present now, not which file produced the boxes. It is a separate program beside the library, so the library itself still takes frames from its caller.

MPCut owns reviewed feed identities, corrections, mic and transcript bindings, treatments, preferred tiles, multicam choices and media delivery. Its app and CLI share those operations.

### Today's commands

All eleven `participants` commands and tools stay as entry points with their current JSON fields.

| Today | Equivalent |
| --- | --- |
| `participants scan` | `tiles scan` |
| `participants markers build` | `tiles inspect`, layout changes |
| `participants project inspect` | `tiles inspect` on a project, and `tiles feeds list` |
| `participants project accept` | `tiles accept` |
| `participants project apply` | The single-property commands; kept for whole-object edits |
| `participants render plan`, `render export` | `export project render` once there is one export path |
| `participants angles list`, `angles take` | `tiles angles use` and the ordinary switch edit |
| `participants angles plan`, `angles render` | `tiles angles plan`, `tiles angles render` |

The rules `participants markers build` takes today, such as how many feeds must change and which kinds of change count, become options on the layout-change query of `tiles inspect`.

### Gaps this closes

The [CLI and MCP parity review](CLI-MCP-PARITY-REVIEW.md) lists five gaps for this feature.

| Gap | Closed by | Stage |
| --- | --- | --- |
| No editor tools; all eleven tools work on files | A `tiles_editor_` tool for every command | 3 onwards |
| The panel cannot be opened or inspected through MCP; the published schema leaves it out | The Tiles panel in the workspace tools | 3 |
| Reconciliation is app only | `tiles reconcile` and `tiles feeds confirm` | 3 |
| No composed review frame | Frame export and review frames go through the gated pipeline | 3 |
| Dialogue proposals are app only | `tiles switches propose` | 2 |

### Documents and tests

New commands reach [CLI.md](CLI.md), the CLI help, the MCP catalog, the generated [MCP reference](MCP-REFERENCE.md) and the agent guide in the same commit. The packaging tests compare the reference with the catalog. The format change also reaches [CUT-FORMAT.md](CUT-FORMAT.md) and [PARTICIPANTS.md](PARTICIPANTS.md).

## What this overturns and what it keeps

**Overturned from the video chat plan**

- A participants inspector with a roster and source geometry as its organizing sections.
- "Save layout changes as timed decisions" as a list of shots edited in a sheet.
- Virtual angles expressed as shots, with a separate take command.
- A separate renderer for compositions, and "preview the output composition beside the source".
- Output-time shots as the anchor in sequence projects.

**Kept**

- Tile, feed and layout as three separate things.
- Boxes stored against the source in source time, with corrections applying to every occurrence.
- In multicam, timed group layouts as the default and a per-occurrence override.
- The rule for choosing between a stage and a thumbnail appearance, with a time-scoped override.
- Treatments resolved on the source before cropping, and the stop-or-cover choice for unchecked frames.
- One shared decode for several crops of the same frame.
- Rendering angle files for other editors.
- The detector, its scan modes and its cache, with the detection work listed under [One contract](#one-contract-app-cli-and-mcp): a gallery hint, grid correction for a stretch, evidence for returns, and a generic `tiletrail` CLI on the same scan format.

## Stages

The [stage 0 design record](FEEDS-STAGE-0.md) specifies the command inventory, migration, privacy, review, delivery and acceptance criteria. It describes the target contract and records the legacy entry points separately.

Each stage leaves the app usable. Each check in the last column can be run headless with what that stage ships. Requirements 3 and 6 are met from stage 3 and requirement 2 from stage 4. The limits before then are listed below the table.

Five rules set the order:

- The whole format is designed in stage 0, before any of it ships.
- Hide and blur get their own commands only once treatments are stored outside the composition.
- A control is removed only in the stage that ships its replacement.
- Cutting between feeds with nothing rendered is the intended way and is required. It needs the format step and an export that can render it, so it follows stage 4. Rendered angles are an early stopgap, because they already exist as files.
- Privacy is tested from the start, on one small fixture that every stage must keep passing.

| Stage | App | CLI, MCP and TileTrail | Done when |
| --- | --- | --- | --- |
| 0. Measure and design | Accessibility identifiers, and the desktop test moved onto them. A throwaway monitor prototype: pixel buffer in, treatment and crop, pixel buffer out. | The format design with every stored addition, including what a layout does on split, duplicate and trim, and how an old timed shot is read. The privacy gate's new scope. The `needs_review` contract and the delivery-folder design. An inventory with one row per command. Two committed fixtures: a detection test with 25 tiles and 40 sources, with a test at the detector's box limit, and a small private-delivery test with a hidden person in an inset, a second clip of the same recording, a replaced file, a shared mix and an interrupted export. Thresholds for missed tiles, false tiles and swapped identities. | The prototype is timed at 1080p and 4K with blur on a dense gallery, and HDR is traced through it. A two-hour, 40-feed review project is saved, reopened, edited and undone inside the project size limit. Each design named here is written and reviewed. |
| 1. ISO export on today's detector | Export ISOs, calling the same operation, with a plan to review and a verify step. | `tiles scan`, `inspect`, `preview`, `link`, `accept`, `feeds list`, `inspect`, `rename`, `mic`, `voice`, `prefer`, `merge` and `split`, `angles plan`, `render` and `verify`, and `export-isos`. File tools for each. Progress, the manifest, `needs_review` and the resumable delivery folder. | A small reviewed project and a raw recording that today's detector handles both export, and `angles verify` passes. A run interrupted mid-movie resumes, and a correction made before resuming re-renders every movie it affects. A second run on the saved review project keeps its feed IDs. The private-delivery fixture behaves as today's gate does. Today's `participants` script still produces the same output. |
| 2. Detection, and cuts from the transcript | Proposed cuts on the switch lane of any multicam project, including the one Export ISOs writes, with a step that links each transcript voice to an angle. Both counts shown in the existing panel. | The gallery hint beside the fixed grid. Grid correction for a stretch. Evidence for returns in `inspect` and `preview`. `tiles switches propose`, accepted with the ordinary switch edit. `tiletrail scan` and `tiletrail inspect` last, once the scan carries its own record of which file it came from. | On the committed test, the measured rates meet the stage 0 thresholds, and every unresolved move, departure or return is reported as an issue with its timestamp. On the project `export-isos` wrote, a transcript is made, its voices are linked to angles, cuts are proposed, accepted and undone, and the switch coverage report is complete. |
| 3. Format, gate and live layout | The main format step. Treatments move out of the composition. Changes commit as they are made. The monitor shows the output, with a Source and Output toggle. The clip badge, layout lane and feed lane. The sheet's layout, mask, canvas and soundtrack controls are replaced. The panel becomes Find, Check and Fix with a recording picker, Needs a Look, grid correction and the return review. Hide and Blur on the tile. Marks replace typed seconds. Keyboard and menu equivalents for every drag. The words table. The even grid in a build without the analyzer. | The rescoped privacy gate, and the one shared export decision. `feeds treatment`, `feeds confirm`, `tiles layout set` and `list` with their final arguments, and `tiles reconcile`. Frame export and review frames through the gated pipeline. Editor tools for every command shipped so far. | A layout set through an editor tool is in the next review frame with no save call. After a clip is moved behind another video, `inspect` shows the layout on the moved clip and none on the other. A project with the Original layout and one blurred feed either renders the blur or refuses, through ordinary, stream-copy, selection, queued and frame export. The private-delivery fixture passes under the new gate. A project saved before the format step opens, and today's `participants` script gives the same rendered frames on it. |
| 4. One export path | Layout changes among the scene markers. | The ordinary export renders layouts and treatments, with the codec and still limits lifted. Selection and queued exports. `export-isos` and `angles render` read the source once for all movies, with bounded memory, a disk-space estimate before starting, and a fallback to fewer movies at a time. | A project with a layout exports through `export project render` in a codec other than H.264. A 40-feed export decodes the source once, stays inside a stated memory limit, and resumes correctly after an interruption. |
| 5. Feed angles with nothing rendered | Use Feeds as Multicam Angles. One record per person shared with transcript tracks. Linking by name. Take at Playhead and the old dialogue suggestions are retired. | `tiles angles use`. | A call is converted with nothing rendered and with no ISO export run, cut from its transcript, and the project exports a movie. |
| 6. Editing on the picture | Swap and Remove on a tile. The box popover, replacing the old box controls. Reframing by drag. | `tiles box add`, `box set`, `tile split` and `tile screen-share`, with `tiles link`, `tiles feeds prefer` and `tiles layout set` with the arranged layout. | A nine-tile gallery is reordered and one tile removed by commands alone, including across a change of gallery size, and a review frame shows the result. |

Stage 3 is the largest. Inside it the format and the gate land first, then the monitor and the lane, then the panel. Monitor playback through the pipeline ships in stage 3 if the stage 0 prototype is fast enough. If it is not, playback drops frames to keep up and a Metal version of the pipeline becomes the last part of stage 3. Playback never shows the untreated source under an Output label.

Until stage 5, cutting between feeds goes through rendered angles or through Take at Playhead. After stages 1 and 2, rendered angles give a route from a call to a transcript-cut edit. The project `export-isos` writes carries the angles by feed name, the shared mix and any ISO microphones as audio lanes. It carries no transcript and no link from a transcript voice to an angle, so the transcript is made in that project, and stage 2 adds the link from each voice to an angle: by name when ISO microphones supply names, and by hand otherwise. Stage 5 removes the rendering step: feeds become angles straight from the recording, which is how the feature is meant to work. Export ISOs then remains as an optional delivery for files to hand to someone else.

**Until the later stages land**

- **Hide and blur before stage 3** work as they do today, through the sheet and the saved composition.
- **Old controls stay until replaced.** The box controls stay until stage 6. Take at Playhead and the dialogue suggestions move into the panel in stage 3 and stay until stage 5. The composition they wrote timed shots into is gone by then, so from stage 3 they write Solo layouts on the layout lane.
- **Stage 1 is led by the CLI.** Its app change is Export ISOs. Review is by command or in the existing panel. A project saved by a `needs_review` run opens like any project, and its issues are read with `mpcut tiles inspect --issues`.
- **Refused exports.** From stage 3, selection, queued and stream-copy exports are refused for a project with any layout or treatment until stage 4. The layout is visible on the monitor and Original removes it, so the refusal has a visible cause and a way out.
- **ISO export speed.** Until stage 4, `export-isos` renders one full pass per movie, as angle rendering does today.
- **Editor tools.** Stages 1 and 2 ship file tools only. Editor tools arrive in stage 3 with the rebuilt panel.
- **Names.** The `mpcut tiles` commands are added beside `mpcut participants`, so no script breaks. The app's labels change in stage 3. From stage 3 the old commands work through a translation of the new stored shape.
- **ISO export with someone hidden.** Until the gate is rescoped in stage 3, today's gate applies: with one feed hidden, the unchecked stretches of every ISO are blanked or the export stops.

## Decided

1. **The privacy gate.** It applies only to a recording that contains a hidden or blurred feed, so an unscanned recording passes. An output of one crop passes on a checked frame when the hidden feed is outside it. Unchecked footage is cleared by a frame-by-frame verification pass before export, with a recorded confirmation by the editor as the explicit override. See [Privacy](#privacy), which also sets out amendments that are not yet confirmed.
2. **A feed belongs to the project.** One person can appear in two recordings, and a treatment follows them into both. Counts are reported per recording, and commands take `--source-id` when a project has more than one scanned recording.
3. **`tiletrail scan` is a separate program** beside the library, with its own decoder. MPCut stamps an imported scan with the recording's identity.
4. **Command spellings follow the installed commands**, as the flag table under [One contract](#one-contract-app-cli-and-mcp) records.
5. **Old project files keep opening.** A saved composition is converted into clip layouts.
6. **Names.** The feature and panel are Tiles, the box is a tile, and the thing it shows is a feed. `mpcut participants` stays compatible.

## Open decisions

1. **Amendments to decided items, from the second review.** The Privacy section and the TileTrail section are written with these in. Each needs a yes or no.
   - The gate stays on for a recording where a tile was ever linked to the hidden feed, where tiles are unassigned, or which was replaced on disk. This is stricter than decided.
   - A crop that overlaps the hidden feed's tile passes when the treatment is applied to those pixels. This is looser than decided, which passed a crop only when the hidden feed was outside it.
   - The frame-by-frame pass alone does not clear footage. Open issues for that recording keep their stretches unchecked. This is stricter than decided.
   - An editor's confirmation is tied to the scan and range it was made against and is cancelled by later edits. This is stricter than decided.
   - A standalone scan records which file it came from and MPCut checks it, in place of stamping the identity at import. This is stricter than decided.
   - Converting an old composition includes its timed shots, not only its default layout.
2. **Leaving someone out of the ISOs.** The table under [Privacy](#privacy) proposes that who gets an ISO is chosen in the export, separately from how a feed looks, and that a covered or removed feed cannot be selected. This replaces the earlier question of what `--all` does with a hidden feed, and it is a proposal until confirmed.
3. **Scope of hide and blur.** This plan keeps today's rule: a treatment applies to the feed everywhere it appears, so hiding someone on one clip hides them on every clip of that recording. Whether it should also be limitable to one clip or a range is not decided.
4. **What the arranged layout maps.** "Swap Alice and Bob" can mean exchange the two people, exchange two positions, or leave a position empty, and these differ once the gallery changes size or a person has two tiles. The recommendation is that it maps feeds to positions and lasts until the next layout change. Stage 0 has to define collisions and gaps.
5. **How a feed angle is stored.** Per-source state in the multicam editor is keyed by source ID, and a multicam source requires a file today. The recommendation is a reference to the parent source. Stage 0 also has to say what an angle shows while its feed is offscreen, what the coverage report and audio follow do with it, and whether interchange to other editors renders it or refuses it.
6. **Sequence projects and switching.** A sequence project gets layouts and treatments. Cutting between feeds is offered by converting the clip to multicam angles. Whether a sequence project should switch between feeds without that step is not decided, and neither is what conversion does with the other clips in the sequence.
7. **How a layout is addressed in a multicam project.** A clip ID and a source range do not pick out one occurrence when the same stretch is used twice. The command needs the group clock and a stable occurrence ID there.
8. **The exit code for `needs_review`.** It needs a documented code of its own beside 0, 1, 2 and 130.
9. **Where proposed cuts live in the CLI.** `tiles switches propose` produces switches, which belong to multicam. It may fit better beside `multicam switch coverage`.

## Unknowns

- **Playback speed.** Whether Core Image keeps up on the monitor path in real time has not been measured. The existing export compositor's speed does not answer it.
- **HDR.** The compositing code is set up for sRGB and the monitor handles HDR. What happens to HDR footage has not been traced.
- **Stream copy beside a layout.** Whether stretches with no layout and no treatment can still be copied without re-encoding in the same export is not known.
- **Real recordings.** The interface was judged on a five-second synthetic fixture. One real call and one real multiview would settle file naming, alignment and whether the footage is gallery or speaker view.
- **Detection on a dense gallery.** The 64 boxes and 164 identities reported for the 25-tile, 40-source test come from the CLI proposal and were not re-measured here. The detector limits a grid to 64 boxes, so 64 may be that limit being reached. That is a hypothesis for stage 0 to test. How much of the fix is the gallery hint, and how much is tracking, is not known.

## Not covered, or to be measured

- **Speaker view.** In a call recorded in speaker view, one stage tile changes content with the speaker. Whether a Solo or an ISO then shows a person only while they hold the stage, and what a visible-tile limit means there, is not designed.
- **Variable frame rate.** Outputs are resampled to a fixed frame rate today, so an ISO of a variable-frame-rate source is not aligned frame for frame.
- **Long, dense recordings.** Every change of a box is a stored segment, and each edit snapshots the project for undo. The cost of one undo step on a 40-person hour is unmeasured.
- **Undo of automatic actions.** Whether a name match applied automatically is its own undo step is not decided.
- **Names beside tiles.** A name drawn outside its tile is not covered by a treatment.

## Costs outside the feature

- **The desktop test** drives the panel by visible label. It moves to accessibility identifiers in stage 0, before any label changes.
- **The guide** quotes current labels and is rewritten when the panel is rebuilt in stage 3. Everything under `docs` is copied into the app bundle, including this plan.
- **Scripts and agents.** Existing `mpcut participants` scripts keep working. The CLI help, the MCP catalog, the generated reference and the agent guide gain the `tiles` commands in the same commit as the code, and the packaging tests check that they agree.
- **Two sets of names to maintain.** Keeping `participants` beside `tiles` means both are tested and documented, and it needs an exception to the app-wide naming plan, which forbids permanent aliases. No end date for the old names is set.
- **Tests.** The participant core tests, the integration scripts and the desktop test all exercise the saved composition, the sheet and today's gate. Stage 3 changes all three.
- **Other work in this checkout.** The adaptive participant scan was being implemented in TileTrail and in the same working tree while this plan was written, and the schema version moved during the session. Stage 2 changes the same detector, so it is coordinated with that work.

## Evidence

This plan rests on reading the panel, the sheet, the monitor overlay, the renderer and the project model, and on the accessibility tree of a debug build opened on the participant test fixture. Screenshots were not available. That build had no analyzer and the fixture already had accepted feeds, so the first-run, scan and sheet behaviour described above comes from the code and was not exercised. The claims about several clips, that a layout change is left behind on reorder and that a second video takes the first one's layout, are also read from the code and were not exercised.

- Panel and sheet: [ParticipantInspector.swift](../Sources/MPCutApp/ParticipantInspector.swift), [ParticipantCompositionSheet.swift](../Sources/MPCutApp/ParticipantCompositionSheet.swift), [ParticipantMarkerInspector.swift](../Sources/MPCutApp/ParticipantMarkerInspector.swift), [ParticipantDialogueReview.swift](../Sources/MPCutApp/ParticipantDialogueReview.swift)
- Monitor: [ParticipantMonitor.swift](../Sources/MPCutApp/ParticipantMonitor.swift), [PreviewSurface.swift](../Sources/MPCutApp/PreviewSurface.swift)
- Renderer and export limits: [ParticipantRenderer.swift](../Sources/MPCutCore/ParticipantRenderer.swift), [ParticipantRenderPicture.swift](../Sources/MPCutCore/ParticipantRenderPicture.swift), [ParticipantRenderTimeline.swift](../Sources/MPCutCore/ParticipantRenderTimeline.swift), [ParticipantProjectExport.swift](../Sources/MPCutCore/ParticipantProjectExport.swift)
- Model: [ParticipantProject.swift](../Sources/MPCutCore/ParticipantProject.swift), [ParticipantRenderPlan.swift](../Sources/MPCutCore/ParticipantRenderPlan.swift), [ParticipantMulticam.swift](../Sources/MPCutCore/ParticipantMulticam.swift), [MulticamProject.swift](../Sources/MPCutCore/MulticamProject.swift), [StillProject.swift](../Sources/MPCutCore/StillProject.swift)
- Transcript side: [TranscriptJob.swift](../Sources/MPCutCore/TranscriptJob.swift), [TranscriptPane.swift](../Sources/MPCutApp/TranscriptPane.swift)
- Desktop test: [participant_gui.swift](../Tests/Integration/participant_gui.swift)
- CLI and MCP: [Participants.swift](../Sources/MPCutCLI/Participants.swift), [CommandHelp.swift](../Sources/MPCutCLI/CommandHelp.swift), [participants.json](../Sources/MPCutApp/MCPResources/participants.json), the [naming convention](NAMING-CONVENTION.md), the [app-wide naming plan](APP-NAMING-PLAN.md) and the [parity review](CLI-MCP-PARITY-REVIEW.md)

The scan timings, the size of adaptive output and the cache behaviour on a rescan were reported by the session implementing the adaptive scan, from its uncommitted work on two real calls of over two hours. They were not measured here. That session did not test whether automatic detection stops at the detector's box limit.

An independent adversarial review then checked this plan against the source. Its main findings were re-checked here before the plan was changed: the privacy gate's two limits, random IDs on acceptance, the screen share having no feed, the all-or-nothing delivery folder, the participant parser's rules, the sequence limit on ISO microphones, and the detector's box limit and lack of a command-line program. The rest of its findings were accepted on its citations and not re-opened, including the count of places that branch on a saved composition and the detector's internals.

A second adversarial review was run through Codex with the `gpt-6.2-astra` model, as a read-only stress test of eight scenarios. These of its findings were re-checked here: exports report as publishable under the cover setting, so a hidden feed blanks other ISOs and does not always block them; the 64 MiB limit applies when a project is loaded and saved; the old scan command prints the whole scan to standard output; `--feed-layout` defaults to a meeting; several export guards test only for a saved composition; the camera-angle review frame is returned even when a composition is saved; and the file-job runner reports every exit code other than 0 and 130 as failed. Its other findings were accepted on its citations.

The CLI side of this plan is the "Proposed update to MPCut and TileTrail" supplied during planning. Its commands, defaults, outputs and job behaviour are carried over, and its syntax is marked as proposed. One name differs: the proposal says tile-unique where this plan says feed, so its `uniques` commands, `--tile-unique` flag and `tile_unique_id` field appear here as `feeds`, `--feed-id` and `feed_id`. Its flag spellings were also changed where the flag table says. Two of its statements about today were checked: the 1 GiB limit on an importable scan report is in the CLI source, and progress and resume already exist on `participants scan`. Its detection result was not re-measured. Its last heading mentions shipping in stages and lists none, so the stages here are this plan's.
