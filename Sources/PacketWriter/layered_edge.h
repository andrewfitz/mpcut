#ifndef MPCUT_LAYERED_EDGE_H
#define MPCUT_LAYERED_EDGE_H

#include <stdbool.h>
#include <stdint.h>

#include <libavformat/avformat.h>

/* Smart Trim edges of HEVC with more than one layer, which FFmpeg's decoder and encoder do not keep: an alpha layer
 * (HEVC with alpha) or a second view (MV-HEVC spatial video). AVFoundation decodes every layer of the edge, from
 * the keyframe before it, and VideoToolbox encodes them again into one picture of the same kind: alpha with the
 * source's alpha mode, or both views with the source's layer IDs and eye assignment. */

/* 1 when the edge encoder keeps every layer of this picture (HEVC with alpha, MV-HEVC with two views), else 0. */
int mpcut_layered_edge_supported(const AVCodecParameters *codec);

/* Receives each encoded picture in presentation order: Annex B NAL units, with every parameter set of every layer
 * before a keyframe's picture. `pts` is in the video time base, on the plan's clock. Nonzero stops the encode. */
typedef int (*MPCutLayeredPicture)(void *context, const uint8_t *data, int size, int key, int64_t pts);
typedef bool (*MPCutLayeredCancelled)(void *context);

/* Encode the pictures presented in [first, end) (video time base ticks on the plan's clock, which is `offset` ticks
 * after the movie's own) of `video`, the FFmpeg stream of the movie at `path`, at `bit_rate`. Returns 0, or a
 * negative AVERROR with *message set to a sentence. */
int mpcut_layered_edge_encode(const char *path, const AVStream *video, int64_t offset, int64_t first, int64_t end,
                              int64_t bit_rate, MPCutLayeredPicture picture, void *context,
                              MPCutLayeredCancelled cancelled, void *cancel_context, const char **message);

#endif
