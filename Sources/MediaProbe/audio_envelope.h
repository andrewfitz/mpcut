#ifndef MPCUT_AUDIO_ENVELOPE_H
#define MPCUT_AUDIO_ENVELOPE_H
#include "MediaProbe.h"
#include <libavutil/samplefmt.h>
int mp_envelope_frame(uint8_t *const *planes, enum AVSampleFormat sample_format,
                      int frames, int channels, int rate, double start, MPAudioEnvelope *window);
#endif
