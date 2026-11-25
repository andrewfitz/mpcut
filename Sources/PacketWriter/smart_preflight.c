#include "PacketWriter.h"
#include "splice_headers.h"
#include "FFPreviewDecoder.h"

#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

/* Plan-time version of the two Smart Trim refusals an export meets only while it writes:
 * a copied avc3/hev1 sample that carries parameter sets (mpcut_splice_check_copy), and an
 * edge picture whose decoded frame carries metadata a re-encode would drop
 * (edge_metadata_supported in FFPreviewDecoder.c). The frame metadata is predicted from the
 * coded packets the way libavcodec attaches it, so nothing is decoded. Edges whose pictures a
 * player would add film grain to are written, with a note that they lose it. */

enum { REFUSED_NONE, REFUSED_PARAMETER_SETS, REFUSED_SAMPLE, REFUSED_METADATA };

typedef struct {
    enum AVCodecID codec;
    int length_size;
    bool picture_seen;  /* HEVC: a picture was decoded since the decoder began. */
    int mastering;      /* HEVC: libavcodec's persistence counters for SEI 137 and 144. */
    int light;
    bool ambient;       /* HEVC: SEI 148 persists until the decoder is flushed. */
    bool av1_hdr;       /* AV1: MDCV and CLL metadata persist until the decoder is flushed. */
    bool sequence;      /* H.264: SEI 137, 144 or 148 since the last keyframe (FFPreviewDecoder.c). */
    bool unit_sequence; /* H.264: the current access unit carries one of them. */
    bool unit_key;      /* H.264: the current access unit has a recovery point with no frame count. */
    bool grain;         /* Film grain a decoder would synthesize: H.274 or AOM SEI since the last cancel,
                         * or an AV1 sequence header with film grain parameters. */
    bool kept;          /* H.264/HEVC: a sample since the edge's keyframe carried SEI an encode drops
                         * (mp_preview_sample_keeps_sei): frame packing, orientation, time code, AFD and so on. */
} DecoderState;

static size_t unescape(const uint8_t *in, size_t size, uint8_t *out)
{
    size_t n = 0, zeros = 0;
    for (size_t i = 0; i < size; i++) {
        if (zeros >= 2 && in[i] == 3) {
            zeros = 0;
            continue;
        }
        zeros = in[i] ? 0 : zeros + 1;
        out[n++] = in[i];
    }
    return n;
}

/* ITU-T T.35 payloads that libavcodec turns into captions, HDR10+, HDR Vivid or, in AV1,
 * Dolby Vision frame metadata (libavcodec/itut35.c). */
static bool refused_t35(const uint8_t *data, size_t size, bool av1)
{
    if (size < 1)
        return false;
    unsigned country = data[0];
    data++, size--;
    if (country == 0xB5 && size >= 2) {
        unsigned provider = AV_RB16(data);
        data += 2, size -= 2;
        if (provider == 0x0031 && size >= 4 && AV_RB32(data) == MKBETAG('G', 'A', '9', '4')) {
            data += 4, size -= 4;
            // ff_parse_a53_cc: cc_data with process_cc_data_flag and at least one construct.
            return size >= 3 && data[0] == 3 && (data[1] & 0x40) && (data[1] & 0x1F) &&
                   (size_t)(data[1] & 0x1F) * 3 < size - 3;
        }
        if (provider == 0x003C)
            return size >= 3 && AV_RB16(data) == 1 && data[2] == 4;
        if (provider == 0x003B)
            return av1 && size >= 4 && AV_RB32(data) == 0x800;
        return false;
    }
    if (country == 0x26 && size >= 4)
        return AV_RB16(data) == 0x0004 && AV_RB16(data + 2) == 0x0005;
    return false;
}

/* AOM film grain (AFGS1) in an ITU-T T.35 payload, which libavcodec's HEVC decoder applies (libavcodec/itut35.c). */
static bool aom_grain_t35(const uint8_t *data, size_t size)
{
    return size >= 4 && data[0] == 0xB5 && AV_RB16(data + 1) == 0x5890 && data[3] == 0x01;
}

