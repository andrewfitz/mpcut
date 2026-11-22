# Export rules

<!-- Generated from Sources/MPCutCore/ExportRules.swift. Do not edit. ExportRulesTests regenerates and compares it. -->

These rules apply to the app and the CLI alike. Both resolve every export through `ExportPlanner` in MPCutCore.

## Names

| Concept | Identifier | Name |
| --- | --- | --- |
| Mode | `smart` | Smart Trim |
| Mode | `copy` | Lossless Copy |
| Mode | `encode` | Re-encode (movies), Convert Audio (sound only) |
| Tracks | `all` | Video and audio |
| Tracks | `video` | Video only |
| Tracks | `audio` | Audio only |
| Audio action | `auto` | Auto. Copy when the copy is exact, otherwise the first alternative that works. |
| Audio action | `copy` | Copy Original. Copy the source packets, or fail. |
| Audio action | `aac` | AAC. Encode AAC. |
| Audio action | `pcm` | PCM. Write PCM. |
| Audio action | `remove` | Remove Audio. Write no sound. |
| Audio action | `mp3` | MP3. Encode MP3 with LAME. |
| Audio action | `flac` | FLAC. Encode FLAC, which is lossless. |
| Source kind | `movie` | Movie |
| Source kind | `audio` | Audio recording |
| Source kind | `multicam` | Multicam program |

## Matrix

Containers marked *verified* are those the copy planner accepts for the source and its cuts.

