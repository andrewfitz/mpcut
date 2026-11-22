#include "codec_header.h"

#include <libavcodec/avcodec.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/pixdesc.h>
#include <stdio.h>

/* MOV H.26x samples are length-prefixed. Transport streams use Annex B. */
bool mp_h26x_random_access(const AVPacket *packet, const AVCodecParameters *params, bool source_start, int *multilayer)
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
        if (hevc && mp_hevc_multilayer_unit(bytes + i, unit_end - i))
            *multilayer = 1;
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

typedef struct {
    const uint8_t *data;
    size_t size, position;
    bool invalid;
} BitReader;

static unsigned read_bits(BitReader *bits, unsigned count)
{
    if (bits->size * 8 - bits->position < count) {
        bits->invalid = true;
        return 0;
    }
    unsigned value = 0;
    for (unsigned i = 0; i < count; i++) {
        size_t position = bits->position++;
        value = (value << 1) | ((bits->data[position / 8] >> (7 - position % 8)) & 1);
    }
    return value;
}

static unsigned ue(BitReader *bits)
{
    unsigned zeros = 0;
    while (!read_bits(bits, 1)) {
        if (bits->invalid || zeros == 30) {
            bits->invalid = true;
            return 0;
        }
        zeros++;
    }
    return (1u << zeros) - 1 + read_bits(bits, zeros);
}

static int se(BitReader *bits)
{
    unsigned code = ue(bits);
    return (code & 1) ? (int)(code / 2 + 1) : -(int)(code / 2);
}

static enum AVPixelFormat planar_format(const char *name, unsigned depth)
{
    if (depth == 8)
        return av_get_pix_fmt(name);
    char format[20];
    snprintf(format, sizeof(format), "%s%ule", name, depth);
    return av_get_pix_fmt(format);
}

static enum AVPixelFormat yuv_format(unsigned chroma, unsigned depth)
{
    static const char *const names[] = {"gray", "yuv420p", "yuv422p", "yuv444p", "yuv440p"};
    if (chroma >= FF_ARRAY_ELEMS(names))
        return AV_PIX_FMT_NONE;
    return planar_format(names[chroma], depth);
}

static bool avc_extended_sps(unsigned profile)
{
    switch (profile) {
    case 44: case 83: case 86: case 100: case 110: case 118: case 122:
    case 128: case 134: case 135: case 138: case 139: case 144: case 244:
        return true;
    default:
        return false;
    }
}

static void avc_scaling_lists(BitReader *bits, unsigned count)
{
    for (unsigned i = 0; i < count; i++) {
        if (!read_bits(bits, 1))
            continue;
        unsigned previous = 8, next = 8;
        for (unsigned n = 0; n < (i < 6 ? 16u : 64u); n++) {
            if (next)
                next = (previous + se(bits)) & 255;
            if (next)
                previous = next;
        }
    }
}

static void read_vui_color(BitReader *bits, AVCodecParameters *params)
{
    // read_bits returns 0 past the end, and 0 is a valid color enum. Commit only a complete prefix.
    int range = AVCOL_RANGE_UNSPECIFIED;
    unsigned primaries = AVCOL_PRI_UNSPECIFIED, transfer = AVCOL_TRC_UNSPECIFIED, matrix = AVCOL_SPC_UNSPECIFIED;
    if (read_bits(bits, 1) && read_bits(bits, 8) == 255)
        read_bits(bits, 32);
    if (read_bits(bits, 1))
        read_bits(bits, 1);
    if (read_bits(bits, 1)) {
        read_bits(bits, 3);
        range = read_bits(bits, 1) ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
        if (read_bits(bits, 1)) {
            primaries = read_bits(bits, 8);
            transfer = read_bits(bits, 8);
            matrix = read_bits(bits, 8);
        }
    }
    unsigned top = 0; // Inferred as 0 when chroma_loc_info_present_flag is 0.
    if (read_bits(bits, 1)) {
        top = ue(bits);
        ue(bits); // chroma_sample_loc_type_bottom_field
    }
    if (bits->invalid)
        return;
    if (range != AVCOL_RANGE_UNSPECIFIED && params->color_range == AVCOL_RANGE_UNSPECIFIED)
        params->color_range = range;
    if (params->color_primaries == AVCOL_PRI_UNSPECIFIED && primaries != AVCOL_PRI_UNSPECIFIED &&
        av_color_primaries_name(primaries))
        params->color_primaries = primaries;
    if (params->color_trc == AVCOL_TRC_UNSPECIFIED && transfer != AVCOL_TRC_UNSPECIFIED &&
        av_color_transfer_name(transfer))
        params->color_trc = transfer;
    if (params->color_space == AVCOL_SPC_UNSPECIFIED && matrix != AVCOL_SPC_UNSPECIFIED &&
        av_color_space_name(matrix))
        params->color_space = matrix;
    if (top <= 5 && params->chroma_location == AVCHROMA_LOC_UNSPECIFIED)
        params->chroma_location = (enum AVChromaLocation)(top + 1);
}

