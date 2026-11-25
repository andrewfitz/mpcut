#ifndef MPCUT_HEVC_SETS_H
#define MPCUT_HEVC_SETS_H

#include <stdint.h>

/* The HEVC video, sequence and picture parameter sets (or the H.264 sequence and
 * picture parameter sets) a decoder holds at one point in a copied stream, keyed by
 * type and ID as a decoder keys them. A later set with the same type and ID replaces
 * the earlier one. HEVC sets of every layer count (the second view of MV-HEVC, an
 * alpha layer), keyed as the base layer's are, and so do H.264 sequence parameter set
 * extensions (an auxiliary alpha picture's format) and subset sequence parameter sets
 * (MVC and SVC), each under IDs of their own. An update holding a set that cannot be
 * read fails. */
typedef struct MPCutHevcSets MPCutHevcSets;

/* Start from the sets of an hvcC record. NULL for a record that cannot be read, or that
 * does not hold at least one set of each type. */
MPCutHevcSets *mpcut_hevc_sets_create(const uint8_t *config, int size);
/* The same for H.264, from an avcC record. hevc_sets_new_pictures and hevc_sets_record do not take these sets. */
MPCutHevcSets *mpcut_avc_sets_create(const uint8_t *config, int size);
void mpcut_hevc_sets_free(MPCutHevcSets *sets);

/* Apply the sets of another record of the same kind, or of a sample with length-prefixed NAL units.
 * Return 1 when the active sets changed, 0 when they did not, or a negative AVERROR. */
int mpcut_hevc_sets_apply_config(MPCutHevcSets *sets, const uint8_t *config, int size);
int mpcut_hevc_sets_apply_sample(MPCutHevcSets *sets, const uint8_t *data, int size, int length_size);

/* Append to *units (each with a 4-byte length) the picture parameter sets of a sample with length-prefixed NAL
 * units whose IDs no active set holds. Returns 1 when every set the sample would change is such a picture
 * parameter set, 0 when it would replace a set or change a video or sequence parameter set, or a negative AVERROR.
 * The active sets do not change. HEVC only. */
int mpcut_hevc_sets_new_pictures(const MPCutHevcSets *sets, const uint8_t *data, int size, int length_size,
                                 uint8_t **units, int *units_size);

/* 1 when the active sets are exactly those of the record the sets were created from. */
int mpcut_hevc_sets_initial(const MPCutHevcSets *sets);

/* An independent copy of the sets, or NULL. */
MPCutHevcSets *mpcut_hevc_sets_copy(const MPCutHevcSets *sets);

/* 1 when every set active in `other` is active in `sets` with the same bytes. */
int mpcut_hevc_sets_holds(const MPCutHevcSets *sets, const MPCutHevcSets *other);

/* Every active set as NAL units with 4-byte lengths, video before sequence before picture parameter sets (H.264
 * sequence parameter set extensions and subset sets with the sequence parameter sets),
 * which a decoder that reads them in this order ends up holding. Returns 0 with av_malloc'd units, or a negative
 * AVERROR. */
int mpcut_hevc_sets_units(const MPCutHevcSets *sets, uint8_t **units, int *size);

/* An hvcC record holding every active set, with the header and any SEI arrays of the
 * initial record. Sets of higher layers go into the same arrays, as FFmpeg's MOV reader
 * gives them with an lhvC box: its writer puts them back into lhvC for a track marked
 * AV_DISPOSITION_MULTILAYER. Returns 0 with an av_malloc'd record, or a negative AVERROR. */
int mpcut_hevc_sets_record(const MPCutHevcSets *sets, uint8_t **record, int *size);

/* What the parameter sets of layers above the base layer in an hvcC record (FFmpeg appends an lhvC box's arrays to
 * it) are for, from the scalability its video parameter set declares: "the second view" (MV-HEVC spatial video),
 * "the alpha layer" (HEVC with alpha), "the auxiliary picture layer", or "the additional picture layer". NULL when
 * the record holds no set of a higher layer. */
const char *mpcut_hevc_layers(const uint8_t *config, int size);

/* The same as a kind. */
enum { MPCUT_HEVC_SINGLE_LAYER, MPCUT_HEVC_OTHER_LAYER, MPCUT_HEVC_VIEWS, MPCUT_HEVC_ALPHA, MPCUT_HEVC_AUXILIARY };
int mpcut_hevc_layer_kind(const uint8_t *config, int size);

#endif