/* Walk the messages of one SEI RBSP. */
static bool sei_refused(DecoderState *state, const uint8_t *rbsp, size_t size)
{
    bool hevc = state->codec == AV_CODEC_ID_HEVC;
    bool refused = false;
    size_t pos = 0;
    while (pos + 2 <= size && !(size - pos == 1 && rbsp[pos] == 0x80)) {
        unsigned type = 0, length = 0;
        while (pos < size && rbsp[pos] == 0xFF)
            type += rbsp[pos++];
        if (pos >= size)
            break;
        type += rbsp[pos++];
        while (pos < size && rbsp[pos] == 0xFF)
            length += rbsp[pos++];
        if (pos >= size)
            break;
        length += rbsp[pos++];
        if (length > size - pos)
            break;
        const uint8_t *payload = rbsp + pos;
        pos += length;
        switch (type) {
        case 4:
            refused |= refused_t35(payload, length, false);
            state->grain |= hevc && aom_grain_t35(payload, length);
            break;
        case 19:
            // film_grain_characteristics_cancel_flag is the first bit.
            if (length > 0)
                state->grain = !(payload[0] & 0x80);
            break;
        case 6:
            // recovery_frame_cnt is ue(v): zero is a single 1 bit. libavcodec marks that picture a keyframe.
            if (!hevc && length > 0 && (payload[0] & 0x80))
                state->unit_key = true;
            break;
        case 137:
            // libavcodec reads the colour volume only from a complete payload.
            if (length < 24)
                break;
            if (hevc) state->mastering = 2; else state->unit_sequence = true;
            break;
        case 144:
            if (length < 4)
                break;
            if (hevc) state->light = 2; else state->unit_sequence = true;
            break;
        case 148:
            if (length < 8)
                break;
            if (hevc) state->ambient = true; else state->unit_sequence = true;
            break;
        default:
            break;
        }
    }
    return refused;
}

/* One length-prefixed AVC/HEVC sample in decode order. Returns whether its picture carries
 * refused metadata, updating the decoder's persistent SEI state first. */
static bool h26x_refused(DecoderState *state, const uint8_t *data, int size)
{
    bool hevc = state->codec == AV_CODEC_ID_HEVC;
    bool refused = false;
    bool picture = false;
    bool idr = false;
    int index = 0;
    state->unit_sequence = state->unit_key = false;
    for (int pos = 0; pos + state->length_size <= size; index++) {
        uint32_t length = 0;
        for (int i = 0; i < state->length_size; i++)
            length = length << 8 | data[pos++];
        if (length < (hevc ? 2U : 1U) || length > (uint32_t)(size - pos))
            break;
        const uint8_t *nal = data + pos;
        pos += (int)length;
        int type = hevc ? nal[0] >> 1 & 63 : nal[0] & 31;
        idr |= !hevc && type == 5;
        if (hevc ? type == 39 : type == 6) {
            int header = hevc ? 2 : 1;
            uint8_t *rbsp = av_malloc(length);
            if (!rbsp)
                return true;
            size_t rbsp_size = unescape(nal + header, length - header, rbsp);
            refused |= sei_refused(state, rbsp, rbsp_size);
            av_free(rbsp);
        } else if (hevc && type == 62) {
            // A Dolby Vision RPU after the first NAL, in the base layer at temporal level 0.
            int layer = (nal[0] & 1) << 5 | nal[1] >> 3;
            refused |= index > 0 && length > 2 && layer == 0 && (nal[1] & 7) == 1;
        } else if (hevc && type < 32 && !picture && length > 2 && (nal[2] & 0x80)) {
            // The first slice of a picture. An IDR or BLA picture, and a CRA picture that
            // starts decoding, end a coded video sequence: libavcodec counts down there.
            picture = true;
            bool ends_sequence = (type >= 16 && type <= 20) || (type == 21 && !state->picture_seen);
            if (ends_sequence) {
                if (state->mastering > 0) state->mastering--;
                if (state->light > 0) state->light--;
            }
            state->picture_seen = true;
        }
    }
    if (hevc) {
        refused |= state->mastering > 0 || state->light > 0 || state->ambient;
    } else {
        // These SEI describe the whole coded sequence, which the edge's new IDR would restart without them.
        state->sequence = idr || state->unit_key ? state->unit_sequence : state->sequence || state->unit_sequence;
        refused |= state->sequence;
    }
    return refused;
}

