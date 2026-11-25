#include "timecode.h"

#include <limits.h>

#include <libavutil/intreadwrite.h>

typedef __int128 Wide;

enum {
    MOV_TIMECODE_DROP_FRAME = 1,
    MOV_TIMECODE_WRAP_24_HOURS = 2,
    MOV_TIMECODE_ALLOW_NEGATIVE = 4
};

int mpcut_timecode_describe(const AVStream *track, const AVStream *video, MPCutTimecode *timecode)
{
    const AVCodecParameters *codec = track->codecpar;
    if (codec->extradata_size < 18 || !codec->extradata || !video
        || track->time_base.num <= 0 || track->time_base.den <= 0) {
        return AVERROR_INVALIDDATA;
    }
    const uint8_t *description = codec->extradata;
    unsigned flags = AV_RB32(description + 4);
    unsigned timescale = AV_RB32(description + 8);
    unsigned frame_duration = AV_RB32(description + 12);
    unsigned nominal = description[16];

    const unsigned supported_flags = MOV_TIMECODE_DROP_FRAME | MOV_TIMECODE_WRAP_24_HOURS
                                   | MOV_TIMECODE_ALLOW_NEGATIVE;
    if (flags & ~supported_flags || !timescale || timescale > INT_MAX
        || !frame_duration || frame_duration > INT_MAX || !nominal) {
        return AVERROR_INVALIDDATA;
    }
    av_reduce(&timecode->rate.num, &timecode->rate.den, timescale, frame_duration, INT_MAX);
    AVRational video_rate = video->avg_frame_rate;
    if (video_rate.num <= 0 || video_rate.den <= 0)
        video_rate = video->r_frame_rate;
    if (video_rate.num <= 0 || video_rate.den <= 0 || av_cmp_q(video_rate, timecode->rate)
        || video->time_base.den <= 0)
        return AVERROR_INVALIDDATA;
    int64_t output_timescale = video->time_base.den / av_gcd(video->time_base.den, timecode->rate.num)
                               * timecode->rate.num;
    if (output_timescale > INT_MAX || output_timescale / timecode->rate.num * timecode->rate.den > INT_MAX)
        return AVERROR_INVALIDDATA;
    timecode->output_timescale = (int)output_timescale;

    unsigned fps = (timescale + frame_duration / 2U) / frame_duration;
    if (!fps || fps > 255
        || ((flags & MOV_TIMECODE_DROP_FRAME)
            && (fps % 30 || (Wide)timescale * 1001 != (Wide)frame_duration * fps * 1000)))
        return AVERROR_INVALIDDATA;
    /* Some cameras store one count per field pair, while older fractional-rate
     * files round the declared nominal rate down. Match the MOV demuxer here. */
    if (nominal == timescale / frame_duration)
        nominal = fps;
    if (fps % nominal)
        return AVERROR_INVALIDDATA;
    timecode->fps = fps;
    timecode->frames_per_count = fps / nominal;
    timecode->flags = ((flags & MOV_TIMECODE_DROP_FRAME) ? AV_TIMECODE_FLAG_DROPFRAME : 0)
                    | ((flags & MOV_TIMECODE_WRAP_24_HOURS) ? AV_TIMECODE_FLAG_24HOURSMAX : 0)
                    | ((flags & MOV_TIMECODE_ALLOW_NEGATIVE) ? AV_TIMECODE_FLAG_ALLOWNEGATIVE : 0);
    return 0;
}

static int format_value(const AVPacket *packet, Wide tick_offset, Wide clock_denominator,
                        const MPCutTimecode *timecode, MPCutTime duration, char value[AV_TIMECODE_STR_SIZE])
{
    Wide frame_number;
    if (__builtin_mul_overflow(tick_offset, timecode->rate.num, &frame_number))
        return AVERROR_INVALIDDATA;
    Wide frame_denominator = clock_denominator * timecode->rate.den;
    Wide length_numerator = (Wide)duration.numerator * timecode->rate.num;
    Wide length_denominator = (Wide)duration.denominator * timecode->rate.den;
    if (packet->size != 4 || frame_number % frame_denominator || length_numerator % length_denominator)
        return AVERROR_INVALIDDATA;

    uint32_t sample = AV_RB32(packet->data);
    if (sample > INT32_MAX)
        return AVERROR_INVALIDDATA;
    Wide first = (Wide)sample * timecode->frames_per_count + frame_number / frame_denominator;
    Wide end = first + length_numerator / length_denominator;
    if (timecode->flags & AV_TIMECODE_FLAG_24HOURSMAX) {
        int frames_per_day = timecode->fps * 24 * 3600;
        if (timecode->flags & AV_TIMECODE_FLAG_DROPFRAME)
            frames_per_day -= (timecode->fps / 30 * 2) * (24 * 60 - 24 * 6);
        first %= frames_per_day;
        end = first + length_numerator / length_denominator;
        /* The MOV muxer can emit drop-frame timecode, but cannot set the 24-hour wrap flag. */
        if (end > frames_per_day)
            return AVERROR_INVALIDDATA;
    }
    if (first < 0 || end > INT_MAX || end <= first)
        return AVERROR_INVALIDDATA;

    AVTimecode tc;
    int result = av_timecode_init(&tc, timecode->rate, timecode->flags, (int)first, NULL);
    if (result < 0)
        return result;
    av_timecode_make_string(&tc, value, 0);
    /* Verify that the muxer's string parser can encode this frame number. */
    result = av_timecode_init_from_string(&tc, timecode->rate, value, NULL);
    return result < 0 ? result : tc.start == first ? 0 : AVERROR_INVALIDDATA;
}

