#ifndef MPCUT_TIMECODE_H
#define MPCUT_TIMECODE_H

#include "PacketWriter.h"

#include <libavformat/avformat.h>
#include <libavutil/timecode.h>

#define MPCUT_TIMECODE_TAG MKTAG('t', 'm', 'c', 'd')

typedef struct {
    AVRational rate;
    int flags;
    int fps;
    int output_timescale;
    unsigned frames_per_count;
} MPCutTimecode;

int mpcut_timecode_describe(const AVStream *track, const AVStream *video, MPCutTimecode *timecode);
int mpcut_timecode_read(const AVFormatContext *source, unsigned stream_index, const MPCutTimecode *timecode,
                       MPCutTime start, MPCutTime duration, MPCutProgress progress, void *context,
                       double fraction, char value[AV_TIMECODE_STR_SIZE]);

#endif
