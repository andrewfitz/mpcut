#ifndef MPCUT_JPEG_FRAME_H
#define MPCUT_JPEG_FRAME_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/pixfmt.h>

// A baseline JPEG with all of its scan tables can start a decoder at any
// timeline position. Abbreviated MJPEG packets can inherit tables from a
// preceding packet, even when the container marks every packet as a keyframe.
static bool self_contained_jpeg(const uint8_t *data, int size, int width, int height,
                                enum AVPixelFormat *format)
{
    if (size < 4 || AV_RB16(data) != 0xffd8 || AV_RB16(data + size - 2) != 0xffd9)
        return false;
    const uint8_t *p = data + 2, *end = data + size - 2;
    uint8_t component_ids[4] = {0}, quant_ids[4] = {0}, sampling[4] = {0};
    unsigned components = 0, quant = 0, dc = 0, ac = 0;
    while (end - p >= 4 && *p++ == 0xff) {
        while (p < end && *p == 0xff) p++;
        if (end - p < 3) return false;
        unsigned marker = *p++;
        unsigned length = AV_RB16(p);
        if (length < 2 || length > end - p) return false;
        const uint8_t *next = p + length;
        p += 2;
        switch (marker) {
        case 0xdb: // Quantization tables
            while (p < next) {
                unsigned table = *p++;
                if (table > 3 || next - p < 64) return false;
                quant |= 1u << table;
                p += 64;
            }
            break;
        case 0xc4: // Huffman tables
            while (p < next) {
                unsigned table = *p++, id = table & 15;
                if (table > 0x13 || id > 3 || next - p < 16) return false;
                unsigned symbols = 0;
                for (unsigned i = 0; i < 16; i++) symbols += *p++;
                if (!symbols || symbols > 256 || next - p < symbols) return false;
                if (table & 16) ac |= 1u << id;
                else dc |= 1u << id;
                p += symbols;
            }
            break;
        case 0xc0: // Baseline sequential frame
            if (components || next - p < 6 || *p != 8 ||
                AV_RB16(p + 1) != height || AV_RB16(p + 3) != width) return false;
            components = p[5];
            p += 6;
            if (!components || components > 4 || next - p != 3 * components) return false;
            for (unsigned i = 0; i < components; i++, p += 3) {
                if (p[2] > 3 || memchr(component_ids, p[0], i)) return false;
                component_ids[i] = p[0];
                quant_ids[i] = p[2];
                sampling[i] = p[1];
            }
            break;
        case 0xda: { // A single interleaved scan requiring only local tables
            if (!components || next - p != 4 + 2 * components || *p++ != components) return false;
            unsigned scanned = 0;
            for (unsigned i = 0; i < components; i++) {
                const uint8_t *component = memchr(component_ids, *p++, components);
                unsigned tables = *p++, dc_id = tables >> 4, ac_id = tables & 15;
                if (!component || dc_id > 3 || ac_id > 3 ||
                    !(dc & (1u << dc_id)) || !(ac & (1u << ac_id))) return false;
                unsigned index = (unsigned)(component - component_ids);
                if (!(quant & (1u << quant_ids[index]))) return false;
                scanned |= 1u << index;
            }
            if (scanned != (1u << components) - 1 || AV_RB24(p) != 0x003f00 || next == end)
                return false;
            if (format && components == 3 && component_ids[0] == 1 && component_ids[1] == 2 &&
                component_ids[2] == 3 && sampling[1] == sampling[2]) {
                unsigned h = sampling[0] >> 4, v = sampling[0] & 15;
                unsigned ch = sampling[1] >> 4, cv = sampling[1] & 15;
                if (ch && cv && h == 2 * ch && v == cv) *format = AV_PIX_FMT_YUVJ422P;
                if (ch && cv && h == 2 * ch && v == 2 * cv) *format = AV_PIX_FMT_YUVJ420P;
                if (ch && cv && h == ch && v == cv) *format = AV_PIX_FMT_YUVJ444P;
            }
            return true;
        }
        default:
            if ((marker < 0xe0 || marker > 0xef) && marker != 0xfe && marker != 0xdd)
                return false;
        }
        p = next;
    }
    return false;
}

#endif
