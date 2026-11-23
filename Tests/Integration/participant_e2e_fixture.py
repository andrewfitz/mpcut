"""Generate an annotated gallery and isolated microphones from public-domain primitives."""

from dataclasses import dataclass
from fractions import Fraction
import struct
import wave

from media_regression import ffmpeg, probe

WIDTH, HEIGHT = 320, 180
FPS = 8
FRAME_COUNT = 5 * FPS
RATE = 48_000
BACKGROUND = (24, 24, 24)
HOST = (207, 49, 42)
GUEST = (32, 178, 83)
STAGE = (54, 190, 31)
THUMB = (29, 151, 162)
CARD = (105, 110, 126)
GAP = (35, 47, 155)
COVER = (0, 0, 0)
PRORES = ("-vf", "scale=out_color_matrix=bt709", "-c:v", "prores_ks", "-profile:v", "standard",
          "-pix_fmt", "yuv422p10le", "-colorspace", "bt709", "-color_primaries", "bt709",
          "-color_trc", "bt709")

LEFT = (8, 30, 144, 120)
RIGHT = (168, 30, 144, 120)
STAGE_RECT = (8, 16, 200, 148)
UPPER = (224, 16, 88, 64)
LOWER = (224, 100, 88, 64)


@dataclass(frozen=True)
class Tile:
    participant: str
    appearance: str
    rect: tuple[int, int, int, int]
    color: tuple[int, int, int]
    role: str = "tile"
    camera_off: bool = False


def tiles_at(frame):
    if frame < FPS:
        return (Tile("host", "host-left", LEFT, HOST), Tile("guest", "guest-right", RIGHT, GUEST))
    if frame < 2 * FPS:
        return (Tile("guest", "guest-left", LEFT, GUEST), Tile("host", "host-right", RIGHT, HOST))
    if frame < 3 * FPS:
        return (
            Tile("guest", "guest-stage", STAGE_RECT, STAGE, "stage"),
            Tile("host", "host-upper", UPPER, HOST),
            Tile("guest", "guest-thumb", LOWER, THUMB, "thumbnail"),
        )
    if frame == 27:
        return (Tile("host", "host-left", LEFT, HOST), Tile("guest", "guest-flash", RIGHT, GUEST))
    if frame >= 4 * FPS:
        return (Tile("guest", "guest-return", LEFT, GUEST), Tile("host", "host-right", RIGHT, HOST))
    if 30 <= frame < 32:
        return (Tile("host", "host-left", LEFT, HOST), Tile("guest", "guest-card", RIGHT, CARD, camera_off=True))
    return (Tile("host", "host-left", LEFT, HOST),)


def paint(image, rect, color):
    x, y, width, height = rect
    row = bytes(color) * width
    for line in range(y, y + height):
        start = 3 * (line * WIDTH + x)
        image[start:start + len(row)] = row


def gallery_frame(frame):
    image = bytearray(bytes(BACKGROUND) * (WIDTH * HEIGHT))
    for tile in tiles_at(frame):
        x, y, width, height = tile.rect
        paint(image, tile.rect, tile.color)
        # A bright nameplate on every guest appearance gives privacy tests a
        # second region to inspect after encoding, including in the thumbnail.
        if tile.participant == "guest":
            paint(image, (x + 4, y + height - 16, min(width - 8, 48), 12), (235, 230, 204))
    return image


def write_mic(path, duration, impulses):
    signal = bytearray(2 * int(duration * RATE))
    for position, amplitude in impulses:
        struct.pack_into("<h", signal, 2 * int(position * RATE), amplitude)
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", ""))
        audio.writeframes(signal)
    return path


def generate(directory):
    raw = directory / "gallery.rgb"
    raw.write_bytes(b"".join(map(gallery_frame, range(FRAME_COUNT))))
    mix = write_mic(directory / "mix.wav", 5, [(Fraction(1, 4), 19_000), (Fraction(9, 4), 12_000), (Fraction(17, 4), -21_000)])
    gallery = directory / "gallery.mov"
    ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{WIDTH}x{HEIGHT}",
           "-framerate", str(FPS), "-i", raw, "-i", mix, *PRORES, "-c:a", "pcm_s16le", gallery)
    raw.unlink()

    iso_offset = Fraction(5, 4)
    iso_duration = Fraction(5) - iso_offset
    # Stream 0 is an intentionally wrong channel. Stream 1 has distinctive
    # cues during the guest's stage view and visual absence.
    decoy = write_mic(directory / "decoy.wav", iso_duration, [(Fraction(1, 8), 29_000)])
    iso = write_mic(directory / "iso-reference.wav", iso_duration,
                    [(Fraction(1), 26_000), (Fraction(5, 2), -25_000)])
    recorder = directory / "recorder.mov"
    ffmpeg("-i", decoy, "-i", iso, "-map", "0:a:0", "-map", "1:a:0", "-c:a", "pcm_s16le", recorder)
    return gallery, recorder, iso_offset


def generate_camera(path, color, duration):
    frame = bytes(color) * (WIDTH * HEIGHT)
    ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{WIDTH}x{HEIGHT}",
           "-framerate", str(FPS), "-i", "-", *PRORES, path, input=frame * (duration * FPS))
    return path


def video(path):
    stream, = probe(path, "-select_streams", "v:0", "-show_streams")["streams"]
    raw = ffmpeg("-i", path, "-map", "0:v:0", "-an", "-fps_mode", "passthrough",
                 "-pix_fmt", "rgb24", "-f", "rawvideo", "-")
    size = 3 * stream["width"] * stream["height"]
    if len(raw) % size:
        raise AssertionError(f"{path.name} decoded to an incomplete RGB frame")
    return stream, [raw[start:start + size] for start in range(0, len(raw), size)]


def frame_times(path, stream):
    frames = probe(path, "-select_streams", "v:0", "-show_frames",
                   "-show_entries", "frame=best_effort_timestamp")["frames"]
    time_base = Fraction(stream["time_base"])
    return [int(frame["best_effort_timestamp"]) * time_base for frame in frames]


def pixel(frame, width, x, y):
    start = 3 * (y * width + x)
    return tuple(frame[start:start + 3])


def sound(path, track=0):
    return ffmpeg("-i", path, "-map", f"0:a:{track}", "-c:a", "pcm_s16le", "-f", "s16le", "-")
