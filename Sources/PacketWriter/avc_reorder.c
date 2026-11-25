#include "avc_reorder.h"

#include <limits.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>

enum { MAX_DPB_FRAMES = 16 };

typedef struct {
    const uint8_t *data;
    size_t bits;
    size_t position;
    int error;
} Reader;

static unsigned read_bit(Reader *reader) {
    if (reader->position >= reader->bits) {
        reader->error = 1;
        return 0;
    }
    unsigned bit = reader->data[reader->position >> 3] >> (7 - (reader->position & 7)) & 1;
    reader->position++;
    return bit;
}

static uint32_t read_bits(Reader *reader, int count) {
    uint32_t value = 0;
    while (count-- > 0)
        value = value << 1 | read_bit(reader);
    return value;
}

static uint32_t read_ue(Reader *reader) {
    int zeros = 0;
    while (!read_bit(reader)) {
        if (reader->error || ++zeros > 31) {
            reader->error = 1;
            return 0;
        }
    }
    return (uint32_t)((1ULL << zeros) - 1 + read_bits(reader, zeros));
}

static void skip_hrd(Reader *reader) {
    uint32_t count = read_ue(reader) + 1;
    if (count > 32) {
        reader->error = 1;
        return;
    }
    read_bits(reader, 8); /* bit_rate_scale, cpb_size_scale */
    for (uint32_t i = 0; i < count && !reader->error; i++) {
        read_ue(reader); /* bit_rate_value_minus1 */
        read_ue(reader); /* cpb_size_value_minus1 */
        read_bit(reader); /* cbr_flag */
    }
    read_bits(reader, 20); /* four delay and offset lengths */
}

typedef struct {
    uint8_t *data;
    size_t capacity;
    size_t bits;
} Writer;

static void write_bit(Writer *writer, unsigned bit) {
    if ((writer->bits >> 3) >= writer->capacity)
        return; /* Sized by the caller; a short buffer shows as a bit count mismatch. */
    if (bit)
        writer->data[writer->bits >> 3] |= (uint8_t)(0x80 >> (writer->bits & 7));
    writer->bits++;
}

static void write_ue(Writer *writer, uint32_t value) {
    uint64_t coded = (uint64_t)value + 1;
    int length = 0;
    while (coded >> (length + 1))
        length++;
    for (int i = 0; i < length; i++)
        write_bit(writer, 0);
    for (int i = length; i >= 0; i--)
        write_bit(writer, (unsigned)(coded >> i) & 1);
}

/* Table A-1 MaxDpbMbs, with level 1b written as 9 or as 11 with constraint_set3_flag. */
static int max_dpb_mbs(int profile, int constraints, int level) {
    if (level == 9 || (level == 11 && (constraints & 0x10) && (profile == 66 || profile == 77 || profile == 88)))
        return 396;
    static const int table[][2] = {
        {10, 396}, {11, 900}, {12, 2376}, {13, 2376}, {20, 2376}, {21, 4752}, {22, 8100}, {30, 8100},
        {31, 18000}, {32, 20480}, {40, 32768}, {41, 32768}, {42, 34816}, {50, 110400}, {51, 184320},
        {52, 184320}, {60, 696320}, {61, 696320}, {62, 696320},
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++)
        if (table[i][0] == level)
            return table[i][1];
    return 0;
}

typedef struct {
    size_t insert;        /* Bit position of the flag that is replaced: VUI present, or bitstream restriction. */
    int has_vui;
    int max_dec_frame_buffering;
} Layout;

/* Remove emulation prevention bytes. */
static uint8_t *unescape(const uint8_t *data, size_t size, size_t *length) {
    uint8_t *rbsp = av_malloc(size ? size : 1);
    if (!rbsp)
        return NULL;
    size_t used = 0;
    unsigned zeros = 0;
    for (size_t i = 0; i < size; i++) {
        if (zeros >= 2 && data[i] == 3) {
            zeros = 0;
            continue;
        }
        zeros = data[i] ? 0 : zeros + 1;
        rbsp[used++] = data[i];
    }
    *length = used;
    return rbsp;
}

