#include "MediaProbe.h"
#include "codec_header.h"
#include "scene_distance.h"
#include "scene_reader.h"
#include "video_clock.h"
#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/cpu.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/avstring.h>
#include <CommonCrypto/CommonDigest.h>
#include <libswscale/swscale.h>
#include <math.h>
#include <string.h>

// Equal-area spatial samples compare color and composition without decoding a
// full-resolution RGB image. Hardware NV12/P010 surfaces stay in shared memory.
enum { W = 64, H = 36, CHANNELS = 3 };
typedef struct {
    _Alignas(16) uint8_t planes[CHANNELS][W * H + AV_INPUT_BUFFER_PADDING_SIZE];
    int64_t pts;
} ScenePicture;

enum { DIGEST_SIZE = 32, CHECKPOINT_VERSION = 1 };
enum { SCAN_RANGE_END = 3, SCAN_RETRY_FROM_START = 4, SCAN_RETRY_SOFTWARE = 5 };
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

static int consume(Scan *scan, AVFrame *frame)
{
    if (scan->cancelled(scan->context)) return AVERROR_EXIT;
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

static int open_decoder(AVCodecContext *codec, const AVCodec *decoder, const AVPacket *first, bool software)
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
                      char *error, size_t capacity)
{
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *codec = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    Scan scan = { .visit = visit, .cancelled = cancelled, .context = context,
                  .options = options, .checkpoint = progress };
    int64_t first_pts = INT64_MAX, last_pts = INT64_MIN, packet_end = INT64_MIN;
    bool complete_clock = true;
    int hardware_failures = 0;
    int ret = AVERROR(ENOMEM);
    if (timing) *timing = (MPSceneTiming){0};
    if (!format || !packet || !frame) goto done;
    format->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if ((ret = avformat_open_input(&format, path, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(format, NULL)) < 0) goto done;
    if (index < 0 || index >= format->nb_streams) { ret = AVERROR_STREAM_NOT_FOUND; goto done; }
    AVStream *stream = format->streams[index];
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
            av_buffer_unref(&packet->opaque_ref);
            packet->opaque_ref = av_buffer_alloc(sizeof(identity));
            if (!packet->opaque_ref) { ret = AVERROR(ENOMEM); goto done; }
            memcpy(packet->opaque_ref->data, &identity, sizeof(identity));
        }
        ret = avcodec_send_packet(codec, eof ? NULL : packet);
        av_packet_unref(packet);
        // One damaged packet must not discard the rest of the recording.
        // The scan still fails below when no picture decodes at all.
        if (!eof && damaged_picture(codec, ret, &hardware_failures)) ret = 0;
        if (ret < 0) goto done;
        int failures = 0;
        for (;;) {
            ret = avcodec_receive_frame(codec, frame);
            if (failures < 64 && damaged_picture(codec, ret, &hardware_failures)) { failures++; continue; }
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
            ret = scan.count ? 0 : AVERROR_INVALIDDATA;
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
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    return ret;
}

int mp_scene_scan(const char *path, int index, int allow_asset_reader,
                  MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, MPSceneTiming *timing, char *error, size_t capacity)
{
    return scan_video(path, index, allow_asset_reader, cancelled, visit, context, timing,
                      NULL, NULL, false, false, error, capacity);
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
                         options, progress, true, false, error, capacity);
    if (ret == SCAN_RETRY_SOFTWARE)
        ret = scan_video(path, index, 0, cancelled, visit, context, NULL,
                         options, progress, true, true, error, capacity);
    if (ret == SCAN_RETRY_FROM_START)
        ret = scan_video(path, index, 0, cancelled, visit, context, NULL,
                         options, progress, false, false, error, capacity);
    return ret == AVERROR_EXIT ? MP_SCENE_SCAN_CANCELLED : ret;
}
