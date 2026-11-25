#pragma once

#include "PacketWriter.h"
#include <libavformat/avformat.h>

typedef struct MPCutEdge MPCutEdge;

/* Decode and encode only [from,to). Times are relative to origin_pts, the plan's
 * clock origin in the video time base: the first picture, or movie time zero.
 * Encoded packets have strictly increasing original presentation times in the video
 * time base. The muxer supplies the DTS slots and container framing. `sets` (NAL units with 4-byte lengths, or
 * none) are the H.264/HEVC parameter sets the source holds at decode_from, which its decoder is given first. */
MPCutEdge *mpcut_edge_open(const char *path, const AVStream *video, int64_t origin_pts, MPCutTime decode_from,
                           MPCutTime from, MPCutTime to, size_t expected_frames, const uint8_t *sets, int sets_size,
                           int64_t target_bit_rate, MPCutProgress progress, void *context,
                           double fraction, char *error, size_t capacity);
int mpcut_edge_next(MPCutEdge *edge, AVPacket *target);
void mpcut_edge_free(MPCutEdge *edge);
