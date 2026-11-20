#include "MediaProbe.h"
#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>
#include <math.h>

// Equal-area spatial samples compare color and composition without decoding a
// full-resolution RGB image. Hardware NV12/P010 surfaces stay in shared memory.
enum { W = 64, H = 36, CHANNELS = 3, SIZE = W * H * CHANNELS };
typedef struct {
    uint8_t pixels[SIZE];
    int64_t pts;
} ScenePicture;

typedef struct {
    ScenePicture frames[3];
    int64_t count;
    double motion, pending, last_delta;
    struct SwsContext *scale;
    MPSceneVisit visit;
    MPProbeCancelled cancelled;
    void *context;
} Scan;

static double distance(const ScenePicture *a, const ScenePicture *b)
{
    unsigned sum = 0;
    for (int i = 0; i < SIZE; i += 3)
        sum += abs(a->pixels[i] - b->pixels[i]) +
               abs(a->pixels[i+1] - b->pixels[i+1]) + abs(a->pixels[i+2] - b->pixels[i+2]);
    return (double)sum / (W * H);
}

static int sample_surface(CVPixelBufferRef surface, ScenePicture *picture)
{
    OSType format = CVPixelBufferGetPixelFormatType(surface);
    bool wide = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if (!wide && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
                 format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return 0;
    if (CVPixelBufferLockBaseAddress(surface, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return 0;
    size_t width = CVPixelBufferGetWidth(surface), height = CVPixelBufferGetHeight(surface);
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(surface, 0);
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(surface, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(surface, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(surface, 1);
    for (int y = 0; y < H; y++) {
        size_t sy = (2*y+1)*height/(2*H);
        for (int x = 0; x < W; x++) {
            size_t sx = (2*x+1)*width/(2*W), cx = 2*(sx/2);
            uint8_t *out = picture->pixels + (y*W+x)*3;
            if (wide) {
                out[0] = ((uint16_t *)(luma + sy*ys))[sx] >> 8;
                out[1] = ((uint16_t *)(chroma + sy/2*cs))[cx] >> 8;
                out[2] = ((uint16_t *)(chroma + sy/2*cs))[cx+1] >> 8;
            } else {
                out[0] = luma[sy*ys+sx];
                out[1] = chroma[sy/2*cs+cx];
                out[2] = chroma[sy/2*cs+cx+1];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(surface, kCVPixelBufferLock_ReadOnly);
    return 1;
}

static int sample(Scan *scan, AVFrame *frame, ScenePicture *picture)
{
    AVFrame *transfer = NULL;
    int ret = 0;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (sample_surface((CVPixelBufferRef)frame->data[3], picture)) return 0;
        if (!(transfer = av_frame_alloc())) return AVERROR(ENOMEM);
        if ((ret = av_hwframe_transfer_data(transfer, frame, 0)) < 0) goto done;
        frame = transfer;
    }
    scan->scale = sws_getCachedContext(scan->scale, frame->width, frame->height, frame->format,
                                      W, H, AV_PIX_FMT_YUV444P, SWS_POINT, NULL, NULL, NULL);
    if (!scan->scale) { ret = AVERROR(ENOMEM); goto done; }
    uint8_t planes[3][W*H + AV_INPUT_BUFFER_PADDING_SIZE];
    uint8_t *out[4] = { planes[0], planes[1], planes[2], NULL };
    int stride[4] = { W, W, W, 0 };
    ret = sws_scale(scan->scale, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, out, stride);
    if (ret != H) { ret = AVERROR_INVALIDDATA; goto done; }
    for (int i = 0; i < W*H; i++)
        for (int c = 0; c < 3; c++) picture->pixels[3*i+c] = planes[c][i];
    ret = 0;
done:
    av_frame_free(&transfer);
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
                        sum += frame->pixels[((4*y+j)*W+4*x+k)*3+c];
                layout[(y*(W/4)+x)*3+c] = sum/16;
            }
    scan->visit(scan->context, frame->pts, layout);
}

static int consume(Scan *scan, AVFrame *frame)
{
    if (scan->cancelled(scan->context)) return AVERROR_EXIT;
    if (frame->best_effort_timestamp == AV_NOPTS_VALUE) return AVERROR_INVALIDDATA;
    ScenePicture *now = &scan->frames[scan->count % 3];
    now->pts = frame->best_effort_timestamp;
    int ret = sample(scan, frame, now);
    if (ret < 0) return ret;
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
            if (distance(before, now) < fmax(13, scan->pending*0.35)) candidate = false;
            else if (scan->pending > 1.25*delta) emit(scan, prev);
        }
        scan->motion = 0.85*scan->motion + 0.15*fmin(delta, fmax(15, scan->motion*2+8));
        scan->pending = candidate ? delta : 0;
        scan->last_delta = delta;
    }
    scan->count++;
    if ((scan->count % 32) == 0) scan->visit(scan->context, now->pts, NULL);
    return 0;
}

static enum AVPixelFormat choose_format(AVCodecContext *ctx, const enum AVPixelFormat *available)
{
    for (const enum AVPixelFormat *p = available; *p != AV_PIX_FMT_NONE; ++p)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return avcodec_default_get_format(ctx, available);
}

int mp_scene_scan(const char *path, int index, MPProbeCancelled cancelled, MPSceneVisit visit,
                  void *context, char *error, size_t capacity)
{
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *codec = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    Scan scan = { .visit = visit, .cancelled = cancelled, .context = context };
    int ret = AVERROR(ENOMEM);
    if (!format || !packet || !frame) goto done;
    format->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if ((ret = avformat_open_input(&format, path, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(format, NULL)) < 0) goto done;
    if (index < 0 || index >= format->nb_streams) { ret = AVERROR_STREAM_NOT_FOUND; goto done; }
    AVStream *stream = format->streams[index];
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) { ret = AVERROR_DECODER_NOT_FOUND; goto done; }
    if (!(codec = avcodec_alloc_context3(decoder))) { ret = AVERROR(ENOMEM); goto done; }
    if ((ret = avcodec_parameters_to_context(codec, stream->codecpar)) < 0) goto done;
    codec->pkt_timebase = stream->time_base;
    codec->thread_count = 2;
    for (int i = 0; ; ++i) {
        const AVCodecHWConfig *hw = avcodec_get_hw_config(decoder, i);
        if (!hw) break;
        if (hw->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
            av_hwdevice_ctx_create(&codec->hw_device_ctx, hw->device_type, NULL, NULL, 0) >= 0) {
            codec->get_format = choose_format;
            break;
        }
    }
    if ((ret = avcodec_open2(codec, decoder, NULL)) < 0) goto done;
    while (!cancelled(context)) {
        ret = av_read_frame(format, packet);
        bool eof = ret == AVERROR_EOF;
        if (ret < 0 && !eof) goto done;
        if (!eof && packet->stream_index != index) { av_packet_unref(packet); continue; }
        ret = avcodec_send_packet(codec, eof ? NULL : packet);
        av_packet_unref(packet);
        if (ret < 0) goto done;
        while ((ret = avcodec_receive_frame(codec, frame)) >= 0) {
            ret = consume(&scan, frame);
            av_frame_unref(frame);
            if (ret < 0) goto done;
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) goto done;
        if (eof) {
            if (scan.pending > 0) emit(&scan, &scan.frames[(scan.count-1)%3]);
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
