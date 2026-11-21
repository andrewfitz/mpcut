#ifndef MPCUT_WAVE_PCM_H
#define MPCUT_WAVE_PCM_H

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>

/* Right after opening WAVE, FFmpeg positions AVIO at the first PCM byte.
 * Accept one complete packed PCM chunk, optionally followed by a pad byte.
 * The codec, block alignment, and duration must all agree with that extent. */
static inline int mp_wave_pcm_layout(AVFormatContext *file, int64_t *start)
{
    if (file->nb_streams != 1 || !av_match_name("wav", file->iformat->name) ||
        !file->pb || !(file->pb->seekable & AVIO_SEEKABLE_NORMAL))
        return 0;
    const AVStream *stream = file->streams[0];
    const AVCodecParameters *codec = stream->codecpar;
    switch (codec->codec_id) {
        case AV_CODEC_ID_PCM_U8:
        case AV_CODEC_ID_PCM_S16LE: case AV_CODEC_ID_PCM_S16BE:
        case AV_CODEC_ID_PCM_S24LE: case AV_CODEC_ID_PCM_S24BE:
        case AV_CODEC_ID_PCM_S32LE: case AV_CODEC_ID_PCM_S32BE:
        case AV_CODEC_ID_PCM_S64LE: case AV_CODEC_ID_PCM_S64BE:
        case AV_CODEC_ID_PCM_F32LE: case AV_CODEC_ID_PCM_F32BE:
        case AV_CODEC_ID_PCM_F64LE: case AV_CODEC_ID_PCM_F64BE:
            break;
        default:
            return 0;
    }
    const int64_t align = av_get_exact_bits_per_sample(codec->codec_id) / 8 *
                          (int64_t)codec->ch_layout.nb_channels;
    if (align <= 0 || align != codec->block_align ||
        codec->sample_rate <= 0 || stream->time_base.num != 1 ||
        stream->time_base.den != codec->sample_rate ||
        (stream->start_time != AV_NOPTS_VALUE && stream->start_time != 0) ||
        codec->initial_padding || codec->trailing_padding || codec->seek_preroll ||
        stream->duration <= 0 || stream->duration > INT64_MAX / align)
        return 0;
    const int64_t payload = stream->duration * align;
    const int64_t offset = avio_tell(file->pb);
    const int64_t size = avio_size(file->pb);
    if (offset < 0 || size < offset || payload > size - offset ||
        size - offset - payload > (payload & 1))
        return 0;
    *start = offset;
    return (int)align;
}

#endif
