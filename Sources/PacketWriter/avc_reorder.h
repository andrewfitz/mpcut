#ifndef MPCUT_AVC_REORDER_H
#define MPCUT_AVC_REORDER_H

#include <stddef.h>
#include <stdint.h>

#include <libavcodec/packet.h>

/* An H.264 sequence parameter set may leave its picture reorder depth undeclared
 * (no VUI bitstream_restriction). MOV readers learn the depth from the composition
 * offsets of the whole track; Matroska has none, so libavcodec guesses it from the
 * first pictures and drops a picture when a later picture group reorders deeper.
 * These helpers declare a depth in such parameter sets. Every other bit, and every
 * slice, stays as it was. Parameter sets that already declare one are left alone. */

/* 1 when some sequence parameter set in the avcC record leaves its reorder depth
 * undeclared and can declare one, else 0. */
int mpcut_avcc_needs_reorder(const uint8_t *config, int size);

/* 1 when some sequence parameter set in the avcC record neither declares a reorder depth
 * nor can be rewritten to declare one (field coding, or syntax these helpers do not read),
 * else 0. A Matroska copy of such a stream keeps libavcodec's guess. */
int mpcut_avcc_reorder_unknown(const uint8_t *config, int size);

/* Rewrite each such sequence parameter set in an avcC record to declare `reorder`.
 * Returns 1 with a new av_malloc'd record in *out (padded for libavcodec), 0 when
 * nothing changed, or a negative AVERROR. */
int mpcut_avcc_declare_reorder(const uint8_t *config, int size, int reorder, uint8_t **out, int *out_size);

/* The same for sequence parameter sets carried in a length-prefixed sample. The
 * packet's payload is replaced only when one changed. Returns 1, 0 or a negative AVERROR. */
int mpcut_avc_packet_declare_reorder(AVPacket *packet, int length_size, int reorder);

/* Rewrite one sequence parameter set NAL unit (header byte included). Returns 1 with
 * an av_malloc'd unit in *out, 0 when it is left alone, or a negative AVERROR. */
int mpcut_avc_sps_declare_reorder(const uint8_t *nal, size_t size, int reorder, uint8_t **out, size_t *out_size);

/* Fold one presentation timestamp, in decode order, into a running reorder depth:
 * the most pictures that precede a picture in decode order and follow it in
 * presentation order, counted within the 16 that may be held for reordering. */
typedef struct {
    int64_t window[17];
    unsigned filled;
    int depth;
} MPCutReorderScan;

void mpcut_reorder_scan_add(MPCutReorderScan *scan, int64_t pts);

#endif
