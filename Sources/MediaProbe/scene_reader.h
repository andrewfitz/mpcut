#ifndef MPCUT_SCENE_READER_H
#define MPCUT_SCENE_READER_H

#include "MediaProbe.h"
#include <CoreVideo/CoreVideo.h>
#include <libavformat/avformat.h>

typedef int (*MPSceneSurfaceVisit)(void *context, CVPixelBufferRef surface, int64_t pts);

// Returns 1 after verifying a complete zero-origin MOV video clock, 0 to retry
// with the demuxer, or a negative error for cancellation.
int mp_scene_read_asset(const char *path, const AVStream *stream,
                        MPSceneSurfaceVisit visit, MPProbeCancelled cancelled, void *context);

#endif
