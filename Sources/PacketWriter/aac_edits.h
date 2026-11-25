#ifndef MPCUT_AAC_EDITS_H
#define MPCUT_AAC_EDITS_H

#include "PacketWriter.h"

#include <libavcodec/packet.h>
#include <libavutil/rational.h>

typedef struct MPCutAAC MPCutAAC;

enum { MPCUT_AAC_PREROLL_SAMPLES = 2048 };

MPCutAAC *mpcut_aac_create(unsigned track_count, int movie_timescale);
void mpcut_aac_free(MPCutAAC *aac);
int mpcut_aac_begin(MPCutAAC *aac, unsigned index, int sample_rate, MPCutTime src_start,
                    MPCutTime out_start, MPCutTime out_end, char *error, size_t error_capacity);
int mpcut_aac_packet(MPCutAAC *aac, AVPacket *packet, AVRational input_tb,
                     AVRational output_tb, int keep_tail_duration, char *error, size_t error_capacity);
int mpcut_aac_end(MPCutAAC *aac, unsigned index, char *error, size_t error_capacity);
int mpcut_aac_empty(MPCutAAC *aac, unsigned index, int sample_rate, MPCutTime out_start,
                   MPCutTime out_end, char *error, size_t error_capacity);
int mpcut_aac_finalize(MPCutAAC *aac, const char *path, char *error, size_t error_capacity);

/* Give a written movie's chapter track a millisecond clock. The writer hands the MOV
 * muxer chapter times counted in milliseconds, because the muxer's chapter samples
 * cannot span more than about three seconds on this writer's movie clock. */
int mpcut_mov_finish_chapters(const char *path, int movie_timescale, char *error, size_t error_capacity);

/* Relabel the 'hev1' sample entries of the given tracks as 'hvc1' and mark their
 * parameter-set arrays complete. The caller has checked that every parameter set
 * in those tracks' samples repeats one in the sample entry. */
/* MOV times a track's samples by decode intervals. When a copy ends inside a
 * picture group after a held picture, its last decoded sample can end before the
 * presentation does, and FFmpeg reads the track as the shorter of its sample table
 * and its edit. Extend the last decoded sample of each video track whose single
 * media edit ends at the planned `duration` so that the sample table covers it. */
int mpcut_mov_cover_edits(const char *path, MPCutTime duration, char *error, size_t error_capacity);

int mpcut_mov_label_hvc1(const char *path, const uint32_t *track_ids, size_t count, char *error,
                         size_t error_capacity);

#endif
