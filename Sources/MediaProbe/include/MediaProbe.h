#ifndef MPCUT_MEDIA_PROBE_H
#define MPCUT_MEDIA_PROBE_H
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
    uint8_t *config, *metadata;
    size_t config_size, metadata_size;
    MPProbePacket *packets;
    size_t count, capacity;
} MPProbeStream;

typedef struct {
    char format[64], issue[256], timeline_issue[256];
    MPProbeStream *streams;
    int stream_count, video_index, source_start_safe;
    int64_t origin, end;
} MPProbeResult;

typedef int (*MPProbeCancelled)(void *context);
MPProbeResult *mp_probe_read(const char *path, int conversion, int preview_only,
                            MPProbeCancelled cancelled, void *context,
                            char *error, size_t error_capacity);
enum { MP_SCENE_FEATURE_SIZE = 16 * 9 * 3 };
typedef void (*MPSceneVisit)(void *context, int64_t pts, const uint8_t *feature);
int mp_scene_scan(const char *path, int stream, MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, char *error, size_t capacity);
void mp_probe_free(MPProbeResult *result);
#endif
