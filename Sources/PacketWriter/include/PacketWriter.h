#ifndef MPCUT_PACKET_WRITER_H
#define MPCUT_PACKET_WRITER_H

#include <stddef.h>
#include <stdint.h>

/* Clear recording-specific fields in a FLAC STREAMINFO decoder configuration. */
void mpcut_normalize_flac_streaminfo(uint8_t *bytes, size_t size);

typedef struct {
    int64_t numerator;
    int64_t denominator;
} MPCutTime;

typedef struct {
    MPCutTime from;
    MPCutTime to;
    size_t frame_count;
    MPCutTime decode_from;
    int64_t target_bit_rate;
} MPCutEdgeRange;

/* Xing stores 12 bits of encoder delay in addition to decoder latency. */
enum { MPCUT_MP3_MAX_SKIP = 4095 + 529 };
typedef struct {
    int64_t sample, offset;
    uint32_t checksum;
} MPCutMP3Anchor;

typedef struct {
    const char *path;
    MPCutTime start;
    MPCutTime end;
    MPCutTime last_video_frame; /* Presentation time relative to source video origin. */
    int reaches_end;
    const int32_t *opus_pre_skip; /* Per-track decoder preroll for a standalone Opus trim. */
    size_t opus_track_count;
    MPCutEdgeRange head_edge;
    MPCutEdgeRange tail_edge;
    int multiple_descriptions; /* Source MOV contains multiple video sample descriptions. */
    const MPCutTime *video_dts; /* Optional output decode slots for Smart Trim MOV splices. */
    size_t video_dts_count;
    MPCutTime source_origin; /* Indexed video or audio presentation origin, when available. */
    MPCutTime output_start; /* Planned movie time of the range start. Positive in a whole MOV copy whose linked audio leads. */
    unsigned audio_stream_override; /* Absolute audio stream index + 1, or 0 to use the export-wide selector. */
    MPCutMP3Anchor mp3_anchor;
} MPCutSegment;

/* AAC presentation edits in their track's native sample clock. */
typedef struct MPCutAACSource MPCutAACSource;
typedef struct {
    int64_t presentation_start;
    int64_t presentation_end;
    int64_t media_start; /* -1 for an empty edit */
} MPCutAACSourceEdit;

typedef struct {
    int track_id;
    int sample_rate;
} MPCutAACTrackClock;

int mpcut_aac_source_open(const char *path, const MPCutAACTrackClock *clocks, size_t clock_count,
                          MPCutAACSource **source, char *error, size_t error_capacity);
void mpcut_aac_source_free(MPCutAACSource *source);
const MPCutAACSourceEdit *mpcut_aac_source_track(const MPCutAACSource *source, int track_id,
                                                size_t *count, int *sample_rate);

/* Restore a copied AAC stream's decoder priming after moving it to a positive
 * presentation time. The MOV payload and its sample tables stay byte-identical. */
int mpcut_align_copied_aac(const char *path, unsigned track_index, int sample_rate,
                           int64_t priming, MPCutTime start, MPCutTime end, int movie_timescale,
                           char *error, size_t capacity);

int mpcut_restore_copied_aac(const char *source_path, int source_track_id, int sample_rate, const char *output_path,
                             unsigned output_index, MPCutTime shift, int movie_timescale,
                             char *error, size_t capacity);

/* Return a nonzero value from progress to cancel. Fraction is in [0, 1]. */
typedef int (*MPCutProgress)(void *context, double fraction);

/* Selected primary tracks. Linked copies also preserve supported MOV timecode. */
enum {
    MPCUT_TRACKS_ALL = 0, MPCUT_TRACKS_AUDIO = 1, MPCUT_TRACKS_VIDEO = 2,
    MPCUT_TRACKS_LINKED_AUDIO = 3, /* A temporary soundtrack aligned to the linked movie's clock. */
    MPCUT_TRACKS_PROGRAM_AUDIO = 4 /* An independent soundtrack bounded by its planned ranges. */
};

/* Validate one standalone MP3 crop on its absolute decoded-sample clock. */
int mpcut_check_mp3_crop(const char *path, int stream_index, int64_t start_sample, int64_t end_sample,
                         MPCutMP3Anchor anchor, MPCutProgress progress, void *context, char *error, size_t capacity);

/* Checks the selected tracks against the output container without creating a file. */
int mpcut_check_mux(const char *input_path, const char *output_path, int padded_opus_track, int tracks, int audio_stream,
                    char *error, size_t error_capacity);

/* Write presentation end times (nanoseconds) into a staged WebM or MKV. */
int mpcut_set_matroska_durations(const char *path, const int64_t *ends, size_t count);

/* Validates an edit's timecode continuity and the first retained timecode sample. */
int mpcut_check_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                         const char *output_path, size_t *failed_segment,
                         MPCutProgress progress, void *context, char *error, size_t error_capacity);

/*
 * Ranges are prevalidated and relative to source_origin. audio_stream is an
 * absolute FFmpeg stream index, or -1 for every selected audio stream.
 * output_path is a temporary file with the destination's real extension.
 * Returns 0 on success, 1 on failure, or 2 on cancellation.
 */
int mpcut_write(const MPCutSegment *segments, size_t count, const char *output_path, int tracks, int audio_stream,
                MPCutProgress progress, void *context, char *error, size_t error_capacity);

#endif
