#ifndef MPCUT_MEDIA_PROBE_H
#define MPCUT_MEDIA_PROBE_H
#include "JPEGFrameReader.h"
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int64_t pts, dts, duration;
    uint32_t skip, discard, decoded_samples, byte_count;
    unsigned char key, start, end;
} MPProbePacket;

typedef struct {
    int64_t sample, offset;
    uint32_t checksum;
} MPProbeMP3Anchor;

enum { MP_PROBE_DIGEST_SIZE = 32 };

typedef struct {
    const char *kind, *codec, *pixel_format;
    char codec_tag[32], channel_layout[128];
    const char *primaries, *transfer, *matrix, *range, *chroma_location;
    int profile, width, height, display_width, display_height, rotation, bit_depth, alpha_bits;
    int field_order, rotation_only;
    uint32_t prores_layout;
    int rate_num, rate_den, tb_num, tb_den, sar_num, sar_den;
    int64_t start, duration;
    int sample_rate, channels, pcm, initial_padding, trailing_padding, seek_preroll;
    char *language;
    char name[256];
    int disposition;
    int track_id, deferred_aac_issue, complex_picture, multilayer, multiple_descriptions, reconstructed_dts;
    char audio_clock_issue[128];
    uint8_t *config, *metadata;
    size_t config_size, metadata_size;
    struct AVVorbisParseContext *vorbis_parser;
    struct AVCodecParserContext *flac_parser;
    struct AVCodecContext *flac_context;
    int64_t last_audio_pts;
    // Sum of the packet sizes of a compressed audio track. Zero for PCM and video.
    int64_t coded_bytes;
    MPProbeMP3Anchor *mp3_anchors;
    size_t mp3_anchor_count;
    int mp3_unindexed;
    MPProbePacket *packets;
    size_t count, capacity;
    uint8_t payload_digest[MP_PROBE_DIGEST_SIZE], timing_digest[MP_PROBE_DIGEST_SIZE];
    uint8_t layout_digest[MP_PROBE_DIGEST_SIZE];
    int has_payload_evidence;
} MPProbeStream;

typedef struct {
    char format[64], issue[256], timeline_issue[256];
    MPProbeStream *streams;
    int stream_count, video_index, source_start_safe, has_unsupported_auxiliary;
    int64_t origin, end;
    int64_t source_stamp_units;
    int source_stamp_kind, source_stamp_stream, source_stamp_num, source_stamp_den;
} MPProbeResult;

// Writes the layout two descriptions are compared by: a layout that names no speakers ("2 channels") becomes the
// standard layout of its channel count ("stereo", "5.1"); a layout that names them is written as it is.
// Returns 0 and writes nothing when the description cannot be read.
int mp_canonical_channel_layout(const char *layout, int channels, char *canonical, size_t capacity);
// The layout that Vorbis channel order defines for one to eight channels, which Opus channel mapping family 1
// shares. Null for other counts.
const char *mp_vorbis_order_layout(int channels);

enum { MP_SOURCE_SYNC_TIMECODE = 1, MP_SOURCE_SYNC_BWF = 2 };
// Positive values identify present metadata, including a genuine timestamp of zero.
int mp_source_sync_stamp(const char *path, int stream, int rate_num, int rate_den,
                         int64_t *units, int *scale_num, int *scale_den);
int mp_source_timecode(const char *path, int stream, int rate_num, int rate_den,
                       int64_t *units, int *scale_num, int *scale_den);

typedef int (*MPProbeCancelled)(void *context);
typedef void (*MPProbeProgress)(void *context, double fraction);
MPProbeResult *mp_probe_read(const char *path, int conversion, int preview_only, int audio_analysis, int force_payload,
                            MPProbeCancelled cancelled, MPProbeProgress progress, void *context,
                            char *error, size_t error_capacity);
typedef struct {
    int64_t start, end;
    int scale;
} MPProbeHDRRange;
typedef struct {
    uint32_t mastering[10]; /* G, B, R, white, max/min luminance in MOV mdcv units */
    int has_mastering, conflicting_mastering, content_light, inband_content_light;
    int dolby_vision, hdr10plus, additional_layers;
} MPProbeHDR;
int mp_probe_hdr(const char *path, int stream, const MPProbeHDRRange *ranges, size_t count,
                 MPProbeCancelled cancelled, void *context, MPProbeHDR *result,
                 char *error, size_t capacity);
/* Check a copied MOV HEVC sample for unsupported dynamic HDR signaling and layers. */
int mp_probe_check_still_hevc(const uint8_t *data, int size, const uint8_t *config, int config_size);
enum {
    MP_PROBE_SIDE_MASTERING_DISPLAY = 1,
    MP_PROBE_SIDE_CONTENT_LIGHT = 2
};
int mp_probe_hdr_side_type(uint32_t type);

