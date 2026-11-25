#include "MediaProbe.h"
#include "codec_header.h"
#include "jpeg_frame.h"
#include "../CFFmpeg/layer3_frame.h"
#include "../CFFmpeg/copy_probe.h"
#include "mov_index.h"
#include "probe_evidence.h"
#include "video_clock.h"
#include "source_timecode.h"
#include "wave_pcm.h"
#include "../CFFmpeg/opus_packet.h"

#include <libavcodec/avcodec.h>
#include <libavcodec/vorbis_parser.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/avstring.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/opt.h>
#include <libavutil/parseutils.h>
#include <libavutil/pixdesc.h>

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void issue(MPProbeResult *result, const char *message)
{
    if (!result->issue[0])
        snprintf(result->issue, sizeof(result->issue), "%s", message);
}

int mp_canonical_channel_layout(const char *layout, int channels, char *canonical, size_t capacity)
{
    AVChannelLayout parsed = {0};
    int count = 0, used = 0;
    if (!layout || !canonical || !capacity)
        return 0;
    // "N channels" is how a layout without speaker positions describes itself.
    if (sscanf(layout, "%d channels%n", &count, &used) == 1 && used && !layout[used] && count > 0) {
        av_channel_layout_default(&parsed, count);
    } else {
        if (!layout[0] || av_channel_layout_from_string(&parsed, layout) < 0)
            return 0;
        if (parsed.order == AV_CHANNEL_ORDER_UNSPEC) {
            count = parsed.nb_channels;
            av_channel_layout_uninit(&parsed);
            av_channel_layout_default(&parsed, count);
        }
    }
    // A description that disagrees with the track's channel count is left as it is.
    int written = channels > 0 && parsed.nb_channels != channels ? -1
        : av_channel_layout_describe(&parsed, canonical, capacity);
    av_channel_layout_uninit(&parsed);
    return written > 0 && (size_t)written <= capacity;
}

const char *mp_vorbis_order_layout(int channels)
{
    static const char *const names[] = {"mono", "stereo", "3.0", "quad", "5.0", "5.1", "6.1", "7.1"};
    return channels >= 1 && channels <= 8 ? names[channels - 1] : NULL;
}

// The demuxers give Opus and Vorbis a channel count without speakers. An OpusHead with channel mapping
// family 1, and a Vorbis stream of three to eight channels, carry the layout their channel count defines.
static const char *coded_layout(const AVCodecParameters *params)
{
    const int channels = params->ch_layout.nb_channels;
    if (params->ch_layout.order != AV_CHANNEL_ORDER_UNSPEC)
        return NULL;
    if (params->codec_id == AV_CODEC_ID_VORBIS)
        return channels > 2 ? mp_vorbis_order_layout(channels) : NULL;
    const uint8_t *head = params->extradata;
    if (params->codec_id != AV_CODEC_ID_OPUS || channels < 1 || channels > 8 || !head ||
        params->extradata_size < 21 + channels || memcmp(head, "OpusHead", 8) || head[9] != channels || head[18] != 1)
        return NULL;
    return mp_vorbis_order_layout(channels);
}

void mp_probe_free(MPProbeResult *result)
{
    if (!result)
        return;
    for (int i = 0; result->streams && i < result->stream_count; i++) {
        MPProbeStream *stream = &result->streams[i];
        av_vorbis_parse_free(&stream->vorbis_parser);
        if (stream->flac_parser)
            av_parser_close(stream->flac_parser);
        avcodec_free_context(&stream->flac_context);
        av_free(stream->mp3_anchors);
        av_free(stream->packets);
        av_free(stream->config);
        av_free(stream->metadata);
        av_free(stream->language);
    }
    av_free(result->streams);
    av_free(result);
}

static bool linear_pcm(enum AVCodecID codec)
{
    switch (codec) {
    case AV_CODEC_ID_PCM_S8: case AV_CODEC_ID_PCM_U8:
    case AV_CODEC_ID_PCM_S16LE: case AV_CODEC_ID_PCM_S16BE:
    case AV_CODEC_ID_PCM_U16LE: case AV_CODEC_ID_PCM_U16BE:
    case AV_CODEC_ID_PCM_S24LE: case AV_CODEC_ID_PCM_S24BE:
    case AV_CODEC_ID_PCM_U24LE: case AV_CODEC_ID_PCM_U24BE:
    case AV_CODEC_ID_PCM_S32LE: case AV_CODEC_ID_PCM_S32BE:
    case AV_CODEC_ID_PCM_U32LE: case AV_CODEC_ID_PCM_U32BE:
    case AV_CODEC_ID_PCM_F32LE: case AV_CODEC_ID_PCM_F32BE:
    case AV_CODEC_ID_PCM_F64LE: case AV_CODEC_ID_PCM_F64BE:
        return true;
    default:
        return false;
    }
}

static bool raw_video(const AVCodecParameters *params, const char *format)
{
    // FFmpeg exposes REDCODE as JPEG 2000, which is also used for non-RAW video.
    const AVPixFmtDescriptor *pixel = av_pix_fmt_desc_get(params->format);
    if (av_match_name("r3d", format) || (pixel && (pixel->flags & AV_PIX_FMT_FLAG_BAYER)))
        return true;
    switch (params->codec_id) {
    case AV_CODEC_ID_PRORES_RAW: case AV_CODEC_ID_RAWVIDEO:
    case AV_CODEC_ID_V210: case AV_CODEC_ID_V210X:
    case AV_CODEC_ID_R210: case AV_CODEC_ID_R10K:
    case AV_CODEC_ID_Y41P:
    case AV_CODEC_ID_YUV4: case AV_CODEC_ID_AVUI:
    case AV_CODEC_ID_AVRP: case AV_CODEC_ID_012V:
        return true;
    default:
        return false;
    }
}

static int copy_metadata(const AVCodecParameters *params, MPProbeStream *stream)
{
    static const enum AVPacketSideDataType retained[] = {
        AV_PKT_DATA_DISPLAYMATRIX, AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
        AV_PKT_DATA_CONTENT_LIGHT_LEVEL, AV_PKT_DATA_ICC_PROFILE,
        AV_PKT_DATA_DOVI_CONF, AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT,
        AV_PKT_DATA_STEREO3D, AV_PKT_DATA_SPHERICAL, AV_PKT_DATA_AUDIO_SERVICE_TYPE
    };
    const AVPacketSideData *items[FF_ARRAY_ELEMS(retained)];
    size_t size = 0;
    for (size_t i = 0; i < FF_ARRAY_ELEMS(retained); i++) {
        items[i] = av_packet_side_data_get(params->coded_side_data, params->nb_coded_side_data, retained[i]);
        if (items[i]) {
            if (retained[i] != AV_PKT_DATA_DISPLAYMATRIX)
                stream->complex_picture = 1;
            if (items[i]->size > UINT32_MAX || SIZE_MAX - size < items[i]->size + 8)
                return AVERROR_INVALIDDATA;
            size += items[i]->size + 8;
        }
    }
    if (!size)
        return 0;
    stream->metadata = av_malloc(size);
    if (!stream->metadata)
        return AVERROR(ENOMEM);
    stream->metadata_size = size;
    uint8_t *cursor = stream->metadata;
    for (size_t i = 0; i < FF_ARRAY_ELEMS(items); i++) {
        if (!items[i])
            continue;
        AV_WL32(cursor, items[i]->type);
        AV_WL32(cursor + 4, (uint32_t)items[i]->size);
        memcpy(cursor + 8, items[i]->data, items[i]->size);
        cursor += 8 + items[i]->size;
    }
    const AVPacketSideData *matrix = items[0];
    if (matrix && matrix->size == 9 * sizeof(int32_t)) {
        double rotation = av_display_rotation_get((const int32_t *)matrix->data);
        if (isfinite(rotation)) {
            stream->rotation = (int)lround(rotation);
            int32_t canonical[9];
            av_display_rotation_set(canonical, -stream->rotation);
            // Camera matrices can translate a rotated picture back into view.
            // Reject flips, scaling, perspective and approximate rotations.
            const int32_t *m = (const int32_t *)matrix->data;
            stream->rotation_only = stream->rotation % 90 == 0 &&
                !memcmp(m, canonical, 6 * sizeof(*m)) && m[8] == canonical[8];
        }
    }
    return 0;
}

