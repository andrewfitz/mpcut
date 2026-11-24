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

#endif