enum { MP_SCENE_FEATURE_SIZE = 16 * 9 * 3 };
// Layouts are packed descriptors. Returns count when none match.
size_t mp_scene_match_view(const uint8_t *feature, const uint8_t *layouts, size_t count);
// A null feature reports progress. INT64_MIN with a null feature retracts the
// provisional scenes if the hardware reader must restart on the general decoder.
typedef void (*MPSceneVisit)(void *context, int64_t pts, const uint8_t *feature);
// Populated only when the decode pass can verify a report-only timeline.
// If supplied, metadata runs for every decoded picture. A positive return
// requests RGB for this picture, zero skips it, and a negative return stops
// the scan. Damaged or untimestamped pictures never request conversion.
typedef int (*MPParticipantFrameSelect)(void *context, int64_t pts, int64_t duration, int damaged);
// RGB24, coded orientation. The pointer is valid only for the duration of
// the callback. Without a selector, a null pointer reports damaged pictures.
// unplaced_damage is set when the decoder recovers from an error without
// yielding the affected picture's timestamp.
typedef int (*MPParticipantFrameVisit)(void *context, int64_t pts, int64_t duration,
                                      const uint8_t *rgb, int32_t width, int32_t height,
                                      int32_t stride, int32_t sar_num, int32_t sar_den);
int mp_participant_scan(const char *path, int stream, MPProbeCancelled cancelled,
                        MPParticipantFrameSelect select_frame, MPParticipantFrameVisit frame,
                        MPSceneVisit scene, void *context,
                        int *unplaced_damage, char *error, size_t capacity);
// A picture of the adaptive scan, with the analysis the prepare callback
// returned for it or NULL. The visit owns that analysis. As the frame visit, a
// nonzero return stops the scan and null pixels report a damaged picture. As
// the coarse visit, the picture follows pictures the scan has not decoded,
// normally the next keyframe: a positive return accepts it in their place,
// zero asks for the pictures before it, and a negative return stops the scan.
// A refused picture arrives again through the frame visit after the pictures
// it follows.
typedef int (*MPParticipantSampleVisit)(void *context, int64_t pts, int64_t duration,
                                       const uint8_t *rgb, int32_t width, int32_t height,
                                       int32_t stride, int32_t sar_num, int32_t sar_den, void *prepared);
// Analyze a picture's pixels ahead of its visit. Runs on several threads at
// once, never during a visit. Discard releases an analysis no visit received.
typedef void *(*MPParticipantPrepare)(void *context, int64_t pts, const uint8_t *rgb, int32_t width,
                                      int32_t height, int32_t stride, int32_t sar_num, int32_t sar_den);
typedef void (*MPParticipantDiscard)(void *context, void *prepared);
// Decode random access pictures first and the pictures between two of them
// only on request. A stretch is offered for skipping when its packets cover
// the time between both pictures without a gap and it lasts at most three
// seconds. Every other picture reaches the frame visit in presentation order,
// as in mp_participant_scan without a selector. With a null coarse visit every
// picture does. Small H.264 pictures decode on frame threads in software,
// packed as the NV12 the hardware decoder returns.
// A positive sample limit delivers each picture as the grid of point samples
// the analyzer reads: the longer side becomes the limit, the other scales to
// match, and sample i of n is source pixel (2i + 1) * size / 2n. Pictures then
// convert side by side. Zero delivers whole pictures.
// A scene visit receives the scene detector's markers, as in mp_scene_scan,
// and makes the scan decode every picture.
int mp_participant_scan_adaptive(const char *path, int stream, int sample_limit, MPProbeCancelled cancelled,
                                 MPParticipantSampleVisit coarse, MPParticipantSampleVisit frame,
                                 MPParticipantPrepare prepare, MPParticipantDiscard discard, MPSceneVisit scene,
                                 void *context, int *unplaced_damage, char *error, size_t capacity);

typedef struct {
    int64_t last_pts;
    int64_t preroll_ticks;
    // The width of a last stored sample that the edit ends before, so that it
    // is never presented. last_pts is then the sample before it.
    int64_t trailing_ticks;
} MPParticipantEditTail;

// Resume after this exact source-stream presentation timestamp (INT64_MIN for
// a fresh scan). Pictures required for decoder preroll are never submitted.
int mp_participant_scan_from(const char *path, int stream, int sample_limit, int64_t resume_anchor,
                             MPProbeCancelled cancelled,
                             MPParticipantSampleVisit coarse, MPParticipantSampleVisit frame,
                             MPParticipantPrepare prepare, MPParticipantDiscard discard, MPSceneVisit scene,
                             void *context, int *unplaced_damage, MPParticipantEditTail *edit_tail, char *error, size_t capacity);

