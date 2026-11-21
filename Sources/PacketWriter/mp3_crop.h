#ifndef MPCUT_MP3_CROP_H
#define MPCUT_MP3_CROP_H

#include "include/PacketWriter.h"
#include <libavformat/avformat.h>

int mpcut_write_mp3_crop(AVFormatContext *input, int stream_index, AVFormatContext *output,
                         int64_t start_sample, int64_t end_sample, MPCutProgress progress, void *context,
                         char *error, size_t capacity);
#endif
