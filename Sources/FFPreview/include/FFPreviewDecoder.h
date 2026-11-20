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

MPPreviewDecoder *mp_preview_open(const char *path, bool video_only, MPPreviewCancelled cancelled,
                                 void *context, const char **error);
/* Before the first read, request native YUV surfaces for a Smart Trim encode.
 * The returned stream belongs to this decoder and includes its probed configuration. */
struct AVStream;
const struct AVStream *mp_preview_prepare_edge(MPPreviewDecoder *preview);
void mp_preview_coded_size(const MPPreviewDecoder *preview, int *width, int *height);
void mp_preview_close(MPPreviewDecoder *preview);
bool mp_preview_has_audio(const MPPreviewDecoder *preview);
bool mp_preview_has_unavailable_audio(const MPPreviewDecoder *preview);
bool mp_preview_seek(MPPreviewDecoder *preview, double seconds);
int mp_preview_next(MPPreviewDecoder *preview, CMSampleBufferRef *sample CF_RETURNS_RETAINED,
                    const char **error);
CGAffineTransform mp_preview_transform(const MPPreviewDecoder *preview);