/* Find where a reorder depth can be declared. Returns 1 with the layout, 0 when the
 * set already declares one (or an intra profile has nothing to reorder), or -1 when it
 * cannot be rewritten without guessing. */
static int sps_layout(const uint8_t *rbsp, size_t size, Layout *layout) {
    /* The stop bit: the last set bit of the RBSP. Trailing zero bytes are allowed. */
    while (size && !rbsp[size - 1])
        size--;
    if (size < 4)
        return -1;
    size_t stop = size * 8 - 1;
    for (uint8_t last = rbsp[size - 1]; !(last & 1); last >>= 1)
        stop--;
    Reader reader = {rbsp, size * 8, 0, 0};
    int profile = (int)read_bits(&reader, 8);
    int constraints = (int)read_bits(&reader, 8);
    int level = (int)read_bits(&reader, 8);
    read_ue(&reader); /* seq_parameter_set_id */
    unsigned chroma_format = 1;
    switch (profile) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128: case 138: case 139:
    case 134: case 135:
        chroma_format = read_ue(&reader);
        if (chroma_format == 3)
            read_bit(&reader); /* separate_colour_plane_flag */
        read_ue(&reader); /* bit_depth_luma_minus8 */
        read_ue(&reader); /* bit_depth_chroma_minus8 */
        read_bit(&reader); /* qpprime_y_zero_transform_bypass_flag */
        if (read_bit(&reader)) { /* seq_scaling_matrix_present_flag */
            for (unsigned list = 0; list < (chroma_format != 3 ? 8u : 12u) && !reader.error; list++) {
                if (!read_bit(&reader))
                    continue;
                int last = 8, next = 8;
                for (int j = 0; j < (list < 6 ? 16 : 64) && !reader.error; j++) {
                    if (next) {
                        uint32_t code = read_ue(&reader);
                        int delta = code & 1 ? (int)((code + 1) / 2) : -(int)(code / 2);
                        if (delta < -128 || delta > 127)
                            return -1;
                        next = (last + delta + 256) % 256;
                    }
                    last = next ? next : last;
                }
            }
        }
        break;
    default:
        break;
    }
    read_ue(&reader); /* log2_max_frame_num_minus4 */
    uint32_t order = read_ue(&reader);
    if (order == 0) {
        read_ue(&reader);
    } else if (order == 1) {
        read_bit(&reader);
        read_ue(&reader); /* offset_for_non_ref_pic, as se(v): only its length matters */
        read_ue(&reader); /* offset_for_top_to_bottom_field */
        uint32_t cycle = read_ue(&reader);
        if (cycle > 255)
            return -1;
        for (uint32_t i = 0; i < cycle && !reader.error; i++)
            read_ue(&reader);
    } else if (order != 2) {
        return -1;
    }
    uint32_t references = read_ue(&reader);
    read_bit(&reader); /* gaps_in_frame_num_value_allowed_flag */
    uint32_t width = read_ue(&reader) + 1;
    uint32_t height = read_ue(&reader) + 1;
    if (!read_bit(&reader)) /* frame_mbs_only_flag: field pictures count differently */
        return -1;
    read_bit(&reader); /* direct_8x8_inference_flag */
    if (read_bit(&reader)) { /* frame_cropping_flag */
        for (int i = 0; i < 4; i++)
            read_ue(&reader);
    }
    if (reader.error)
        return -1;
    layout->insert = reader.position;
    layout->has_vui = (int)read_bit(&reader);
    if (layout->has_vui) {
        if (read_bit(&reader) && read_bits(&reader, 8) == 255) /* aspect_ratio_info_present_flag, aspect_ratio_idc */
            read_bits(&reader, 32);
        if (read_bit(&reader)) /* overscan_info_present_flag */
            read_bit(&reader);
        if (read_bit(&reader)) { /* video_signal_type_present_flag */
            read_bits(&reader, 4);
            if (read_bit(&reader))
                read_bits(&reader, 24);
        }
        if (read_bit(&reader)) { /* chroma_loc_info_present_flag */
            read_ue(&reader);
            read_ue(&reader);
        }
        if (read_bit(&reader)) /* timing_info_present_flag */
            read_bits(&reader, 32), read_bits(&reader, 32), read_bit(&reader);
        int nal_hrd = (int)read_bit(&reader);
        if (nal_hrd)
            skip_hrd(&reader);
        int vcl_hrd = (int)read_bit(&reader);
        if (vcl_hrd)
            skip_hrd(&reader);
        if (nal_hrd || vcl_hrd)
            read_bit(&reader); /* low_delay_hrd_flag */
        read_bit(&reader); /* pic_struct_present_flag */
        if (reader.error)
            return -1;
        layout->insert = reader.position;
        /* An encoder may end the VUI here; FFmpeg reads that as no restriction. */
        if (stop == layout->insert)
            goto checked;
        if (read_bit(&reader)) /* bitstream_restriction_flag */
            return 0;
    }
    if (reader.error || stop != layout->insert + 1)
        return -1; /* Anything else after these flags is not understood here. */
