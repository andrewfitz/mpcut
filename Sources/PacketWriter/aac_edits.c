#include "aac_edits.h"

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libavutil/avutil.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mathematics.h>

typedef struct {
    int64_t duration;
    int64_t media_time;
} Edit;

typedef struct {
    Edit *edits;
    size_t count;
    size_t capacity;
    int sample_rate;
    int64_t media_end;
    int64_t frame_samples;
    int64_t source_first;
    int64_t source_end;
    int64_t next_source_sample;
    int64_t edit_media_time;
    int64_t covered_until;
    int64_t movie_duration;
} AudioTrack;

struct MPCutAAC {
    unsigned track_count;
    int movie_timescale;
    AudioTrack tracks[];
};

static int errorf(char *error, size_t cap, const char *format, ...) {
    if (error && cap) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, cap, format, args);
        va_end(args);
    }
    return 1;
}

static int64_t ticks(MPCutTime time, int timescale) {
    if (time.denominator <= 0) {
        return INT64_MIN;
    }
    __int128 num = (__int128)time.numerator * timescale;
    __int128 half = time.denominator / 2;
    __int128 result = (num < 0 ? num - half : num + half) / time.denominator;
    return result <= INT64_MIN || result > INT64_MAX ? INT64_MIN : (int64_t)result;
}

MPCutAAC *mpcut_aac_create(unsigned track_count, int movie_timescale) {
    MPCutAAC *aac = calloc(1, sizeof(*aac) + (size_t)track_count * sizeof(AudioTrack));
    if (aac) {
        aac->track_count = track_count;
        aac->movie_timescale = movie_timescale;
    }
    return aac;
}

void mpcut_aac_free(MPCutAAC *aac) {
    if (aac) {
        for (unsigned i = 0; i < aac->track_count; i++) {
            free(aac->tracks[i].edits);
        }
        free(aac);
    }
}

int mpcut_aac_begin(MPCutAAC *aac, unsigned index, int sample_rate, MPCutTime src_start,
                    MPCutTime out_start, MPCutTime out_end, char *error, size_t cap) {
    AudioTrack *track = &aac->tracks[index];
    int64_t first = ticks(src_start, sample_rate);
    int64_t out_first_sample = ticks(out_start, sample_rate);
    int64_t out_end_sample = ticks(out_end, sample_rate);
    if (sample_rate <= 0 || (track->sample_rate && track->sample_rate != sample_rate)
        || first == INT64_MIN || out_first_sample < 0 || out_end_sample <= out_first_sample
        || first > INT64_MAX - (out_end_sample - out_first_sample)) {
        return errorf(error, cap, "Cannot map AAC samples on track %u", index);
    }
    track->sample_rate = sample_rate;
    track->source_first = first;
    track->source_end = first + (out_end_sample - out_first_sample);
    track->frame_samples = 0;
    track->next_source_sample = INT64_MIN;
    track->edit_media_time = INT64_MIN;
    track->covered_until = first;
    /* Round cumulative output boundaries to samples before making edit durations.
       An unsnapped edit would round up separately at each join in AVFoundation. */
    AVRational samples = {1, sample_rate};
    AVRational movie_ticks = {1, aac->movie_timescale};
    int64_t movie_first = av_rescale_q(out_first_sample, samples, movie_ticks);
    int64_t movie_end = av_rescale_q(out_end_sample, samples, movie_ticks);
    if (movie_first < 0 || movie_end <= movie_first) {
        return errorf(error, cap, "Cannot map AAC duration on track %u", index);
    }
    track->movie_duration = movie_end - movie_first;
    return 0;
}

int mpcut_aac_packet(MPCutAAC *aac, AVPacket *packet, AVRational input_tb,
                     AVRational output_tb, int keep_tail_duration, char *error, size_t cap) {
    AudioTrack *track = &aac->tracks[packet->stream_index];
    AVRational sample_tb = {1, track->sample_rate};
    int64_t first = av_rescale_q(packet->pts, input_tb, sample_tb);
    int64_t length = av_rescale_q(packet->duration, input_tb, sample_tb);
    if (packet->pts == AV_NOPTS_VALUE || first == AV_NOPTS_VALUE || packet->dts != packet->pts
        || length <= 0 || first > INT64_MAX - length || av_cmp_q(output_tb, sample_tb)) {
        return errorf(error, cap, "Invalid AAC sample timing on track %d", packet->stream_index);
    }
    int64_t end = first + length;
    if (length > track->frame_samples) {
        track->frame_samples = length;
    }

    /* Keep two AAC access units before the cut for decoder overlap and SBR. */
    if ((__int128)end <= (__int128)track->source_first - MPCUT_AAC_PREROLL_SAMPLES
        || first >= track->source_end) {
        packet->size = 0;
        return 0;
    }
    size_t side_size = 0;
    const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &side_size);
    int64_t skip = side && side_size >= 8 ? AV_RL32(side) : 0;
    int64_t discard = side && side_size >= 8 ? AV_RL32(side + 4) : 0;
    /* MOV can report a final sample duration already shortened by its edit,
       and still attach decoder padding for the discarded portion of the AAC frame. */
    int64_t coded_length = discard ? track->frame_samples : length;
    int64_t clipped = coded_length - length;
    discard = discard > clipped ? discard - clipped : 0;
    if ((track->next_source_sample != INT64_MIN && track->next_source_sample != first)
        || track->media_end > INT64_MAX - coded_length) {
        return errorf(error, cap, "Discontinuous AAC samples on track %d", packet->stream_index);
    }
    track->next_source_sample = end;
    int64_t audible_first = skip >= length ? end : first + skip;
    int64_t audible_end = discard >= length ? first : end - discard;
    if (audible_first < audible_end && audible_end > track->source_first
        && audible_first < track->source_end) {
        if (audible_first > track->covered_until) {
            return errorf(error, cap, "AAC edit crosses a gap on track %d", packet->stream_index);
        }
        if (track->edit_media_time == INT64_MIN) {
            /* Keep the entire access unit, but present it from the exact cut sample. */
            track->edit_media_time = track->media_end + (track->source_first - first);
        }
        if (audible_end > track->covered_until) {
            track->covered_until = audible_end;
        }
    }
    av_packet_side_data_remove(packet->side_data, &packet->side_data_elems,
                               AV_PKT_DATA_SKIP_SAMPLES);
    packet->dts = track->media_end;
    packet->pts = track->media_end;
    // Preserve an explicitly shortened last stts sample in a complete
    // soundtrack. Splices need the full decoder cadence between access units.
    packet->duration = keep_tail_duration ? length : coded_length;
    track->media_end += packet->duration;
    return 0;
}

