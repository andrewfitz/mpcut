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
    int generated_still; /* Internally generated video-only span with verified picture properties. */
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

/* Selected primary tracks. Linked copies also preserve supported MOV timecode.
 * ALL, AUDIO and the two DELIVERED selections write a file a person keeps: its chapters travel
 * with it, and a sound-only source copied with every audio track keeps its cover art.
 * VIDEO, LINKED_AUDIO and PROGRAM_AUDIO stage a lane for a later mux and carry neither. */
enum {
    MPCUT_TRACKS_ALL = 0, MPCUT_TRACKS_AUDIO = 1, MPCUT_TRACKS_VIDEO = 2,
    MPCUT_TRACKS_LINKED_AUDIO = 3, /* A temporary soundtrack aligned to the linked movie's clock. */
    MPCUT_TRACKS_PROGRAM_AUDIO = 4, /* An independent soundtrack bounded by its planned ranges. */
    MPCUT_TRACKS_DELIVERED_VIDEO = 5, /* A picture-only movie a person asked for. */
    MPCUT_TRACKS_DELIVERED_VIDEO_TIMECODE = 6 /* The same, keeping the source's MOV timecode track. */
};

/* Validate one standalone MP3 crop on its absolute decoded-sample clock. */
int mpcut_check_mp3_crop(const char *path, int stream_index, int64_t start_sample, int64_t end_sample,
                         MPCutMP3Anchor anchor, MPCutProgress progress, void *context, char *error, size_t capacity);

/* Checks the selected tracks against the output container without creating a file.
 * All audio-only selections use the same track compatibility checks. */
int mpcut_check_mux(const char *input_path, const char *output_path, int padded_opus_track, int tracks, int audio_stream,
                    char *error, size_t error_capacity);

/* Check several output paths against one open source, writing one boolean per path. */
void mpcut_check_muxes(const char *input_path, const char *const *output_paths, size_t count,
                      int padded_opus_track, int tracks, int audio_stream, uint8_t *supported);

/* Write presentation end times (nanoseconds) into a staged WebM or MKV. */
int mpcut_set_matroska_durations(const char *path, const int64_t *ends, size_t count);

typedef struct {
    int64_t pts;
    int64_t duration;
} MPCutMatroskaBlock;

/* Verify video presentation timestamps and declared block durations (milliseconds).
 * A zero expected duration checks the timestamp only. */
int mpcut_verify_matroska_video(const char *path, const MPCutMatroskaBlock *expected, size_t count);

/* Restage a video-only MOV with in-band parameter sets at random access points.
 * This carries changes in MOV sample descriptions into a single Matroska stream. */
int mpcut_stage_matroska_picture(const char *input_path, const char *output_path,
                                MPCutProgress progress, void *context, char *error, size_t error_capacity);

/* Validates an edit's timecode continuity and the first retained timecode sample.
 * On a segment-specific failure, failed_segment receives its one-based index. */
int mpcut_check_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                         const char *output_path, size_t *failed_segment,
                         MPCutProgress progress, void *context, char *error, size_t error_capacity);

/* The same check for a picture-only copy that would keep the timecode track
 * (MPCUT_TRACKS_DELIVERED_VIDEO_TIMECODE). Audio tracks do not affect it. */
int mpcut_check_video_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                               const char *output_path, size_t *failed_segment,
                               MPCutProgress progress, void *context, char *error, size_t error_capacity);

/* List what mpcut_write would leave out with these arguments: cover art or chapters the
 * output container cannot store, and chapters that cannot be placed on the output timeline.
 * Writes one sentence per line into notes, or an empty string. Only file headers are read.
 * Returns nonzero when a source or the output container cannot be examined. */
int mpcut_copy_omissions(const MPCutSegment *segments, size_t count, const char *output_path,
                         int tracks, int audio_stream, char *notes, size_t capacity);

/*
 * Ranges are prevalidated and relative to source_origin. audio_stream is an
 * absolute FFmpeg stream index, or -1 for every selected audio stream.
 * output_path is a temporary file with the destination's real extension.
 * Returns 0 on success, 1 on failure, or 2 on cancellation.
 */
int mpcut_write(const MPCutSegment *segments, size_t count, const char *output_path, int tracks, int audio_stream,
                const uint32_t *still_mastering_display, /* Optional 10-element GBR/white/luminance tuple. */
                MPCutProgress progress, void *context, char *error, size_t error_capacity);

#endif
