#ifndef MPCUT_CODEC_HEADER_H
#define MPCUT_CODEC_HEADER_H

#include <stdbool.h>
#include <libavformat/avformat.h>

bool mp_has_header_probe(enum AVCodecID codec);
bool mp_read_video_header(AVCodecParameters *params, const AVPacket *packet, bool *may_interlace,
                          int *multilayer);

static inline bool mp_hevc_multilayer_unit(const uint8_t *unit, size_t size)
{
    if (size < 2)
        return false;
    unsigned layer_id = ((unit[0] & 1) << 5) | (unit[1] >> 3);
    if (layer_id != 0)
        return true;
    unsigned type = (unit[0] >> 1) & 63;
    if (type != 32 || size < 4)
        return false;
    unsigned vps_max_layers_minus1 = ((unit[2] & 3) << 4) | (unit[3] >> 4);
    return vps_max_layers_minus1 != 0;
}

#endif
