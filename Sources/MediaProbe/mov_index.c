#include "mov_index.h"

#include <libavutil/intreadwrite.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    int64_t payload, end;
    uint32_t type;
} Atom;

static bool nonprinting_type(uint32_t type)
{
    for (int byte = 0; byte < 4; byte++, type >>= 8)
        if ((type & 255) < 32 || (type & 255) > 126)
            return true;
    return false;
}

bool mp_mov_read_at(int fd, int64_t offset, void *buffer, size_t size)
{
    return pread(fd, buffer, size, offset) == (ssize_t)size;
}

static bool next_atom(int fd, int64_t *offset, int64_t end, Atom *atom, bool trailing_padding)
{
    uint8_t bytes[8];
    int header = 8;
    if (end - *offset < header || !mp_mov_read_at(fd, *offset, bytes, sizeof(bytes)))
        return false;
    uint64_t size = AV_RB32(bytes);
    atom->type = AV_RB32(bytes + 4);
    if (size == 1) {
        header = 16;
        if (end - *offset < header || !mp_mov_read_at(fd, *offset + 8, bytes, sizeof(bytes)))
            return false;
        size = AV_RB64(bytes);
    } else if (size == 0) {
        size = end - *offset;
    }
    // Some camera originals pad the file after moov with nonprinting atom types.
    // FFmpeg clamps an oversized unknown root atom to the bytes remaining.
    if (trailing_padding && nonprinting_type(atom->type) && size > (uint64_t)(end - *offset))
        size = end - *offset;
    if (size < (uint64_t)header || size > (uint64_t)(end - *offset))
        return false;
    atom->payload = *offset + header;
    atom->end = *offset += size;
    return true;
}

static bool find_atom(int fd, Atom parent, uint32_t type, Atom *found)
{
    *found = (Atom){0};
    for (int64_t offset = parent.payload; offset < parent.end;) {
        Atom atom;
        if (!next_atom(fd, &offset, parent.end, &atom, false))
            return false;
        if (atom.type == type) {
            if (found->payload)
                return false;
            *found = atom;
        }
    }
    return true;
}

#define TAG(a, b, c, d) MKBETAG(a, b, c, d)

static bool read_sample_table(int fd, Atom table, const AVStream *stream)
{
    bool description = false, timing = false;
    for (int64_t offset = table.payload; offset < table.end;) {
        Atom atom;
        uint8_t bytes[24];
        if (!next_atom(fd, &offset, table.end, &atom, false))
            return false;
        switch (atom.type) {
        case TAG('s', 't', 's', 'd'):
            // Require one sample description using the track's local data reference.
            if (description || atom.end - atom.payload < 24 ||
                !mp_mov_read_at(fd, atom.payload, bytes, sizeof(bytes)) ||
                AV_RB32(bytes) || AV_RB32(bytes + 4) != 1 ||
                AV_RL32(bytes + 12) != stream->codecpar->codec_tag ||
                AV_RB16(bytes + 22) != 1)
                return false;
            description = true;
            break;
        case TAG('s', 't', 't', 's'): {
            // A single timing run rules out gaps and variable durations.
            if (timing || atom.end - atom.payload != 16 ||
                !mp_mov_read_at(fd, atom.payload, bytes, 16) ||
                AV_RB32(bytes) || AV_RB32(bytes + 4) != 1)
                return false;
            uint32_t count = AV_RB32(bytes + 8), duration = AV_RB32(bytes + 12);
            if (!count || !duration || count != stream->nb_frames ||
                (uint64_t)count * duration != (uint64_t)stream->duration ||
                (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && duration != 1))
                return false;
            timing = true;
            break;
        }
        case TAG('s', 't', 's', 'z'):
        case TAG('s', 't', 's', 'c'):
        case TAG('s', 't', 'c', 'o'):
        case TAG('c', 'o', '6', '4'):
            break;
        default:
            // Leave composition offsets, sample groups and any other extensions to the demuxer.
            return false;
        }
    }
    return description && timing;
}

static bool local_data_reference(int fd, Atom minf)
{
    Atom dinf, dref;
    uint8_t bytes[20];
    return find_atom(fd, minf, TAG('d', 'i', 'n', 'f'), &dinf) && dinf.payload &&
           find_atom(fd, dinf, TAG('d', 'r', 'e', 'f'), &dref) &&
           dref.end - dref.payload == sizeof(bytes) &&
           mp_mov_read_at(fd, dref.payload, bytes, sizeof(bytes)) &&
           AV_RB32(bytes) == 0 && AV_RB32(bytes + 4) == 1 && AV_RB32(bytes + 8) == 12 &&
           (AV_RB32(bytes + 12) == TAG('u', 'r', 'l', ' ') ||
            AV_RB32(bytes + 12) == TAG('a', 'l', 'i', 's')) &&
           AV_RB32(bytes + 16) == 1;
}

