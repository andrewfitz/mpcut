#ifndef MPCUT_MP3_CROP_H
#define MPCUT_MP3_CROP_H

#include "include/PacketWriter.h"
#include <libavformat/avformat.h>

/* lead and tail receive the samples the copy hides before the first and after the last audible sample. */
int mpcut_write_mp3_crop(AVFormatContext *input, int stream_index, AVFormatContext *output,
                         int64_t start_sample, int64_t end_sample, MPCutMP3Anchor anchor, MPCutProgress progress, void *context,
                         unsigned *lead, unsigned *tail, char *error, size_t capacity);

/* The lead of a crop that starts at start_sample, for a stream whose first frame starts at sample zero. */
int64_t mpcut_mp3_crop_lead(int64_t start_sample, int sample_rate);
#endif
