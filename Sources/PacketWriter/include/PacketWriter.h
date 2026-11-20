#ifndef MPCUT_PACKET_WRITER_H
#define MPCUT_PACKET_WRITER_H

#include <stddef.h>
#include <stdint.h>

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
    MPCutTime source_origin; /* Indexed video presentation origin, when available. */
} MPCutSegment;

/* AAC presentation edits in their track's native sample clock. */
typedef struct MPCutAACSource MPCutAACSource;
typedef struct {
    int64_t presentation_start;
    int64_t presentation_end;
    int64_t media_start; /* -1 for an empty edit */
} MPCutAACSourceEdit;

int mpcut_aac_source_open(const char *path, MPCutAACSource **source, char *error, size_t error_capacity);
void mpcut_aac_source_free(MPCutAACSource *source);
const MPCutAACSourceEdit *mpcut_aac_source_track(const MPCutAACSource *source, int track_id,
                                                size_t *count, int *sample_rate);

/* Return a nonzero value from progress to cancel. Fraction is in [0, 1]. */
typedef int (*MPCutProgress)(void *context, double fraction);

/* Checks the input tracks against the output container without creating a file. */
int mpcut_check_mux(const char *input_path, const char *output_path, int padded_opus_track,
                    char *error, size_t error_capacity);

/* Write presentation end times (nanoseconds) into a staged WebM or MKV. */
int mpcut_set_matroska_durations(const char *path, const int64_t *ends, size_t count);

/* Validates an edit's timecode continuity and the first retained timecode sample. */
int mpcut_check_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                         const char *output_path, size_t *failed_segment,
                         MPCutProgress progress, void *context, char *error, size_t error_capacity);

/*
 * Ranges are prevalidated and relative to the primary video presentation origin.
 * output_path is a temporary file with the destination's real extension.
 * Returns 0 on success, 1 on failure, or 2 on cancellation.
 */
int mpcut_write(const MPCutSegment *segments, size_t count, const char *output_path, int audio_only,
                MPCutProgress progress, void *context, char *error, size_t error_capacity);

#endif
