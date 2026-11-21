#include "audio_envelope.h"
#include "wave_pcm.h"
#include <Accelerate/Accelerate.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/cpu.h>
#include <math.h>

// Keep channels separate. Opposite-phase stereo must still register as sound.
static float plane_peak(enum AVSampleFormat format, const uint8_t *data, int count)
{
    float peak = 0;
    switch (format) {
        case AV_SAMPLE_FMT_FLT:
            vDSP_maxmgv((const float *)data, 1, &peak, count);
            return peak;
        case AV_SAMPLE_FMT_DBL: {
            double value;
            vDSP_maxmgvD((const double *)data, 1, &value, count);
            return (float)value;
        }
        // Integer min/max reductions vectorize without converting each PCM
        // sample to float. Convert the minimum before negating it (INT_MIN).
        case AV_SAMPLE_FMT_U8: {
            uint8_t low = 128, high = 128;
            for (int i = 0; i < count; i++) {
                if (data[i] < low) low = data[i];
                if (data[i] > high) high = data[i];
            }
            return fmaxf(128 - low, high - 128) / 128;
        }
        case AV_SAMPLE_FMT_S16: {
            const int16_t *samples = (const int16_t *)data;
            int16_t low = 0, high = 0;
            for (int i = 0; i < count; i++) {
                if (samples[i] < low) low = samples[i];
                if (samples[i] > high) high = samples[i];
            }
            return fmaxf(-(float)low, high) / 32768;
        }
        case AV_SAMPLE_FMT_S32: {
            const int32_t *samples = (const int32_t *)data;
            int32_t low = 0, high = 0;
            for (int i = 0; i < count; i++) {
                if (samples[i] < low) low = samples[i];
                if (samples[i] > high) high = samples[i];
            }
            return fmaxf(-(float)low, (float)high) / 2147483648.0f;
        }
        case AV_SAMPLE_FMT_S64: {
            const int64_t *samples = (const int64_t *)data;
            int64_t low = 0, high = 0;
            for (int i = 0; i < count; i++) {
                if (samples[i] < low) low = samples[i];
                if (samples[i] > high) high = samples[i];
            }
            return fmaxf(-(float)low, (float)high) / 9223372036854775808.0f;
        }
        default: return -1;
    }
}

static int peaks(uint8_t *const *planes, enum AVSampleFormat sample_format, int frames, int channels,
                 int rate, double start, double duration, MPPeakVisit visit, void *context)
{
    if (rate <= 0 || channels <= 0 || !isfinite(start))
        return AVERROR_INVALIDDATA;
    if (start >= duration || start + (double)frames / rate <= 0) return 0;
    const int planar = av_sample_fmt_is_planar(sample_format);
    const int stride = planar ? 1 : channels;
    const int bytes = av_get_bytes_per_sample(sample_format);
    const enum AVSampleFormat format = av_get_packed_sample_fmt(sample_format);
    for (int i = (int)fmax(0, ceil(-start * rate)); i < frames;) {
        double time = start + (double)i / rate;
        if (time >= duration) break;
        int64_t bin = (int64_t)floor(time * MP_PEAK_RATE + 1e-9);
        double next = fmin(duration, (double)(bin + 1) / MP_PEAK_RATE);
        int end = (int)fmin(frames, fmax(i + 1, ceil((next - start) * rate - 1e-7)));
        float maximum = 0;
        for (int ch = 0; ch < (planar ? channels : 1); ch++) {
            float value = plane_peak(format, planes[ch] + (size_t)i * stride * bytes,
                                     (end - i) * stride);
            if (value < 0) return AVERROR_INVALIDDATA;
            // Float PCM can carry Inf or NaN. Show it as full scale.
            if (!isfinite(value)) value = 1;
            maximum = fmaxf(maximum, value);
        }
        visit(context, bin, maximum);
        i = end;
    }
    return 0;
}

static int read_wave_packet(AVIOContext *io, AVPacket *packet, int64_t *sample, int64_t end, int align)
{
    if (*sample >= end) return AVERROR_EOF;
    const int frames = (int)FFMIN(end - *sample, FFMAX(1, 65536 / align));
    const int bytes = frames * align;
    int read = av_get_packet(io, packet, bytes);
    if (read == AVERROR_EOF) return AVERROR_INVALIDDATA;
    if (read < 0) return read;
    if (read != bytes) return AVERROR_INVALIDDATA;
    packet->pts = packet->dts = *sample;
    packet->duration = frames;
    packet->stream_index = 0;
    *sample += frames;
    return 0;
}

