#include "MediaProbe.h"
#include "../CFFmpeg/copy_probe.h"
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mastering_display_metadata.h>
#include <string.h>

static int64_t orientation(const uint32_t *a, const uint32_t *b, const uint32_t *c)
{
    return ((int64_t)b[0] - a[0]) * ((int64_t)c[1] - a[1]) -
           ((int64_t)b[1] - a[1]) * ((int64_t)c[0] - a[0]);
}

static void mastering(MPProbeHDR *result, const uint32_t values[10])
{
    if (result->has_mastering && memcmp(result->mastering, values, sizeof(result->mastering)))
        result->conflicting_mastering = 1;
    memcpy(result->mastering, values, sizeof(result->mastering));
    result->has_mastering = 1;
    for (int i = 0; i < 8; i += 2) {
        if (values[i] > 50000 || !values[i + 1] || values[i + 1] > 50000 - values[i]) {
            result->conflicting_mastering = 1;
            return;
        }
    }
    const uint32_t *g = values, *b = values + 2, *r = values + 4, *white = values + 6;
    int64_t gamut = orientation(g, b, r);
    if (!gamut || orientation(g, b, white) * gamut < 0 ||
        orientation(b, r, white) * gamut < 0 || orientation(r, g, white) * gamut < 0 ||
        !values[8] || values[8] > 100000000 || values[9] >= values[8])
        result->conflicting_mastering = 1;
}

static int normalized(AVRational value, int scale, uint32_t *result)
{
    if (value.num < 0 || value.den <= 0)
        return 0;
    int64_t n = (int64_t)value.num * scale;
    if (n % value.den || n / value.den > UINT32_MAX)
        return 0;
    *result = (uint32_t)(n / value.den);
    return 1;
}

static void side_mastering(MPProbeHDR *result, const uint8_t *data, size_t size)
{
    if (!data)
        return;
    AVMasteringDisplayMetadata m;
    uint32_t values[10];
    if (size < sizeof(m))
        goto invalid;
    memcpy(&m, data, sizeof(m));
    if (!m.has_primaries || !m.has_luminance)
        goto invalid;
    for (int i = 0; i < 6; i++) {
        // The container struct stores RGB. The elementary stream stores GBR.
        if (!normalized(m.display_primaries[(i / 2 + 1) % 3][i % 2], 50000, &values[i]))
            goto invalid;
    }
    if (!normalized(m.white_point[0], 50000, &values[6]) ||
        !normalized(m.white_point[1], 50000, &values[7]) ||
        !normalized(m.max_luminance, 10000, &values[8]) ||
        !normalized(m.min_luminance, 10000, &values[9]))
        goto invalid;
    mastering(result, values);
    return;
invalid:
    result->conflicting_mastering = 1;
}

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t pos;
    unsigned zeroes;
} RBSP;

static int byte(RBSP *rbsp)
{
    if (rbsp->pos == rbsp->size)
        return -1;
    int next = rbsp->data[rbsp->pos++];
    if (rbsp->zeroes == 2 && next == 3) {
        rbsp->zeroes = 0;
        if (rbsp->pos == rbsp->size)
            return -1;
        next = rbsp->data[rbsp->pos++];
    }
    rbsp->zeroes = next == 0 ? rbsp->zeroes + 1 : 0;
    return next;
}

static int extension_byte(RBSP *rbsp, size_t *value)
{
    *value = 0;
    int next;
    do {
        next = byte(rbsp);
        if (next < 0)
            return AVERROR_INVALIDDATA;
        *value += (unsigned)next;
    } while (next == 255);
    return 0;
}

static void message(MPProbeHDR *result, size_t type, const uint8_t *payload, size_t length)
{
    if (type == 4) {
        static const uint8_t hdr10plus[] = {0xb5, 0, 0x3c, 0, 1, 4};
        static const uint8_t dolby[] = {0xb5, 0, 0x3b, 0, 0, 8, 0};
        if (length >= sizeof(hdr10plus) && !memcmp(payload, hdr10plus, sizeof(hdr10plus)))
            result->hdr10plus = 1;
        if (length >= sizeof(dolby) && !memcmp(payload, dolby, sizeof(dolby)))
            result->dolby_vision = 1;
    }
    // A zero value is unspecified rather than a statistic about the pictures.
    if (type == 144 && (length != 4 || AV_RB32(payload)))
        result->inband_content_light = 1;
    if (type != 137)
        return;
    if (length != 24) {
        result->conflicting_mastering = 1;
        return;
    }
    uint32_t values[10];
    for (int i = 0; i < 8; i++)
        values[i] = AV_RB16(payload + i * 2);
    values[8] = AV_RB32(payload + 16);
    values[9] = AV_RB32(payload + 20);
    mastering(result, values);
}

