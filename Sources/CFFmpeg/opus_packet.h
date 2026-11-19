#ifndef MPCUT_OPUS_PACKET_H
#define MPCUT_OPUS_PACKET_H

#include <stddef.h>
#include <stdint.h>

/* Read the duration in 48 kHz samples from the Opus TOC (RFC 6716, section 3.1).
 * In multistream Opus the subpackets have the same duration. */
static inline int mpcut_opus_samples(const uint8_t *data, size_t size) {
    if (!size) {
        return 0;
    }
    unsigned config = data[0] >> 3;
    unsigned code = data[0] & 3;
    unsigned frames = code == 0 ? 1 : 2;
    if (code == 3) {
        if (size < 2) {
            return 0;
        }
        frames = data[1] & 63;
    }
    unsigned samples_per_frame;
    if (config >= 16) {
        samples_per_frame = 120 << (config & 3);
    } else if (config >= 12) {
        samples_per_frame = 480 << (config & 1);
    } else {
        unsigned silk_durations[] = {480, 960, 1920, 2880};
        samples_per_frame = silk_durations[config & 3];
    }
    unsigned samples = frames * samples_per_frame;
    return samples <= 5760 ? samples : 0;
}

#endif
