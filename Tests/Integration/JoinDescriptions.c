// Join MP4 or MOV video files of one codec and size into one MP4 or MOV track that starts a new sample description
// (AV_PKT_DATA_NEW_EXTRADATA) wherever the input's description changes. Samples are copied as they are, so inputs
// written with global headers keep their parameter sets out of the samples. Each input follows the end of the one
// before:
//   JoinDescriptions OUTPUT INPUT INPUT...
// With STSD_LATE=N each later description starts N packets after its input's first packet, at a picture that is not
// a keyframe (the samples before it keep the previous description). With STSD_LATE=key it starts at the input's
// second keyframe, such as an HEVC CRA picture with leading pictures.
#include <libavformat/avformat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s OUTPUT INPUT INPUT...\n", argv[0]); return 2; }
    AVFormatContext *out = NULL;
    if (avformat_alloc_output_context2(&out, NULL, NULL, argv[1]) < 0) return 1;
    AVStream *ost = NULL;
    AVPacket *p = av_packet_alloc();
    int64_t offset = 0, next = 0;
    uint8_t *current = NULL; int current_size = 0;
    for (int i = 2; i < argc; i++) {
        AVFormatContext *in = NULL;
        if (avformat_open_input(&in, argv[i], NULL, NULL) < 0 || avformat_find_stream_info(in, NULL) < 0) return 1;
        int vi = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        AVStream *ist = in->streams[vi];
        if (!ost) {
            ost = avformat_new_stream(out, NULL);
            avcodec_parameters_copy(ost->codecpar, ist->codecpar);
            ost->time_base = ist->time_base;
            ost->avg_frame_rate = ist->avg_frame_rate;
            if (!(out->oformat->flags & AVFMT_NOFILE) && avio_open(&out->pb, argv[1], AVIO_FLAG_WRITE) < 0) return 1;
            if (avformat_write_header(out, NULL) < 0) return 1;
        }
        const char *late = i > 2 ? getenv("STSD_LATE") : NULL;
        const int at_key = late && !strcmp(late, "key");
        int first = 1 + (late && !at_key ? atoi(late) : 0), keys = 0;
        while (av_read_frame(in, p) >= 0) {
            if (p->stream_index != vi) { av_packet_unref(p); continue; }
            av_packet_rescale_ts(p, ist->time_base, ost->time_base);
            p->pts += offset; p->dts += offset;
            int64_t end = p->pts + p->duration;
            if (end > next) next = end;
            const AVCodecParameters *par = ist->codecpar;
            keys += (p->flags & AV_PKT_FLAG_KEY) != 0;
            if (at_key)
                first = keys == 2 && (p->flags & AV_PKT_FLAG_KEY) ? 1 : 2;
            if (first == 1 && (par->extradata_size != current_size || memcmp(par->extradata, current, current_size))) {
                if (current) {
                    uint8_t *side = av_packet_new_side_data(p, AV_PKT_DATA_NEW_EXTRADATA, par->extradata_size);
                    memcpy(side, par->extradata, par->extradata_size);
                }
                current = par->extradata; current_size = par->extradata_size;
            }
            first = first > 0 ? first - 1 : 0;
            p->stream_index = 0;
            if (av_write_frame(out, p) < 0) return 1;
        }
        offset = next;
        current = av_memdup(current, current_size);
        avformat_close_input(&in);
    }
    av_write_trailer(out);
    avio_closep(&out->pb);
    avformat_free_context(out);
    return 0;
}