static int append_edit(MPCutAAC *aac, unsigned index, int64_t media_time,
                       char *error, size_t cap) {
    AudioTrack *track = &aac->tracks[index];
    if (track->count == track->capacity) {
        size_t new_capacity = track->capacity ? track->capacity * 2 : 4;
        if (new_capacity > (UINT32_MAX - 24) / 20) {
            return errorf(error, cap, "Too many AAC edits on track %u", index);
        }
        Edit *edits = realloc(track->edits, new_capacity * sizeof(*edits));
        if (!edits) {
            return errorf(error, cap, "Cannot allocate AAC edits on track %u", index);
        }
        track->edits = edits;
        track->capacity = new_capacity;
    }
    track->edits[track->count++] = (Edit){track->movie_duration, media_time};
    return 0;
}

int mpcut_aac_end(MPCutAAC *aac, unsigned index, char *error, size_t cap) {
    const AudioTrack *track = &aac->tracks[index];
    if (track->edit_media_time < 0 || track->covered_until < track->source_end - 1) {
        return errorf(error, cap, "AAC track %u does not cover the selected video range", index);
    }
    return append_edit(aac, index, track->edit_media_time, error, cap);
}

int mpcut_aac_empty(MPCutAAC *aac, unsigned index, int sample_rate, MPCutTime out_start,
                   MPCutTime out_end, char *error, size_t cap) {
    int result = mpcut_aac_begin(aac, index, sample_rate, (MPCutTime){0, 1},
                                 out_start, out_end, error, cap);
    return result ? result : append_edit(aac, index, -1, error, cap);
}

#define BOX(a,b,c,d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

typedef struct {
    const uint8_t *begin;
    const uint8_t *payload;
    const uint8_t *end;
    uint32_t type;
} Box;

static int next_box(const uint8_t **position, const uint8_t *end, Box *box) {
    const uint8_t *start = *position;
    size_t available = (size_t)(end - start);
    if (available < 8) {
        return 0;
    }
    uint64_t size = AV_RB32(start);
    size_t header_size = 8;
    if (size == 1) {
        if (available < 16) {
            return 0;
        }
        header_size = 16;
        size = AV_RB64(start + 8);
    } else if (size == 0) {
        size = available;
    }
    if (size < header_size || size > available) {
        return 0;
    }
    *box = (Box){start, start + header_size, start + size, AV_RB32(start + 4)};
    *position = box->end;
    return 1;
}

static int find_box(Box parent, uint32_t type, Box *child) {
    const uint8_t *position = parent.payload;
    while (next_box(&position, parent.end, child)) {
        if (child->type == type) {
            return 1;
        }
    }
    return 0;
}

static int time_fields(Box box, size_t prefix, uint32_t *id_or_timescale,
                       size_t *duration_offset, size_t *duration_width) {
    const uint8_t *p = box.payload;
    size_t size = (size_t)(box.end - p);
    int version = size ? p[0] : -1;
    size_t creation_and_modification = version == 1 ? 16 : 8;
    size_t value_offset = 4 + creation_and_modification;
    size_t time_offset = value_offset + prefix;
    size_t width = version == 1 ? 8 : 4;
    if ((version != 0 && version != 1) || size < time_offset + width) {
        return 0;
    }
    *id_or_timescale = AV_RB32(p + value_offset);
    *duration_offset = (size_t)(p - box.begin) + time_offset;
    *duration_width = width;
    return 1;
}

static size_t duration_header_size(Box box, size_t width, uint64_t duration) {
    size_t size = (size_t)(box.end - box.begin);
    return width == 4 && duration >= UINT32_MAX ? (size_t)(box.end - box.payload) + 20 : size;
}

static size_t write_duration_header(uint8_t *output, Box box, size_t offset, size_t width,
                                    uint64_t duration) {
    size_t size = duration_header_size(box, width, duration);
    if (width == 4 && duration >= UINT32_MAX) {
        /* The muxed track's coded samples can be much shorter than its
           presentation after adding empty edits. Expand its time fields. */
        const uint8_t *old_duration = box.begin + offset;
        size_t middle = (size_t)(old_duration - (box.payload + 12));
        AV_WB32(output, (uint32_t)size);
        AV_WB32(output + 4, box.type);
        AV_WB32(output + 8, (AV_RB32(box.payload) & 0x00ffffff) | 0x01000000);
        AV_WB64(output + 12, AV_RB32(box.payload + 4));
        AV_WB64(output + 20, AV_RB32(box.payload + 8));
        memcpy(output + 28, box.payload + 12, middle);
        AV_WB64(output + 28 + middle, duration);
        memcpy(output + 36 + middle, old_duration + 4, (size_t)(box.end - (old_duration + 4)));
    } else {
        memcpy(output, box.begin, size);
        if (width == 4) {
            AV_WB32(output + offset, (uint32_t)duration);
        } else {
            AV_WB64(output + offset, duration);
        }
    }
    return size;
}

static uint8_t *write_edits(uint8_t *p, const AudioTrack *track) {
    const uint32_t edit_bytes = (uint32_t)(track->count * 20);
    AV_WB32(p, edit_bytes + 24);
    AV_WB32(p + 4, BOX('e','d','t','s'));
    AV_WB32(p + 8, edit_bytes + 16);
    AV_WB32(p + 12, BOX('e','l','s','t'));
    AV_WB32(p + 16, 1U << 24);
    AV_WB32(p + 20, (uint32_t)track->count);
    p += 24;
    for (size_t i = 0; i < track->count; i++) {
        AV_WB64(p, track->edits[i].duration);
        AV_WB64(p + 8, track->edits[i].media_time);
        AV_WB32(p + 16, 1U << 16);
        p += 20;
    }
    return p;
}