static int nal(MPProbeHDR *result, int hevc, const uint8_t *data, size_t size)
{
    unsigned header = hevc ? 2 : 1;
    if (size < header)
        return AVERROR_INVALIDDATA;
    unsigned type = hevc ? (data[0] >> 1) & 63 : data[0] & 31;
    if (hevc && (type == 62 || type == 63))
        result->dolby_vision = 1;
    if (hevc && ((data[0] & 1) || (data[1] >> 3)))
        result->additional_layers = 1;
    if (hevc ? (type != 39 && type != 40) : type != 6)
        return 0;
    RBSP rbsp = {data + header, size - header, 0, 0};
    while (rbsp.pos < rbsp.size) {
        if (rbsp.data[rbsp.pos] == 0x80 && rbsp.pos + 1 == rbsp.size)
            break;
        size_t payload_type, length;
        if (extension_byte(&rbsp, &payload_type) < 0 || extension_byte(&rbsp, &length) < 0 ||
            length > rbsp.size - rbsp.pos)
            return AVERROR_INVALIDDATA;
        uint8_t prefix[24];
        for (size_t i = 0; i < length; i++) {
            int value = byte(&rbsp);
            if (value < 0)
                return AVERROR_INVALIDDATA;
            if (i < sizeof(prefix))
                prefix[i] = value;
        }
        message(result, payload_type, prefix, length);
    }
    return 0;
}

static int annex_start(const uint8_t *data, int size, int *start)
{
    for (int i = *start; i < size - 2; i++) {
        if (!data[i] && !data[i + 1] && data[i + 2] == 1) {
            *start = i;
            return i + 3;
        }
    }
    *start = size;
    return size;
}

static int annex(MPProbeHDR *result, int hevc, const uint8_t *data, int size)
{
    int start = 0;
    int payload = annex_start(data, size, &start);
    if (payload == size)
        return AVERROR_INVALIDDATA;
    while (payload < size) {
        start = payload;
        int next = annex_start(data, size, &start);
        if (next == size && start != size)
            return AVERROR_INVALIDDATA;
        while (start > payload && data[start - 1] == 0)
            start--;
        int ret = nal(result, hevc, data + payload, start - payload);
        if (ret < 0)
            return ret;
        payload = next;
    }
    return 0;
}

static int hevc_config(MPProbeHDR *result, const uint8_t *data, int size)
{
    if (size < 23)
        return AVERROR_INVALIDDATA;
    int pos = 23;
    for (unsigned array = 0; array < data[22]; array++) {
        if (size - pos < 3)
            return AVERROR_INVALIDDATA;
        unsigned count = AV_RB16(data + pos + 1);
        pos += 3;
        for (unsigned i = 0; i < count; i++) {
            if (size - pos < 2)
                return AVERROR_INVALIDDATA;
            unsigned length = AV_RB16(data + pos);
            pos += 2;
            if (length > (unsigned)(size - pos))
                return AVERROR_INVALIDDATA;
            int ret = nal(result, 1, data + pos, length);
            if (ret < 0)
                return ret;
            pos += (int)length;
        }
    }
    return 0;
}

static int leb128(const uint8_t *data, size_t size, size_t *pos, uint64_t *value)
{
    *value = 0;
    for (unsigned shift = 0; shift < 56 && *pos < size; shift += 7) {
        unsigned next = data[(*pos)++];
        *value |= (uint64_t)(next & 127) << shift;
        if (!(next & 128))
            return 0;
    }
    return AVERROR_INVALIDDATA;
}

