#include <tiletrail.h>

static inline int mpcut_tiletrail_has_feed_layouts(void) {
#ifdef TILETRAIL_HAS_FEED_LAYOUTS
    return 1;
#else
    return 0;
#endif
}

static inline uint32_t mpcut_tiletrail_feed_detector_revision(void) {
#if defined(TILETRAIL_FEED_DETECTOR_REVISION)
    return TILETRAIL_FEED_DETECTOR_REVISION;
#elif defined(TILETRAIL_HAS_FEED_LAYOUTS)
    return 1;
#else
    return 0;
#endif
}

// Zero unless TileTrail documents the grid it samples from a larger frame.
static inline int mpcut_tiletrail_sample_limit(void) {
#ifdef TILETRAIL_SAMPLE_LIMIT
    return (int)TILETRAIL_SAMPLE_LIMIT;
#else
    return 0;
#endif
}

// Prepared frames let several threads measure and detect ahead of the pushes.
static inline int mpcut_tiletrail_has_prepared_frames(void) {
#ifdef TILETRAIL_HAS_PREPARED_FRAMES
    return 1;
#else
    return 0;
#endif
}

static inline void *mpcut_tiletrail_analyzer_prepare(const tiletrail_analyzer_t *analyzer,
                                                     const tiletrail_frame_t *frame) {
#ifdef TILETRAIL_HAS_PREPARED_FRAMES
    tiletrail_prepared_t *prepared = 0;
    return tiletrail_analyzer_prepare(analyzer, frame, &prepared, 0) == TILETRAIL_OK ? prepared : 0;
#else
    return 0;
#endif
}

// Consumes prepared.
static inline int32_t mpcut_tiletrail_analyzer_push_prepared(
    tiletrail_analyzer_t *analyzer, void *prepared, uint32_t coarse,
    uint32_t *outcome, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_PREPARED_FRAMES
    return tiletrail_analyzer_push_prepared(analyzer, (tiletrail_prepared_t *)prepared, coarse, outcome, error);
#else
    return -1;
#endif
}

static inline void mpcut_tiletrail_prepared_free(void *prepared) {
#ifdef TILETRAIL_HAS_PREPARED_FRAMES
    tiletrail_prepared_free((tiletrail_prepared_t *)prepared);
#endif
}

static inline int mpcut_tiletrail_has_coarse_push(void) {
#ifdef TILETRAIL_HAS_COARSE_PUSH
    return 1;
#else
    return 0;
#endif
}

// Without the coarse entry point every frame is refused and analyzed in full.
static inline int32_t mpcut_tiletrail_analyzer_push_coarse(
    tiletrail_analyzer_t *analyzer, const tiletrail_frame_t *frame,
    uint32_t *outcome, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_COARSE_PUSH
    return tiletrail_analyzer_push_coarse(analyzer, frame, outcome, error);
#else
    *outcome = 1;
    return TILETRAIL_OK;
#endif
}

static inline int mpcut_tiletrail_coarse_committed(uint32_t outcome) {
#ifdef TILETRAIL_HAS_COARSE_PUSH
    return outcome == TILETRAIL_COARSE_COMMITTED;
#else
    return 0;
#endif
}

// One before TileTrail published a revision for meeting analysis.
static inline uint32_t mpcut_tiletrail_meeting_detector_revision(void) {
#ifdef TILETRAIL_MEETING_DETECTOR_REVISION
    return TILETRAIL_MEETING_DETECTOR_REVISION;
#else
    return 1;
#endif
}

static inline int32_t mpcut_tiletrail_analyzer_create_feeds(
    const tiletrail_config_t *config, tiletrail_timestamp_t start,
    uint32_t columns, uint32_t rows, tiletrail_analyzer_t **out, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_FEED_LAYOUTS
    return tiletrail_analyzer_create_feeds(config, start, columns, rows, out, error);
#else
    return -1;
#endif
}
