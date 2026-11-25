#include "JPEGFrameReader.h"
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
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
    if (cancelled && cancelled(context)) { ret = AVERROR_EXIT; goto fail; }
    if ((ret = avformat_open_input(&r->format, path, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(r->format, NULL)) < 0) goto fail;
    if (stream < 0 || stream >= r->format->nb_streams ||
        r->format->streams[stream]->codecpar->codec_type != AVMEDIA_TYPE_VIDEO ||
        (r->format->streams[stream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
        ret = AVERROR_STREAM_NOT_FOUND;
        goto fail;
    }
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
    while (!r->cancelled || !r->cancelled(r->context)) {
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
                // The decoder keeps a packet even when sending it reports damage in
                // pictures sent earlier, so a keyframe sent here can still resume.
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

// The color VideoToolbox, and so the native preview, gives a picture for the fields it leaves
// unspecified (measured on macOS 27; FFPreviewDecoder.c keeps the same rule). With no color
// recorded at all it goes by size: larger than 704x576 is BT.709, smaller is BT.601 with SMPTE C
// primaries, or EBU Tech 3213 at exactly 704x576, with the BT.709 transfer. When every recorded
// field is BT.709 or BT.601 (SMPTE 170M), a missing matrix is BT.709 for BT.709 primaries and
// otherwise BT.601, missing primaries follow the matrix (BT.709, otherwise SMPTE C) and a missing
// transfer is BT.709. Other recorded values (an sRGB or PQ transfer, BT.2020 or EBU fields) leave
// the missing primaries and transfer unspecified, and Core Animation decodes a missing matrix as
// BT.601, also for BT.2020 primaries. A PQ or HLG picture with recorded primaries is the exception:
// Core Animation decodes its missing matrix, and BT.601, as BT.2020 for BT.2020 primaries and
// otherwise BT.709, which is also what Core Image, and so the SDR preview of an HDR picture, reads
// for a missing matrix. Returns whether the missing primaries and transfer are filled.
static bool untagged_color(const AVFrame *f, enum AVColorSpace *matrix, enum AVColorPrimaries *primaries)
{
    *matrix = f->colorspace;
    *primaries = f->color_primaries;
    if (f->colorspace == AVCOL_SPC_UNSPECIFIED && f->color_primaries == AVCOL_PRI_UNSPECIFIED &&
        f->color_trc == AVCOL_TRC_UNSPECIFIED) {
        const bool hd = f->width > 704 || f->height > 576;
        *matrix = hd ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
        *primaries = hd ? AVCOL_PRI_BT709 : f->width == 704 && f->height == 576 ? AVCOL_PRI_BT470BG : AVCOL_PRI_SMPTE170M;
        return true;
    }
    const bool fills = (f->colorspace == AVCOL_SPC_UNSPECIFIED || f->colorspace == AVCOL_SPC_BT709 ||
                        f->colorspace == AVCOL_SPC_SMPTE170M) &&
        (f->color_primaries == AVCOL_PRI_UNSPECIFIED || f->color_primaries == AVCOL_PRI_BT709 ||
         f->color_primaries == AVCOL_PRI_SMPTE170M) &&
        (f->color_trc == AVCOL_TRC_UNSPECIFIED || f->color_trc == AVCOL_TRC_BT709 || f->color_trc == AVCOL_TRC_SMPTE170M);
    const bool hdr = (f->color_trc == AVCOL_TRC_SMPTE2084 || f->color_trc == AVCOL_TRC_ARIB_STD_B67) &&
        *primaries != AVCOL_PRI_UNSPECIFIED;
    if (*matrix == AVCOL_SPC_UNSPECIFIED)
        *matrix = hdr && *primaries == AVCOL_PRI_BT2020 ? AVCOL_SPC_BT2020_NCL :
            hdr || (fills && *primaries == AVCOL_PRI_BT709) ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
    if (fills && *primaries == AVCOL_PRI_UNSPECIFIED)
        *primaries = *matrix == AVCOL_SPC_BT709 ? AVCOL_PRI_BT709 : AVCOL_PRI_SMPTE170M;
    return fills;
}

static enum AVColorSpace untagged_matrix(const AVFrame *f)
{
    enum AVColorSpace matrix;
    enum AVColorPrimaries primaries;
    untagged_color(f, &matrix, &primaries);
    return matrix;
}

// Each color field a video picture leaves unspecified takes VideoToolbox's value above, which
// the native preview and the FFmpeg preview show. Without these tags Core Image reads the
// picture as sRGB, 11 levels darker at mid grey than the preview. A JPEG picture without tags is
// a JFIF image, which is sRGB by convention, and RGB or palette pictures are not video, so they
// keep that reading.
static void tag_unspecified_color(MPJPEGReader *r, CVPixelBufferRef buffer, const AVFrame *f)
{
    switch (r->codec->codec_id) {
    case AV_CODEC_ID_MJPEG: case AV_CODEC_ID_MJPEGB: case AV_CODEC_ID_LJPEG:
    case AV_CODEC_ID_JPEGLS: case AV_CODEC_ID_SMVJPEG:
        return;
    default:
        break;
    }
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(f->format);
    if (!desc || (desc->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL)) || f->colorspace == AVCOL_SPC_RGB)
        return;
    enum AVColorSpace matrix;
    enum AVColorPrimaries primaries;
    const bool fills = untagged_color(f, &matrix, &primaries);
    bool tagged = false;
    if (f->colorspace == AVCOL_SPC_UNSPECIFIED) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              matrix == AVCOL_SPC_BT709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 :
                              matrix == AVCOL_SPC_BT2020_NCL ? kCVImageBufferYCbCrMatrix_ITU_R_2020 :
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
        tagged = true;
    }
    if (fills && f->color_primaries == AVCOL_PRI_UNSPECIFIED) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              primaries == AVCOL_PRI_BT709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 :
                              primaries == AVCOL_PRI_BT470BG ? kCVImageBufferColorPrimaries_EBU_3213 :
                              kCVImageBufferColorPrimaries_SMPTE_C, kCVAttachmentMode_ShouldPropagate);
        tagged = true;
    }
    if (fills && f->color_trc == AVCOL_TRC_UNSPECIFIED) {
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        tagged = true;
    }
    // Core Animation shows other primaries recorded without a transfer through a transfer of its
    // own, where Core Image reads the picture as sRGB: the BT.709 transfer for EBU Tech 3213 or
    // SMPTE C primaries, sRGB for P3 D65, and the ITU-R BT.2020 color space for BT.2020 primaries
    // (measured on macOS 27; the FFmpeg preview leaves these to Core Animation).
    if (!fills && f->color_trc == AVCOL_TRC_UNSPECIFIED) {
        if (f->color_primaries == AVCOL_PRI_BT470BG || f->color_primaries == AVCOL_PRI_SMPTE170M) {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                                  kCVAttachmentMode_ShouldPropagate);
            tagged = true;
        } else if (f->color_primaries == AVCOL_PRI_SMPTE432) {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB,
                                  kCVAttachmentMode_ShouldPropagate);
            tagged = true;
        } else if (f->color_primaries == AVCOL_PRI_BT2020) {
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
            if (space) {
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
                CGColorSpaceRelease(space);
            }
            return;
        }
    }
    if (!tagged) return;
    CFDictionaryRef attachments = CVBufferCopyAttachments(buffer, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRef space = attachments ? CVImageBufferCreateColorSpaceFromAttachments(attachments) : NULL;
    if (space) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
        CGColorSpaceRelease(space);
    }
    if (attachments) CFRelease(attachments);
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
    const int *matrix = sws_getCoefficients(untagged_matrix(f));
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
    tag_unspecified_color(r, buffer, f);
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
    if (ret < 0 && seek_dts != AV_NOPTS_VALUE && (!r->cancelled || !r->cancelled(r->context))) {
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
                                          untagged_matrix(r->frame) == AVCOL_SPC_BT709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
                                                                                        : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                          kCVAttachmentMode_ShouldPropagate);
                tag_unspecified_color(r, buffer, r->frame);
                *image = CVPixelBufferRetain(buffer);
            } else ret = AVERROR_INVALIDDATA;
        } else ret = software_image(r, max_edge, image);
        av_frame_unref(r->frame);
    }
    if (ret < 0) av_strerror(ret, error, capacity);
    return ret;
}

