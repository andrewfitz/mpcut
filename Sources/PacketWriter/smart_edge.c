#include "smart_edge.h"
#include "FFPreviewDecoder.h"

#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <stdio.h>
#include <string.h>

/* Only timestamps live in memory for the full span. Encoded pictures are spooled
 * to a private, unlinked file until the packet writer reaches this edge. */
struct MPCutEdge {
    FILE *packets;
    int64_t *times; /* Includes the exclusive end at times[count]. */
    size_t count;
    size_t next;
    uint64_t payload_bytes;
};

typedef struct {
    int size;
    int flags;
} PacketHeader;

typedef struct {
    MPCutEdge *edge;
    AVCodecContext *codec;
    AVPacket *packet;
    int coded_width;
    int coded_height;
    size_t submitted;
    size_t encoded;
    MPCutProgress progress;
    void *context;
    double fraction;
} EdgeEncoder;

void mpcut_edge_free(MPCutEdge *edge)
{
    if (!edge)
        return;
    if (edge->packets)
        fclose(edge->packets);
    av_free(edge->times);
    av_free(edge);
}

static bool is_cancelled(void *opaque)
{
    EdgeEncoder *work = opaque;
    return work->progress && work->progress(work->context, work->fraction);
}

static bool exact_ticks(int64_t value, int64_t denominator, AVRational base, int64_t *ticks)
{
    if (denominator <= 0 || base.num <= 0 || base.den <= 0)
        return false;
    __int128 dividend = (__int128)value * base.den;
    __int128 divisor = (__int128)denominator * base.num;
    __int128 result = dividend / divisor;
    if (dividend % divisor || result <= INT64_MIN || result > INT64_MAX)
        return false;
    *ticks = (int64_t)result;
    return true;
}

static int configure_encoder(EdgeEncoder *work, const AVStream *video, int64_t target_bit_rate, int max_qp)
{
    const AVCodecParameters *source = video->codecpar;
    const char *name;
    switch (source->codec_id) {
    case AV_CODEC_ID_H264: name = "h264_videotoolbox"; break;
    case AV_CODEC_ID_HEVC: name = "hevc_videotoolbox"; break;
    case AV_CODEC_ID_AV1: name = "libsvtav1"; break;
    default: return AVERROR_ENCODER_NOT_FOUND;
    }
    bool main10 = source->codec_id == AV_CODEC_ID_HEVC && source->profile == AV_PROFILE_HEVC_MAIN_10 &&
                  source->format == AV_PIX_FMT_YUV420P10LE;
    if ((!main10 && source->format != AV_PIX_FMT_YUV420P && source->format != AV_PIX_FMT_YUVJ420P) ||
        source->color_trc == AVCOL_TRC_SMPTE2084 || source->color_trc == AVCOL_TRC_ARIB_STD_B67)
        return AVERROR(ENOTSUP);
    const AVCodec *encoder = avcodec_find_encoder_by_name(name);
    if (!encoder)
        return AVERROR_ENCODER_NOT_FOUND;
    AVCodecContext *codec = work->codec = avcodec_alloc_context3(encoder);
    if (!codec)
        return AVERROR(ENOMEM);
    codec->width = source->width;
    codec->height = source->height;
    codec->time_base = video->time_base;
    codec->framerate = video->avg_frame_rate.num > 0 ? video->avg_frame_rate : video->r_frame_rate;
    codec->sample_aspect_ratio = video->sample_aspect_ratio.num > 0 && video->sample_aspect_ratio.den > 0
                                 ? video->sample_aspect_ratio : source->sample_aspect_ratio;
    codec->color_primaries = source->color_primaries;
    codec->color_trc = source->color_trc;
    codec->colorspace = source->color_space;
    codec->color_range = source->format == AV_PIX_FMT_YUVJ420P ? AVCOL_RANGE_JPEG : source->color_range;
    codec->chroma_sample_location = source->chroma_location;
    codec->profile = source->profile;
    codec->bit_rate = target_bit_rate;
    codec->max_b_frames = 0;
    codec->flags |= AV_CODEC_FLAG_CLOSED_GOP;
    codec->err_recognition |= AV_EF_EXPLODE;
    AVDictionary *options = NULL;
    int result;
    if (source->codec_id == AV_CODEC_ID_AV1) {
        codec->pix_fmt = AV_PIX_FMT_YUV420P;
        result = av_dict_set(&options, "preset", "6", 0);
        // Equal average and peak rates select SVT's low-delay CBR mode.
        codec->rc_max_rate = target_bit_rate;
        codec->qmin = 1;
        codec->qmax = max_qp;
        if (result >= 0)
            result = av_dict_set(&options, "svtav1-params", "pred-struct=1:lookahead=0:lp=4", 0);
    } else {
        // FFmpeg's default inserts an extra hardware keyframe every 12 pictures.
        // Each edge already starts independently and ends at the next copy seam.
        codec->gop_size = (int)FFMIN(work->edge->count, INT_MAX);
        codec->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
        codec->sw_pix_fmt = main10 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        result = av_dict_set(&options, "allow_sw", "0", 0);
    }
    if (result >= 0)
        result = avcodec_open2(codec, encoder, &options);
    if (result >= 0 && av_dict_count(options))
        result = AVERROR_OPTION_NOT_FOUND;
    av_dict_free(&options);
    return result;
}

