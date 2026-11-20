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
    const char *primaries, *transfer, *matrix, *range;
    int profile, width, height, display_width, display_height, rotation, bit_depth, alpha_bits;
    int rate_num, rate_den, tb_num, tb_den, sar_num, sar_den;
    int64_t start, duration;
    int sample_rate, channels, pcm, initial_padding, trailing_padding, seek_preroll;
    char *language;
    int disposition;
    int track_id, deferred_aac_issue, complex_picture, multiple_descriptions;
    uint8_t *config, *metadata;
    size_t config_size, metadata_size;
    MPProbePacket *packets;
    size_t count, capacity;
} MPProbeStream;

typedef struct {
    char format[64], issue[256];
    MPProbeStream *streams;
    int stream_count, video_index, source_start_safe;
    int64_t origin, end;
} MPProbeResult;

typedef int (*MPProbeCancelled)(void *context);
MPProbeResult *mp_probe_read(const char *path, MPProbeCancelled cancelled, void *context,
                            char *error, size_t error_capacity);
void mp_probe_free(MPProbeResult *result);
#endif
