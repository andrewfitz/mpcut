#ifndef MPCUT_PROBE_EVIDENCE_H
#define MPCUT_PROBE_EVIDENCE_H

#include "MediaProbe.h"
#include <libavformat/avformat.h>
#include <CommonCrypto/CommonDigest.h>

typedef struct MPProbeEvidence MPProbeEvidence;

MPProbeEvidence *mp_probe_evidence_open(const char *path, const AVFormatContext *file);
void mp_probe_evidence_packet(MPProbeEvidence *evidence, const AVStream *stream, const AVPacket *packet);
void mp_probe_evidence_finish(MPProbeEvidence *evidence, MPProbeResult *result);
void mp_probe_evidence_free(MPProbeEvidence *evidence);
void mp_probe_hash_value(CC_SHA256_CTX *hash, uint64_t value);
void mp_probe_hash_time(CC_SHA256_CTX *hash, int64_t ticks, AVRational base);

#endif