static int rewrite_track(Box trak, const MPCutAAC *aac, uint8_t **output,
                         uint64_t *movie_duration, unsigned *patched, uint8_t *seen) {
    Box header;
    uint32_t id;
    size_t duration_offset, duration_width;
    if (!find_box(trak, BOX('t','k','h','d'), &header)
        || !time_fields(header, 8, &id, &duration_offset, &duration_width)) {
        return 0;
    }

    const AudioTrack *track = id > 0 && id <= aac->track_count ? &aac->tracks[id - 1] : NULL;
    uint64_t duration = duration_width == 4
        ? AV_RB32(header.begin + duration_offset) : AV_RB64(header.begin + duration_offset);
    if (!track || !track->count) {
        size_t size = (size_t)(trak.end - trak.begin);
        memcpy(*output, trak.begin, size);
        *output += size;
    } else {
        if (seen[id - 1]) {
            return 0;
        }
        seen[id - 1] = 1;

        Box media, media_header;
        uint32_t timescale;
        size_t media_offset, media_width;
        if (!find_box(trak, BOX('m','d','i','a'), &media)
            || !find_box(media, BOX('m','d','h','d'), &media_header)
            || !time_fields(media_header, 4, &timescale, &media_offset, &media_width)
            || timescale != (uint32_t)track->sample_rate) {
            return 0;
        }

        duration = 0;
        for (size_t i = 0; i < track->count; i++) {
            if ((uint64_t)track->edits[i].duration > UINT64_MAX - duration) {
                return 0;
            }
            duration += (uint64_t)track->edits[i].duration;
        }

        uint8_t *new_trak = *output;
        AV_WB32(new_trak + 4, trak.type);
        *output = new_trak + 8;
        for (const uint8_t *next = trak.payload; next < trak.end;) {
            Box child;
            if (!next_box(&next, trak.end, &child)) {
                return 0;
            }
            if (child.type == BOX('e','d','t','s')) {
                continue;
            }
            if (child.begin == header.begin) {
                *output += write_duration_header(*output, child, duration_offset, duration_width, duration);
            } else {
                size_t size = (size_t)(child.end - child.begin);
                memcpy(*output, child.begin, size);
                *output += size;
            }
        }
        *output = write_edits(*output, track);
        AV_WB32(new_trak, (uint32_t)(*output - new_trak));
        (*patched)++;
    }
    if (duration > *movie_duration) {
        *movie_duration = duration;
    }
    return 1;
}

/* FFmpeg's ordinary MOV mux layout places the movie metadata after all media.
 * Replacing that final box leaves every sample/chunk offset intact. */
static int locate_movie(FILE *file, int require_final, off_t *offset, size_t *size) {
    if (fseeko(file, 0, SEEK_END)) {
        return 0;
    }
    off_t end = ftello(file);
    if (end < 0) {
        return 0;
    }
    for (off_t position = 0; position < end;) {
        uint8_t header[16];
        if (end - position < 8 || fseeko(file, position, SEEK_SET)
            || fread(header, 1, 8, file) != 8) {
            return 0;
        }
        uint64_t length = AV_RB32(header);
        unsigned header_size = 8;
        if (length == 1) {
            if (fread(header + 8, 1, 8, file) != 8) {
                return 0;
            }
            length = AV_RB64(header + 8);
            header_size = 16;
        } else if (length == 0) {
            length = (uint64_t)(end - position);
        }
        if (length < header_size || length > (uint64_t)(end - position)) {
            return 0;
        }
        if (AV_RB32(header + 4) == BOX('m','o','o','v')) {
            if ((require_final && length != (uint64_t)(end - position)) || length > UINT32_MAX) {
                return 0;
            }
            *offset = position;
            *size = (size_t)length;
            return 1;
        }
        position += (off_t)length;
    }
    return 0;
}

static int rewrite_movie(const MPCutAAC *aac, const uint8_t *original, size_t original_size,
                         uint8_t *replacement, size_t *replacement_size, unsigned expected,
                         uint8_t *seen) {
    const uint8_t *position = original;
    Box moov, movie_header;
    size_t duration_offset, duration_width;
    uint32_t timescale;
    if (!next_box(&position, original + original_size, &moov)
        || !find_box(moov, BOX('m','v','h','d'), &movie_header)
        || !time_fields(movie_header, 4, &timescale, &duration_offset, &duration_width)
        || timescale != (uint32_t)aac->movie_timescale) {
        return 0;
    }

    AV_WB32(replacement + 4, moov.type);
    uint8_t *output = replacement + 8;
    uint8_t *new_movie_header = NULL;
    unsigned patched = 0;
    uint64_t movie_duration = 0;
    for (position = moov.payload; position < moov.end;) {
        Box child;
        if (!next_box(&position, moov.end, &child)) {
            return 0;
        }
        if (child.type == BOX('t','r','a','k')) {
            if (!rewrite_track(child, aac, &output, &movie_duration, &patched, seen)) {
                return 0;
            }
        } else {
            if (child.begin == movie_header.begin) {
                new_movie_header = output;
            }
            size_t size = (size_t)(child.end - child.begin);
            memcpy(output, child.begin, size);
            output += size;
        }
    }
    if (patched != expected || !new_movie_header) {
        return 0;
    }
    size_t old_header_size = (size_t)(movie_header.end - movie_header.begin);
    size_t new_header_size = duration_header_size(movie_header, duration_width, movie_duration);
    if (new_header_size > old_header_size) {
        uint8_t *after_header = new_movie_header + old_header_size;
        memmove(new_movie_header + new_header_size, after_header, (size_t)(output - after_header));
        output += new_header_size - old_header_size;
    }
    write_duration_header(new_movie_header, movie_header, duration_offset, duration_width, movie_duration);

    *replacement_size = (size_t)(output - replacement);
    AV_WB32(replacement, (uint32_t)*replacement_size);
    return 1;
}

