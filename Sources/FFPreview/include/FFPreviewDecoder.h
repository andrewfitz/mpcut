#pragma once

#include <CoreMedia/CoreMedia.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef struct MPPreviewDecoder MPPreviewDecoder;

enum MPPreviewResult {
    MPPreviewError = -1,
    MPPreviewEnd = 0,
    MPPreviewVideo = 1,
    MPPreviewAudio = 2,
    MPPreviewAgain = 3
};

typedef bool (*MPPreviewCancelled)(void *context);

enum MPPreviewTracks {
    MPPreviewPictureAndSound,
    MPPreviewPictureOnly,
    MPPreviewSoundOnly
};

/* A valid origin is the source presentation timestamp at timeline zero.
 * An audio ordinal of -1 mixes linked movie tracks or selects the first standalone sound track. */
MPPreviewDecoder *mp_preview_open(const char *path, enum MPPreviewTracks tracks, int audio_ordinal, CMTime origin,
                                 MPPreviewCancelled cancelled,
                                 void *context, const char **error);
/* Before the first read, request native YUV surfaces for a Smart Trim encode.
 * The returned stream belongs to this decoder and includes its probed configuration. */
struct AVStream;
const struct AVStream *mp_preview_prepare_edge(MPPreviewDecoder *preview);
void mp_preview_coded_size(const MPPreviewDecoder *preview, int *width, int *height);
void mp_preview_close(MPPreviewDecoder *preview);
/* Select picture-only scrubbing or A/V playback before the next seek. */
void mp_preview_enable_audio(MPPreviewDecoder *preview, bool enabled);
/* Request the selected stream's surround layout before reading its first sample. */
void mp_preview_preserve_surround(MPPreviewDecoder *preview);
/* Keep the selected source channel order, including a single mono channel. */
void mp_preview_preserve_audio_channels(MPPreviewDecoder *preview);
bool mp_preview_has_audio(const MPPreviewDecoder *preview);
bool mp_preview_has_unavailable_audio(const MPPreviewDecoder *preview);
/* Seconds count from the video track's first picture, whatever origin was given to mp_preview_open. */
bool mp_preview_seek(MPPreviewDecoder *preview, double seconds);
/* Seconds count from the origin of the presented sample times. The two differ
 * when an explicit origin precedes a picture track that starts late. */
bool mp_preview_seek_timeline(MPPreviewDecoder *preview, double seconds);
/* On MPPreviewVideo or MPPreviewAudio, the caller owns the returned sample.
 * MPPreviewAgain means no sample is ready and the caller may retry. */
int mp_preview_next(MPPreviewDecoder *preview, CMSampleBufferRef *sample CF_RETURNS_RETAINED,
                    const char **error);
/* For picture-only preview. On MPPreviewVideo, the caller owns the image and
 * receives its presentation timing. Other results leave the image empty. */
int mp_preview_next_picture(MPPreviewDecoder *preview, CVPixelBufferRef *image CF_RETURNS_RETAINED,
                            CMTime *pts, CMTime *duration, const char **error);
/* Whether the decoder rejected a picture since the last seek. A preview then resumes at the
 * next keyframe and omits the pictures in between. A Smart Trim edge returns the intact
 * pictures decoded before the damage and then reports an error. */
bool mp_preview_met_damage(const MPPreviewDecoder *preview);
/* For a Smart Trim edge that ended with a damage error: every picture returned before the
 * error was decoded from packets that precede the damaged one. */
bool mp_preview_edge_intact_before_damage(const MPPreviewDecoder *preview);
CGAffineTransform mp_preview_transform(const MPPreviewDecoder *preview);

/* The program mixer accepts timestamped, interleaved Float PCM on the output
 * clock. When next returns Again with a lane >= 0, submit one sample buffer or
 * NULL to finish that lane. Matrix rows contain one coefficient per input
 * channel. A discontinuity resets resampling at a source edit. Its clock
 * tick describes input packet timestamp precision (zero for exact sample
 * timestamps). Provide the rounded program range and source sample count for
 * each span so resampling respects edit boundaries. */
typedef struct LinkedAudioMix MPProgramAudioMix;
MPProgramAudioMix *mp_program_mix_create(int lanes);
void mp_program_mix_close(MPProgramAudioMix *);
void mp_program_mix_submit(MPProgramAudioMix *, int lane, CMSampleBufferRef,
                           const double *matrix, bool discontinuity, CMTime timestamp_tick,
                           int64_t source_samples, CMTime output_start, CMTime output_end);
int mp_program_mix_next(MPProgramAudioMix *, CMSampleBufferRef *sample CF_RETURNS_RETAINED, int *lane);
/* Returns the FFmpeg speaker abbreviation of a channel in decoded PCM. */
const char *mp_program_mix_speaker(CMAudioFormatDescriptionRef, int channel);