static size_t unescape_rbsp(uint8_t *rbsp, const uint8_t *data, size_t length)
{
    size_t size = 0;
    unsigned zeros = 0;
    for (size_t i = 0; i < length; i++) {
        if (zeros >= 2 && data[i] == 3) {
            zeros = 0;
            continue;
        }
        rbsp[size++] = data[i];
        zeros = data[i] == 0 ? zeros + 1 : 0;
    }
    return size;
}

static bool read_avc_sps(AVCodecParameters *params, bool *may_interlace)
{
    if (params->extradata_size < 9 || params->extradata[0] != 1)
        return false;
    const uint8_t *data = params->extradata;
    if ((data[5] & 31) != 1)
        return false;
    unsigned length = AV_RB16(data + 6);
    if (length < 4 || length > (unsigned)(params->extradata_size - 8) || (data[8] & 31) != 7)
        return false;
    uint8_t rbsp[4096];
    if (length > sizeof(rbsp))
        return false;
    BitReader bits = {.data = rbsp, .size = unescape_rbsp(rbsp, data + 9, length - 1)};
    unsigned profile = read_bits(&bits, 8);
    unsigned constraints = read_bits(&bits, 8);
    read_bits(&bits, 8); // level_idc
    ue(&bits); // seq_parameter_set_id
    unsigned chroma = 1, depth = 8;
    if (avc_extended_sps(profile)) {
        chroma = ue(&bits);
        if (chroma > 3)
            return false;
        if (chroma == 3)
            read_bits(&bits, 1);
        depth = ue(&bits) + 8;
        ue(&bits); // bit_depth_chroma_minus8
        read_bits(&bits, 1); // qpprime_y_zero_transform_bypass_flag
        if (read_bits(&bits, 1))
            avc_scaling_lists(&bits, chroma == 3 ? 12 : 8);
    }
    ue(&bits); // log2_max_frame_num_minus4
    unsigned order_type = ue(&bits);
    if (!order_type) {
        ue(&bits);
    } else if (order_type == 1) {
        read_bits(&bits, 1);
        se(&bits);
        se(&bits);
        unsigned cycle = ue(&bits);
        if (cycle > 255)
            return false;
        for (unsigned i = 0; i < cycle; i++)
            se(&bits);
    } else if (order_type != 2) {
        return false;
    }
    ue(&bits); // max_num_ref_frames
    read_bits(&bits, 1); // gaps_in_frame_num_value_allowed_flag
    ue(&bits); // pic_width_in_mbs_minus1
    ue(&bits); // pic_height_in_map_units_minus1
    bool frame_only = read_bits(&bits, 1);
    if (!frame_only)
        read_bits(&bits, 1);
    read_bits(&bits, 1); // direct_8x8_inference_flag
    if (read_bits(&bits, 1)) {
        for (int i = 0; i < 4; i++)
            ue(&bits);
    }
    if (read_bits(&bits, 1))
        read_vui_color(&bits, params);
    if (bits.invalid)
        return false;
    if (params->color_range == AVCOL_RANGE_UNSPECIFIED)
        params->color_range = AVCOL_RANGE_MPEG;
    *may_interlace = !frame_only;
    if (frame_only && params->field_order == AV_FIELD_UNKNOWN)
        params->field_order = AV_FIELD_PROGRESSIVE;
    params->profile = profile;
    if (profile == 66 && (constraints & 0x40))
        params->profile |= AV_PROFILE_H264_CONSTRAINED;
    if ((profile == 110 || profile == 122 || profile == 244) && (constraints & 0x10))
        params->profile |= AV_PROFILE_H264_INTRA;
    params->format = chroma == 3 && params->color_space == AVCOL_SPC_RGB
        ? planar_format("gbrp", depth) : yuv_format(chroma, depth);
    return params->format != AV_PIX_FMT_NONE;
}