static int describe_stream(AVFormatContext *file, AVStream *input, MPProbeStream *stream)
{
    const AVCodecParameters *params = input->codecpar;
    stream->field_order = params->field_order;
    stream->chroma_location = av_chroma_location_name(params->chroma_location);
    stream->complex_picture = params->field_order != AV_FIELD_UNKNOWN && params->field_order != AV_FIELD_PROGRESSIVE;
    stream->track_id = input->id;
    stream->disposition = input->disposition;
    const AVDictionaryEntry *language = av_dict_get(input->metadata, "language", NULL, 0);
    if (language) {
        stream->language = av_strdup(language->value);
        if (!stream->language)
            return AVERROR(ENOMEM);
    }
    if (params->codec_type == AVMEDIA_TYPE_AUDIO) {
        const AVDictionaryEntry *title = av_dict_get(input->metadata, "title", NULL, 0);
        if (!title || !title->value[0])
            title = av_dict_get(input->metadata, "handler_name", NULL, 0);
        if (title)
            av_strlcpy(stream->name, title->value, sizeof(stream->name));
    }
    stream->kind = (input->disposition & AV_DISPOSITION_ATTACHED_PIC) ? "attachment" : av_get_media_type_string(params->codec_type);
    stream->codec = avcodec_get_name(params->codec_id);
    av_fourcc_make_string(stream->codec_tag, params->codec_tag);
    stream->profile = params->profile;
    stream->width = stream->display_width = params->width;
    stream->height = stream->display_height = params->height;
    stream->tb_num = input->time_base.num;
    stream->tb_den = input->time_base.den;
    stream->start = input->start_time;
    stream->duration = input->duration;
    stream->sample_rate = params->sample_rate;
    stream->channels = params->ch_layout.nb_channels;
    stream->pcm = linear_pcm(params->codec_id);
    stream->initial_padding = params->initial_padding;
    stream->trailing_padding = params->trailing_padding;
    stream->seek_preroll = params->seek_preroll;
    if (stream->channels)
        av_channel_layout_describe(&params->ch_layout, stream->channel_layout, sizeof(stream->channel_layout));
    const char *coded = coded_layout(params);
    if (coded)
        snprintf(stream->channel_layout, sizeof(stream->channel_layout), "%s", coded);
    stream->bit_depth = params->bits_per_raw_sample;
    if (params->codec_type == AVMEDIA_TYPE_VIDEO) {
        AVRational rate = av_guess_frame_rate(file, input, NULL);
        stream->rate_num = rate.num;
        stream->rate_den = rate.den;
        stream->pixel_format = av_get_pix_fmt_name(params->format);
        const AVPixFmtDescriptor *pixel = av_pix_fmt_desc_get(params->format);
        if (pixel && pixel->nb_components) {
            if (!stream->bit_depth)
                stream->bit_depth = pixel->comp[0].depth;
            if ((pixel->flags & AV_PIX_FMT_FLAG_ALPHA) && params->codec_id != AV_CODEC_ID_PRORES)
                stream->alpha_bits = pixel->comp[pixel->nb_components - 1].depth;
        }
        if (params->codec_id == AV_CODEC_ID_VP8 || params->codec_id == AV_CODEC_ID_VP9) {
            const AVDictionaryEntry *alpha = av_dict_get(input->metadata, "alpha_mode", NULL, 0);
            // Matroska exposes the bitstream's separately coded alpha plane as a track tag.
            if (alpha && !strcmp(alpha->value, "1"))
                stream->alpha_bits = stream->bit_depth ? stream->bit_depth : 8;
        }
        AVRational sar = av_guess_sample_aspect_ratio(file, input, NULL);
        if (sar.num <= 0 || sar.den <= 0)
            sar = (AVRational){1, 1};
        stream->sar_num = sar.num;
        stream->sar_den = sar.den;
        int64_t width = av_rescale(params->width, sar.num, sar.den);
        if (width <= INT_MAX)
            stream->display_width = (int)width;
    }
    stream->primaries = av_color_primaries_name(params->color_primaries);
    stream->transfer = av_color_transfer_name(params->color_trc);
    stream->matrix = av_color_space_name(params->color_space);
    stream->range = av_color_range_name(params->color_range);
    if (params->extradata_size > 0) {
        stream->config_size = params->extradata_size;
        stream->config = av_memdup(params->extradata, stream->config_size);
        if (!stream->config)
            return AVERROR(ENOMEM);
    }
    int status = copy_metadata(params, stream);
    if (abs(stream->rotation) % 180 == 90) {
        int width = stream->display_width;
        stream->display_width = stream->display_height;
        stream->display_height = width;
    }
    return status;
}

static bool vp9_start(const uint8_t *bytes, size_t size)
{
    if (size < 4)
        return false;
    // Marker, profile, optional reserved bit, show_existing_frame,
    // frame_type, show_frame, error_resilient_mode, then the 24-bit sync code.
    uint64_t header = AV_RB32(bytes);
    if ((header & 0x30000000) == 0x30000000) {
        if (size < 5 || (header & 0x08000000))
            return false;
        header = (header << 1) | (bytes[4] >> 7);
    }
    return (bytes[0] >> 6) == 2 &&
           (header & 0x0e000000) == 0x02000000 &&
           (header & 0xffffff) == 0x498342;
}

static bool vp8_start(const uint8_t *bytes, size_t size)
{
    return size >= 10 && (bytes[0] & 0x11) == 0x10 && AV_RB24(bytes + 3) == 0x9d012a;
}

/* AV1 low-overhead OBU format. A displayed KEY_FRAME refreshes all references. */
static bool av1_units(const uint8_t *bytes, size_t size, int *reduced_header)
{
    for (size_t i = 0; i < size;) {
        uint8_t header = bytes[i++];
        if (header & 0x81)
            return false;
        if (header & 4) {
            if (i == size || bytes[i++] != 0)
                return false;
        }
        uint64_t length = size - i;
        if (header & 2) {
            length = 0;
            for (unsigned int shift = 0;; shift += 7) {
                if (i == size || shift >= 56)
                    return false;
                unsigned int value = bytes[i++];
                length |= (uint64_t)(value & 127) << shift;
                if (!(value & 128))
                    break;
            }
        }
        if (length > size - i)
            return false;
        unsigned int type = header >> 3;
        if (type == 1 && length)
            *reduced_header = !!(bytes[i] & 8);
        if ((type == 3 || type == 6) && length)
            return *reduced_header == 1 || (*reduced_header == 0 && (bytes[i] & 0xf0) == 0x10);
        i += length;
    }
    return false;
}

/* VP8, VP9 and AV1 packets are coded in presentation order, one shown picture each, so the
 * packets before any packet decode without it. A packet can also code hidden pictures, shown
 * later or never: a VP8 or VP9 alternate reference, or an AV1 frame shown by a later
 * show_existing_frame. A copy may end before a packet when every picture coded since the last
 * displayed keyframe was shown before it. Anything not understood blocks these ends until the
 * next keyframe. Verified by decoding truncated copies (libavcodec, and VideoToolbox for VP9 and
 * AV1) of one- and two-pass libvpx VP8 and VP9 (8- and 10-bit) and libsvtav1 random-access and
 * low-delay AV1 in WebM, Matroska and MP4. */
typedef struct {
    bool active;          /* A displayed keyframe started the current group. */
    bool blocked;         /* A hidden picture that is never shown, or an unknown header. */
    unsigned serial;      /* VP9: hidden pictures in this group. */
    uint64_t pending;     /* VP9: hidden pictures not yet shown, by serial. */
    unsigned char slot[8];/* VP9: serial + 1 of the hidden picture in each reference slot. */
    int av1_pending;      /* AV1: showable hidden pictures not yet shown. */
    int reduced_header;   /* AV1: reduced_still_picture_header, or -1 before a sequence header. */
} PictureEnds;

typedef struct {
    const uint8_t *data;
    size_t size, bit;
} BitReader;

static unsigned read_bits(BitReader *reader, int count)
{
    unsigned value = 0;
    for (int i = 0; i < count; i++, reader->bit++) {
        unsigned byte = reader->bit / 8 < reader->size ? reader->data[reader->bit / 8] : 0;
        value = value << 1 | (byte >> (7 - reader->bit % 8) & 1);
    }
    return value;
}

/* One VP9 frame. Returns the number of pictures it shows, or -1 when not understood. */
static int vp9_picture(PictureEnds *ends, const uint8_t *data, size_t size)
{
    BitReader bits = {data, size, 0};
    if (size < 1 || read_bits(&bits, 2) != 2)
        return -1;
    unsigned profile = read_bits(&bits, 1);
    profile |= read_bits(&bits, 1) << 1;
    if (profile == 3 && read_bits(&bits, 1))
        return -1;
    if (read_bits(&bits, 1)) { /* show_existing_frame */
        unsigned shown = ends->slot[read_bits(&bits, 3)];
        if (shown)
            ends->pending &= ~(UINT64_C(1) << (shown - 1));
        return 1;
    }
    bool key = !read_bits(&bits, 1);
    bool show = read_bits(&bits, 1);
    bool error_resilient = read_bits(&bits, 1);
    if (key) {
        if (!show)
            return -1;
        ends->pending = 0;
        ends->serial = 0;
        memset(ends->slot, 0, sizeof(ends->slot));
        return 1;
    }
    bool intra_only = show ? false : read_bits(&bits, 1);
    if (!error_resilient)
        read_bits(&bits, 2); /* reset_frame_context */
    if (intra_only) {
        if (read_bits(&bits, 24) != 0x498342)
            return -1;
        if (profile > 0) {
            if (profile >= 2)
                read_bits(&bits, 1);
            if (read_bits(&bits, 3) != 7) { /* not sRGB */
                read_bits(&bits, 1);
                if (profile == 1 || profile == 3)
                    read_bits(&bits, 3);
            } else if (profile == 1 || profile == 3) {
                read_bits(&bits, 1);
            }
        }
    }
    unsigned refresh = read_bits(&bits, 8);
    if (bits.bit > size * 8)
        return -1;
    unsigned char id = 0;
    if (!show) {
        if (ends->serial >= 64)
            return -1;
        id = (unsigned char)++ends->serial;
        ends->pending |= UINT64_C(1) << (id - 1);
    }
    for (int i = 0; i < 8; i++)
        if (refresh >> i & 1)
            ends->slot[i] = id;
    return show;
}

