#include "MediaProbe.h"
#include "video_clock.h"
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/mathematics.h>
#include <libavutil/parseutils.h>
#include <stdbool.h>

// Confirm a seekable container's declared source clock from a bounded packet
// suffix. Return no clock if the container or packet timing needs a full index.
int mp_scene_verify_clock(const char *path, int index, MPProbeCancelled cancelled,
                          void *context, MPSceneTiming *timing)
{
    AVFormatContext *file = avformat_alloc_context();
    AVPacket *packet = av_packet_alloc();
    int verified = 0;
    if (!file || !packet || !timing) goto done;
    file->interrupt_callback = (AVIOInterruptCB){cancelled, context};
    if (avformat_open_input(&file, path, NULL, NULL) < 0 ||
        index < 0 || (unsigned)index >= file->nb_streams) goto done;

    const char *format = file->iformat->name;
    bool movie = av_match_name("mov", format);
    bool matroska = av_match_name("matroska", format);
    if (!movie && !matroska) goto done;
    if (matroska && avformat_find_stream_info(file, NULL) < 0) goto done;

    AVStream *video = file->streams[index];
    if (video->codecpar->codec_type != AVMEDIA_TYPE_VIDEO ||
        video->start_time == AV_NOPTS_VALUE ||
        video->time_base.num <= 0 || video->time_base.den <= 0) goto done;

    int64_t origin = video->start_time;
    int64_t declared = video->duration;
    int64_t end = AV_NOPTS_VALUE;
    if (declared > 0 && origin <= INT64_MAX - declared) {
        end = origin + declared;
    } else if (matroska) {
        const AVDictionaryEntry *tag = av_dict_get(video->metadata, "DURATION", NULL, 0);
        int64_t microseconds;
        if (tag && av_parse_time(&microseconds, tag->value, 1) == 0 && microseconds > 0)
            end = av_rescale_q(microseconds, AV_TIME_BASE_Q, video->time_base);
    }
    if (end <= origin) goto done;

    for (unsigned i = 0; i < file->nb_streams; i++)
        if (i != (unsigned)index) file->streams[i]->discard = AVDISCARD_ALL;

    int64_t lead = av_rescale_q(2, (AVRational){1, 1}, video->time_base);
    int64_t seek = FFMAX(origin, av_sat_sub64(end, lead));
    if (av_seek_frame(file, index, seek, AVSEEK_FLAG_BACKWARD) < 0) goto done;

    int64_t last = INT64_MIN;
    int64_t packet_end = INT64_MIN;
    int result;
    size_t packets = 0;
    while ((result = av_read_frame(file, packet)) == 0) {
        if (++packets > 20000) goto done;
        if (packet->stream_index == index) {
            if (packet->pts == AV_NOPTS_VALUE) goto done;
            if (movie && packet->pts >= end) goto done;
            if (matroska && (packet->duration <= 0 || packet->pts > INT64_MAX - packet->duration))
                goto done;
            last = FFMAX(last, packet->pts);
            packet_end = FFMAX(packet_end, av_sat_add64(packet->pts, packet->duration));
        }
        av_packet_unref(packet);
    }
    if (result != AVERROR_EOF || last < seek) goto done;
    if (matroska) {
        // Bound the final seek to a real near-end cluster and resolve the same
        // last-block rounding as a full index.
        if (last > av_sat_add64(end, lead)) goto done;
        end = mp_video_presentation_end(format, video, declared, origin, last, packet_end);
        if (end <= last) goto done;
    }
    *timing = (MPSceneTiming){.valid = 1, .tb_num = video->time_base.num,
                             .tb_den = video->time_base.den, .first_pts = AV_NOPTS_VALUE,
                             .origin = origin, .end = end};
    verified = 1;
done:
    av_packet_free(&packet);
    avformat_close_input(&file);
    return verified;
}
