#ifndef MPCUT_VIDEO_CLOCK_H
#define MPCUT_VIDEO_CLOCK_H
#include <libavformat/avformat.h>

int64_t mp_video_presentation_end(const char *format, const AVStream *video, int64_t duration,
                                  int64_t origin, int64_t last_pts, int64_t packet_end);
#endif
