#include "JPEGFrameReader.h"
#include <libavcodec/avcodec.h>
#include <libavcodec/videotoolbox.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <math.h>

struct MPJPEGReader {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *scaler;
    AVStream *stream;
    int (*cancelled)(void *);
    void *context;
    bool draining;
    bool saw_frame;
    bool sought;
    // Deliver software pictures deeper than 8 bits as 16-bit RGB.
    bool deep;
    int64_t first_dts;
    // Pictures before this time may depend on a packet that failed to decode.
    int64_t clean_pts;
    // The first keyframe packet sent after the latest failure. An earlier
    // keyframe can still be waiting in the decoder when a failure is reported.
    int64_t resume_pts;
    int hardware_failures;
    CGAffineTransform transform;
    CGSize display_size;
};

static CGAffineTransform display_transform(const uint8_t *data, size_t size);

void mp_jpeg_close(MPJPEGReader *r)
{
    if (!r) return;
    av_frame_free(&r->frame);
    av_packet_free(&r->packet);
    avcodec_free_context(&r->codec);
    avformat_close_input(&r->format);
    sws_freeContext(r->scaler);
    av_free(r);
}

static enum AVPixelFormat jpeg_format(AVCodecContext *codec, const enum AVPixelFormat *formats)
{
    if (codec->hw_device_ctx) {
        for (const enum AVPixelFormat *f = formats; *f != AV_PIX_FMT_NONE; f++)
            if (*f == AV_PIX_FMT_VIDEOTOOLBOX) return *f;
    }
    for (const enum AVPixelFormat *f = formats; *f != AV_PIX_FMT_NONE; f++)
        if (!(av_pix_fmt_desc_get(*f)->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *f;
    return AV_PIX_FMT_NONE;
}

MPJPEGReader *mp_jpeg_open(const char *path, int stream, int (*cancelled)(void *), void *context,
                           char *error, size_t capacity)
{
    MPJPEGReader *r = av_mallocz(sizeof(*r));
    int ret = AVERROR(ENOMEM);
    if (!r) goto fail;
    r->cancelled = cancelled;
    r->context = context;
    r->first_dts = AV_NOPTS_VALUE;
    r->clean_pts = INT64_MIN;
    r->format = avformat_alloc_context();
    r->frame = av_frame_alloc();
    r->packet = av_packet_alloc();
    if (!r->format || !r->frame || !r->packet) goto fail;
    r->format->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if ((ret = avformat_open_input(&r->format, path, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(r->format, NULL)) < 0) goto fail;
    if (stream < 0 || stream >= r->format->nb_streams) { ret = AVERROR_STREAM_NOT_FOUND; goto fail; }
    r->stream = r->format->streams[stream];
    const AVCodecParameters *p = r->stream->codecpar;
    const AVPacketSideData *matrix = av_packet_side_data_get(p->coded_side_data, p->nb_coded_side_data,
                                                              AV_PKT_DATA_DISPLAYMATRIX);
    r->transform = matrix ? display_transform(matrix->data, matrix->size) : CGAffineTransformIdentity;
    const AVCodec *decoder = avcodec_find_decoder(r->stream->codecpar->codec_id);
    if (!decoder) { ret = AVERROR_DECODER_NOT_FOUND; goto fail; }
    r->codec = avcodec_alloc_context3(decoder);
    if (!r->codec) { ret = AVERROR(ENOMEM); goto fail; }
    if ((ret = avcodec_parameters_to_context(r->codec, r->stream->codecpar)) < 0) goto fail;
    r->codec->pkt_timebase = r->stream->time_base;
    r->codec->thread_count = 2;
    for (int i = 0; ; i++) {
        const AVCodecHWConfig *hw = avcodec_get_hw_config(decoder, i);
        if (!hw) break;
        if (hw->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
            av_hwdevice_ctx_create(&r->codec->hw_device_ctx, hw->device_type, NULL, NULL, 0) >= 0) break;
    }
    r->codec->get_format = jpeg_format;
    if ((ret = avcodec_open2(r->codec, decoder, NULL)) < 0) goto fail;
    for (unsigned i = 0; i < r->format->nb_streams; i++)
        if (i != (unsigned)stream) r->format->streams[i]->discard = AVDISCARD_ALL;
    return r;
fail:
    av_strerror(ret, error, capacity);
    mp_jpeg_close(r);
    return NULL;
}

void mp_jpeg_set_deep(MPJPEGReader *r, bool deep)
{
    r->deep = deep;
}

CGAffineTransform mp_jpeg_transform(MPJPEGReader *r)
{
    return r->transform;
}

CGSize mp_jpeg_display_size(MPJPEGReader *r)
{
    return r->display_size;
}

static CGAffineTransform display_transform(const uint8_t *data, size_t size)
{
    if (size < 9 * sizeof(int32_t)) return CGAffineTransformIdentity;
    int32_t m[9];
    memcpy(m, data, sizeof(m));
    if (m[2] || m[5] || m[8] != (1 << 30)) return CGAffineTransformMakeScale(0, 0);
    // Core Image coordinates point up, media display coordinates point down.
    // The export normalizes the transformed extent before JPEG encoding.
    return CGAffineTransformMake(m[0]/65536., -m[1]/65536., -m[3]/65536., m[4]/65536., 0, 0);
}

// A software decoder reports a packet it cannot read as invalid data and
// VideoToolbox as an unknown or external error. Reading continues so that one
// damaged packet does not hide every later picture, but nothing is trusted
// until the next keyframe decodes: the pictures in between can be built from
// a missing reference. The decoder reports a failure after later packets were
// sent, so recovery needs a keyframe that was both sent after the failure and
// then decoded.
static bool skip_damage(MPJPEGReader *r, int ret)
{
    if ((ret == AVERROR_UNKNOWN || ret == AVERROR_EXTERNAL) && r->codec->hw_device_ctx) {
        if (++r->hardware_failures > 512) return false;
    } else if (ret != AVERROR_INVALIDDATA) {
        return false;
    }
    r->clean_pts = INT64_MAX;
    r->resume_pts = INT64_MAX;
    return true;
}

static int read_to(MPJPEGReader *r, int64_t pts)
{
    int failures = 0;
    while (!r->cancelled(r->context)) {
        int ret = avcodec_receive_frame(r->codec, r->frame);
        if (failures < 64 && skip_damage(r, ret)) { failures++; continue; }
        if (ret >= 0) {
            failures = 0;
            if (r->frame->decode_error_flags || (r->frame->flags & AV_FRAME_FLAG_CORRUPT)) {
                // A software decoder can deliver a concealed picture with a success status.
                // Later pictures can depend on it until a new keyframe has decoded.
                skip_damage(r, AVERROR_INVALIDDATA);
                av_frame_unref(r->frame);
                continue;
            }
            r->hardware_failures = 0;
            r->saw_frame = true;
            const AVFrameSideData *matrix = av_frame_get_side_data(r->frame, AV_FRAME_DATA_DISPLAYMATRIX);
            if (matrix) r->transform = display_transform(matrix->data, matrix->size);
            int64_t actual = r->frame->best_effort_timestamp;
            if (r->clean_pts == INT64_MAX && (r->frame->flags & AV_FRAME_FLAG_KEY) &&
                actual != AV_NOPTS_VALUE && actual >= r->resume_pts)
                r->clean_pts = actual;
            if (pts == AV_NOPTS_VALUE) return 0;
            if (actual == pts) {
                if (actual >= r->clean_pts) return 0;
                av_frame_unref(r->frame);
                return AVERROR_INVALIDDATA;
            }
            av_frame_unref(r->frame);
            if (actual > pts) return AVERROR_INVALIDDATA;
            continue;
        }
        if (ret != AVERROR(EAGAIN) || r->draining) return ret;
        ret = av_read_frame(r->format, r->packet);
        if (ret == AVERROR_EOF) {
            r->draining = true;
            ret = avcodec_send_packet(r->codec, NULL);
        } else if (ret >= 0) {
            if (r->packet->stream_index == r->stream->index) {
                failures = 0;
                if (r->first_dts == AV_NOPTS_VALUE && !r->sought)
                    r->first_dts = r->packet->dts != AV_NOPTS_VALUE ? r->packet->dts : r->packet->pts;
                ret = avcodec_send_packet(r->codec, r->packet);
                if (skip_damage(r, ret)) ret = 0;
                if (r->clean_pts == INT64_MAX && r->resume_pts == INT64_MAX &&
                    (r->packet->flags & AV_PKT_FLAG_KEY) && r->packet->pts != AV_NOPTS_VALUE)
                    r->resume_pts = r->packet->pts;
            }
            av_packet_unref(r->packet);
        }
        if (ret < 0) return ret;
    }
    return AVERROR_EXIT;
}

static int seek(MPJPEGReader *r, int64_t dts)
{
    int ret = av_seek_frame(r->format, r->stream->index, dts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) return ret;
    avcodec_flush_buffers(r->codec);
    r->draining = false;
    r->sought = true;
    r->clean_pts = INT64_MIN;
    r->resume_pts = INT64_MAX;
    return 0;
}

// swscale's table-driven RGB output darkens a limited-range picture by about two
// code values (white 235 becomes 253). Its full-chroma output and its NEON
// converter are exact, so every conversion below takes one of those two.
#define SOFTWARE_SCALER_FLAGS (SWS_BICUBIC | SWS_FULL_CHR_H_INT)

static int expand_gray(const AVFrame *f, uint8_t *out, int stride)
{
    uint8_t expanded[256];
    for (int i = 0; i < 256; i++)
        expanded[i] = av_clip_uint8((int)lrint((i - 16) * 255.0 / 219.0));
    for (int y = 0; y < f->height; y++) {
        const uint8_t *in = f->data[0] + (ptrdiff_t)y * f->linesize[0];
        uint8_t *row = out + (ptrdiff_t)y * stride;
        for (int x = 0; x < f->width; x++, row += 4) {
            row[0] = row[1] = row[2] = expanded[in[x]];
            row[3] = 255;
        }
    }
    return f->height;
}

// The unscaled 8-bit 4:2:0 and 4:2:2 converter has its exact NEON form only for
// widths in whole blocks of 16 and falls back to the table-driven one otherwise.
// Convert a copy widened to the next block and keep the picture's own columns.
static int convert_in_blocks(MPJPEGReader *r, const int *matrix, uint8_t *out, int stride)
{
    const AVFrame *f = r->frame;
    const int w = f->width, h = f->height, wide = FFALIGN(w, 16);
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(f->format);
    uint8_t *planes[4] = { NULL }, *rgb[4] = { NULL };
    int lines[4] = { 0 }, rgb_lines[4] = { 0 };
    int ret = av_image_alloc(planes, lines, wide, h, f->format, 32);
    if (ret >= 0) ret = av_image_alloc(rgb, rgb_lines, wide, h, AV_PIX_FMT_BGRA, 32);
    if (ret >= 0) {
        r->scaler = sws_getCachedContext(r->scaler, wide, h, f->format, wide, h, AV_PIX_FMT_BGRA,
                                         SOFTWARE_SCALER_FLAGS, NULL, NULL, NULL);
        if (!r->scaler) ret = AVERROR(ENOMEM);
    }
    if (ret >= 0) {
        for (int p = 0; p < 4 && planes[p]; p++) {
            const bool chroma = p == 1 || p == 2;
            const int columns = chroma ? AV_CEIL_RSHIFT(w, desc->log2_chroma_w) : w;
            const int padded = chroma ? AV_CEIL_RSHIFT(wide, desc->log2_chroma_w) : wide;
            const int rows = chroma ? AV_CEIL_RSHIFT(h, desc->log2_chroma_h) : h;
            for (int y = 0; y < rows; y++) {
                uint8_t *row = planes[p] + (ptrdiff_t)y * lines[p];
                memcpy(row, f->data[p] + (ptrdiff_t)y * f->linesize[p], columns);
                memset(row + columns, row[columns - 1], padded - columns);
            }
        }
        sws_setColorspaceDetails(r->scaler, matrix, 0, matrix, 1, 0, 1<<16, 1<<16);
        ret = sws_scale(r->scaler, (const uint8_t *const *)planes, lines, 0, h, rgb, rgb_lines);
        for (int y = 0; y < ret && y < h; y++)
            memcpy(out + (ptrdiff_t)y * stride, rgb[0] + (ptrdiff_t)y * rgb_lines[0], (size_t)w * 4);
    }
    av_freep(&planes[0]);
    av_freep(&rgb[0]);
    return ret;
}

// A picture without a recorded matrix is BT.709 when it is larger than 704x576
// and BT.601 otherwise. VideoToolbox tags its untagged output by this rule, so
// the native preview shows the same colors.
static bool untagged_is_bt709(const AVFrame *f)
{
    return f->width > 704 || f->height > 576;
}

static int software_image(MPJPEGReader *r, int max_edge, CVPixelBufferRef *image)
{
    AVFrame *f = r->frame;
    int w = f->width, h = f->height;
    if (max_edge > 0) {
        // Budget against displayed dimensions. An anamorphic source can need
        // every coded row even when its coded width is much larger than 640.
        CGAffineTransform transform = r->transform;
        double display_w = r->display_size.width, display_h = r->display_size.height;
        double edge = FFMAX(fabs(transform.a) * display_w + fabs(transform.c) * display_h,
                            fabs(transform.b) * display_w + fabs(transform.d) * display_h);
        if (isfinite(edge) && edge > 0) {
            double scale = FFMIN(1, max_edge / edge);
            double samples_w = hypot(transform.a, transform.b) * display_w * scale;
            double samples_h = hypot(transform.c, transform.d) * display_h * scale;
            w = FFMAX(1, (int)FFMIN(w, ceil(samples_w)));
            h = FFMAX(1, (int)FFMIN(h, ceil(samples_h)));
        }
    }
    const int *matrix = sws_getCoefficients(f->colorspace != AVCOL_SPC_UNSPECIFIED ? f->colorspace
        : untagged_is_bt709(f) ? SWS_CS_ITU709 : SWS_CS_DEFAULT);
    const bool limited = f->color_range != AVCOL_RANGE_JPEG;
    const bool unscaled = w == f->width && h == f->height;
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(f->format);
    const bool deep = r->deep && desc && desc->comp[0].depth > 8;
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(NULL, w, h, deep ? kCVPixelFormatType_64RGBALE : kCVPixelFormatType_32BGRA,
                            NULL, &buffer) != kCVReturnSuccess)
        return AVERROR(ENOMEM);
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return AVERROR_EXTERNAL;
    }
    uint8_t *out[] = { CVPixelBufferGetBaseAddress(buffer), NULL, NULL, NULL };
    int stride[] = { (int)CVPixelBufferGetBytesPerRow(buffer), 0, 0, 0 };
    int written;
    if (unscaled && limited && f->format == AV_PIX_FMT_GRAY8) {
        // swscale copies unscaled 8-bit gray as if it were full range.
        written = expand_gray(f, out[0], stride[0]);
    } else if (unscaled && limited && !(h & 1) && (w & 15) &&
               (f->format == AV_PIX_FMT_YUV420P || f->format == AV_PIX_FMT_YUV422P ||
                f->format == AV_PIX_FMT_YUVA420P)) {
        written = convert_in_blocks(r, matrix, out[0], stride[0]);
    } else {
        r->scaler = sws_getCachedContext(r->scaler, f->width, f->height, f->format, w, h,
                                         deep ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_BGRA,
                                         SOFTWARE_SCALER_FLAGS, NULL, NULL, NULL);
        if (!r->scaler) {
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            CVPixelBufferRelease(buffer);
            return AVERROR(ENOMEM);
        }
        sws_setColorspaceDetails(r->scaler, matrix, !limited, matrix, 1, 0, 1<<16, 1<<16);
        written = sws_scale(r->scaler, (const uint8_t *const *)f->data, f->linesize, 0, f->height, out, stride);
        // swscale computes 16-bit RGB from YCbCr on its 8-bit scale times 256: limited-range
        // white arrives as 65280, and a full-range sample as its code shifted up to 16 bits
        // (10-bit peak 1023 as 65472). Stretch either scale to the full 16 bits.
        if (deep && !(desc->flags & AV_PIX_FMT_FLAG_RGB)) {
            const int depth = FFMIN(desc->comp[0].depth, 16);
            const uint64_t numerator = limited ? 257 : 65535;
            const uint64_t denominator = limited ? 256 : (uint64_t)((1 << depth) - 1) << (16 - depth);
            for (int y = 0; y < written; y++) {
                uint16_t *row = (uint16_t *)(out[0] + (ptrdiff_t)y * stride[0]);
                for (int x = 0; x < w; x++, row += 4)
                    for (int c = 0; c < 3; c++)
                        row[c] = (uint16_t)FFMIN(65535, (row[c] * numerator + denominator / 2) / denominator);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (written != h) { CVPixelBufferRelease(buffer); return written < 0 ? written : AVERROR_INVALIDDATA; }
    av_vt_pixbuf_set_attachments(r->codec, buffer, f);
    *image = buffer;
    return 0;
}

int mp_jpeg_frame(MPJPEGReader *r, int64_t pts, int64_t seek_dts, int max_edge,
                  CVPixelBufferRef *image, char *error, size_t capacity)
{
    int ret = 0;
    *image = NULL;
    if (seek_dts != AV_NOPTS_VALUE) {
        // H.264 can specify orientation only on its first picture.
        // Read it before jumping to a distant initial request.
        if (!r->saw_frame) {
            ret = read_to(r, AV_NOPTS_VALUE);
            av_frame_unref(r->frame);
        }
        if (ret >= 0) ret = seek(r, seek_dts);
    }
    if (ret >= 0) ret = read_to(r, pts);
    // Some container indexes seek past an open GOP or a reordered target.
    // Retry from the beginning and still require the exact presentation tick.
    if (ret < 0 && seek_dts != AV_NOPTS_VALUE && !r->cancelled(r->context)) {
        // INT64_MIN is AV_NOPTS_VALUE, which MOV seeks backward from the end
        // and AVI rejects. The first presentation time follows reordered
        // packets in MPEG-TS, so prefer the decode time of the first packet.
        int64_t start = r->first_dts != AV_NOPTS_VALUE ? r->first_dts :
            r->stream->start_time != AV_NOPTS_VALUE ? r->stream->start_time : 0;
        ret = seek(r, start);
        if (ret >= 0) ret = read_to(r, pts);
    }
    if (ret >= 0) {
        AVRational aspect = av_guess_sample_aspect_ratio(r->format, r->stream, r->frame);
        const double pixel_width = aspect.num > 0 && aspect.den > 0 ? av_q2d(aspect) : 1;
        r->display_size = CGSizeMake(r->frame->width * pixel_width, r->frame->height);
        if (r->frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
            CVPixelBufferRef buffer = (CVPixelBufferRef)r->frame->data[3];
            if (buffer) {
                av_vt_pixbuf_set_attachments(r->codec, buffer, r->frame);
                // Core Image and swscale use different defaults for untagged
                // YUV. Give both decoders the same matrix when none was recorded.
                if (r->frame->colorspace == AVCOL_SPC_UNSPECIFIED)
                    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                          untagged_is_bt709(r->frame) ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
                                                                      : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                          kCVAttachmentMode_ShouldPropagate);
                *image = CVPixelBufferRetain(buffer);
            } else ret = AVERROR_INVALIDDATA;
        } else ret = software_image(r, max_edge, image);
        av_frame_unref(r->frame);
    }
    if (ret < 0) av_strerror(ret, error, capacity);
    return ret;
}
