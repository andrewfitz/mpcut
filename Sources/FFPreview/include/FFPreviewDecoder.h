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
/* After mp_preview_prepare_edge and before the seek: H.264 or HEVC parameter sets (NAL units with 4-byte lengths)
 * that the source's decoder holds at the edge's keyframe, which in-band sets earlier in the stream may have changed
 * from the description. The keyframe each seek starts from brings them first. False when they cannot be kept. */
bool mp_preview_prime_edge(MPPreviewDecoder *preview, const uint8_t *units, int size);
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
enum MPPreviewOmission {
    MPPreviewOmitsNothing,
    MPPreviewOmitsDamagedPicture,     /* Resumed at the next keyframe after a damaged picture. */
    MPPreviewOmitsUnalignedSwitch,    /* Resumed at the next keyframe after a description change between keyframes. */
    MPPreviewOmitsLeadingPictures     /* Reopened at an HEVC CRA picture with a new description, which drops its
                                       * RASL pictures: they predict from pictures before it. */
};
/* Why the pictures returned since the last seek omit some of the source's (mp_preview_met_damage is then true),
 * the most specific reason first. A change of description at any other keyframe omits nothing. */
int mp_preview_omission(const MPPreviewDecoder *preview);
/* The sentence for mp_preview_omission, naming the omitted leading pictures, or NULL. Valid until the next call
 * on the decoder. */
const char *mp_preview_notice(const MPPreviewDecoder *preview);
/* Whether the audio decoder rejected a damaged packet since the last seek. Its samples are missing. */
bool mp_preview_met_audio_damage(const MPPreviewDecoder *preview);
/* For a Smart Trim edge that ended with a damage error: every picture returned before the
 * error was decoded from packets that precede the damaged one. */
bool mp_preview_edge_intact_before_damage(const MPPreviewDecoder *preview);
/* For a Smart Trim edge: the picture returned last carries captions, colour or grain
 * metadata that re-encoding it would drop, or belongs to a coded sequence whose keyframe
 * or earlier pictures carried colour volume, light level or viewing environment metadata,
 * or was decoded from or after a sample with SEI mp_preview_sample_keeps_sei names, or carries
 * an S12M time code. Pictures outside the edge are copied. */
bool mp_preview_edge_metadata(const MPPreviewDecoder *preview);
CGAffineTransform mp_preview_transform(const MPPreviewDecoder *preview);
/* Whether a length-prefixed H.264 or HEVC sample (codec is an AVCodecID) carries SEI that a re-encoded Smart Trim edge
 * would drop and libavcodec cannot hand to the encoder: frame packing, display orientation, an HEVC time code,
 * alternative transfer characteristics, or ATSC active format description or bar data. A decoder keeps frame packing
 * and display orientation until they are cancelled, so an edge refuses every picture decoded from the first such
 * sample after its keyframe on (mp_preview_edge_metadata), and the Smart Trim plan (smart_preflight.c) the same. */
bool mp_preview_sample_keeps_sei(int codec, int length_size, const uint8_t *data, int size);

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
