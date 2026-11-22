#include "MediaProbe.h"
#include "scene_distance.h"

size_t mp_scene_match_view(const uint8_t *feature, const uint8_t *layouts, size_t count)
{
    // The first layout within four percent wins ties. Accumulate fixed-size
    // blocks to vectorize the sum and still reject distant views early.
    enum { block = MP_SCENE_FEATURE_SIZE / 3 };
    unsigned minimum = 255 * MP_SCENE_FEATURE_SIZE / 25;
    size_t best = count;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *layout = layouts + i * MP_SCENE_FEATURE_SIZE;
        unsigned difference = 0;
        for (size_t j = 0; j < MP_SCENE_FEATURE_SIZE; j += block) {
            difference += mp_scene_byte_distance(feature + j, layout + j, block);
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