static void release_pixel(void *unused, uint8_t *data)
{
    (void)unused;
    CFRelease((CVPixelBufferRef)data);
}

/* SVT expects planar chroma. Apple delivers NV12 with interleaved CbCr. */
static int copy_planar(CVPixelBufferRef image, AVFrame *frame)
{
    int result = av_frame_get_buffer(frame, 32);
    if (result < 0)
        return result;
    if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return AVERROR_EXTERNAL;
    int chroma_width = (frame->width + 1) / 2;
    for (int plane = 0; plane < 2; plane++) {
        const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(image, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
        int width = plane ? chroma_width : frame->width;
        int height = plane ? (frame->height + 1) / 2 : frame->height;
        if (!base || CVPixelBufferGetHeightOfPlane(image, plane) < (size_t)height ||
            stride < (size_t)width * (plane ? 2 : 1)) {
            result = AVERROR_INVALIDDATA;
            break;
        }
        for (int y = 0; y < height; y++) {
            const uint8_t *input = base + y * stride;
            uint8_t *dst = frame->data[plane] + (size_t)y * frame->linesize[plane];
            uint8_t *cr = plane ? frame->data[2] + (size_t)y * frame->linesize[2] : NULL;
            if (!plane) {
                memcpy(dst, input, width);
            } else {
                for (int x = 0; x < width; x++) {
                    dst[x] = input[2 * x];
                    cr[x] = input[2 * x + 1];
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    return result;
}

static int fill_frame(AVFrame *frame, const AVCodecContext *codec, CMSampleBufferRef sample, int64_t pts)
{
    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (!image || CVPixelBufferGetWidth(image) != (size_t)codec->width ||
        CVPixelBufferGetHeight(image) != (size_t)codec->height || CVPixelBufferGetPlaneCount(image) != 2)
        return AVERROR(ENOTSUP);
    OSType format = CVPixelBufferGetPixelFormatType(image);
    bool main10 = codec->sw_pix_fmt == AV_PIX_FMT_P010LE;
    OSType full = main10 ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    OSType limited = main10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    bool full_range = format == full;
    if ((!full_range && format != limited) ||
        (codec->color_range != AVCOL_RANGE_UNSPECIFIED && full_range != (codec->color_range == AVCOL_RANGE_JPEG)))
        return AVERROR(ENOTSUP);
    frame->format = codec->pix_fmt;
    frame->width = codec->width;
    frame->height = codec->height;
    frame->pts = pts;
    frame->time_base = codec->time_base;
    frame->sample_aspect_ratio = codec->sample_aspect_ratio;
    frame->color_range = codec->color_range;
    frame->colorspace = codec->colorspace;
    frame->color_trc = codec->color_trc;
    frame->color_primaries = codec->color_primaries;
    frame->chroma_location = codec->chroma_sample_location;
    if (codec->pix_fmt != AV_PIX_FMT_VIDEOTOOLBOX)
        return copy_planar(image, frame);
    frame->buf[0] = av_buffer_create((uint8_t *)image, 1, release_pixel, NULL, AV_BUFFER_FLAG_READONLY);
    if (!frame->buf[0])
        return AVERROR(ENOMEM);
    CFRetain(image);
    frame->data[3] = (uint8_t *)image;
    return 0;
}

/* Native AVC/HEVC readers may keep their decode surface across sample
 * descriptions. For instance, a small AVC source may be coded at 160x96
 * while VideoToolbox codes 192x96 with cropping. Equal visible dimensions
 * alone do not make that switch decodable on macOS. */
static int check_coded_size(const EdgeEncoder *work, const AVPacket *packet)
{
    enum AVCodecID id = work->codec->codec_id;
    if (id == AV_CODEC_ID_AV1)
        return 0;
    AVCodecParserContext *parser = av_parser_init(id);
    AVCodecContext *codec = avcodec_alloc_context3(NULL);
    int result = AVERROR(ENOMEM);
    if (parser && codec) {
        parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
        codec->codec_id = id;
        uint8_t *data = NULL;
        int size = 0;
        result = av_parser_parse2(parser, codec, &data, &size, packet->data, packet->size,
                                  packet->pts, packet->dts, 0);
        if (result >= 0) {
            // HEVC encoders can pad a visible picture to 8 or 16 lines. These
            // two standard bottom paddings can share the same decoded surface.
            int64_t height = work->codec->height;
            int64_t aligned8 = (height + 7) & ~INT64_C(7);
            int64_t aligned16 = (height + 15) & ~INT64_C(15);
            bool height_matches = parser->coded_height == work->coded_height ||
                (id == AV_CODEC_ID_HEVC &&
                 ((work->coded_height == aligned8 && parser->coded_height == aligned16) ||
                  (work->coded_height == aligned16 && parser->coded_height == aligned8)));
            result = parser->coded_width == work->coded_width && height_matches &&
                     parser->width == work->codec->width && parser->height == height ? 0 : AVERROR_INPUT_CHANGED;
        }
    }
    av_parser_close(parser);
    avcodec_free_context(&codec);
    return result;
}

static int encode(EdgeEncoder *work, AVFrame *frame)
{
    int result = avcodec_send_frame(work->codec, frame);
    if (result < 0)
        return result;
    while ((result = avcodec_receive_packet(work->codec, work->packet)) == 0) {
        AVPacket *packet = work->packet;
        if (work->encoded >= work->submitted || packet->pts != work->edge->times[work->encoded] ||
            packet->size <= 0 || (work->encoded == 0 && !(packet->flags & AV_PKT_FLAG_KEY)))
            return AVERROR_INVALIDDATA;
        if (work->encoded == 0) {
            result = check_coded_size(work, packet);
            if (result < 0)
                return result;
        }
        PacketHeader header = { packet->size, packet->flags };
        if (fwrite(&header, sizeof(header), 1, work->edge->packets) != 1 ||
            fwrite(packet->data, packet->size, 1, work->edge->packets) != 1)
            return AVERROR(errno ? errno : EIO);
        work->edge->payload_bytes += packet->size;
        work->encoded++;
        av_packet_unref(packet);
        if (is_cancelled(work))
            return AVERROR_EXIT;
    }
    return (frame && result == AVERROR(EAGAIN)) || (!frame && result == AVERROR_EOF) ? 0 : result;
}

static MPCutEdge *encode_edge(const char *path, const AVStream *video, int64_t origin_pts, MPCutTime decode_from,
                              MPCutTime from, MPCutTime to, size_t expected_frames,
                              int64_t target_bit_rate, int max_qp, MPCutProgress progress,
                              void *context, double fraction, char *error, size_t capacity)
{
    EdgeEncoder work = {.progress = progress, .context = context, .fraction = fraction};
    MPPreviewDecoder *decoder = NULL;
    AVFrame *frame = NULL;
    const char *message = "Cannot initialize Smart Trim";
    bool complete_message = false; /* The decoder's own sentence needs no libav error text. */
    int result = AVERROR_INVALIDDATA;
    int64_t anchor, first, end;
    if (!video || target_bit_rate <= 0 || target_bit_rate > INT32_MAX || !expected_frames || expected_frames >= SIZE_MAX / sizeof(int64_t) ||
        !exact_ticks(decode_from.numerator, decode_from.denominator, video->time_base, &anchor) ||
        !exact_ticks(from.numerator, from.denominator, video->time_base, &first) ||
        !exact_ticks(to.numerator, to.denominator, video->time_base, &end) || anchor < 0 || first < anchor || end <= first)
        goto done;
    /* The plan counts from origin_pts. A multicam movie clock puts that before a
     * video track that starts late, so report decoded times from the same origin.
     * The decoder's seek still counts from the track's own first picture. */
    CMTime timeline = kCMTimeInvalid;
    double seek = (double)decode_from.numerator / decode_from.denominator;
    if (origin_pts != AV_NOPTS_VALUE && video->start_time != AV_NOPTS_VALUE && origin_pts != video->start_time) {
        __int128 origin = (__int128)origin_pts * video->time_base.num;
        __int128 lead = (__int128)origin_pts + anchor - video->start_time;
        if (origin < INT64_MIN || origin > INT64_MAX || lead < INT64_MIN || lead > INT64_MAX)
            goto done;
        timeline = CMTimeMake((int64_t)origin, video->time_base.den);
        seek = lead > 0 ? (double)lead * video->time_base.num / video->time_base.den : 0;
    }
    result = AVERROR(ENOMEM);
    work.edge = av_mallocz(sizeof(*work.edge));
    if (!work.edge)
        goto done;
    work.edge->times = av_calloc(expected_frames + 1, sizeof(int64_t));
    work.edge->count = expected_frames;
    frame = av_frame_alloc();
    work.packet = av_packet_alloc();
    if (!frame || !work.packet || !work.edge->times)
        goto done;
    work.edge->times[expected_frames] = end;
    work.edge->packets = tmpfile();
    if (!work.edge->packets) {
        result = AVERROR(errno);
        goto done;
    }
    result = AVERROR_EXTERNAL;
    decoder = mp_preview_open(path, MPPreviewPictureOnly, -1, timeline, is_cancelled, &work, &message);
    if (!decoder)
        goto done;
    const AVStream *probed = mp_preview_prepare_edge(decoder);
    message = "Smart Trim requires a matching 4:2:0 video format and time base";
    if (!probed || probed->index != video->index || av_cmp_q(probed->time_base, video->time_base) ||
        probed->codecpar->codec_id != video->codecpar->codec_id) {
        result = AVERROR(ENOTSUP);
        goto done;
    }
    message = "Cannot initialize the Smart Trim edge encoder";
    result = configure_encoder(&work, probed, target_bit_rate, max_qp);
    if (result < 0)
        goto done;
    result = AVERROR_EXTERNAL;
    message = "Cannot seek to the Smart Trim edge";
    if (!mp_preview_seek(decoder, seek))
        goto done;

    while (!is_cancelled(&work)) {
        CMSampleBufferRef sample = NULL;
        int kind = mp_preview_next(decoder, &sample, &message);
        if (kind == MPPreviewError) {
            // Reading ahead can reach a damaged picture that follows the edge. The edge is
            // complete when every indexed picture was decoded before the damage.
            if (mp_preview_edge_intact_before_damage(decoder) && work.submitted == expected_frames)
                break;
            result = AVERROR_EXTERNAL;
            complete_message = true;
            goto done;
        }
        if (kind == MPPreviewEnd)
            break;
        if (kind != MPPreviewVideo)
            continue;
        CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
        int64_t pts;
        if (!CMTIME_IS_NUMERIC(time) || !exact_ticks(time.value, time.timescale, video->time_base, &pts)) {
            CFRelease(sample);
            result = AVERROR_INVALIDDATA;
            message = "The source picture timestamp cannot be represented";
            goto done;
        }
        if (pts >= end || pts < first) {
            CFRelease(sample);
            if (pts >= end)
                break;
            continue;
        }
        if (work.submitted >= expected_frames || (work.submitted == 0 ? pts != first :
            pts <= work.edge->times[work.submitted - 1])) {
            CFRelease(sample);
            result = AVERROR_INVALIDDATA;
            message = "The decoded Smart Trim range differs from the frame index";
            goto done;
        }
        if (pts > INT64_MAX / video->time_base.num) {
            CFRelease(sample);
            result = AVERROR(EOVERFLOW);
            message = "The source picture time exceeds the encoder clock";
            goto done;
        }
        if (work.submitted == 0)
            mp_preview_coded_size(decoder, &work.coded_width, &work.coded_height);
        work.edge->times[work.submitted++] = pts;
        message = "Cannot encode the source pixel format or frame timing at the Smart Trim edge";
        result = fill_frame(frame, work.codec, sample, pts);
        CFRelease(sample);
        if (result >= 0)
            result = encode(&work, frame);
        av_frame_unref(frame);
        if (result < 0)
            goto done;
    }
    result = AVERROR_EXIT;
    if (is_cancelled(&work))
        goto done;
    message = "The encoded Smart Trim range differs from the frame index";
    if (work.submitted != expected_frames) {
        result = AVERROR_INVALIDDATA;
        goto done;
    }
    result = encode(&work, NULL);
    if (result >= 0 && work.encoded != expected_frames)
        result = AVERROR_INVALIDDATA;
    if (result >= 0 && fseeko(work.edge->packets, 0, SEEK_SET) != 0)
        result = AVERROR(errno);
done:
    mp_preview_close(decoder);
    avcodec_free_context(&work.codec);
    av_frame_free(&frame);
    av_packet_free(&work.packet);
    if (result < 0) {
        if (error && capacity) {
            if (result == AVERROR_INPUT_CHANGED)
                snprintf(error, capacity, "The hardware encoder's coded picture dimensions do not match the source. "
                         "Use a lossless cut point for this clip.");
            else if (complete_message && message)
                snprintf(error, capacity, "%s", message);
            else
                snprintf(error, capacity, "%s: %s", message ? message : "Smart Trim failed", av_err2str(result));
        }
        mpcut_edge_free(work.edge);
        return NULL;
    }
    return work.edge;
}

MPCutEdge *mpcut_edge_open(const char *path, const AVStream *video, int64_t origin_pts, MPCutTime decode_from,
                           MPCutTime from, MPCutTime to, size_t expected_frames,
                           int64_t target_bit_rate, MPCutProgress progress, void *context,
                           double fraction, char *error, size_t capacity)
{
    // Protect the quality of the first few AV1 pictures after a cut. If this
    // costs over 25% more than the local byte budget, let SVT use its full QP
    // range for one retry. Keep whichever result consumes fewer video bytes.
    MPCutEdge *edge = encode_edge(path, video, origin_pts, decode_from, from, to, expected_frames,
                                  target_bit_rate, 44, progress, context, fraction, error, capacity);
    if (!edge || video->codecpar->codec_id != AV_CODEC_ID_AV1)
        return edge;

    long double seconds = (long double)to.numerator / to.denominator - (long double)from.numerator / from.denominator;
    if (edge->payload_bytes <= seconds * target_bit_rate / 8 * 1.25L)
        return edge;
    MPCutEdge *retry = encode_edge(path, video, origin_pts, decode_from, from, to, expected_frames,
                                   target_bit_rate, 63, progress, context, fraction, error, capacity);
    if (!retry) {
        // The first encode is still valid. Only a cancellation discards it.
        if (progress && progress(context, fraction)) {
            mpcut_edge_free(edge);
            return NULL;
        }
        if (error && capacity)
            error[0] = '\0';
        return edge;
    }
    if (edge->payload_bytes <= retry->payload_bytes) {
        mpcut_edge_free(retry);
        return edge;
    }
    mpcut_edge_free(edge);
    return retry;
}

int mpcut_edge_next(MPCutEdge *edge, AVPacket *target)
{
    if (!edge || edge->next >= edge->count)
        return AVERROR_EOF;
    PacketHeader header;
    if (fread(&header, sizeof(header), 1, edge->packets) != 1 || header.size <= 0)
        return AVERROR(EIO);
    av_packet_unref(target);
    int result = av_new_packet(target, header.size);
    if (result < 0)
        return result;
    if (fread(target->data, header.size, 1, edge->packets) != 1) {
        av_packet_unref(target);
        return AVERROR(EIO);
    }
    target->flags = header.flags;
    target->pts = target->dts = edge->times[edge->next];
    target->duration = edge->times[edge->next + 1] - target->pts;
    edge->next++;
    return 0;
}
