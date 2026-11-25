#include "hevc_sets.h"

#include <errno.h>
#include <limits.h>
#include <string.h>

#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>

/* HEVC slots: 16 video, 16 sequence, then 64 picture parameter sets, for every layer. A decoder of a stream with more
 * than one layer (MV-HEVC views, an alpha layer) keys a set by its type and ID alone, whatever layer carries it.
 * H.264 slots: 32 sequence, 256 picture parameter sets, then 32 sequence parameter set extensions (an auxiliary
 * picture's format) and 32 subset sequence parameter sets (MVC and SVC), which keep IDs of their own. */
enum {
    VPS = 32, SPS = 33, PPS = 34, AVC_SPS = 7, AVC_PPS = 8, AVC_SPS_EXT = 13, AVC_SUBSET_SPS = 15,
    AVC_EXT_SLOT = 32 + 256, AVC_SUBSET_SLOT = AVC_EXT_SLOT + 32, SLOTS = AVC_SUBSET_SLOT + 32
};

typedef struct {
    uint8_t *data;
    size_t size;
} Unit;

struct MPCutHevcSets {
    int avc;            /* H.264 sets, from an avcC record. */
    Unit active[SLOTS];
    Unit initial[SLOTS];
    uint8_t header[22];
    uint8_t *other;     /* Arrays of other NAL unit types (SEI), copied from the initial record. */
    size_t other_size;
    unsigned other_arrays;
};

typedef struct {
    const uint8_t *data;
    size_t bits, position;
    int error;
} Reader;

static unsigned bit(Reader *reader) {
    if (reader->position >= reader->bits) {
        reader->error = 1;
        return 0;
    }
    unsigned value = reader->data[reader->position >> 3] >> (7 - (reader->position & 7)) & 1;
    reader->position++;
    return value;
}

static void skip(Reader *reader, size_t count) {
    reader->position += count;
    if (reader->position > reader->bits)
        reader->error = 1;
}

static uint32_t ue(Reader *reader) {
    int zeros = 0;
    while (!bit(reader)) {
        if (reader->error || ++zeros > 31) {
            reader->error = 1;
            return 0;
        }
    }
    uint32_t value = 0;
    for (int i = 0; i < zeros; i++)
        value = value << 1 | bit(reader);
    return (uint32_t)((1ULL << zeros) - 1 + value);
}

/* Whether a NAL unit is a parameter set the slots hold. */
static int parameter_set(int avc, const uint8_t *nal) {
    unsigned type = avc ? nal[0] & 0x1f : (nal[0] >> 1) & 0x3f;
    return avc ? type == AVC_SPS || type == AVC_PPS || type == AVC_SPS_EXT || type == AVC_SUBSET_SPS
               : type >= VPS && type <= PPS;
}

