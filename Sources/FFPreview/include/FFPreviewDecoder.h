#pragma once

#include <CoreMedia/CoreMedia.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef struct MPPreviewDecoder MPPreviewDecoder;

enum MPPreviewResult {
    MPPreviewError = -1,
    MPPreviewEnd = 0,
    MPPreviewVideo = 1,
    MPPreviewAudio = 2,
    MPPreviewAgain = 3
};

typedef bool (*MPPreviewCancelled)(void *context);

enum MPPreviewTracks {
    MPPreviewPictureAndSound,
    MPPreviewPictureOnly,
    MPPreviewSoundOnly
};

/* A valid origin is the source presentation timestamp at timeline zero.
 * An audio ordinal of -1 uses the default for the source. */
MPPreviewDecoder *mp_preview_open(const char *path, enum MPPreviewTracks tracks, int audio_ordinal, CMTime origin,
                                 MPPreviewCancelled cancelled,
                                 void *context, const char **error);
/* Before the first read, request native YUV surfaces for a Smart Trim encode.
 * The returned stream belongs to this decoder and includes its probed configuration. */
struct AVStream;
const struct AVStream *mp_preview_prepare_edge(MPPreviewDecoder *preview);
void mp_preview_coded_size(const MPPreviewDecoder *preview, int *width, int *height);
void mp_preview_close(MPPreviewDecoder *preview);
/* Select picture-only scrubbing or A/V playback before the next seek. */
void mp_preview_enable_audio(MPPreviewDecoder *preview, bool enabled);
bool mp_preview_has_audio(const MPPreviewDecoder *preview);
bool mp_preview_has_unavailable_audio(const MPPreviewDecoder *preview);
/* Seconds count from the video track's first picture, whatever origin was given to mp_preview_open. */
bool mp_preview_seek(MPPreviewDecoder *preview, double seconds);
/* Seconds count from the origin of the presented sample times. The two differ
 * when an explicit origin precedes a picture track that starts late. */
bool mp_preview_seek_timeline(MPPreviewDecoder *preview, double seconds);
int mp_preview_next(MPPreviewDecoder *preview, CMSampleBufferRef *sample CF_RETURNS_RETAINED,
                    const char **error);
/* Whether the decoder rejected a picture since the last seek. A preview then resumes at the
 * next keyframe and omits the pictures in between. A Smart Trim edge returns the intact
 * pictures decoded before the damage and then reports an error. */
bool mp_preview_met_damage(const MPPreviewDecoder *preview);
/* For a Smart Trim edge that ended with a damage error: every picture returned before the
 * error was decoded from packets that precede the damaged one. */
bool mp_preview_edge_intact_before_damage(const MPPreviewDecoder *preview);
CGAffineTransform mp_preview_transform(const MPPreviewDecoder *preview);