int mpcut_aac_finalize(MPCutAAC *aac, const char *path, char *error, size_t cap) {
    if (!aac) {
        return 0;
    }
    uint64_t extra_size = 12;
    unsigned expected = 0;
    for (unsigned i = 0; i < aac->track_count; i++) {
        if (aac->tracks[i].count) {
            extra_size += 36 + aac->tracks[i].count * 20;
            expected++;
        }
    }
    if (!expected) {
        return 0;
    }

    FILE *file = fopen(path, "r+b");
    if (!file) {
        return errorf(error, cap, "Cannot open movie for AAC edits: %s", path);
    }
    off_t offset = 0;
    size_t original_size = 0;
    size_t replacement_size = 0;
    uint8_t *original = NULL;
    uint8_t *replacement = NULL;
    int ok = locate_movie(file, 1, &offset, &original_size)
        && extra_size <= UINT32_MAX - original_size && !fseeko(file, offset, SEEK_SET);
    if (ok) {
        original = malloc(original_size);
        replacement = malloc(original_size + (size_t)extra_size);
        uint8_t *seen = calloc(aac->track_count, sizeof(*seen));
        ok = original && replacement && seen && fread(original, 1, original_size, file) == original_size
            && rewrite_movie(aac, original, original_size, replacement, &replacement_size, expected, seen);
        free(seen);
    }
    if (ok) {
        ok = !fseeko(file, offset, SEEK_SET)
            && fwrite(replacement, 1, replacement_size, file) == replacement_size
            && !fflush(file) && !ftruncate(fileno(file), offset + (off_t)replacement_size);
    }
    if (fclose(file)) {
        ok = 0;
    }
    free(original);
    free(replacement);
    return ok ? 0 : errorf(error, cap, "Cannot write AAC track edits to %s", path);
}

int mpcut_align_copied_aac(const char *path, unsigned index, int rate, int64_t priming,
                           MPCutTime start, MPCutTime end, int movie_timescale,
                           char *error, size_t cap) {
    if (index >= INT_MAX || rate <= 0 || priming < 0 || movie_timescale <= 0)
        return errorf(error, cap, "Invalid AAC track timing.");
    MPCutAAC *layout = mpcut_aac_create(index + 1, movie_timescale);
    if (!layout)
        return errorf(error, cap, "Could not allocate the AAC edit list.");
    int status = 0;
    if (start.numerator > 0)
        status = mpcut_aac_empty(layout, index, rate, (MPCutTime){0, 1}, start, error, cap);
    if (!status)
        status = mpcut_aac_begin(layout, index, rate, (MPCutTime){0, 1}, start, end, error, cap);
    if (!status)
        status = append_edit(layout, index, priming, error, cap);
    if (!status)
        status = mpcut_aac_finalize(layout, path, error, cap);
    mpcut_aac_free(layout);
    return status;
}

typedef struct AACSourceTrack {
    struct AACSourceTrack *next;
    int id;
    int sample_rate;
    size_t count;
    MPCutAACSourceEdit edits[];
} AACSourceTrack;

struct MPCutAACSource {
    AACSourceTrack *tracks;
};

void mpcut_aac_source_free(MPCutAACSource *source) {
    if (source) {
        while (source->tracks) {
            AACSourceTrack *track = source->tracks;
            source->tracks = track->next;
            free(track);
        }
        free(source);
    }
}

const MPCutAACSourceEdit *mpcut_aac_source_track(const MPCutAACSource *source, int track_id,
                                                size_t *count, int *sample_rate) {
    *count = 0;
    *sample_rate = 0;
    for (const AACSourceTrack *track = source ? source->tracks : NULL; track; track = track->next) {
        if (track->id == track_id) {
            *count = track->count;
            *sample_rate = track->sample_rate;
            return track->edits;
        }
    }
    return NULL;
}

static int read_source_track(MPCutAACSource *source, Box trak, uint32_t movie_timescale,
                             const MPCutAACTrackClock *clocks, size_t clock_count) {
    Box mdia, minf, stbl, stsd, entry, edts, elst;
    if (!find_box(trak, BOX('m','d','i','a'), &mdia)
        || !find_box(mdia, BOX('m','i','n','f'), &minf)
        || !find_box(minf, BOX('s','t','b','l'), &stbl)
        || !find_box(stbl, BOX('s','t','s','d'), &stsd)
        || stsd.end - stsd.payload < 8) {
        return 1;
    }
    const uint8_t *entry_position = stsd.payload + 8;
    if (!next_box(&entry_position, stsd.end, &entry) || entry.type != BOX('m','p','4','a')
        || !find_box(trak, BOX('e','d','t','s'), &edts)
        || !find_box(edts, BOX('e','l','s','t'), &elst)) {
        return 1;
    }

    Box tkhd;
    uint32_t track_id;
    size_t offset, field_width;
    if (!find_box(trak, BOX('t','k','h','d'), &tkhd)
        || !time_fields(tkhd, 8, &track_id, &offset, &field_width)
        || !track_id || track_id > INT_MAX) {
        return 0;
    }
    size_t index = 0;
    while (index < clock_count && clocks[index].track_id != (int)track_id) index++;
    if (index == clock_count) return 1;

    const uint8_t *start = elst.payload;
    if (elst.end - start < 8 || start[0] > 1) {
        return 0;
    }
    unsigned width = start[0] ? 8 : 4;
    unsigned stride = 2 * width + 4;
    uint32_t count = AV_RB32(start + 4);
    start += 8;
    if (!count) {
        return 1;
    }
    if (count > (size_t)(elst.end - start) / stride) {
        return 0;
    }
    if (count == 1) {
        /* MOV demuxing already handles a single, normal-speed media edit. */
        int64_t media = width == 8 ? (int64_t)AV_RB64(start + width) : (int32_t)AV_RB32(start + width);
        return media >= 0 && AV_RB32(start + 2 * width) == (1U << 16);
    }

    Box mdhd;
    uint32_t media_timescale;
    if (!find_box(mdia, BOX('m','d','h','d'), &mdhd)
        || !time_fields(mdhd, 4, &media_timescale, &offset, &field_width)
        || !media_timescale || media_timescale > INT_MAX
        || AV_RB32(stsd.payload + 4) != 1) {
        return 0;
    }
    int sample_rate = clocks[index].sample_rate;
    if (sample_rate <= 0) return 0;
    uint64_t media_duration = field_width == 8 ? AV_RB64(mdhd.begin + offset) : AV_RB32(mdhd.begin + offset);

    AACSourceTrack *track = malloc(sizeof(*track) + (size_t)count * sizeof(*track->edits));
    if (!track) {
        return 0;
    }
    track->id = (int)track_id;
    track->sample_rate = (int)sample_rate;
    track->count = count;
    track->next = source->tracks;
    source->tracks = track;

    int64_t cursor = 0;
    int64_t presentation_start = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *edit = start + (size_t)i * stride;
        uint64_t duration = width == 8 ? AV_RB64(edit) : AV_RB32(edit);
        int64_t media = width == 8 ? (int64_t)AV_RB64(edit + width) : (int32_t)AV_RB32(edit + width);
        if (!duration || duration > (uint64_t)(INT64_MAX - cursor) || media < -1
            || AV_RB32(edit + 2 * width) != (1U << 16)) {
            return 0;
        }
        cursor += (int64_t)duration;
        int64_t presentation_end = av_rescale(cursor, sample_rate, movie_timescale);
        /* The edit's media offset and mdhd duration use the media clock.
         * Convert them separately from the movie-clock presentation boundaries. */
        int64_t media_sample = media < 0 ? -1 : av_rescale(media, sample_rate, media_timescale);
        /* A fractional-sample media offset cannot survive conversion to the
         * destination sample clock without changing the decoded waveform. */
        if (media >= 0 && (__int128)media_sample * media_timescale != (__int128)media * sample_rate)
            return 0;
        __int128 media_end = (__int128)media_sample + (presentation_end - (__int128)presentation_start);
        if (presentation_end <= presentation_start || (media >= 0
            && (media_sample < 0 || media_end > INT64_MAX ||
                (media_end - 1) * media_timescale > (__int128)media_duration * sample_rate))) {
            return 0;
        }
        track->edits[i] = (MPCutAACSourceEdit){presentation_start, presentation_end, media_sample};
        presentation_start = presentation_end;
    }
    return 1;
}