typedef struct {
    int valid, tb_num, tb_den;
    int64_t first_pts, origin, end;
} MPSceneTiming;
int mp_scene_uses_segment_cadence(const char *path, int stream, int64_t origin,
                                  int rate_num, int rate_den, MPProbeCancelled cancelled, void *context);
int mp_scene_verify_clock(const char *path, int stream, MPProbeCancelled cancelled,
                          void *context, MPSceneTiming *timing);
int mp_scene_scan(const char *path, int stream, int allow_asset_reader,
                  MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, MPSceneTiming *timing, char *error, size_t capacity);

enum { MP_SCENE_RESUME_MISMATCH = 1, MP_SCENE_SCAN_CANCELLED = 2 };
enum { MP_PARTICIPANT_UNSUPPORTED_DISPLAY_TRANSFORM = 3, MP_PARTICIPANT_RESUME_ANCHOR_MISSING = 8 };
// Leading scene's descriptor, emitted separately from actual scene boundaries.
#define MP_SCENE_RANGE_LEADING_PTS (INT64_MIN + 1)
typedef struct {
    int has_range;
    int64_t start_pts, end_pts;
    const uint8_t *resume;
    size_t resume_size;
} MPSceneScanOptions;
// The state is only valid during the callback. The confirmed timestamp is the
// settled cut frontier, or INT64_MIN until a picture's successor is available.
typedef void (*MPSceneCheckpointVisit)(void *context, int64_t decoded_pts,
                                       int64_t confirmed_pts, int64_t ordinal,
                                       const uint8_t *state, size_t size);
// A resume mismatch emits no markers or checkpoints. The caller may discard
// the saved attempt and retry with an empty resume state.
int mp_scene_scan_resumable(const char *path, int stream, const MPSceneScanOptions *options,
                            MPProbeCancelled cancelled, MPSceneVisit visit,
                            MPSceneCheckpointVisit checkpoint, void *context,
                            char *error, size_t capacity);
// One peak per 20 ms, in source-picture time. Negative peaks indicate unobserved audio.
enum { MP_PEAK_RATE = 50 };
typedef void (*MPPeakVisit)(void *context, int64_t bin, float peak);
int mp_float_pcm_peaks(const float *samples, int frames, int channels, int rate,
                       double start, double duration, MPPeakVisit visit, void *context);
int mp_audio_peaks(const char *path, int stream, double origin, double duration, int ordered_clock,
                   MPProbeCancelled cancelled, MPPeakVisit visit, void *context,
                   char *error, size_t capacity);
// Native signed sample extrema for a bounded window. low/high arrays have columns elements.
typedef struct {
    double from, to, through;
    int columns;
    float *low, *high;
} MPAudioEnvelope;
int mp_audio_envelope(const char *path, int stream, double origin, MPAudioEnvelope *window,
                      MPProbeCancelled cancelled, void *context, char *error, size_t capacity);
int mp_float_pcm_envelope(const float *samples, int frames, int channels, int rate,
                          double start, MPAudioEnvelope *window);
void mp_envelope_silence(MPAudioEnvelope *window, double from, double to);
void mp_probe_free(MPProbeResult *result);
/* Continuous mono PCM on the indexed source clock. */
typedef struct MPTranscriptPCM MPTranscriptPCM;
MPTranscriptPCM *mp_transcript_pcm_open(const char *path, int64_t samples, int rate, int channel);
int mp_transcript_pcm_float(MPTranscriptPCM *pcm, const float *samples, int frames, int channels,
                            int rate, double start);
int mp_transcript_decode(MPTranscriptPCM *pcm, const char *path, int stream, double origin, double duration,
                         MPProbeCancelled cancelled, void *context, char *error, size_t capacity);
void mp_transcript_pcm_set_cancel(MPTranscriptPCM *pcm, MPProbeCancelled cancelled, void *context);
int mp_transcript_pcm_finish(MPTranscriptPCM *pcm, MPProbeCancelled cancelled, void *context);
/* Linear RMS of each 20 ms window of the written PCM. Complete after mp_transcript_pcm_finish. */
const float *mp_transcript_pcm_levels(const MPTranscriptPCM *pcm, int64_t *count);
/* The strongest source channel when the default downmix cancelled itself, otherwise -1. */
int mp_transcript_pcm_cancelled_downmix(const MPTranscriptPCM *pcm);
void mp_transcript_pcm_close(MPTranscriptPCM *pcm);

#endif
