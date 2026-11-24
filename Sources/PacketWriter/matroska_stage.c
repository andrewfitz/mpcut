#include "PacketWriter.h"

#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/mem.h>
#include <limits.h>
#include <string.h>

static int configure_filter(AVBSFContext **filter, const AVStream *stream,
                            const uint8_t *replacement, size_t size) {
    const AVCodecParameters *codec = stream->codecpar;
    const char *name = codec->codec_id == AV_CODEC_ID_H264 ? "h264_mp4toannexb" : "hevc_mp4toannexb";
    const AVBitStreamFilter *implementation = av_bsf_get_by_name(name);
    if (!implementation) return AVERROR_BSF_NOT_FOUND;
    av_bsf_free(filter);
    int result = av_bsf_alloc(implementation, filter);
    if (result < 0) return result;
    AVBSFContext *context = *filter;
    result = avcodec_parameters_copy(context->par_in, codec);
    if (result < 0) return result;
    if (replacement) {
        if (!size || size > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) return AVERROR_INVALIDDATA;
        uint8_t *bytes = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!bytes) return AVERROR(ENOMEM);
        memcpy(bytes, replacement, size);
        av_free(context->par_in->extradata);
        context->par_in->extradata = bytes;
        context->par_in->extradata_size = (int)size;
    }
    context->time_base_in = stream->time_base;
    return av_bsf_init(context);
}

static int stage_packets(AVFormatContext *input, AVFormatContext *output, AVBSFContext **filter,
                         AVPacket *packet, MPCutProgress progress, void *context) {
    AVStream *source = input->streams[0];
    AVStream *destination = output->streams[0];
    int result;
    while ((result = av_read_frame(input, packet)) >= 0) {
        if (progress && progress(context, 0)) return AVERROR_EXIT;
        size_t size = 0;
        const uint8_t *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
        if (extra) {
            if (!(packet->flags & AV_PKT_FLAG_KEY)) return AVERROR_INVALIDDATA;
            // HEVC's filter ignores packet-side replacement extradata. Restart it
            // from the active MOV sample description, as for the first run.
            result = configure_filter(filter, source, extra, size);
            if (result < 0) return result;
        }
        result = av_bsf_send_packet(*filter, packet);
        if (result < 0) return result;
        result = av_bsf_receive_packet(*filter, packet);
        if (result < 0) return result;
        av_packet_rescale_ts(packet, (*filter)->time_base_out, destination->time_base);
        packet->pos = -1;
        result = av_interleaved_write_frame(output, packet);
        if (result < 0) return result;
    }
    return result == AVERROR_EOF ? av_write_trailer(output) : result;
}

int mpcut_stage_matroska_picture(const char *input_path, const char *output_path,
                                MPCutProgress progress, void *context, char *error, size_t error_capacity) {
    AVFormatContext *input = NULL, *output = NULL;
    AVBSFContext *filter = NULL;
    AVPacket *packet = NULL;
    int result = avformat_open_input(&input, input_path, NULL, NULL);
    if (result < 0) goto cleanup;

    result = AVERROR_INVALIDDATA;
    if (input->nb_streams != 1) goto cleanup;
    AVStream *source = input->streams[0];
    if (source->codecpar->codec_id != AV_CODEC_ID_H264 &&
        source->codecpar->codec_id != AV_CODEC_ID_HEVC) goto cleanup;
    result = configure_filter(&filter, source, NULL, 0);
    if (result < 0) goto cleanup;

    result = avformat_alloc_output_context2(&output, NULL, "matroska", output_path);
    if (result < 0) goto cleanup;
    output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    AVStream *destination = avformat_new_stream(output, NULL);
    packet = av_packet_alloc();
    if (!destination || !packet) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    result = avcodec_parameters_copy(destination->codecpar, filter->par_out);
    if (result < 0) goto cleanup;
    destination->codecpar->codec_tag = 0;
    destination->time_base = source->time_base;
    destination->sample_aspect_ratio = source->sample_aspect_ratio;
    // Keep the fallback block duration at a whole Matroska tick count.
    destination->avg_frame_rate = (AVRational){25, 1};
    result = avio_open(&output->pb, output_path, AVIO_FLAG_WRITE);
    if (result < 0) goto cleanup;
    result = avformat_write_header(output, NULL);
    if (result < 0) goto cleanup;
    result = stage_packets(input, output, &filter, packet, progress, context);

cleanup:
    av_packet_free(&packet);
    av_bsf_free(&filter);
    avformat_close_input(&input);
    if (output) {
        int close_error = avio_closep(&output->pb);
        if (result >= 0) result = close_error;
        avformat_free_context(output);
    }
    if (result == AVERROR_EXIT) return 2;
    if (result < 0) {
        av_strerror(result, error, error_capacity);
        return 1;
    }
    return 0;
}