/* The slot of a parameter set: its type and ID, read as a decoder reads them. */
static int slot(int avc, const uint8_t *nal, size_t size) {
    if (size < (avc ? 2u : 3u)) /* An H.264 set extension with ID 0 and no auxiliary picture is two bytes. */
        return AVERROR_INVALIDDATA;
    unsigned type = avc ? nal[0] & 0x1f : (nal[0] >> 1) & 0x3f;
    if (avc && type != AVC_SPS && type != AVC_PPS && type != AVC_SPS_EXT && type != AVC_SUBSET_SPS)
        return AVERROR(ENOTSUP);
    unsigned layer = avc ? 0 : (nal[0] & 1) << 5 | nal[1] >> 3;
    if (!avc && type == VPS)
        return layer ? AVERROR_INVALIDDATA : nal[2] >> 4; /* Every layer shares the video parameter sets of layer 0. */
    /* The IDs come early, so only a short prefix is unescaped. */
    uint8_t rbsp[64];
    size_t used = 0;
    unsigned zeros = 0;
    for (size_t i = avc ? 1 : 2; i < size && used < sizeof(rbsp); i++) {
        if (zeros >= 2 && nal[i] == 3) {
            zeros = 0;
            continue;
        }
        zeros = nal[i] ? 0 : zeros + 1;
        rbsp[used++] = nal[i];
    }
    Reader reader = {rbsp, used * 8, 0, 0};
    uint32_t id;
    if (avc && type == AVC_PPS) {
        id = ue(&reader);
        return reader.error || id > 255 ? AVERROR_INVALIDDATA : 32 + (int)id;
    }
    if (avc && type == AVC_SPS_EXT) {
        id = ue(&reader);
        return reader.error || id > 31 ? AVERROR_INVALIDDATA : AVC_EXT_SLOT + (int)id;
    }
    if (avc) { /* A subset set begins as a sequence parameter set does. */
        skip(&reader, 24); /* profile_idc, constraint flags, level_idc */
        id = ue(&reader);
        return reader.error || id > 31 ? AVERROR_INVALIDDATA : (type == AVC_SUBSET_SPS ? AVC_SUBSET_SLOT : 0) + (int)id;
    }
    if (type == PPS) {
        id = ue(&reader);
        return reader.error || id > 63 ? AVERROR_INVALIDDATA : 32 + (int)id;
    }
    if (type != SPS)
        return AVERROR_INVALIDDATA;
    skip(&reader, 4); /* sps_video_parameter_set_id */
    unsigned sub_layers = 0;
    for (int i = 0; i < 3; i++)
        sub_layers = sub_layers << 1 | bit(&reader);
    if (layer && sub_layers == 7) { /* sps_ext_or_max_sub_layers_minus1: a multilayer extension set has no profile. */
        id = ue(&reader);
        return reader.error || id > 15 ? AVERROR_INVALIDDATA : 16 + (int)id;
    }
    skip(&reader, 1 + 88 + 8); /* temporal nesting, general profile, general level */
    unsigned profile_present = 0, level_present = 0;
    for (unsigned i = 0; i < sub_layers; i++) {
        profile_present |= bit(&reader) << i;
        level_present |= bit(&reader) << i;
    }
    if (sub_layers)
        skip(&reader, 2 * (8 - sub_layers));
    for (unsigned i = 0; i < sub_layers; i++)
        skip(&reader, (profile_present >> i & 1 ? 88 : 0) + (level_present >> i & 1 ? 8 : 0));
    id = ue(&reader);
    return reader.error || id > 15 ? AVERROR_INVALIDDATA : 16 + (int)id;
}

/* Returns 1 when the set changed the active sets, 0 when it repeats one, else a negative AVERROR. */
static int apply_unit(MPCutHevcSets *sets, const uint8_t *nal, size_t size) {
    int index = slot(sets->avc, nal, size);
    if (index < 0)
        return index;
    Unit *unit = &sets->active[index];
    if (unit->data && unit->size == size && !memcmp(unit->data, nal, size))
        return 0;
    uint8_t *copy = av_memdup(nal, size);
    if (!copy)
        return AVERROR(ENOMEM);
    av_free(unit->data);
    *unit = (Unit){copy, size};
    return 1;
}

/* Apply every parameter set in an hvcC record. With `other` set, also keep its other arrays. */
static int apply_record(MPCutHevcSets *sets, const uint8_t *config, int size, int other) {
    if (!config || size < 23 || config[0] != 1)
        return AVERROR_INVALIDDATA;
    int changed = 0;
    const uint8_t *p = config + 23, *end = config + size;
    for (unsigned array = 0; array < config[22]; array++) {
        if (end - p < 3)
            return AVERROR_INVALIDDATA;
        const uint8_t *start = p;
        unsigned type = p[0] & 0x3f, count = AV_RB16(p + 1);
        p += 3;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2 || end - p - 2 < AV_RB16(p))
                return AVERROR_INVALIDDATA;
            size_t length = AV_RB16(p);
            if (type >= VPS && type <= PPS && length) {
                int result = apply_unit(sets, p + 2, length);
                if (result < 0)
                    return result;
                changed |= result;
            }
            p += 2 + length;
        }
        if (other && (type < VPS || type > PPS)) {
            uint8_t *grown = av_realloc(sets->other, sets->other_size + (size_t)(p - start));
            if (!grown)
                return AVERROR(ENOMEM);
            memcpy(grown + sets->other_size, start, (size_t)(p - start));
            sets->other = grown;
            sets->other_size += (size_t)(p - start);
            sets->other_arrays++;
        }
    }
    return changed;
}

void mpcut_hevc_sets_free(MPCutHevcSets *sets) {
    if (!sets)
        return;
    for (int i = 0; i < SLOTS; i++) {
        av_free(sets->active[i].data);
        av_free(sets->initial[i].data);
    }
    av_free(sets->other);
    av_free(sets);
}