static void hevc_profile_tier_level(BitReader *bits, unsigned layers)
{
    for (int i = 0; i < 3; i++)
        read_bits(bits, 32);
    unsigned profiles = 0, levels = 0;
    for (unsigned i = 0; i < layers; i++) {
        profiles |= read_bits(bits, 1) << i;
        levels |= read_bits(bits, 1) << i;
    }
    if (layers)
        read_bits(bits, 2 * (8 - layers));
    for (unsigned i = 0; i < layers; i++) {
        if (profiles & (1u << i)) {
            read_bits(bits, 32);
            read_bits(bits, 32);
            read_bits(bits, 24);
        }
        if (levels & (1u << i))
            read_bits(bits, 8);
    }
}

static void hevc_scaling_lists(BitReader *bits)
{
    for (unsigned size = 0; size < 4; size++) {
        for (unsigned matrix = 0; matrix < 6; matrix += size == 3 ? 3 : 1) {
            if (!read_bits(bits, 1)) {
                ue(bits);
                continue;
            }
            if (size > 1)
                se(bits);
            for (unsigned coefficient = 0; coefficient < (size == 0 ? 16u : 64u); coefficient++)
                se(bits);
        }
    }
}

static bool hevc_reference_sets(BitReader *bits, unsigned poc_bits)
{
    unsigned sets = ue(bits);
    unsigned previous_refs = 0;
    if (sets > 64)
        return false;
    for (unsigned i = 0; i < sets; i++) {
        if (i && read_bits(bits, 1)) {
            read_bits(bits, 1); // delta_rps_sign
            ue(bits); // abs_delta_rps_minus1
            unsigned refs = 0;
            for (unsigned j = 0; j <= previous_refs; j++) {
                if (read_bits(bits, 1) || read_bits(bits, 1))
                    refs++;
            }
            previous_refs = refs;
        } else {
            unsigned negative = ue(bits);
            unsigned positive = ue(bits);
            if (negative > 16 || positive > 16)
                return false;
            previous_refs = negative + positive;
            for (unsigned j = 0; j < previous_refs; j++) {
                ue(bits); // delta_poc_s0_minus1 or delta_poc_s1_minus1
                read_bits(bits, 1); // used_by_curr_pic
            }
        }
        if (bits->invalid || previous_refs > 16)
            return false;
    }
    if (read_bits(bits, 1)) {
        unsigned refs = ue(bits);
        if (refs > 32)
            return false;
        for (unsigned i = 0; i < refs; i++)
            read_bits(bits, poc_bits + 1);
    }
    return !bits->invalid;
}

