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
static inline int mpcut_tiletrail_has_prepared_frames(int gpu_required) {
#ifndef TILETRAIL_HAS_GPU_PREPARED_FRAMES
    if (gpu_required) return 0;
#endif
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

static inline int mpcut_tiletrail_has_gallery_hint(void) {
#ifdef TILETRAIL_HAS_GALLERY_HINT
    return 1;
#else
    return 0;
#endif
}

static inline int32_t mpcut_tiletrail_analyzer_create_gallery(
    const tiletrail_config_t *config, tiletrail_timestamp_t start,
    uint32_t columns, uint32_t rows, tiletrail_analyzer_t **out, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_GALLERY_HINT
    return tiletrail_analyzer_create_gallery(config, start, columns, rows, out, error);
#else
    return -1;
#endif
}

#include <errno.h>
#include <stddef.h>
#include <unistd.h>

#ifdef TILETRAIL_HAS_CHECKPOINTS
typedef tiletrail_checkpoint_cursor_t mpcut_tiletrail_checkpoint_cursor_t;

static inline ptrdiff_t mpcut_tiletrail_checkpoint_read_fd(void *context, uint8_t *data, size_t capacity) {
    const int fd = *(const int *)context;
    ssize_t count;
    do { count = read(fd, data, capacity); } while (count < 0 && errno == EINTR);
    return count;
}

static inline int32_t mpcut_tiletrail_checkpoint_write_fd(void *context, const uint8_t *data, size_t size) {
    const int fd = *(const int *)context;
    while (size) {
        ssize_t count = write(fd, data, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        data += count;
        size -= (size_t)count;
    }
    return 0;
}
#else
typedef struct { size_t observations, events, coarse; } mpcut_tiletrail_checkpoint_cursor_t;
#endif

static inline int mpcut_tiletrail_has_checkpoints(void) {
#ifdef TILETRAIL_HAS_CHECKPOINTS
    return 1;
#else
    return 0;
#endif
}

static inline int32_t mpcut_tiletrail_checkpoint_read(tiletrail_analyzer_t *analyzer,
    mpcut_tiletrail_checkpoint_cursor_t *cursor, int fd, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_CHECKPOINTS
    return tiletrail_analyzer_checkpoint_read(analyzer, cursor, mpcut_tiletrail_checkpoint_read_fd, &fd, error);
#else
    return -1;
#endif
}

static inline int32_t mpcut_tiletrail_checkpoint_write(const tiletrail_analyzer_t *analyzer,
    mpcut_tiletrail_checkpoint_cursor_t *cursor, int fd, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_CHECKPOINTS
    return tiletrail_analyzer_checkpoint_write(analyzer, cursor, mpcut_tiletrail_checkpoint_write_fd, &fd, error);
#else
    return -1;
#endif
}

typedef int32_t (*mpcut_tiletrail_result_chunk_t)(void *context, uint32_t kind, const uint8_t *data, size_t size);

static inline int mpcut_tiletrail_has_result_chunks(void) {
#ifdef TILETRAIL_HAS_RESULT_CHUNKS
    return 1;
#else
    return 0;
#endif
}

static inline int32_t mpcut_tiletrail_result_chunks(const tiletrail_analyzer_t *analyzer,
    tiletrail_timestamp_t end, mpcut_tiletrail_result_chunk_t visit, void *context, tiletrail_error_t *error) {
#ifdef TILETRAIL_HAS_RESULT_CHUNKS
    return tiletrail_analyzer_result_chunks(analyzer, end, visit, context, error);
#else
    return -1;
#endif
}
