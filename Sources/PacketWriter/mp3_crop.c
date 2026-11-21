#include "mp3_crop.h"
#include "../CFFmpeg/copy_probe.h"
#include <libavutil/intreadwrite.h>
#include <stdio.h>
#include <string.h>

// LAME stores encoder delay and end padding as two unsigned 12-bit fields.
// The MPEG audio decoder adds 529 samples to encoder delay and subtracts
// them from end padding. Neither stored field may be clipped by the muxer.
enum { decoder_delay = 529, max_skip = 4095 + decoder_delay };

typedef struct {
    int samples, back_reference, main_bytes, reservoir_limit;
} Layer3Frame;

static int layer3_frame(const AVPacket *packet, int rate, Layer3Frame *frame) {
    static const int rates[] = {44100, 48000, 32000};
    static const int kbps[2][15] = {
        {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
        {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}
    };
    if (packet->size < 4) return 0;
    const uint8_t *data = packet->data;
    int version = (data[1] >> 3) & 3;
    int mpeg1 = version == 3;
    int rate_code = (data[2] >> 2) & 3, bit_rate = data[2] >> 4;
    if (data[0] != 255 || (data[1] & 0xe6) != 0xe2 || version == 1 || rate_code == 3 ||
        bit_rate == 0 || bit_rate == 15 || rate != rates[rate_code] / (mpeg1 ? 1 : version == 2 ? 2 : 4))
        return 0;
    int size = (mpeg1 ? 144000 : 72000) * kbps[mpeg1][bit_rate] / rate + ((data[2] >> 1) & 1);
    int mono = data[3] >> 6 == 3;
    int side_offset = 4 + ((data[1] & 1) ? 0 : 2);
    int side_size = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    if (size != packet->size || size < side_offset + side_size) return 0;
    frame->samples = mpeg1 ? 1152 : 576;
    frame->back_reference = mpeg1 ? AV_RB16(data + side_offset) >> 7 : data[side_offset];
    frame->main_bytes = size - side_offset - side_size;
    frame->reservoir_limit = mpeg1 ? 511 : 255;
    return 1;
}

static int crop_error(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message);
    return 1;
}

