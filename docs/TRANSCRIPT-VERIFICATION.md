# Verifying transcript edits

The same generated interview drives the audio extraction, command-line, live MCP and native window checks. The two camera recordings and isolated lav have known starts, dialogue and overlap. The separate parity fixture makes a wrong edit audible and measurable. Its middle second has negative PCM samples, and the retained sections have different positive values.

## What the checks measure

| Workflow | Observable outcome |
|---|---|
| Preparing input | MPCut stages the correct streams and channels. Delayed and primed clicks land at samples 28,000 and 20,000. A packet hole inserts silence on the source clock. |
| Merging three microphones | Track-local word evidence, speaker assignment, group timing, insertions and misses are scored separately. The off-air line is present on its camera and absent from the fixed-lav program. |
| Cutting by word | Removing the middle word leaves exactly the ranges [0, 1) and [2, 4). Undo restores [0, 4). Applying an obsolete plan after rebinding leaves the project as edited by the user. |
| Assembling separate takes | Two independently imported transcripts deliberately use the same word IDs. An ordered edit keeps the selected qualifier and source order in one undo step. The copy-safe output preserves the compressed picture packets and PCM samples. |
| Delivering a multicam quote | An excerpt keeps its original camera switch after the source project changes. The switch falls between frames 24 and 25 of the excerpt. The soundtrack matches the reference lav's 64,000 PCM bytes. |
| Recovery | A gated helper allows repeatable cancellation and interruption. A separate desktop-process test quits and relaunches the app to check durable jobs, attachment recovery, saved timeline edits and undo. |

The synthetic interview has 38 labeled conversation words. The Parakeet and Qwen session runs each recovered 38. Parakeet added one word and assigned two words to the wrong speaker. Qwen had zero insertions and zero speaker errors on this fixture. A separate 45-word audiobook sample checks recognition on two human voices. Four five-microphone AMI meeting excerpts test overlapping human speech, headset bleed, duplicate words and speaker assignment. The fixture guide includes per-engine measurements, source licenses and scoring definitions. [Fixture and model measurements](../Tests/Integration/transcript_fixture.md)

