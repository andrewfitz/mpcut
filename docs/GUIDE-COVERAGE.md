# MPCut user-guide coverage

The first desktop walkthrough covers adding a movie, marking and removing a range, saving the edit, and exporting the joined footage. It uses the macOS accessibility controls in a separate instance of MPCut. The other rows below record a review of the source and existing instructions. A row identifies where a reader can complete a task and which parts still need a desktop walkthrough.

| What the user wants to do | Where the instructions live | Audit finding |
| --- | --- | --- |
| Remove a section and keep the two ends | [Make your first cut](USAGE.md#make-your-first-cut) | Added before-and-after screenshots, an exact-time example, the expected duration, and the separate save and export steps. The pilot checks both saved source ranges and every decoded output frame. |
| Trim, restore, split, move or repeat clips | [Edit a sequence](USAGE.md#edit-a-sequence) · [Timeline ranges](USAGE.md#select-and-edit-a-timeline-range) · [CSV cuts](USAGE.md#apply-csv-cut-points-to-a-clip) | Dragging, shortcuts and CSV formats were covered. Added the Sequence menu paths for trimming, restoring an original edge and moving a clip one position. |
| Preview edits, navigate by frame, or work across windows | [Edit a sequence](USAGE.md#edit-a-sequence) · [Project windows](USAGE.md#work-with-several-editor-windows) | The guide covers the video monitor, shortcuts, speed, scrub audio, history and draft recovery. Added the exact-time menu path to the first cut. Recovery after an interrupted session is a separate walkthrough candidate. |
| Set up cameras, route microphones and build an assembly | [Multicam editing](USAGE.md#edit-a-multicam-project) | Setup, relinking, group versus assembly time and timing alternatives have instructions. Added how to extend the group to the last camera. A visual example switching between group time and a repeated assembly range would help readers predict which occurrence an edit affects. |
| Detect silence or scenes and reuse analysis | [Shorten pauses](USAGE.md#find-and-shorten-pauses) · [Scenes and recurring views](USAGE.md#detect-scenes-and-recurring-views) · [Sidecars](USAGE.md#save-and-reuse-analysis) | The guide describes scanning, reviewing and applying results. A desktop example could show one protected pause surviving a shortening operation. |
| Replace audio, export tracks, stills or JPEGs | [Audio and track export](USAGE.md#edit-audio-and-export-tracks) · [JPEG review](USAGE.md#review-a-recording-with-jpegs) | The written workflows cover stream selection, replacement and image review. A multitrack fixture would allow a walkthrough to demonstrate how to check which audio actually reached the output. |
| Choose an export mode or write several files | [Export modes](USAGE.md#choose-an-export-mode) · [Export queue](USAGE.md#export-several-ranges-from-the-timeline) | Added the mode-specific File menu and how to find the finished export. The first-cut pilot exercises Lossless Copy. Queue naming, alternate formats and cut-boundary review still need their own illustrated example. |
| Exchange an editable project with another editor | [Project conversion](../README.md#convert-projects) · [Resolve handoff](../README.md#export-a-project-to-davinci-resolve) · [Premiere panel](PREMIERE.md) | The detailed setup already lives with each integration. Added both CLI routes to the usage guide’s task table. Opening the result in the receiving editor is a separate verification step. |
| Change settings or find offline help | [Settings](USAGE.md#set-editing-and-export-defaults) · [Guide introduction](USAGE.md) | Settings covers timeline, history, monitoring, output and analysis defaults. Added the automation guide to the description of the Help menu. |
| Script jobs or control a live project | [CLI task table](USAGE.md#use-the-cli-from-an-agent) · [Agent guide](MCP-AGENT-GUIDE.md) · [MCP coverage](MCP-COVERAGE.md) | Reviewed the 14 CLI help topics against the task table. MCP already has a generated reference and a separate live verification record. |

## Repeat the review

The initial inventory found 232 literal desktop control declarations and 14 CLI help topics. After the guide edits, 62 declarations still used wording that did not appear verbatim in the guide. These include repeated controls, shortcut labels, and buttons such as **Done**. The findings above group them by the task a reader needs to perform.

Run these from the repository root after changing a menu, setting or command.

```sh
python3 scripts/guide-inventory.py
python3 scripts/mcp-reference.py --check
```

The inventory prints source locations, literal control labels, CLI topics and matches in the guide. Review each candidate in context. For example, the guide explains **Shuttle Forward (L)** under the J/K/L shortcuts. A matching word can also occur in an unrelated paragraph. Inspect conditional labels, AppKit panels, shortcuts and gestures in their source files as well. The regular-expression inventory covers literal SwiftUI declarations and the CLI topic list.

## Reproduce the first cut

On an Apple Silicon Mac with MPCut built, run the following in a logged-in desktop session. The terminal needs Accessibility and Screen Recording access. Leave MPCut in front while the script uses the file picker and keyboard shortcuts. Supply a new output directory.

```sh
work=$(mktemp -d)
swift scripts/first-cut.swift dist/MPCut.app "$work/first-cut"
```

The script creates a six-second, 24 fps ProRes movie and opens an empty named project. It adds the movie through the file picker, sets the timeline ruler to 2 and 4 seconds, presses the mark controls, deletes the selection, and saves. It checks that the project retained source intervals 0–2 and 4–6. It previews the join, exports through the native save sheet, and compares the decoded movie against source frames 0–47 and 96–143 in order. Lossless Copy and snapping off are set for this launch. The project, practice movie, export, frame checksums and both screenshots stay in the output directory. After a successful run, inspect the two JPEGs and copy them into `docs/images/` to refresh the guide.