/* Keep the sets read from the record as the initial ones. NULL (and the sets freed) unless every kind is present. */
static MPCutHevcSets *keep_initial(MPCutHevcSets *sets) {
    int types = 0;
    for (int i = 0; i < SLOTS; i++) {
        if (!sets->active[i].data)
            continue;
        types |= sets->avc ? (i < 32 ? 2 : i < AVC_EXT_SLOT ? 4 : 0) : (i < 16 ? 1 : i < 32 ? 2 : 4);
        if (!(sets->initial[i].data = av_memdup(sets->active[i].data, sets->active[i].size))) {
            mpcut_hevc_sets_free(sets);
            return NULL;
        }
        sets->initial[i].size = sets->active[i].size;
    }
    if (types != (sets->avc ? 6 : 7)) {
        mpcut_hevc_sets_free(sets);
        return NULL;
    }
    return sets;
}

MPCutHevcSets *mpcut_hevc_sets_create(const uint8_t *config, int size) {
    MPCutHevcSets *sets = av_mallocz(sizeof(*sets));
    if (!sets || apply_record(sets, config, size, 1) < 0) {
        mpcut_hevc_sets_free(sets);
        return NULL;
    }
    memcpy(sets->header, config, sizeof(sets->header));
    return keep_initial(sets);
}

/* Apply the sequence and picture parameter sets of an avcC record. */
static int apply_avcc(MPCutHevcSets *sets, const uint8_t *config, int size) {
    if (!config || size < 7 || config[0] != 1)
        return AVERROR_INVALIDDATA;
    int changed = 0;
    const uint8_t *p = config + 5, *end = config + size;
    for (int kind = 0; kind < 2; kind++) {
        if (end - p < 1)
            return AVERROR_INVALIDDATA;
        unsigned count = kind ? p[0] : p[0] & 0x1f;
        p++;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2 || end - p - 2 < AV_RB16(p))
                return AVERROR_INVALIDDATA;
            int result = AV_RB16(p) ? apply_unit(sets, p + 2, AV_RB16(p)) : 0;
            if (result < 0)
                return result;
            changed |= result;
            p += 2 + AV_RB16(p);
        }
    }
    // A high profile record may end with its sequence parameter set extensions. Records that leave that part out,
    // or fill it with something else, keep only the sets above, as they did before it was read.
    unsigned profile = config[1];
    if (profile == 66 || profile == 77 || profile == 88 || end - p < 4)
        return changed;
    unsigned count = p[3];
    p += 4;
    for (unsigned i = 0; i < count && end - p >= 2 && end - p - 2 >= AV_RB16(p); i++) {
        size_t length = AV_RB16(p);
        if (length && (p[2] & 0x1f) == AVC_SPS_EXT) {
            int result = apply_unit(sets, p + 2, length);
            if (result < 0)
                return result;
            changed |= result;
        }
        p += 2 + length;
    }
    return changed;
}

MPCutHevcSets *mpcut_avc_sets_create(const uint8_t *config, int size) {
    MPCutHevcSets *sets = av_mallocz(sizeof(*sets));
    if (sets)
        sets->avc = 1;
    if (!sets || apply_avcc(sets, config, size) < 0) {
        mpcut_hevc_sets_free(sets);
        return NULL;
    }
    return keep_initial(sets);
}

int mpcut_hevc_sets_apply_config(MPCutHevcSets *sets, const uint8_t *config, int size) {
    return sets->avc ? apply_avcc(sets, config, size) : apply_record(sets, config, size, 0);
}

int mpcut_hevc_sets_apply_sample(MPCutHevcSets *sets, const uint8_t *data, int size, int length_size) {
    if (length_size < 1 || length_size > 4 || size < 0)
        return AVERROR_INVALIDDATA;
    int changed = 0;
    for (const uint8_t *p = data, *end = data + size; p < end;) {
        if (end - p < length_size)
            return AVERROR_INVALIDDATA;
        size_t length = 0;
        for (int i = 0; i < length_size; i++)
            length = length << 8 | p[i];
        p += length_size;
        if (!length || (size_t)(end - p) < length)
            return AVERROR_INVALIDDATA;
        if (parameter_set(sets->avc, p)) {
            int result = apply_unit(sets, p, length);
            if (result < 0)
                return result;
            changed |= result;
        }
        p += length;
    }
    return changed;
}

