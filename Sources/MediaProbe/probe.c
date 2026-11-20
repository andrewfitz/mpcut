#include "MediaProbe.h"
#include "codec_header.h"
#include "../CFFmpeg/copy_probe.h"
#include "mov_index.h"
#include "../CFFmpeg/opus_packet.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/avstring.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/opt.h>
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

void mp_probe_free(MPProbeResult *result)
{
    if (!result)
        return;
    for (int i = 0; result->streams && i < result->stream_count; i++) {
        MPProbeStream *stream = &result->streams[i];
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
        if (isfinite(rotation))
            stream->rotation = (int)lround(rotation);
    }
    return 0;
}

static int describe_stream(AVFormatContext *file, AVStream *input, MPProbeStream *stream)
{
    const AVCodecParameters *params = input->codecpar;
    stream->complex_picture = params->field_order != AV_FIELD_UNKNOWN && params->field_order != AV_FIELD_PROGRESSIVE;
    stream->track_id = input->id;
    stream->disposition = input->disposition;
    const AVDictionaryEntry *language = av_dict_get(input->metadata, "language", NULL, 0);
    if (language) {
        stream->language = av_strdup(language->value);
        if (!stream->language)
            return AVERROR(ENOMEM);
    }
    stream->kind = av_get_media_type_string(params->codec_type);
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

/* MOV H.26x samples are length-prefixed. Transport streams use Annex B. */
static bool h26x_start(const AVPacket *packet, const AVCodecParameters *params, bool source_start)
{
    bool hevc = params->codec_id == AV_CODEC_ID_HEVC;
    int length_size = 0;
    if (!hevc && params->extradata_size >= 5 && params->extradata[0] == 1)
        length_size = (params->extradata[4] & 3) + 1;
    if (hevc && params->extradata_size >= 22 && params->extradata[0] == 1)
        length_size = (params->extradata[21] & 3) + 1;
    const uint8_t *bytes = packet->data;
    int size = packet->size;
    bool random_access = false;
    for (int i = 0; i < size;) {
        int unit_end = size;
        if (length_size) {
            if (size - i < length_size)
                return false;
            uint32_t length = 0;
            for (int end = i + length_size; i < end; i++)
                length = (length << 8) | bytes[i];
            if (!length || length > (uint32_t)(size - i))
                return false;
            unit_end = i + (int)length;
        } else {
            while (i <= size - 3 && (bytes[i] || bytes[i + 1] || bytes[i + 2] != 1))
                i++;
            if (i > size - 4)
                break;
            i += 3;
            for (int next = i; next <= size - 3; next++) {
                if (!bytes[next] && !bytes[next + 1] && bytes[next + 2] == 1) {
                    unit_end = next;
                    break;
                }
            }
        }
        if (unit_end - i < (hevc ? 2 : 1))
            return false;
        int type = hevc ? (bytes[i] >> 1) & 63 : bytes[i] & 31;
        if (hevc && type <= 31) {
            if (type < 16 || type > (source_start ? 21 : 20))
                return false;
            random_access = true;
        } else if (!hevc && type >= 1 && type <= 5) {
            if (type != 5)
                return false;
            random_access = true;
        }
        i = unit_end;
    }
    return random_access;
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

static bool independent(const AVPacket *packet, const AVCodecParameters *params, bool source_start)
{
    if (params->codec_id == AV_CODEC_ID_PRORES)
        return packet->size >= 26 && AV_RB32(packet->data + 4) == MKBETAG('i', 'c', 'p', 'f');
    if (!(packet->flags & AV_PKT_FLAG_KEY))
        return false;
    switch (params->codec_id) {
    case AV_CODEC_ID_H264: case AV_CODEC_ID_HEVC:
        return h26x_start(packet, params, source_start);
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
        parsed_size == packet->size && parser->format == AV_PIX_FMT_YUV420P &&
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

static int record_packet(MPProbeResult *result, const AVCodecParameters *params, const AVPacket *packet,
                         MPDescriptionShape *first_description)
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
        if (can_compare && first_description->width && independent(packet, params, false) &&
            description_shape(params, config, side_size, packet, &shape) &&
            !memcmp(first_description, &shape, sizeof(shape))) {
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
    MPProbePacket *sample = &stream->packets[stream->count];
    *sample = (MPProbePacket){.pts = packet->pts, .dts = packet->dts, .duration = packet->duration,
                              .byte_count = packet->size};
    if (video) {
        bool first = !stream->count;
        sample->key = !!(packet->flags & AV_PKT_FLAG_KEY) || params->codec_id == AV_CODEC_ID_PRORES;
        if (independent(packet, params, false))
            sample->start = 1;
        else if (first && independent(packet, params, true))
            sample->start = 2;
        if (params->codec_id == AV_CODEC_ID_VP8 || params->codec_id == AV_CODEC_ID_VP9) {
            const uint8_t *alpha = av_packet_get_side_data(packet, AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL, &side_size);
            const bool has_alpha = alpha && side_size > 8 && AV_RB64(alpha) == 1;
            if (has_alpha && !stream->alpha_bits) {
                issue(result, "The video contains alpha samples without a declared alpha track mode.");
            } else if (stream->alpha_bits && sample->start) {
                if (!has_alpha || !(params->codec_id == AV_CODEC_ID_VP8 ? vp8_start(alpha + 8, side_size - 8) :
                                                                        vp9_start(alpha + 8, side_size - 8)))
                    sample->start = 0;
            }
        }
        sample->end = sample->key && interior_cut_codec(params->codec_id);
        if (packet->flags & AV_PKT_FLAG_DISCARD)
            issue(result, "The video track contains disposable packets from a presentation edit.");
        if (params->codec_id == AV_CODEC_ID_PRORES) {
            if (!sample->start) {
                issue(result, "A ProRes sample has an invalid frame header.");
            } else {
                const int alpha_code = packet->data[25] & 15;
                const int alpha_bits = alpha_code == 1 ? 8 : alpha_code == 2 ? 16 : 0;
                if (alpha_code > 2 || (!first && alpha_bits != stream->alpha_bits))
                    issue(result, "The ProRes alpha configuration is unsupported or changes during the file.");
                stream->alpha_bits = alpha_bits;
            }
        }
    } else {
        if (params->codec_id == AV_CODEC_ID_OPUS)
            sample->decoded_samples = mpcut_opus_samples(packet->data, packet->size);
        const uint8_t *skip = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &side_size);
        if (skip && side_size >= 10) {
            sample->skip = AV_RL32(skip);
            sample->discard = AV_RL32(skip + 4);
        }
        bool nonincreasing = stream->count && packet->pts <= stream->packets[stream->count - 1].pts;
        if (params->codec_id == AV_CODEC_ID_AAC && av_match_name("mov", result->format)) {
            /* The advanced MOV demuxer can re-emit preroll across presentation edits. */
            if (nonincreasing)
                stream->deferred_aac_issue = 1;
            else if (packet->duration <= 0 && !stream->deferred_aac_issue)
                stream->deferred_aac_issue = 2;
        } else {
            if (nonincreasing)
                issue(result, "An audio track has non-increasing presentation timestamps.");
            if (packet->duration <= 0)
                issue(result, "An audio packet is missing its duration.");
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

static int reorder_video(MPProbeStream *video, bool *source_start)
{
    MPProbePacket *packets = video->packets;
    CutPoint *cuts = av_calloc(video->count, sizeof(*cuts));
    if (!cuts)
        return AVERROR(ENOMEM);

    int64_t suffix_min = INT64_MAX;
    for (size_t i = video->count; i-- > 0;) {
        suffix_min = FFMIN(suffix_min, packets[i].pts);
        cuts[i].first_presentation = suffix_min;
    }

    // Retaining by presentation timestamps must reproduce the decode prefix
    // and suffix. Some closed GOPs display leading B pictures before the IDR.
    int64_t prefix_max = INT64_MIN;
    for (size_t i = 0; i < video->count; i++) {
        CutPoint *cut = &cuts[i];
        MPProbePacket *packet = &packets[i];
        if (prefix_max < cut->first_presentation) {
            cut->start = packet->start == 1 ||
                (packet->start == 2 && cut->first_presentation == packet->pts);
            cut->end = packet->end;
        }
        prefix_max = FFMAX(prefix_max, packet->pts);
        packet->start = packet->end = 0;
    }
    *source_start = cuts[0].start;
    qsort(packets, video->count, sizeof(*packets), compare_pts);
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

static int build_video_index(MPProbeResult *result)
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
    if (!sorted) {
        int status = reorder_video(video, &source_start);
        if (status < 0)
            return status;
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
    result->end = packet_end;
    if (av_match_name("mov", result->format) && video->duration > 0 &&
        result->origin <= INT64_MAX - video->duration) {
        // MOV sample durations are DTS intervals. With reordered VFR samples
        // they do not give presentation widths or the presentation end.
        int64_t track_end = result->origin + video->duration;
        if (track_end > packets[video->count - 1].pts)
            result->end = track_end;
    }
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
            (!params->sample_rate || !params->ch_layout.nb_channels))
            return true;
    }
    return false;
}

static void update_header_description(MPProbeStream *stream, const AVCodecParameters *params)
{
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
                          MPProbeCancelled cancelled, void *context)
{
    if (index->fd < 0 || result->issue[0] ||
        file->streams[result->video_index]->codecpar->codec_id != AV_CODEC_ID_PRORES)
        return 0;
    for (int i = 0; i < result->stream_count; i++) {
        const MPProbeStream *stream = &result->streams[i];
        if (file->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
            (!stream->pcm || stream->initial_padding || stream->trailing_padding ||
             stream->seek_preroll || stream->sample_rate != stream->tb_den))
            return 0;
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
        for (int j = 0; j < count; j++) {
            if (cancelled && cancelled(context)) {
                status = AVERROR_EXIT;
                goto done;
            }
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
            if (!video && !audio)
                continue;

            uint8_t header[26];
            if (video && !mp_mov_read_at(index->fd, entry->pos, header, sizeof(header)))
                goto fallback;
            AVPacket packet = {
                .stream_index = i, .pts = entry->timestamp, .dts = entry->timestamp,
                .duration = duration, .flags = AV_PKT_FLAG_KEY,
                .data = video ? header : NULL, .size = video ? sizeof(header) : 0,
            };
            status = record_packet(result, params, &packet, NULL);
            if (status < 0)
                goto done;
        }
        if (expected != stream->duration)
            goto fallback;
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

MPProbeResult *mp_probe_read(const char *path, MPProbeCancelled cancelled, void *context,
                            char *error, size_t error_capacity)
{
    AVFormatContext *file = avformat_alloc_context();
    AVPacket *packet = NULL;
    MPProbeResult *result = NULL;
    MPMOVIndex mov_index = {.fd = -1};
    int status = AVERROR(ENOMEM);
    if (!file)
        goto fail;
    file->interrupt_callback = (AVIOInterruptCB){.callback = cancelled, .opaque = context};
    status = avformat_open_input(&file, path, NULL, NULL);
    if (status < 0)
        goto fail;
    AVStream *prores = NULL;
    if (prores_index_candidate(file, &prores)) {
        describe_pcm_bit_depths(file);
        if (mp_mov_open_index(path, file, &mov_index) && !describe_prores_header(&mov_index, prores)) {
            close(mov_index.fd);
            mov_index.fd = -1;
        }
    }
    if (needs_stream_analysis(file)) {
        status = av_opt_set(file, "codec_whitelist", MPCUT_PROBE_DECODERS, 0);
        if (status < 0)
            goto fail;
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
    for (int i = 0; i < result->stream_count; i++) {
        AVStream *stream = file->streams[i];
        status = describe_stream(file, stream, &result->streams[i]);
        if (status < 0)
            goto fail;
        enum AVMediaType type = stream->codecpar->codec_type;
        if (type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            if (result->video_index == -1)
                result->video_index = i;
            else
                issue(result, "Multiple video tracks are unsupported.");
            if (raw_video(stream->codecpar, result->format))
                issue(result, "RAW video is unsupported.");
        } else if (type == AVMEDIA_TYPE_DATA && stream->codecpar->codec_tag == MKTAG('t', 'm', 'c', 'd') &&
                   av_match_name("mov", file->iformat->name) && !timecode) {
            timecode = true;
        } else if (type != AVMEDIA_TYPE_AUDIO) {
            issue(result, "The file contains an unsupported auxiliary, subtitle, or data track.");
        }
    }
    if (result->video_index == -1) {
        status = AVERROR_STREAM_NOT_FOUND;
        goto fail;
    }
    AVCodecParameters *video_params = file->streams[result->video_index]->codecpar;
    bool prores_video = video_params->codec_id == AV_CODEC_ID_PRORES;
    bool needs_video_header = video_params->format < 0 &&
                              (prores_video || mp_has_header_probe(video_params->codec_id));
    status = indexed_prores(&mov_index, file, result, cancelled, context);
    if (status < 0)
        goto fail;
    MPDescriptionShape first_description = {0};
    while (status == 0) {
        if (cancelled && cancelled(context)) {
            status = AVERROR_EXIT;
            goto fail;
        }
        status = av_read_frame(file, packet);
        if (status < 0)
            break;
        if (needs_video_header && packet->stream_index == result->video_index &&
            (prores_video ? read_prores_header(video_params, packet->data, packet->size) :
             (packet->flags & AV_PKT_FLAG_KEY) && mp_read_video_header(video_params, packet))) {
            update_header_description(&result->streams[result->video_index], video_params);
            needs_video_header = false;
        }
        if (packet->stream_index < result->stream_count)
            status = record_packet(result, file->streams[packet->stream_index]->codecpar, packet, &first_description);
        else
            issue(result, "The source introduces a track after its stream headers.");
        av_packet_unref(packet);
        if (status < 0)
            goto fail;
    }
    if (status != AVERROR_EOF && status != 1)
        goto fail;
    if (needs_video_header)
        issue(result, "The video codec headers do not identify the pixel format.");
    status = build_video_index(result);
    if (status < 0)
        goto fail;
    av_packet_free(&packet);
    avformat_close_input(&file);
    if (mov_index.fd >= 0)
        close(mov_index.fd);
    return result;

fail:
    if (error && error_capacity)
        av_strerror(status, error, error_capacity);
    av_packet_free(&packet);
    avformat_close_input(&file);
    if (mov_index.fd >= 0)
        close(mov_index.fd);
    mp_probe_free(result);
    return NULL;
}