struct MPJPEGPackets {
    AVFormatContext *format;
    AVStream *stream;
    AVPacket *packet;
    bool check_layout;
};

void mp_jpeg_packets_close(MPJPEGPackets *p)
{
    if (!p) return;
    av_packet_free(&p->packet);
    avformat_close_input(&p->format);
    av_free(p);
}

MPJPEGPackets *mp_jpeg_packets_open(const char *path, int stream, bool check_layout,
                                    int (*cancelled)(void *), void *context)
{
    MPJPEGPackets *p = av_mallocz(sizeof(*p));
    if (!p) return NULL;
    p->check_layout = check_layout;
    p->format = avformat_alloc_context();
    p->packet = av_packet_alloc();
    if (!p->format || !p->packet) goto fail;
    p->format->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if (avformat_open_input(&p->format, path, NULL, NULL) < 0 || stream < 0 ||
        stream >= (int)p->format->nb_streams) goto fail;
    p->stream = p->format->streams[stream];
    const AVCodecParameters *params = p->stream->codecpar;
    if (params->codec_id != AV_CODEC_ID_MJPEG) goto fail;
    // A copied JPEG cannot carry the container's display transform.
    const AVPacketSideData *matrix = av_packet_side_data_get(params->coded_side_data, params->nb_coded_side_data,
                                                             AV_PKT_DATA_DISPLAYMATRIX);
    if (matrix) {
        CGAffineTransform t = display_transform(matrix->data, matrix->size);
        if (!CGAffineTransformIsIdentity(t)) goto fail;
    }
    for (unsigned i = 0; i < p->format->nb_streams; i++)
        if (i != (unsigned)stream) p->format->streams[i]->discard = AVDISCARD_ALL;
    return p;
fail:
    mp_jpeg_packets_close(p);
    return NULL;
}