checked:;
    /* A depth may be declared only where the inferred value is the level's whole buffer. */
    if ((profile == 44 || profile == 86 || profile == 100 || profile == 110 || profile == 122 || profile == 244)
        && (constraints & 0x10))
        return 0;
    int mbs = max_dpb_mbs(profile, constraints, level);
    if (!mbs || !width || !height || width > 1024 || height > 1024)
        return -1;
    int frames = (int)(mbs / (width * height));
    if (frames > MAX_DPB_FRAMES)
        frames = MAX_DPB_FRAMES;
    /* max_dec_frame_buffering keeps the inferred buffer (MaxDpbFrames), and is never
     * below the reference frames of a stream that overstates its level's buffer. */
    if ((uint32_t)frames < references)
        frames = references > MAX_DPB_FRAMES ? MAX_DPB_FRAMES : (int)references;
    layout->max_dec_frame_buffering = frames;
    return 1;
}

int mpcut_avc_sps_declare_reorder(const uint8_t *nal, size_t size, int reorder, uint8_t **out, size_t *out_size) {
    *out = NULL;
    *out_size = 0;
    if (!nal || size < 2 || (nal[0] & 0x1f) != 7 || reorder <= 0)
        return 0;
    size_t rbsp_size = 0;
    uint8_t *rbsp = unescape(nal + 1, size - 1, &rbsp_size);
    if (!rbsp)
        return AVERROR(ENOMEM);
    Layout layout;
    if (sps_layout(rbsp, rbsp_size, &layout) <= 0) {
        av_free(rbsp);
        return 0;
    }
    /* A stream that reorders deeper than its level's buffer still gets its true depth declared. */
    if (reorder > MAX_DPB_FRAMES)
        reorder = MAX_DPB_FRAMES;
    if (reorder > layout.max_dec_frame_buffering)
        layout.max_dec_frame_buffering = reorder;
    /* Copy every bit before the replaced flag, then write a VUI that declares only the
     * restriction (with the values a reader infers when it is absent) and the stop bit. */
    size_t capacity = layout.insert / 8 + 32;
    uint8_t *edited = av_mallocz(capacity);
    if (!edited) {
        av_free(rbsp);
        return AVERROR(ENOMEM);
    }
    Writer writer = {edited, capacity, 0};
    Reader copy = {rbsp, rbsp_size * 8, 0, 0};
    while (copy.position < layout.insert)
        write_bit(&writer, read_bit(&copy));
    av_free(rbsp);
    if (!layout.has_vui) {
        write_bit(&writer, 1); /* vui_parameters_present_flag */
        for (int i = 0; i < 8; i++)
            write_bit(&writer, 0); /* aspect ratio, overscan, video signal, chroma location, timing, NAL HRD, VCL HRD, pic_struct */
    }
    write_bit(&writer, 1); /* bitstream_restriction_flag */
    write_bit(&writer, 1); /* motion_vectors_over_pic_boundaries_flag */
    write_ue(&writer, 2);  /* max_bytes_per_pic_denom */
    write_ue(&writer, 1);  /* max_bits_per_mb_denom */
    write_ue(&writer, 15); /* log2_max_mv_length_horizontal */
    write_ue(&writer, 15); /* log2_max_mv_length_vertical */
    write_ue(&writer, (uint32_t)reorder);
    write_ue(&writer, (uint32_t)layout.max_dec_frame_buffering);
    write_bit(&writer, 1); /* rbsp_stop_one_bit */
    while (writer.bits & 7)
        write_bit(&writer, 0);
    size_t length = writer.bits / 8;
    if (length + 1 > capacity) {
        av_free(edited);
        return AVERROR_BUG;
    }
    /* Header byte, then the RBSP with emulation prevention restored. */
    uint8_t *unit = av_malloc(1 + length + length / 2 + 1);
    if (!unit) {
        av_free(edited);
        return AVERROR(ENOMEM);
    }
    size_t used = 0;
    unit[used++] = nal[0];
    unsigned zeros = 0;
    for (size_t i = 0; i < length; i++) {
        if (zeros >= 2 && edited[i] <= 3) {
            unit[used++] = 3;
            zeros = 0;
        }
        unit[used++] = edited[i];
        zeros = edited[i] ? 0 : zeros + 1;
    }
    av_free(edited);
    *out = unit;
    *out_size = used;
    return 1;
}