int mpcut_hevc_sets_new_pictures(const MPCutHevcSets *sets, const uint8_t *data, int size, int length_size,
                                 uint8_t **units, int *units_size) {
    if (sets->avc || length_size < 1 || length_size > 4 || size < 0)
        return AVERROR_INVALIDDATA;
    for (const uint8_t *p = data, *end = data + size; p < end;) {
        if (end - p < length_size)
            return AVERROR_INVALIDDATA;
        size_t length = 0;
        for (int i = 0; i < length_size; i++)
            length = length << 8 | p[i];
        p += length_size;
        if (!length || (size_t)(end - p) < length)
            return AVERROR_INVALIDDATA;
        unsigned type = (p[0] >> 1) & 0x3f;
        if (type >= VPS && type <= PPS) {
            int index = slot(0, p, length);
            if (index < 0)
                return index;
            const Unit *unit = &sets->active[index];
            if (!(unit->data && unit->size == length && !memcmp(unit->data, p, length))) {
                if (type != PPS || unit->data || length > INT_MAX - 4 || *units_size > INT_MAX - 4 - (int)length)
                    return 0;
                uint8_t *grown = av_realloc(*units, (size_t)*units_size + 4 + length);
                if (!grown)
                    return AVERROR(ENOMEM);
                AV_WB32(grown + *units_size, (uint32_t)length);
                memcpy(grown + *units_size + 4, p, length);
                *units = grown;
                *units_size += 4 + (int)length;
            }
        }
        p += length;
    }
    return 1;
}

int mpcut_hevc_sets_initial(const MPCutHevcSets *sets) {
    for (int i = 0; i < SLOTS; i++) {
        const Unit *a = &sets->active[i], *b = &sets->initial[i];
        if (a->size != b->size || (a->size && memcmp(a->data, b->data, a->size)))
            return 0;
    }
    return 1;
}

MPCutHevcSets *mpcut_hevc_sets_copy(const MPCutHevcSets *sets) {
    MPCutHevcSets *copy = av_mallocz(sizeof(*copy));
    if (!copy)
        return NULL;
    copy->avc = sets->avc;
    memcpy(copy->header, sets->header, sizeof(copy->header));
    int failed = sets->other_size && !(copy->other = av_memdup(sets->other, sets->other_size));
    copy->other_size = sets->other_size;
    copy->other_arrays = sets->other_arrays;
    for (int i = 0; i < SLOTS && !failed; i++) {
        const Unit *units[] = {&sets->active[i], &sets->initial[i]};
        Unit *copies[] = {&copy->active[i], &copy->initial[i]};
        for (int k = 0; k < 2 && !failed; k++) {
            if (units[k]->data && !(copies[k]->data = av_memdup(units[k]->data, units[k]->size)))
                failed = 1;
            copies[k]->size = copies[k]->data ? units[k]->size : 0;
        }
    }
    if (failed) {
        mpcut_hevc_sets_free(copy);
        return NULL;
    }
    return copy;
}

int mpcut_hevc_sets_holds(const MPCutHevcSets *sets, const MPCutHevcSets *other) {
    for (int i = 0; i < SLOTS; i++) {
        const Unit *a = &sets->active[i], *b = &other->active[i];
        if (b->data && (!a->data || a->size != b->size || memcmp(a->data, b->data, b->size)))
            return 0;
    }
    return sets->avc == other->avc;
}

int mpcut_hevc_sets_units(const MPCutHevcSets *sets, uint8_t **units, int *size) {
    *units = NULL;
    *size = 0;
    size_t total = 0;
    for (int i = 0; i < SLOTS; i++)
        total += sets->active[i].data ? 4 + sets->active[i].size : 0;
    if (total > INT_MAX - 64)
        return AVERROR_INVALIDDATA;
    uint8_t *bytes = av_malloc(total + 1), *q = bytes;
    if (!bytes)
        return AVERROR(ENOMEM);
    for (int n = 0; n < SLOTS; n++) { /* Video, then sequence, then picture parameter sets. */
        // H.264 puts sequence parameter set extensions and subset sets before the picture parameter sets that use them.
        int i = !sets->avc || n < 32 ? n : n < 96 ? AVC_EXT_SLOT + n - 32 : n - 64;
        const Unit *unit = &sets->active[i];
        if (!unit->data)
            continue;
        AV_WB32(q, (uint32_t)unit->size);
        memcpy(q + 4, unit->data, unit->size);
        q += 4 + unit->size;
    }
    *units = bytes;
    *size = (int)total;
    return 0;
}

