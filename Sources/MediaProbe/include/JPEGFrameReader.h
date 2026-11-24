#pragma once
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct MPJPEGReader MPJPEGReader;
MPJPEGReader *mp_jpeg_open(const char *path, int stream, int (*cancelled)(void *), void *context,
                           char *error, size_t capacity);
CGAffineTransform mp_jpeg_transform(MPJPEGReader *reader);
/// When set, a software-decoded picture with more than 8 bits per sample arrives as
/// kCVPixelFormatType_64RGBALE instead of 8-bit BGRA. Hardware pictures keep their own format.
void mp_jpeg_set_deep(MPJPEGReader *reader, bool deep);
CGSize mp_jpeg_display_size(MPJPEGReader *reader);
int mp_jpeg_frame(MPJPEGReader *reader, int64_t pts, int64_t seek_dts, int max_edge,
                  CVPixelBufferRef *image CF_RETURNS_RETAINED, char *error, size_t capacity);
void mp_jpeg_close(MPJPEGReader *reader);