static int vp9_pictures(PictureEnds *ends, const uint8_t *data, size_t size)
{
    uint8_t marker = size ? data[size - 1] : 0;
    if ((marker & 0xe0) == 0xc0) {
        size_t count = (marker & 7) + 1, width = ((marker >> 3) & 3) + 1, index = 2 + width * count;
        if (size >= index && data[size - index] == marker) {
            const uint8_t *sizes = data + size - index + 1;
            size_t position = 0;
            int shown = 0;
            for (size_t frame = 0; frame < count; frame++) {
                size_t length = 0;
                for (size_t byte = 0; byte < width; byte++)
                    length |= (size_t)sizes[frame * width + byte] << (8 * byte);
                if (length > size - index - position)
                    return -1;
                int result = vp9_picture(ends, data + position, length);
                if (result < 0)
                    return -1;
                shown += result;
                position += length;
            }
            return shown;
        }
    }
    return vp9_picture(ends, data, size);
}

/* One AV1 temporal unit. Returns the number of pictures it shows, or -1 when not understood. */
static int av1_pictures(PictureEnds *ends, const uint8_t *data, size_t size)
{
    int shown = 0;
    for (size_t i = 0; i < size;) {
        uint8_t header = data[i++];
        if (header & 0x81)
            return -1;
        if (header & 4)
            return -1; /* Scalable layers. */
        uint64_t length = size - i;
        if (header & 2) {
            length = 0;
            for (unsigned shift = 0;; shift += 7) {
                if (i == size || shift >= 56)
                    return -1;
                unsigned value = data[i++];
                length |= (uint64_t)(value & 127) << shift;
                if (!(value & 128))
                    break;
            }
        }
        if (length > size - i)
            return -1;
        unsigned type = header >> 3;
        if (type == 1 && length) {
            ends->reduced_header = !!(data[i] & 8);
        } else if ((type == 3 || type == 6) && length) {
            if (ends->reduced_header < 0)
                return -1;
            uint8_t first = data[i];
            if (ends->reduced_header || (first & 0x80)) {
                // A still picture, or show_existing_frame of an earlier hidden picture.
                if (!ends->reduced_header && ends->av1_pending-- <= 0)
                    return -1;
                shown++;
            } else if (first & 0x10) {
                shown++;
            } else if (first & 0x08) {
                ends->av1_pending++; /* showable_frame */
            } else {
                ends->blocked = true;
            }
        }
        i += length;
    }
    return shown;
}

static void picture_end(PictureEnds *ends, const AVCodecParameters *params, const AVPacket *packet,
                        MPProbePacket *sample, bool alpha)
{
    enum AVCodecID codec = params->codec_id;
    if (codec != AV_CODEC_ID_VP8 && codec != AV_CODEC_ID_VP9 && codec != AV_CODEC_ID_AV1)
        return;
    if (alpha) {
        // An alpha stream codes its own hidden pictures in block additions.
        ends->active = false;
        return;
    }
    if (codec == AV_CODEC_ID_AV1 && ends->reduced_header < 0 && params->extradata_size > 4 && params->extradata[0] == 0x81)
        av1_pictures(ends, params->extradata + 4, params->extradata_size - 4); /* av1C sequence header */
    if (sample->start) {
        ends->active = true;
        ends->blocked = false;
        ends->pending = 0;
        ends->serial = 0;
        ends->av1_pending = 0;
        memset(ends->slot, 0, sizeof(ends->slot));
    } else if (ends->active && !ends->blocked && !ends->pending && !ends->av1_pending && !sample->key) {
        sample->end = 1;
    }
    int shown;
    if (codec == AV_CODEC_ID_VP8)
        shown = packet->size >= 3 ? packet->data[0] >> 4 & 1 : -1;
    else if (codec == AV_CODEC_ID_VP9)
        shown = vp9_pictures(ends, packet->data, packet->size);
    else
        shown = av1_pictures(ends, packet->data, packet->size);
    // Each packet shows exactly one picture. VP8 cannot show a hidden picture later.
    if (shown != 1)
        ends->blocked = true;
}

static bool independent(const AVPacket *packet, const AVCodecParameters *params, bool source_start, int *multilayer)
{
    if (params->codec_id == AV_CODEC_ID_PRORES)
        return packet->size >= 26 && AV_RB32(packet->data + 4) == MKBETAG('i', 'c', 'p', 'f');
    if (!(packet->flags & AV_PKT_FLAG_KEY))
        return false;
    switch (params->codec_id) {
    case AV_CODEC_ID_H264: case AV_CODEC_ID_HEVC:
        return mp_h26x_random_access(packet, params, source_start, multilayer);
    case AV_CODEC_ID_MJPEG:
        return self_contained_jpeg(packet->data, packet->size, params->width, params->height, NULL) || source_start;
    case AV_CODEC_ID_VP8:
        return vp8_start(packet->data, packet->size);
    case AV_CODEC_ID_VP9:
        return vp9_start(packet->data, packet->size);
    case AV_CODEC_ID_AV1: {
        int reduced_header = -1;
        // An av1C record may carry sequence OBUs after its four fixed bytes.
        if (params->extradata_size > 4 && params->extradata[0] == 0x81)
            av1_units(params->extradata + 4, params->extradata_size - 4, &reduced_header);
        return av1_units(packet->data, packet->size, &reduced_header);
    }
    default:
        return source_start;
    }
}

static bool interior_cut_codec(enum AVCodecID codec)
{
    return codec == AV_CODEC_ID_PRORES || codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC ||
           codec == AV_CODEC_ID_VP8 || codec == AV_CODEC_ID_VP9 || codec == AV_CODEC_ID_AV1;
}

/* MOV may switch avc1/hvc1 sample descriptions at an IDR. Verify the
 * dimensions and pixel layout described by the actual bitstream, as well
 * as the container-level presentation properties checked by the caller. */
typedef struct {
    int width, height, coded_width, coded_height, format, field_order;
} MPDescriptionShape;

static bool description_shape(const AVCodecParameters *params, const uint8_t *config, size_t size,
                              const AVPacket *packet, MPDescriptionShape *shape)
{
    const size_t length_field = params->codec_id == AV_CODEC_ID_HEVC ? 21 : 4;
    if (!config || size <= length_field || size > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE ||
        config[0] != 1 || (config[length_field] & 3) != 3)
        return false;
    AVCodecParserContext *parser = av_parser_init(params->codec_id);
    AVCodecContext *context = avcodec_alloc_context3(NULL);
    bool success = false;
    if (!parser || !context)
        goto done;
    context->extradata = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!context->extradata)
        goto done;
    memcpy(context->extradata, config, size);
    context->extradata_size = (int)size;
    context->codec_id = params->codec_id;
    parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
    uint8_t *parsed = NULL;
    int parsed_size = 0;
    if (av_parser_parse2(parser, context, &parsed, &parsed_size, packet->data, packet->size,
                         packet->pts, packet->dts, packet->pos) == packet->size &&
        parsed_size == packet->size &&
        (parser->format == AV_PIX_FMT_YUV420P ||
         (params->codec_id == AV_CODEC_ID_HEVC && parser->format == AV_PIX_FMT_YUV420P10LE)) &&
        parser->width == params->width && parser->height == params->height &&
        parser->coded_width > 0 && parser->coded_height > 0 &&
        (parser->field_order == AV_FIELD_UNKNOWN || parser->field_order == AV_FIELD_PROGRESSIVE)) {
        *shape = (MPDescriptionShape){parser->width, parser->height, parser->coded_width, parser->coded_height,
                                      parser->format, parser->field_order};
        success = true;
    }
done:
    av_parser_close(parser);
    avcodec_free_context(&context);
    return success;
}

static bool matching_shape(enum AVCodecID codec, const MPDescriptionShape *a, const MPDescriptionShape *b)
{
    if (a->width != b->width || a->height != b->height || a->coded_width != b->coded_width ||
        a->format != b->format || a->field_order != b->field_order)
        return false;
    if (a->coded_height == b->coded_height)
        return true;
    // HEVC encoders can pad the same visible rows to an 8- or 16-line boundary.
    int64_t height = a->height;
    return codec == AV_CODEC_ID_HEVC && FFMIN(a->coded_height, b->coded_height) == ((height + 7) & ~INT64_C(7)) &&
           FFMAX(a->coded_height, b->coded_height) == ((height + 15) & ~INT64_C(15));
}