int mpcut_aac_source_open(const char *path, const MPCutAACTrackClock *clocks, size_t clock_count,
                          MPCutAACSource **source, char *error, size_t cap) {
    *source = NULL;
    FILE *file = fopen(path, "rb");
    if (!file) {
        return errorf(error, cap, "Cannot open MOV AAC track metadata in %s", path);
    }
    off_t offset;
    size_t size;
    if (!locate_movie(file, 0, &offset, &size)) {
        /* Other MOV layouts, such as media segments, have no movie edit list. */
        fclose(file);
        return 0;
    }
    uint8_t *bytes = malloc(size);
    int ok = bytes && !fseeko(file, offset, SEEK_SET) && fread(bytes, 1, size, file) == size;
    fclose(file);
    if (!ok) {
        free(bytes);
        return errorf(error, cap, "Cannot read MOV AAC track metadata in %s", path);
    }
    MPCutAACSource *map = calloc(1, sizeof(*map));
    if (!map) {
        free(bytes);
        return errorf(error, cap, "Cannot allocate AAC edit state");
    }
    Box moov, mvhd;
    uint32_t timescale;
    size_t duration_offset, duration_width;
    const uint8_t *next = bytes;
    ok = map && next_box(&next, bytes + size, &moov)
        && find_box(moov, BOX('m','v','h','d'), &mvhd)
        && time_fields(mvhd, 4, &timescale, &duration_offset, &duration_width)
        && timescale > 0 && timescale <= INT_MAX;
    if (ok) {
        for (next = moov.payload; next < moov.end;) {
            Box child;
            if (!next_box(&next, moov.end, &child)
                || (child.type == BOX('t','r','a','k') && !read_source_track(map, child, timescale, clocks, clock_count))) {
                ok = 0;
                break;
            }
        }
    }
    free(bytes);
    if (!ok) {
        mpcut_aac_source_free(map);
        return errorf(error, cap, "Unsupported AAC media edit list in %s", path);
    }
    if (map->tracks) {
        *source = map;
    } else {
        mpcut_aac_source_free(map);
    }
    return 0;
}

/* A raw (-ignore_editlist) copy retains all coded access units in the source's
 * media clock. Install its original sample-to-presentation mapping on the new
 * track, shifting only its presentation in the destination movie. */
int mpcut_restore_copied_aac(const char *source_path, int source_id, int sample_rate, const char *output_path,
                             unsigned index, MPCutTime shift, int movie_timescale,
                             char *error, size_t cap) {
    MPCutAACSource *source = NULL;
    MPCutAACTrackClock clock = {source_id, sample_rate};
    int status = mpcut_aac_source_open(source_path, &clock, 1, &source, error, cap);
    if (status) return status;
    size_t count = 0;
    int rate = 0;
    const MPCutAACSourceEdit *edits = mpcut_aac_source_track(source, source_id, &count, &rate);
    if (!edits || !count || index >= INT_MAX || rate <= 0 || movie_timescale <= 0) {
        mpcut_aac_source_free(source);
        return errorf(error, cap, "The copied AAC presentation edits are unavailable.");
    }
    MPCutAAC *layout = mpcut_aac_create(index + 1, movie_timescale);
    if (!layout) {
        mpcut_aac_source_free(source);
        return errorf(error, cap, "Could not allocate the copied AAC edit list.");
    }
    int64_t offset = ticks(shift, rate);
    if (offset == INT64_MIN) status = errorf(error, cap, "Invalid AAC presentation offset.");
    if (!status && offset > 0)
        status = mpcut_aac_empty(layout, index, rate, (MPCutTime){0, 1},
                                 (MPCutTime){offset, rate}, error, cap);
    for (size_t i = 0; i < count && !status; i++) {
        if (offset > 0 && edits[i].presentation_end > INT64_MAX - offset) {
            status = errorf(error, cap, "The AAC presentation offset overflows.");
            break;
        }
        int64_t from = edits[i].presentation_start + offset;
        int64_t end = edits[i].presentation_end + offset;
        if (edits[i].media_start >= 0 && from < 0) {
            status = errorf(error, cap, "The AAC presentation starts before movie time zero.");
            break;
        }
        if (end <= 0) continue; /* The original leading silence preceded the new movie. */
        if (from < 0) from = 0;
        status = mpcut_aac_begin(layout, index, rate, (MPCutTime){0, 1},
                                 (MPCutTime){from, rate}, (MPCutTime){end, rate}, error, cap);
        if (!status) status = append_edit(layout, index, edits[i].media_start, error, cap);
    }
    if (!status) status = mpcut_aac_finalize(layout, output_path, error, cap);
    mpcut_aac_free(layout);
    mpcut_aac_source_free(source);
    return status;
}

