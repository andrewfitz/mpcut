#ifndef MPCUT_SPLICE_HEADERS_H
#define MPCUT_SPLICE_HEADERS_H

#include <libavformat/avformat.h>
#include <stdbool.h>

/* Switch the sample description for MOV, or the in-band AV1 sequence header
 * for WebM, at each transition between encoded and copied video. */
int mpcut_splice_encoded(AVPacket *packet, const AVCodecParameters *source, bool first);
int mpcut_splice_check_copy(const AVPacket *packet, const AVCodecParameters *source,
                            const uint8_t *extra, int extra_size);
int mpcut_splice_check_still_hdr(const AVPacket *packet, const uint8_t *extra, int extra_size);
int mpcut_splice_restore(AVPacket *packet, const AVCodecParameters *codec,
                         const uint8_t *extra, int extra_size);

#endif