static bool leb128(const uint8_t *data, size_t size, size_t *pos, uint64_t *value)
{
    *value = 0;
    for (unsigned shift = 0; shift < 56; shift += 7) {
        if (*pos >= size)
            return false;
        uint8_t byte = data[(*pos)++];
        *value |= (uint64_t)(byte & 127) << shift;
        if (!(byte & 128))
            return true;
    }
    return false;
}

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t pos; /* In bits. */
    bool overrun;
} BitReader;

static uint32_t read_bits(BitReader *reader, unsigned count)
{
    uint32_t value = 0;
    for (unsigned i = 0; i < count; i++) {
        if (reader->pos >= reader->size * 8) {
            reader->overrun = true;
            return 0;
        }
        value = value << 1 | (reader->data[reader->pos >> 3] >> (7 - (reader->pos & 7)) & 1);
        reader->pos++;
    }
    return value;
}

/* film_grain_params_present of an AV1 sequence header OBU payload (AV1 specification 5.5),
 * or -1 when the header ends early. */
static int av1_sequence_grain(const uint8_t *data, size_t size)
{
    BitReader b = {.data = data, .size = size};
    unsigned profile = read_bits(&b, 3);
    read_bits(&b, 1); // still_picture
    bool reduced = read_bits(&b, 1);
    if (reduced) {
        read_bits(&b, 5); // seq_level_idx[0]
    } else {
        bool decoder_model = false;
        unsigned delay_length = 0;
        if (read_bits(&b, 1)) { // timing_info_present_flag
            read_bits(&b, 32);
            read_bits(&b, 32);
            if (read_bits(&b, 1)) { // equal_picture_interval: num_ticks_per_picture_minus_1 is uvlc()
                unsigned zeros = 0;
                while (!b.overrun && !read_bits(&b, 1))
                    zeros++;
                if (zeros < 32)
                    read_bits(&b, zeros);
            }
            decoder_model = read_bits(&b, 1);
            if (decoder_model) {
                delay_length = read_bits(&b, 5) + 1;
                read_bits(&b, 32);
                read_bits(&b, 10); // buffer_removal_time_length_minus_1, frame_presentation_time_length_minus_1
            }
        }
        bool display_delay = read_bits(&b, 1);
        unsigned points = read_bits(&b, 5) + 1;
        for (unsigned i = 0; i < points && !b.overrun; i++) {
            read_bits(&b, 12); // operating_point_idc
            if (read_bits(&b, 5) > 7)
                read_bits(&b, 1); // seq_tier
            if (decoder_model && read_bits(&b, 1)) {
                read_bits(&b, delay_length);
                read_bits(&b, delay_length);
                read_bits(&b, 1);
            }
            if (display_delay && read_bits(&b, 1))
                read_bits(&b, 4);
        }
    }
    unsigned width_bits = read_bits(&b, 4) + 1, height_bits = read_bits(&b, 4) + 1;
    read_bits(&b, width_bits);
    read_bits(&b, height_bits);
    if (!reduced && read_bits(&b, 1)) { // frame_id_numbers_present_flag
        read_bits(&b, 4);
        read_bits(&b, 3);
    }
    read_bits(&b, 3); // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
    if (!reduced) {
        read_bits(&b, 4); // enable_interintra_compound, masked_compound, warped_motion, dual_filter
        bool order_hint = read_bits(&b, 1);
        if (order_hint)
            read_bits(&b, 2); // enable_jnt_comp, enable_ref_frame_mvs
        unsigned screen_content = read_bits(&b, 1) ? 2 : read_bits(&b, 1);
        if (screen_content && !read_bits(&b, 1)) // seq_choose_integer_mv
            read_bits(&b, 1);                    // seq_force_integer_mv
        if (order_hint)
            read_bits(&b, 3);
    }
    read_bits(&b, 3); // enable_superres, enable_cdef, enable_restoration
    // color_config()
    bool high_bitdepth = read_bits(&b, 1);
    bool twelve_bit = profile == 2 && high_bitdepth && read_bits(&b, 1);
    bool mono_chrome = profile != 1 && read_bits(&b, 1);
    unsigned primaries = 2, transfer = 2, matrix = 2;
    if (read_bits(&b, 1)) {
        primaries = read_bits(&b, 8);
        transfer = read_bits(&b, 8);
        matrix = read_bits(&b, 8);
    }
    if (mono_chrome) {
        read_bits(&b, 1); // color_range
    } else {
        if (!(primaries == 1 && transfer == 13 && matrix == 0)) {
            read_bits(&b, 1); // color_range
            bool x = profile == 0 || (profile == 2 && !twelve_bit), y = profile == 0;
            if (profile == 2 && twelve_bit) {
                x = read_bits(&b, 1);
                y = x && read_bits(&b, 1);
            }
            if (x && y)
                read_bits(&b, 2); // chroma_sample_position
        }
        read_bits(&b, 1); // separate_uv_delta_q
    }
    unsigned grain = read_bits(&b, 1);
    return b.overrun ? -1 : (int)grain;
}