int mpcut_timecode_read(const AVFormatContext *source, unsigned stream_index, const MPCutTimecode *timecode,
                       MPCutTime start, MPCutTime duration, MPCutProgress progress, void *context,
                       double fraction, char value[AV_TIMECODE_STR_SIZE])
{
    if (start.denominator <= 0 || duration.denominator <= 0)
        return AVERROR_INVALIDDATA;
    AVFormatContext *reader = NULL;
    AVPacket *packet = av_packet_alloc();
    if (!packet)
        return AVERROR(ENOMEM);
    int result = avformat_open_input(&reader, source->url, source->iformat, NULL);
    if (result < 0)
        goto cleanup;
    if (stream_index >= reader->nb_streams || reader->streams[stream_index]->codecpar->codec_tag != MPCUT_TIMECODE_TAG) {
        result = AVERROR_INVALIDDATA;
        goto cleanup;
    }
    AVRational base = reader->streams[stream_index]->time_base;
    if (base.num <= 0 || base.den <= 0) {
        result = AVERROR_INVALIDDATA;
        goto cleanup;
    }

    Wide tick_numerator = (Wide)start.numerator * base.den;
    Wide tick_denominator = (Wide)start.denominator * base.num;
    Wide target = tick_numerator / tick_denominator;
    Wide remainder = tick_numerator % tick_denominator;
    if (remainder < 0) {
        target--;
        remainder += tick_denominator;
    }
    if (target > INT64_MAX || target <= INT64_MIN) {
        result = AVERROR_INVALIDDATA;
        goto cleanup;
    }
    int seek = target > 0;
    for (;;) {
        if (seek && av_seek_frame(reader, stream_index, (int64_t)target, AVSEEK_FLAG_BACKWARD) < 0)
            goto restart;
        while ((result = av_read_frame(reader, packet)) >= 0) {
            if (progress && progress(context, fraction)) {
                result = AVERROR_EXIT;
                goto cleanup;
            }
            if ((unsigned)packet->stream_index == stream_index && packet->pts != AV_NOPTS_VALUE) {
                Wide offset_ticks = target - packet->pts;
                if (offset_ticks < 0)
                    break;
                if (offset_ticks < packet->duration) {
                    Wide offset;
                    if (__builtin_mul_overflow(offset_ticks, tick_denominator, &offset)
                        || __builtin_add_overflow(offset, remainder, &offset)) {
                        result = AVERROR_INVALIDDATA;
                        goto cleanup;
                    }
                    result = format_value(packet, offset, (Wide)start.denominator * base.den,
                                          timecode, duration, value);
                    goto cleanup;
                }
            }
            av_packet_unref(packet);
        }
        if (!seek || (result < 0 && result != AVERROR_EOF))
            break;
    restart:
        /* A seek can land after the active timecode sample if the demuxer
         * indexes it on a different clock. Confirm coverage from the start. */
        seek = 0;
        av_packet_unref(packet);
        avformat_close_input(&reader);
        result = avformat_open_input(&reader, source->url, source->iformat, NULL);
        if (result < 0)
            goto cleanup;
    }
    if (result == AVERROR_EOF || result >= 0)
        result = AVERROR_INVALIDDATA;

cleanup:
    av_packet_free(&packet);
    avformat_close_input(&reader);
    return result;
}

int mpcut_timecode_breaks(const char *url, unsigned stream_index, const MPCutTimecode *timecode,
                          MPCutTime from, MPCutTime to)
{
    if (from.denominator <= 0 || to.denominator <= 0)
        return 0;
    AVFormatContext *reader = NULL;
    AVPacket *packet = av_packet_alloc();
    int breaks = 0;
    if (!packet || avformat_open_input(&reader, url, NULL, NULL) < 0 || stream_index >= reader->nb_streams)
        goto cleanup;
    AVRational base = reader->streams[stream_index]->time_base;
    if (base.num <= 0 || base.den <= 0)
        goto cleanup;
    for (unsigned i = 0; i < reader->nb_streams; i++) {
        if (i != stream_index)
            reader->streams[i]->discard = AVDISCARD_ALL;
    }
    int have = 0;
    int64_t previous_pts = 0;
    Wide previous_frame = 0;
    while (av_read_frame(reader, packet) >= 0) {
        if ((unsigned)packet->stream_index == stream_index && packet->size == 4 && packet->pts != AV_NOPTS_VALUE) {
            Wide frame = (Wide)AV_RB32(packet->data) * timecode->frames_per_count;
            if (have) {
                /* A later sample that does not continue the count of the one before it is a break. */
                Wide numerator = (Wide)(packet->pts - previous_pts) * base.num * timecode->rate.num;
                Wide denominator = (Wide)base.den * timecode->rate.den;
                int continuous = denominator > 0 && numerator % denominator == 0
                                 && previous_frame + numerator / denominator == frame;
                Wide at = (Wide)packet->pts * base.num;
                int inside = at * from.denominator > (Wide)from.numerator * base.den
                             && at * to.denominator < (Wide)to.numerator * base.den;
                if (!continuous && inside)
                    breaks++;
            }
            have = 1;
            previous_pts = packet->pts;
            previous_frame = frame;
        }
        av_packet_unref(packet);
    }

cleanup:
    av_packet_free(&packet);
    avformat_close_input(&reader);
    return breaks;
}