static bool hevc_vui(const uint8_t *sps, unsigned length, AVCodecParameters *params, bool *may_interlace)
{
    uint8_t rbsp[4096];
    if (length < 3 || length > sizeof(rbsp) || (sps[0] & 1) || (sps[1] & 0xf8))
        return false;
    BitReader bits = {.data = rbsp, .size = unescape_rbsp(rbsp, sps + 2, length - 2)};
    read_bits(&bits, 4); // sps_video_parameter_set_id
    unsigned layers = read_bits(&bits, 3);
    read_bits(&bits, 1);
    hevc_profile_tier_level(&bits, layers);
    ue(&bits); // sps_seq_parameter_set_id
    if (ue(&bits) == 3)
        read_bits(&bits, 1);
    ue(&bits); // width
    ue(&bits); // height
    if (read_bits(&bits, 1)) {
        for (int i = 0; i < 4; i++)
            ue(&bits);
    }
    ue(&bits); // bit_depth_luma_minus8
    ue(&bits); // bit_depth_chroma_minus8
    unsigned poc_bits = ue(&bits) + 4;
    if (poc_bits > 16)
        return false;
    for (unsigned i = read_bits(&bits, 1) ? 0 : layers; i <= layers; i++) {
        ue(&bits); // max_dec_pic_buffering_minus1
        ue(&bits); // max_num_reorder_pics
        ue(&bits); // max_latency_increase_plus1
    }
    for (int i = 0; i < 6; i++)
        ue(&bits); // coding/transform block dimensions and hierarchy depths
    if (read_bits(&bits, 1) && read_bits(&bits, 1))
        hevc_scaling_lists(&bits);
    read_bits(&bits, 2); // amp_enabled_flag and sample_adaptive_offset_enabled_flag
    if (read_bits(&bits, 1)) {
        read_bits(&bits, 8); // PCM bit depths
        ue(&bits); // log2_min_pcm_luma_coding_block_size_minus3
        ue(&bits); // log2_diff_max_min_pcm_luma_coding_block_size
        read_bits(&bits, 1);
    }
    if (!hevc_reference_sets(&bits, poc_bits))
        return false;
    read_bits(&bits, 2); // temporal_mvp_enabled_flag and strong_intra_smoothing_enabled_flag
    if (read_bits(&bits, 1)) {
        read_vui_color(&bits, params);
        read_bits(&bits, 1); // neutral_chroma_indication_flag
        if (read_bits(&bits, 1)) // field_seq_flag
            *may_interlace = true;
    }
    return !bits.invalid;
}

static void read_hevc_sps_color(AVCodecParameters *params, bool *may_interlace, int *multilayer)
{
    const uint8_t *bytes = params->extradata;
    const uint8_t *sps = NULL;
    unsigned sps_length = 0;
    size_t size = params->extradata_size;
    if (size < 23 || bytes[0] != 1)
        return;
    *may_interlace = !!(bytes[6] & 0x40); // general_interlaced_source_flag in hvcC
    size_t cursor = 23;
    for (unsigned array = 0; array < bytes[22]; array++) {
        if (size - cursor < 3)
            return;
        unsigned type = bytes[cursor] & 63;
        unsigned units = AV_RB16(bytes + cursor + 1);
        cursor += 3;
        for (unsigned i = 0; i < units; i++) {
            if (size - cursor < 2)
                return;
            unsigned length = AV_RB16(bytes + cursor);
            cursor += 2;
            if (length > size - cursor)
                return;
            if (mp_hevc_multilayer_unit(bytes + cursor, length))
                *multilayer = 1;
            if (type == 33) {
                if (sps)
                    return;
                sps = bytes + cursor;
                sps_length = length;
            }
            cursor += length;
        }
    }
    if (sps && hevc_vui(sps, sps_length, params, may_interlace) && params->color_range == AVCOL_RANGE_UNSPECIFIED)
        params->color_range = AVCOL_RANGE_MPEG;
}

static bool read_vp9_header(AVCodecParameters *params, const AVPacket *packet)
{
    static const enum AVColorSpace spaces[] = {
        AVCOL_SPC_UNSPECIFIED, AVCOL_SPC_BT470BG, AVCOL_SPC_BT709, AVCOL_SPC_SMPTE170M,
        AVCOL_SPC_SMPTE240M, AVCOL_SPC_BT2020_NCL, AVCOL_SPC_RESERVED, AVCOL_SPC_RGB
    };
    BitReader bits = {.data = packet->data, .size = (size_t)packet->size};
    if (read_bits(&bits, 2) != 2)
        return false;
    unsigned profile = read_bits(&bits, 1);
    profile |= read_bits(&bits, 1) << 1;
    if ((profile == 3 && read_bits(&bits, 1)) || read_bits(&bits, 1) || read_bits(&bits, 1))
        return false;
    read_bits(&bits, 2); // show_frame and error_resilient_mode
    if (read_bits(&bits, 24) != 0x498342)
        return false;
    unsigned depth = profile >= 2 ? (read_bits(&bits, 1) ? 12 : 10) : 8;
    enum AVColorSpace space = spaces[read_bits(&bits, 3)];
    enum AVColorRange range;
    enum AVPixelFormat format;
    if (space == AVCOL_SPC_RGB) {
        if (!(profile & 1) || read_bits(&bits, 1))
            return false;
        range = AVCOL_RANGE_JPEG;
        format = depth == 8 ? AV_PIX_FMT_GBRP : depth == 10 ? AV_PIX_FMT_GBRP10 : AV_PIX_FMT_GBRP12;
    } else {
        range = read_bits(&bits, 1) ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
        unsigned chroma = 1;
        if (profile & 1) {
            unsigned horizontal = read_bits(&bits, 1);
            unsigned vertical = read_bits(&bits, 1);
            if ((horizontal && vertical) || read_bits(&bits, 1))
                return false;
            chroma = horizontal ? 2 : vertical ? 4 : 3;
        }
        format = yuv_format(chroma, depth);
    }
    if (bits.invalid || format == AV_PIX_FMT_NONE)
        return false;
    if (params->color_space == AVCOL_SPC_UNSPECIFIED)
        params->color_space = space;
    if (params->color_range == AVCOL_RANGE_UNSPECIFIED)
        params->color_range = range;
    params->profile = profile;
    params->format = format;
    return true;
}

