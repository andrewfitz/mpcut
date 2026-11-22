#ifndef MP_SCENE_DISTANCE_H
#define MP_SCENE_DISTANCE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

static inline unsigned mp_scene_byte_distance(const uint8_t *a, const uint8_t *b, size_t count)
{
    unsigned sum = 0;
    size_t i = 0;
#if defined(__aarch64__)
    // Each lane adds two byte differences per 32 samples. Limit the
    // vector loop to 128 iterations so a 16-bit lane cannot overflow.
    const size_t vector_count = count < 4096 ? count : 4096;
    uint16x8_t first = vdupq_n_u16(0), second = vdupq_n_u16(0);
    for (; vector_count - i >= 32; i += 32) {
        uint8x16_t d0 = vabdq_u8(vld1q_u8(a + i), vld1q_u8(b + i));
        uint8x16_t d1 = vabdq_u8(vld1q_u8(a + i + 16), vld1q_u8(b + i + 16));
        first = vpadalq_u8(first, d0);
        second = vpadalq_u8(second, d1);
    }
    sum = vaddlvq_u16(first) + vaddlvq_u16(second);
    if (vector_count - i >= 16) {
        sum += vaddlvq_u8(vabdq_u8(vld1q_u8(a + i), vld1q_u8(b + i)));
        i += 16;
    }
#endif
    for (; i < count; i++) sum += abs(a[i] - b[i]);
    return sum;
}

#endif
