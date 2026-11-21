#ifndef MPCUT_COPY_PROBE_H
#define MPCUT_COPY_PROBE_H

#include <libavformat/avformat.h>
#include <libavutil/opt.h>

// Unindexed containers may need an audio decoder to identify the sample
// clock. Video eligibility and timestamps use only headers and parsers.
#define MPCUT_PROBE_DECODERS "aac,aac_latm,ac3,eac3,mp2,mp2float,mp3,mp3float,opus,vorbis"

static inline int mpcut_probe_decoder_policy(AVFormatContext *input)
{
    int audio = 0, picture = 0;
    for (unsigned int i = 0; i < input->nb_streams; ++i) {
        AVStream *stream = input->streams[i];
        if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
            stream->discard = AVDISCARD_ALL;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audio = 1;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            picture = 1;
        }
    }
    // Audio files may use any installed audio decoder for format discovery,
    // including PCM variants, FLAC and ALAC. Compressed movie pictures only
    // need headers and parsers during lossless eligibility checks.
    return audio && !picture ? 0 : av_opt_set(input, "codec_whitelist", MPCUT_PROBE_DECODERS, 0);
}

#endif
