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
    int disposition;
    int track_id, deferred_aac_issue, complex_picture, multilayer, multiple_descriptions, reconstructed_dts;
    char audio_clock_issue[128];
    uint8_t *config, *metadata;
    size_t config_size, metadata_size;
    struct AVVorbisParseContext *vorbis_parser;
    struct AVCodecParserContext *flac_parser;
    struct AVCodecContext *flac_context;
    int64_t last_audio_pts;
    MPProbePacket *packets;
    size_t count, capacity;
} MPProbeStream;

typedef struct {
    char format[64], issue[256], timeline_issue[256];
    MPProbeStream *streams;
    int stream_count, video_index, source_start_safe, has_unsupported_auxiliary;
    int64_t origin, end;
} MPProbeResult;

typedef int (*MPProbeCancelled)(void *context);
typedef void (*MPProbeProgress)(void *context, double fraction);
MPProbeResult *mp_probe_read(const char *path, int conversion, int preview_only, int audio_analysis,
                            MPProbeCancelled cancelled, MPProbeProgress progress, void *context,
                            char *error, size_t error_capacity);
enum { MP_SCENE_FEATURE_SIZE = 16 * 9 * 3 };
// Layouts are packed descriptors. Returns count when none match.
size_t mp_scene_match_view(const uint8_t *feature, const uint8_t *layouts, size_t count);
// A null feature reports progress. INT64_MIN with a null feature retracts the
// provisional scenes if the hardware reader must restart on the general decoder.
typedef void (*MPSceneVisit)(void *context, int64_t pts, const uint8_t *feature);
// Populated only when the decode pass can verify a report-only timeline.
typedef struct {
    int valid, tb_num, tb_den;
    int64_t first_pts, origin, end;
} MPSceneTiming;
int mp_scene_scan(const char *path, int stream, int allow_asset_reader,
                  MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, MPSceneTiming *timing, char *error, size_t capacity);
// One peak per 20 ms, in source-picture time. Negative peaks indicate unobserved audio.
enum { MP_PEAK_RATE = 50 };
typedef void (*MPPeakVisit)(void *context, int64_t bin, float peak);
int mp_float_pcm_peaks(const float *samples, int frames, int channels, int rate,
                       double start, double duration, MPPeakVisit visit, void *context);
int mp_audio_peaks(const char *path, int stream, double origin, double duration,
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
#endif