A release-helper replay of all four meetings reduced label-supported duplicate words from 15 to 6 on Qwen, 13 to 5 on Parakeet and 52 to 20 on Apple. Each engine retained its overlapping-word count and attributed more of those words to the right participant. A separate fresh Apple run verified mixed-microphone speaker labels with Sortformer. The controlled Apple interview still misses its word-error and exact-retake checks. [Overlapping speech measurements and reproduction](../Tests/Integration/transcript_fixture.md#overlapping-speech-across-all-three-engines)

With the signed helper, the native window test selected each engine, enabled speaker identification, saved the transcript, changed a camera offset and reconciled the existing attachment. All three runs passed. In a separate CLI test for each engine, MPCut prepared the three tracks, Transcriberrr ran offline, and MPCut imported the result by job ID. Searching for “compass” found the off-air line in Group and excluded it from the fixed-lav Current Cut.

## Measured backend changes

The three-hour performance fixture contains four sources, 20,082 conversation words and 70,372 track observations. The following medians come from three alternating runs with the changed projection and search files compiled with Swift optimization enabled against the same dependency objects. Encoded reads, searches and gap reports had identical SHA-256 digests across the variants. The last column builds only the index requested by a Current Cut command.

| Measurement | Original full index | Revised full index | Revised Current Cut only |
|---|---:|---:|---:|
| Build index, thread CPU | 1.064 s | 0.691 s | 0.559 s |
| 101 filtered reads, thread CPU | 231 ms | 37 ms | 36 ms |
| 101 searches, thread CPU | 87 ms | 23 ms | 20 ms |
| Peak resident memory | 579 MiB | 500 MiB | 499 MiB |

The standalone benchmark starts a new CLI process for each operation on the same three-hour project. The original run used the signed release CLI staged with its FFmpeg dependencies. The revised run used the CLI from the verified app bundle. Five runs per release build verified word IDs, result order, and saved correction history. The project, transcript and all four media inputs had identical SHA-256 hashes. Median process CPU and peak resident memory improved on the read and search paths. [Benchmark](../Tests/Benchmarks/transcript.py)

| Public CLI operation | Original release CPU | Revised release CPU |
|---|---:|---:|
| Read first page | 1.06 s | 0.71 s |
| Read middle page | 1.05 s | 0.70 s |
| Search a phrase | 1.07 s | 0.70 s |
| Read a later search-results page | 1.10 s | 0.69 s |
| Search after saving a correction | 1.23 s | 0.83 s |

Read and search peak memory fell from about 622–628 MiB to 507–511 MiB. Opening a plain project and opening one with the attachment took median wall times of 1.18 s and 1.21 s in the revised build. Project-open samples overlapped. Load varied during the comparison, especially for the original build. A separate quieter original run also showed lower read and search CPU in the revised build. Saving a correction itself peaked at 685 MiB compared with 673 MiB previously.

## Measured native window changes

The macOS Accessibility runner imported a two-hour recording with 28,800 timestamped words into the desktop app. It searched for a phrase with 120 matches and advanced through five matches. The second revision also increased the dialogue viewport from about 157 to 239 points at the same 315-point pane width, making three complete speaker turns visible. [Transcript search screenshot](images/transcript-search.png)

| Action | Original pane | Background import and search | Revised reader layout |
|---|---:|---:|---:|
| Confirm binding until dialogue appears | 3,035 ms | 1,523 ms | 1,798 ms |
| Submit search until results appear | 336 ms | 339 ms | 435 ms |
| Go to next match, median | 252 ms | 137 ms | 155 ms |

These are single native-window runs on a machine also running builds. The original search and navigation times come from a rerun with the fixture already attached. It submitted the search through the field's accessibility confirmation action. The two revised builds used the Find button. A second run with the revised layout took 1,805 ms to display dialogue, 346 ms to find the phrase, and a median 162 ms to move between matches. The measured gain was in import and navigation. Search latency varied between runs. Use a new output directory to repeat the measurements and capture both window screenshots.

```sh
swift Tests/Integration/transcript_gui.swift "$app" --benchmark /tmp/mpcut-transcript-window-run
```

On the final signed release, choosing the file opened the binding review in 837 ms. Confirming the binding opened the paged, 28,800-word transcript in 1,457 ms. Finding 120 matches took 327 ms. Moving to the next match took a median 119 ms over five clicks (93–170 ms). This run used the production build after the pane refresh fixes.

## Reproduce the checks

From the MPCut checkout, create the fixture in a writable directory. The generator needs FFmpeg and Flite. The fixture guide includes the speech labels, scoring rules and installed-engine comparison. [Spoken transcript fixture](../Tests/Integration/transcript_fixture.md)

```sh
python3 Tests/Integration/transcript_fixture.py /tmp/mpcut-spoken
scripts/build-app.sh .build/transcript-verified
app="$PWD/.build/transcript-verified/MPCut.app"
cli="$app/Contents/Helpers/mpcut"
MPCUT_SPOKEN_FIXTURE=/tmp/mpcut-spoken swift test --filter Transcript
python3 Tests/Integration/transcript_cli.py "$cli"
python3 Tests/Integration/transcript_parity.py "$cli"
python3 Tests/Integration/transcript_takes.py "$cli"
swift Tests/Integration/transcript_gui.swift "$app" /tmp/mpcut-spoken
swift Tests/Integration/transcript_gui.swift "$app" --switch-cameras /tmp/mpcut-spoken
python3 Tests/Integration/transcript_lifecycle.py "$app" --scratch-dir "$PWD/.build/recovery-process"
```

The native window and lifecycle tests need a logged-in Mac, Backstage, and Accessibility permission. They launch muted MPCut instances on Backstage’s hidden display. The Go suite launches its own copy of the bundle, starts the packaged MCP server and reads back the resulting project and exports.

```sh
go test -C mcp -v ./integration -run '^TestLiveBundle$/^Transcript' -count=1 \
    -args -bundle="$app" -transcript-fixture=/tmp/mpcut-spoken
```

To run the agent walkthrough directly, open the matching MPCut build and enable local control. Use a fresh copy of the disposable fixture project and an empty output directory for each run.

```sh
example=$(mktemp -d)
cp /tmp/mpcut-spoken/parity.cut /tmp/mpcut-spoken/parity.wav "$example/"
mkdir "$example/exports"
python3 docs/mcp_walkthrough.py --helper "$app/Contents/Helpers/mpcut-mcp" \
    --transcript-project "$example/parity.cut" \
    --import-transcript /tmp/mpcut-spoken/parity-words.json \
    --bind-file "$example/parity.wav" --bind-stream 0 \
    --quote remove --output-dir "$example/exports"
```

To exercise the model-backed checks, supply a Transcriberrr helper that advertises session schema version 1 and has the selected engine's models available locally. The standalone workflow starts the provider explicitly. [Command-line workflow](TRANSCRIPTS.md#stage-recognition-and-import-the-result)

The preparation output and provider result have separate versioned schemas. The provider and MPCut use matching schemas for the handoff. An MPCut JSON export has its own document schema and can be imported into the editor again. [MPCut document schema](schema/transcript-document-v2.schema.json) The shared native result example includes per-track observations and signed sample clocks. [Session manifest schema](schema/transcript-session-v1.schema.json) · [Native result schema](schema/transcript-result-v1.schema.json) · [Native result example](../Tests/Integration/fixtures/transcripts/session-result-v1.json)

```sh
MPCUT_TEST_TRANSCRIBERRR_HELPER="$helper" swift test --filter TranscriptJobRunnerTests
MPCUT_TEST_TRANSCRIPT_CLI="$cli" MPCUT_TEST_TRANSCRIBERRR_HELPER="$helper" \
    swift test --filter TranscriptExternalCacheTests
python3 Tests/Integration/transcript_fixture_session.py /tmp/mpcut-spoken --helper "$helper"
swift Tests/Integration/transcript_gui.swift "$app" --transcribe /tmp/mpcut-spoken "$helper"
for engine in apple-native parakeet-v3 qwen3; do
  MPCUT_GUI_TEST_ENGINE="$engine" swift Tests/Integration/transcript_gui.swift "$app" --reconcile /tmp/mpcut-spoken "$helper" || break
done
```

## Native audition and edit review

Run `swift test --filter TranscriptAuditionTests` to check source stream selection and the bounded playback range. In the native window, select dialogue in Source before the synchronized group starts, or on a recording that is off-air. The Source Context window should show the selected file and source time while the transcript selection stays in place. Play Context should stop at its displayed source range end. Close the context window during playback and confirm audio stops. Repeat with live MCP `transcript_editor_occurrence_seek` in Source, and with Play Context in Current Cut.

Select a phrase whose endpoints have different camera coverage. In Switch Angle at Dialogue, change Word Edge and check the listed cameras and source times. Review a switch in a group with repeated ranges and check the affected occurrence numbers and times. For a deletion with overlapping dialogue from another attachment, confirm that the speech listed for removal carries the attachment name and Current Cut time. Dismiss an edit options sheet immediately after starting review and verify that no Apply sheet opens.

After replacing source audio in a sequence, open Rebind Transcript and check that the original recording and the replacement each offer their own audio streams. Choose the original stream and verify Source Context opens the original recording.

## November 22 audit: a participant without a microphone, word edges, and editor responsiveness

Five generated shoots check what the tuned fixtures could not. In each, three macOS voices hold a conversation of about a minute. Host and Guest wear lavs. A producer speaks from behind the cameras and is heard only on the two camera mixes, at spill level on both lavs, in pauses and over the Host or Guest. The four sources use different sample rates and signed offsets. Utterance bounds come from the generator, so word error, speaker attribution and utterance edges are scored without reference to any recognizer. The repository ships the first shoot's generator; the other four change the voices, script, microphone levels and overlaps.

Each row is one complete run: MPCut prepares the session, Transcriberrr recognizes and reconciles it, and MPCut imports the result by job ID. "Before" is the tree and helper as they stood at the start of the audit. The reconciliation rules were adjusted with the first four shoots in view. The fifth was generated after the last change and never used for tuning.

| Shoot, engine | Word error rate, before → after | Wrong speaker, before → after | Speakers found |
|---|---:|---:|---:|
| First, Qwen3 | 10.8% → 0.0% | 15 → 0 | 2 → 3 |
| First, Parakeet | 11.5% → 2.3% | 14 → 0 | 2 → 3 |
| First, Apple | 17.7% → 0.8% | 13 → 0 | 2 → 3 |
| Fourth, Qwen3 | 26.3% → 5.1% | 27 → 0 | 3 → 3 |
| Fourth, Parakeet | 27.7% → 8.0% | 27 → 0 | 3 → 3 |
| Fourth, Apple | 32.1% → 10.2% | 31 → 0 | 3 → 3 |
| Fifth (held out), Qwen3 | 31.8% → 11.3% | 30 → 1 | 3 → 3 |
| Fifth (held out), Parakeet | 31.8% → 12.6% | 37 → 7 | 3 → 3 |
| Fifth (held out), Apple | 31.1% → 14.6% | 38 → 3 | 3 → 3 |

Before, both lavs claimed the producer's sentences for their wearers and the conversation repeated them under two names. The session now compares each microphone's level with the balance its wearer's own speech keeps against the same camera mix, follows a phrase from a pause into speech a wearer talks over, and attaches another recording's different reading of a wearer's words to those words as an alternate. Digits and spelled-out numbers, and a compound and its two parts, count as one reading. What remains on the held-out shoot is mostly recognition: digits where the script has words, which the scorer counts as substitutions, and a producer's line that no track decoded. Its wrong names are the producer's two lines spoken entirely over a wearer. Such a line is placed when one of its words falls in a dip of every microphone, or when the camera is at least twice as loud as the wearer accounts for through three words; otherwise it keeps the label the camera's diarizer gave it, and Parakeet puts "The light just flickered behind you." under the Guest. Telling that sentence from a camera's garbled reading of the wearer by its words alone was tried and rejected: on the twelve stored runs it would have renamed 31 correctly named words and placed none. On the third shoot both lav voices are hard to recognize and the recordings disagree by whole phrases; Qwen3 ends at 25.9% and Apple at 39.3% from 49.6% and 69.6%.

These rows mark the two lavs as isolated microphones with speaker names, in the Role menu of the transcription sheet or in `track_options`. With every track left at Unknown, the default, no microphone is known to have a wearer and the producer's words still go to the Host or Guest.

Parakeet Unified stamps a word about 0.28 s after its onset and gives it one or two 80 ms frames. Deleting the Host's sentence "Could you say that again a little slower?" by its words left the first 346 ms of the sentence in the program. With corrected onsets and spoken durations it leaves 67 ms, and utterance start and end error on the first shoot fall from 386 and 148 ms to 104 and 67 ms. The Qwen3 edit removes the sentence cleanly, 33 ms into the preceding pause. On the two AMI meeting excerpts, recognized again with Parakeet, paired word-edge error fell from 227.5 to 82.8 ms and from 247.8 to 63.4 ms. Batch output for a single file and for per-speaker tracks keeps the same words across a 120-second chunk boundary. Apple's word times showed no steady offset on the meeting audio and were left as recognized.

On the stored recognition of both meetings, where every participant wears a headset, matched words and overlapping matches are unchanged, and Qwen3 emits three and three fewer unmatched words. The synthetic interview passes all ten session checks with Parakeet and Qwen3 before and after. The five shoots are linear mixes from one generator, so the rules for a participant without a microphone were also replayed on real meeting audio with one headset removed at a time, which leaves that speaker on the room microphone alone. On 150 seconds of AMI meeting ES2008a, where all four participants speak (464 reference words, four removals), the removed speaker's words filed under another participant's name fell from 65 to 13 with Parakeet and from 151 to 34 with Qwen3. The other speakers' correctly named words went from 1,179 to 1,172 and from 1,122 to 1,121, and their wrongly named words from 0 to 0 and from 16 to 6. These figures rest on that one window; two more could not be fetched while the corpus mirror was refusing requests. On the two 15-second excerpts the counts do not move. In the Qwen3 cases examined, the headset that claims the removed speaker's words belongs to someone who says nothing in the excerpt, so there is no speech of the wearer's own to compare levels with.

### Extraction

| Input | Before | After |
|---|---:|---:|
| 44.1 kHz stream on a millisecond clock starting between two samples, 20 s: samples displaced | 1,503 | 0 |
| Stereo with one channel inverted: staged level, words recognized | silence, 0 | strongest channel, 30 |
| Stage four one-hour recorders and a camera: wall time, peak memory | 16.8 s, 497 MB | 3.8 s, 208 MB |
| Stage one hour of AAC: process CPU, peak memory | 2.41 s, 313 MB | 2.01 s, 99 MB |
| Stage audio to reconcile finished tracks after a camera offset change | every track again | none |
| Stereo with one channel inverted, transcribed in the app with the real helper | no words | 30 words attached |

The six interview recordings and the four sources of the first shoot stage to byte-identical WAV files before and after. Recognition and levels of a stream staged from one channel because its channels cancel are cached under that channel, so a result cached for the silent mix is not reused. A stalled helper that writes nothing and uses no processor time for thirty minutes is stopped and the job can be retried. At launch the app removes job folders and shared recognition results that nothing has written for thirty days. A finished result whose project still exists is kept, attached or not, because Reconcile reads it.

### Reading, searching and editing

Release builds on the three-hour multicam benchmark, medians of seven alternating runs of a fresh CLI process, on a machine under load:

| Operation | Before | After |
|---|---:|---:|
| `transcript words read` or `search`, process CPU | 0.95 s | 0.25 s |
| `transcript words correct`, process CPU | 1.22 s | 0.32 s |
| Peak memory, read or search | 515 MB | 281 MB |
| Decode a 15 MB stored result | 502 ms | 33 ms |
| Align four 100-word script beats against 28,800 words | 2,869 ms | 38 ms |

In the native window with a 28,800-word transcript, medians of three runs after and five before:

| Action | Before | After |
|---|---:|---:|
| Delete a matched passage until the reader shows the edit | 645 ms | 441 ms |
| Undo it | about 600 ms | 167 ms |
| Reader unavailable after the undo | 451 to 475 ms | 0 ms |
| Place after deleting the sixth of 120 matches, then undo | Match 1 of 119, 1 of 120 | Match 6 of 119, 7 of 120 |
| Main-thread stall when a job delivers a 24,000-word result | 359 to 655 ms | about 17 ms |
| Pane passes during four seconds of playback | 121, with 2,904 word rows | 16, with 32 word rows |

A recording's different reading of a spoken word ("first" where the conversation has "1st") arrives attached to that word. It is read once: in Source as that recording's own word under the speaker's name, and in Group and Current Cut as the conversation's word. Listed beside it as well, it had put 6 extra words in Group on the fifth shoot with Apple and 17 on the third, and a second "Speaker 0" for each camera in the speaker list. Search finds a compound written as one word or two, follows a phrase through crosstalk when one speaker label covers two people, and reads through a word a blade cut split. Speakers talking over each other export as whole lines. In Source, text and subtitle export gives one line per recording per utterance. Tests added with this audit fail on the earlier tree for: a protected pause tightened from another microphone's copy of the words, a correction across a join reaching the removed take, a corrected word blank on the other tracks in Source, SubRip styling and common timestamp spellings, a project renamed only in letter case, and a duplicate project losing its transcript when the renamed original is saved.

A search reads the numbers in the query and in the transcript by their value, so one engine's digits and another's words answer the same search. Number words, ordinal forms and the names of signs such as "$" and "%" come from the rule sets of ICU, the Unicode library in macOS, for the transcript's language; no language is written into MPCut. The language is the one the transcript declares, or else the one its words are written in. Tests cover English, German, Spanish, French, Russian and Japanese, and the reader was also run on Chinese, Hindi, Arabic, Italian, Portuguese, Dutch, Korean and Turkish. On the fifth shoot, matches in Group:

| Query | Qwen3 | Parakeet | Apple |
|---|---|---|---|
| `two hundred hours` | 0 → 2 | 0 → 2 | 0 → 2 |
| `first one` | 1 → 1 | 1 → 1 | 0 → 1 |
| `1st one` | 0 → 1 | 0 → 1 | 1 → 1 |
| `sixteen` | 1 → 1 | 0 → 1 | 0 → 1 |
| `16` | 0 → 1 | 1 → 1 | 1 → 1 |
| `three or four months` | 2 → 2 | 0 → 2 | 2 → 2 |
| `four and six thousand dollars` | 1 → 1 | 0 → 1 | 0 → 1 |

Parakeet wrote that last figure as the two words "6," and "000", and Apple as "$6,000". A plain phrase finds what it found before, in 0.04 ms on a 28,800-word transcript in a release build. With a third of that transcript's words in numbers, the first search that names a number takes 70 to 77 ms once in a process, while the language's rules are read, and 18 ms on each index built after that, while the transcript's numbers are read. Each later one takes 0.05 to 0.15 ms. The window runs a search off the main thread.

Transcriberrr's session reconciliation reads figures from the same ICU rules. It had its own English table: whole numbers below ten thousand, clock times, and the ordinals to 20th and the tens. A word written in digits is now read every way its language says it, and the words another recording has in its place are compared with those readings.

| One recording has | Another has | Before | After |
|---|---|---|---|
| `200`, `4:00`, `3rd`, `1,250` | two hundred, four, third, twelve fifty | one reading | one reading |
| `21st`, `12,500` | twenty-first, twelve thousand five hundred | two words | one reading |
| `$200`, `50%` | two hundred dollars, fifty percent | two words | one reading |
| German `250`, `3.`, `1.250` | zweihundertfünfzig, dritten, ein tausend zwei hundert fünfzig | two words | one reading |
| Spanish `1`, `1.250`, `3.ª` | una, mil doscientas cincuenta, tercera | two words | one reading |
| French `80`, `1er`, `200€` | quatre-vingts, premier, deux cents euros | two words | one reading |
| Russian `250`, `21` | двухсот пятидесяти, двадцать один | two words | one reading |
| `4:00` | four o'clock | one reading | "four" joins, "o'clock" stays a word |
| `1905` | nineteen o five | one reading | two words ("nineteen oh five" joins) |

The rows above the last two are tests that run `reconcile` on two recordings of one sentence. The last two are what was given up: ICU has no rule for "o'clock" or for "o" as a spelling of "oh". The fifteen stored shoots, all English, reconcile to the same words, speakers and observations as before. They hold `200`, `300.`, `4`, `4:00`, `12`, `16.`, `20`, `40`, `900`, `1st` and `$6,000`, and the old table already read those. The four stored meeting recordings were not replayed; their recognition files were no longer on disk. A full run on the fifth shoot through the installed helper gives Parakeet 12.6% with 7 wrong names, as before. The language is the session's declared one, or else the language of the words when there are 200 characters of them, or else English, which is the only language the batch recognizers transcribe. A session with no word in digits does none of this work.

Nearest Frame moves a boundary by up to half a frame. Deleting "garage" on the fifth shoot with Apple asked for 9.54 to 9.78 s and cut 9.52 to 9.76 s, which left 20 ms of the word in the program. Current Cut listed that remainder as a word and search found it. It now lists neither a remainder of half a frame or less nor finds it. The same holds in a sequence with picture, where the same delete left 20 ms and nine listed words and now leaves eight. The 20 ms of audio is still in the program. A word a blade went through continues in the next clip and is still listed.

| After deleting "garage" | Before | After |
|---|---:|---:|
| Search for "garage" in Current Cut | 1 match, 20 ms | 0 |
| Words in Current Cut | 128 → 128 | 128 → 127 |

```sh
python3 Tests/Integration/transcript_fixture_roundtable.py /tmp/mpcut-roundtable
python3 Tests/Integration/transcript_fixture_roundtable_session.py --fixture /tmp/mpcut-roundtable \
    --cli "$cli" --helper "$helper" --engine parakeet-v3 --out /tmp/mpcut-roundtable-parakeet
swift test --filter 'Transcript|ClipEditCSV'
MPCUT_TRANSCRIPT_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter 'TranscriptBenchmarkTests|testReopeningAStoredResultBenchmark'
```