static int av1_metadata(MPProbeHDR *result, const uint8_t *data, size_t size)
{
    for (size_t pos = 0; pos < size;) {
        unsigned header = data[pos++];
        if ((header & 0x81) || ((header & 4) && pos++ == size))
            return AVERROR_INVALIDDATA;
        uint64_t length = size - pos;
        if ((header & 2) && leb128(data, size, &pos, &length) < 0)
            return AVERROR_INVALIDDATA;
        if (length > size - pos)
            return AVERROR_INVALIDDATA;
        if (((header >> 3) & 15) == 5) {
            size_t end = pos + (size_t)length;
            uint64_t type;
            if (leb128(data, end, &pos, &type) < 0 || pos == end)
                return AVERROR_INVALIDDATA;
            if (type == 1) {
                if (end - pos < 4 || AV_RB32(data + pos))
                    result->inband_content_light = 1;
            } else if (type == 2) {
                if (end - pos < 24)
                    return AVERROR_INVALIDDATA;
                // AV1 uses different fixed-point units for chromaticity/luminance.
                // Refuse values which cannot be represented exactly in the output.
                uint32_t values[10];
                for (int i = 0; i < 8; i++) {
                    int index = i < 6 ? (i + 2) % 6 : i;
                    if (!normalized((AVRational){AV_RB16(data + pos + index * 2), 65536}, 50000, &values[i]))
                        result->conflicting_mastering = 1;
                }
                uint32_t max = AV_RB32(data + pos + 16), min = AV_RB32(data + pos + 20);
                if (max > INT32_MAX || min > INT32_MAX ||
                    !normalized((AVRational){(int)max, 256}, 10000, &values[8]) ||
                    !normalized((AVRational){(int)min, 16384}, 10000, &values[9]))
                    result->conflicting_mastering = 1;
                if (!result->conflicting_mastering)
                    mastering(result, values);
            } else if (type == 4) {
                message(result, 4, data + pos, end - pos);
            }
            pos = end;
        } else {
            pos += (size_t)length;
        }
    }
    return 0;
}

static int configuration(MPProbeHDR *result, enum AVCodecID codec, const uint8_t *data, int size, int *width)
{
    *width = 0;
    if (size <= 0)
        return 0;
    if (codec == AV_CODEC_ID_AV1)
        return data[0] == 0x81 && size >= 4 ? av1_metadata(result, data + 4, size - 4) : 0;
    if (codec != AV_CODEC_ID_H264 && codec != AV_CODEC_ID_HEVC)
        return 0;
    if (data[0] != 1)
        return annex(result, codec == AV_CODEC_ID_HEVC, data, size);
    int offset = codec == AV_CODEC_ID_HEVC ? 21 : 4;
    if (size <= offset)
        return AVERROR_INVALIDDATA;
    *width = (data[offset] & 3) + 1;
    return codec == AV_CODEC_ID_HEVC ? hevc_config(result, data, size) : 0;
}

static int picture(MPProbeHDR *result, enum AVCodecID codec, const uint8_t *data, int size, int width)
{
    if (codec == AV_CODEC_ID_AV1)
        return av1_metadata(result, data, size);
    int hevc = codec == AV_CODEC_ID_HEVC;
    if (!hevc && codec != AV_CODEC_ID_H264)
        return 0;
    if (!width)
        return annex(result, hevc, data, size);
    for (int pos = 0; pos < size;) {
        if (size - pos < width)
            return AVERROR_INVALIDDATA;
        unsigned length = 0;
        for (int i = 0; i < width; i++)
            length = length << 8 | data[pos++];
        if (length > (unsigned)(size - pos))
            return AVERROR_INVALIDDATA;
        int ret = nal(result, hevc, data + pos, length);
        if (ret < 0)
            return ret;
        pos += (int)length;
    }
    return 0;
}

int mp_probe_check_still_hevc(const uint8_t *data, int size, const uint8_t *config, int config_size)
{
    if (!data || size <= 0 || !config || config_size < 23 || config[0] != 1)
        return AVERROR_INVALIDDATA;
    MPProbeHDR result = {0};
    int ret = hevc_config(&result, config, config_size);
    if (ret < 0)
        return ret;
    ret = picture(&result, AV_CODEC_ID_HEVC, data, size, (config[21] & 3) + 1);
    if (ret < 0)
        return ret;
    return result.dolby_vision || result.hdr10plus || result.additional_layers ? AVERROR(ENOTSUP) : 0;
}

static int retained(int64_t pts, AVRational time_base, const MPProbeHDRRange *ranges, size_t count)
{
    if (!count)
        return 1;
    if (pts == AV_NOPTS_VALUE)
        return 0;
    size_t lo = 0, hi = count;
    while (lo < hi) {
        size_t middle = lo + (hi - lo) / 2;
        const MPProbeHDRRange *range = &ranges[middle];
        AVRational clock = {1, range->scale};
        if (av_compare_ts(pts, time_base, range->start, clock) < 0)
            hi = middle;
        else if (av_compare_ts(pts, time_base, range->end, clock) >= 0)
            lo = middle + 1;
        else
            return 1;
    }
    return 0;
}