static bool av1_refused(DecoderState *state, const uint8_t *data, size_t size)
{
    bool refused = false;
    for (size_t pos = 0; pos < size;) {
        uint8_t header = data[pos++];
        if (header & 0x80)
            break;
        if (header & 4)
            pos++;
        uint64_t length = size - FFMIN(pos, size);
        if ((header & 2) && !leb128(data, size, &pos, &length))
            break;
        if (pos > size || length > size - pos)
            break;
        unsigned type = header >> 3 & 15;
        if (type == 1) {
            int grain = av1_sequence_grain(data + pos, (size_t)length);
            if (grain >= 0)
                state->grain = grain;
        } else if (type == 5) {
            size_t at = pos;
            uint64_t kind;
            if (leb128(data, pos + length, &at, &kind)) {
                if (kind == 1 || kind == 2)
                    state->av1_hdr = true;
                else if (kind == 4)
                    refused |= refused_t35(data + at, pos + length - at, true);
            }
        }
        pos += length;
    }
    return refused || state->av1_hdr;
}

static bool packet_side_data_refused(const AVPacket *packet)
{
    static const enum AVPacketSideDataType refused[] = {
        AV_PKT_DATA_A53_CC, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
        AV_PKT_DATA_ICC_PROFILE, AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT, AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
    };
    for (size_t i = 0; i < sizeof(refused) / sizeof(*refused); i++)
        if (av_packet_get_side_data(packet, refused[i], NULL))
            return true;
    return false;
}

/* Metadata libavcodec attaches to every decoded frame: container-level colour volume, light
 * level, ICC profile and viewing environment, and SEI carried in an hvcC record. */
static bool stream_metadata_refused(const AVCodecParameters *codec)
{
    static const enum AVPacketSideDataType refused[] = {
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA, AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
        AV_PKT_DATA_ICC_PROFILE, AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT,
    };
    for (size_t i = 0; i < sizeof(refused) / sizeof(*refused); i++)
        if (av_packet_side_data_get(codec->coded_side_data, codec->nb_coded_side_data, refused[i]))
            return true;
    const uint8_t *extra = codec->extradata;
    int size = codec->extradata_size;
    if (codec->codec_id != AV_CODEC_ID_HEVC || size < 23 || extra[0] != 1)
        return false;
    DecoderState state = {.codec = AV_CODEC_ID_HEVC, .length_size = 2};
    int pos = 23;
    for (int array = 0; array < extra[22]; array++) {
        if (pos + 3 > size)
            return false;
        int count = AV_RB16(extra + pos + 1);
        pos += 3;
        for (int i = 0; i < count; i++) {
            if (pos + 2 > size)
                return false;
            int length = AV_RB16(extra + pos);
            if (length > size - pos - 2)
                return false;
            // Each NAL is parsed on its own, with the same two-byte length in front.
            if ((extra[pos + 2] >> 1 & 63) == 39) {
                DecoderState sei = state;
                if (h26x_refused(&sei, extra + pos, length + 2) || sei.mastering || sei.light || sei.ambient)
                    return true;
            }
            pos += 2 + length;
        }
    }
    return false;
}

typedef struct {
    AVFormatContext *input;
    const AVStream *video;
    AVPacket *packet;
    MPCutProgress progress;
    void *context;
    unsigned steps;
} Reader;

