#ifndef MPCUT_TRANSCRIPT_PCM_H
#define MPCUT_TRANSCRIPT_PCM_H

#include "MediaProbe.h"
#include <libavutil/frame.h>

int mp_transcript_frame(MPTranscriptPCM *pcm, const AVFrame *frame, double start);

#endif
