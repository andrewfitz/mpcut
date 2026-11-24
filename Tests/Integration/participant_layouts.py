#!/usr/bin/env python3
"""Check participant shot layout and blur against decoded movie pixels."""

import argparse
from fractions import Fraction
from pathlib import Path
import unittest

import participant_e2e as participant
from participant_e2e import ParticipantFixtureCase, bounds, color, geometry, interval, plan, slot
from participant_e2e_fixture import (
    BACKGROUND, CARD, FPS, GAP, GUEST, HEIGHT, HOST, LOWER, STAGE, STAGE_RECT, THUMB, WIDTH, pixel, tiles_at,
)

LABEL = (235, 230, 204)
SLOT_BACKGROUND = (149, 40, 145)


def label_rect(tile):
    x, y, width, height = tile.rect
    return (x + 4, y + height - 16, min(width - 8, 48), 12)


def sample(frame, width, rect):
    x, y, w, h = rect
    return pixel(frame, width, x + w // 2, y + h // 2)


class ParticipantLayouts(ParticipantFixtureCase):
    def test_grid_slot_order_horizontal_anchors_and_camera_off(self):
        source = geometry()
        source["appearances"].append({
            "id": "presentation", "range": interval(0, 5), "bounds": bounds((0, 0, WIDTH, 8)),
            "role": "presentation", "state": "presentation",
        })
        project = self.approved(self.base(), edited_geometry=source)
        size = (180, 220)
        left = dict(slot("guest", include_card=True), anchor_x=0)
        right = dict(slot("guest"), anchor_x=1, background=color(SLOT_BACKGROUND))
        host = dict(slot("host", framing="fit"), background=color(SLOT_BACKGROUND))
        choices = plan("grid", left, right, host, slot("presentation", target="presentation"), size=size)
        output, _ = self.export(project, "grid", choices)
        frames = self.decode(output, size=size)

        # The same left-side nameplate survives a left anchor and is cut by a right anchor.
        # The guest moves between sides in the gallery, but their rendered slots stay fixed.
        for index in (0, 8, 32):
            frame = frames[index]
            self.assert_color(frame, size[0], 12, 100, LABEL, f"left anchor frame {index}")
            self.assert_color(frame, size[0], 102, 100, GUEST, f"right anchor frame {index}")
            self.assert_color(frame, size[0], 45, 165, HOST, f"host lower left frame {index}")
            self.assert_color(frame, size[0], 45, 116, SLOT_BACKGROUND, f"host fit margin frame {index}")
            self.assert_color(frame, size[0], 135, 165, BACKGROUND, f"presentation lower right frame {index}")

        for index in (30, 31):
            frame = frames[index]
            self.assert_color(frame, size[0], 45, 55, CARD, f"retained camera card frame {index}")
            self.assert_color(frame, size[0], 135, 55, SLOT_BACKGROUND, f"replaced camera card frame {index}")
        self.assert_color(frames[24], size[0], 45, 55, GAP, "absent participant holds the upper-left grid slot")

    def test_flow_compacts_confirmed_absence_only(self):
        source = geometry()
        source["coverage"] = [
            {"range": interval(0, 3), "state": "verified"},
            {"range": interval(3, Fraction(25, FPS)), "state": "inferred"},
            {"range": interval(Fraction(25, FPS), 5), "state": "verified"},
        ]
        project = self.approved(self.base(), edited_geometry=source)
        size = (320, 180)
        guest = slot("guest", include_card=True)
        host = dict(slot("host", framing="fit"), background=color(SLOT_BACKGROUND))
        choices = plan("flow", guest, host, size=size)
        choices["shots"][0]["compact"] = True
        output, _ = self.export(project, "flow", choices)
        frames = self.decode(output, size=size)

        for index, expected in ((0, GUEST), (8, GUEST), (16, STAGE), (27, GUEST), (30, CARD), (32, GUEST)):
            self.assert_color(frames[index], size[0], 80, 90, expected, f"guest stays first at frame {index}")
            self.assert_color(frames[index], size[0], 240, 90, HOST, f"host stays second at frame {index}")
        self.assert_color(frames[24], size[0], 80, 90, GAP, "inferred absence keeps the original position")
        self.assert_color(frames[24], size[0], 240, 90, HOST, "host remains in second slot during inferred absence")
        self.assert_color(frames[25], size[0], 160, 90, HOST, "confirmed absence grows the host to a solo layout")
        self.assert_color(frames[25], size[0], 20, 90, SLOT_BACKGROUND, "the surviving slot keeps its own color")

    def test_fit_fill_vertical_anchor_and_slot_color_in_reordered_occurrences(self):
        base = self.base(assembly=[interval(1, 2), interval(0, 1), interval(1, 2)])
        project = self.approved(base)
        size = (320, 90)
        fit = dict(slot("guest", framing="fit"), background=color(SLOT_BACKGROUND))
        upper = dict(slot("guest"), anchor_y=0)
        lower = dict(slot("guest"), anchor_y=1)
        choices = plan("pair", fit, upper, size=size)
        choices["shots"].append({
            "layout": "pair", "slots": [lower, fit], "range": interval(1, 2), "occurrence": 1,
        })
        output, _ = self.export(project, "reordered", choices)
        frames = self.decode(output, size=size, frame_count=3 * FPS)

        for index in (0, 7, 16, 23):
            frame = frames[index]
            self.assert_color(frame, size[0], 8, 45, SLOT_BACKGROUND, f"fit margin follows left slot {index}")
            self.assert_color(frame, size[0], 80, 45, GUEST, f"fit retains the picture {index}")
            self.assert_color(frame, size[0], 186, 78, GUEST, f"top-anchored fill omits the nameplate {index}")
        for index in (8, 15):
            frame = frames[index]
            self.assert_color(frame, size[0], 26, 78, LABEL, f"bottom-anchored fill retains the nameplate {index}")
            self.assert_color(frame, size[0], 168, 45, SLOT_BACKGROUND, f"fit margin follows right slot {index}")
            self.assert_color(frame, size[0], 240, 45, GUEST, f"fit remains in the correct occurrence {index}")

    def test_blur_changes_stage_thumbnail_and_their_nameplates(self):
        source = geometry()
        labels = {tile.appearance: label_rect(tile) for tile in tiles_at(16) if tile.participant == "guest"}
        for appearance in source["appearances"]:
            prefix = appearance["id"].rsplit("-", 1)[0]
            if prefix in labels:
                appearance["label_bounds"] = bounds(labels[prefix])
        project = self.approved(self.base(), edited_geometry=source)
        size = (WIDTH, HEIGHT)
        clean_output, _ = self.export(project, "clean", plan("original", size=size))
        masked_output, _ = self.export(project, "blur", plan(
            "original", size=size, redactions=[{"participant_id": "guest", "treatment": "blur"}],
        ))
        clean = self.decode(clean_output, size=size)
        masked = self.decode(masked_output, size=size)
        for index in (16, 20, 23):
            for rect, expected, role in ((STAGE_RECT, STAGE, "stage"), (LOWER, THUMB, "thumbnail")):
                x, y, width, height = rect
                label = (x + 4, y + height - 16, 48, 12)
                clear_label = sample(clean[index], WIDTH, label)
                blurred_label = sample(masked[index], WIDTH, label)
                self.assertLessEqual(max(abs(a - b) for a, b in zip(clear_label, LABEL)), 22)
                self.assertGreater(max(abs(a - b) for a, b in zip(clear_label, blurred_label)), 32,
                                   f"{role} nameplate remains readable at frame {index}")
                # Just above the nameplate, blur changes the adjacent picture while
                # the broad tile color and the other participant stay recognizable.
                at = (x + 20, y + height - 20)
                clear_picture = pixel(clean[index], WIDTH, *at)
                blurred_picture = pixel(masked[index], WIDTH, *at)
                self.assertGreater(max(abs(a - b) for a, b in zip(clear_picture, blurred_picture)), 20,
                                   f"{role} picture failed to blur at frame {index}")
                self.assert_color(masked[index], WIDTH, x + width // 2, y + height // 3, expected, role)
            self.assert_color(masked[index], WIDTH, 268, 48, HOST, f"unmasked host frame {index}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mpcut", type=Path)
    options, tests = parser.parse_known_args()
    participant.CLI = options.mpcut.resolve(strict=True)
    unittest.main(argv=[__file__, *tests])
