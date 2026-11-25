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

/// Stored JPEG pictures of an MJPEG or Photo JPEG stream, for a copy without re-encoding.
typedef struct MPJPEGPackets MPJPEGPackets;
/// Returns NULL when the stream cannot be copied (another codec or a display transform) or cannot be opened.
/// Set check_layout when the stream's pixel format is not known: each picture is then copied only when its
/// frame header codes 8-bit gray or YCbCr 4:2:0 or 4:2:2, which a JPEG decoder reads as full range.
MPJPEGPackets *mp_jpeg_packets_open(const char *path, int stream, bool check_layout,
                                    int (*cancelled)(void *), void *context);
/// On 1, *data holds a standalone baseline JPEG of the picture at pts, width x height,
/// for the caller to free(): the stored bytes, or with the standard Huffman tables an AVI
/// picture omits. Returns 0 when that picture needs decoding instead, negative on error.
int mp_jpeg_packet(MPJPEGPackets *packets, int64_t pts, int width, int height, uint8_t **data, size_t *size);
void mp_jpeg_packets_close(MPJPEGPackets *packets);