int mpcut_hevc_sets_record(const MPCutHevcSets *sets, uint8_t **record, int *size) {
    *record = NULL;
    *size = 0;
    if (sets->avc)
        return AVERROR(ENOSYS);
    static const struct { unsigned type, first, count; } kinds[] = {{VPS, 0, 16}, {SPS, 16, 16}, {PPS, 32, 64}};
    size_t total = 23 + sets->other_size;
    unsigned arrays = sets->other_arrays;
    for (unsigned k = 0; k < 3; k++) {
        unsigned count = 0;
        for (unsigned i = kinds[k].first; i < kinds[k].first + kinds[k].count; i++) {
            if (sets->active[i].data) {
                if (sets->active[i].size > UINT16_MAX)
                    return AVERROR_INVALIDDATA;
                total += 2 + sets->active[i].size;
                count++;
            }
        }
        if (count) {
            total += 3;
            arrays++;
        }
    }
    if (arrays > 255 || total > INT_MAX - 64)
        return AVERROR_INVALIDDATA;
    uint8_t *bytes = av_mallocz(total + 64);
    if (!bytes)
        return AVERROR(ENOMEM);
    memcpy(bytes, sets->header, sizeof(sets->header));
    bytes[22] = (uint8_t)arrays;
    uint8_t *q = bytes + 23;
    for (unsigned k = 0; k < 3; k++) {
        uint8_t *heading = q;
        unsigned count = 0;
        q += 3;
        for (unsigned i = kinds[k].first; i < kinds[k].first + kinds[k].count; i++) {
            const Unit *unit = &sets->active[i];
            if (!unit->data)
                continue;
            AV_WB16(q, (unsigned)unit->size);
            memcpy(q + 2, unit->data, unit->size);
            q += 2 + unit->size;
            count++;
        }
        if (!count) {
            q = heading;
            continue;
        }
        heading[0] = (uint8_t)(0x80 | kinds[k].type); /* array_completeness: every set is here */
        AV_WB16(heading + 1, count);
    }
    if (sets->other_size)
        memcpy(q, sets->other, sets->other_size);
    *record = bytes;
    *size = (int)total;
    return 0;
}

/* Skip a profile_tier_level() of a video parameter set: the general profile when present, the general level, and the
 * sub-layer flags, profiles and levels. */
static void skip_profile(Reader *reader, int profile, unsigned sub_layers) {
    skip(reader, (profile ? 88 : 0) + 8);
    unsigned profile_present = 0, level_present = 0;
    for (unsigned i = 0; i < sub_layers; i++) {
        profile_present |= bit(reader) << i;
        level_present |= bit(reader) << i;
    }
    if (sub_layers)
        skip(reader, 2 * (8 - sub_layers));
    for (unsigned i = 0; i < sub_layers; i++)
        skip(reader, (profile_present >> i & 1 ? 88 : 0) + (level_present >> i & 1 ? 8 : 0));
}

/* The scalability a video parameter set's extension declares for its layers: 2 for views (MV-HEVC), 3 for an
 * auxiliary alpha picture, 4 for another auxiliary picture (depth), else 1. */