static int sps_needs_reorder(const uint8_t *nal, size_t size) {
    if (size < 2 || (nal[0] & 0x1f) != 7)
        return 0;
    size_t rbsp_size = 0;
    uint8_t *rbsp = unescape(nal + 1, size - 1, &rbsp_size);
    Layout layout;
    int needed = rbsp && sps_layout(rbsp, rbsp_size, &layout) > 0 && layout.max_dec_frame_buffering > 0;
    av_free(rbsp);
    return needed;
}

int mpcut_avcc_needs_reorder(const uint8_t *config, int size) {
    if (!config || size < 7 || config[0] != 1)
        return 0;
    const uint8_t *p = config + 6, *end = config + size;
    for (unsigned i = 0; i < (config[5] & 0x1fu); i++) {
        if (end - p < 2 || end - p - 2 < AV_RB16(p))
            return 0;
        size_t length = AV_RB16(p);
        if (sps_needs_reorder(p + 2, length))
            return 1;
        p += 2 + length;
    }
    return 0;
}

int mpcut_avcc_reorder_unknown(const uint8_t *config, int size) {
    if (!config || size < 7 || config[0] != 1)
        return 0;
    const uint8_t *p = config + 6, *end = config + size;
    for (unsigned i = 0; i < (config[5] & 0x1fu); i++) {
        if (end - p < 2 || end - p - 2 < AV_RB16(p))
            return 0;
        size_t length = AV_RB16(p), rbsp_size = 0;
        uint8_t *rbsp = length >= 2 && (p[2] & 0x1f) == 7 ? unescape(p + 3, length - 1, &rbsp_size) : NULL;
        Layout layout;
        int unknown = rbsp && sps_layout(rbsp, rbsp_size, &layout) < 0;
        av_free(rbsp);
        if (unknown)
            return 1;
        p += 2 + length;
    }
    return 0;
}

int mpcut_avcc_declare_reorder(const uint8_t *config, int size, int reorder, uint8_t **out, int *out_size) {
    *out = NULL;
    *out_size = 0;
    if (!config || size < 7 || config[0] != 1 || reorder <= 0)
        return 0;
    const unsigned count = config[5] & 0x1f;
    uint8_t *units[32] = {0};
    size_t sizes[32] = {0};
    const uint8_t *p = config + 6, *end = config + size;
    size_t total = (size_t)size;
    int changed = 0, result = 0;
    for (unsigned i = 0; i < count; i++) {
        if (end - p < 2 || end - p - 2 < AV_RB16(p)) {
            result = AVERROR_INVALIDDATA;
            goto done;
        }
        size_t length = AV_RB16(p);
        result = mpcut_avc_sps_declare_reorder(p + 2, length, reorder, &units[i], &sizes[i]);
        if (result < 0)
            goto done;
        if (result) {
            if (sizes[i] > UINT16_MAX) {
                result = AVERROR_INVALIDDATA;
                goto done;
            }
            total += sizes[i] - length;
            changed = 1;
        }
        p += 2 + length;
    }
    result = 0;
    if (!changed || total > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE)
        goto done;
    uint8_t *record = av_mallocz(total + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!record) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    memcpy(record, config, 6);
    uint8_t *q = record + 6;
    p = config + 6;
    for (unsigned i = 0; i < count; i++) {
        size_t length = AV_RB16(p);
        const uint8_t *unit = units[i] ? units[i] : p + 2;
        size_t unit_size = units[i] ? sizes[i] : length;
        AV_WB16(q, (unsigned)unit_size);
        memcpy(q + 2, unit, unit_size);
        q += 2 + unit_size;
        p += 2 + length;
    }
    memcpy(q, p, (size_t)(end - p)); /* Picture parameter sets and any profile extension, unchanged. */
    *out = record;
    *out_size = (int)total;
    result = 1;
done:
    for (unsigned i = 0; i < count; i++)
        av_free(units[i]);
    return result;
}

