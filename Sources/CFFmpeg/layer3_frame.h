#pragma once
#include <libavcodec/packet.h>
#include <libavutil/adler32.h>
#include <libavutil/intreadwrite.h>

typedef struct {
    int samples, back_reference, main_bytes, reservoir_limit;
} Layer3Frame;

static inline int layer3_frame(const AVPacket *packet, int rate, Layer3Frame *frame) {
    static const int rates[] = {44100, 48000, 32000};
    static const int kbps[2][15] = {
        {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
        {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}
    };
    if (packet->size < 4) return 0;
    const uint8_t *data = packet->data;
    int version = (data[1] >> 3) & 3;
    int mpeg1 = version == 3;
    int rate_code = (data[2] >> 2) & 3, bit_rate = data[2] >> 4;
    if (data[0] != 255 || (data[1] & 0xe6) != 0xe2 || version == 1 || rate_code == 3 ||
        bit_rate == 0 || bit_rate == 15 || rate != rates[rate_code] / (mpeg1 ? 1 : version == 2 ? 2 : 4))
        return 0;
    int size = (mpeg1 ? 144000 : 72000) * kbps[mpeg1][bit_rate] / rate + ((data[2] >> 1) & 1);
    int mono = data[3] >> 6 == 3;
    int side_offset = 4 + ((data[1] & 1) ? 0 : 2);
    int side_size = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    if (size != packet->size || size < side_offset + side_size) return 0;
    frame->samples = mpeg1 ? 1152 : 576;
    frame->back_reference = mpeg1 ? AV_RB16(data + side_offset) >> 7 : data[side_offset];
    frame->main_bytes = size - side_offset - side_size;
    frame->reservoir_limit = mpeg1 ? 511 : 255;
    return 1;
}
