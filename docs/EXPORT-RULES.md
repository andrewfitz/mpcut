# Export rules

<!-- Generated from Sources/MPCutCore/ExportRules.swift. Regenerate with MPCUT_WRITE_EXPORT_RULES=1 swift test --filter ExportRulesParityTests. -->

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
| Audio action | `auto` | Auto. Copy the original audio when possible. Otherwise, use the first supported alternative. |
| Audio action | `copy` | Copy Original. Copy the original audio packets. Stop if they can’t be copied exactly. |
| Audio action | `aac` | AAC. Encode AAC. |
| Audio action | `pcm` | PCM. Write PCM. |
| Audio action | `remove` | Remove Audio. Omit the audio track. |
| Audio action | `mp3` | MP3. Encode MP3 with LAME. |
| Audio action | `flac` | FLAC. Encode FLAC, which is lossless. |
| Audio action | `opus` | Opus. Encode Opus with libopus. |
| Source kind | `movie` | Movie |
| Source kind | `audio` | Audio recording |
| Source kind | `multicam` | Multicam program |

## Matrix

Containers marked *verified* are those the copy planner accepts for the source and its cuts.

| Source | Tracks | Mode | Written as | Containers | Audio actions | Default audio | If unavailable, offer |
| --- | --- | --- | --- | --- | --- | --- | --- |
| movie | all | smart | Smart Trim | *verified* | — | — | `copy_other_container`, `smart_trim`, `reencode` |
| movie | all | copy | Lossless Copy | *verified* | — | — | `copy_other_container`, `smart_trim`, `reencode` |
| movie | all | encode | Re-encode | `mp4`, `mov`, `mkv` | `auto`, `copy`, `aac`, `pcm`, `remove` | `auto` | `reencode` |
| movie | video | smart | Lossless Copy | *verified* | — | — | `copy_other_container` |
| movie | video | copy | Lossless Copy | *verified* | — | — | `copy_other_container` |
| movie | video | encode | refused: `invalid_arguments` “A video-only selection uses Lossless Copy.” | — | — | — | — |
| movie | audio | smart | Lossless Copy | *verified* | — | — | `copy_other_container`, `copy_sample_aligned`, `convert_same_format`, `convert_pcm`, `convert_aac` |
| movie | audio | copy | Lossless Copy | *verified* | — | — | `copy_other_container`, `copy_sample_aligned`, `convert_same_format`, `convert_pcm`, `convert_aac` |
| movie | audio | encode | Convert Audio | by audio action | `auto`, `copy`, `pcm`, `flac`, `aac`, `mp3`, `opus` | `auto` | `convert_same_format`, `convert_pcm`, `convert_aac` |
| audio | all | smart | Lossless Copy | *verified* | — | — | `copy_other_container`, `copy_sample_aligned`, `convert_same_format`, `convert_pcm`, `convert_aac` |
| audio | all | copy | Lossless Copy | *verified* | — | — | `copy_other_container`, `copy_sample_aligned`, `convert_same_format`, `convert_pcm`, `convert_aac` |
| audio | all | encode | Convert Audio | by audio action | `auto`, `copy`, `pcm`, `flac`, `aac`, `mp3`, `opus` | `auto` | `convert_same_format`, `convert_pcm`, `convert_aac` |
| audio | video | smart | refused: `no_video` “The source has no video track.” | — | — | — | — |
| audio | video | copy | refused: `no_video` “The source has no video track.” | — | — | — | — |
| audio | video | encode | refused: `no_video` “The source has no video track.” | — | — | — | — |
| audio | audio | smart | Lossless Copy | *verified* | — | — | `copy_other_container`, `copy_sample_aligned`, `convert_same_format`, `convert_pcm`, `convert_aac` |
| audio | audio | copy | Lossless Copy | *verified* | — | — | `copy_other_container`, `copy_sample_aligned`, `convert_same_format`, `convert_pcm`, `convert_aac` |
| audio | audio | encode | Convert Audio | by audio action | `auto`, `copy`, `pcm`, `flac`, `aac`, `mp3`, `opus` | `auto` | `convert_same_format`, `convert_pcm`, `convert_aac` |
| multicam | all | smart | Smart Trim | `mov`, `mp4`, `m4v`, `mkv`, `webm` | `auto`, `copy`, `aac`, `pcm`, `remove` | `copy` | `copy_other_container`, `smart_trim`, `reencode` |
| multicam | all | copy | Lossless Copy | `mov`, `mp4`, `m4v`, `mkv`, `webm` | `auto`, `copy`, `aac`, `pcm`, `remove` | `copy` | `copy_other_container`, `smart_trim`, `reencode` |
| multicam | all | encode | Re-encode | `mov`, `mp4`, `m4v`, `mkv` | `auto`, `copy`, `aac`, `pcm`, `remove` | `copy` | `convert_pcm`, `convert_aac`, `reencode` |
| multicam | video | smart | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | video | copy | Lossless Copy | *verified* | — | — | `copy_other_container` |
| multicam | video | encode | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | audio | smart | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |
| multicam | audio | copy | Lossless Copy | *verified* | `auto`, `copy`, `aac`, `pcm` | `copy` | `copy_other_container` |
| multicam | audio | encode | refused: `invalid_arguments` “Multicam single-type track selection uses copy. Omit --mode or choose --mode copy.” | — | — | — | — |

