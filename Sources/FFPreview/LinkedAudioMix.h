#pragma once
#include "FFPreviewDecoder.h"
#include <libavutil/rational.h>

typedef struct LinkedAudioMix LinkedAudioMix;
LinkedAudioMix *linked_mix_create(int count);
void linked_mix_set_lane(LinkedAudioMix *, int index, MPPreviewDecoder *, AVRational timestamp_base);
void linked_mix_preserve_surround(LinkedAudioMix *);
void linked_mix_close(LinkedAudioMix *);
bool linked_mix_has_audio(const LinkedAudioMix *);
bool linked_mix_unavailable(const LinkedAudioMix *);
bool linked_mix_met_audio_damage(const LinkedAudioMix *);
bool linked_mix_seek(LinkedAudioMix *, double seconds);
int linked_mix_next(LinkedAudioMix *, CMSampleBufferRef *);