static int64_t ticks(MPCutTime origin, MPCutTime time, AVRational base)
{
    // The writer's rounding (time_round in writer.c) of origin + time on the stream clock.
    __int128 numerator = (__int128)origin.numerator * time.denominator + (__int128)time.numerator * origin.denominator;
    __int128 denominator = (__int128)origin.denominator * time.denominator;
    __int128 n = numerator * base.den, d = denominator * base.num;
    if (d <= 0)
        return AV_NOPTS_VALUE;
    __int128 rounded = n < 0 ? n - d / 2 : n + d / 2;
    __int128 value = rounded / d;
    return value <= INT64_MIN || value > INT64_MAX ? AV_NOPTS_VALUE : (int64_t)value;
}

/* Reads the next video packet. Returns 1 for a packet, 0 at the end, 2 when cancelled. */
static int next_video(Reader *reader)
{
    for (;;) {
        av_packet_unref(reader->packet);
        if ((++reader->steps & 255) == 0 && reader->progress && reader->progress(reader->context, 0))
            return 2;
        int code = av_read_frame(reader->input, reader->packet);
        if (code == AVERROR_EOF)
            return 0;
        if (code < 0)
            return code;
        if (reader->packet->stream_index == reader->video->index)
            return 1;
    }
}

static int seek_to(Reader *reader, int64_t pts)
{
    return av_seek_frame(reader->input, reader->video->index, pts, AVSEEK_FLAG_BACKWARD);
}

/* The decoded pictures of one edge, from its keyframe up to its last picture. Sets grain when
 * a decoder would synthesize film grain on one of them, which the re-encoded edge cannot carry. */
static int check_edge(Reader *reader, const MPCutEdgeRange *edge, MPCutTime origin, int64_t *refused_pts, bool *grain)
{
    AVRational base = reader->video->time_base;
    int64_t decode_from = ticks(origin, edge->decode_from, base);
    int64_t from = ticks(origin, edge->from, base), to = ticks(origin, edge->to, base);
    if (decode_from == AV_NOPTS_VALUE || from == AV_NOPTS_VALUE || to == AV_NOPTS_VALUE)
        return AVERROR(EINVAL);
    const AVCodecParameters *codec = reader->video->codecpar;
    DecoderState state = {.codec = codec->codec_id};
    if (codec->codec_id == AV_CODEC_ID_H264 || codec->codec_id == AV_CODEC_ID_HEVC) {
        int offset = codec->codec_id == AV_CODEC_ID_HEVC ? 21 : 4;
        if (codec->extradata_size <= offset || codec->extradata[0] != 1)
            return 0; // Smart Trim planning accepts only length-prefixed samples.
        state.length_size = (codec->extradata[offset] & 3) + 1;
    } else if (codec->codec_id == AV_CODEC_ID_AV1 && codec->extradata_size > 4 && (codec->extradata[0] & 0x80)) {
        // The av1C record's configOBUs carry the sequence header in force before an in-band one.
        DecoderState config = state;
        av1_refused(&config, codec->extradata + 4, (size_t)codec->extradata_size - 4);
        state.grain = config.grain;
    }
    int code = seek_to(reader, decode_from);
    if (code < 0)
        return code;
    bool started = false;
    size_t found = 0;
    while (found < edge->frame_count && (code = next_video(reader)) == 1) {
        const AVPacket *packet = reader->packet;
        // Decode times never decrease, so no edge picture follows one decoded at or after the end.
        if (packet->dts != AV_NOPTS_VALUE && packet->dts >= to)
            break;
        if (!started) {
            // The export's decoder starts at the edge's keyframe, after the seek.
            if (packet->pts != decode_from && !(packet->pts > decode_from && (packet->flags & AV_PKT_FLAG_KEY)))
                continue;
            started = true;
        }
        bool refused = packet_side_data_refused(packet);
        if (codec->codec_id == AV_CODEC_ID_AV1) {
            refused |= av1_refused(&state, packet->data, packet->size);
        } else {
            refused |= h26x_refused(&state, packet->data, packet->size);
            // The edge decoder refuses every picture decoded from such a sample on (FFPreviewDecoder.c).
            state.kept |= mp_preview_sample_keeps_sei(codec->codec_id, state.length_size, packet->data, packet->size);
            refused |= state.kept;
        }
        if (packet->pts >= from && packet->pts < to) {
            found++;
            *grain |= state.grain;
            if (refused) {
                *refused_pts = packet->pts;
                return 0;
            }
        }
    }
    return code < 0 || code == 2 ? code : 0;
}