static bool read_with_parser(AVCodecParameters *params, const AVPacket *packet)
{
    AVCodecParserContext *parser = av_parser_init(params->codec_id);
    AVCodecContext *context = avcodec_alloc_context3(NULL);
    bool ready = false;
    if (parser && context && avcodec_parameters_to_context(context, params) >= 0) {
        parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
        uint8_t *output = NULL;
        int size = 0;
        int status = av_parser_parse2(parser, context, &output, &size, packet->data, packet->size,
                                      packet->pts, packet->dts, packet->pos);
        if (status >= 0 && parser->format != AV_PIX_FMT_NONE) {
            params->format = parser->format;
            if (params->field_order == AV_FIELD_UNKNOWN)
                params->field_order = parser->field_order;
            if (params->chroma_location == AVCHROMA_LOC_UNSPECIFIED)
                params->chroma_location = context->chroma_sample_location;
            if (!params->width)
                params->width = parser->width;
            if (!params->height)
                params->height = parser->height;
            if (params->profile == AV_PROFILE_UNKNOWN)
                params->profile = context->profile;
            if (params->color_range == AVCOL_RANGE_UNSPECIFIED)
                params->color_range = context->color_range;
            if (params->color_primaries == AVCOL_PRI_UNSPECIFIED)
                params->color_primaries = context->color_primaries;
            if (params->color_trc == AVCOL_TRC_UNSPECIFIED)
                params->color_trc = context->color_trc;
            if (params->color_space == AVCOL_SPC_UNSPECIFIED)
                params->color_space = context->colorspace;
            ready = true;
        }
    }
    av_parser_close(parser);
    avcodec_free_context(&context);
    return ready;
}

bool mp_has_header_probe(enum AVCodecID codec)
{
    return codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC || codec == AV_CODEC_ID_VP8 ||
           codec == AV_CODEC_ID_VP9 || codec == AV_CODEC_ID_AV1;
}

bool mp_read_video_header(AVCodecParameters *params, const AVPacket *packet, bool *may_interlace,
                          int *multilayer)
{
    switch (params->codec_id) {
    case AV_CODEC_ID_H264:
        if (read_avc_sps(params, may_interlace)) {
            if (*may_interlace && params->field_order == AV_FIELD_UNKNOWN)
                read_with_parser(params, packet);
            return true;
        }
        return read_with_parser(params, packet);
    case AV_CODEC_ID_HEVC:
        read_hevc_sps_color(params, may_interlace, multilayer);
        return read_with_parser(params, packet);
    case AV_CODEC_ID_AV1:
        return read_with_parser(params, packet);
    case AV_CODEC_ID_VP8:
        if (packet->size < 10 || (packet->data[0] & 1) || AV_RB24(packet->data + 3) != 0x9d012a)
            return false;
        params->profile = (packet->data[0] >> 1) & 7;
        params->format = AV_PIX_FMT_YUV420P;
        if (params->color_range == AVCOL_RANGE_UNSPECIFIED)
            params->color_range = AVCOL_RANGE_MPEG;
        return true;
    case AV_CODEC_ID_VP9:
        return read_vp9_header(params, packet);
    default:
        return false;
    }
}
