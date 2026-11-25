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

/* The samples of a timecode track that start inside (from, to), on the track's own clock, and do not continue the
 * count of the sample before them. A copy counts on from the range start, so each is a break it does not keep. */
int mpcut_timecode_breaks(const char *url, unsigned stream_index, const MPCutTimecode *timecode,
                          MPCutTime from, MPCutTime to);

#endif
