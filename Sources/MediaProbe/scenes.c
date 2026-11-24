#include "MediaProbe.h"
#include "codec_header.h"
#include "scene_distance.h"
#include "scene_reader.h"
#include "video_clock.h"
#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/buffer.h>
#include <libavutil/cpu.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/avstring.h>
#include <CommonCrypto/CommonDigest.h>
#include <libswscale/swscale.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <string.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// Equal-area spatial samples compare color and composition without decoding a
// full-resolution RGB image. Hardware NV12/P010 surfaces stay in shared memory.
enum { W = 64, H = 36, CHANNELS = 3 };
typedef struct {
    _Alignas(16) uint8_t planes[CHANNELS][W * H + AV_INPUT_BUFFER_PADDING_SIZE];
    int64_t pts;
} ScenePicture;

enum { DIGEST_SIZE = 32, CHECKPOINT_VERSION = 1 };
enum { SCAN_RANGE_END = MP_PARTICIPANT_UNSUPPORTED_DISPLAY_TRANSFORM + 1,
       SCAN_RETRY_FROM_START, SCAN_RETRY_SOFTWARE };
typedef struct {
    int64_t position, dts;
    bool independent;
} ScenePacket;
typedef struct {
    int64_t pts, seek, ordinal;
    uint8_t picture[DIGEST_SIZE], sequence[DIGEST_SIZE];
} SceneAnchor;

typedef struct {
    int version, stream, tb_num, tb_den;
    unsigned decoder_version, scaler_version;
    int has_range, started, finished, has_leading, software;
    int64_t start_pts, end_pts, initial_seek;
    int64_t count, confirmed;
    double motion, pending, last_delta;
    ScenePicture frames[3];
    SceneAnchor initial, previous, latest;
    uint8_t leading[MP_SCENE_FEATURE_SIZE];
} SceneCheckpoint;

typedef struct {
    ScenePicture frames[3];
    int64_t count;
    double motion, pending, last_delta;
    struct SwsContext *scale;
    size_t width, height;
    size_t luma_x[W], chroma_x[W], sample_y[H];
    MPSceneVisit visit;
    MPParticipantFrameSelect select_picture;
    MPParticipantFrameVisit picture;
    // Interleave planar 4:2:0 chroma so software pictures convert as NV12.
    bool pack_nv12;
    uint8_t *chroma;
    unsigned chroma_size;
    AVFormatContext *picture_format;
    AVStream *picture_stream;
    int32_t picture_display_matrix[9];
    struct SwsContext *rgb_scale;
    AVFrame *rgb_frame;
    int rgb_source_width, rgb_source_height, rgb_source_format;
    enum AVColorSpace rgb_source_space;
    enum AVColorRange rgb_source_range;
    int64_t pictures;
    MPProbeCancelled cancelled;
    void *context;
    const MPSceneScanOptions *options;
    MPSceneCheckpointVisit checkpoint;
    CC_SHA256_CTX sha;
    SceneCheckpoint saved;
    SceneAnchor replay;
    const SceneAnchor *replay_anchor;
    int64_t replay_count;
    bool restoring;
} Scan;

static double distance(const ScenePicture *a, const ScenePicture *b)
{
    unsigned sum = 0;
    for (int c = 0; c < CHANNELS; c++)
        sum += mp_scene_byte_distance(a->planes[c], b->planes[c], W * H);
    return (double)sum / (W * H);
}

static void sample_grid(Scan *scan, size_t width, size_t height)
{
    if (width == scan->width && height == scan->height) return;
    scan->width = width;
    scan->height = height;
    for (int x = 0; x < W; x++) {
        scan->luma_x[x] = (2*x + 1) * width / (2*W);
        scan->chroma_x[x] = scan->luma_x[x] / 2;
    }
    for (int y = 0; y < H; y++)
        scan->sample_y[y] = (2*y + 1) * height / (2*H);
}

