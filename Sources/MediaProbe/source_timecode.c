#include "MediaProbe.h"
#include "../CFFmpeg/copy_probe.h"

#include <errno.h>
#include <stdlib.h>
#include <libavformat/avformat.h>
#include <libavutil/timecode.h>

// Source timecode lives in media metadata, independently of presentation PTS.
// Read it directly, including for projects with older analysis sidecars.
int mp_source_sync_stamp(const char *path, int stream, int rate_num, int rate_den,
                         int64_t *units, int *scale_num, int *scale_den)
{
    AVFormatContext *input = NULL;
    int status = avformat_open_input(&input, path, NULL, NULL);
    if (status < 0)
        return status;

    // MPEG program streams discover tracks while reading packets.
    if (stream >= 0 && (unsigned)stream >= input->nb_streams) {
        status = mpcut_probe_decoder_policy(input);
        if (status < 0)
            goto done;
        status = avformat_find_stream_info(input, NULL);
        if (status < 0)
            goto done;
    }
    if (stream < 0 || (unsigned)stream >= input->nb_streams) {
        status = AVERROR_INVALIDDATA;
        goto done;
    }
    status = 0;
    AVStream *track = input->streams[stream];
    const AVDictionaryEntry *tag = av_dict_get(track->metadata, "timecode", NULL, 0);
    if (!tag)
        tag = av_dict_get(input->metadata, "timecode", NULL, 0);
    if (tag && rate_num > 0 && rate_den > 0) {
        AVTimecode tc;
        status = av_timecode_init_from_string(&tc, (AVRational){rate_num, rate_den}, tag->value, input);
        if (status >= 0) {
            *units = tc.start;
            *scale_num = rate_den;
            *scale_den = rate_num;
            status = MP_SOURCE_SYNC_TIMECODE;
        }
    } else if (track->codecpar->sample_rate > 0 &&
               (tag = av_dict_get(input->metadata, "time_reference", NULL, 0))) {
        char *end;
        errno = 0;
        int64_t reference = strtoll(tag->value, &end, 10);
        if (end == tag->value || *end || errno) {
            status = AVERROR_INVALIDDATA;
            goto done;
        }
        *units = reference;
        *scale_num = 1;
        *scale_den = track->codecpar->sample_rate;
        status = MP_SOURCE_SYNC_BWF;
    }

done:
    avformat_close_input(&input);
    return status;
}

int mp_source_timecode(const char *path, int stream, int rate_num, int rate_den,
                       int64_t *units, int *scale_num, int *scale_den)
{
    int status = mp_source_sync_stamp(path, stream, rate_num, rate_den, units, scale_num, scale_den);
    return status > 0 ? 0 : status;
}