/* --- Chapter track ---
 * The MOV muxer times its chapter track on the movie clock. At this writer's movie
 * timescale a 32-bit sample duration holds about three seconds, so the muxer would
 * drop every longer chapter. The writer therefore hands the muxer chapter times
 * counted in milliseconds. This pass gives the finished track the clock those
 * numbers were counted on and restates its length in movie time. */
static int relabel_chapter_track(Box trak, uint32_t movie_timescale, uint64_t movie_duration, uint8_t **output) {
    enum { CHAPTER_TIMESCALE = 1000 };
    Box header, media, media_header;
    uint32_t id, timescale;
    size_t duration_offset, duration_width, media_offset, media_width;
    if (!find_box(trak, BOX('t','k','h','d'), &header)
        || !time_fields(header, 8, &id, &duration_offset, &duration_width)
        || !find_box(trak, BOX('m','d','i','a'), &media)
        || !find_box(media, BOX('m','d','h','d'), &media_header)
        || !time_fields(media_header, 4, &timescale, &media_offset, &media_width)
        || timescale != movie_timescale) {
        return 0;
    }
    uint64_t length = media_width == 4 ? AV_RB32(media_header.begin + media_offset)
                                       : AV_RB64(media_header.begin + media_offset);
    if (!length || length > INT64_MAX / movie_timescale || !movie_duration) {
        return 0;
    }
    /* The muxer starts the first chapter sample at zero, so one edit presents the whole track. */
    int64_t extent = av_rescale((int64_t)length, movie_timescale, CHAPTER_TIMESCALE);
    if ((uint64_t)extent > movie_duration) {
        extent = (int64_t)movie_duration; /* The last chapter ends with the movie. */
    }
    Edit entry = {extent, 0};
    AudioTrack layout = {.edits = &entry, .count = 1};

    uint8_t *new_trak = *output;
    AV_WB32(new_trak + 4, trak.type);
    *output = new_trak + 8;
    for (const uint8_t *next = trak.payload; next < trak.end;) {
        Box child;
        if (!next_box(&next, trak.end, &child)) {
            return 0;
        }
        if (child.type == BOX('e','d','t','s')) {
            continue;
        }
        if (child.begin == header.begin) {
            *output += write_duration_header(*output, child, duration_offset, duration_width, (uint64_t)extent);
            continue;
        }
        size_t size = (size_t)(child.end - child.begin);
        memcpy(*output, child.begin, size);
        if (child.begin == media.begin) {
            AV_WB32(*output + (media_header.begin - media.begin) + media_offset - 4, CHAPTER_TIMESCALE);
        }
        *output += size;
    }
    *output = write_edits(*output, &layout);
    AV_WB32(new_trak, (uint32_t)(*output - new_trak));
    return 1;
}

static uint32_t track_id(Box trak) {
    Box header;
    uint32_t id;
    size_t offset, width;
    return find_box(trak, BOX('t','k','h','d'), &header) && time_fields(header, 8, &id, &offset, &width) ? id : 0;
}

int mpcut_mov_finish_chapters(const char *path, int movie_timescale, char *error, size_t cap) {
    enum { GROWTH = 64 }; /* A 64-bit track header and edit list. */
    FILE *file = fopen(path, "r+b");
    if (!file) {
        return errorf(error, cap, "Cannot open movie to finish its chapter track: %s", path);
    }
    off_t offset = 0;
    size_t original_size = 0;
    uint8_t *original = NULL;
    uint8_t *replacement = NULL;
    uint8_t *output = NULL;
    int ok = movie_timescale > 0 && locate_movie(file, 1, &offset, &original_size)
        && original_size <= UINT32_MAX - GROWTH && !fseeko(file, offset, SEEK_SET);
    if (ok) {
        original = malloc(original_size);
        replacement = malloc(original_size + GROWTH);
        ok = original && replacement && fread(original, 1, original_size, file) == original_size;
    }
    const uint8_t *position = original;
    Box moov = {0}, movie_header;
    uint32_t timescale = 0, chapters = 0;
    size_t duration_offset = 0, duration_width = 0;
    ok = ok && next_box(&position, original + original_size, &moov)
        && find_box(moov, BOX('m','v','h','d'), &movie_header)
        && time_fields(movie_header, 4, &timescale, &duration_offset, &duration_width)
        && timescale == (uint32_t)movie_timescale;
    /* Every media track names the chapter track in a 'chap' reference. */
    for (position = moov.payload; ok && !chapters && position < moov.end;) {
        Box child, references, reference;
        if (!next_box(&position, moov.end, &child)) {
            ok = 0;
        } else if (child.type == BOX('t','r','a','k') && find_box(child, BOX('t','r','e','f'), &references)
                   && find_box(references, BOX('c','h','a','p'), &reference) && reference.end - reference.payload >= 4) {
            chapters = AV_RB32(reference.payload);
        }
    }
    ok = ok && chapters;
    unsigned relabeled = 0;
    if (ok) {
        uint64_t movie_duration = duration_width == 4 ? AV_RB32(movie_header.begin + duration_offset)
                                                      : AV_RB64(movie_header.begin + duration_offset);
        AV_WB32(replacement + 4, moov.type);
        output = replacement + 8;
        for (position = moov.payload; ok && position < moov.end;) {
            Box child;
            if (!next_box(&position, moov.end, &child)) {
                ok = 0;
            } else if (child.type == BOX('t','r','a','k') && track_id(child) == chapters) {
                ok = !relabeled++ && relabel_chapter_track(child, timescale, movie_duration, &output);
            } else {
                size_t size = (size_t)(child.end - child.begin);
                memcpy(output, child.begin, size);
                output += size;
            }
        }
        ok = ok && relabeled == 1;
    }
    if (ok) {
        size_t replacement_size = (size_t)(output - replacement);
        AV_WB32(replacement, (uint32_t)replacement_size);
        ok = !fseeko(file, offset, SEEK_SET)
            && fwrite(replacement, 1, replacement_size, file) == replacement_size
            && !fflush(file) && !ftruncate(fileno(file), offset + (off_t)replacement_size);
    }
    if (fclose(file)) {
        ok = 0;
    }
    free(original);
    free(replacement);
    return ok ? 0 : errorf(error, cap, "Cannot finish the chapter track in %s", path);
}

/* Check an hvcC record and, when `apply` is set, mark its arrays of video, sequence
 * and picture parameter sets complete, as 'hvc1' requires. */