static bool full_track_edit(int fd, Atom track, const AVStream *stream, uint32_t movie_scale)
{
    Atom edits, list;
    uint8_t bytes[28];
    if (!find_atom(fd, track, TAG('e', 'd', 't', 's'), &edits))
        return false;
    if (!edits.payload)
        return true;
    if (!next_atom(fd, &edits.payload, edits.end, &list, false) || edits.payload != edits.end ||
        list.type != TAG('e', 'l', 's', 't'))
        return false;
    int64_t size = list.end - list.payload;
    if ((size != 20 && size != 28) || !mp_mov_read_at(fd, list.payload, bytes, size) ||
        AV_RB32(bytes) != (size == 28 ? 1U << 24 : 0) || AV_RB32(bytes + 4) != 1)
        return false;
    uint64_t duration = size == 28 ? AV_RB64(bytes + 8) : AV_RB32(bytes + 8);
    uint64_t start = size == 28 ? AV_RB64(bytes + 16) : AV_RB32(bytes + 12);
    // Only full, forward, zero-based tracks are eligible.
    return duration <= INT64_MAX && start == 0 && AV_RB32(bytes + size - 4) == 0x10000 &&
           av_rescale(duration, stream->time_base.den, movie_scale) == stream->duration;
}

static bool read_movie(int fd, Atom movie, const AVFormatContext *file)
{
    Atom header, extensions;
    uint8_t bytes[24];
    if (!find_atom(fd, movie, TAG('m', 'v', 'h', 'd'), &header) ||
        header.end - header.payload < (int64_t)sizeof(bytes) ||
        !mp_mov_read_at(fd, header.payload, bytes, sizeof(bytes)) ||
        !find_atom(fd, movie, TAG('m', 'v', 'e', 'x'), &extensions) || extensions.payload)
        return false;
    if (bytes[0] > 1)
        return false;
    uint32_t scale = AV_RB32(bytes + (bytes[0] ? 20 : 12));
    if (!scale)
        return false;
    unsigned int tracks = 0;
    for (int64_t offset = movie.payload; offset < movie.end;) {
        Atom track;
        if (!next_atom(fd, &offset, movie.end, &track, false))
            return false;
        if (track.type != TAG('t', 'r', 'a', 'k'))
            continue;
        if (tracks >= file->nb_streams)
            return false;
        const AVStream *stream = file->streams[tracks++];
        Atom tkhd, mdia, minf, stbl;
        if (!find_atom(fd, track, TAG('t', 'k', 'h', 'd'), &tkhd) ||
            tkhd.end - tkhd.payload < (int64_t)sizeof(bytes) ||
            !mp_mov_read_at(fd, tkhd.payload, bytes, sizeof(bytes)) || bytes[0] > 1 ||
            AV_RB32(bytes + (bytes[0] ? 20 : 12)) != (uint32_t)stream->id ||
            stream->time_base.num != 1 || stream->time_base.den <= 0 ||
            stream->start_time != 0 || stream->duration <= 0 ||
            !full_track_edit(fd, track, stream, scale) ||
            !find_atom(fd, track, TAG('m', 'd', 'i', 'a'), &mdia) || !mdia.payload ||
            !find_atom(fd, mdia, TAG('m', 'i', 'n', 'f'), &minf) || !minf.payload ||
            !local_data_reference(fd, minf) ||
            !find_atom(fd, minf, TAG('s', 't', 'b', 'l'), &stbl) || !stbl.payload ||
            !read_sample_table(fd, stbl, stream))
            return false;
    }
    return tracks == file->nb_streams;
}

bool mp_mov_open_index(const char *path, const AVFormatContext *file, MPMOVIndex *index)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
#ifdef F_RDAHEAD
    fcntl(fd, F_RDAHEAD, 0);
#endif
    struct stat info;
    Atom movie = {0}, media = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode))
        goto fallback;
    for (int64_t offset = 0; offset < info.st_size;) {
        Atom atom;
        if (!next_atom(fd, &offset, info.st_size, &atom, movie.payload && media.payload))
            goto fallback;
        switch (atom.type) {
        case TAG('m', 'o', 'o', 'v'):
            if (movie.payload)
                goto fallback;
            movie = atom;
            break;
        case TAG('m', 'd', 'a', 't'):
            if (media.payload)
                goto fallback;
            media = atom;
            break;
        case TAG('f', 't', 'y', 'p'):
        case TAG('f', 'r', 'e', 'e'):
        case TAG('s', 'k', 'i', 'p'):
            break;
        case TAG('w', 'i', 'd', 'e'): {
            uint8_t header[8];
            if (atom.end - atom.payload >= (int64_t)sizeof(header) &&
                (!mp_mov_read_at(fd, atom.payload, header, sizeof(header)) ||
                 AV_RB64(header) == TAG('m', 'd', 'a', 't')))
                goto fallback;
            break;
        }
        default:
            if (!movie.payload || !media.payload || !nonprinting_type(atom.type))
                goto fallback;
            break;
        }
    }
    if (!movie.payload || !media.payload || !read_movie(fd, movie, file))
        goto fallback;
    *index = (MPMOVIndex){.fd = fd, .payload_start = media.payload, .payload_end = media.end};
    return true;

fallback:
    close(fd);
    return false;
}
