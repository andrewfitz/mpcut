# Premiere Pro projects

MPCut reads and writes native `.prproj` files through Adobe Premiere and a small UXP panel. The panel uses Premiere's project and sequence translation APIs. The temporary sequence XML stays inside the conversion workspace. Keep the original media accessible to both editors. [Adobe Project API](https://developer.adobe.com/premiere-pro/uxp/ppro-reference/classes/project/) · [Adobe sequence XML translation](https://helpx.adobe.com/uk/premiere/desktop/render-and-export/export-files/export-a-project-as-a-final-cut-pro-xml-file.html)

## Install the panel

1. Open `MPCut.app/Contents/Resources/MPCut Premiere.ccx` with Creative Cloud and install it. From a source checkout, build the same installer with the command below.
2. Launch Premiere. Choose **Window → UXP Plugins → MPCut Project Converter** and leave the panel available.
3. In MPCut, use the project import/export menu or run the CLI commands below.

```sh
(cd packaging/premiere && zip -q -X "/tmp/MPCut Premiere.ccx" manifest.json index.html index.js)
open "/tmp/MPCut Premiere.ccx"
```

```sh
mpcut convert Interview.cut --output Interview.prproj
mpcut convert Interview.prproj --output Reopened.cut --allow-loss
mpcut convert Concert.cut --output Concert-Flat.prproj --flatten-multicam --allow-loss
```

The panel communicates through its per-user Adobe plugin data directory and requires a local Premiere session. It opens a private copy for import and a temporary project for export. Conversion reads the last saved project on disk. The resulting project can be opened in Premiere without the panel.

## What transfers

| Content | Premiere conversion |
| --- | --- |
| Ordered and repeated trims | Transfers the timeline order, source files and source in/out points. Premiere generates its own item IDs. |
| Ordinary clip audio | All source channels go to editable timeline tracks. Replacement media stays linked. MPCut-specific replacement history, display names and preview selection require accepting an export warning. |
| Native multicam export | Groups of two to four cameras transfer as switchable Premiere multicam clips when the cameras share a frame rate, start at zero, and each covers the full group range. Each timeline occurrence selects its original camera. Independent microphone selections become editable audio tracks. MPCut reopens the staged project in Premiere and checks its native angle selections before publishing. |
| Flattened multicam export | **Allow Loss** permits projects outside the native subset to export the assembled picture and sound as normal clips. Use `--flatten-multicam --allow-loss` to request this representation explicitly when planning to import the project back into MPCut. |
| Multicam import | Premiere omits native multicam clips from its sequence XML. MPCut detects these clips and stops before translation. In a duplicate Premiere sequence select the multicam clips, choose **Multi-Camera → Flatten**, and save the copy. Import can recover a synchronized MPCut group from separately positioned picture and a single microphone selection at each point. Flattening removes the unused alternate angles. |
| Timing | Premiere measures source in/out and timeline positions at the sequence rate. Mixed-rate media retain their original playback rate. Subframe edits require accepting rounding. A cut that would disappear is rejected. |
| Track layout | Disjoint cuts on separate video tracks can be combined in timeline order with a warning. Reordered audio channels require accepting a warning that MPCut restores their source order. |
| Multiple sequences | Import uses the active sequence or the first available sequence and reports how many sequences the project contains. |
| Editorial features outside MPCut | Native import always requires **Allow Loss** because Premiere's sequence translation may discard bins, grades, titles, keyframes, transitions, effects, graphics, audio processing and project settings before MPCut can examine them. |
| Unrepresentable edits | Unresolved media, unflattened nested or multicam clips without a direct media reference, retimes, overlapping video layers, timeline gaps, partial channel selection and overlapping mixes can stop import. Simplify the sequence in a separate copy or export stems in Premiere. |

Premiere Pro 27.0 on macOS was tested through the CLI. A stereo sequence returned both trims in reverse source order with their original source ranges. A two-camera native project reopened with alternate camera sources in both clips, active angles 2 then 1, source ranges 1–2 then 0–1 seconds, and an independent microphone on channel 2 across both edits. The explicitly flattened version returned both camera edits and the selected microphone to MPCut. A Resolve `.drp` converted through Premiere `.prproj` back to MPCut with ranges 4–6, 1–2 and 4–6 seconds and both replacement audio streams.
