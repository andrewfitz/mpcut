#include "MediaProbe.h"
#include <stdlib.h>

size_t mp_scene_match_view(const uint8_t *feature, const uint8_t *layouts, size_t count)
{
    // The first layout within four percent wins ties. Accumulate fixed-size
    // blocks so clang can vectorize the sum and still reject distant views early.
    enum { block = MP_SCENE_FEATURE_SIZE / 3 };
    unsigned minimum = 255 * MP_SCENE_FEATURE_SIZE / 25;
    size_t best = count;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *layout = layouts + i * MP_SCENE_FEATURE_SIZE;
        unsigned difference = 0;
        for (size_t j = 0; j < MP_SCENE_FEATURE_SIZE; j += block) {
            for (size_t k = j; k < j + block; k++)
                difference += abs(feature[k] - layout[k]);
            if (difference >= minimum) break;
        }
        if (difference < minimum) {
            minimum = difference;
            best = i;
            if (!difference) break;
        }
    }
    return best;
}