A source without picture has one selection, so `all` means `audio`. Smart Trim applies to picture, so a single-type selection is written as Lossless Copy.

The multicam rows describe picture mode and the available audio actions. The export inspector, queue and CLI resolve the requested picture and sound independently. A sound-only request uses the copy mode for track selection and can still render audio. The planner validates the program clock, the cut times reported in `nearest` and the source and output boundaries of every copied lane.

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
| Convert Audio, `opus` | `opus`, `ogg`, `webm`, `mka` |
| Multicam program, picture and sound | `mov`, `mp4`, `m4v`, `mkv`, `webm` |
| Multicam re-encode, `h264` | `mov`, `mp4`, `m4v`, `mkv` |
| Multicam re-encode, `hevc` | `mov`, `mp4`, `m4v`, `mkv` |
| Multicam re-encode, `prores` | `mov`, `mkv` |
| Multicam picture only, listed by the app | `mov`, `mp4`, `m4v`, `mkv`, `webm` |
| Multicam sound only, listed by the app | `mov`, `mp4`, `m4v`, `mkv`, `wav`, `caf`, `m4a` |
| Replace Source Audio, movie (after the source's own) | `mov`, `mp4`, `mkv`, `webm` |
| Replace Source Audio, recording without picture (after the source's own) | `mov`, `mka`, `m4a`, `wav`, `mp4`, `mkv`, `webm` |
| Movie re-encode with `pcm` sound | `mov`, `mkv` |
| Movie re-encode with `aac` sound | `mp4`, `mov`, `mkv` |
| Multicam program re-encode with `pcm` sound | `mov`, `mkv` |
| Multicam program re-encode with `aac` sound | `mov`, `mp4`, `m4v` |

An audio action its container cannot carry is refused with `unsupported_audio` and offers the containers that carry it, then `auto` for a movie. No front end substitutes another action. A multicam `m4v` is written as MP4. Multicam AAC needs a movie edit list for gapless timing, so it is not written into Matroska.

PCM bit depth is chosen by the engine that writes it: a sound-only conversion keeps the source depth (16, 24 or 32-bit, or 32-bit float), while a movie or multicam re-encode writes 32-bit, or 32-bit float for a float source, so that no source depth is reduced.

When `auto` cannot copy the sound of a movie re-encode exactly it converts to AAC, or PCM for ProRes outside MP4. A multicam export uses `separate_tracks` by default, with one selectable track per lane in project order. Copy preserves source formats and refuses a lane that needs rendering. Explicit `auto` tries copy for each lane and may render the affected lanes or insert silence while retaining eligible PCM samples. `downmix_mono` and `downmix_stereo` always render one track. For picture with sound, MOV renders PCM or AAC, MP4 and M4V render AAC, and MKV renders PCM. WebM offers audio copy. For sound-only output, WAV, WAVE and CAF render PCM, and M4A renders AAC.

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

Every CLI command and the app's factory settings use the default above. The app's Settings can change the movie default mode for the app.

## Alternatives when an export is unavailable

Alternatives are checked in rank order and every one that works is reported, least destructive first. The rank compares, in order: how much is encoded (nothing, cut edges, the sound, picture and sound), whether the source format changes, whether an encoding generation is added, and the time to write. An alternative is offered, never applied, unless the request asked for `--audio auto`.

| Rank | Id | Encoded | Format | Added loss | What it does |
| --- | --- | --- | --- | --- | --- |
| 1 | `copy_other_container` | nothing | kept | none | Keep the original packets and use a container that supports these cuts. |
| 2 | `copy_sample_aligned` | nothing | kept | none | Move each cut to the nearest audio sample, then copy the audio. Each cut moves by less than one sample. |
| 3 | `smart_trim` | cut edges | kept | one generation | Copy complete sections and encode only the video at the cut edges. |
| 4 | `convert_same_format` | sound | kept | one generation | Re-encode the selected audio once using the original codec (MP3, AAC, FLAC or Opus) and settings. |
| 5 | `convert_pcm` | sound | changed | none | Save the selected audio as a PCM WAV file. This preserves the decoded samples and uses more disk space. |
| 6 | `convert_aac` | sound | changed | one generation | Save the selected audio as AAC in an M4A file. |
| 7 | `reencode` | picture and sound | changed | one generation | Encode the whole timeline with the hardware video encoder. |

## Mixed timelines

A timeline is mixed when a clip differs from the first one in anything a packet copy has to match: codec, picture size, orientation, pixel format, frame rate, colour tags, codec configuration, track layout, or the codec, sample rate and channels of a sound track. The container itself is not compared: the same picture-only streams in MP4, MOV and MKV copy together. A container can describe the same stream in other words: MP4 states an AAC track as “2 channels” where MOV states “stereo”. Channel layouts are compared by what they stand for, so a layout that names no speakers equals the standard layout of its channel count (mono, stereo, 5.1) and those two clips copy together. Layouts that name different speakers, such as 5.1 and 5.1(side), are different.

| Mode | Mixed timeline | If unavailable, offer |
| --- | --- | --- |
| `smart` | refused: `incompatible_clip`, reason `join_stream_mismatch`. The message names the first property that differs. | `reencode` |
| `copy` | refused: `incompatible_clip`, reason `join_stream_mismatch`. The message names the first property that differs. | `reencode` |
| `encode` | written on one canvas, with the warnings below | — |

The tier of a mixed timeline is Re-encode with the factor `join_stream_mismatch`. Nothing switches mode by itself: a copy or Smart Trim request is refused and offers the re-encode. In the app, adding a clip that makes the timeline mixed asks first, like any edit that lowers the tier, and says: “Exporting these clips together requires Re-encode. All clips will use the first clip’s frame size.” The choices are “Add Anyway” and “Cancel”. These rules are about movies. Sound-only recordings in different formats are joined by Convert Audio, as before; the app still asks for matching recordings when one is added to a sound-only timeline.

### Canvas

- Picture size: the first clip's display size, with its rotation and pixel shape applied, rounded up to even numbers. Pixels are square.
- Fit: every other clip is turned upright, scaled to fit inside the canvas and centred on black. Bars are added at the sides or at top and bottom. Nothing is cropped or stretched.
- Pixel format: the chosen encoder's (8-bit 4:2:0 for H.264, 4:2:2 10-bit for ProRes, 4:2:0 for HEVC with ten bits when any clip has more than eight).
- Colour: tagged like the first clip. A clip with another matrix or range is converted to it. Primaries and transfer function are not converted, so an HDR clip is never joined to an SDR one.
- Frame rate: not converted. Every picture keeps its own time, so clips with different frame rates give a variable frame rate.
- Sound: one output track per track position, as many as the clip with the most. A position keeps its sample rate and channel layout when the clips agree; otherwise it is resampled to 48 kHz or mixed to stereo. A clip without that track is written as silence. The sound is always converted: AAC, or PCM where the rules choose it for the codec and container.
- There is no project setting for the canvas. Put the clip whose picture should be kept first.

### Audio actions on a mixed timeline

| Action | Result |
| --- | --- |
| `auto` | Converted: AAC, or PCM for ProRes outside MP4. |
| `copy` | Refused: `incompatible_clip`. Offers the re-encode with `auto`. |
| `aac` | Converted to AAC in the canvas format. |
| `pcm` | Converted to PCM in the canvas format. |
| `remove` | No sound is written. |

### Refused in every mode

| Mix | Refusal | Reason id |
| --- | --- | --- |
| A movie and a sound-only recording | “Clip 2 (name) has no picture. A timeline holds movies or sound-only recordings, not both. To change a movie's soundtrack, use Replace Source Audio.” | `join_media_type` |
| SDR with HDR, or PQ with HLG | “Clip 1 (name) is SDR and clip 2 (name) is HDR (PQ). Re-encode cannot convert between them, so they cannot share a timeline. Export them separately.” | `join_dynamic_range` |
| A source Re-encode cannot read (alpha, interlaced, extra HEVC layers, a rotation that is not a quarter turn) | the source's own refusal, with the clip number | `source_encode_unsupported` |

A single-type selection of a mixed timeline is not a re-encode. Video only is a packet copy, so it is refused with `incompatible_clip` and has no alternative. Audio only is refused as a copy and offers Convert Audio, which converts sound in different formats.

Editor interchange (Resolve, Final Cut Pro, Premiere Pro) writes no media, so a mixed timeline is not refused there. Each clip is described in its own format, and the sequence takes its size and frame rate from the first clip with picture.

### Warnings

A dry run and the export it plans report the same warnings.

- Sources differ in video codec and picture size (clips 1 and 2); the whole timeline is re-encoded to 1920×1080.
- Sources differ in audio sample rate (clips 1 and 2); the sound of the whole timeline is converted.
- Clip 2 has another picture shape and is fitted inside 1920×1080 with black bars. Nothing is cropped or stretched.
- The clips have different frame rates. Every picture keeps its own time, so the output has a variable frame rate.
- The clips have different colour primaries or transfer functions. They are not converted, and the output is tagged like clip 1.
- Audio track 1 is resampled to 48 kHz, so that every clip has one sample rate the encoder accepts.
- Audio track 1 has different channel layouts and is mixed to stereo.
- Clip 3 has no audio track 1. Silence is written there.

## Visible still placements

These rows apply to both sequence and multicam projects. The planner verifies the source, joins, image generation and audio independently.

| Selection | Lossless Copy | Smart Trim | Re-encode |
| --- | --- | --- | --- |
| Picture and sound | Refused (`placement_picture`) | Smart Trim | Re-encode |
| Picture only | Refused (`placement_picture`) | Smart Trim | Re-encode |
| Sound only with an insert | Refused (`placement_silence`) | Refused (`placement_silence`) | Convert Audio |

Omitting the mode with visible still picture selects Smart Trim. A picture replacement alone leaves the sound-only selection on the ordinary rules. Preserve camera picture requires zero encoded camera duration. Export reports distinguish copied camera, encoded camera and generated still durations. The True Lossless tier requires every selected output packet to copy.


## Timeline tier

The tier of a timeline is the best mode that plans for all of its clips with every track and exact cuts, over the containers the planner verifies. It is computed by running the planners in the order below, never by restating their rules, and it uses the same rank as the alternatives above. The app shows it as a badge and asks before an edit made by hand lowers it. For a multicam program the tier is found the same way from `MulticamEngine`, with picture and sound; the multicam editor shows the badge and asks after an edit made by hand lowers it, because the program is planned off the main thread and the tier of an edit arrives after it: it is compared with the tier of the program before the first of those edits, the question offers to move the switches and range edges that lower it to their nearest verified times when that keeps the tier, and Cancel undoes those edits. In the CLI, media inspect reads the cut index for a movie or sound-only source to report tier, including with --frames or --keyframes. A sidecar can supply the index. Selecting one track type or requesting --audio-packets omits tier. Project inspection reports the saved timeline tier. Export clips join, export project render, export ranges join, export ranges separate, scenes export and silence export also report it. The tier never changes what a request writes.

Adjacent clips that are contiguous in one source, a split that removes nothing, are planned as the single range they make, in every mode and container. Their seam is not a cut: it needs no verified boundary, nothing is encoded there, and the copy is the one the unsplit range gives. The seam becomes a cut when a piece is removed, moved or trimmed.

| Tier | Id | Movie mode | Sound-only mode | What is encoded |
| --- | --- | --- | --- | --- |
| True Lossless | `true_lossless` | `copy` | `copy` | MPCut copies the original media without re-encoding it. Sound only: MPCut copies the original media without re-encoding it. |
| Lossless | `lossless` | `smart` | `encode` with `pcm` | Smart Trim re-encodes the video around cuts that need it and copies the rest. Sound only: Export as PCM to keep the audio samples unchanged. |
| Re-encode | `reencode` | `encode` | `encode` with `aac` | Exporting this timeline requires a full re-encode. Sound only: This audio needs a lossy conversion to export. |

The badge shows “Checking…” during indexing and “Can’t Export” if none of the export modes work. The export sheet starts with your preferred mode when the timeline supports it. Otherwise, it selects the best available mode. Audio-only exports always open on Lossless Copy. If an exact copy isn’t possible, the sheet lists the available alternatives in order of preference. `--audio auto` uses the first one. Both checks try the preferred container first, then use the first compatible one. MPCut checks the hardware encoder when you export.

## Tier factors

Each factor explains why a higher-quality mode is unavailable. Errors include the factor ID in `reason`. An audio-only timeline can still qualify as Lossless when it can export as PCM without changing the decoded samples.

| Id | Scope | Leaves at best | Exact alternative | Meaning |
| --- | --- | --- | --- | --- |
| `cut_video_start` | cut | Lossless | verified times in `nearest` | The first frame needs an earlier frame to decode. Smart Trim re-encodes the start of the clip. |
| `cut_video_end` | cut | Lossless | verified times in `nearest` | Frames near the end of the clip depend on frames past the cut. Smart Trim re-encodes the end of the clip. |
| `cut_off_frame` | cut | Can’t Export | verified times in `nearest` | The cut falls between video frames. |
| `cut_audio_packet` | cut | Re-encode | verified times in `nearest` | A cut falls inside a compressed audio packet, or the picture and a sound track share no boundary there. |
| `cut_audio_priming` | cut | Re-encode | — | The clip starts in the audio track’s encoder delay, before the first audible sample. |
| `cut_audio_sample` | cut | Lossless | verified times in `nearest` | A cut falls between audio samples. |
| `cut_aac_coverage` | cut | Re-encode | — | An AAC track does not cover the cut with continuous, audible samples. |
| `cut_pcm_sample_clock` | cut | Re-encode | — | A PCM track cannot place the cut on its sample clock in this container. |
| `cut_opus_window` | cut | Re-encode | — | An Opus track cannot keep the requested start or end within its trim window. |
| `cut_mp3_crop` | cut | Re-encode | — | An MP3 track cannot be cropped to the range with gapless timing. |
| `join_decoder_history` | join | Re-encode | — | The audio decoder needs samples from before the join. It can copy one continuous range. |
| `join_video_dts_overlap` | join | Lossless | verified times in `nearest` | The two ranges overlap in video decode time at the join. |
| `join_smart_open_gop` | join | Re-encode | — | Frames in this open GOP depend on frames from an earlier group of pictures. Smart Trim has no verified keyframe where it can resume copying. |
| `join_stream_mismatch` | join | Re-encode | — | These clips use different codecs, frame formats, timing or audio formats. Use Re-encode to export them together. |
| `join_media_type` | join | Can’t Export | — | The timeline contains both video clips and audio-only recordings. |
| `join_dynamic_range` | join | Can’t Export | — | MPCut can’t combine HDR with SDR, or PQ with HLG. Export them separately. |
| `join_timecode` | join | Re-encode | — | The timecode track cannot be rewritten for these ranges. A re-encode omits it. |
| `source_unsupported_tracks` | source | Re-encode | — | The source has tracks or timing a copy cannot write. |
| `source_smart_ineligible` | source | Re-encode | — | Smart Trim cannot encode this picture format at cut edges, so it copies on verified boundaries only. |
| `source_multiple_descriptions` | source | the same tier in another container | — | The source uses several video sample descriptions and needs MOV or MP4. |
| `source_start_unsafe` | source | Re-encode | — | The source cannot be copied from its first picture. |
| `source_timeline` | source | Can’t Export | — | The source timeline is unsupported. |
| `source_encode_unsupported` | source | Can’t Export | — | The encoder cannot read or keep this source's picture, timing or sound. |
| `source_changed` | source | Can’t Export | — | A source file changed since it was indexed. |
| `output_container` | output | the same tier in another container | — | The container cannot carry these tracks or cuts. |
| `selection_tracks` | selection | Can’t Export | — | These tracks or settings aren’t available for this source. |
| `placement_picture` | placement | Lossless | — | A visible still needs generated picture samples. |
| `placement_silence` | placement | Lossless | — | An inserted still needs generated silence. |
| `writer_other` | writer | Can’t Export | — | MPCut couldn’t prepare or write the export. |

## Entry points

| Entry point | Source | Modes | Reports alternatives | Named restrictions |
| --- | --- | --- | --- | --- |
| App: Export sheet | movie | `smart`, `copy`, `encode` | yes | noAutoAudioConversion: Convert Audio names a format, so the sheet always shows what it will write. The first offer is what `--audio auto` applies. |
| App: Export Queue | movie | `smart`, `copy`, `encode` | yes | sharedSettings: one setting applies to every range, so an alternative that moves cuts (`copy_sample_aligned`) is not offered.<br>sourceCompatible: Lossless Copy and Smart Trim can leave the container to the copy planner. |
| App: multicam Export inspector | multicam | `smart`, `copy`, `encode` | yes | listedContainers: the app lists containers for the selected picture mode and audio delivery. The CLI accepts every extension the planner verifies.<br>switchTimes: an unsafe switch or range edge also reports verified times. |
| App: multicam Export Queue | multicam | `smart`, `copy`, `encode` | yes | listedContainers: the app lists containers for the selected picture mode and audio delivery. The CLI accepts every extension the planner verifies.<br>switchTimes: an unsafe switch or range edge also reports verified times. |
| App and CLI: Replace Source Audio | movie | `copy` | no | copyOnly: a replaced soundtrack is copied with both track types. |
| CLI: export clips join | movie | `smart`, `copy`, `encode` | yes | namedOutput: `--audio auto` applies the first alternative that fits the extension of `--output`. |
| CLI: export ranges separate | movie | `smart`, `copy`, `encode` | yes | namedOutput: `--audio auto` applies the first alternative that fits `container` when one is given. |
| CLI: export ranges join | movie | `smart` | yes | noEncode: use export clips join for --mode encode.<br>nearestByDefault: video cuts snap to the nearest boundary. |
| CLI: silence export | movie | `smart`, `copy` | yes | noEncode: retained ranges are written with Smart Trim or Lossless Copy.<br>generatedClips: the failing clips are the retained ranges, so each alternative lists them in `clips`.<br>projectRanges: with `--project` the retained ranges resolve through `MulticamEngine.resolution` like `export project render --project`. They exist only in the report, so the alternatives listed are the ones this command can request for them: another container or the other mode, through its own `--output` and `--mode`. |
| CLI: scenes export | movie | `smart` | yes | smartOnly: every scene is written with Smart Trim, or Lossless Copy for a single-type selection. |
| CLI: export project render (multicam) | multicam | `smart`, `copy`, `encode` | yes | namedOutput: the extension of `--output` is the container.<br>audioDelivery: separate tracks default to copy. Explicit `--audio auto` chooses treatment per lane. Downmix always renders.<br>switchTimes: an unsafe switch or range edge also reports verified times in `nearest`. |

## Refusals

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | The matrix refuses this combination of tracks, mode and settings. |
| `unsafe_boundary` | A cut cannot be copied exactly. `nearest` lists verified times when there are any. |
| `still_requires_generation` | Visible still picture or inserted silence requires generated samples. |
| `camera_copy_required` | The requested settings encode retained camera picture. Review any verified placement adjustments in `stillBoundaryAdjustments`. |
| `unsupported_container` | The container cannot carry the selected tracks or this conversion. The message names the valid extensions. |
| `unsupported_tracks` | The source has tracks or timing that this mode cannot write. |
| `unsupported_audio` | The audio action does not apply to this source, selection or container. |
| `audio_copy_unavailable` | `--audio copy` was requested and the sound cannot be copied exactly. |
| `uncovered_audio` | A copied multicam lane would require new silence samples. The error identifies the lane and output interval. |
| `incompatible_clip` | The clips differ, so their packets cannot be joined. Re-encode writes a mixed timeline; see Mixed timelines for what no mode joins. |
| `encoder_unavailable` | The FFmpeg helper lacks the encoder, or the hardware encoder did not start. |
| `no_video` | A picture was requested from a source without one. |
| `no_audio` | Sound was requested from a source without a matching track. |
| `output_exists` | The destination exists. MPCut never overwrites. |
| `invalid_output` | The destination is not a writable local file path matching the container. |
