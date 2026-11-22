#include "MediaProbe.h"
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
#include <libswscale/swscale.h>
#include <math.h>

// Equal-area spatial samples compare color and composition without decoding a
// full-resolution RGB image. Hardware NV12/P010 surfaces stay in shared memory.
enum { W = 64, H = 36, CHANNELS = 3 };
typedef struct {
    _Alignas(16) uint8_t planes[CHANNELS][W * H + AV_INPUT_BUFFER_PADDING_SIZE];
    int64_t pts;
} ScenePicture;

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
    if ((scan->count % 32) == 0) scan->visit(scan->context, now->pts, NULL);
    return 0;
}

static int consume(Scan *scan, AVFrame *frame)
{
    if (scan->cancelled(scan->context)) return AVERROR_EXIT;
    // A picture without a timestamp cannot start a scene. Compare its neighbors instead.
    if (frame->best_effort_timestamp == AV_NOPTS_VALUE) return 0;
    ScenePicture *now = &scan->frames[scan->count % 3];
    now->pts = frame->best_effort_timestamp;
    int ret = sample(scan, frame, now);
    return ret < 0 ? ret : advance(scan, now);
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

static int open_decoder(AVCodecContext *codec, const AVCodec *decoder, const AVPacket *first)
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
    for (int i = 0; ; ++i) {
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

int mp_scene_scan(const char *path, int index, int allow_asset_reader,
                  MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, MPSceneTiming *timing, char *error, size_t capacity)
{
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *codec = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    Scan scan = { .visit = visit, .cancelled = cancelled, .context = context };
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
    const int64_t declared_duration = stream->duration;
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) { ret = AVERROR_DECODER_NOT_FOUND; goto done; }
    if (!(codec = avcodec_alloc_context3(decoder))) { ret = AVERROR(ENOMEM); goto done; }
    if ((ret = avcodec_parameters_to_context(codec, stream->codecpar)) < 0) goto done;
    codec->pkt_timebase = stream->time_base;
    while (!cancelled(context)) {
        ret = av_read_frame(format, packet);
        bool eof = ret == AVERROR_EOF;
        if (ret < 0 && !eof) goto done;
        if (!eof && packet->stream_index != index) { av_packet_unref(packet); continue; }
        if (!avcodec_is_open(codec) && (ret = open_decoder(codec, decoder, eof ? NULL : packet)) < 0)
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
            if (ret < 0) goto done;
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) goto done;
        if (eof) {
            if (scan.pending > 0) emit(&scan, &scan.frames[(scan.count-1)%3]);
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
    if (ret < 0) av_strerror(ret, error, capacity);
    sws_freeContext(scan.scale);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    return ret;
}
