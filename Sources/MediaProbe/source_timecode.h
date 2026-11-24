#ifndef MPCUT_SOURCE_TIMECODE_H
#define MPCUT_SOURCE_TIMECODE_H

#include <libavformat/avformat.h>

int mp_source_sync_stamp_in_input(AVFormatContext *input, int stream, int rate_num, int rate_den,
                                  int64_t *units, int *scale_num, int *scale_den);

#endif