/* Copied samples of a range: in range by presentation time, outside both edges. */
static int check_copies(Reader *reader, const MPCutSegment *segment, MPCutTime origin, int *refusal)
{
    AVRational base = reader->video->time_base;
    int64_t start = ticks(origin, segment->start, base), end = ticks(origin, segment->end, base);
    const MPCutEdgeRange *edges[] = {&segment->head_edge, &segment->tail_edge};
    int64_t edge_from[2], edge_to[2];
    for (int i = 0; i < 2; i++) {
        edge_from[i] = edges[i]->frame_count ? ticks(origin, edges[i]->from, base) : 0;
        edge_to[i] = edges[i]->frame_count ? ticks(origin, edges[i]->to, base) : 0;
    }
    if (start == AV_NOPTS_VALUE || end == AV_NOPTS_VALUE)
        return AVERROR(EINVAL);
    const AVCodecParameters *codec = reader->video->codecpar;
    const uint8_t *extra = codec->extradata;
    int extra_size = codec->extradata_size;
    uint8_t *active = NULL;
    int code = seek_to(reader, start);
    if (code < 0)
        return code;
    while ((code = next_video(reader)) == 1) {
        const AVPacket *packet = reader->packet;
        size_t size = 0;
        const uint8_t *config = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
        if (config && size > 0 && size <= INT_MAX) {
            av_free(active);
            active = av_memdup(config, size);
            if (!active)
                return AVERROR(ENOMEM);
            extra = active;
            extra_size = (int)size;
        }
        // Decode times never decrease, so no later sample presents before the end.
        if (packet->dts != AV_NOPTS_VALUE && packet->dts >= end)
            break;
        int64_t pts = packet->pts;
        if (pts == AV_NOPTS_VALUE || pts < start || pts >= end)
            continue;
        bool edge = false;
        for (int i = 0; i < 2; i++)
            edge |= edges[i]->frame_count && pts >= edge_from[i] && pts < edge_to[i];
        if (edge)
            continue;
        int check = mpcut_splice_check_copy(packet, codec, extra, extra_size);
        if (check < 0) {
            *refusal = check == AVERROR(ENOTSUP) ? REFUSED_PARAMETER_SETS : REFUSED_SAMPLE;
            break;
        }
    }
    av_free(active);
    return code < 0 || code == 2 ? code : 0;
}

/* One sentence per source whose edges lose film grain synthesis. The edge decoder hands the encoder
 * pictures without the grain (VideoToolbox ignores H.274 SEI) or with it baked in (VideoToolbox
 * applies AV1 grain, which the bit budget of an inter edge picture mostly smooths away). Either way
 * the re-encoded pictures carry no grain parameters, so a player synthesizes no grain on them. */
static void note_grain(char *notes, size_t capacity, const char *path)
{
    if (!notes || !capacity)
        return;
    const char *slash = strrchr(path, '/');
    char sentence[1024];
    snprintf(sentence, sizeof(sentence), "The pictures Smart Trim re-encodes in %s carry no film grain parameters, "
             "so a player that synthesizes film grain adds none to them.", slash ? slash + 1 : path);
    size_t used = strlen(notes), separator = used ? 1 : 0;
    // Only whole sentences, each once.
    if (strstr(notes, sentence) || used + separator + strlen(sentence) >= capacity)
        return;
    snprintf(notes + used, capacity - used, "%s%s", separator ? "\n" : "", sentence);
}