static int record_packet(MPProbeResult *result, const AVCodecParameters *params, const AVPacket *packet,
                         MPDescriptionShape *first_description, PictureEnds *pictures)
{
    MPProbeStream *stream = &result->streams[packet->stream_index];
    bool video = packet->stream_index == result->video_index;
    if (!video && params->codec_type != AVMEDIA_TYPE_AUDIO)
        return 0;
    if (packet->flags & AV_PKT_FLAG_CORRUPT)
        issue(result, "An audio or video packet is marked corrupt.");
    size_t side_size;
    const uint8_t *config = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &side_size);
    bool can_compare = first_description && video && av_match_name("mov", result->format) &&
        ((params->codec_id == AV_CODEC_ID_H264 && params->codec_tag == MKTAG('a', 'v', 'c', '1')) ||
         (params->codec_id == AV_CODEC_ID_HEVC && params->codec_tag == MKTAG('h', 'v', 'c', '1')));
    if (can_compare && !stream->count)
        description_shape(params, params->extradata, params->extradata_size, packet, first_description);
    if (config) {
        MPDescriptionShape shape;
        if (can_compare && first_description->width && independent(packet, params, false, &stream->multilayer) &&
            description_shape(params, config, side_size, packet, &shape) &&
            matching_shape(params->codec_id, first_description, &shape)) {
            stream->multiple_descriptions = 1;
        } else {
            issue(result, "The stream changes codec configuration during the file.");
        }
    }
    if (av_packet_get_side_data(packet, AV_PKT_DATA_PARAM_CHANGE, &side_size))
        issue(result, "The stream changes codec configuration during the file.");
    if (packet->pts == AV_NOPTS_VALUE) {
        issue(result, "An audio or video packet is missing its presentation timestamp.");
        return 0;
    }
    bool nonincreasing = false;
    if (!video) {
        nonincreasing = stream->count && packet->pts <= stream->last_audio_pts;
        stream->last_audio_pts = packet->pts;
        if (!stream->pcm)
            stream->coded_bytes += packet->size;
    }
    const bool coarse_audio = result->video_index < 0 &&
                              (int64_t)stream->tb_num * params->sample_rate > stream->tb_den;
    // Keep coarse-clock PCM packets individually so a rounded duration cannot
    // hide which sample count and timestamp belong to each block.
    if (stream->pcm && !coarse_audio && stream->count && !nonincreasing && packet->duration > 0 &&
        !av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &side_size)) {
        MPProbePacket *previous = &stream->packets[stream->count - 1];
        if (!previous->skip && !previous->discard && previous->duration > 0 &&
            previous->pts <= INT64_MAX - previous->duration &&
            previous->pts + previous->duration == packet->pts &&
            previous->duration <= INT64_MAX - packet->duration) {
            previous->duration += packet->duration;
            return 0;
        }
    }
    if (stream->count == stream->capacity) {
        size_t capacity = stream->capacity ? stream->capacity * 2 : 1024;
        if (capacity <= stream->capacity)
            return AVERROR(ENOMEM);
        void *packets = av_realloc_array(stream->packets, capacity, sizeof(*stream->packets));
        if (!packets)
            return AVERROR(ENOMEM);
        stream->packets = packets;
        stream->capacity = capacity;
    }
    // Index only a verified continuous Layer III sample clock. An unusual file
    // keeps the sequential crop verifier, including its prefix diagnostics.
    if (params->codec_id == AV_CODEC_ID_MP3 && !strcmp(result->format, "mp3") && !stream->mp3_unindexed) {
        Layer3Frame frame;
        AVRational base = {stream->tb_num, stream->tb_den}, samples = {1, params->sample_rate};
        if (!layer3_frame(packet, params->sample_rate, &frame) || packet->pos < 0 ||
            stream->count > INT64_MAX / frame.samples ||
            av_rescale_q(packet->pts, base, samples) != (int64_t)stream->count * frame.samples ||
            av_rescale_q(packet->duration, base, samples) != frame.samples) {
            stream->mp3_unindexed = 1;
            stream->mp3_anchor_count = 0;
        } else if (stream->count % 64 == 0) {
            size_t n = stream->mp3_anchor_count;
            if (n % 128 == 0) {
                void *anchors = av_realloc_array(stream->mp3_anchors, n + 128, sizeof(*stream->mp3_anchors));
                if (!anchors) return AVERROR(ENOMEM);
                stream->mp3_anchors = anchors;
            }
            stream->mp3_anchors[n] = (MPProbeMP3Anchor){(int64_t)stream->count * frame.samples,
                packet->pos, av_adler32_update(1, packet->data, packet->size)};
            stream->mp3_anchor_count++;
        }
    }
    MPProbePacket *sample = &stream->packets[stream->count];
    *sample = (MPProbePacket){.pts = packet->pts, .dts = packet->dts, .duration = packet->duration,
                              .byte_count = packet->size};
    if (video) {
        bool first = !stream->count;
        sample->key = !!(packet->flags & AV_PKT_FLAG_KEY) || params->codec_id == AV_CODEC_ID_PRORES;
        if (independent(packet, params, false, &stream->multilayer))
            sample->start = 1;
        else if (first && independent(packet, params, true, &stream->multilayer))
            sample->start = 2;
        // H.264 auxiliary (alpha) pictures, MVC views and SVC layers come with every access unit, keyframes included.
        // A decoder of the primary pictures drops them, as an encode of those pictures would.
        if (params->codec_id == AV_CODEC_ID_H264 && sample->key && !stream->multilayer && mp_h264_layered(packet, params))
            stream->multilayer = 1;
        if (params->codec_id == AV_CODEC_ID_VP8 || params->codec_id == AV_CODEC_ID_VP9) {
            const uint8_t *alpha = av_packet_get_side_data(packet, AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL, &side_size);
            const bool has_alpha = alpha && side_size > 8 && AV_RB64(alpha) == 1;
            if (has_alpha && !stream->alpha_bits) {
                issue(result, "The video contains alpha samples without a declared alpha track mode.");
                stream->alpha_bits = stream->bit_depth ? stream->bit_depth : 8;
            } else if (stream->alpha_bits && sample->start) {
                if (!has_alpha || !(params->codec_id == AV_CODEC_ID_VP8 ? vp8_start(alpha + 8, side_size - 8) :
                                                                        vp9_start(alpha + 8, side_size - 8)))
                    sample->start = 0;
            }
        }
        sample->end = sample->key && (interior_cut_codec(params->codec_id) ||
                                      (params->codec_id == AV_CODEC_ID_MJPEG && sample->start == 1));
        if (pictures)
            picture_end(pictures, params, packet, sample, stream->alpha_bits != 0);
        if (packet->flags & AV_PKT_FLAG_DISCARD)
            issue(result, "The video track contains disposable packets from a presentation edit.");
        if (params->codec_id == AV_CODEC_ID_PRORES) {
            if (!sample->start) {
                issue(result, "A ProRes sample has an invalid frame header.");
            } else {
                const uint8_t flags = packet->data[20];
                const unsigned frame_type = (flags >> 2) & 3;
                const uint32_t layout = (uint32_t)(flags & 0xcc) << 24 | AV_RB24(packet->data + 22);
                if (AV_RB16(packet->data + 16) != params->width || AV_RB16(packet->data + 18) != params->height ||
                    (flags >> 6) < 2 || frame_type == 3 || (!first && stream->prores_layout != layout))
                    issue(result, "A ProRes sample changes dimensions, chroma, field order or color description.");
                if (first) {
                    stream->prores_layout = layout;
                    if (stream->field_order == AV_FIELD_UNKNOWN)
                        stream->field_order = frame_type == 0 ? AV_FIELD_PROGRESSIVE :
                                              frame_type == 1 ? AV_FIELD_TT : AV_FIELD_BB;
                }
                const int alpha_code = packet->data[25] & 15;
                const int alpha_bits = alpha_code == 1 ? 8 : alpha_code == 2 ? 16 : 0;
                if (alpha_code > 2 || (!first && alpha_bits != stream->alpha_bits))
                    issue(result, "The ProRes alpha configuration is unsupported or changes during the file.");
                // Conversion must preserve transparency seen anywhere in the clip.
                stream->alpha_bits = first ? alpha_bits : FFMAX(stream->alpha_bits, alpha_bits);
            }
        }
    } else {
        if (coarse_audio && stream->pcm && packet->size > 0) {
            const int bits = av_get_exact_bits_per_sample(params->codec_id);
            const int64_t align = (int64_t)(bits / 8) * params->ch_layout.nb_channels;
            if (bits % 8 == 0 && align > 0 && packet->size % align == 0)
                sample->decoded_samples = packet->size / align;
        }
        if (params->codec_id == AV_CODEC_ID_FLAC && packet->size > 0) {
            if (!stream->flac_parser) {
                stream->flac_parser = av_parser_init(AV_CODEC_ID_FLAC);
                stream->flac_context = avcodec_alloc_context3(NULL);
                if (!stream->flac_parser || !stream->flac_context)
                    return AVERROR(ENOMEM);
                stream->flac_parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
                stream->flac_context->sample_rate = params->sample_rate;
            }
            uint8_t *parsed = NULL;
            int parsed_size = 0;
            stream->flac_parser->duration = 0;
            if (av_parser_parse2(stream->flac_parser, stream->flac_context, &parsed, &parsed_size,
                                 packet->data, packet->size, packet->pts, packet->dts, packet->pos) == packet->size &&
                parsed_size == packet->size && stream->flac_parser->duration > 0)
                sample->decoded_samples = stream->flac_parser->duration;
        }
        if (params->codec_id == AV_CODEC_ID_ALAC && packet->size >= 3) {
            // The first ALAC channel element gives the packet's frame count.
            // Full frames use the maximum frame size from the ALAC magic cookie.
            const bool partial_frame = (packet->data[2] & 0x10) != 0;
            uint32_t frames = 0;
            if (partial_frame && packet->size >= 7)
                frames = (AV_RB32(packet->data + 2) << 7) | (packet->data[6] >> 1);
            else if (!partial_frame && params->extradata_size >= 16)
                frames = AV_RB32(params->extradata + 12);
            if (frames <= INT_MAX)
                sample->decoded_samples = frames;
        }
        if (params->codec_id == AV_CODEC_ID_OPUS)
            sample->decoded_samples = mpcut_opus_samples(packet->data, packet->size);
        if (params->codec_id == AV_CODEC_ID_VORBIS) {
            if (!stream->count)
                stream->vorbis_parser = av_vorbis_parse_init(params->extradata, params->extradata_size);
            if (stream->vorbis_parser) {
                int samples = av_vorbis_parse_frame(stream->vorbis_parser, packet->data, packet->size);
                if (samples > 0)
                    sample->decoded_samples = samples;
            }
        }
        const uint8_t *skip = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &side_size);
        if (skip && side_size >= 10) {
            sample->skip = AV_RL32(skip);
            sample->discard = AV_RL32(skip + 4);
        }
        if (params->codec_id == AV_CODEC_ID_AAC && av_match_name("mov", result->format)) {
            /* The advanced MOV demuxer can re-emit preroll across presentation edits. */
            if (nonincreasing)
                stream->deferred_aac_issue = 1;
            else if (packet->duration <= 0 && !stream->deferred_aac_issue)
                stream->deferred_aac_issue = 2;
        } else if (!stream->audio_clock_issue[0]) {
            const char *message = nonincreasing ? "An audio track has non-increasing presentation timestamps." :
                packet->duration <= 0 ? "An audio packet is missing its duration." : NULL;
            if (message)
                snprintf(stream->audio_clock_issue, sizeof(stream->audio_clock_issue), "%s", message);
        }
    }
    stream->count++;
    return 0;
}

