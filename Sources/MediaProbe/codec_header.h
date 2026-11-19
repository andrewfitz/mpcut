#ifndef MPCUT_CODEC_HEADER_H
#define MPCUT_CODEC_HEADER_H

#include <stdbool.h>
#include <libavformat/avformat.h>

bool mp_has_header_probe(enum AVCodecID codec);
bool mp_read_video_header(AVCodecParameters *params, const AVPacket *packet);

#endif