static int crop(AVFormatContext *input, int index, AVFormatContext *output,
                int64_t start, int64_t end, MPCutProgress progress, void *context,
                char *error, size_t capacity) {
    if (index < 0 || (unsigned)index >= input->nb_streams || end <= start || start < 0 ||
        strcmp(input->iformat->name, "mp3") || input->streams[index]->codecpar->codec_id != AV_CODEC_ID_MP3)
        return crop_error(error, capacity, "A standalone Layer III track and a positive sample range are required.");
    AVStream *stream = input->streams[index];
    int rate = stream->codecpar->sample_rate;
    if (rate <= 0 || stream->time_base.num <= 0 || stream->time_base.den <= 0)
        return crop_error(error, capacity, "The MP3 source lacks a valid sample clock.");
    AVRational samples = {1, rate};
    AVPacket *packet = av_packet_alloc();
    if (!packet) return crop_error(error, capacity, "Cannot allocate an MP3 packet.");
    int result = 1, available = 0, spf = 0, from_source_head = 0;
    uint64_t seen = 0;
    int64_t next = AV_NOPTS_VALUE, first = 0, stop = 0, stable_after = 0;
    const char *failure = "The MP3 ended before the requested samples.";
    while (av_read_frame(input, packet) >= 0) {
        if (packet->stream_index != index) {
            av_packet_unref(packet);
            continue;
        }
        Layer3Frame frame;
        int64_t pts = av_rescale_q_rnd(packet->pts, stream->time_base, samples,
                                       AV_ROUND_NEAR_INF | AV_ROUND_PASS_MINMAX);
        if (pts == AV_NOPTS_VALUE || (next != AV_NOPTS_VALUE && pts != next) ||
            !layer3_frame(packet, rate, &frame) || (spf && spf != frame.samples) ||
            pts < 0 || pts > INT64_MAX - 2 * 1152) {
            failure = "The MP3 has unsupported framing or a discontinuous sample clock.";
            break;
        }
        spf = frame.samples;
        next = pts + spf;
        if (!seen++) {
            if (pts > start || end > INT64_MAX - 2 * spf) break;
            int64_t distance = start - pts;
            // Include as much original history as the encoder-delay field can hide.
            int64_t offset = distance > max_skip ? (distance - max_skip + spf - 1) / spf : 0;
            first = pts + offset * spf;
            from_source_head = first == pts;
            stable_after = first;
            if (start - first < decoder_delay) {
                failure = "Xing cannot represent the required leading skip at this MP3 cut.";
                break;
            }
            // A standalone MP3 must expose two audio frames for reliable sync.
            stop = FFMAX(first + 2 * spf, pts + ((end - pts + spf - 1) / spf) * spf);
        }
        if (progress && (seen & 255) == 0 && progress(context, (double)pts / (double)stop)) {
            failure = "Export cancelled";
            result = 2;
            break;
        }
        if (pts < first) {
            av_packet_unref(packet);
            continue;
        }
        if (!from_source_head && available < frame.back_reference)
            stable_after = next;
        // After a full valid granule flushes IMDCT overlap, 512 further
        // samples flush the polyphase synthesis bank. A byte reservoir alone
        // cannot guarantee that the first audible sample was decoded faithfully.
        if (!from_source_head && next > start && start - stable_after < 576 + 512) {
            failure = "This MP3 cut needs more decoder history than its Xing encoder-delay field can store.";
            break;
        }
        available = FFMIN(frame.reservoir_limit, available + frame.main_bytes);
        if (output) {
            int is_first = pts == first, is_last = next == stop;
            av_packet_free_side_data(packet);
            if (is_first || is_last) {
                uint8_t *side = av_packet_new_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, 10);
                if (!side) {
                    failure = "Cannot allocate MP3 gapless timing.";
                    break;
                }
                AV_WL32(side, is_first ? start - first : 0);
                AV_WL32(side + 4, is_last ? stop - end : 0);
                side[8] = side[9] = 0;
            }
            packet->pts = packet->dts = pts - first;
            packet->duration = spf;
            packet->stream_index = 0;
            packet->pos = -1;
            av_packet_rescale_ts(packet, samples, output->streams[0]->time_base);
            if (av_interleaved_write_frame(output, packet) < 0) {
                failure = "Cannot write the copied MP3 packet.";
                break;
            }
        }
        av_packet_unref(packet);
        if (next == stop || (!output && next > start &&
                             (from_source_head || available == frame.reservoir_limit) && next >= first + 2 * spf)) {
            result = 0;
            break;
        }
    }
    av_packet_free(&packet);
    if (result) crop_error(error, capacity, failure);
    return result;
}

int mpcut_check_mp3_crop(const char *path, int index, int64_t start, int64_t end,
                         MPCutProgress progress, void *context, char *error, size_t capacity) {
    if (progress && progress(context, 0)) {
        crop_error(error, capacity, "Export cancelled");
        return 2;
    }
    AVFormatContext *input = NULL;
    int result = avformat_open_input(&input, path, NULL, NULL);
    if (result >= 0) result = mpcut_probe_decoder_policy(input);
    if (result >= 0) result = avformat_find_stream_info(input, NULL);
    if (result < 0) {
        avformat_close_input(&input);
        return crop_error(error, capacity, "Cannot open the MP3 source to verify decoder preroll.");
    }
    result = crop(input, index, NULL, start, end, progress, context, error, capacity);
    avformat_close_input(&input);
    return result;
}

int mpcut_write_mp3_crop(AVFormatContext *input, int index, AVFormatContext *output,
                         int64_t start, int64_t end, MPCutProgress progress, void *context,
                         char *error, size_t capacity) {
    return crop(input, index, output, start, end, progress, context, error, capacity);
}