static int compare_pts(const void *left, const void *right)
{
    const MPProbePacket *a = left;
    const MPProbePacket *b = right;
    return (a->pts > b->pts) - (a->pts < b->pts);
}

typedef struct {
    int64_t first_presentation;
    unsigned char start, end;
} CutPoint;

/* `picture_ends` marks every point where the decode order is also split by presentation
 * time as an end, whether or not the next coded picture is a keyframe. */
static int reorder_video(MPProbeStream *video, bool *source_start, bool matroska_avc_or_hevc, bool picture_ends)
{
    MPProbePacket *packets = video->packets;
    CutPoint *cuts = av_calloc(video->count, sizeof(*cuts));
    if (!cuts)
        return AVERROR(ENOMEM);

    int64_t suffix_min = INT64_MAX;
    for (size_t i = video->count; i-- > 0;) {
        if (matroska_avc_or_hevc && (packets[i].dts == AV_NOPTS_VALUE || (i && packets[i].dts <= packets[i - 1].dts)))
            video->reconstructed_dts = 1;
        suffix_min = FFMIN(suffix_min, packets[i].pts);
        cuts[i].first_presentation = suffix_min;
    }

    // Retaining by presentation timestamps must reproduce the decode prefix
    // and suffix. Some closed GOPs display leading B pictures before the IDR.
    // The pictures before such a point are a complete decode prefix: none of them
    // was coded after, or predicted from, a picture at or past it. A reordered
    // stream has one of these before each anchor picture that no earlier-presented
    // picture follows in decode order, typically one per run of B pictures.
    int64_t prefix_max = INT64_MIN;
    for (size_t i = 0; i < video->count; i++) {
        CutPoint *cut = &cuts[i];
        MPProbePacket *packet = &packets[i];
        if (prefix_max < cut->first_presentation) {
            cut->start = packet->start == 1 ||
                (packet->start == 2 && cut->first_presentation == packet->pts);
            // An end before a keyframe, or with picture_ends, one inside a picture group.
            cut->end = packet->end || picture_ends;
        }
        prefix_max = FFMAX(prefix_max, packet->pts);
        packet->start = packet->end = 0;
        if (video->reconstructed_dts)
            packet->dts = (int64_t)i; // Keep the coded packet ordinal through the presentation sort.
    }
    *source_start = cuts[0].start;
    if (video->count >= 65536)
        psort(packets, video->count, sizeof(*packets), compare_pts);
    else
        qsort(packets, video->count, sizeof(*packets), compare_pts);
    if (video->reconstructed_dts) {
        // Matroska AVC/HEVC blocks store PTS in coded order. A packet-only demux
        // may report these same values as DTS. Assign presentation-clock slots
        // in coded order, shifted just far enough that no DTS exceeds its PTS.
        __int128 delay = 0;
        for (size_t i = 0; i < video->count; i++) {
            __int128 lead = (__int128)packets[packets[i].dts].pts - packets[i].pts;
            if (lead > delay) delay = lead;
        }
        for (size_t i = 0; i < video->count; i++) {
            __int128 dts = (__int128)packets[packets[i].dts].pts - delay;
            if (dts <= INT64_MIN) {
                av_free(cuts);
                return AVERROR_INVALIDDATA;
            }
            packets[i].dts = (int64_t)dts;
        }
    }
    // After a held picture, neither a MOV sample's decode interval nor a Matroska block's
    // (often default) duration reaches the next picture, so a prefix that stops inside its
    // picture group can end its last picture early. The writer runs the range's last picture
    // to the planned end and extends the last decoded MOV sample to it (mpcut_mov_cover_edits),
    // so these ends are kept for sources with varying picture durations too.
    size_t frame = 0;
    for (size_t i = 0; i < video->count; i++) {
        const CutPoint *cut = &cuts[i];
        if (!cut->start && !cut->end)
            continue;
        while (frame < video->count && packets[frame].pts < cut->first_presentation)
            frame++;
        if (frame < video->count && packets[frame].pts == cut->first_presentation) {
            packets[frame].start = cut->start;
            packets[frame].end = cut->end;
        }
    }
    av_free(cuts);
    return 0;
}

int64_t mp_video_presentation_end(const char *format, const AVStream *video, int64_t duration,
                                  int64_t origin, int64_t last_pts, int64_t packet_end)
{
    int64_t end = packet_end;
    if (av_match_name("mov", format) && duration > 0 && origin <= INT64_MAX - duration) {
        // MOV sample durations are DTS intervals. With reordered VFR samples
        // they do not give presentation widths or the presentation end.
        int64_t track_end = origin + duration;
        if (track_end > last_pts)
            end = track_end;
    }
    if (av_match_name("matroska", format) && av_cmp_q(video->time_base, AV_TIME_BASE_Q) >= 0) {
        // Matroska demux rounds a track's default block duration down to whole
        // ticks. FFmpeg's per-track DURATION tag records its absolute end on
        // the segment clock. Use it only to resolve a one-tick rounding error.
        const AVDictionaryEntry *tag = av_dict_get(video->metadata, "DURATION", NULL, 0);
        int64_t us;
        if (tag && av_parse_time(&us, tag->value, 1) == 0 && us >= 0) {
            int64_t tagged_end = av_rescale_q(us, AV_TIME_BASE_Q, video->time_base);
            int64_t delta = av_sat_sub64(tagged_end, packet_end);
            if (tagged_end > last_pts && delta >= -1 && delta <= 1)
                end = tagged_end;
        }
    }
    return end;
}

