#ifndef MPCUT_AAC_BRIDGE_H
#define MPCUT_AAC_BRIDGE_H

#include "PacketWriter.h"

#include <libavcodec/packet.h>
#include <libavutil/rational.h>

enum { MPCUT_AAC_FRAME = 1024 };

/* The encoded frames of a planned bridge, in order. Frame `trimmed` carries the trim as end-discard side data.
 * Their timestamps are left for the writer to set. Returns 0, or 1 with a sentence in error. */
typedef struct {
    AVPacket **packets;
    int count;
    int trimmed;
    int trim;
} MPCutAACBridgeFrames;

int mpcut_build_aac_bridge(const MPCutAACBridge *bridge, MPCutAACBridgeFrames *frames, char *error, size_t capacity);
void mpcut_aac_bridge_frames_free(MPCutAACBridgeFrames *frames);

/* A packet's frame start on its source's sample clock, snapped to the frame grid. INT64_MIN when it has no time. */
int64_t mpcut_aac_bridge_position(int64_t pts, AVRational time_base, MPCutTime origin, int sample_rate, int64_t grid);

#endif