// 0: a complete 8-bit baseline JPEG of one whole picture. 1: the same without Huffman tables,
// which an AVI MJPEG picture may leave to the decoder's standard ones. -1: anything else, such as a
// progressive or lossless picture, two interlaced fields, an Exif orientation or ICC profile
// (APP1, APP2 and later segments), a picture of another size, or data after the end marker.
// With check_layout, the frame header must also code gray, or YCbCr with 4:2:0 or 4:2:2 chroma.
static int jpeg_structure(const uint8_t *d, size_t n, int width, int height, bool check_layout)
{
    if (n < 6 || d[0] != 0xFF || d[1] != 0xD8 || d[n - 2] != 0xFF || d[n - 1] != 0xD9) return -1;
    bool tables = false, frame = false;
    size_t i = 2;
    while (i + 4 <= n) {
        if (d[i] != 0xFF) return -1;
        const uint8_t marker = d[i + 1];
        if (marker == 0xFF) { i++; continue; }
        const size_t length = ((size_t)d[i + 2] << 8) | d[i + 3];
        if (length < 2 || i + 2 + length > n) return -1;
        const uint8_t *segment = d + i + 4;
        switch (marker) {
        case 0xC0: case 0xC1:
            if (frame || length < 8 || segment[0] != 8) return -1;
            if (((segment[1] << 8) | segment[2]) != height || ((segment[3] << 8) | segment[4]) != width) return -1;
            if (check_layout) {
                // Components: identifier, horizontal and vertical sampling, quantization table.
                const uint8_t count = segment[5];
                const uint8_t *c = segment + 6;
                if (length < 8 + 3 * (size_t)count) return -1;
                if (count == 3) {
                    // FFmpeg reads components named R, G and B as RGB.
                    if (c[0] == 'R' && c[3] == 'G' && c[6] == 'B') return -1;
                    if ((c[1] != 0x22 && c[1] != 0x21) || c[4] != 0x11 || c[7] != 0x11) return -1;
                } else if (count != 1) return -1;
            }
            frame = true;
            break;
        case 0xC4: tables = true; break;
        case 0xDB: case 0xDD: break;
        case 0xFE: {
            // FFmpeg's decoder reads these comments as limited range, a flipped picture,
            // half-height pixels or Avid fields. A JPEG viewer reads none of them.
            static const char *const decoding[] = { "AVID", "CS=ITU601", "Intel(R) JPEG Library",
                                                    "Metasoft MJPEG Codec", "MULTISCOPE II" };
            for (size_t k = 0; k < sizeof(decoding) / sizeof(*decoding); k++) {
                const size_t tag = strlen(decoding[k]);
                if (length - 2 >= tag && !memcmp(segment, decoding[k], tag)) return -1;
            }
            break;
        }
        case 0xE0:
            // AVI1 names the field of an interlaced picture in the byte after its tag.
            if (length >= 7 && !memcmp(segment, "AVI1", 4) && segment[4] != 0) return -1;
            break;
        case 0xDA:
            if (!frame) return -1;
            // Entropy-coded data up to the final end marker may contain only stuffed bytes,
            // restart markers and fill bytes: no second scan, picture or field.
            for (size_t j = i + 2 + length; j + 1 < n - 2; j++) {
                if (d[j] != 0xFF) continue;
                const uint8_t next = d[j + 1];
                if (next != 0x00 && next != 0xFF && (next < 0xD0 || next > 0xD7)) return -1;
            }
            return tables ? 0 : 1;
        default:
            return -1;
        }
        i += 2 + length;
    }
    return -1;
}