static int build_video_index(MPProbeResult *result, const AVStream *input_video)
{
    MPProbeStream *video = &result->streams[result->video_index];
    MPProbePacket *packets = video->packets;
    if (!video->count)
        return AVERROR_INVALIDDATA;

    bool sorted = true;
    for (size_t i = 1; i < video->count; i++) {
        if (packets[i].pts <= packets[i - 1].pts) {
            sorted = false;
            break;
        }
    }
    bool source_start = packets[0].start != 0;
    enum AVCodecID codec = input_video->codecpar->codec_id;
    // Every sample is one displayed progressive picture, so a decode prefix holds
    // exactly the pictures it presents. A field-coded stream can split a frame
    // across two samples. VP8, VP9 and AV1 packets can also carry pictures that
    // are shown later.
    bool picture_ends = (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC) &&
        (av_match_name("mov", result->format) || av_match_name("matroska", result->format)) &&
        input_video->codecpar->extradata_size > 0 && input_video->codecpar->extradata[0] == 1 &&
        video->field_order == AV_FIELD_PROGRESSIVE && !video->complex_picture &&
        !video->multilayer && !video->multiple_descriptions;
    if (!sorted) {
        bool matroska_avc_or_hevc = av_match_name("matroska", result->format) &&
                                    (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC);
        int status = reorder_video(video, &source_start, matroska_avc_or_hevc, picture_ends);
        if (status < 0)
            return status;
    } else if (picture_ends) {
        // In presentation order every picture decodes from earlier samples only.
        // The pictures before any picture decode without it.
        for (size_t i = 0; i < video->count; i++)
            packets[i].end = 1;
    }
    if (sorted && av_match_name("matroska", result->format) &&
        (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC)) {
        // Matroska stores no decode time. A packet-only demux leaves it unset for AVC/HEVC
        // whose blocks are in presentation order, where it equals the presentation time.
        for (size_t i = 0; i < video->count; i++)
            if (packets[i].dts == AV_NOPTS_VALUE)
                packets[i].dts = packets[i].pts;
    }
    result->origin = video->start == AV_NOPTS_VALUE ? packets[0].pts : video->start;
    result->source_start_safe = source_start && packets[0].pts == result->origin;

    AVRational time_base = {video->tb_num, video->tb_den};
    int64_t nominal = video->rate_num > 0 && video->rate_den > 0
        ? av_rescale_q(1, (AVRational){video->rate_den, video->rate_num}, time_base) : 0;
    int64_t packet_end = packets[0].pts;
    for (size_t i = 0; i < video->count; i++) {
        MPProbePacket *frame = &packets[i];
        if (i && packets[i - 1].pts == frame->pts)
            issue(result, "The video track has more than one sample at a presentation timestamp.");
        if (frame->duration <= 0) {
            if (i + 1 < video->count)
                frame->duration = av_sat_sub64(packets[i + 1].pts, frame->pts);
            else if (video->duration > 0 &&
                     av_sat_add64(result->origin, video->duration) > frame->pts)
                frame->duration = av_sat_sub64(av_sat_add64(result->origin, video->duration), frame->pts);
            else
                frame->duration = nominal;
        }
        if (frame->duration <= 0 || frame->pts > INT64_MAX - frame->duration)
            return AVERROR_INVALIDDATA;
        packet_end = FFMAX(packet_end, frame->pts + frame->duration);
    }
    result->end = mp_video_presentation_end(result->format, input_video, video->duration, result->origin,
                                            packets[video->count - 1].pts, packet_end);
    for (size_t i = 0; i < video->count; i++) {
        int64_t next = i + 1 < video->count ? packets[i + 1].pts : result->end;
        if (next > packets[i].pts)
            packets[i].duration = av_sat_sub64(next, packets[i].pts);
    }
    return result->end > result->origin ? 0 : AVERROR_INVALIDDATA;
}

static bool needs_stream_analysis(const AVFormatContext *file)
{
    if (!file->nb_streams)
        return true;
    for (unsigned int i = 0; i < file->nb_streams; i++) {
        const AVCodecParameters *params = file->streams[i]->codecpar;
        if (params->codec_type == AVMEDIA_TYPE_VIDEO &&
            (!params->width || !params->height ||
             (params->format < 0 && params->codec_id != AV_CODEC_ID_PRORES &&
              !mp_has_header_probe(params->codec_id))))
            return true;
        if (params->codec_type == AVMEDIA_TYPE_AUDIO &&
            (!params->sample_rate || !params->ch_layout.nb_channels ||
             (params->codec_id == AV_CODEC_ID_AAC && params->ch_layout.nb_channels > 2 &&
              params->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC)))
            return true;
    }
    return false;
}

static void update_header_description(MPProbeStream *stream, const AVCodecParameters *params)
{
    stream->field_order = params->field_order;
    stream->complex_picture |= params->field_order != AV_FIELD_UNKNOWN && params->field_order != AV_FIELD_PROGRESSIVE;
    stream->chroma_location = av_chroma_location_name(params->chroma_location);
    stream->profile = params->profile;
    stream->pixel_format = av_get_pix_fmt_name(params->format);
    const AVPixFmtDescriptor *pixel = av_pix_fmt_desc_get(params->format);
    if (pixel && pixel->nb_components) {
        stream->bit_depth = pixel->comp[0].depth;
        if (pixel->flags & AV_PIX_FMT_FLAG_ALPHA)
            stream->alpha_bits = pixel->comp[pixel->nb_components - 1].depth;
        else if (stream->alpha_bits && (params->codec_id == AV_CODEC_ID_VP8 || params->codec_id == AV_CODEC_ID_VP9))
            stream->alpha_bits = stream->bit_depth;
    }
    stream->primaries = av_color_primaries_name(params->color_primaries);
    stream->transfer = av_color_transfer_name(params->color_trc);
    stream->matrix = av_color_space_name(params->color_space);
    stream->range = av_color_range_name(params->color_range);
}

/* For simple intraframe MOV, FFmpeg's index already describes the packets.
 * Read each real ProRes frame header to preserve the frame and alpha checks. */
static int indexed_prores(const MPMOVIndex *index, AVFormatContext *file, MPProbeResult *result,
                          MPProbeCancelled cancelled, MPProbeProgress progress, void *context)
{
    if (index->fd < 0 || result->issue[0] || result->has_unsupported_auxiliary ||
        file->streams[result->video_index]->codecpar->codec_id != AV_CODEC_ID_PRORES)
        return 0;
    for (int i = 0; i < result->stream_count; i++) {
        const MPProbeStream *stream = &result->streams[i];
        if (file->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
            (!stream->pcm || stream->initial_padding || stream->trailing_padding ||
             stream->seek_preroll || stream->sample_rate != stream->tb_den))
            return 0;
    }

    int64_t entries = 0, completed = 0;
    if (progress) {
        for (int i = 0; i < result->stream_count; i++)
            entries += avformat_index_get_entries_count(file->streams[i]);
    }
    int status = 0;
    for (int i = 0; i < result->stream_count; i++) {
        AVStream *stream = file->streams[i];
        const AVCodecParameters *params = stream->codecpar;
        bool video = i == result->video_index;
        bool audio = params->codec_type == AVMEDIA_TYPE_AUDIO;
        int count = avformat_index_get_entries_count(stream);
        if (count <= 0 || (!audio && count != stream->nb_frames))
            goto fallback;
        int64_t expected = 0, end = index->payload_start;
        int64_t frame_duration = video ? stream->duration / count : 0;
        int64_t block_align = av_get_exact_bits_per_sample(params->codec_id) / 8 *
                              (int64_t)params->ch_layout.nb_channels;
        if (audio && (block_align <= 0 || (params->block_align && params->block_align != block_align)))
            goto fallback;
        MPProbeStream *indexed = &result->streams[i];
        if (video && count > (index->payload_end - index->payload_start) / 26)
            goto fallback;
        if (video || audio) {
            size_t capacity = video ? count : 1;
            indexed->packets = av_malloc_array(capacity, sizeof(*indexed->packets));
            if (!indexed->packets) {
                status = AVERROR(ENOMEM);
                goto done;
            }
            indexed->capacity = capacity;
        }
        int last_audio_size = 0;
        for (int j = 0; j < count; j++) {
            bool report = (j % 128) == 0;
            if ((video || report) && cancelled && cancelled(context)) {
                status = AVERROR_EXIT;
                goto done;
            }
            if (report && progress && entries > 0)
                progress(context, (double)(completed + j) / entries);
            const AVIndexEntry *entry = avformat_index_get_entry(stream, j);
            if (!entry || entry->timestamp != expected || entry->pos < end ||
                entry->pos >= index->payload_end || entry->size <= 0 ||
                entry->size > index->payload_end - entry->pos ||
                (entry->flags & (AVINDEX_KEYFRAME | AVINDEX_DISCARD_FRAME)) != AVINDEX_KEYFRAME)
                goto fallback;
            end = entry->pos + entry->size;
            int64_t duration = stream->duration;
            if (video) {
                if (entry->size < 26)
                    goto fallback;
                duration = frame_duration;
            } else if (audio) {
                if (entry->size % block_align)
                    goto fallback;
                duration = entry->size / block_align;
            } else if (count != 1 || entry->size != 4) {
                goto fallback;
            }
            if (duration <= 0 || duration > stream->duration - expected)
                goto fallback;
            expected += duration;
            if (!video) {
                if (audio)
                    last_audio_size = entry->size;
                continue;
            }

            uint8_t header[26];
            if (!mp_mov_read_at(index->fd, entry->pos, header, sizeof(header)))
                goto fallback;
            AVPacket packet = {
                .stream_index = i, .pts = entry->timestamp, .dts = entry->timestamp,
                .duration = duration, .flags = AV_PKT_FLAG_KEY,
                .data = header, .size = sizeof(header),
            };
            status = record_packet(result, params, &packet, NULL, NULL);
            if (status < 0)
                goto done;
            indexed->packets[indexed->count - 1].byte_count = entry->size;
        }
        completed += count;
        if (expected != stream->duration)
            goto fallback;
        if (audio) {
            // The validated PCM rows are contiguous and have no padding.
            // Store the same coalesced row as the ordinary packet scan.
            AVPacket packet = {
                .stream_index = i, .duration = expected, .size = last_audio_size,
                .flags = AV_PKT_FLAG_KEY,
            };
            status = record_packet(result, params, &packet, NULL, NULL);
            if (status < 0)
                goto done;
        }
    }
    status = 1;
    goto done;

fallback:
    for (int i = 0; i < result->stream_count; i++)
        result->streams[i].count = 0;
    result->streams[result->video_index].alpha_bits = 0;
    result->issue[0] = 0;
done:
    return status;
}