static int complete_hvcc(uint8_t *config, size_t size, int apply) {
    if (size < 23 || config[0] != 1)
        return 0;
    uint8_t *p = config + 23, *end = config + size;
    for (unsigned array = 0; array < config[22]; array++) {
        if (end - p < 3)
            return 0;
        unsigned type = p[0] & 0x3f, count = AV_RB16(p + 1);
        if (apply && type >= 32 && type <= 34)
            p[0] |= 0x80;
        p += 3;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2 || (size_t)(end - p - 2) < AV_RB16(p))
                return 0;
            p += 2 + AV_RB16(p);
        }
    }
    return 1;
}

/* Turn one track's 'hev1' sample entries into 'hvc1' in place. The boxes keep their
 * sizes, so the copy in `movie` maps byte for byte onto the file. A track with any
 * other entry, or an unreadable hvcC, is left as the muxer wrote it. */
static int label_hvc1(uint8_t *movie, Box trak) {
    enum { VISUAL_SAMPLE_ENTRY = 78 };
    Box media, information, table, descriptions;
    if (!find_box(trak, BOX('m','d','i','a'), &media) || !find_box(media, BOX('m','i','n','f'), &information)
        || !find_box(information, BOX('s','t','b','l'), &table)
        || !find_box(table, BOX('s','t','s','d'), &descriptions) || descriptions.end - descriptions.payload < 8)
        return 0;
    const uint32_t count = AV_RB32(descriptions.payload + 4);
    for (int apply = 0; apply < 2; apply++) { // Check every entry before changing any.
        const uint8_t *position = descriptions.payload + 8;
        for (uint32_t i = 0; i < count; i++) {
            Box entry, config;
            if (!next_box(&position, descriptions.end, &entry) || entry.type != BOX('h','e','v','1')
                || entry.end - entry.payload < VISUAL_SAMPLE_ENTRY)
                return 0;
            Box fields = {entry.begin, entry.payload + VISUAL_SAMPLE_ENTRY, entry.end, entry.type};
            if (!find_box(fields, BOX('h','v','c','C'), &config)
                || !complete_hvcc(movie + (config.payload - movie), (size_t)(config.end - config.payload), apply))
                return 0;
            if (apply)
                AV_WB32(movie + (entry.begin - movie) + 4, BOX('h','v','c','1'));
        }
    }
    return count > 0;
}

int mpcut_mov_label_hvc1(const char *path, const uint32_t *track_ids, size_t count, char *error, size_t cap) {
    if (!count)
        return 0;
    FILE *file = fopen(path, "r+b");
    if (!file)
        return errorf(error, cap, "Cannot open movie to label its HEVC sample entries: %s", path);
    off_t offset = 0;
    size_t size = 0;
    uint8_t *movie = NULL;
    int ok = locate_movie(file, 0, &offset, &size) && !fseeko(file, offset, SEEK_SET)
        && (movie = malloc(size)) && fread(movie, 1, size, file) == size;
    const uint8_t *position = movie;
    Box moov = {0};
    ok = ok && next_box(&position, movie + size, &moov);
    size_t labeled = 0;
    for (position = moov.payload; ok && position < moov.end;) {
        Box child;
        if (!next_box(&position, moov.end, &child)) {
            ok = 0;
        } else if (child.type == BOX('t','r','a','k')) {
            uint32_t id = track_id(child);
            for (size_t i = 0; i < count; i++)
                if (track_ids[i] == id)
                    labeled += label_hvc1(movie, child);
        }
    }
    // A track left 'hev1' (an entry of another kind, or an hvcC without every set) would not play in AVFoundation
    // or QuickTime although the copy was planned as 'hvc1', so it fails here instead of being kept unlabeled.
    int unlabeled = ok && labeled != count;
    if (ok && !unlabeled)
        ok = !fseeko(file, offset, SEEK_SET) && fwrite(movie, 1, size, file) == size && !fflush(file);
    if (fclose(file))
        ok = 0;
    free(movie);
    if (unlabeled)
        return errorf(error, cap, "Cannot describe the HEVC picture in %s as hvc1, so AVFoundation and QuickTime could "
                      "not play the copy", path);
    return ok ? 0 : errorf(error, cap, "Cannot label the HEVC sample entries in %s", path);
}

typedef struct {
    size_t ancestors[5]; /* moov, trak, mdia, minf, stbl: the boxes that contain the stts box */
    size_t stts, stts_end, mdhd_duration, mdhd_width;
    uint64_t target;
} ShortTrack;

/* A video track that presents the planned duration in one media edit, while its
 * sample table, and so its media header, ends before that edit does. */