int mpcut_check_smart_trim(const MPCutSegment *segments, size_t count, size_t *failed_segment,
                           MPCutProgress progress, void *context, char *error, size_t capacity,
                           char *notes, size_t notes_capacity)
{
    if (failed_segment)
        *failed_segment = 0;
    if (error && capacity)
        error[0] = '\0';
    if (notes && notes_capacity)
        notes[0] = '\0';
    bool encodes = false;
    for (size_t i = 0; i < count; i++)
        encodes |= segments[i].head_edge.frame_count || segments[i].tail_edge.frame_count;
    if (!encodes)
        return 0;
    Reader reader = {.progress = progress, .context = context, .packet = av_packet_alloc()};
    if (!reader.packet)
        return 1;
    int result = 0;
    for (size_t index = 0; index < count && !result; index++) {
        const MPCutSegment *segment = &segments[index];
        reader.input = NULL;
        int code = avformat_open_input(&reader.input, segment->path, NULL, NULL);
        const AVStream *video = NULL;
        for (unsigned i = 0; code >= 0 && i < reader.input->nb_streams && !video; i++) {
            const AVStream *stream = reader.input->streams[i];
            if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC))
                video = stream;
        }
        if (code < 0 || !video) {
            if (error && capacity)
                snprintf(error, capacity, "Cannot read the video samples of %s to plan Smart Trim.", segment->path);
            result = 1;
        } else {
            reader.video = video;
            for (unsigned i = 0; i < reader.input->nb_streams; i++)
                reader.input->streams[i]->discard = i == (unsigned)video->index ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
            MPCutTime origin = segment->source_origin.denominator > 0 ? segment->source_origin
                : (MPCutTime){video->start_time == AV_NOPTS_VALUE ? 0 : video->start_time * video->time_base.num,
                              video->time_base.den};
            const AVCodecParameters *codec = video->codecpar;
            const MPCutEdgeRange *edges[] = {&segment->head_edge, &segment->tail_edge};
            bool metadata = false, grain = false;
            for (int i = 0; i < 2 && code >= 0 && code != 2 && !metadata; i++) {
                if (!edges[i]->frame_count)
                    continue;
                double seconds = (double)edges[i]->from.numerator / edges[i]->from.denominator;
                int64_t pts = AV_NOPTS_VALUE;
                metadata = stream_metadata_refused(codec);
                if (!metadata) {
                    code = check_edge(&reader, edges[i], origin, &pts, &grain);
                    metadata = pts != AV_NOPTS_VALUE;
                    if (metadata)
                        seconds = (double)pts * video->time_base.num / video->time_base.den -
                                  (double)origin.numerator / origin.denominator;
                }
                if (metadata && error && capacity)
                    snprintf(error, capacity, "The picture at %.3f s, which Smart Trim would re-encode, carries embedded captions "
                             "or colour metadata, or stereo, orientation, time code or active format signalling, that requires "
                             "copying. Choose a verified boundary, or re-encode.", seconds);
            }
            int refusal = REFUSED_NONE;
            bool inband = (codec->codec_id == AV_CODEC_ID_H264 && codec->codec_tag == MKTAG('a', 'v', 'c', '3')) ||
                          (codec->codec_id == AV_CODEC_ID_HEVC && codec->codec_tag == MKTAG('h', 'e', 'v', '1'));
            if (!metadata && inband && code >= 0 && code != 2)
                code = check_copies(&reader, segment, origin, &refusal);
            if (code == 2) {
                result = 2;
            } else if (code < 0) {
                if (error && capacity)
                    snprintf(error, capacity, "Cannot read the video samples of %s to plan Smart Trim: %s",
                             segment->path, av_err2str(code));
                result = 1;
            } else if (metadata || refusal != REFUSED_NONE) {
                if (refusal == REFUSED_PARAMETER_SETS && error && capacity)
                    snprintf(error, capacity, "Samples that Smart Trim would copy carry in-band parameter sets, which an avc1 or "
                             "hvc1 track cannot keep. Choose verified boundaries with Lossless Copy, or re-encode.");
                else if (refusal == REFUSED_SAMPLE && error && capacity)
                    snprintf(error, capacity, "A video sample that Smart Trim would copy is invalid for its decoder configuration.");
                result = 1;
            } else if (grain) {
                note_grain(notes, notes_capacity, segment->path);
            }
        }
        if (result == 1 && failed_segment)
            *failed_segment = index + 1;
        avformat_close_input(&reader.input);
    }
    av_packet_free(&reader.packet);
    return result;
}