/* The MOV demuxer reads a track that other tracks name in a 'chap' reference into the
 * file's chapters, and marks the track itself as discarded binary data. A copy writes
 * those chapters into a new chapter track, so the source track is not an extra track. */
static bool chapter_track(const AVFormatContext *file, const AVStream *stream)
{
    const AVCodecParameters *params = stream->codecpar;
    return av_match_name("mov", file->iformat->name) && file->nb_chapters > 0 &&
           params->codec_type == AVMEDIA_TYPE_DATA && params->codec_id == AV_CODEC_ID_BIN_DATA &&
           stream->discard == AVDISCARD_ALL;
}

static bool prores_index_candidate(const AVFormatContext *file, AVStream **video)
{
    if (!av_match_name("mov", file->iformat->name))
        return false;
    bool timecode = false;
    for (unsigned int i = 0; i < file->nb_streams; i++) {
        AVStream *stream = file->streams[i];
        const AVCodecParameters *params = stream->codecpar;
        if (params->codec_type == AVMEDIA_TYPE_VIDEO && params->codec_id == AV_CODEC_ID_PRORES &&
            !*video && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            *video = stream;
        } else if (params->codec_type == AVMEDIA_TYPE_DATA && params->codec_tag == MKTAG('t', 'm', 'c', 'd') &&
                   !timecode) {
            timecode = true;
        } else if (params->codec_type != AVMEDIA_TYPE_AUDIO || !linear_pcm(params->codec_id)) {
            return false;
        }
    }
    return *video != NULL;
}

/* The intraframe header carries chroma and alpha mode. The sample entry
 * identifies the ProRes profile and component bit depth. Neither needs a decoder. */
static bool read_prores_header(AVCodecParameters *params, const uint8_t *bytes, int size)
{
    if (size < 28 || AV_RB32(bytes + 4) != MKBETAG('i', 'c', 'p', 'f') ||
        AV_RB32(bytes) > (uint32_t)size || AV_RB16(bytes + 10) > 1 ||
        AV_RB16(bytes + 8) < 20 + 64 * (!!(bytes[27] & 1) + !!(bytes[27] & 2)) ||
        AV_RB32(bytes) < 8U + AV_RB16(bytes + 8) ||
        AV_RB16(bytes + 16) != params->width || AV_RB16(bytes + 18) != params->height)
        return false;
    unsigned int chroma = bytes[20] >> 6;
    unsigned int alpha = bytes[25] & 15;
    if (chroma < 2 || alpha > 2)
        return false;
    int profile;
    switch (params->codec_tag) {
    case MKTAG('a', 'p', 'c', 'o'): profile = AV_PROFILE_PRORES_PROXY; break;
    case MKTAG('a', 'p', 'c', 's'): profile = AV_PROFILE_PRORES_LT; break;
    case MKTAG('a', 'p', 'c', 'n'): profile = AV_PROFILE_PRORES_STANDARD; break;
    case MKTAG('a', 'p', 'c', 'h'): profile = AV_PROFILE_PRORES_HQ; break;
    case MKTAG('a', 'p', '4', 'h'): profile = AV_PROFILE_PRORES_4444; break;
    case MKTAG('a', 'p', '4', 'x'): profile = AV_PROFILE_PRORES_XQ; break;
    default: return false;
    }
    static const int formats[2][2][2] = {
        {{AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUVA422P10LE}, {AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_YUVA444P10LE}},
        {{AV_PIX_FMT_YUV422P12LE, AV_PIX_FMT_YUVA422P12LE}, {AV_PIX_FMT_YUV444P12LE, AV_PIX_FMT_YUVA444P12LE}},
    };
    bool depth12 = profile == AV_PROFILE_PRORES_4444 || profile == AV_PROFILE_PRORES_XQ;
    params->format = formats[depth12][chroma - 2][alpha != 0];
    params->profile = profile;
    params->bits_per_raw_sample = depth12 ? 12 : 10;
    if (params->color_primaries == AVCOL_PRI_UNSPECIFIED && av_color_primaries_name(bytes[22]))
        params->color_primaries = bytes[22];
    if (params->color_trc == AVCOL_TRC_UNSPECIFIED && av_color_transfer_name(bytes[23]))
        params->color_trc = bytes[23];
    if (params->color_space == AVCOL_SPC_UNSPECIFIED && av_color_space_name(bytes[24]))
        params->color_space = bytes[24];
    if (params->color_range == AVCOL_RANGE_UNSPECIFIED)
        params->color_range = AVCOL_RANGE_MPEG;
    return true;
}

static bool describe_prores_header(const MPMOVIndex *index, AVStream *stream)
{
    const AVIndexEntry *first = avformat_index_get_entry(stream, 0);
    uint8_t bytes[28];
    return first && first->pos >= index->payload_start && first->size >= (int)sizeof(bytes) &&
           first->size <= index->payload_end - first->pos &&
           mp_mov_read_at(index->fd, first->pos, bytes, sizeof(bytes)) &&
           read_prores_header(stream->codecpar, bytes, first->size);
}

static void describe_pcm_bit_depths(AVFormatContext *file)
{
    for (unsigned int i = 0; i < file->nb_streams; i++) {
        AVCodecParameters *params = file->streams[i]->codecpar;
        switch (params->codec_id) {
        case AV_CODEC_ID_PCM_S24LE: case AV_CODEC_ID_PCM_S24BE:
        case AV_CODEC_ID_PCM_U24LE: case AV_CODEC_ID_PCM_U24BE:
        case AV_CODEC_ID_PCM_S32LE: case AV_CODEC_ID_PCM_S32BE:
        case AV_CODEC_ID_PCM_U32LE: case AV_CODEC_ID_PCM_U32BE:
            params->bits_per_raw_sample = av_get_exact_bits_per_sample(params->codec_id);
            break;
        default:
            break;
        }
    }
}

/* A simple PCM WAVE data chunk has one frame per block and no edits or
 * packet timestamps. Validate its declared span against the physical file
 * before using its implicit sample clock for analysis. */
static int indexed_wave_audio(AVFormatContext *file, MPProbeResult *result)
{
    int64_t start;
    if (!mp_wave_pcm_layout(file, &start)) return 0;
    AVStream *stream = file->streams[0];
    AVPacket packet = {.pts = 0, .dts = 0, .duration = stream->duration};
    int status = record_packet(result, stream->codecpar, &packet, NULL, NULL);
    return status < 0 ? status : 1;
}

static void capture_source_stamp(AVFormatContext *file, MPProbeResult *result, int primary)
{
    const MPProbeStream *track = &result->streams[primary];
    result->source_stamp_stream = primary;
    result->source_stamp_kind = mp_source_sync_stamp_in_input(file, primary, track->rate_num, track->rate_den,
                                                               &result->source_stamp_units, &result->source_stamp_num,
                                                               &result->source_stamp_den);
    if (result->source_stamp_kind != 0 || result->video_index < 0)
        return;
    for (int i = 0; i < result->stream_count; i++) {
        if (file->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO || result->streams[i].sample_rate <= 0)
            continue;
        result->source_stamp_stream = i;
        result->source_stamp_kind = mp_source_sync_stamp_in_input(file, i, 0, 0, &result->source_stamp_units,
                                                                   &result->source_stamp_num, &result->source_stamp_den);
        return;
    }
}