| Source | Tracks | Mode | Written as | Containers | Audio actions | Default audio | If unavailable, offer |
| --- | --- | --- | --- | --- | --- | --- | --- |
| movie | all | smart | Smart Trim | *verified* | — | — | `reencode` |
| movie | all | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `smartTrim`, `reencode` |
| movie | all | encode | Re-encode | `mp4`, `mov`, `mkv` | `auto`, `copy`, `aac`, `pcm`, `remove` | `auto` | `reencode` |
| movie | video | smart | Lossless Copy | *verified* | — | — | `copyOtherContainer` |
| movie | video | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer` |
| movie | video | encode | refused: `invalid_arguments` “A video-only selection uses Lossless Copy.” | — | — | — | — |
| movie | audio | smart | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `copySampleAligned`, `convertSameFormat`, `convertPCM`, `convertAAC` |
| movie | audio | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `copySampleAligned`, `convertSameFormat`, `convertPCM`, `convertAAC` |
| movie | audio | encode | Convert Audio | by audio action | `auto`, `copy`, `pcm`, `flac`, `aac`, `mp3` | `auto` | `convertSameFormat`, `convertPCM`, `convertAAC` |
| audio | all | smart | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `copySampleAligned`, `convertSameFormat`, `convertPCM`, `convertAAC` |
| audio | all | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `copySampleAligned`, `convertSameFormat`, `convertPCM`, `convertAAC` |
| audio | all | encode | Convert Audio | by audio action | `auto`, `copy`, `pcm`, `flac`, `aac`, `mp3` | `auto` | `convertSameFormat`, `convertPCM`, `convertAAC` |
| audio | video | smart | refused: `no_video` “The source has no video track.” | — | — | — | — |
| audio | video | copy | refused: `no_video` “The source has no video track.” | — | — | — | — |
| audio | video | encode | refused: `no_video` “The source has no video track.” | — | — | — | — |
| audio | audio | smart | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `copySampleAligned`, `convertSameFormat`, `convertPCM`, `convertAAC` |
| audio | audio | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer`, `copySampleAligned`, `convertSameFormat`, `convertPCM`, `convertAAC` |
| audio | audio | encode | Convert Audio | by audio action | `auto`, `copy`, `pcm`, `flac`, `aac`, `mp3` | `auto` | `convertSameFormat`, `convertPCM`, `convertAAC` |
| multicam | all | smart | Smart Trim | `mov`, `mp4`, `m4v`, `mkv`, `webm` | — | — | `copyOtherContainer`, `reencode` |
| multicam | all | copy | Lossless Copy | `mov`, `mp4`, `m4v`, `mkv`, `webm` | — | — | `copyOtherContainer`, `smartTrim`, `reencode` |
| multicam | all | encode | Re-encode | `mov`, `mp4`, `m4v`, `mkv` | `copy`, `aac`, `pcm`, `remove` | `copy` | `convertPCM`, `convertAAC`, `reencode` |
| multicam | video | smart | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | video | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer` |
| multicam | video | encode | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | audio | smart | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | audio | copy | Lossless Copy | *verified* | — | — | `copyOtherContainer` |
| multicam | audio | encode | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |

A source without picture has one selection, so `all` means `audio`. Smart Trim applies to picture, so a single-type selection is written as Lossless Copy.

The multicam rows are enforced: `MulticamEngine` reads its refusals, containers and audio actions from these rules, so no front end can write what a row refuses. The Export inspector, both Export Queues and `export --project` resolve through `MulticamEngine.resolution`, which reports the alternatives of the row. `silence --project --output` plans its retained ranges with the engine directly and reports verified times only, because no `export --project` request stands for ranges that exist only in its report. The engine still owns what depends on the recordings: the program clock, the switch and range-edge times in `nearest`, the mux of picture and sound, and sample-exact sound conversion. For a multicam program `convertPCM` and `convertAAC` re-encode with the program sound converted, in the requested container when it carries that sound.

## Containers by setting

| Setting | Containers (default first) |
| --- | --- |
| Re-encode, `h264` | `mp4`, `mov`, `mkv` |
| Re-encode, `hevc` | `mp4`, `mov`, `mkv` |
| Re-encode, `prores` | `mov`, `mkv` |
| Convert Audio, `pcm` | `wav`, `caf`, `mov` |
| Convert Audio, `aac` | `m4a`, `mp4`, `mov` |
| Convert Audio, `mp3` | `mp3` |
| Convert Audio, `flac` | `flac` |
| Multicam program, picture and sound | `mov`, `mp4`, `m4v`, `mkv`, `webm` |
| Multicam re-encode, `h264` | `mov`, `mp4`, `m4v`, `mkv` |
| Multicam re-encode, `hevc` | `mov`, `mp4`, `m4v`, `mkv` |
| Multicam re-encode, `prores` | `mov`, `mkv` |
| Multicam picture only, listed by the app | `mov`, `mp4`, `m4v`, `mkv`, `webm` |
| Multicam sound only, listed by the app | `mov`, `mp4`, `m4v`, `mkv`, `wav` |
| Movie re-encode with `pcm` sound | `mov`, `mkv` |
| Movie re-encode with `aac` sound | `mp4`, `mov`, `mkv` |
| Multicam program re-encode with `pcm` sound | `mov`, `mkv` |
| Multicam program re-encode with `aac` sound | `mov`, `mp4`, `m4v` |

An audio action its container cannot carry is refused with `unsupported_audio` and offers the containers that carry it, then `auto` for a movie. No front end substitutes another action. A multicam `m4v` is written as MP4. Multicam AAC needs a movie edit list for gapless timing, so it is not written into Matroska.

PCM bit depth is chosen by the engine that writes it: a sound-only conversion keeps the source depth (16, 24 or 32-bit, or 32-bit float), while a movie or multicam re-encode writes 32-bit, or 32-bit float for a float source, so that no source depth is reduced.

When `auto` cannot copy the sound of a movie re-encode exactly it converts: AAC, or PCM for ProRes outside MP4. A multicam re-encode never converts the routed program sound unasked: `auto` is accepted and means `copy`, and when that copy is not exact the export is unavailable and offers `convertPCM` and `convertAAC`.

## Defaults

| Setting | Default |
| --- | --- |
| Mode, movie | `smart` |
| Mode, audio recording | `copy` |
| Mode, multicam program | `smart` |
| Tracks | `all` |
| Snap | `exact` |
| Video codec | `h264` |
| Quality | `balanced`, ProRes `422` |
| Audio action in encode | `auto` |

The app's Settings can change the movie default mode. CLI commands use the default above, except `export`, whose exception is named under Entry points.

## Alternatives when an export is unavailable

Alternatives are checked in rank order and every one that works is reported, least destructive first. The rank compares, in order: how much is encoded (nothing, cut edges, the sound, picture and sound), whether the source format changes, whether an encoding generation is added, and the time to write. An alternative is offered, never applied, unless the request asked for `--audio auto`.

| Rank | Id | Encoded | Format | Added loss | What it does |
| --- | --- | --- | --- | --- | --- |
| 1 | `copyOtherContainer` | nothing | kept | none | Copy the same packets into another container that can carry these cuts. |
| 2 | `copySampleAligned` | nothing | kept | none | Copy with each cut moved to the nearest audio sample, less than one sample away. |
| 3 | `smartTrim` | cut edges | kept | one generation | Copy complete sections and encode only the video at the cut edges. |
| 4 | `convertSameFormat` | sound | kept | one generation | Decode the kept ranges and encode them once in the source codec (MP3, AAC or FLAC) with the source parameters. |
| 5 | `convertPCM` | sound | changed | none | Decode the kept ranges to PCM in WAV. No further quality loss, and a much larger file. |
| 6 | `convertAAC` | sound | changed | one generation | Decode the kept ranges and encode AAC in M4A. |
| 7 | `reencode` | picture and sound | changed | one generation | Encode the whole timeline with the hardware video encoder. |

## Entry points

| Entry point | Source | Modes | Reports alternatives | Named restrictions |
| --- | --- | --- | --- | --- |
| App: Export sheet | movie | `smart`, `copy`, `encode` | yes | noAutoAudioConversion: Convert Audio names a format, so the sheet always shows what it will write. The first offer is what `--audio auto` applies. |
| App: Export Queue | movie | `smart`, `copy`, `encode` | yes | sharedSettings: one setting applies to every range, so an alternative that moves cuts (`copySampleAligned`) is not offered.<br>sourceCompatible: Lossless Copy and Smart Trim can leave the container to the copy planner. |
| App: multicam Export inspector | multicam | `smart`, `copy`, `encode` | yes | listedContainers: a picture-only or sound-only copy lists the containers under Containers by setting. The CLI accepts every extension the copy planner verifies.<br>switchTimes: an unsafe switch or range edge also reports verified times. |
| App: multicam Export Queue | multicam | `smart`, `copy`, `encode` | yes | listedContainers: a picture-only or sound-only copy lists the containers under Containers by setting. The CLI accepts every extension the copy planner verifies.<br>switchTimes: an unsafe switch or range edge also reports verified times. |
| App and CLI: Replace Source Audio | movie | `copy` | no | copyOnly: a replaced soundtrack is copied with both track types. |
| CLI: export | movie | `smart`, `copy`, `encode` | yes | namedOutput: `--audio auto` applies the first alternative that fits the extension of `--output`.<br>defaultCopy: without `--mode`, export copies, or uses Smart Trim when `--order` is given. The app starts from Smart Trim. Existing scripts depend on this default, so it is kept until a change is approved. |
| CLI: bulk | movie | `smart`, `copy`, `encode` | yes | namedOutput: `--audio auto` applies the first alternative that fits `container` when one is given. |
| CLI: rearrange | movie | `smart` | yes | noEncode: use export for --mode encode.<br>nearestByDefault: video cuts snap to the nearest boundary. |
| CLI: silence --output | movie | `smart`, `copy` | yes | noEncode: retained ranges are written with Smart Trim or Lossless Copy.<br>generatedClips: the failing clips are the retained ranges, so each alternative lists them in `clips`. |
| CLI: scenes --export-to | movie | `smart` | yes | smartOnly: every scene is written with Smart Trim, or Lossless Copy for a single-type selection. |
| CLI: export --project (multicam) | multicam | `smart`, `copy`, `encode` | yes | namedOutput: the extension of `--output` is the container.<br>autoCopies: `--audio auto`, the flag's default, means `copy`. An inexact copy is refused and offers the conversions.<br>switchTimes: an unsafe switch or range edge also reports verified times in `nearest`. |

## Refusals

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | The matrix refuses this combination of tracks, mode and settings. |
| `unsafe_boundary` | A cut cannot be copied exactly. `nearest` lists verified times when there are any. |
| `unsupported_container` | The container cannot carry the selected tracks or this conversion. The message names the valid extensions. |
| `unsupported_tracks` | The source has tracks or timing that this mode cannot write. |
| `unsupported_audio` | The audio action does not apply to this source, selection or container. |
| `audio_copy_unavailable` | `--audio copy` was requested and the sound cannot be copied exactly. |
| `encoder_unavailable` | The FFmpeg helper lacks the encoder, or the hardware encoder did not start. |
| `no_video` | A picture was requested from a source without one. |
| `no_audio` | Sound was requested from a source without a matching track. |
| `output_exists` | The destination exists. MPCut never overwrites. |
| `invalid_output` | The destination is not a writable local file path matching the container. |
