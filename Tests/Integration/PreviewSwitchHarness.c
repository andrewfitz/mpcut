// Compare the pictures of MPCut's FFmpeg preview decoder (Sources/FFPreview, VideoToolbox through FFmpeg) with
// FFmpeg's software decoder, which follows a change of sample description exactly. Build it with the decoder's
// sources (see .build/r7/verify-preview.sh):
//   PreviewSwitchHarness FILE [SECONDS...]
// plays FILE from the start, then seeks to each time and decodes twelve pictures. Every picture must equal the
// software decoder's, and the pictures must follow one another from the target. MP_PREVIEW_EDGE=1 decodes as a
// Smart Trim edge does. It lists each change of sample description and whether that sample carries parameter
// sets, prints any notice the decoder reports, and ends with PASS or FAIL.
#include "FFPreviewDecoder.h"
#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int64_t key; uint8_t *y, *u, *v; int w, h; } Ref;
static Ref refs[4096];
static int ref_count;
static int64_t key_of(double seconds) { return llround(seconds * 1e6); }

static int reference(const char *path) {
    AVFormatContext *f = NULL;
    if (avformat_open_input(&f, path, NULL, NULL) < 0 || avformat_find_stream_info(f, NULL) < 0) return -1;
    int vi = av_find_best_stream(f, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVStream *st = f->streams[vi];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    AVCodecContext *c = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(c, st->codecpar);
    c->pkt_timebase = st->time_base;
    c->thread_count = 1;
    if (avcodec_open2(c, codec, NULL) < 0) return -1;
    int64_t start = st->start_time == AV_NOPTS_VALUE ? 0 : st->start_time;
    const AVCodecParameters *par = st->codecpar;
    const int hevc = par->codec_id == AV_CODEC_ID_HEVC;
    AVPacket *p = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();
    for (int eof = 0; !eof;) {
        int r = av_read_frame(f, p);
        if (r < 0) { eof = 1; avcodec_send_packet(c, NULL); }
        else if (p->stream_index == vi) {
            size_t size = 0;
            const uint8_t *side = av_packet_get_side_data(p, AV_PKT_DATA_NEW_EXTRADATA, &size);
            if (side && size > 22 && side[0] == 1 && (hevc || par->codec_id == AV_CODEC_ID_H264)) {
                // A new sample description: does the sample itself repeat any parameter set?
                int width = (side[hevc ? 21 : 4] & 3) + 1, sets = 0;
                for (int at = 0; at + width < p->size;) {
                    uint32_t length = 0;
                    for (int i = 0; i < width; i++) length = length << 8 | p->data[at + i];
                    int type = hevc ? (p->data[at + width] >> 1) & 0x3f : p->data[at + width] & 0x1f;
                    sets += hevc ? type >= 32 && type <= 34 : type == 7 || type == 8;
                    at += width + (int)length;
                }
                printf("description change at %.3f s (%s): in-band parameter sets: %s\n",
                       (p->pts - start) * av_q2d(st->time_base), p->flags & AV_PKT_FLAG_KEY ? "keyframe" : "not a keyframe",
                       sets ? "yes" : "no");
            }
            avcodec_send_packet(c, p);
        }
        av_packet_unref(p);
        while (avcodec_receive_frame(c, fr) == 0) {
            if (fr->format != AV_PIX_FMT_YUV420P && fr->format != AV_PIX_FMT_YUVJ420P) { fprintf(stderr, "format %d\n", fr->format); return -1; }
            Ref *ref = &refs[ref_count++];
            ref->key = key_of((fr->best_effort_timestamp - start) * av_q2d(st->time_base));
            ref->w = fr->width; ref->h = fr->height;
            ref->y = malloc((size_t)ref->w * ref->h);
            ref->u = malloc((size_t)ref->w * ref->h / 4);
            ref->v = malloc((size_t)ref->w * ref->h / 4);
            for (int y = 0; y < ref->h; y++) memcpy(ref->y + y * ref->w, fr->data[0] + y * fr->linesize[0], ref->w);
            for (int y = 0; y < ref->h / 2; y++) {
                memcpy(ref->u + y * ref->w / 2, fr->data[1] + y * fr->linesize[1], ref->w / 2);
                memcpy(ref->v + y * ref->w / 2, fr->data[2] + y * fr->linesize[2], ref->w / 2);
            }
            av_frame_unref(fr);
        }
    }
    avcodec_free_context(&c);
    avformat_close_input(&f);
    return ref_count;
}

static int64_t order[4096];
static int by_key(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}
static void sort_order(void) {
    for (int i = 0; i < ref_count; i++) order[i] = refs[i].key;
    qsort(order, ref_count, sizeof(*order), by_key);
}

static int ref_index(int64_t key) {
    for (int i = 0; i < ref_count; i++) if (llabs(refs[i].key - key) <= 1) return i;
    return -1;
}

// 0 exact, 1 differs, -1 no reference picture.
static int compare(CVPixelBufferRef image, double seconds) {
    int i = ref_index(key_of(seconds));
    if (i < 0) return -1;
    Ref *ref = &refs[i];
    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    int differs = (int)CVPixelBufferGetWidth(image) != ref->w || (int)CVPixelBufferGetHeight(image) != ref->h ||
        CVPixelBufferGetPlaneCount(image) != 2 ||
        (CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    for (int y = 0; !differs && y < ref->h; y++) {
        const uint8_t *row = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(image, 0) + y * CVPixelBufferGetBytesPerRowOfPlane(image, 0);
        differs = memcmp(row, ref->y + y * ref->w, ref->w) != 0;
    }
    for (int y = 0; !differs && y < ref->h / 2; y++) {
        const uint8_t *row = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(image, 1) + y * CVPixelBufferGetBytesPerRowOfPlane(image, 1);
        for (int x = 0; !differs && x < ref->w / 2; x++)
            differs = row[2 * x] != ref->u[y * ref->w / 2 + x] || row[2 * x + 1] != ref->v[y * ref->w / 2 + x];
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    return differs;
}

typedef struct { int pictures, exact, differ, unmatched; char *notice; } Pass;

// Decode `count` pictures (all when <0) after seeking to `from`.
static int edge_mode;

static int pass(MPPreviewDecoder *d, double from, int count, Pass *out, int verbose) {
    memset(out, 0, sizeof(*out));
    int expected = 0;
    while (expected < ref_count && order[expected] < key_of(from < 0 ? 0 : from) - 1) expected++;
    if (from >= 0 && !mp_preview_seek(d, from)) { fprintf(stderr, "seek %.3f failed\n", from); return -1; }
    for (;;) {
        CVPixelBufferRef image = NULL; CMTime pts, duration; const char *error = NULL;
        int kind;
        if (edge_mode) {
            // A Smart Trim edge decoder returns sample buffers.
            CMSampleBufferRef sample = NULL;
            kind = mp_preview_next(d, &sample, &error);
            if (sample) {
                pts = CMSampleBufferGetPresentationTimeStamp(sample);
                image = CMSampleBufferGetImageBuffer(sample);
                if (image) CVPixelBufferRetain(image);
                CFRelease(sample);
            }
        } else {
            kind = mp_preview_next_picture(d, &image, &pts, &duration, &error);
        }
        if (kind == MPPreviewAgain) continue;
        if (kind == MPPreviewError) { printf("  error: %s\n", error); return -1; }
        if (kind == MPPreviewEnd) break;
        if (!image) continue;
        double seconds = CMTimeGetSeconds(pts);
        if (seconds + 1e-6 >= from) {
            // Pictures follow one another from the first reference picture at or after the target.
            if (expected < ref_count && llabs(order[expected] - key_of(seconds)) > 1) {
                out->unmatched++;
                if (verbose) printf("  expected the picture at %.3f s, got %.3f s\n", order[expected] / 1e6, seconds);
                while (expected < ref_count && order[expected] < key_of(seconds) - 1) expected++;
            }
            expected++;
            int c = compare(image, seconds);
            out->pictures++;
            if (c == 0) out->exact++; else if (c > 0) out->differ++; else out->unmatched++;
            if (c && verbose) printf("  %s picture at %.3f s\n", c > 0 ? "WRONG" : "unmatched", seconds);
        }
        CVPixelBufferRelease(image);
        if (count >= 0 && out->pictures >= count) break;
    }
#ifndef MP_PREVIEW_WITHOUT_NOTICE // For a decoder from before mp_preview_notice.
    const char *notice = mp_preview_notice(d);
    if (notice) printf("  notice: %s\n", notice);
#endif
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s FILE [seek...]\n", argv[0]); return 2; }
    av_log_set_level(AV_LOG_ERROR);
    if (reference(argv[1]) <= 0) { fprintf(stderr, "reference decode failed\n"); return 2; }
    sort_order();
    const char *error = NULL;
    MPPreviewDecoder *d = mp_preview_open(argv[1], MPPreviewPictureOnly, -1, kCMTimeInvalid, NULL, NULL, &error);
    if (!d) { fprintf(stderr, "open: %s\n", error); return 2; }
    const char *edge = getenv("MP_PREVIEW_EDGE");
    if (edge && *edge && strcmp(edge, "0")) {
        // Decode as a Smart Trim edge does: native YUV surfaces and errors for any damage.
        edge_mode = 1;
        if (!mp_preview_prepare_edge(d)) { fprintf(stderr, "this stream cannot be decoded for an edge\n"); return 2; }
        printf("edge decoder\n");
    }
    int failures = 0;
    Pass p;
    printf("reference pictures: %d\n", ref_count);
    // Whole file from the start.
    if (pass(d, 0, -1, &p, 1) < 0) failures++;
    printf("play from 0: %d pictures, %d exact, %d wrong, %d unmatched\n", p.pictures, p.exact, p.differ, p.unmatched);
    failures += p.differ + p.unmatched + (p.pictures != ref_count);
    // Seeks (scrub, reverse steps) given on the command line: each decodes 12 pictures from there.
    for (int i = 2; i < argc; i++) {
        // TIME or TIME:COUNT, as a still decodes only up to its target.
        double t = atof(argv[i]);
        const char *colon = strchr(argv[i], ':');
        if (pass(d, t, colon ? atoi(colon + 1) : 12, &p, 1) < 0) failures++;
        printf("seek %.3f: %d pictures, %d exact, %d wrong, %d unmatched\n", t, p.pictures, p.exact, p.differ, p.unmatched);
        failures += p.differ + p.unmatched;
    }
    mp_preview_close(d);
    printf(failures ? "FAIL\n" : "PASS\n");
    return failures ? 1 : 0;
}
