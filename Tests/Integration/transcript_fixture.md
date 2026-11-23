# Spoken transcript fixture

Generate about 8 MB of local QA media on macOS with Python 3.10+, FFmpeg with libx264, and Flite 2.2 (`brew install flite` or pass `--flite /path/to/flite`). The dialogue is original. The picture and non-speech burst are generated. The fixture uses the BSD-like CMU Flite `rms` and `slt` voices, whose upstream distribution permits commercial use. Generated media and the synthesizer are local build products. [Flite license](https://github.com/festvox/flite/blob/v2.2/COPYING)

```sh
python3 Tests/Integration/transcript_fixture.py /tmp/mpcut-spoken
MPCUT_SPOKEN_FIXTURE=/tmp/mpcut-spoken swift test --filter TranscriptFixtureTests
python3 Tests/Integration/transcript_fixture_baseline.py /tmp/mpcut-spoken
```

- Open `interview.cut` for multicam or `sequence.cut` for the same lav as a standalone sequence. The multicam uses the lav throughout and switches wide → close at 2 s and close → wide at 12 s. Source starts in group time are −0.5 s for wide, +1 s for close, and zero for the lav. Close audio starts another 0.5 s after its picture.
- `truth.json` gives speaker, group-time sample bounds, word order, internal word boundaries, track gains, non-speech, and exact click positions. The reference aligns the annotated word-to-phoneme mapping with Flite's phoneme times to 1 ms precision. Search for “The lantern glows” across three readings at 3 s, 7 s, and 11 s. The 7 s take omits “only.” “Just a second!” interrupts the host at 1.8 s. “The compass is upside down” at 15 s belongs only to the off-air close camera. During the host's question, close has the generated non-speech burst at 1.55–1.75 s.
- `lav.srt`, `wide.srt`, and `close.srt` use their respective source clocks. The three `*-recognition.wav` files put all inputs on the group clock for the legacy batch benchmark. `helper-session/manifest.json` uses source-local reference WAVs and signed starts for replay against the session-capable helper.
- `priming-click.mov` has AAC priming and a click at sample 20,000. `delayed-click.mov` has a 0.5 s delayed PCM stream and a click at sample 28,000. `close-gap.mkv` also removes 960 ms of silent PCM packets between the first and second retakes, leaving the subsequent dialogue positions unchanged. The extraction test uses MPCut's full index and production decoder.
- `parity.cut`, `parity.wav`, and `parity-words.json` provide a shared 48 kHz sequence fixture for the three editing surfaces. Its constant PCM is +4000 over [0, 1), −4000 over [1, 2), and +8000 over [2, 4). The imported word “remove” covers the entire negative block.
- `queue.cut` and `queue-words.json` provide a separate exact multicam parity case with a 2 s camera switch and one imported word on either side.
- The generated helper manifest references local paths and creates its artifacts under the fixture directory. To replay and score it with the new helper, use `python3 Tests/Integration/transcript_fixture_session.py /tmp/mpcut-spoken --helper /path/to/transcriberrr`.

## Installed ASR baseline

Transcriberrr 0.4.0 from `/Applications`, offline on an Apple M4 Max running macOS 27.0.1. Three 18-second aligned inputs produce 97 labeled audible word observations, including scripted bleed. The scorer aligns each phrase's emitted words against its ordered reference and measures edge error against the phoneme clock only on matched words. It scores diarization after a one-to-one mapping of speaker IDs on each track. Real-time factor is total process wall time divided by 54 s and includes cold model setup.

| Engine | Matched observations | Mean word-edge error | Attribution errors | Duplicate utterances within one track | Interruption recovered on wide / close / lav | Off-air words | Real-time factor |
|---|---:|---:|---:|---:|---|---:|---:|
| Parakeet Unified English | 92/97 | 253.8 ms | 3/92 | 0 | 3 / 3 / 0 | 5/5 | 0.458 |
| Apple SpeechTranscriber | 90/97 | 84.8 ms | Unavailable | 0 | 3 / 2 / 0 | 5/5 | 0.027 |
| Qwen3-ASR 1.7B with forced aligner | 93/97 | 38.2 ms | 2/93 | 0 | 3 / 3 / 0 | 5/5 | 0.867 |

For the isolated-track comparison, the existing Parakeet batch helper ran with `lav-recognition.wav guest-lav-benchmark.wav --offline --engine parakeet-v3`, once with `--iso-tracks=all` and once with `--iso-tracks=off`. Both produced all 33 intended Host and Guest words on their own lavs. Mute-first suppressed five exact Host bleed words plus two substitutions on the Guest lav. All 23 Guest retake words remained on the Host lav in both runs. The Guest's word-edge error was 247.7 ms independent and 252.3 ms muted. The new session uses independent recognition and reconciles using the words and track evidence. In the Apple run, Camera B emitted “2nd” for “second,” which the literal scorer counts as a substitution.

## Reconciled session thresholds

Set from the installed batch baseline before evaluating the session implementation.

- Recover at least 36 of 38 conversation words, including all five off-air words and all three interruption words. Case and punctuation are ignored. Numeric spellings count as substitutions. A recognized word matches at most one hand-labeled word in its utterance, in word order.
- Require word error rate at or below 10% and at most three insertions. An emitted word whose midpoint is outside all labeled utterance windows counts as an insertion.
- Retain exactly one “The lantern glows” onset for each scripted take at group 3 s, 7 s, and 11 s. Allow 450 ms of onset error. Installed Parakeet consistently emitted these onsets 360 ms late. Any additional occurrence anywhere in the conversation counts as a duplicate.
- Allow up to two mistaken or unresolved speaker assignments across matched words. Determine the best one-to-one mapping from emitted speaker IDs to the two scripted speakers, then count the remaining mismatches and words with an unknown speaker.
- Require mean absolute error across the start and end edges of matched words to be at most 300 ms on the group clock. The reference edges follow the synthesizer's phoneme clock. The click tests separately require the source transform within one 16 kHz sample.
- Require Camera B to report activity during the non-speech burst at 1.55–1.75 s without emitting a recognized word there. All five off-air words must have recognized Camera B observations with the exact normalized reference text. Each observation must match the linked track-local word ID, text, and sample bounds exactly. Its start and end must land within 350 ms of the reference edges after the Camera B offset is applied. The signed source starts must agree exactly with the manifest.

The scorer also reports normalized word counts per track and after reconciliation, plus substitutions, deletions, and insertions. Word error rate is those edits divided by the number of labeled words. A duplicate regression gate requires zero extra occurrences of any labeled word within its utterance. The reference retains intentional repetition and shared words spoken concurrently by different speakers. Run `python3 Tests/Integration/transcript_fixture_scoring_test.py` for independent cases.

## Initial session measurement

The first optimized session-compatible Parakeet build took 40.59 s for 53.52 s of input (0.758 real-time factor). The three tracks emitted 33 wide, 31 close, and 30 lav words. The merged result contained 54 words, recovered all 38 reference words, and inserted 16 words, for 42.1% word error rate. Fifteen insertions repeated words already present in their utterance. Its 4 speaker errors exceeded the limit of 2. All three retake onsets, all interruption and off-air words, the signed clocks, the absence of word recognition during the Camera B burst, and the 255.7 ms mean word-edge error met their thresholds.

## MPCut extraction and saved project checks

Both ordinary and multicam source clocks placed the AAC click at sample 20,000 and the delayed PCM click at 28,000. MPCut indexed the Matroska recording as discontinuous. The continuous MOV and the packet-hole Matroska extraction each delivered the same 272,000 source-clock samples as the independent PCM reference.

The CLI prepared three tracks from the same ordinary multicam project. All three staged WAV files matched the corresponding source-clock fixture files byte for byte. The actual offline Parakeet helper completed that manifest. The CLI reopened its durable job, attached all three verified bindings by job ID, and reopened the saved project. Group search found the off-air phrase once. Current Cut had no match because program audio was fixed to the lav.

A second CLI job recognized only Camera B. The helper reported Camera B as recognized and the wide and lav tracks as skipped. All three retained activity, with 850 close, 926 wide, and 900 lav level frames.

## Updated session measurement

The updated native helper replayed stored recognition artifacts from the optimized offline runs with `--reconcile-only`. Both engines met all ten session checks, including the duplicate regression gate. Each set had 94 recognized track words before reconciliation (33 wide, 31 close, 30 lav).

| Engine | Merged words | Reference words recovered | Insertions | Word error rate | Mean word-edge error | Speaker errors | ASR and original reconciliation real-time factor |
|---|---:|---:|---:|---:|---:|---:|---:|
| Parakeet Unified English | 39 | 38/38 | 1 | 2.6% | 235.7 ms | 2 | 0.758 |
| Qwen3-ASR 1.7B with forced aligner | 38 | 38/38 | 0 | 0% | 22.1 ms | 0 | 1.334 |

Moving Camera B half a second forward and reconciling the stored Parakeet outputs moved the group onset of “compass” from sample 246,400 to 254,400. Its track-local word ID and sample bounds were identical. The helper opened no recognition run, and the recognition and activity artifact digests were identical before and after.

## Human read-speech check

A separate check used `1089-134686-0001` and `1221-135766-0000` from the official LibriSpeech `test-clean` archive, by Vassil Panayotov and collaborators. The archive's `LICENSE.TXT` applies Creative Commons Attribution 4.0. The downloaded archive's MD5 was `32fa31d27d2e1cad72775fee3f4849a9`. The original FLACs, converted WAVs, and license file stayed in the external QA directory. [OpenSLR LibriSpeech resource and archive](https://www.openslr.org/12/), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

The two excerpts contain 15.710 seconds of audiobook narration and 45 labeled words. The updated offline session helper with Apple SpeechTranscriber emitted 45 words with one spelling substitution, “counseled” for “counselled,” and no deletions or insertions, for 2.22% literal word error rate. The installed offline Parakeet and Qwen batch runs each matched all 45 reference words. Each excerpt contains one narrator. Word timing, concurrent speakers, room bleed, and multicam routing remain covered by the separate controlled fixture.

```sh
export TRANSCRIBERRR_NATIVE=/Applications/Transcriberrr.app/Contents/Helpers/transcriberrr-native
python3 Tests/Integration/transcript_fixture_human.py /path/to/test-clean.tar.gz /tmp/mpcut-human-session --helper /path/to/session-capable/transcriberrr
```

## Human multichannel meeting check

The AMI Consortium’s Edinburgh meeting `ES2002a` provides four synchronized close-talking headsets and a table microphone. The test cropped the original `Headset-0` through `Headset-3` and `Array1-01` recordings to `[902, 917)` seconds, with no gain or timing adjustments, then packaged the slices as 16 kHz mono PCM WAVs. The 1.6.2 manual annotation archive supplies per-speaker word timing. The official channel map associates headsets 0 through 3 with participants A through D. The corpus and annotations are CC BY 4.0. Audio, annotations, and results stay in an external scratch directory. [AMI download and manual annotations](https://groups.inf.ed.ac.uk/ami/download/), [AMI license](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml), [AMI channel map](https://groups.inf.ed.ac.uk/ami/corpus/signals.shtml)

The excerpt was selected from the annotations before hearing the ASR output. It contains 68 complete positive-duration lexical tokens, with 39 overlapping a different speaker’s annotated word by at least 80 ms. There are three active speakers. Headset C remains in the inventory as an inactive channel. The scorer pairs equal normalized tokens one to one within a 650 ms midpoint window and reports mean absolute start/end error for the paired words. Duplicate candidates are unmatched outputs with a same-token reference inside that window. A stricter label-supported count requires exactly one plausible human-labeled token and an overlapping matched output whose midpoint is within 125 ms. The other candidates remain unclassified. Per-headset recall uses that headset’s annotated speaker. The room and merged speaker scores map inferred IDs one to one to the annotated speakers. The merged report also checks the actual exported participant names. Words crossing the cut boundary are outside the reference, and concurrent word ordering and tokenization can affect matching.

```sh
mkdir -p /tmp/mpcut-ami
curl --fail --location https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip -o /tmp/mpcut-ami/manual.zip
python3 Tests/Integration/transcript_fixture_ami.py /tmp/mpcut-ami/manual.zip /tmp/mpcut-ami/parakeet --helper /path/to/optimized/transcriberrr
```

The optimized Parakeet run took 15.48 seconds for 75 seconds of track input. It reconciled 54/68 reference words, compared with 45/68 on the room mic alone. Coverage of overlapping words rose from 21/39 to 29/39. Thus ten labeled overlapping words remained unmatched. The merged output had 59 words, including five unmatched outputs and zero same-token duplicate candidates. Three of the 54 matched words had a wrong participant label. Headset D was the hardest active channel, matching six of 12 reference words. The inactive headset emitted no words.

| Parakeet source | Emitted words | Timed matches | Matches on overlapping reference words | Mean paired word-edge error |
|---|---:|---:|---:|---:|
| Headset A | 33 | 31/38 | 12/18 | 233.2 ms |
| Headset B | 18 | 16/18 | 9/10 | 245.3 ms |
| Headset C | 0 | 0/0 | 0/0 | — |
| Headset D | 7 | 6/12 | 6/11 | 205.8 ms |
| Room | 48 | 45/68 | 21/39 | 230.0 ms |
| Reconciled | 59 | 54/68 | 29/39 | 227.5 ms |

The initial optimized Qwen run took 44.70 seconds. It matched 54/68 reference words with 90.7 ms paired edge error, but the merged output emitted 116 words, with 45 duplicate candidates and 25 supported by a unique human label. Twelve of 54 timed matches had the wrong named speaker. The inactive headset alone emitted 46 words, 42 matching other speakers’ manual annotations in the same time window. A reconcile-only diagnostic with C marked skipped reduced the merged output from 116 to 70 words, duplicate candidates from 45 to six, label-supported duplicates from 25 to zero, and named attribution errors from 12 to two. It also lost three matches, reducing recall to 51/68. The test retains the original all-channel result.

| Initial Qwen source | Emitted words | Timed matches | Matches on overlapping reference words | Mean paired word-edge error |
|---|---:|---:|---:|---:|
| Headset A | 44 | 31/38 | 12/18 | 75.3 ms |
| Headset B | 22 | 15/18 | 8/10 | 22.7 ms |
| Headset C | 46 | 0/0 | 0/0 | — |
| Headset D | 11 | 5/12 | 5/11 | 26.0 ms |
| Room | 48 | 45/68 | 21/39 | 74.2 ms |
| Reconciled | 116 | 54/68 | 27/39 | 90.7 ms |

The held-out run uses a different Edinburgh meeting, `ES2004a` at `[578, 593)` seconds. Choose it with `--meeting ES2004a` and a new output directory. Its four participants speak in the selected excerpt. The 1.6.2 official annotation ZIP used for both excerpts has SHA-256 `b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d`.

| ES2004a source | Parakeet emitted / matched / reference | Parakeet edge error | Qwen emitted / matched / reference | Qwen edge error |
|---|---:|---:|---:|---:|
| Headset A | 13 / 13 / 14 | 241.9 ms | 13 / 13 / 14 | 54.2 ms |
| Headset B | 16 / 14 / 16 | 256.1 ms | 15 / 13 / 16 | 95.4 ms |
| Headset C | 13 / 13 / 16 | 254.2 ms | 16 / 15 / 16 | 159.0 ms |
| Headset D | 20 / 20 / 20 | 230.5 ms | 20 / 20 / 20 | 53.0 ms |
| Room | 53 / 44 / 66 | 259.3 ms | 40 / 30 / 66 | 132.6 ms |
| Reconciled | 74 / 60 / 66 | 247.8 ms | 80 / 62 / 66 | 101.7 ms |

The initial held-out Parakeet session ran in 7.13 seconds. It matched 29/33 overlapping words, with five named-speaker errors, four duplicate candidates, and two label-supported duplicates. Qwen ran in 28.94 seconds and matched 31/33 overlapping words, with two named-speaker errors, six duplicate candidates, and zero label-supported duplicates. On this excerpt both mixes missed many overlapping words that the reconciler recovered from the headsets.

For room-only diarization, the best label mapping left 1/45 Parakeet and 2/45 Qwen matched words misattributed on `ES2002a`. On `ES2004a` the counts were 5/44 and 2/30. Headset results report lexical coverage against the registered participant’s reference. Their raw ASR outputs carry no independent speaker IDs.

Replay existing recognition artifacts with `--reuse-from` and an empty output directory to compare reconciliation revisions. The script checks the input audio, recognition, and activity digests after replay.

```sh
python3 Tests/Integration/transcript_fixture_ami.py /tmp/mpcut-ami/manual.zip /tmp/mpcut-ami/qwen-replay --helper /path/to/updated/transcriberrr --engine qwen3 --reuse-from /tmp/mpcut-ami/qwen
```

The updated helper combines lexical and timing agreement with relative activity evidence when it identifies headset bleed. It replayed all four stored sessions without changing any input artifact or rerunning recognition. The initial high-bleed Qwen case improved as follows.

| ES2002a Qwen reconciliation | Initial | Updated |
|---|---:|---:|
| Emitted words | 116 | 85 |
| Timed matches | 54/68 | 53/68 |
| Matches on overlapping words | 27/39 | 26/39 |
| Unmatched emitted words | 62 | 32 |
| Same-token duplicate candidates | 45 | 15 |
| Label-supported duplicates | 25 | 2 |
| Wrong or unknown named speakers among timed matches | 12/54 | 7/53 |
| Mean paired word-edge error | 90.7 ms | 72.8 ms |

The other three sessions had identical measured results. The high-bleed case still loses some labeled overlap and emits extra words. One fewer reference word matched after reconciliation. Both engine replays on the controlled Flite fixture passed all ten existing checks with the updated helper.

These room-recorded excerpts exercise human overlap, bleed, and microphone reconciliation. The synthetic fixture remains the acceptance reference for exact camera direction and routing.

## Overlapping speech across all three engines

The release helper was tested on four AMI excerpts with the same four headsets and room microphone per meeting. The excerpts cover 65 seconds and contain 277 human-labeled words, including 150 spoken while another participant was talking. Alongside the two excerpts above, the test uses `ES2005a` at `[0, 15)` and `ES2012b` at `[2000, 2020)`. The last meeting runs without a supplied speaker count.

Both helper versions merged the same saved recognition and activity data. The fixture verified the audio, recognition and activity digests on replay. Each cell shows the earlier and revised result.

| Engine | Label-supported duplicate words | Overlapping words recovered / 150 | Overlapping words matched to the right participant / 150 | All timed word matches / 277 |
|---|---:|---:|---:|---:|
| Qwen3 | 15 → 6 | 115 → 115 | 114 → 115 | 227 → 227 |
| Parakeet V3 | 13 → 5 | 123 → 123 | 120 → 122 | 242 → 241 |
| Apple Native | 52 → 20 | 106 → 106 | 103 → 104 | 216 → 215 |

A label-supported duplicate is an extra emission of the same token with overlapping word spans and midpoints within 125 ms, where a single human label supports both. The correct-participant measure matches each token one-to-one within each named speaker's words. This lets two people both get credit for saying “yeah” at the same time. Across the 12 revised session results, all 1,655 raw track words can be traced from the conversation to their original track, word ID, text and sample range.

The raw microphones themselves contained timed matches for at most 116 of the 150 overlapping words on Qwen, 124 on Parakeet and 107 on Apple, even with the scorer free to choose any microphone for each reference word. The reconciler recovered all but one of those possible matches on each engine. An example of the one-word tradeoff in total recall occurred on Parakeet. A participant stuttered “be be,” while the microphones returned one “be” at the same time. The old version emitted a second copy attributed to a different participant. The revised result keeps one word and links the microphone observations.

The Apple replay above used the original recognition without room diarization. A separate offline run recognized all four sets of WAVs afresh with Apple Native and Sortformer enabled on the room microphone. It produced 21 label-supported duplicates, recovered 106 overlapping words and matched 104 to the right participant. The room track acquired three, four, three and three speaker labels respectively in meeting order. Across all 277 words, 211 matched both the token and the named participant, compared with 209 in the revised replay without room diarization.

On the controlled three-track interview, Parakeet and Qwen passed all ten checks. Apple passed eight, including the interruption, off-air dialogue, attribution, and duplicate checks. It matched 36/38 words, added two words, and missed the word-error and literal retake checks. Apple repeatedly heard “blows” for “glows.” The merged transcript presents one reading of the phrase and preserves the competing track text when it exists.

To compare a fresh recognition with an earlier run, pass `--audio-from PATH` to reuse its verified microphone WAVs. For a merge-only comparison, pass `--reuse-from PATH` to replay its original recognition and activity files. Give each run its own output directory.