int mp_float_pcm_peaks(const float *samples, int frames, int channels, int rate,
                       double start, double duration, MPPeakVisit visit, void *context)
{
    uint8_t *plane = (uint8_t *)samples;
    return peaks(&plane, AV_SAMPLE_FMT_FLT, frames, channels, rate, start, duration, visit, context);
}

static int read_peaks(const char *path, int stream, double origin, double duration, MPAudioEnvelope *window, int seek,
                   MPProbeCancelled cancelled, MPPeakVisit visit, void *context,
                   char *error, size_t capacity)
{
    AVFormatContext *input = avformat_alloc_context();
    AVCodecContext *decoder = NULL;
    AVFrame *frame = NULL;
    AVPacket *packet = NULL;
    int retry_from_start = 0;
    int ret = AVERROR(ENOMEM);
    if (!input) goto done;
    input->interrupt_callback = (AVIOInterruptCB){.callback = cancelled, .opaque = context};
    if (cancelled(context)) { ret = AVERROR_EXIT; goto done; }
    ret = avformat_open_input(&input, path, NULL, NULL);
    if (ret < 0) goto done;
    // MOV and Matroska usually describe the audio decoder in the header.
    // Probe packets only when a demuxer still needs to discover the stream.
    const AVCodecParameters *params = stream >= 0 && stream < input->nb_streams
        ? input->streams[stream]->codecpar : NULL;
    if (!params || params->codec_id == AV_CODEC_ID_NONE || params->sample_rate <= 0 ||
        params->ch_layout.nb_channels <= 0) {
        if ((ret = avformat_find_stream_info(input, NULL)) < 0) goto done;
    }
    if (stream < 0 || stream >= input->nb_streams ||
        input->streams[stream]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        ret = AVERROR_STREAM_NOT_FOUND;
        goto done;
    }
    for (unsigned i = 0; i < input->nb_streams; i++)
        if (i != stream) input->streams[i]->discard = AVDISCARD_ALL;
    AVStream *audio = input->streams[stream];
    const AVCodec *codec = avcodec_find_decoder(audio->codecpar->codec_id);
    if (!codec) { ret = AVERROR_DECODER_NOT_FOUND; goto done; }
    decoder = avcodec_alloc_context3(codec);
    frame = av_frame_alloc();
    packet = av_packet_alloc();
    if (!decoder || !frame || !packet) { ret = AVERROR(ENOMEM); goto done; }
    if ((ret = avcodec_parameters_to_context(decoder, audio->codecpar)) < 0) goto done;
    decoder->pkt_timebase = audio->time_base;
    // FLAC frames are independently decodable. FFmpeg schedules workers and
    // returns PCM in presentation order to the existing peak/envelope reducer.
    if (audio->codecpar->codec_id == AV_CODEC_ID_FLAC &&
        (window ? window->to - window->from : duration) >= 60)
        decoder->thread_count = FFMIN(8, av_cpu_count());
    if ((ret = avcodec_open2(decoder, codec, NULL)) < 0) goto done;
    const double timestamp_tick = av_q2d(audio->time_base);
    const int coarse_clock = (int64_t)audio->time_base.num * decoder->sample_rate > audio->time_base.den;
    int64_t wave_start, wave_sample = 0, wave_end = 0;
    const int wave_align = seek && window && window->from > 0 && origin == 0 ?
        mp_wave_pcm_layout(input, &wave_start) : 0;
    if (wave_align) {
        // Read an extra sample on the left for sub-sample columns. Assign
        // packet timestamps on the same sample clock as the WAV demuxer.
        const int rate = audio->codecpar->sample_rate;
        const double first = fmax(0, floor(window->from * rate) - 1);
        const double end = ceil(window->to * rate);
        wave_sample = first < (double)audio->duration ? (int64_t)first : audio->duration;
        wave_end = end < (double)audio->duration ? (int64_t)end : audio->duration;
        int64_t position = wave_start + wave_sample * wave_align;
        if (avio_seek(input->pb, position, SEEK_SET) != position) {
            retry_from_start = 1;
            goto done;
        }
    }
    // Indexed formats seek directly. FFmpeg's generic packet index can walk raw
    // MPEG/ADTS without decoding the preceding audio. Leave fast/bitrate-based
    // seeking disabled so VBR MP3's approximate Xing TOC isn't used as a clock.
    // With samples finer than the container clock, a seek loses
    // the continuous sample position carried forward from the first frame.
    if (!wave_align && seek && window && !coarse_clock && window->from > 2 &&
        input->pb && (input->pb->seekable & AVIO_SEEKABLE_NORMAL)) {
        const double seconds = origin + window->from - 1; // Decoder preroll for AAC/Opus.
        if (seconds > (double)INT64_MIN / AV_TIME_BASE && seconds < (double)INT64_MAX / AV_TIME_BASE) {
            int64_t target = av_rescale_q(llround(seconds * AV_TIME_BASE), AV_TIME_BASE_Q, audio->time_base);
            if (av_seek_frame(input, stream, target, AVSEEK_FLAG_BACKWARD) < 0) {
                // A demuxer may advance to EOF during a failed seek. Reopen rather
                // than treating the requested interval as silence.
                retry_from_start = 1;
                goto done;
            }
        }
    }
    double run_start = NAN;
    int64_t run_samples = 0;
    int run_rate = 0;
    // A damaged packet leaves its interval unobserved. The scan still fails
    // when damage is all it found.
    int decoded = 0, damaged = 0;

    for (;;) {
        if (cancelled(context)) { ret = AVERROR_EXIT; break; }
        ret = wave_align ? read_wave_packet(input->pb, packet, &wave_sample, wave_end, wave_align)
                         : av_read_frame(input, packet);
        int eof = ret == AVERROR_EOF;
        if (!eof && ret < 0) break;
        if (!eof && packet->stream_index != stream) { av_packet_unref(packet); continue; }
        ret = avcodec_send_packet(decoder, eof ? NULL : packet);
        av_packet_unref(packet);
        if (ret == AVERROR_INVALIDDATA && !eof) { damaged++; ret = 0; }
        if (ret < 0) break;
        int failures = 0;
        for (;;) {
            ret = avcodec_receive_frame(decoder, frame);
            // The decoder has dropped the packet it could not decode.
            if (ret == AVERROR_INVALIDDATA && ++failures <= 64) { damaged++; continue; }
            if (ret < 0) break;
            failures = 0;
            if (frame->best_effort_timestamp == AV_NOPTS_VALUE) damaged++;
            else {
                decoded++;
                double start = frame->best_effort_timestamp * timestamp_tick - origin;
                // A millisecond container clock can round neighboring PCM blocks in opposite
                // directions. Keep a sample-continuous clock within its timestamp precision.
                // On an exact sample clock even a one-sample gap is meaningful.
                if (coarse_clock) {
                    const int rate = frame->sample_rate;
                    if (rate <= 0) { ret = AVERROR_INVALIDDATA; goto done; }
                    const double next_time = run_start + (double)run_samples / rate;
                    if (rate == run_rate && fabs(start - next_time) <= timestamp_tick + 0.5 / rate) {
                        start = next_time;
                    } else {
                        run_start = start;
                        run_rate = rate;
                        run_samples = 0;
                    }
                    run_samples += frame->nb_samples;
                }
                if (window) {
                    if (start >= window->to) { ret = 0; goto done; }
                    ret = mp_envelope_frame(frame->extended_data, frame->format, frame->nb_samples,
                                            frame->ch_layout.nb_channels, frame->sample_rate, start, window);
                } else {
                    ret = peaks(frame->extended_data, frame->format, frame->nb_samples,
                                frame->ch_layout.nb_channels, frame->sample_rate, start, duration, visit, context);
                }
            }
            av_frame_unref(frame);
            if (ret < 0) break;
        }
        if (ret == AVERROR_EOF || (eof && ret == AVERROR(EAGAIN))) { ret = 0; break; }
        if (ret != AVERROR(EAGAIN)) break;
    }
    if (ret == 0 && damaged && !decoded) ret = AVERROR_INVALIDDATA;
done:
    if (ret < 0) av_strerror(ret, error, capacity);
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&decoder);
    avformat_close_input(&input);
    if (retry_from_start)
        return read_peaks(path, stream, origin, duration, window, 0, cancelled, visit, context, error, capacity);
    return ret;
}

int mp_audio_peaks(const char *path, int stream, double origin, double duration,
                   MPProbeCancelled cancelled, MPPeakVisit visit, void *context,
                   char *error, size_t capacity)
{
    return read_peaks(path, stream, origin, duration, NULL, 0, cancelled, visit, context, error, capacity);
}

int mp_audio_envelope(const char *path, int stream, double origin, MPAudioEnvelope *window,
                      MPProbeCancelled cancelled, void *context, char *error, size_t capacity)
{
    return read_peaks(path, stream, origin, window->to, window, 1, cancelled, NULL, context, error, capacity);
}
