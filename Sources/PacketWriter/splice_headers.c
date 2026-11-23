#include "splice_headers.h"
#include <libavcodec/bsf.h>
#include <libavutil/opt.h>
#include <limits.h>
#include <string.h>

/* Matroska stores AV1 as low-overhead OBUs. Sequence headers must precede
 * pictures that use them; an outer av1C record may supply the original one. */
static bool av1_sequence(const uint8_t *data, int size)
{
    int pos = 0;
    while (pos < size) {
        unsigned header = data[pos++];
        unsigned type = (header >> 3) & 15;
        if (header & 0x81 || (header & 4 && ++pos > size))
            return false;
        uint64_t length = 0;
        if (header & 2) {
            unsigned byte;
            unsigned shift = 0;
            do {
                if (pos >= size || shift >= 56)
                    return false;
                byte = data[pos++];
                length |= (uint64_t)(byte & 127) << shift;
                shift += 7;
            } while (byte & 128);
        } else {
            length = size - pos;
        }
        if (length > (unsigned)(size - pos))
            return false;
        if (type == 1)
            return length > 0;
        if (type == 3 || type == 4 || type == 6 || type == 7)
            return false;
        pos += (int)length;
    }
    return false;
}

static int prepend(AVPacket *packet, const uint8_t *prefix, int size)
{
    if (!prefix || size <= 0 || packet->size > INT_MAX - size)
        return AVERROR_INVALIDDATA;
    int old_size = packet->size;
    int ret = av_grow_packet(packet, size);
    if (ret < 0)
        return ret;
    memmove(packet->data + size, packet->data, old_size);
    memcpy(packet->data, prefix, size);
    return 0;
}

int mpcut_splice_encoded(AVPacket *packet, const AVCodecParameters *source, bool first)
{
    if (first && !(packet->flags & AV_PKT_FLAG_KEY))
        return AVERROR_INVALIDDATA;
    if (source->codec_id == AV_CODEC_ID_AV1)
        return !first || av1_sequence(packet->data, packet->size) ? 0 : AVERROR_INVALIDDATA;
    if (!(packet->flags & AV_PKT_FLAG_KEY))
        return 0;

    /* libavformat's MOV muxer maps NEW_EXTRADATA to an stsd entry and starts
     * a new chunk at the configuration change. Its active Annex B extradata
     * also tells it to length-prefix the remaining picture NALs on write. */
    const AVBitStreamFilter *filter = av_bsf_get_by_name("extract_extradata");
    if (!filter)
        return AVERROR_BSF_NOT_FOUND;
    AVBSFContext *ctx = NULL;
    int ret = av_bsf_alloc(filter, &ctx);
    if (ret >= 0) {
        ctx->par_in->codec_type = AVMEDIA_TYPE_VIDEO;
        ctx->par_in->codec_id = source->codec_id;
        ret = av_opt_set_int(ctx->priv_data, "remove", 1, 0);
    }
    if (ret >= 0)
        ret = av_bsf_init(ctx);
    if (ret >= 0)
        ret = av_bsf_send_packet(ctx, packet);
    if (ret >= 0)
        ret = av_bsf_receive_packet(ctx, packet);
    if (ret >= 0 && (packet->size <= 0 ||
        (first && !av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, NULL))))
        ret = AVERROR_INVALIDDATA;
    av_bsf_free(&ctx);
    return ret;
}

/* avc3/hev1 permit parameter updates inside media samples. When the source
 * actually uses this feature, renaming it to avc1/hvc1 would publish an
 * incorrect track, and rewriting the retained packets would break stream copy. */
int mpcut_splice_check_copy(const AVPacket *packet, const AVCodecParameters *codec,
                            const uint8_t *extra, int extra_size)
{
    bool hevc = codec->codec_id == AV_CODEC_ID_HEVC;
    if ((!hevc || codec->codec_tag != MKTAG('h','e','v','1')) &&
        (codec->codec_id != AV_CODEC_ID_H264 || codec->codec_tag != MKTAG('a','v','c','3')))
        return 0;
    int offset = hevc ? 21 : 4;
    if (!extra || extra_size <= offset || extra[0] != 1)
        return AVERROR_INVALIDDATA;
    int width = (extra[offset] & 3) + 1;
    int pos = 0;
    while (pos < packet->size) {
        if (packet->size - pos < width)
            return AVERROR_INVALIDDATA;
        unsigned size = 0;
        for (int i = 0; i < width; i++)
            size = size << 8 | packet->data[pos++];
        if (size < (hevc ? 2U : 1U) || size > (unsigned)(packet->size - pos))
            return AVERROR_INVALIDDATA;
        int type = hevc ? packet->data[pos] >> 1 & 63 : packet->data[pos] & 31;
        if (hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8 || type == 13))
            return AVERROR(ENOTSUP);
        pos += (int)size;
    }
    return 0;
}

int mpcut_splice_restore(AVPacket *packet, const AVCodecParameters *codec,
                         const uint8_t *extra, int extra_size)
{
    if (!(packet->flags & AV_PKT_FLAG_KEY))
        return AVERROR_INVALIDDATA;
    if (codec->codec_id == AV_CODEC_ID_AV1) {
        if (av1_sequence(packet->data, packet->size))
            return 0;
        if (!extra)
            return AVERROR_INVALIDDATA;
        int offset = extra_size >= 4 && extra[0] == 0x81 ? 4 : 0;
        if (extra_size <= offset ||
            !av1_sequence(extra + offset, extra_size - offset))
            return AVERROR_INVALIDDATA;
        return prepend(packet, extra + offset, extra_size - offset);
    }
    /* The original packets are still length-prefixed. Re-select the original
     * sample description so seeking into either run finds the right decoder
     * configuration, without changing any bytes in the copied pictures. */
    if (!extra || extra_size <= 0 || extra[0] != 1)
        return AVERROR_INVALIDDATA;
    uint8_t *config = av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, extra_size);
    if (!config)
        return AVERROR(ENOMEM);
    memcpy(config, extra, extra_size);
    return 0;
}
