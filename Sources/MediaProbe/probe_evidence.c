#include <libavutil/avstring.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <CommonCrypto/CommonDigest.h>
#include "mov_index.h"
#include "probe_evidence.h"

typedef struct {
    CC_SHA256_CTX payload, timing, layout;
    bool seen, invalid;
} StreamEvidence;

struct MPProbeEvidence {
    unsigned count;
    StreamEvidence streams[];
};

void mp_probe_hash_value(CC_SHA256_CTX *hash, uint64_t value)
{
    uint8_t bytes[8];
    AV_WB64(bytes, value);
    CC_SHA256_Update(hash, bytes, sizeof(bytes));
}

static uint64_t gcd(uint64_t a, uint64_t b)
{
    while (b) {
        uint64_t remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}

void mp_probe_hash_time(CC_SHA256_CTX *hash, int64_t ticks, AVRational base)
{
    uint64_t denominator = base.den;
    bool negative = ticks < 0;
    uint64_t magnitude = negative ? 0 - (uint64_t)ticks : (uint64_t)ticks;
    uint64_t tick_factor = gcd(magnitude, denominator);
    magnitude /= tick_factor;
    denominator /= tick_factor;
    uint64_t base_factor = gcd(base.num, denominator);
    // One update per timestamp, including the high bits of a large numerator.
    __uint128_t numerator = (__uint128_t)magnitude * (base.num / base_factor);
    uint8_t bytes[32];
    AV_WB64(bytes, negative);
    AV_WB64(bytes + 8, (uint64_t)(numerator >> 64));
    AV_WB64(bytes + 16, (uint64_t)numerator);
    AV_WB64(bytes + 24, denominator / base_factor);
    CC_SHA256_Update(hash, bytes, sizeof(bytes));
}

MPProbeEvidence *mp_probe_evidence_open(const char *path, const AVFormatContext *file)
{
    MPProbeEvidence *evidence = av_mallocz(sizeof(*evidence) + sizeof(StreamEvidence) * file->nb_streams);
    CC_SHA256_CTX **mov_timing = NULL;
    if (!evidence)
        goto fail;
    evidence->count = file->nb_streams;
    bool mov = av_match_name("mov", file->iformat->name);
    if (mov && !(mov_timing = av_calloc(evidence->count, sizeof(*mov_timing))))
        goto fail;
    for (unsigned i = 0; i < evidence->count; i++) {
        const AVStream *stream = file->streams[i];
        const AVCodecParameters *params = stream->codecpar;
        StreamEvidence *entry = &evidence->streams[i];
        CC_SHA256_Init(&entry->payload);
        CC_SHA256_Init(&entry->timing);
        CC_SHA256_Init(&entry->layout);
        mp_probe_hash_value(&entry->payload, params->codec_id);
        mp_probe_hash_value(&entry->payload, params->extradata_size);
        if (params->extradata_size > 0)
            CC_SHA256_Update(&entry->payload, params->extradata, params->extradata_size);
        entry->invalid = stream->time_base.num <= 0 || stream->time_base.den <= 0;
        if (mov && !entry->invalid)
            mov_timing[i] = &entry->timing;
        else
            mp_probe_hash_value(&entry->timing, 0);
    }
    if (mov) {
        mp_mov_hash_edits(path, file, mov_timing);
        for (unsigned i = 0; i < evidence->count; i++)
            if (!mov_timing[i])
                evidence->streams[i].invalid = true;
    }
    av_free(mov_timing);
    return evidence;
fail:
    av_free(mov_timing);
    mp_probe_evidence_free(evidence);
    return NULL;
}

static void hash_side_data(CC_SHA256_CTX *hash, const AVPacketSideData *side)
{
    const uint8_t *bytes = side->data;
    size_t remaining = side->size;
    while (remaining > 0) {
        CC_LONG length = remaining > UINT32_MAX ? UINT32_MAX : (CC_LONG)remaining;
        CC_SHA256_Update(hash, bytes, length);
        bytes += length;
        remaining -= length;
    }
}

void mp_probe_evidence_packet(MPProbeEvidence *evidence, const AVStream *stream, const AVPacket *packet)
{
    StreamEvidence *entry = &evidence->streams[stream->index];
    if (entry->invalid)
        return;
    if (stream->time_base.num <= 0 || stream->time_base.den <= 0 ||
        packet->pts == AV_NOPTS_VALUE || packet->size < 0 || (packet->flags & AV_PKT_FLAG_CORRUPT)) {
        entry->invalid = true;
        return;
    }
    entry->seen = true;
    mp_probe_hash_value(&entry->payload, packet->size);
    if (packet->size > 0)
        CC_SHA256_Update(&entry->payload, packet->data, packet->size);
    mp_probe_hash_time(&entry->timing, packet->pts, stream->time_base);
    mp_probe_hash_time(&entry->timing, packet->duration, stream->time_base);
    mp_probe_hash_value(&entry->timing, packet->flags & AV_PKT_FLAG_DISCARD);
    mp_probe_hash_value(&entry->layout, packet->pos);
    mp_probe_hash_value(&entry->layout, packet->flags & AV_PKT_FLAG_KEY);
    mp_probe_hash_value(&entry->layout, packet->dts == AV_NOPTS_VALUE);
    if (packet->dts != AV_NOPTS_VALUE)
        mp_probe_hash_time(&entry->layout, packet->dts, stream->time_base);
    for (int i = 0; i < packet->side_data_elems; i++) {
        const AVPacketSideData *side = &packet->side_data[i];
        switch (side->type) {
        case AV_PKT_DATA_SKIP_SAMPLES:
            mp_probe_hash_value(&entry->timing, side->type + 1);
            mp_probe_hash_value(&entry->timing, side->size);
            hash_side_data(&entry->timing, side);
            break;
        case AV_PKT_DATA_NEW_EXTRADATA:
        case AV_PKT_DATA_PARAM_CHANGE:
            mp_probe_hash_value(&entry->payload, side->type + 1);
            mp_probe_hash_value(&entry->payload, side->size);
            hash_side_data(&entry->payload, side);
            break;
        default:
            break;
        }
    }
    mp_probe_hash_value(&entry->timing, 0);
    mp_probe_hash_value(&entry->payload, 0);
}

void mp_probe_evidence_finish(MPProbeEvidence *evidence, MPProbeResult *result)
{
    for (unsigned i = 0; i < evidence->count; i++) {
        StreamEvidence *entry = &evidence->streams[i];
        if (entry->seen && !entry->invalid) {
            MPProbeStream *stream = &result->streams[i];
            CC_SHA256_Final(stream->payload_digest, &entry->payload);
            CC_SHA256_Final(stream->timing_digest, &entry->timing);
            CC_SHA256_Final(stream->layout_digest, &entry->layout);
            stream->has_payload_evidence = 1;
        }
    }
}

void mp_probe_evidence_free(MPProbeEvidence *evidence)
{
    av_free(evidence);
}