static int sample_surface(Scan *scan, CVPixelBufferRef surface, ScenePicture *picture)
{
    OSType format = CVPixelBufferGetPixelFormatType(surface);
    bool wide = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if (!wide && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
                 format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return 0;
    if (CVPixelBufferLockBaseAddress(surface, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return 0;
    sample_grid(scan, CVPixelBufferGetWidth(surface), CVPixelBufferGetHeight(surface));
    // P010 stores the ten bits at the top of a little-endian word.
    // Keep its high byte, exactly as for an eight-bit sample.
    const int bytes = wide ? 2 : 1;
    const uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(surface, 0);
    const uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(surface, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(surface, 0);
    size_t cs = CVPixelBufferGetBytesPerRowOfPlane(surface, 1);
    for (int y = 0; y < H; y++) {
        size_t sy = scan->sample_y[y];
        const uint8_t *luma_row = luma + sy * ys;
        const uint8_t *chroma_row = chroma + (sy/2) * cs;
        for (int x = 0; x < W; x++) {
            size_t cx = 2 * scan->chroma_x[x] * bytes + (bytes - 1);
            int i = y*W + x;
            picture->planes[0][i] = luma_row[scan->luma_x[x] * bytes + (bytes - 1)];
            picture->planes[1][i] = chroma_row[cx];
            picture->planes[2][i] = chroma_row[cx + bytes];
        }
    }
    CVPixelBufferUnlockBaseAddress(surface, kCVPixelBufferLock_ReadOnly);
    return 1;
}

static void sample_planar_420(Scan *scan, const AVFrame *frame, ScenePicture *picture)
{
    sample_grid(scan, frame->width, frame->height);
    const bool wide = frame->format == AV_PIX_FMT_YUV420P10LE;
    // Use the same points and code values as the bi-planar hardware path.
    // Scaling YUVJ420P to YUV444P would compress its full range.
    for (int c = 0; c < CHANNELS; c++) {
        const size_t *sample_x = c == 0 ? scan->luma_x : scan->chroma_x;
        for (int y = 0; y < H; y++) {
            ptrdiff_t sy = scan->sample_y[y] / (c == 0 ? 1 : 2);
            const uint8_t *row = frame->data[c] + sy * frame->linesize[c];
            uint8_t *out = &picture->planes[c][y * W];
            for (int x = 0; x < W; x++) {
                size_t sx = sample_x[x];
                out[x] = wide ? AV_RL16(row + 2 * sx) >> 2 : row[sx];
            }
        }
    }
}

static int sample(Scan *scan, AVFrame *frame, ScenePicture *picture)
{
    AVFrame *mapped = NULL;
    int ret = 0;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (sample_surface(scan, (CVPixelBufferRef)frame->data[3], picture)) return 0;
        // Scale e.g. ProRes 4:2:2 directly from the locked surface, avoiding
        // allocation and copying of a full-resolution software picture.
        if (!(mapped = av_frame_alloc())) return AVERROR(ENOMEM);
        ret = av_hwframe_map(mapped, frame, AV_HWFRAME_MAP_READ);
        if (ret < 0) {
            av_frame_unref(mapped);
            if ((ret = av_hwframe_transfer_data(mapped, frame, 0)) < 0) goto done;
        }
        frame = mapped;
    }
    if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P ||
        frame->format == AV_PIX_FMT_YUV420P10LE) {
        sample_planar_420(scan, frame, picture);
        goto done;
    }
    scan->scale = sws_getCachedContext(scan->scale, frame->width, frame->height, frame->format,
                                      W, H, AV_PIX_FMT_YUV444P, SWS_POINT, NULL, NULL, NULL);
    if (!scan->scale) { ret = AVERROR(ENOMEM); goto done; }
    uint8_t *out[4] = { picture->planes[0], picture->planes[1], picture->planes[2], NULL };
    int stride[4] = { W, W, W, 0 };
    ret = sws_scale(scan->scale, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, out, stride);
    if (ret != H) { ret = AVERROR_INVALIDDATA; goto done; }
    ret = 0;
done:
    av_frame_free(&mapped);
    return ret;
}

static void start_range(Scan *scan)
{
    if (scan->saved.started || !scan->saved.has_leading) return;
    scan->saved.started = 1;
    scan->visit(scan->context, MP_SCENE_RANGE_LEADING_PTS, scan->saved.leading);
}

static void emit(Scan *scan, const ScenePicture *frame)
{
    // Average 4x4 neighborhoods for the recurring-view descriptor.
    uint8_t layout[MP_SCENE_FEATURE_SIZE];
    for (int y = 0; y < H/4; y++)
        for (int x = 0; x < W/4; x++)
            for (int c = 0; c < 3; c++) {
                unsigned sum = 0;
                for (int j = 0; j < 4; j++)
                    for (int k = 0; k < 4; k++)
                        sum += frame->planes[c][(4*y+j)*W+4*x+k];
                layout[(y*(W/4)+x)*3+c] = sum/16;
            }
    if (scan->saved.has_range) {
        if (frame->pts < scan->saved.start_pts || scan->count == 0) {
            memcpy(scan->saved.leading, layout, sizeof(layout));
            scan->saved.has_leading = 1;
            return;
        }
        if (frame->pts >= scan->saved.end_pts) return;
        start_range(scan);
    }
    scan->visit(scan->context, frame->pts, layout);
}

static int advance(Scan *scan, ScenePicture *now)
{
    if (scan->count == 0) emit(scan, now);
    else {
        ScenePicture *prev = &scan->frames[(scan->count-1)%3];
        double delta = distance(now, prev);
        // A hard cut is a temporal peak. Compare both sides before
        // accepting it so sustained motion or a composited effect cannot
        // produce a run of adjacent scene starts.
        bool candidate = delta > fmax(22, scan->motion*2.6+6) && delta > 1.25*scan->last_delta;
        if (scan->pending > 0) {
            ScenePicture *before = &scan->frames[(scan->count-2)%3];
            // A flash differs sharply from both neighbors, which resemble
            // each other. Suppress both sides of that excursion.
            double across = distance(before, now);
            if (across < fmax(13, scan->pending*0.35)) {
                candidate = false;
                // Resume motion history between the two ordinary pictures.
                // The return from a flash would mask a cut on the next frame.
                delta = across;
            } else if (scan->pending > 1.25*delta) emit(scan, prev);
        }
        scan->motion = 0.85*scan->motion + 0.15*fmin(delta, fmax(15, scan->motion*2+8));
        scan->pending = candidate ? delta : 0;
        scan->last_delta = delta;
    }
    scan->count++;
    if (!scan->checkpoint && (scan->count % 32) == 0)
        scan->visit(scan->context, now->pts, NULL);
    return 0;
}

static void checkpoint(Scan *scan)
{
    if (!scan->checkpoint || scan->restoring || !scan->count ||
        (scan->saved.has_range && !scan->saved.started)) return;
    SceneCheckpoint *state = &scan->saved;
    state->count = scan->count;
    state->motion = scan->motion;
    state->pending = scan->pending;
    state->last_delta = scan->last_delta;
    memcpy(state->frames, scan->frames, sizeof(scan->frames));
    scan->checkpoint(scan->context, scan->frames[(scan->count-1)%3].pts,
                     state->confirmed, scan->count, (const uint8_t *)state, sizeof(*state));
}

static void picture_digest(Scan *scan, const ScenePicture *picture, const AVFrame *frame,
                           int64_t position, uint8_t digest[DIGEST_SIZE])
{
    const int64_t identity[] = { picture->pts, position, frame->format, frame->width, frame->height };
    CC_SHA256_Init(&scan->sha);
    CC_SHA256_Update(&scan->sha, (const uint8_t *)identity, sizeof(identity));
    for (int c = 0; c < CHANNELS; c++)
        CC_SHA256_Update(&scan->sha, picture->planes[c], W * H);
    CC_SHA256_Final(digest, &scan->sha);
}

static void extend_anchor(Scan *scan, SceneAnchor *anchor, const uint8_t digest[DIGEST_SIZE])
{
    CC_SHA256_Init(&scan->sha);
    CC_SHA256_Update(&scan->sha, anchor->sequence, DIGEST_SIZE);
    CC_SHA256_Update(&scan->sha, digest, DIGEST_SIZE);
    CC_SHA256_Final(anchor->sequence, &scan->sha);
}

static void begin_anchor(SceneAnchor *anchor, int64_t pts, int64_t seek, int64_t ordinal,
                         const uint8_t digest[DIGEST_SIZE])
{
    *anchor = (SceneAnchor){ .pts = pts, .seek = seek, .ordinal = ordinal };
    memcpy(anchor->picture, digest, DIGEST_SIZE);
}

static int reconcile(Scan *scan, const ScenePicture *picture, const uint8_t digest[DIGEST_SIZE])
{
    const SceneAnchor *anchor = scan->replay_anchor;
    if (!scan->replay_count) {
        if (picture->pts < anchor->pts && anchor != &scan->saved.initial) return 0;
        if (picture->pts != anchor->pts || memcmp(digest, anchor->picture, DIGEST_SIZE))
            return picture->pts == anchor->pts && anchor != &scan->saved.initial
                ? 0 : MP_SCENE_RESUME_MISMATCH;
    }
    extend_anchor(scan, &scan->replay, digest);
    if (++scan->replay_count < scan->count - anchor->ordinal + 1) return 0;
    if (picture->pts != scan->frames[(scan->count-1)%3].pts ||
        memcmp(scan->replay.sequence, anchor->sequence, DIGEST_SIZE)) return MP_SCENE_RESUME_MISMATCH;
    scan->restoring = false;
    return scan->saved.finished ? SCAN_RANGE_END : 0;
}

static int rgb_matrix(enum AVColorSpace space)
{
    switch (space) {
        case AVCOL_SPC_BT709: return SWS_CS_ITU709;
        case AVCOL_SPC_FCC: return SWS_CS_FCC;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M: return SWS_CS_ITU601;
        case AVCOL_SPC_SMPTE240M: return SWS_CS_SMPTE240M;
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL: return SWS_CS_BT2020;
        default: return SWS_CS_DEFAULT;
    }
}

static void interleave_chroma(uint8_t *restrict out, const uint8_t *restrict u, const uint8_t *restrict v, int count)
{
    int x = 0;
#if defined(__aarch64__)
    for (; x + 16 <= count; x += 16) {
        const uint8x16x2_t pair = { { vld1q_u8(u + x), vld1q_u8(v + x) } };
        vst2q_u8(out + 2 * x, pair);
    }
#endif
    for (; x < count; x++) {
        out[2 * x] = u[x];
        out[2 * x + 1] = v[x];
    }
}

// Participant coordinates use the recording's declared rotation. A decoded
// override changes the display space independently of short or sparse sampling.
static int picture_state(const Scan *scan, const AVFrame *frame, bool *damaged)
{
    *damaged = frame->best_effort_timestamp == AV_NOPTS_VALUE || frame->decode_error_flags ||
        (frame->flags & AV_FRAME_FLAG_CORRUPT);
    const AVFrameSideData *display = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
    if (!*damaged && display &&
        (display->size != sizeof(scan->picture_display_matrix) ||
         memcmp(display->data, scan->picture_display_matrix, 6 * sizeof(int32_t)) ||
         memcmp(display->data + 8 * sizeof(int32_t), scan->picture_display_matrix + 8, sizeof(int32_t)))) {
        return MP_PARTICIPANT_UNSUPPORTED_DISPLAY_TRANSFORM;
    }
    return 0;
}

// Convert a decoded picture to RGB24 in scan->rgb_frame.
static int render_picture(Scan *scan, const AVFrame *frame)
{
    const enum AVColorSpace color_space = frame->colorspace;
    const enum AVColorRange color_range = frame->color_range;
    AVFrame *mapped = NULL;
    int ret = 0;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (!(mapped = av_frame_alloc())) return AVERROR(ENOMEM);
        ret = av_hwframe_map(mapped, frame, AV_HWFRAME_MAP_READ);
        if (ret < 0) {
            av_frame_unref(mapped);
            if ((ret = av_hwframe_transfer_data(mapped, frame, 0)) < 0) goto done;
        }
        frame = mapped;
    }
    AVFrame *rgb = scan->rgb_frame;
    if (rgb->width != frame->width || rgb->height != frame->height) {
        av_frame_unref(rgb);
        rgb->format = AV_PIX_FMT_RGB24;
        rgb->width = frame->width;
        rgb->height = frame->height;
        if ((ret = av_frame_get_buffer(rgb, 32)) < 0) goto done;
    }
    const uint8_t *planes[4] = { frame->data[0], frame->data[1], frame->data[2], frame->data[3] };
    int strides[4] = { frame->linesize[0], frame->linesize[1], frame->linesize[2], frame->linesize[3] };
    int source_format = frame->format;
    if (scan->pack_nv12 && (source_format == AV_PIX_FMT_YUV420P || source_format == AV_PIX_FMT_YUVJ420P)) {
        const int columns = (frame->width + 1) / 2, rows = (frame->height + 1) / 2;
        const int stride = FFALIGN(2 * columns, 64);
        av_fast_malloc(&scan->chroma, &scan->chroma_size, (size_t)stride * rows + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!scan->chroma) { ret = AVERROR(ENOMEM); goto done; }
        for (int y = 0; y < rows; y++)
            interleave_chroma(scan->chroma + (size_t)y * stride, frame->data[1] + (ptrdiff_t)y * frame->linesize[1],
                              frame->data[2] + (ptrdiff_t)y * frame->linesize[2], columns);
        planes[1] = scan->chroma;
        strides[1] = stride;
        planes[2] = NULL;
        strides[2] = 0;
        source_format = AV_PIX_FMT_NV12;
    }
    if (!scan->rgb_scale || scan->rgb_source_width != frame->width ||
        scan->rgb_source_height != frame->height || scan->rgb_source_format != source_format ||
        scan->rgb_source_space != color_space || scan->rgb_source_range != color_range) {
        if (color_range == AVCOL_RANGE_UNSPECIFIED && scan->rgb_source_range != color_range) {
            // Recover the format default if the preceding frame declared an override.
            sws_freeContext(scan->rgb_scale);
            scan->rgb_scale = NULL;
        }
        scan->rgb_scale = sws_getCachedContext(scan->rgb_scale, frame->width, frame->height, source_format,
                                               rgb->width, rgb->height, rgb->format, SWS_BILINEAR,
                                               NULL, NULL, NULL);
        if (!scan->rgb_scale) { ret = AVERROR(ENOMEM); goto done; }
        int *input, *output, in_range, out_range, brightness, contrast, saturation;
        if (sws_getColorspaceDetails(scan->rgb_scale, &input, &in_range, &output, &out_range,
                                     &brightness, &contrast, &saturation) >= 0) {
            if (color_range != AVCOL_RANGE_UNSPECIFIED) in_range = color_range == AVCOL_RANGE_JPEG;
            const int *matrix = sws_getCoefficients(rgb_matrix(color_space));
            ret = sws_setColorspaceDetails(scan->rgb_scale, matrix, in_range, matrix, 1,
                                           brightness, contrast, saturation);
            if (ret < 0) goto done;
        }
        scan->rgb_source_width = frame->width;
        scan->rgb_source_height = frame->height;
        scan->rgb_source_format = source_format;
        scan->rgb_source_space = color_space;
        scan->rgb_source_range = color_range;
    }
    ret = sws_scale(scan->rgb_scale, planes, strides, 0, frame->height, rgb->data, rgb->linesize);
    if (ret != rgb->height) { ret = AVERROR_INVALIDDATA; goto done; }
    ret = 0;
done:
    av_frame_free(&mapped);
    return ret;
}

static int visit_picture(Scan *scan, AVFrame *frame)
{
    const int64_t pts = frame->best_effort_timestamp;
    const int64_t duration = frame->duration;
    const AVRational sar = av_guess_sample_aspect_ratio(scan->picture_format, scan->picture_stream, frame);
    scan->pictures++;
    bool damaged;
    int ret = picture_state(scan, frame, &damaged);
    if (ret != 0) return ret;
    if (scan->select_picture) {
        int selection = scan->select_picture(scan->context, pts, duration, damaged);
        if (selection < 0) return AVERROR_EXIT;
        if (!selection || damaged) return 0;
    } else if (damaged) {
        return scan->picture(scan->context, pts, duration, NULL, frame->width, frame->height,
                             0, sar.num, sar.den) ? AVERROR_EXIT : 0;
    }
    if ((ret = render_picture(scan, frame)) < 0) return ret;
    const AVFrame *rgb = scan->rgb_frame;
    return scan->picture(scan->context, pts, duration, rgb->data[0], rgb->width, rgb->height,
                         rgb->linesize[0], sar.num, sar.den) ? AVERROR_EXIT : 0;
}

static int consume(Scan *scan, AVFrame *frame)
{
    if (scan->cancelled(scan->context)) return AVERROR_EXIT;
    if (scan->picture) {
        int ret = visit_picture(scan, frame);
        if (ret != 0 || !scan->visit) return ret;
    }
    // A picture without a timestamp cannot start a scene. Compare its neighbors instead.
    if (frame->best_effort_timestamp == AV_NOPTS_VALUE) return 0;
    const bool damaged = frame->decode_error_flags || (frame->flags & AV_FRAME_FLAG_CORRUPT);
    const bool initial_range_seek = scan->saved.initial_seek != AV_NOPTS_VALUE &&
        (scan->restoring ? scan->replay_anchor == &scan->saved.initial && !scan->replay_count
                         : !scan->count);
    if (scan->checkpoint && initial_range_seek && damaged) return 0;
    ScenePicture replay_picture;
    ScenePicture *now = scan->restoring ? &replay_picture : &scan->frames[scan->count % 3];
    now->pts = frame->best_effort_timestamp;
    int ret = sample(scan, frame, now);
    if (ret < 0) return ret;
    if (!scan->checkpoint) return advance(scan, now);
    ScenePacket packet = { .position = -1, .dts = AV_NOPTS_VALUE };
    if (frame->opaque_ref && frame->opaque_ref->size == sizeof(packet))
        memcpy(&packet, frame->opaque_ref->data, sizeof(packet));
    uint8_t digest[DIGEST_SIZE];
    picture_digest(scan, now, frame, packet.position, digest);
    if (scan->restoring) return reconcile(scan, now, digest);

    SceneCheckpoint *state = &scan->saved;
    if (!scan->count) {
        // If a seek landed on the far side of the requested trim, find its
        // leading scene from the verified source start instead.
        if (state->initial_seek != AV_NOPTS_VALUE && now->pts >= state->start_pts)
            return SCAN_RETRY_FROM_START;
        begin_anchor(&state->initial, now->pts, state->initial_seek, 1, digest);
    }
    if (scan->count && now->pts < scan->frames[(scan->count-1)%3].pts)
        return AVERROR_INVALIDDATA;
    // Only a seekable coded keyframe with a stable packet position can anchor
    // replay. Retain the preceding anchor to preroll through open GOPs.
    if (!damaged && (frame->flags & AV_FRAME_FLAG_KEY) && packet.independent) {
        state->previous = state->latest;
        int64_t seek = packet.dts == AV_NOPTS_VALUE ? now->pts : FFMIN(packet.dts, now->pts);
        begin_anchor(&state->latest, now->pts, seek, scan->count + 1, digest);
    }
    if (!state->previous.ordinal) extend_anchor(scan, &state->initial, digest);
    else extend_anchor(scan, &state->previous, digest);
    if (state->latest.ordinal) extend_anchor(scan, &state->latest, digest);

    const bool range_started = state->started;
    advance(scan, now);
    if (scan->count >= 2) state->confirmed = scan->frames[(scan->count-2)%3].pts;
    if (state->has_range && now->pts >= state->start_pts) start_range(scan);
    if (state->has_range && now->pts >= state->end_pts) {
        state->confirmed = state->end_pts;
        state->finished = 1;
        return SCAN_RANGE_END;
    }
    if ((!range_started && state->started) || scan->count == 1 || scan->count % 32 == 0)
        checkpoint(scan);
    return 0;
}

static int consume_surface(void *context, CVPixelBufferRef surface, int64_t pts)
{
    Scan *scan = context;
    if (scan->cancelled(scan->context)) return AVERROR_EXIT;
    if (pts == AV_NOPTS_VALUE) return AVERROR_INVALIDDATA;
    ScenePicture *now = &scan->frames[scan->count % 3];
    now->pts = pts;
    if (!sample_surface(scan, surface, now)) return AVERROR(ENOSYS);
    return advance(scan, now);
}

static int asset_cancelled(void *context)
{
    Scan *scan = context;
    return scan->cancelled(scan->context);
}

static enum AVPixelFormat choose_format(AVCodecContext *ctx, const enum AVPixelFormat *available)
{
    for (const enum AVPixelFormat *p = available; *p != AV_PIX_FMT_NONE; ++p)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return avcodec_default_get_format(ctx, available);
}

// FFV1 v3+ ends every slice with its 24-bit payload length and an optional
// five-byte error-checking field. Count only chains covering the entire packet.
static int ffv1_slice_count(const AVPacket *packet, int trailer)
{
    int remaining = packet->size;
    int count = 0;
    while (remaining > trailer && count < 1024) {
        int size = AV_RB24(packet->data + remaining - trailer);
        if (size == 0 || size > remaining - trailer) return 0;
        remaining -= size + trailer;
        count++;
    }
    return remaining == 0 ? count : 0;
}

static void configure_decoder(AVCodecContext *codec, const AVCodec *decoder, const AVPacket *first, bool software)
{
    codec->thread_count = 2;
    if (codec->codec_id == AV_CODEC_ID_FFV1 && codec->extradata_size && first) {
        int plain = ffv1_slice_count(first, 3);
        int checked = ffv1_slice_count(first, 8);
        int slices = FFMAX(plain, checked);
        // Ambiguous, single-slice and legacy streams keep frame workers.
        if ((!plain || !checked) && slices >= 4) {
            codec->thread_type = FF_THREAD_SLICE;
            codec->thread_count = FFMIN(av_cpu_count(), FFMIN(8, slices));
        }
    } else if (codec->codec_id == AV_CODEC_ID_VP9 &&
        (codec->profile == AV_PROFILE_VP9_1 || codec->profile == AV_PROFILE_VP9_3)) {
        // Non-4:2:0 VP9 often decodes in software. Frame workers also help on
        // untiled streams. Bound the extra two picture buffers to 16 MiB.
        int bytes = av_image_get_buffer_size(codec->pix_fmt, codec->width, codec->height, 32);
        if (bytes > 0 && bytes <= 8 * 1024 * 1024)
            codec->thread_count = FFMIN(av_cpu_count(), 4);
    }
    for (int i = 0; !software; ++i) {
        const AVCodecHWConfig *hw = avcodec_get_hw_config(decoder, i);
        if (!hw) break;
        if (hw->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
            av_hwdevice_ctx_create(&codec->hw_device_ctx, hw->device_type, NULL, NULL, 0) >= 0) {
            codec->get_format = choose_format;
            break;
        }
    }
}

static int open_decoder(AVCodecContext *codec, const AVCodec *decoder, const AVPacket *first, bool software)
{
    configure_decoder(codec, decoder, first, software);
    return avcodec_open2(codec, decoder, NULL);
}

// A software decoder reports a packet it cannot read as invalid data.
// VideoToolbox reports the same damage as an unknown or external error. A hardware session
// that keeps failing is a decoder fault, which must not pass as a complete scan.
static bool damaged_picture(const AVCodecContext *codec, int ret, int *hardware_failures)
{
    if (ret == AVERROR_INVALIDDATA) return true;
    if ((ret != AVERROR_UNKNOWN && ret != AVERROR_EXTERNAL) || !codec->hw_device_ctx) return false;
    return ++*hardware_failures <= 512;
}

static int prepare_checkpoint(Scan *scan, AVFormatContext *format, int index, bool seek_range, bool software)
{
    const AVStream *stream = format->streams[index];
    const MPSceneScanOptions *options = scan->options;
    SceneCheckpoint *state = &scan->saved;
    if (stream->time_base.num <= 0 || stream->time_base.den <= 0) return AVERROR_INVALIDDATA;
    *state = (SceneCheckpoint){
        .version = CHECKPOINT_VERSION, .stream = index,
        .tb_num = stream->time_base.num, .tb_den = stream->time_base.den,
        .decoder_version = avcodec_version(), .scaler_version = swscale_version(),
        .has_range = !!options->has_range, .start_pts = options->start_pts, .end_pts = options->end_pts,
        .initial_seek = AV_NOPTS_VALUE, .confirmed = AV_NOPTS_VALUE, .software = software
    };
    int64_t seek = AV_NOPTS_VALUE;
    if (options->resume_size) {
        SceneCheckpoint restored;
        if (!options->resume || options->resume_size != sizeof(restored)) return MP_SCENE_RESUME_MISMATCH;
        memcpy(&restored, options->resume, sizeof(restored));
        if (restored.version != state->version || restored.stream != state->stream ||
            restored.tb_num != state->tb_num || restored.tb_den != state->tb_den ||
            restored.decoder_version != state->decoder_version || restored.scaler_version != state->scaler_version ||
            restored.has_range != state->has_range || restored.start_pts != state->start_pts ||
            restored.end_pts != state->end_pts || restored.count <= 0 || restored.count == INT64_MAX ||
            restored.initial.ordinal != 1 || restored.previous.ordinal < 0 ||
            restored.latest.ordinal < restored.previous.ordinal || restored.latest.ordinal > restored.count ||
            (restored.software != 0 && restored.software != 1) ||
            !isfinite(restored.motion) || !isfinite(restored.pending) || !isfinite(restored.last_delta) ||
            restored.pending < 0 || (restored.pending > 0 && restored.count < 2))
            return MP_SCENE_RESUME_MISMATCH;
        *state = restored;
        scan->count = state->count;
        scan->motion = state->motion;
        scan->pending = state->pending;
        scan->last_delta = state->last_delta;
        memcpy(scan->frames, state->frames, sizeof(scan->frames));
        scan->restoring = true;
        scan->replay_anchor = state->previous.ordinal ? &state->previous : &state->initial;
        seek = scan->replay_anchor->seek;
    } else if (options->has_range && seek_range) {
        // One second of detector history after the requested seek point. The
        // demuxer seeks to a keyframe at or before that point.
        int64_t warmup = av_rescale_q(1, (AVRational){1, 1}, stream->time_base);
        if (options->start_pts > INT64_MIN + warmup) {
            seek = options->start_pts - warmup;
            if (stream->start_time != AV_NOPTS_VALUE && seek <= stream->start_time)
                seek = AV_NOPTS_VALUE;
        }
        state->initial_seek = seek;
    }
    if (seek != AV_NOPTS_VALUE && av_seek_frame(format, index, seek, AVSEEK_FLAG_BACKWARD) < 0)
        return scan->restoring ? MP_SCENE_RESUME_MISMATCH : SCAN_RETRY_FROM_START;
    return 0;
}

static int scan_video(const char *path, int index, int allow_asset_reader,
                      MPProbeCancelled cancelled, MPSceneVisit visit, void *context,
                      MPSceneTiming *timing, const MPSceneScanOptions *options,
                      MPSceneCheckpointVisit progress, bool seek_range, bool software,
                      MPParticipantFrameSelect select_picture, MPParticipantFrameVisit picture, int *unplaced_damage,
                      char *error, size_t capacity)
{
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *codec = NULL;
    AVBufferPool *packet_metadata = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    Scan scan = { .visit = visit, .cancelled = cancelled, .context = context,
                  .options = options, .checkpoint = progress, .select_picture = select_picture, .picture = picture };
    int64_t first_pts = INT64_MAX, last_pts = INT64_MIN, packet_end = INT64_MIN;
    bool complete_clock = true;
    int hardware_failures = 0;
    int ret = AVERROR(ENOMEM);
    if (timing) *timing = (MPSceneTiming){0};
    if (!format || !packet || !frame) goto done;
    if (picture && !(scan.rgb_frame = av_frame_alloc())) goto done;
    format->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if ((ret = avformat_open_input(&format, path, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(format, NULL)) < 0) goto done;
    if (index < 0 || index >= format->nb_streams) { ret = AVERROR_STREAM_NOT_FOUND; goto done; }
    AVStream *stream = format->streams[index];
    if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) { ret = AVERROR_STREAM_NOT_FOUND; goto done; }
    if (picture) {
        scan.picture_format = format;
        scan.picture_stream = stream;
        const AVPacketSideData *display = av_packet_side_data_get(stream->codecpar->coded_side_data,
            stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        const int32_t identity[9] = { 1 << 16, 0, 0, 0, 1 << 16, 0, 0, 0, 1 << 30 };
        memcpy(scan.picture_display_matrix, display && display->size == sizeof(identity) ? display->data :
               (const uint8_t *)identity, sizeof(identity));
    }
    if (allow_asset_reader && av_match_name("mov", format->iformat->name)) {
        int result = mp_scene_read_asset(path, stream, consume_surface, asset_cancelled, &scan);
        if (result < 0 || cancelled(context)) { ret = AVERROR_EXIT; goto done; }
        if (result > 0) {
            if (scan.pending > 0) emit(&scan, &scan.frames[(scan.count-1)%3]);
            if (timing) *timing = (MPSceneTiming){
                .valid = 1, .tb_num = 1, .tb_den = stream->time_base.den,
                .first_pts = 0, .origin = 0, .end = stream->duration
            };
            ret = 0;
            goto done;
        }
        // Discard speculative markers if a later frame disproved the header clock.
        // The FFmpeg demuxer has not advanced during the independent asset read.
        if (scan.count) {
            visit(context, AV_NOPTS_VALUE, NULL);
            scan = (Scan){ .visit = visit, .cancelled = cancelled, .context = context };
        }
    }
    for (unsigned i = 0; i < format->nb_streams; i++)
        if (i != (unsigned)index) format->streams[i]->discard = AVDISCARD_ALL;
    if (options && (ret = prepare_checkpoint(&scan, format, index, seek_range, software)) != 0) goto done;
    const int64_t declared_duration = stream->duration;
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) { ret = AVERROR_DECODER_NOT_FOUND; goto done; }
    if (!(codec = avcodec_alloc_context3(decoder))) { ret = AVERROR(ENOMEM); goto done; }
    if ((ret = avcodec_parameters_to_context(codec, stream->codecpar)) < 0) goto done;
    codec->pkt_timebase = stream->time_base;
    if (options) codec->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    while (!cancelled(context)) {
        ret = av_read_frame(format, packet);
        bool eof = ret == AVERROR_EOF;
        if (ret < 0 && !eof) goto done;
        if (!eof && packet->stream_index != index) { av_packet_unref(packet); continue; }
        ScenePacket identity = {0};
        if (options && !eof) {
            identity.position = packet->pos;
            identity.dts = packet->dts;
            identity.independent = !!(packet->flags & AV_PKT_FLAG_KEY);
            if (codec->codec_id == AV_CODEC_ID_H264 || codec->codec_id == AV_CODEC_ID_HEVC) {
                int multilayer = 0;
                identity.independent = identity.independent &&
                    mp_h26x_random_access(packet, stream->codecpar, false, &multilayer) && !multilayer;
                // VideoToolbox may reject an entire open GOP when its first
                // reference pictures precede the demuxer's nominal keyframe.
                if (!identity.independent && !scan.restoring && !scan.count && !software &&
                    scan.saved.initial_seek != AV_NOPTS_VALUE && !avcodec_is_open(codec)) {
                    ret = SCAN_RETRY_SOFTWARE;
                    goto done;
                }
            }
            identity.independent = identity.independent && packet->pos >= 0;
        }
        if (!avcodec_is_open(codec) && (ret = open_decoder(codec, decoder, eof ? NULL : packet,
                                                          scan.saved.software)) < 0)
            goto done;
        if (timing && !eof) {
            if (packet->pts == AV_NOPTS_VALUE || packet->duration <= 0 ||
                packet->pts > INT64_MAX - packet->duration) {
                complete_clock = false;
            } else {
                first_pts = FFMIN(first_pts, packet->pts);
                last_pts = FFMAX(last_pts, packet->pts);
                packet_end = FFMAX(packet_end, packet->pts + packet->duration);
            }
        }
        if (options && !eof && packet->pos >= 0) {
            if (!packet_metadata && !(packet_metadata = av_buffer_pool_init(sizeof(identity), NULL))) {
                ret = AVERROR(ENOMEM);
                goto done;
            }
            av_buffer_unref(&packet->opaque_ref);
            // The decoder can retain metadata across reordered pictures. The pool
            // reuses a block after the last packet or frame reference releases it.
            packet->opaque_ref = av_buffer_pool_get(packet_metadata);
            if (!packet->opaque_ref) { ret = AVERROR(ENOMEM); goto done; }
            memcpy(packet->opaque_ref->data, &identity, sizeof(identity));
        }
        ret = avcodec_send_packet(codec, eof ? NULL : packet);
        av_packet_unref(packet);
        // One damaged packet must not discard the rest of the recording.
        // The scan still fails below when no picture decodes at all.
        if (!eof && damaged_picture(codec, ret, &hardware_failures)) {
            if (unplaced_damage) *unplaced_damage = 1;
            ret = 0;
        }
        if (ret < 0) goto done;
        int failures = 0;
        for (;;) {
            ret = avcodec_receive_frame(codec, frame);
            if (failures < 64 && damaged_picture(codec, ret, &hardware_failures)) {
                if (unplaced_damage) *unplaced_damage = 1;
                failures++;
                continue;
            }
            if (ret < 0) break;
            failures = 0;
            hardware_failures = 0;
            ret = consume(&scan, frame);
            av_frame_unref(frame);
            if (ret != 0) goto done;
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) goto done;
        if (eof) {
            if (cancelled(context)) { ret = AVERROR_EXIT; goto done; }
            if (scan.restoring) { ret = MP_SCENE_RESUME_MISMATCH; goto done; }
            if (scan.pending > 0) emit(&scan, &scan.frames[(scan.count-1)%3]);
            if (options && scan.count) {
                if (scan.saved.has_range) start_range(&scan);
                scan.pending = 0;
                scan.saved.finished = 1;
                scan.saved.confirmed = scan.saved.has_range ? scan.saved.end_pts
                    : scan.frames[(scan.count-1)%3].pts;
            }
            if (timing && complete_clock && first_pts <= last_pts) {
                int64_t origin = stream->start_time == AV_NOPTS_VALUE ? first_pts : stream->start_time;
                *timing = (MPSceneTiming){
                    .valid = 1, .tb_num = stream->time_base.num, .tb_den = stream->time_base.den,
                    .first_pts = first_pts, .origin = origin,
                    .end = mp_video_presentation_end(format->iformat->name, stream, declared_duration,
                                                     origin, last_pts, packet_end)
                };
            }
            ret = scan.count || scan.pictures ? 0 : AVERROR_INVALIDDATA;
            goto done;
        }
    }
    ret = AVERROR_EXIT;
done:
    if (ret == SCAN_RANGE_END) ret = 0;
    if (options && (ret == 0 || ret == AVERROR_EXIT || cancelled(context))) {
        checkpoint(&scan);
        if (ret != 0) ret = AVERROR_EXIT;
    } else if (scan.restoring && ret < 0) {
        ret = MP_SCENE_RESUME_MISMATCH;
    } else if (scan.saved.has_range && !scan.restoring && !scan.count &&
               scan.saved.initial_seek != AV_NOPTS_VALUE &&
               (ret == SCAN_RETRY_FROM_START || ret == AVERROR_INVALIDDATA ||
                ret == AVERROR_EXTERNAL || ret == AVERROR_UNKNOWN)) {
        ret = !software && codec && codec->hw_device_ctx ? SCAN_RETRY_SOFTWARE : SCAN_RETRY_FROM_START;
    }
    if (ret < 0) av_strerror(ret, error, capacity);
    sws_freeContext(scan.scale);
    sws_freeContext(scan.rgb_scale);
    av_frame_free(&scan.rgb_frame);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    av_buffer_pool_uninit(&packet_metadata);
    avformat_close_input(&format);
    return ret;
}

int mp_scene_scan(const char *path, int index, int allow_asset_reader,
                  MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, MPSceneTiming *timing, char *error, size_t capacity)
{
    return scan_video(path, index, allow_asset_reader, cancelled, visit, context, timing,
                      NULL, NULL, false, false, NULL, NULL, NULL, error, capacity);
}

int mp_scene_scan_resumable(const char *path, int index, const MPSceneScanOptions *options,
                            MPProbeCancelled cancelled, MPSceneVisit visit,
                            MPSceneCheckpointVisit progress, void *context, char *error, size_t capacity)
{
    if (!options || !cancelled || !visit || !progress ||
        (options->has_range && options->start_pts > options->end_pts)) {
        av_strerror(AVERROR(EINVAL), error, capacity);
        return AVERROR(EINVAL);
    }
    int ret = scan_video(path, index, 0, cancelled, visit, context, NULL,
                         options, progress, true, false, NULL, NULL, NULL, error, capacity);
    if (ret == SCAN_RETRY_SOFTWARE)
        ret = scan_video(path, index, 0, cancelled, visit, context, NULL,
                         options, progress, true, true, NULL, NULL, NULL, error, capacity);
    if (ret == SCAN_RETRY_FROM_START)
        ret = scan_video(path, index, 0, cancelled, visit, context, NULL,
                         options, progress, false, false, NULL, NULL, NULL, error, capacity);
    return ret == AVERROR_EXIT ? MP_SCENE_SCAN_CANCELLED : ret;
}

int mp_participant_scan(const char *path, int stream, MPProbeCancelled cancelled,
                        MPParticipantFrameSelect select_frame, MPParticipantFrameVisit frame,
                        MPSceneVisit scene, void *context,
                        int *unplaced_damage, char *error, size_t capacity)
{
    if (!path || !cancelled || !frame) {
        av_strerror(AVERROR(EINVAL), error, capacity);
        return AVERROR(EINVAL);
    }
    if (unplaced_damage) *unplaced_damage = 0;
    int ret = scan_video(path, stream, 0, cancelled, scene, context, NULL,
                         NULL, NULL, false, false, select_frame, frame, unplaced_damage, error, capacity);
    return ret == AVERROR_EXIT ? MP_SCENE_SCAN_CANCELLED : ret;
}

// Adaptive participant scan. Spans run from one delivered random access
// picture to the next. The packets of a span stay buffered until its closing
// picture has been offered to the coarse visit, so a refusal can decode them
// without seeking. Closing pictures decode ahead of the offers on their own
// decoder, several at a time, while closed spans wait in a queue.
enum { SPAN_PACKETS = 1024, SPAN_BYTES = 48 << 20, SPAN_SHORTEST_SECONDS = 1, SPAN_LONGEST_SECONDS = 3,
       SPAN_QUEUE = 24, SPAN_QUEUE_BYTES = 96 << 20, SOFTWARE_PIXELS = 1920 * 1088, SOFTWARE_THREADS = 8, KEY_THREADS = 12,
       BATCH = 32, WORKERS = 6, WORKER_BYTES = 160 << 20 };

// A decoded picture reduced to the pixels the analyzer measures.
typedef struct {
    int64_t pts, duration;
    AVRational sar;
    int width, height, status;
    bool damaged;
    uint8_t *rgb;
    unsigned capacity;
    // The caller's analysis of the pixels, until a visit takes it.
    void *prepared;
} Sample;

typedef struct {
    AVPacket **packets;
    int count;
    int64_t bytes;
    // The closing packet went to the key decoder.
    bool offered;
    // Its picture arrived and was reduced, or will not arrive.
    bool sampled, missing;
    AVFrame *picture;
    Sample sample;
} Span;

// Check a decoded picture and convert it. With a limit, keep the grid of
// point samples TileTrail would read from the full picture: the longer side
// becomes the limit and sample i of n reads source pixel (2i + 1) * size / 2n.
static void reduce_picture(Scan *worker, const AVFrame *frame, int limit, Sample *out)
{
    out->pts = frame->best_effort_timestamp;
    out->duration = frame->duration;
    out->sar = av_guess_sample_aspect_ratio(worker->picture_format, worker->picture_stream, (AVFrame *)frame);
    out->width = frame->width;
    out->height = frame->height;
    out->status = picture_state(worker, frame, &out->damaged);
    if (out->status != 0 || out->damaged || (out->status = render_picture(worker, frame)) < 0) return;
    const AVFrame *rgb = worker->rgb_frame;
    const int longest = FFMAX(rgb->width, rgb->height);
    int width = rgb->width, height = rgb->height;
    if (limit > 0 && longest > limit) {
        width = FFMAX(1, (int)(((int64_t)rgb->width * limit + longest / 2) / longest));
        height = FFMAX(1, (int)(((int64_t)rgb->height * limit + longest / 2) / longest));
    }
    av_fast_malloc(&out->rgb, &out->capacity, (size_t)width * height * 3 + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!out->rgb) {
        out->status = AVERROR(ENOMEM);
        return;
    }
    for (int y = 0; y < height; y++) {
        const int64_t source_y = ((2 * (int64_t)y + 1) * rgb->height) / (2 * (int64_t)height);
        const uint8_t *row = rgb->data[0] + source_y * rgb->linesize[0];
        uint8_t *target = out->rgb + (size_t)y * width * 3;
        if (width == rgb->width) {
            memcpy(target, row, (size_t)width * 3);
            continue;
        }
        for (int x = 0; x < width; x++)
            memcpy(target + 3 * x, row + 3 * (((2 * (int64_t)x + 1) * rgb->width) / (2 * (int64_t)width)), 3);
    }
    out->width = width;
    out->height = height;
}

typedef struct {
    Scan scan;
    MPParticipantSampleVisit visit, offer;
    MPParticipantPrepare prepare;
    MPParticipantDiscard discard;
    AVStream *stream;
    const AVCodec *decoder;
    AVCodecContext *dense, *key;
    AVFrame *frame, *held;
    AVPacket *packets[SPAN_PACKETS];
    int count;
    int64_t bytes;
    Span queue[SPAN_QUEUE];
    int queued;
    // The first queued span that may still receive its key picture.
    int next_key;
    int64_t queued_bytes;
    // Decoded pictures wait here to be converted side by side, then reach the
    // frame visit in order.
    AVFrame *batch[BATCH];
    Sample samples[BATCH];
    int batched, batch_limit, sample_limit;
    // Let this many spans queue before settling, so their closing pictures
    // arrive in groups the workers can convert together.
    int backlog;
    Scan *workers;
    int worker_count;
    // Pass packets straight to the dense decoder until the next boundary.
    bool streaming;
    // The first replayed picture can repeat the previously delivered boundary.
    bool skipping;
    int64_t delivered;
    // Random access packets end a span only when none of the pictures after
    // them can be presented before them.
    bool boundaries, intra_only;
    // The key decoder reached end of stream and must be reset before reuse.
    bool key_drained;
    // held carries a key picture that no queued span has claimed yet.
    bool has_held;
    // Frame-threaded software decoding outruns the hardware decoder on small
    // H.264 pictures and lets independent key pictures decode side by side.
    bool software;
    int hardware_failures;
    int *unplaced_damage;
} Adaptive;

// Key pictures are independent, so their decoder scales with every core.
// Pictures that refer to each other gain little beyond a few threads.
static int software_threads(bool key)
{
    const int cores = av_cpu_count();
    return key ? FFMAX(2, FFMIN(cores - 2, KEY_THREADS)) : FFMAX(2, FFMIN(cores, SOFTWARE_THREADS));
}

static int adaptive_decoder(Adaptive *a, AVCodecContext **codec, const AVPacket *first)
{
    const bool key = codec == &a->key;
    if (*codec) {
        if (!key || a->key_drained) avcodec_flush_buffers(*codec);
        a->key_drained = a->key_drained && !key;
        return 0;
    }
    if (!(*codec = avcodec_alloc_context3(a->decoder))) return AVERROR(ENOMEM);
    int ret = avcodec_parameters_to_context(*codec, a->stream->codecpar);
    if (ret >= 0) {
        (*codec)->pkt_timebase = a->stream->time_base;
        if (a->software) {
            (*codec)->thread_count = software_threads(key);
            (*codec)->thread_type = FF_THREAD_FRAME;
        } else {
            configure_decoder(*codec, a->decoder, first, false);
            if (key) {
                // Each packet is one independent picture. Return it without
                // waiting for a successor or a second worker.
                (*codec)->thread_count = 1;
                (*codec)->flags |= AV_CODEC_FLAG_LOW_DELAY;
            }
        }
        ret = avcodec_open2(*codec, a->decoder, NULL);
    }
    if (ret < 0) avcodec_free_context(codec);
    return ret;
}

static bool span_reaches(const Adaptive *a, const AVPacket *first, const AVPacket *last, int seconds, bool beyond)
{
    AVRational base = a->stream->time_base;
    if (base.num <= 0 || base.den <= 0 || last->pts <= first->pts) return false;
    uint64_t ticks = (uint64_t)last->pts - (uint64_t)first->pts;
    uint64_t limit = (uint64_t)seconds * base.den;
    return beyond ? ticks > limit / base.num : ticks >= (limit + base.num - 1) / base.num;
}

static void sample_discard(const Adaptive *a, Sample *sample)
{
    if (sample->prepared) a->discard(a->scan.context, sample->prepared);
    sample->prepared = NULL;
}

// Reduce one picture and let the caller analyze its pixels on this worker.
static void adaptive_reduce_one(const Adaptive *a, Scan *worker, const AVFrame *picture, Sample *sample)
{
    reduce_picture(worker, picture, a->sample_limit, sample);
    if (a->prepare && sample->status == 0 && !sample->damaged)
        sample->prepared = a->prepare(a->scan.context, sample->pts, sample->rgb, sample->width, sample->height,
                                      sample->width * 3, sample->sar.num, sample->sar.den);
}

// Convert pictures on the workers. Each worker owns one converter.
static void adaptive_reduce(Adaptive *a, AVFrame *const *pictures, Sample *const *samples, int count)
{
    const int workers = FFMIN(a->worker_count, count);
    const Adaptive *const state = a;
    Scan *const scans = a->workers;
    if (workers <= 1) {
        for (int i = 0; i < count; i++) adaptive_reduce_one(state, &scans[0], pictures[i], samples[i]);
        return;
    }
    dispatch_apply((size_t)workers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
        for (int i = (int)worker; i < count; i += workers)
            adaptive_reduce_one(state, &scans[worker], pictures[i], samples[i]);
    });
}

