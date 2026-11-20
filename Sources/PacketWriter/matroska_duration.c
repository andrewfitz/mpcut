#include "PacketWriter.h"

#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavutil/crc.h>
#include <libavutil/intreadwrite.h>

/* libavformat writes the end of the last coded block into Info.Duration and
 * the track DURATION tags. After an Opus crop this includes hidden decoder
 * preroll and end padding. Correct the fixed-size fields in our staged output. */
typedef struct {
    uint32_t id;
    uint8_t *data;
    size_t size;
} Element;

static int next(Element *remaining, Element *out) {
    const uint8_t *p = remaining->data;
    size_t n = remaining->size;
    if (!n || !*p) return 0;
    unsigned id_len = 1;
    while (id_len <= 4 && !(*p & (0x80 >> (id_len - 1)))) id_len++;
    if (id_len > 4 || id_len >= n || !p[id_len]) return 0;
    uint32_t id = 0;
    for (unsigned i = 0; i < id_len; i++) id = (id << 8) | p[i];
    unsigned len = 1;
    while (!(p[id_len] & (0x80 >> (len - 1)))) len++;
    if (len > n - id_len) return 0;
    uint64_t size = p[id_len] & (0xff >> len);
    for (unsigned i = 1; i < len; i++) size = (size << 8) | p[id_len + i];
    size_t header = id_len + len;
    if (size > n - header) return 0;
    *out = (Element){id, remaining->data + header, (size_t)size};
    remaining->data += header + size;
    remaining->size -= header + size;
    return 1;
}

static Element child(Element parent, uint32_t id) {
    Element entry;
    while (next(&parent, &entry)) {
        if (entry.id == id) return entry;
    }
    return (Element){0};
}

static uint64_t integer(Element value) {
    if (value.size > 8) return 0;
    uint64_t result = 0;
    for (size_t i = 0; i < value.size; i++) result = (result << 8) | value.data[i];
    return result;
}

static void update_crc(Element section) {
    Element crc;
    if (next(&section, &crc) && crc.id == 0xbf && crc.size == 4) {
        AV_WL32(crc.data, av_crc(av_crc_get_table(AV_CRC_32_IEEE_LE), UINT32_MAX,
                                 section.data, section.size) ^ UINT32_MAX);
    }
}

static int update_duration_tags(Element segment, const int64_t *ends, size_t count, uint64_t *uids) {
    Element info = child(segment, 0x1549a966);
    Element duration = child(info, 0x4489);
    Element tracks = child(segment, 0x1654ae6b);
    Element tags = child(segment, 0x1254c367);
    if (duration.size != 8 || !tracks.data || !tags.data ||
        integer(child(info, 0x2ad7b1)) != 1000000) return -1;

    Element entry;
    while (next(&tracks, &entry)) {
        if (entry.id != 0xae) continue;
        uint64_t number = integer(child(entry, 0xd7));
        if (!number || number > count || uids[number - 1]) return -1;
        uids[number - 1] = integer(child(entry, 0x73c5));
    }

    int64_t longest = 0;
    size_t changed = 0;
    Element rest = tags, tag;
    while (next(&rest, &tag)) {
        if (tag.id != 0x7373) continue;
        uint64_t uid = integer(child(child(tag, 0x63c0), 0x63c5));
        if (!uid) continue;
        size_t index = 0;
        while (index < count && uids[index] != uid) index++;
        if (index == count || ends[index] < 0) return -1;
        Element simple;
        while (next(&tag, &simple)) {
            if (simple.id != 0x67c8) continue;
            Element name = child(simple, 0x45a3);
            if (name.size != 8 || memcmp(name.data, "DURATION", 8)) continue;
            Element value = child(simple, 0x4487);
            int64_t ns = ends[index], seconds = ns / 1000000000;
            char clock[48];
            int length = snprintf(clock, sizeof(clock), "%02" PRId64 ":%02" PRId64 ":%02" PRId64 ".%09" PRId64,
                                  seconds / 3600, seconds / 60 % 60, seconds % 60, ns % 1000000000);
            if (length < 0 || (size_t)length > value.size || (size_t)length >= sizeof(clock)) return -1;
            memset(value.data, 0, value.size);
            memcpy(value.data, clock, length);
            if (ns > longest) longest = ns;
            uids[index] = 0;
            changed++;
            break;
        }
    }
    if (changed != count) return -1;
    double milliseconds = (double)longest / 1000000;
    uint64_t bits;
    memcpy(&bits, &milliseconds, sizeof(bits));
    AV_WB64(duration.data, bits);
    update_crc(info);
    update_crc(tags);
    return 0;
}

int mpcut_set_matroska_durations(const char *path, const int64_t *ends, size_t count) {
    int fd = open(path, O_RDWR);
    if (fd < 0) return -1;
    struct stat st;
    int result = -1;
    if (!fstat(fd, &st) && st.st_size > 0 && (uint64_t)st.st_size <= SIZE_MAX) {
        size_t size = (size_t)st.st_size;
        uint8_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (data != MAP_FAILED) {
            Element segment = child((Element){0, data, size}, 0x18538067);
            uint64_t *uids = calloc(count, sizeof(*uids));
            if (segment.data && uids) result = update_duration_tags(segment, ends, count, uids);
            free(uids);
            if (munmap(data, size) != 0) result = -1;
        }
    }
    if (close(fd) != 0) result = -1;
    return result;
}