int mp_probe_hdr(const char *path, int stream, const MPProbeHDRRange *ranges, size_t count,
                 MPProbeCancelled cancelled, void *context, MPProbeHDR *result,
                 char *error, size_t capacity)
{
    AVFormatContext *file = avformat_alloc_context();
    AVPacket *packet = av_packet_alloc();
    int ret = AVERROR(ENOMEM);
    if (!file || !packet)
        goto done;
    file->interrupt_callback = (AVIOInterruptCB){cancelled, context};
    ret = avformat_open_input(&file, path, NULL, NULL);
    if (ret < 0)
        goto done;
    if (stream >= 0 && ((unsigned)stream >= file->nb_streams ||
                        file->streams[stream]->codecpar->codec_id == AV_CODEC_ID_NONE)) {
        ret = mpcut_probe_decoder_policy(file);
        if (ret < 0)
            goto done;
        ret = avformat_find_stream_info(file, NULL);
        if (ret < 0)
            goto done;
    }
    if (stream < 0 || (unsigned)stream >= file->nb_streams ||
        file->streams[stream]->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
        ret = AVERROR_STREAM_NOT_FOUND;
        goto done;
    }
    for (unsigned i = 0; i < file->nb_streams; i++)
        if (i != (unsigned)stream) file->streams[i]->discard = AVDISCARD_ALL;

    const AVStream *video = file->streams[stream];
    const AVCodecParameters *codec = video->codecpar;
    const AVPacketSideData *side = codec->coded_side_data;
    int n = codec->nb_coded_side_data;
    const AVPacketSideData *display = av_packet_side_data_get(side, n, AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if (display)
        side_mastering(result, display->data, display->size);
    result->content_light = av_packet_side_data_get(side, n, AV_PKT_DATA_CONTENT_LIGHT_LEVEL) != NULL;
    result->dolby_vision = av_packet_side_data_get(side, n, AV_PKT_DATA_DOVI_CONF) != NULL ||
        codec->codec_tag == MKTAG('d', 'v', 'h', '1') || codec->codec_tag == MKTAG('d', 'v', 'h', 'e') ||
        codec->codec_tag == MKTAG('d', 'v', 'a', '1') || codec->codec_tag == MKTAG('d', 'a', 'v', '1');
    result->hdr10plus = av_packet_side_data_get(side, n, AV_PKT_DATA_DYNAMIC_HDR10_PLUS) != NULL;
    int width;
    ret = configuration(result, codec->codec_id, codec->extradata, codec->extradata_size, &width);
    if (ret < 0)
        goto done;

    while ((ret = av_read_frame(file, packet)) >= 0) {
        if (cancelled && cancelled(context)) {
            ret = AVERROR_EXIT;
            goto done;
        }
        if (packet->stream_index == stream) {
            size_t extra_size;
            const uint8_t *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &extra_size);
            if (extra) {
                if (extra_size > INT_MAX) {
                    ret = AVERROR_INVALIDDATA;
                    goto done;
                }
                ret = configuration(result, codec->codec_id, extra, (int)extra_size, &width);
                if (ret < 0)
                    goto done;
            }
            // Mastering and dynamic signaling can apply beyond the packet that
            // introduced them. Track that signaling for the source, including
            // packets before a trim. Only retained CLL would reach a copied output.
            int prior_content_light = result->inband_content_light;
            if (av_packet_get_side_data(packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS, NULL))
                result->hdr10plus = 1;
            if (av_packet_get_side_data(packet, AV_PKT_DATA_DOVI_CONF, NULL))
                result->dolby_vision = 1;
            if (av_packet_get_side_data(packet, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, NULL))
                result->inband_content_light = 1;
            size_t display_size = 0;
            const uint8_t *value = av_packet_get_side_data(packet, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, &display_size);
            side_mastering(result, value, display_size);
            ret = picture(result, codec->codec_id, packet->data, packet->size, width);
            if (ret < 0)
                goto done;
            if (!prior_content_light && result->inband_content_light &&
                !retained(packet->pts, video->time_base, ranges, count))
                result->inband_content_light = 0;
        }
        av_packet_unref(packet);
    }
    if (ret == AVERROR_EOF)
        ret = 0;

done:
    if (ret < 0 && error && capacity)
        av_strerror(ret, error, capacity);
    av_packet_free(&packet);
    avformat_close_input(&file);
    return ret;
}

int mp_probe_hdr_side_type(uint32_t type)
{
    switch (type) {
    case AV_PKT_DATA_MASTERING_DISPLAY_METADATA: return MP_PROBE_SIDE_MASTERING_DISPLAY;
    case AV_PKT_DATA_CONTENT_LIGHT_LEVEL: return MP_PROBE_SIDE_CONTENT_LIGHT;
    default: return 0;
    }
}
