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
| movie | all | encode | Re-encode | `mp4`, `mov`, `mkv` | `auto`, `copy`, `aac`, `pcm`, `remove` | `auto` | — |
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
| multicam | all | smart | Smart Trim | `mov`, `mp4`, `m4v`, `mkv`, `webm` | — | — | — |
| multicam | all | copy | Lossless Copy | `mov`, `mp4`, `m4v`, `mkv`, `webm` | — | — | — |
| multicam | all | encode | Re-encode | `mov`, `mp4`, `m4v`, `mkv`, `webm` | `auto`, `copy`, `aac`, `pcm`, `remove` | `auto` | — |
| multicam | video | smart | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | video | copy | Lossless Copy | `mov`, `mp4`, `m4v`, `mkv`, `webm` | — | — | — |
| multicam | video | encode | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | audio | smart | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | audio | copy | Lossless Copy | `mov`, `mp4`, `m4v`, `mkv`, `webm` | — | — | — |
| multicam | audio | encode | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |

A source without picture has one selection, so `all` means `audio`. Smart Trim applies to picture, so a single-type selection is written as Lossless Copy.

The multicam rows describe `MulticamEngine`, which plans programs itself and is not yet resolved through `ExportPlanner`. A sound-only multicam copy can also be written to `wav`.

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
| Multicam program | `mov`, `mp4`, `m4v`, `mkv`, `webm` |

PCM cannot be written into MP4 by a movie re-encode.

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
| App: Export sheet | movie | `smart`, `copy`, `encode` | yes | noAutoAudioConversion: Convert Audio names a format, so the sheet always shows what it will write. The offer button is what `--audio auto` applies. |
| App: Export Queue | movie | `smart`, `copy`, `encode` | no | copyOnlySound: sound-only queues use Lossless Copy. Convert the ranges with the Export sheet or `bulk --mode encode`.<br>noAlternatives: a failed range reports its error without the ladder. |
| App: multicam Export inspector | multicam | `smart`, `copy`, `encode` | no | multicamConversion: Re-encode converts program sound to AAC or PCM only.<br>singleTypeCopy: picture-only and sound-only selections use Lossless Copy.<br>noAlternatives: an unavailable export reports verified switch times instead of the ladder. |
| App: multicam Export Queue | multicam | `smart`, `copy`, `encode` | no | multicamConversion: Re-encode converts program sound to AAC or PCM only.<br>singleTypeCopy: picture-only and sound-only selections use Lossless Copy.<br>noAlternatives: an unavailable export reports verified switch times instead of the ladder. |
| App and CLI: Replace Source Audio | movie | `copy` | no | copyOnly: a replaced soundtrack is copied with both track types. |
| CLI: export | movie | `smart`, `copy`, `encode` | yes | namedOutput: `--audio auto` applies the first alternative that fits the extension of `--output`.<br>defaultCopy: without `--mode`, export copies, or uses Smart Trim when `--order` is given. The app starts from Smart Trim. Existing scripts depend on this default, so it is kept until a change is approved. |
| CLI: bulk | movie | `smart`, `copy`, `encode` | yes | namedOutput: `--audio auto` applies the first alternative that fits `container` when one is given. |
| CLI: rearrange | movie | `smart` | yes | noEncode: use export for --mode encode.<br>nearestByDefault: video cuts snap to the nearest boundary. |
| CLI: silence --output | movie | `smart`, `copy` | no | noEncode: retained ranges are written with Smart Trim or Lossless Copy.<br>noAlternatives: an unavailable export reports its error without the ladder. |
| CLI: scenes --export-to | movie | `smart` | no | smartOnly: every scene is written with Smart Trim.<br>noAlternatives: an unavailable export reports its error without the ladder. |
| CLI: export --project (multicam) | multicam | `smart`, `copy`, `encode` | no | multicamConversion: Re-encode converts program sound to AAC or PCM only.<br>singleTypeCopy: picture-only and sound-only selections use Lossless Copy.<br>noAlternatives: an unavailable export reports verified switch times instead of the ladder. |

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
