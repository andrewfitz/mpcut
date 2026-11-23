#!/usr/bin/env python3
"""Check word scoring on unrelated repetitions and overlapping lines."""

import unittest
from copy import deepcopy

from transcript_fixture import RATE, SCRIPT, TRACKS, samples
from transcript_fixture_ami import score as score_ami
from transcript_fixture_baseline import edit_counts, report_track
from transcript_fixture_roundtable_session import score as score_roundtable
from transcript_fixture_session import evaluate


def phrase(label, speaker, words):
    timed = [{"text": text, "start": round(start * RATE), "end": round(end * RATE)}
             for text, start, end in words]
    return {"id": label, "speaker": speaker, "start": timed[0]["start"],
            "end": timed[-1]["end"], "words": timed}


def transcript(*words):
    return {"segments": [{"words": [
        {"text": text, "start": start, "end": end, "speaker": speaker}
        for text, start, end, speaker in words
    ]}]}


class TranscriptFixtureScoringTests(unittest.TestCase):
    def test_true_repetition_and_spurious_extra_word(self):
        reference = [phrase("request", "Operator", (
            ("try", 1, 1.3), ("try", 1.35, 1.65), ("again", 1.75, 2),
        ))]
        actual = [("try", 1, 1.3, 7), ("try", 1.35, 1.65, 7), ("again", 1.75, 2, 7)]
        valid = report_track(transcript(*actual), reference)
        self.assertEqual(valid["wordErrorRate"], 0)
        self.assertEqual(valid["repeatedReferenceWords"], 0)

        doubled = report_track(transcript(*actual[:2], ("try", 1.69, 1.72, 8), actual[-1]), reference)
        self.assertEqual(doubled["matchedWords"], 3)
        self.assertEqual(doubled["insertions"], 1)
        self.assertEqual(doubled["repeatedReferenceWords"], 1)
        self.assertAlmostEqual(doubled["wordErrorRate"], 1 / 3, places=3)

    def test_overlapping_speakers_reuse_common_word(self):
        reference = [
            phrase("one", "Driver", (("hold", .2, .4), ("the", .4, .5), ("door", .5, .9))),
            phrase("two", "Caller", (("the", .55, .65), ("bell", .65, .85), ("rings", .85, 1))),
        ]
        actual = transcript(("hold", .2, .4, 3), ("the", .4, .5, 3), ("door", .5, .9, 3),
                            ("the", .55, .65, 4), ("bell", .65, .85, 4), ("rings", .85, 1, 4))
        result = report_track(actual, reference)
        self.assertEqual(result["matchedWords"], 6)
        self.assertEqual(result["repeatedReferenceWords"], 0)
        self.assertEqual(result["speakerMistakes"], 0)

    def test_error_rate_distinguishes_edit_kinds(self):
        self.assertEqual(edit_counts(["open", "now"], ["open", "now", "please"]), (0, 0, 1))
        self.assertEqual(edit_counts(["open", "now"], ["open"]), (0, 1, 0))
        self.assertEqual(edit_counts(["open", "now"], ["open", "soon"]), (1, 0, 0))


def labeled_session():
    tracks = [
        {"id": name, "source_id": name,
         "session_start": {"numerator": samples(track["offset"]), "denominator": RATE},
         "words": [], "activity": []}
        for name, track in TRACKS.items()
    ]
    speech, words = [], []
    for label, speaker, onset, line, gains in SCRIPT:
        start = float(onset)
        reference = phrase(label, speaker, [(text, start + i / 10, start + (i + 1) / 10)
                                             for i, text in enumerate(line.split())])
        speech.append(reference)
        for expected in reference["words"]:
            result = {"text": expected["text"], "start_sample": expected["start"],
                      "end_sample": expected["end"], "speaker_id": speaker, "observations": []}
            for track in tracks:
                name = track["id"]
                if name not in gains:
                    continue
                offset = samples(TRACKS[name]["offset"])
                local = {"id": str(len(track["words"])), "text": expected["text"],
                         "start_sample": expected["start"] - offset, "end_sample": expected["end"] - offset}
                track["words"].append(local)
                result["observations"].append({**local, "word_id": local["id"],
                                               "track_id": name, "evidence": "recognized"})
            words.append(result)
    close = next(track for track in tracks if track["id"] == "close")
    close["activity"].append({"start_sample": 8800, "end_sample": 9120, "level": .25})
    truth = {"phrases": speech, "tracks": TRACKS,
             "nonSpeech": [{"start": samples("1.55"), "end": samples("1.75")}]}
    return {"tracks": tracks, "words": words}, truth