int mpcut_avc_packet_declare_reorder(AVPacket *packet, int length_size, int reorder) {
    if (length_size < 1 || length_size > 4 || reorder <= 0)
        return 0;
    const uint8_t *data = packet->data, *end = packet->data + packet->size;
    size_t total = 0;
    int changed = 0;
    /* First pass: measure. Second pass: build. Units are rewritten twice to keep this simple. */
    for (int pass = 0; pass < 2; pass++) {
        uint8_t *built = NULL, *q = NULL;
        AVBufferRef *buffer = NULL;
        if (pass) {
            if (!changed)
                return 0;
            if (total > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE)
                return AVERROR_INVALIDDATA;
            buffer = av_buffer_allocz(total + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!buffer)
                return AVERROR(ENOMEM);
            built = q = buffer->data;
        }
        for (const uint8_t *p = data; p < end;) {
            if (end - p < length_size) {
                av_buffer_unref(&buffer);
                return AVERROR_INVALIDDATA;
            }
            size_t length = 0;
            for (int i = 0; i < length_size; i++)
                length = length << 8 | p[i];
            if ((size_t)(end - p - length_size) < length) {
                av_buffer_unref(&buffer);
                return AVERROR_INVALIDDATA;
            }
            uint8_t *unit = NULL;
            size_t unit_size = 0;
            int result = length ? mpcut_avc_sps_declare_reorder(p + length_size, length, reorder, &unit, &unit_size) : 0;
            if (result < 0) {
                av_buffer_unref(&buffer);
                return result;
            }
            if (result && length_size < 4 && unit_size >> (8 * length_size)) {
                av_free(unit);
                av_buffer_unref(&buffer);
                return AVERROR_INVALIDDATA;
            }
            const uint8_t *source = result ? unit : p + length_size;
            size_t source_size = result ? unit_size : length;
            changed |= result;
            if (!pass) {
                total += (size_t)length_size + source_size;
            } else {
                for (int i = length_size - 1; i >= 0; i--)
                    *q++ = (uint8_t)(source_size >> (8 * i));
                memcpy(q, source, source_size);
                q += source_size;
            }
            av_free(unit);
            p += length_size + length;
        }
        if (pass) {
            av_buffer_unref(&packet->buf);
            packet->buf = buffer;
            packet->data = built;
            packet->size = (int)total;
        }
    }
    return 1;
}

void mpcut_reorder_scan_add(MPCutReorderScan *scan, int64_t pts) {
    /* window holds the largest presentation times seen so far, ascending. A picture
     * reorders behind every earlier one that presents after it; counts up to 16 are exact. */
    unsigned later = 0;
    for (unsigned i = 0; i < scan->filled; i++)
        later += scan->window[i] > pts;
    if ((int)later > scan->depth)
        scan->depth = later > MAX_DPB_FRAMES ? MAX_DPB_FRAMES : (int)later;
    unsigned capacity = sizeof(scan->window) / sizeof(scan->window[0]);
    if (scan->filled == capacity) {
        if (pts <= scan->window[0])
            return;
        memmove(scan->window, scan->window + 1, (capacity - 1) * sizeof(scan->window[0]));
        scan->filled--;
    }
    unsigned at = scan->filled;
    while (at && scan->window[at - 1] > pts) {
        scan->window[at] = scan->window[at - 1];
        at--;
    }
    scan->window[at] = pts;
    scan->filled++;
}