// Present the waiting pictures to the frame visit in order.
static int adaptive_flush(Adaptive *a)
{
    const int count = a->batched;
    if (!count) return 0;
    a->batched = 0;
    Sample *samples[BATCH];
    for (int i = 0; i < count; i++) samples[i] = &a->samples[i];
    adaptive_reduce(a, a->batch, samples, count);
    int ret = 0;
    for (int i = 0; i < count; i++) {
        Sample *sample = samples[i];
        av_frame_unref(a->batch[i]);
        if (ret == 0 && a->scan.cancelled(a->scan.context)) ret = AVERROR_EXIT;
        if (ret == 0) {
            a->scan.pictures++;
            ret = sample->status;
        }
        if (ret != 0) {
            sample_discard(a, sample);
            continue;
        }
        const bool pixels = !sample->damaged;
        void *prepared = sample->prepared;
        sample->prepared = NULL;
        ret = a->visit(a->scan.context, sample->pts, sample->duration, pixels ? sample->rgb : NULL,
                       sample->width, sample->height, pixels ? sample->width * 3 : 0,
                       sample->sar.num, sample->sar.den, prepared) ? AVERROR_EXIT : 0;
    }
    return ret;
}

static int adaptive_deliver(Adaptive *a, AVFrame *frame)
{
    if (a->scan.cancelled(a->scan.context)) return AVERROR_EXIT;
    const int64_t pts = frame->best_effort_timestamp;
    if (a->skipping) {
        a->skipping = false;
        if (pts != AV_NOPTS_VALUE && pts == a->delivered) return 0;
    }
    if (pts != AV_NOPTS_VALUE) a->delivered = pts;
    av_frame_move_ref(a->batch[a->batched++], frame);
    return a->batched >= a->batch_limit ? adaptive_flush(a) : 0;
}