MPProbeResult *mp_probe_read(const char *path, int conversion, int preview_only, int audio_analysis, int force_payload,
                            MPProbeCancelled cancelled, MPProbeProgress progress, void *context,
                            char *error, size_t error_capacity)
{
    AVFormatContext *file = avformat_alloc_context();
    AVPacket *packet = NULL;
    MPProbeResult *result = NULL;
    MPProbeEvidence *evidence = NULL;
    MPMOVIndex mov_index = {.fd = -1};
    int status = AVERROR(ENOMEM);
    if (!file)
        goto fail;
    file->interrupt_callback = (AVIOInterruptCB){.callback = cancelled, .opaque = context};
    status = avformat_open_input(&file, path, NULL, NULL);
    if (status < 0)
        goto fail;
    AVStream *prores = NULL;
    if (!preview_only && prores_index_candidate(file, &prores)) {
        describe_pcm_bit_depths(file);
        if (mp_mov_open_index(path, file, &mov_index) && !describe_prores_header(&mov_index, prores)) {
            close(mov_index.fd);
            mov_index.fd = -1;
        }
    }
    if (!preview_only && needs_stream_analysis(file)) {
        // Copy inspection uses packet headers. Conversion also needs the decoded
        // pixel format for codecs such as Animation, PNG and FFV1, whose
        // container parameters may give no indication that alpha is present.
        if (!conversion) {
            status = mpcut_probe_decoder_policy(file);
            if (status < 0)
                goto fail;
        }
        status = avformat_find_stream_info(file, NULL);
        if (status < 0)
            goto fail;
    }
    result = av_mallocz(sizeof(*result));
    if (!result) {
        status = AVERROR(ENOMEM);
        goto fail;
    }
    result->video_index = -1;
    result->stream_count = file->nb_streams;
    result->streams = av_calloc(result->stream_count, sizeof(*result->streams));
    packet = av_packet_alloc();
    if (!result->streams || !packet) {
        status = AVERROR(ENOMEM);
        goto fail;
    }
    snprintf(result->format, sizeof(result->format), "%s", file->iformat->name);
    bool timecode = false;
    int first_audio = -1;
    for (int i = 0; i < result->stream_count; i++) {
        AVStream *stream = file->streams[i];
        status = describe_stream(file, stream, &result->streams[i]);
        if (status < 0)
            goto fail;
        enum AVMediaType type = stream->codecpar->codec_type;
        if (type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            if (result->video_index == -1)
                result->video_index = i;
            else {
                issue(result, "Multiple video tracks are unsupported.");
                if (!result->timeline_issue[0])
                    snprintf(result->timeline_issue, sizeof(result->timeline_issue), "Multiple video tracks are unsupported.");
            }
            if (raw_video(stream->codecpar, result->format)) {
                issue(result, "RAW video is unsupported.");
                snprintf(result->timeline_issue, sizeof(result->timeline_issue), "RAW video is unsupported.");
            }
        } else if (type == AVMEDIA_TYPE_AUDIO) {
            if (first_audio == -1) first_audio = i;
        } else if (type == AVMEDIA_TYPE_DATA && stream->codecpar->codec_tag == MKTAG('t', 'm', 'c', 'd') &&
                   av_match_name("mov", file->iformat->name) && !timecode) {
            timecode = true;
        } else if ((type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_SUBTITLE && type != AVMEDIA_TYPE_DATA &&
                    type != AVMEDIA_TYPE_ATTACHMENT) ||
                   (type == AVMEDIA_TYPE_DATA && stream->discard == AVDISCARD_ALL && !chapter_track(file, stream)) ||
                   (type == AVMEDIA_TYPE_DATA && stream->codecpar->codec_tag == MKTAG('t', 'm', 'c', 'd') &&
                    av_match_name("mov", file->iformat->name))) {
            // Cover art, attached files, subtitles and timed data travel beside a copy where the output
            // can hold them, and the copy names any it leaves out. A track of no known kind, one the
            // demuxer set aside without reading its chapters, or a second timecode track (a copy writes
            // one) cannot be judged.
            result->has_unsupported_auxiliary = 1;
        }
    }
    int primary = result->video_index >= 0 ? result->video_index : first_audio;
    if (primary < 0) {
        status = AVERROR_STREAM_NOT_FOUND;
        goto fail;
    }
    if (preview_only) {
        // Use declared timing for an early preview. The full scan determines
        // the edit duration and verified boundaries independently.
        const AVStream *video = file->streams[primary];
        int64_t duration = video->duration;
        if (duration <= 0 && av_match_name("matroska", result->format)) {
            const AVDictionaryEntry *tag = av_dict_get(video->metadata, "DURATION", NULL, 0);
            int64_t end;
            if (tag && av_parse_time(&end, tag->value, 1) == 0 && end > 0) {
                int64_t start = video->start_time == AV_NOPTS_VALUE ? 0 : video->start_time;
                duration = av_sat_sub64(av_rescale_q(end, AV_TIME_BASE_Q, video->time_base), start);
            }
        }
        if (duration <= 0 && file->duration > 0)
            duration = av_rescale_q(file->duration, AV_TIME_BASE_Q, video->time_base);
        result->origin = video->start_time == AV_NOPTS_VALUE ? 0 : video->start_time;
        result->end = av_sat_add64(result->origin, duration);
        if (result->end <= result->origin || (result->video_index >= 0 && (video->codecpar->width <= 0 || video->codecpar->height <= 0))) {
            status = AVERROR_INVALIDDATA;
            goto fail;
        }
        av_packet_free(&packet);
        avformat_close_input(&file);
        return result;
    }
    AVCodecParameters *video_params = file->streams[primary]->codecpar;
    bool prores_video = video_params->codec_id == AV_CODEC_ID_PRORES;
    bool needs_video_header = video_params->format < 0 &&
                              (prores_video || mp_has_header_probe(video_params->codec_id));
    bool inspect_scan = video_params->codec_id == AV_CODEC_ID_H264 || video_params->codec_id == AV_CODEC_ID_HEVC;
    status = force_payload ? 0 : result->video_index >= 0 ? indexed_prores(&mov_index, file, result, cancelled, progress, context) :
             audio_analysis ? indexed_wave_audio(file, result) : 0;
    if (status < 0)
        goto fail;
    if (status == 0) {
        evidence = mp_probe_evidence_open(path, file);
        if (!evidence) {
            status = AVERROR(ENOMEM);
            goto fail;
        }
    }
    int64_t file_size = progress && file->pb && status == 0 ? avio_size(file->pb) : 0;
    unsigned packet_number = 0;
    double packet_bytes = 0;
    MPDescriptionShape first_description = {0};
    PictureEnds pictures = {.reduced_header = -1};
    while (status == 0) {
        if (cancelled && cancelled(context)) {
            status = AVERROR_EXIT;
            goto fail;
        }
        status = av_read_frame(file, packet);
        if (status < 0)
            break;
        if (progress && file_size > 0) {
            // Demuxers can alternate between tracks stored far apart in the file.
            // Payload bytes count work even when packet offsets jump or are unavailable.
            packet_bytes += packet->size;
            if ((packet_number++ % 128) == 0)
                progress(context, fmin(1.0, packet_bytes / file_size));
        }
        if (packet->stream_index == result->video_index && video_params->codec_id == AV_CODEC_ID_MJPEG &&
            video_params->format == AV_PIX_FMT_NONE && result->streams[result->video_index].count == 0) {
            enum AVPixelFormat format = AV_PIX_FMT_NONE;
            if (self_contained_jpeg(packet->data, packet->size, video_params->width, video_params->height, &format) &&
                format != AV_PIX_FMT_NONE) {
                video_params->format = format;
                video_params->profile = AV_PROFILE_MJPEG_HUFFMAN_BASELINE_DCT;
                if (video_params->color_range == AVCOL_RANGE_UNSPECIFIED)
                    video_params->color_range = AVCOL_RANGE_JPEG;
                update_header_description(&result->streams[result->video_index], video_params);
            }
        }
        if ((needs_video_header || inspect_scan) && packet->stream_index == result->video_index &&
            (prores_video || (packet->flags & AV_PKT_FLAG_KEY))) {
            bool may_interlace = false;
            bool read = prores_video ? read_prores_header(video_params, packet->data, packet->size) :
                                       mp_read_video_header(video_params, packet, &may_interlace,
                                                            &result->streams[result->video_index].multilayer);
            if (read) {
                MPProbeStream *stream = &result->streams[result->video_index];
                update_header_description(stream, video_params);
                stream->complex_picture |= may_interlace;
                needs_video_header = false;
            }
            inspect_scan = false;
        }
        if (packet->stream_index < result->stream_count) {
            mp_probe_evidence_packet(evidence, file->streams[packet->stream_index], packet);
            status = record_packet(result, file->streams[packet->stream_index]->codecpar, packet, &first_description,
                                   packet->stream_index == result->video_index ? &pictures : NULL);
        } else
            issue(result, "The source introduces a track after its stream headers.");
        av_packet_unref(packet);
        if (status < 0)
            goto fail;
    }
    if (status != AVERROR_EOF && status != 1)
        goto fail;
    if (evidence)
        mp_probe_evidence_finish(evidence, result);
    if (needs_video_header)
        issue(result, "The video codec headers do not identify the pixel format.");
    if (result->video_index >= 0) {
        status = build_video_index(result, file->streams[result->video_index]);
        if (status < 0) goto fail;
    } else {
        // Swift uses the actual packet times and decoder padding in each track's
        // own sample clock to establish the audible start and end.
        result->source_start_safe = 1;
    }
    capture_source_stamp(file, result, primary);
    av_packet_free(&packet);
    mp_probe_evidence_free(evidence);
    avformat_close_input(&file);
    if (mov_index.fd >= 0)
        close(mov_index.fd);
    return result;

fail:
    if (error && error_capacity)
        av_strerror(status, error, error_capacity);
    av_packet_free(&packet);
    mp_probe_evidence_free(evidence);
    avformat_close_input(&file);
    if (mov_index.fd >= 0)
        close(mov_index.fd);
    mp_probe_free(result);
    return NULL;
}