static int insert_standard_tables(const AVCodecParameters *params, AVPacket *packet)
{
    const AVBitStreamFilter *filter = av_bsf_get_by_name("mjpeg2jpeg");
    AVBSFContext *bsf = NULL;
    int ret = filter ? av_bsf_alloc(filter, &bsf) : AVERROR_BSF_NOT_FOUND;
    if (ret >= 0) ret = avcodec_parameters_copy(bsf->par_in, params);
    if (ret >= 0) ret = av_bsf_init(bsf);
    if (ret >= 0) ret = av_bsf_send_packet(bsf, packet);
    if (ret >= 0) ret = av_bsf_receive_packet(bsf, packet);
    av_bsf_free(&bsf);
    return ret;
}

int mp_jpeg_packet(MPJPEGPackets *p, int64_t pts, int width, int height, uint8_t **data, size_t *size)
{
    *data = NULL;
    *size = 0;
    int ret = av_seek_frame(p->format, p->stream->index, pts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) return ret;
    while ((ret = av_read_frame(p->format, p->packet)) >= 0) {
        if (p->packet->stream_index != p->stream->index) { av_packet_unref(p->packet); continue; }
        const int64_t time = p->packet->pts != AV_NOPTS_VALUE ? p->packet->pts : p->packet->dts;
        if (time == AV_NOPTS_VALUE || time > pts) { ret = 0; break; }
        if (time < pts) { av_packet_unref(p->packet); continue; }
        int structure = (p->packet->flags & (AV_PKT_FLAG_CORRUPT | AV_PKT_FLAG_DISCARD)) ? -1 :
            jpeg_structure(p->packet->data, p->packet->size, width, height, p->check_layout);
        if (structure == 1) {
            if (insert_standard_tables(p->stream->codecpar, p->packet) < 0 ||
                jpeg_structure(p->packet->data, p->packet->size, width, height, p->check_layout) != 0) structure = -1;
            else structure = 0;
        }
        if (structure != 0) { ret = 0; break; }
        *data = malloc(p->packet->size);
        if (!*data) { ret = AVERROR(ENOMEM); break; }
        memcpy(*data, p->packet->data, p->packet->size);
        *size = p->packet->size;
        ret = 1;
        break;
    }
    av_packet_unref(p->packet);
    return ret == AVERROR_EOF ? 0 : ret;
}