class TranscriptSessionScoringTests(unittest.TestCase):
    def test_unrelated_insertions_fail_even_with_complete_recall(self):
        document, truth = labeled_session()
        self.assertTrue(all(evaluate(document, truth)["checks"].values()))
        document["words"].extend({"text": "unrelated", "start_sample": 290000 + i * 16,
                                  "end_sample": 290008 + i * 16, "observations": []} for i in range(100))
        report = evaluate(document, truth)
        self.assertEqual(report["matchedWords"], 38)
        self.assertEqual(report["insertions"], 100)
        self.assertFalse(report["checks"]["wordErrorRateAndInsertions"])

    def test_bad_off_air_evidence_fails_despite_correct_conversation(self):
        document, truth = labeled_session()
        for key, value in (("text", "map"), ("start_sample", 215000), ("end_sample", 250000),
                           ("track_id", "wide")):
            with self.subTest(key=key):
                modified = deepcopy(document)
                word = next(word for word in modified["words"] if word["text"] == "compass")
                observation = word["observations"][0]
                observation[key] = value
                if key != "track_id":
                    close = next(track for track in modified["tracks"] if track["id"] == "close")
                    next(local for local in close["words"] if local["id"] == observation["word_id"])[key] = value
                report = evaluate(modified, truth)
                self.assertEqual(report["phrases"]["off-air"]["matchedWords"], 5)
                self.assertFalse(report["checks"]["offAir"])

        compass = next(word for word in document["words"] if word["text"] == "compass")
        upside = next(word for word in document["words"] if word["text"] == "upside")
        compass["observations"].append({**compass["observations"][0], "track_id": "wide"})
        self.assertFalse(evaluate(document, truth)["checks"]["offAir"])
        compass["observations"].pop()
        compass["observations"], upside["observations"] = upside["observations"], compass["observations"]
        self.assertFalse(evaluate(document, truth)["checks"]["offAir"])

    def test_ami_duplicate_candidates_need_unique_label_and_close_overlap(self):
        reference = [
            {"text": "pause", "start": 1000, "end": 2200, "speaker": "A"},
            {"text": "again", "start": 8000, "end": 9500, "speaker": "A"},
            {"text": "again", "start": 12000, "end": 13500, "speaker": "B"},
        ]
        emitted = [
            {"text": word["text"], "start_sample": word["start"], "end_sample": word["end"]}
            for word in reference
        ]
        emitted.extend([
            {"text": "pause", "start_sample": 1100, "end_sample": 2400},
            {"text": "again", "start_sample": 8050, "end_sample": 9650},
        ])
        score = score_ami(emitted, reference)
        self.assertEqual(score["matched"], 3)
        self.assertEqual(score["duplicateCandidates"], 2)
        self.assertEqual(score["labelSupportedDuplicates"], 1)

    def test_named_overlap_scores_simultaneous_words_on_their_own_speaker_lanes(self):
        reference = [{"text": "yes", "speaker": who, "start": 0, "end": 4000} for who in ("A", "B")]
        words = [{"text": "yes", "speaker_id": who, "start_sample": 0, "end_sample": 4000}
                 for who in ("b", "a")]
        names = {"a": "A", "b": "B"}
        score = score_ami(words, reference, speaker_names=names)
        self.assertEqual(score["overlapMatchedWithCorrectSpeaker"], 2)
        self.assertEqual(score["namedSpeakerWrongOrUnknown"], 0)
        words[1]["speaker_id"] = "b"
        score = score_ami(words, reference, speaker_names=names)
        self.assertEqual(score["overlapMatched"], 2)
        self.assertEqual(score["overlapMatchedWithCorrectSpeaker"], 1)
        self.assertEqual(score["namedSpeakerWrongOrUnknown"], 1)

    def test_ami_repeated_words_use_the_minimum_timing_error(self):
        reference = [{"text": "yes", "speaker": "A", "start": at, "end": at + 160}
                     for at in (0, 4800)]
        words = [{"text": "yes", "start_sample": at, "end_sample": at + 160}
                 for at in (480, 960)]
        score = score_ami(words, reference)
        self.assertEqual(score["matched"], 2)
        self.assertEqual(score["meanEdgeErrorMS"], 135)

    def test_roundtable_maximizes_speaker_matches_and_counts_unknown_words(self):
        utterances, words = [], []
        for index, (name, label, count) in enumerate([
            ("Host", "x", 10), ("Guest", "x", 9), ("Host", "y", 8), ("Guest", None, 1),
        ]):
            start = index * 20
            utterances.append({"id": str(index), "speaker": name, "start": start, "end": start + count,
                               "text": " ".join(["yes"] * count), "overlaps": False})
            words.extend({"text": "yes", "speaker_id": label, "start_sample": (start + i) * RATE,
                          "end_sample": (start + i + 1) * RATE, "observations": []} for i in range(count))
        score = score_roundtable({"sample_rate": RATE, "speakers": [], "tracks": [], "words": words},
                                 {"utterances": utterances})
        self.assertEqual(score["wer"], 0)
        self.assertEqual(score["speakerMap"], {"x": "Guest", "y": "Host"})
        self.assertEqual(score["speakerErrors"], 11)


if __name__ == "__main__":
    unittest.main()