static int vps_scalability(const uint8_t *nal, size_t size) {
    uint8_t rbsp[512];
    size_t used = 0;
    unsigned zeros = 0;
    for (size_t i = 2; i < size && used < sizeof(rbsp); i++) {
        if (zeros >= 2 && nal[i] == 3) {
            zeros = 0;
            continue;
        }
        zeros = nal[i] ? 0 : zeros + 1;
        rbsp[used++] = nal[i];
    }
    Reader reader = {rbsp, used * 8, 0, 0};
    skip(&reader, 4); /* vps_video_parameter_set_id */
    unsigned base_internal = bit(&reader);
    skip(&reader, 1); /* vps_base_layer_available_flag */
    unsigned max_layers = 0, sub_layers = 0;
    for (int i = 0; i < 6; i++)
        max_layers = max_layers << 1 | bit(&reader);
    for (int i = 0; i < 3; i++)
        sub_layers = sub_layers << 1 | bit(&reader);
    skip(&reader, 17); /* temporal nesting, reserved 0xffff */
    skip_profile(&reader, 1, sub_layers);
    unsigned ordering = bit(&reader);
    for (unsigned i = ordering ? 0 : sub_layers; i <= sub_layers; i++) {
        ue(&reader);
        ue(&reader);
        ue(&reader);
    }
    unsigned max_layer_id = 0;
    for (int i = 0; i < 6; i++)
        max_layer_id = max_layer_id << 1 | bit(&reader);
    uint32_t layer_sets = ue(&reader);
    if (reader.error || layer_sets > 1023)
        return 1;
    skip(&reader, (size_t)(max_layer_id + 1) * layer_sets);
    if (bit(&reader) || reader.error) /* vps_timing_info_present_flag: HRD parameters follow, which are not read. */
        return 1;
    if (!bit(&reader)) /* vps_extension_flag */
        return 1;
    while (reader.position & 7)
        skip(&reader, 1); /* vps_extension_alignment_bit_equal_to_one */
    if (max_layers > 0 && base_internal)
        skip_profile(&reader, 0, sub_layers);
    unsigned splitting = bit(&reader), types = 0, mask[16], lengths[16] = {0};
    for (unsigned i = 0; i < 16; i++)
        if (bit(&reader))
            mask[types++] = i;
    for (unsigned j = 0; j + splitting < types; j++) {
        unsigned length = 0;
        for (int i = 0; i < 3; i++)
            length = length << 1 | bit(&reader);
        lengths[j] = length + 1;
    }
    if (reader.error)
        return 1;
    int views = 0, auxiliary = -1;
    for (unsigned j = 0; j < types; j++) {
        views |= mask[j] == 1;
        if (mask[j] == 3)
            auxiliary = (int)j;
    }
    if (views)
        return 2;
    if (auxiliary < 0)
        return 1;
    if (splitting)
        return 4; /* The auxiliary type is in the layer IDs, which are not read here. */
    unsigned present = bit(&reader);
    for (unsigned layer = 1; layer <= max_layers && !reader.error; layer++) {
        if (present)
            skip(&reader, 6); /* layer_id_in_nuh */
        for (unsigned j = 0; j < types; j++) {
            unsigned value = 0;
            for (unsigned i = 0; i < lengths[j]; i++)
                value = value << 1 | bit(&reader);
            if ((int)j == auxiliary && value == 1 && !reader.error)
                return 3; /* AUX_ALPHA */
        }
    }
    return 4;
}

int mpcut_hevc_layer_kind(const uint8_t *config, int size) {
    if (!config || size < 23 || config[0] != 1)
        return MPCUT_HEVC_SINGLE_LAYER;
    const uint8_t *vps = NULL, *p = config + 23, *end = config + size;
    size_t vps_size = 0;
    int higher = 0;
    for (unsigned array = 0; array < config[22]; array++) {
        if (end - p < 3)
            return MPCUT_HEVC_SINGLE_LAYER;
        unsigned count = AV_RB16(p + 1);
        p += 3;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2 || end - p - 2 < AV_RB16(p))
                return MPCUT_HEVC_SINGLE_LAYER;
            size_t length = AV_RB16(p);
            const uint8_t *nal = p + 2;
            if (length >= 2 && ((nal[0] & 1) << 5 | nal[1] >> 3) != 0)
                higher = 1;
            else if (length >= 4 && ((nal[0] >> 1) & 0x3f) == VPS && !vps) {
                vps = nal;
                vps_size = length;
            }
            p += 2 + length;
        }
    }
    if (!higher)
        return MPCUT_HEVC_SINGLE_LAYER;
    switch (vps ? vps_scalability(vps, vps_size) : 1) {
        case 2: return MPCUT_HEVC_VIEWS;
        case 3: return MPCUT_HEVC_ALPHA;
        case 4: return MPCUT_HEVC_AUXILIARY;
        default: return MPCUT_HEVC_OTHER_LAYER;
    }
}

const char *mpcut_hevc_layers(const uint8_t *config, int size) {
    switch (mpcut_hevc_layer_kind(config, size)) {
        case MPCUT_HEVC_VIEWS: return "the second view";
        case MPCUT_HEVC_ALPHA: return "the alpha layer";
        case MPCUT_HEVC_AUXILIARY: return "the auxiliary picture layer";
        case MPCUT_HEVC_OTHER_LAYER: return "the additional picture layer";
        default: return NULL;
    }
}