// Send one packet, or drain with a null packet, and deliver what comes out.
static int adaptive_pump(Adaptive *a, const AVPacket *packet)
{
    if (a->scan.cancelled(a->scan.context)) return AVERROR_EXIT;
    int ret = avcodec_send_packet(a->dense, packet);
    if (packet && damaged_picture(a->dense, ret, &a->hardware_failures)) {
        if (a->unplaced_damage) *a->unplaced_damage = 1;
        ret = 0;
    }
    if (ret < 0 && ret != AVERROR_EOF) return ret;
    int failures = 0;
    for (;;) {
        ret = avcodec_receive_frame(a->dense, a->frame);
        if (failures < 64 && damaged_picture(a->dense, ret, &a->hardware_failures)) {
            if (a->unplaced_damage) *a->unplaced_damage = 1;
            failures++;
            continue;
        }
        if (ret < 0) break;
        failures = 0;
        a->hardware_failures = 0;
        ret = adaptive_deliver(a, a->frame);
        av_frame_unref(a->frame);
        if (ret != 0) return ret;
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static void adaptive_clear(Adaptive *a)
{
    for (int i = 0; i < a->count; i++) av_packet_free(&a->packets[i]);
    a->count = 0;
    a->bytes = 0;
}

static void span_free(const Adaptive *a, Span *span)
{
    for (int i = 0; i < span->count; i++) av_packet_free(&span->packets[i]);
    av_freep(&span->packets);
    av_frame_free(&span->picture);
    sample_discard(a, &span->sample);
    av_free(span->sample.rgb);
    *span = (Span){0};
}

// Decode packets from their random access picture. The first picture was
// delivered when the preceding span closed.
static int adaptive_decode(Adaptive *a, AVPacket *const *packets, int count, bool drain)
{
    int ret = adaptive_decoder(a, &a->dense, count ? packets[0] : NULL);
    if (ret < 0) return ret;
    a->skipping = a->delivered != AV_NOPTS_VALUE;
    for (int i = 0; i < count; i++)
        if ((ret = adaptive_pump(a, packets[i])) != 0) return ret;
    if (!drain) return 0;
    if ((ret = adaptive_pump(a, NULL)) != 0) return ret;
    return adaptive_flush(a);
}

static bool adaptive_boundary(const Adaptive *a, const AVPacket *packet)
{
    if (!a->boundaries || !(packet->flags & AV_PKT_FLAG_KEY) || (packet->flags & AV_PKT_FLAG_CORRUPT) ||
        packet->pts == AV_NOPTS_VALUE || packet->duration <= 0) return false;
    if (a->intra_only) return true;
    return mp_h26x_no_leading_random_access(packet, a->stream->codecpar);
}

static int compare_pts(const void *left, const void *right)
{
    const AVPacket *a = *(AVPacket *const *)left, *b = *(AVPacket *const *)right;
    return (a->pts > b->pts) - (a->pts < b->pts);
}

// The open span may be skipped when its packets present back to back from its
// first picture up to the closing one, within the longest allowed span.
static bool adaptive_tiled(const Adaptive *a)
{
    const AVPacket *first = a->packets[0], *last = a->packets[a->count - 1];
    if (a->count < 2 || first->pts == AV_NOPTS_VALUE) return false;
    if (span_reaches(a, first, last, SPAN_LONGEST_SECONDS, true)) return false;
    const AVPacket *ordered[SPAN_PACKETS];
    memcpy(ordered, a->packets, (size_t)(a->count - 1) * sizeof(*ordered));
    for (int i = 0; i < a->count - 1; i++)
        if (ordered[i]->pts == AV_NOPTS_VALUE || ordered[i]->duration <= 0 ||
            (ordered[i]->flags & AV_PKT_FLAG_CORRUPT)) return false;
    qsort(ordered, (size_t)(a->count - 1), sizeof(*ordered), compare_pts);
    if (ordered[0] != first) return false;
    int64_t end = first->pts;
    for (int i = 0; i < a->count - 1; i++) {
        if (ordered[i]->pts != end || ordered[i]->pts > INT64_MAX - ordered[i]->duration) return false;
        end += ordered[i]->duration;
    }
    return end == last->pts;
}

// Pair the key decoder's finished pictures with their spans, in order, and
// reduce the new ones side by side.
static void adaptive_collect(Adaptive *a)
{
    AVFrame *pictures[SPAN_QUEUE];
    Sample *samples[SPAN_QUEUE];
    Span *owners[SPAN_QUEUE];
    int count = 0;
    for (int failures = 0; a->key && a->next_key < a->queued && failures < 64;) {
        Span *span = &a->queue[a->next_key];
        if (!span->offered || span->picture || span->sampled || span->missing) {
            a->next_key++;
            continue;
        }
        if (!a->has_held) {
            int ret = avcodec_receive_frame(a->key, a->held);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            // A picture the decoder could not read is simply absent. Its span
            // sees a later timestamp, or none, and is decoded in full.
            if (ret < 0) {
                failures++;
                continue;
            }
            a->has_held = true;
        }
        const int64_t pts = a->held->best_effort_timestamp;
        const int64_t closing = span->packets[span->count - 1]->pts;
        if (pts != AV_NOPTS_VALUE && pts > closing) {
            span->missing = true;
            a->next_key++;
            continue;
        }
        if (pts == closing && (span->picture = av_frame_alloc())) {
            av_frame_move_ref(span->picture, a->held);
            pictures[count] = span->picture;
            samples[count] = &span->sample;
            owners[count++] = span;
            a->next_key++;
        } else {
            av_frame_unref(a->held);
        }
        a->has_held = false;
    }
    if (!count) return;
    adaptive_reduce(a, pictures, samples, count);
    for (int i = 0; i < count; i++) {
        av_frame_free(&owners[i]->picture);
        owners[i]->sampled = true;
    }
}

// Settle queued spans in order: offer each closing picture and decode the
// spans it does not replace. Without wait, stop at the first span whose
// picture is still decoding.
static int adaptive_settle(Adaptive *a, bool wait)
{
    for (;;) {
        adaptive_collect(a);
        if (!a->queued) break;
        Span *span = &a->queue[0];
        const AVPacket *first = span->packets[0], *last = span->packets[span->count - 1];
        if (span->offered && !span->sampled && !span->missing) {
            if (a->key_drained) {
                span->missing = true;
            } else if (!wait) {
                return 0;
            } else {
                // Ask the decoder for the pictures it still holds.
                avcodec_send_packet(a->key, NULL);
                a->key_drained = true;
                continue;
            }
        }
        bool accepted = false;
        int ret = adaptive_flush(a);
        if (ret != 0) return ret;
        if (span->sampled && a->boundaries && first->pts == a->delivered) {
            Sample *sample = &span->sample;
            // An invalid display transform keeps its exact status.
            if (sample->status > 0) return sample->status;
            if (sample->status < 0) {
                // A key picture can fail to convert where the dense decoder
                // delivers the same frame. No callback committed it.
                a->boundaries = false;
            } else if (!sample->damaged) {
                if (a->scan.cancelled(a->scan.context)) return AVERROR_EXIT;
                a->scan.pictures++;
                void *prepared = sample->prepared;
                sample->prepared = NULL;
                int answer = a->offer(a->scan.context, sample->pts, sample->duration, sample->rgb,
                                      sample->width, sample->height, sample->width * 3,
                                      sample->sar.num, sample->sar.den, prepared);
                if (answer < 0) return AVERROR_EXIT;
                accepted = answer > 0;
            }
        }
        if (accepted) {
            a->delivered = last->pts;
        } else {
            if ((ret = adaptive_decode(a, span->packets, span->count, true)) != 0) return ret;
            // Without the closing picture nothing anchors the spans after it.
            if (a->delivered != last->pts) a->boundaries = false;
        }
        a->queued_bytes -= span->bytes;
        span_free(a, span);
        memmove(a->queue, a->queue + 1, (size_t)--a->queued * sizeof(*a->queue));
        a->queue[a->queued] = (Span){0};
        if (a->next_key > 0) a->next_key--;
    }
    if (a->key_drained && a->key) {
        // Every queued span has settled. Drop pictures nobody claimed.
        av_frame_unref(a->held);
        a->has_held = false;
        avcodec_flush_buffers(a->key);
        a->key_drained = false;
    }
    a->next_key = 0;
    return 0;
}

// Queue the open span behind its closing packet and start the next span on it.
static int adaptive_close(Adaptive *a, AVPacket *closing)
{
    int ret;
    // The key decoder accepts packets only between drains.
    if (a->key_drained && (ret = adaptive_settle(a, true)) != 0) return ret;
    Span span = { .count = a->count, .bytes = a->bytes };
    AVPacket *next = av_packet_clone(closing);
    span.packets = av_malloc_array((size_t)a->count, sizeof(*span.packets));
    if (!next || !span.packets) {
        av_packet_free(&next);
        av_free(span.packets);
        return AVERROR(ENOMEM);
    }
    if (a->boundaries && adaptive_tiled(a)) {
        if (adaptive_decoder(a, &a->key, closing) < 0) {
            // The dense decoder is already open. Decode this span and continue
            // in order without buffering more speculative spans.
            a->boundaries = false;
        } else {
            ret = avcodec_send_packet(a->key, closing);
            if (ret == AVERROR(EAGAIN)) {
                // Make room by collecting finished pictures.
                adaptive_collect(a);
                ret = avcodec_send_packet(a->key, closing);
            }
            span.offered = ret >= 0;
        }
    }
    memcpy(span.packets, a->packets, (size_t)a->count * sizeof(*span.packets));
    a->queue[a->queued++] = span;
    a->queued_bytes += span.bytes;
    a->packets[0] = next;
    a->count = 1;
    a->bytes = next->size;
    const bool full = !a->boundaries || a->queued == SPAN_QUEUE || a->queued_bytes > SPAN_QUEUE_BYTES;
    return full || a->queued >= a->backlog ? adaptive_settle(a, full) : 0;
}

static int adaptive_packet(Adaptive *a, AVPacket **owned)
{
    AVPacket *packet = *owned;
    const bool boundary = adaptive_boundary(a, packet);
    int ret;
    if (a->streaming) {
        if ((ret = adaptive_pump(a, packet)) != 0) return ret;
        if (!boundary) return 0;
        // Everything through the boundary has been presented. Start a span on it.
        if ((ret = adaptive_pump(a, NULL)) != 0 || (ret = adaptive_flush(a)) != 0) return ret;
        if (a->delivered != packet->pts) {
            // The decoder did not return this picture, so nothing anchors a span.
            avcodec_flush_buffers(a->dense);
            a->boundaries = false;
            a->skipping = a->delivered != AV_NOPTS_VALUE;
            return adaptive_pump(a, packet);
        }
        *owned = NULL;
        a->packets[a->count++] = packet;
        a->bytes = packet->size;
        a->streaming = false;
        return 0;
    }
    if (packet->pts != AV_NOPTS_VALUE && a->packets[0]->pts != AV_NOPTS_VALUE &&
        packet->pts < a->packets[0]->pts) {
        // A later picture presents before its random access picture. Decode
        // the rest of the stream in order.
        a->boundaries = false;
    }
    *owned = NULL;
    a->packets[a->count++] = packet;
    a->bytes += packet->size;
    const AVPacket *first = a->packets[0];
    if (boundary && a->boundaries && span_reaches(a, first, packet, SPAN_SHORTEST_SECONDS, false)) {
        if ((ret = adaptive_close(a, packet)) != 0) return ret;
        if (a->boundaries) return 0;
        // Decode on in order. The later pictures refer to the closing one.
        first = a->packets[0];
        packet = a->packets[a->count - 1];
    }
    const bool long_span = packet->pts != AV_NOPTS_VALUE && first->pts != AV_NOPTS_VALUE &&
        span_reaches(a, first, packet, SPAN_LONGEST_SECONDS, true);
    if (!a->boundaries || long_span || a->count == SPAN_PACKETS || a->bytes > SPAN_BYTES) {
        // Earlier spans present first.
        if ((ret = adaptive_settle(a, true)) != 0) return ret;
        if ((ret = adaptive_decode(a, a->packets, a->count, false)) != 0) return ret;
        adaptive_clear(a);
        a->streaming = true;
    }
    return 0;
}

int mp_participant_scan_adaptive(const char *path, int index, int sample_limit, MPProbeCancelled cancelled,
                                 MPParticipantSampleVisit coarse, MPParticipantSampleVisit frame,
                                 MPParticipantPrepare prepare, MPParticipantDiscard discard,
                                 void *context, int *unplaced_damage, char *error, size_t capacity)
{
    if (!path || !cancelled || !frame || sample_limit < 0 || (prepare && !discard)) {
        av_strerror(AVERROR(EINVAL), error, capacity);
        return AVERROR(EINVAL);
    }
    if (unplaced_damage) *unplaced_damage = 0;
    Adaptive *a = av_mallocz(sizeof(*a));
    AVFormatContext *format = avformat_alloc_context();
    AVPacket *packet = NULL;
    int ret = AVERROR(ENOMEM);
    if (!a || !format) goto done;
    a->scan = (Scan){ .cancelled = cancelled, .context = context };
    a->visit = frame;
    a->offer = coarse;
    a->prepare = prepare;
    a->discard = discard;
    a->unplaced_damage = unplaced_damage;
    a->delivered = AV_NOPTS_VALUE;
    a->streaming = true;
    if (!(a->frame = av_frame_alloc()) || !(a->held = av_frame_alloc())) goto done;
    format->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if ((ret = avformat_open_input(&format, path, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(format, NULL)) < 0) goto done;
    if (index < 0 || index >= (int)format->nb_streams ||
        format->streams[index]->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
        ret = AVERROR_STREAM_NOT_FOUND;
        goto done;
    }
    AVStream *stream = a->stream = format->streams[index];
    a->scan.picture_format = format;
    a->scan.picture_stream = stream;
    const AVPacketSideData *display = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    const int32_t identity[9] = { 1 << 16, 0, 0, 0, 1 << 16, 0, 0, 0, 1 << 30 };
    memcpy(a->scan.picture_display_matrix, display && display->size == sizeof(identity) ? display->data :
           (const uint8_t *)identity, sizeof(identity));
    for (unsigned i = 0; i < format->nb_streams; i++)
        if (i != (unsigned)index) format->streams[i]->discard = AVDISCARD_ALL;
    if (!(a->decoder = avcodec_find_decoder(stream->codecpar->codec_id))) { ret = AVERROR_DECODER_NOT_FOUND; goto done; }
    const AVCodecParameters *parameters = stream->codecpar;
    const enum AVCodecID id = parameters->codec_id;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(id);
    a->intra_only = descriptor && (descriptor->props & AV_CODEC_PROP_INTRA_ONLY) && id != AV_CODEC_ID_FFV1;
    // For H.26x, adaptive_boundary verifies the bitstream's actual access point.
    // Without a coarse visit every picture is decoded in order.
    a->boundaries = coarse && (a->intra_only || id == AV_CODEC_ID_H264 || id == AV_CODEC_ID_HEVC);
    a->software = id == AV_CODEC_ID_H264 && (int64_t)parameters->width * parameters->height <= SOFTWARE_PIXELS &&
        (parameters->format == AV_PIX_FMT_YUV420P || parameters->format == AV_PIX_FMT_YUVJ420P);
    // The hardware decoder returns these pictures as NV12. Present the same
    // planes to the converter so both decoders yield identical RGB.
    a->scan.pack_nv12 = a->software;
    // Full pictures are large. Convert them one at a time unless the caller
    // takes the reduced grid. Hardware pictures come from a small pool that
    // the decoder waits on, so none of them may be held back either.
    a->sample_limit = sample_limit;
    a->batch_limit = sample_limit > 0 && a->software ? BATCH : 1;
    const int64_t picture_bytes = FFMAX(1, (int64_t)parameters->width * parameters->height * 3);
    a->worker_count = sample_limit > 0
        ? (int)FFMAX(1, FFMIN(FFMIN(av_cpu_count() / 2, WORKERS), WORKER_BYTES / picture_bytes)) : 1;
    if (!(a->workers = av_calloc((size_t)a->worker_count, sizeof(*a->workers)))) { ret = AVERROR(ENOMEM); goto done; }
    for (int i = 0; i < a->worker_count; i++) {
        Scan *worker = &a->workers[i];
        worker->picture_format = format;
        worker->picture_stream = stream;
        worker->pack_nv12 = a->software;
        memcpy(worker->picture_display_matrix, a->scan.picture_display_matrix, sizeof(worker->picture_display_matrix));
        if (!(worker->rgb_frame = av_frame_alloc())) { ret = AVERROR(ENOMEM); goto done; }
    }
    for (int i = 0; i < a->batch_limit; i++)
        if (!(a->batch[i] = av_frame_alloc())) { ret = AVERROR(ENOMEM); goto done; }
    a->backlog = FFMIN(SPAN_QUEUE - 1, a->worker_count + (a->software ? software_threads(true) - 1 : 0));
    for (;;) {
        if (cancelled(context)) { ret = AVERROR_EXIT; goto done; }
        if (!packet && !(packet = av_packet_alloc())) { ret = AVERROR(ENOMEM); goto done; }
        ret = av_read_frame(format, packet);
        if (ret == AVERROR_EOF) break;
        if (ret < 0) goto done;
        if (packet->stream_index != index) { av_packet_unref(packet); continue; }
        if (!a->dense && (ret = adaptive_decoder(a, &a->dense, packet)) < 0) goto done;
        ret = adaptive_packet(a, &packet);
        if (packet) av_packet_unref(packet);
        if (ret != 0) goto done;
    }
    if (cancelled(context)) { ret = AVERROR_EXIT; goto done; }
    // The last span has no closing picture. Present all of it.
    if ((ret = adaptive_settle(a, true)) != 0) goto done;
    if (!a->dense && (ret = adaptive_decoder(a, &a->dense, NULL)) < 0) goto done;
    if (!a->streaming && (ret = adaptive_decode(a, a->packets, a->count, false)) != 0) goto done;
    if ((ret = adaptive_pump(a, NULL)) != 0 || (ret = adaptive_flush(a)) != 0) goto done;
    ret = a->scan.pictures ? 0 : AVERROR_INVALIDDATA;
done:
    if (ret < 0) av_strerror(ret, error, capacity);
    if (a) {
        adaptive_clear(a);
        for (int i = 0; i < a->queued; i++) span_free(a, &a->queue[i]);
        for (int i = 0; a->workers && i < a->worker_count; i++) {
            sws_freeContext(a->workers[i].rgb_scale);
            av_frame_free(&a->workers[i].rgb_frame);
            av_free(a->workers[i].chroma);
        }
        av_free(a->workers);
        for (int i = 0; i < BATCH; i++) {
            av_frame_free(&a->batch[i]);
            sample_discard(a, &a->samples[i]);
            av_free(a->samples[i].rgb);
        }
        av_frame_free(&a->frame);
        av_frame_free(&a->held);
        avcodec_free_context(&a->dense);
        avcodec_free_context(&a->key);
    }
    av_packet_free(&packet);
    avformat_close_input(&format);
    av_free(a);
    return ret == AVERROR_EXIT ? MP_SCENE_SCAN_CANCELLED : ret;
}