static int short_track(Box trak, const uint8_t *movie, uint32_t movie_timescale, int64_t planned, ShortTrack *found) {
    Box media, handler, header, information, table, samples, edits, list;
    uint32_t timescale;
    size_t offset, width;
    if (!find_box(trak, BOX('m','d','i','a'), &media) || !find_box(media, BOX('h','d','l','r'), &handler)
        || handler.end - handler.payload < 12 || AV_RB32(handler.payload + 8) != BOX('v','i','d','e')
        || !find_box(media, BOX('m','d','h','d'), &header) || !time_fields(header, 4, &timescale, &offset, &width)
        || !timescale || !find_box(media, BOX('m','i','n','f'), &information)
        || !find_box(information, BOX('s','t','b','l'), &table) || !find_box(table, BOX('s','t','t','s'), &samples)
        || !find_box(trak, BOX('e','d','t','s'), &edits) || !find_box(edits, BOX('e','l','s','t'), &list)
        || list.end - list.payload < 8)
        return 0;
    const int version = list.payload[0];
    const size_t entry_size = version == 1 ? 20 : 12;
    const uint32_t count = AV_RB32(list.payload + 4);
    if ((version != 0 && version != 1) || (size_t)(list.end - list.payload - 8) / entry_size < count)
        return 0;
    uint64_t edit_end = 0, segment = 0;
    unsigned media_edits = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *entry = list.payload + 8 + i * entry_size;
        uint64_t duration = version == 1 ? AV_RB64(entry) : AV_RB32(entry);
        int64_t media_time = version == 1 ? (int64_t)AV_RB64(entry + 8) : (int32_t)AV_RB32(entry + 4);
        if (duration > UINT64_MAX - edit_end)
            return 0;
        edit_end += duration;
        if (media_time != -1) {
            segment = duration;
            media_edits++;
        }
    }
    if (media_edits != 1 || planned < 0 || segment > INT64_MAX
        || (edit_end > (uint64_t)planned ? edit_end - (uint64_t)planned : (uint64_t)planned - edit_end) > 1)
        return 0;
    uint64_t media_duration = width == 4 ? AV_RB32(header.begin + offset) : AV_RB64(header.begin + offset);
    // FFmpeg reads a track as the shorter of its media header, its samples and its edit.
    int64_t target = av_rescale((int64_t)segment, timescale, movie_timescale);
    if (target <= 0 || media_duration >= (uint64_t)target || (width == 4 && target > UINT32_MAX))
        return 0;
    size_t entries = samples.end - samples.payload >= 8 ? AV_RB32(samples.payload + 4) : 0;
    if (!entries || (size_t)(samples.end - samples.payload - 8) / 8 < entries)
        return 0;
    const uint8_t *last = samples.payload + 8 + (entries - 1) * 8;
    uint64_t sum = 0;
    for (const uint8_t *entry = samples.payload + 8; entry <= last; entry += 8)
        sum += (uint64_t)AV_RB32(entry) * AV_RB32(entry + 4);
    if (sum != media_duration || AV_RB32(last + 4) + ((uint64_t)target - media_duration) > UINT32_MAX)
        return 0;
    found->stts = (size_t)(samples.begin - movie);
    found->stts_end = (size_t)(last + 8 - movie);
    found->mdhd_duration = (size_t)(header.begin - movie) + offset;
    found->mdhd_width = width;
    found->target = (uint64_t)target;
    found->ancestors[1] = (size_t)(trak.begin - movie);
    found->ancestors[2] = (size_t)(media.begin - movie);
    found->ancestors[3] = (size_t)(information.begin - movie);
    found->ancestors[4] = (size_t)(table.begin - movie);
    return 1;
}

static int grow_box(uint8_t *box, size_t growth) {
    uint64_t size = AV_RB32(box);
    if (size == 1) {
        size = AV_RB64(box + 8);
        if (size > UINT64_MAX - growth)
            return 0;
        AV_WB64(box + 8, size + growth);
        return 1;
    }
    if (size < 8 || size > UINT32_MAX - growth)
        return 0;
    AV_WB32(box, (uint32_t)(size + growth));
    return 1;
}

/* Give the last decoded sample the rest of the planned duration. */
static int cover_track(uint8_t *movie, size_t *size, const ShortTrack *track) {
    enum { ENTRY = 8 };
    uint8_t *samples = movie + track->stts;
    uint8_t *payload = samples + (AV_RB32(samples) == 1 ? 16 : 8);
    uint32_t entries = AV_RB32(payload + 4);
    uint8_t *last = payload + 8 + (size_t)(entries - 1) * ENTRY;
    uint8_t *media_duration = movie + track->mdhd_duration;
    uint64_t old = track->mdhd_width == 4 ? AV_RB32(media_duration) : AV_RB64(media_duration);
    uint32_t delta = AV_RB32(last + 4) + (uint32_t)(track->target - old);
    if (track->mdhd_width == 4)
        AV_WB32(media_duration, (uint32_t)track->target);
    else
        AV_WB64(media_duration, track->target);
    if (AV_RB32(last) == 1) {
        AV_WB32(last + 4, delta);
        return 1;
    }
    // Split the final run so that only the last sample takes the longer delta.
    uint8_t *end = movie + track->stts_end;
    memmove(end + ENTRY, end, *size - track->stts_end);
    AV_WB32(last, AV_RB32(last) - 1);
    AV_WB32(end, 1);
    AV_WB32(end + 4, delta);
    AV_WB32(payload + 4, entries + 1);
    *size += ENTRY;
    if (!grow_box(samples, ENTRY))
        return 0;
    for (int i = 0; i < 5; i++)
        if (!grow_box(movie + track->ancestors[i], ENTRY))
            return 0;
    return 1;
}

int mpcut_mov_cover_edits(const char *path, MPCutTime duration, char *error, size_t cap) {
    enum { MAX_TRACKS = 64, ENTRY = 8 };
    FILE *file = fopen(path, "r+b");
    if (!file)
        return errorf(error, cap, "Cannot open movie to finish its video sample tables: %s", path);
    off_t offset = 0;
    size_t size = 0;
    uint8_t *movie = NULL;
    if (!locate_movie(file, 1, &offset, &size)) {
        // A movie box that is not the file's last (a fragmented layout) cannot grow in place.
        fclose(file);
        return 0;
    }
    int ok = size <= UINT32_MAX - MAX_TRACKS * ENTRY
        && !fseeko(file, offset, SEEK_SET) && (movie = malloc(size + MAX_TRACKS * ENTRY))
        && fread(movie, 1, size, file) == size;
    int changed = 0;
    for (int pass = 0; ok && pass < MAX_TRACKS; pass++) {
        const uint8_t *position = movie;
        Box moov, movie_header;
        uint32_t movie_timescale;
        size_t duration_offset, duration_width;
        if (!next_box(&position, movie + size, &moov) || moov.type != BOX('m','o','o','v')
            || !find_box(moov, BOX('m','v','h','d'), &movie_header)
            || !time_fields(movie_header, 4, &movie_timescale, &duration_offset, &duration_width)
            || !movie_timescale || movie_timescale > INT_MAX) {
            ok = 0;
            break;
        }
        int64_t planned = ticks(duration, (int)movie_timescale);
        ShortTrack track = {{0}};
        int found = 0;
        for (position = moov.payload; !found && position < moov.end;) {
            Box child;
            if (!next_box(&position, moov.end, &child))
                break;
            found = child.type == BOX('t','r','a','k') && short_track(child, movie, movie_timescale, planned, &track);
        }
        if (!found)
            break;
        ok = cover_track(movie, &size, &track); // ancestors[0] is the movie box at offset 0.
        changed = 1;
    }
    if (ok && changed)
        ok = !fseeko(file, offset, SEEK_SET) && fwrite(movie, 1, size, file) == size && !fflush(file);
    if (fclose(file))
        ok = 0;
    free(movie);
    return ok ? 0 : errorf(error, cap, "Cannot finish the video sample tables in %s", path);
}
