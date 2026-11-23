#include "transcript_pcm.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavutil/intfloat.h>
#include <libavutil/intreadwrite.h>
#include <libswresample/swresample.h>

enum { output_rate = 16000, pad_size = 4096, level_window = 320, probe_size = 32, file_buffer = 1 << 20 };

struct MPTranscriptPCM {
    FILE *file;
    SwrContext *resampler;
    SwrContext *downmix;
    AVChannelLayout layout;
    enum AVSampleFormat format;
    int rate, channel;
    int64_t input_position, output_position, output_length;
    // A continuous run of decoded PCM: where its first sample falls on the source
    // clock, exactly and rounded, and the samples received since.
    double run_origin;
    int64_t run_first, run_samples;
    int run_open;
    int16_t *output;
    unsigned output_capacity;
    const uint8_t **input_planes;
    unsigned input_capacity;
    float *mono;
    unsigned mono_capacity;
    float *levels;
    int64_t level_count, level_capacity;
    float level_sum;
    int level_fill;
    // Energy of the default downmix beside each source channel over the same samples.
    double mix_energy, *channel_energy;
    int energy_channels;
    MPProbeCancelled cancelled;
    void *context;
};

void mp_transcript_pcm_close(MPTranscriptPCM *pcm)
{
    if (!pcm) return;
    if (pcm->file) fclose(pcm->file);
    swr_free(&pcm->resampler);
    swr_free(&pcm->downmix);
    av_channel_layout_uninit(&pcm->layout);
    av_free(pcm->output);
    av_free(pcm->mono);
    av_free(pcm->input_planes);
    av_free(pcm->levels);
    av_free(pcm->channel_energy);
    free(pcm);
}

static int open_resampler(MPTranscriptPCM *pcm, int rate)
{
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    swr_free(&pcm->resampler);
    int ret = swr_alloc_set_opts2(&pcm->resampler, &mono, AV_SAMPLE_FMT_S16, output_rate,
                                  &mono, AV_SAMPLE_FMT_FLT, rate, 0, NULL);
    if (ret < 0) return ret;
    pcm->rate = rate;
    return swr_init(pcm->resampler);
}

MPTranscriptPCM *mp_transcript_pcm_open(const char *path, int64_t samples, int rate, int channel)
{
    if (samples < 0 || samples > (UINT32_MAX - 36) / 2 || rate <= 0 || channel < -1) return NULL;
    MPTranscriptPCM *pcm = calloc(1, sizeof(*pcm));
    if (!pcm) return NULL;
    pcm->file = fopen(path, "wb");
    // A frame resamples to a few hundred bytes. Collect them instead of writing each block.
    if (pcm->file) setvbuf(pcm->file, NULL, _IOFBF, file_buffer);
    pcm->channel = channel;
    pcm->output_length = samples;
    pcm->level_capacity = (samples + level_window - 1) / level_window;
    pcm->levels = av_calloc(FFMAX(pcm->level_capacity, 1), sizeof(*pcm->levels));
    if (!pcm->file || !pcm->levels || open_resampler(pcm, rate) < 0) {
        mp_transcript_pcm_close(pcm);
        return NULL;
    }
    uint8_t header[44] = {0};
    memcpy(header, "RIFF", 4);
    AV_WL32(header + 4, (uint32_t)(samples * 2 + 36));
    memcpy(header + 8, "WAVEfmt ", 8);
    AV_WL32(header + 16, 16);
    AV_WL16(header + 20, 1);
    AV_WL16(header + 22, 1);
    AV_WL32(header + 24, output_rate);
    AV_WL32(header + 28, output_rate * 2);
    AV_WL16(header + 32, 2);
    AV_WL16(header + 34, 16);
    memcpy(header + 36, "data", 4);
    AV_WL32(header + 40, (uint32_t)(samples * 2));
    if (fwrite(header, 1, sizeof(header), pcm->file) != sizeof(header)) {
        mp_transcript_pcm_close(pcm);
        return NULL;
    }
    return pcm;
}

// The provider's level frame is the single-precision RMS of each 20 ms window,
// summed in sample order. A fused multiply-add would round the sum differently.
#pragma STDC FP_CONTRACT OFF
static void measure(MPTranscriptPCM *pcm, const int16_t *samples, int count)
{
    float sum = pcm->level_sum;
    int fill = pcm->level_fill;
    for (int i = 0; i < count; i++) {
        const float value = (float)samples[i] / 32768.0f;
        const float square = value * value;
        sum += square;
        if (++fill == level_window) {
            if (pcm->level_count < pcm->level_capacity)
                pcm->levels[pcm->level_count++] = sqrtf(sum / (float)level_window);
            sum = 0;
            fill = 0;
        }
    }
    pcm->level_sum = sum;
    pcm->level_fill = fill;
}

static int write_output(MPTranscriptPCM *pcm, int ready)
{
    int written = (int)FFMIN(ready, pcm->output_length - pcm->output_position);
    if (fwrite(pcm->output, sizeof(*pcm->output), written, pcm->file) != written) return AVERROR(EIO);
    measure(pcm, pcm->output, written);
    pcm->output_position += written;
    return 0;
}

static int append(MPTranscriptPCM *pcm, const float *mono, int frames)
{
    const int capacity = swr_get_out_samples(pcm->resampler, frames);
    if (capacity < 0) return capacity;
    av_fast_malloc(&pcm->output, &pcm->output_capacity, (size_t)capacity * sizeof(*pcm->output));
    if (!pcm->output) return AVERROR(ENOMEM);
    uint8_t *output = (uint8_t *)pcm->output;
    const uint8_t *input = (const uint8_t *)mono;
    int ready = swr_convert(pcm->resampler, &output, capacity, &input, frames);
    if (ready < 0) return ready;
    pcm->input_position += frames;
    return write_output(pcm, ready);
}

static int pad(MPTranscriptPCM *pcm, int64_t target)
{
    static const float zeros[pad_size];
    while (pcm->input_position < target) {
        if (pcm->cancelled && pcm->cancelled(pcm->context)) return AVERROR_EXIT;
        int ret = append(pcm, zeros, (int)FFMIN(pad_size, target - pcm->input_position));
        if (ret < 0) return ret;
    }
    return 0;
}

// A decoder can report its real output rate only with the first frame (implicit
// SBR) or change it part-way. Finish the samples held by the filter, then count
// input at the new rate from the source time already written.
static int change_rate(MPTranscriptPCM *pcm, int rate)
{
    for (;;) {
        const int capacity = swr_get_out_samples(pcm->resampler, 0);
        if (capacity < 0) return capacity;
        if (capacity == 0) break;
        av_fast_malloc(&pcm->output, &pcm->output_capacity, (size_t)capacity * sizeof(*pcm->output));
        if (!pcm->output) return AVERROR(ENOMEM);
        uint8_t *output = (uint8_t *)pcm->output;
        int ready = swr_convert(pcm->resampler, &output, capacity, NULL, 0);
        if (ready < 0) return ready;
        if (ready == 0) break;
        int ret = write_output(pcm, ready);
        if (ret < 0) return ret;
    }
    // Rounding the filter's tail can leave the output short of the input time.
    const int64_t reached = av_rescale_rnd(pcm->input_position, output_rate, pcm->rate, AV_ROUND_DOWN);
    const int64_t target = FFMIN(reached, pcm->output_length);
    while (pcm->output_position < target) {
        if (pcm->cancelled && pcm->cancelled(pcm->context)) return AVERROR_EXIT;
        const int missing = (int)FFMIN(pad_size, target - pcm->output_position);
        av_fast_malloc(&pcm->output, &pcm->output_capacity, (size_t)missing * sizeof(*pcm->output));
        if (!pcm->output) return AVERROR(ENOMEM);
        memset(pcm->output, 0, (size_t)missing * sizeof(*pcm->output));
        int ret = write_output(pcm, missing);
        if (ret < 0) return ret;
    }
    int ret = open_resampler(pcm, rate);
    if (ret < 0) return ret;
    pcm->input_position = av_rescale_rnd(pcm->output_position, rate, output_rate, AV_ROUND_UP);
    pcm->run_open = 0;
    return 0;
}

static double sample_value(enum AVSampleFormat packed, const uint8_t *sample)
{
    switch (packed) {
        case AV_SAMPLE_FMT_U8: return (*sample - 128) / 128.0;
        case AV_SAMPLE_FMT_S16: return (int16_t)AV_RN16(sample) / 32768.0;
        case AV_SAMPLE_FMT_S32: return (int32_t)AV_RN32(sample) / 2147483648.0;
        case AV_SAMPLE_FMT_S64: return (double)(int64_t)AV_RN64(sample) / 9223372036854775808.0;
        case AV_SAMPLE_FMT_FLT: return av_int2float(AV_RN32(sample));
        case AV_SAMPLE_FMT_DBL: return av_int2double(AV_RN64(sample));
        default: return 0;
    }
}

// Opposite-polarity channels cancel throughout a recording, so a fraction of its
// samples shows it. Spread them across the frame: neighbouring samples of a low
// tone are nearly equal and would count as one.
static void probe_downmix(MPTranscriptPCM *pcm, const AVFrame *frame, int64_t skip, int count)
{
    const int channels = pcm->layout.nb_channels;
    if (pcm->channel >= 0 || channels < 2 || pcm->energy_channels < 0) return;
    if (!pcm->channel_energy) {
        pcm->channel_energy = av_calloc(channels, sizeof(*pcm->channel_energy));
        if (!pcm->channel_energy) { pcm->energy_channels = -1; return; }
        pcm->energy_channels = channels;
    }
    // Energies of different layouts cannot be compared channel by channel.
    if (channels != pcm->energy_channels) { pcm->energy_channels = -1; return; }
    const int planar = av_sample_fmt_is_planar(pcm->format);
    const enum AVSampleFormat packed = av_get_packed_sample_fmt(pcm->format);
    const int bytes = av_get_bytes_per_sample(pcm->format);
    const int step = FFMAX(1, count / probe_size);
    for (int i = 0; i < count; i += step) {
        const double mix = pcm->mono[i];
        if (isfinite(mix)) pcm->mix_energy += mix * mix;
        for (int ch = 0; ch < channels; ch++) {
            const uint8_t *sample = planar ? frame->extended_data[ch] + (skip + i) * bytes
                                           : frame->extended_data[0] + ((skip + i) * channels + ch) * bytes;
            const double value = sample_value(packed, sample);
            if (isfinite(value)) pcm->channel_energy[ch] += value * value;
        }
    }
}

int mp_transcript_pcm_cancelled_downmix(const MPTranscriptPCM *pcm)
{
    if (pcm->channel >= 0 || pcm->energy_channels < 2) return -1;
    int strongest = 0;
    double total = 0;
    for (int ch = 0; ch < pcm->energy_channels; ch++) {
        total += pcm->channel_energy[ch];
        if (pcm->channel_energy[ch] > pcm->channel_energy[strongest]) strongest = ch;
    }
    // Averaging n unrelated channels, or one live channel among n silent ones, leaves
    // 1/n of their mean energy. An eighth of that means the channels subtract: for a
    // stereo pair, a correlation below -0.87, which only inverted polarity produces.
    const double mean = total / pcm->energy_channels;
    if (!(mean > 1e-9) || !(pcm->mix_energy * pcm->energy_channels * 8 < mean)) return -1;
    return strongest;
}

const float *mp_transcript_pcm_levels(const MPTranscriptPCM *pcm, int64_t *count)
{
    *count = pcm->level_count;
    return pcm->levels;
}

int mp_transcript_frame(MPTranscriptPCM *pcm, const AVFrame *frame, double start)
{
    if (frame->sample_rate <= 0 || frame->nb_samples < 0 || !isfinite(start) ||
        frame->ch_layout.nb_channels <= 0 || pcm->channel >= frame->ch_layout.nb_channels ||
        fabs(start) > (double)(INT64_MAX / 2) / frame->sample_rate)
        return AVERROR_INVALIDDATA;
    int ret;
    if (frame->sample_rate != pcm->rate && (ret = change_rate(pcm, frame->sample_rate)) < 0) return ret;
    int64_t end = av_rescale_rnd(pcm->output_length, pcm->rate, output_rate, AV_ROUND_UP);
    // Round a run's start to a sample once and count from there. Rounding every
    // frame's time lets a start midway between two samples fall to either side,
    // which inserts a zero or drops a sample between frames that are continuous.
    const double exact = start * pcm->rate;
    if (!pcm->run_open || fabs(exact - (pcm->run_origin + (double)pcm->run_samples)) > 0.5) {
        pcm->run_origin = exact;
        pcm->run_first = llround(exact);
        pcm->run_samples = 0;
        pcm->run_open = 1;
    }
    int64_t first = pcm->run_first + pcm->run_samples;
    pcm->run_samples += frame->nb_samples;
    ret = pad(pcm, FFMIN(first, end));
    if (ret < 0) return ret;
    int64_t skip = pcm->input_position - first;
    int64_t count = FFMIN(frame->nb_samples - skip, end - pcm->input_position);
    if (count <= 0) return 0;

    // The waveform reader accepts a format or layout change part-way, and so does this.
    int layout_changed = pcm->downmix && av_channel_layout_compare(&frame->ch_layout, &pcm->layout);
    if (layout_changed) pcm->energy_channels = -1;
    if (pcm->downmix && (frame->format != pcm->format || layout_changed)) {
        swr_free(&pcm->downmix);
        av_channel_layout_uninit(&pcm->layout);
    }
    if (!pcm->downmix) {
        AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
        if ((ret = av_channel_layout_copy(&pcm->layout, &frame->ch_layout)) < 0) return ret;
        pcm->format = frame->format;
        if (!av_channel_layout_check(&pcm->layout)) return AVERROR_INVALIDDATA;
        if ((ret = swr_alloc_set_opts2(&pcm->downmix, &mono, AV_SAMPLE_FMT_FLT, pcm->rate,
                                       &pcm->layout, pcm->format, pcm->rate, 0, NULL)) < 0) return ret;
        int channels = pcm->layout.nb_channels;
        double *matrix = av_calloc(channels, sizeof(*matrix));
        if (!matrix) return AVERROR(ENOMEM);
        for (int i = 0; i < channels; i++)
            matrix[i] = pcm->channel < 0 ? 1.0 / channels : (i == pcm->channel ? 1.0 : 0.0);
        ret = swr_set_matrix(pcm->downmix, matrix, channels);
        av_free(matrix);
        if (ret < 0 || (ret = swr_init(pcm->downmix)) < 0) return ret;
    }
    int planar = av_sample_fmt_is_planar(pcm->format);
    int planes = planar ? pcm->layout.nb_channels : 1;
    size_t stride = (size_t)av_get_bytes_per_sample(pcm->format) * (planar ? 1 : pcm->layout.nb_channels);
    av_fast_malloc(&pcm->input_planes, &pcm->input_capacity, (size_t)planes * sizeof(*pcm->input_planes));
    if (!pcm->input_planes) return AVERROR(ENOMEM);
    for (int i = 0; i < planes; i++)
        pcm->input_planes[i] = frame->extended_data[i] + skip * stride;
    av_fast_malloc(&pcm->mono, &pcm->mono_capacity, (size_t)count * sizeof(*pcm->mono));
    uint8_t *output = (uint8_t *)pcm->mono;
    ret = output ? swr_convert(pcm->downmix, &output, (int)count, pcm->input_planes, (int)count) : AVERROR(ENOMEM);
    if (ret < 0) return ret;
    if (ret != count) return AVERROR_INVALIDDATA;
    probe_downmix(pcm, frame, skip, ret);
    return append(pcm, pcm->mono, ret);
}

int mp_transcript_pcm_float(MPTranscriptPCM *pcm, const float *samples, int frames, int channels,
                            int rate, double start)
{
    uint8_t *data = (uint8_t *)samples;
    AVFrame frame = {
        .extended_data = &data, .format = AV_SAMPLE_FMT_FLT, .nb_samples = frames, .sample_rate = rate,
    };
    av_channel_layout_default(&frame.ch_layout, channels);
    int ret = mp_transcript_frame(pcm, &frame, start);
    av_channel_layout_uninit(&frame.ch_layout);
    return ret;
}

void mp_transcript_pcm_set_cancel(MPTranscriptPCM *pcm, MPProbeCancelled cancelled, void *context)
{
    pcm->cancelled = cancelled;
    pcm->context = context;
}

int mp_transcript_pcm_finish(MPTranscriptPCM *pcm, MPProbeCancelled cancelled, void *context)
{
    // Feed the filter's tail with silence to preserve the advertised PCM length,
    // including very short excerpts and a track containing no audible samples.
    pcm->cancelled = cancelled;
    pcm->context = context;
    while (pcm->output_position < pcm->output_length) {
        const int ret = pad(pcm, pcm->input_position + pad_size);
        if (ret < 0) return ret;
    }
    if (pcm->level_fill > 0 && pcm->level_count < pcm->level_capacity) {
        pcm->levels[pcm->level_count++] = sqrtf(pcm->level_sum / (float)pcm->level_fill);
        pcm->level_fill = 0;
        pcm->level_sum = 0;
    }
    return fflush(pcm->file) == 0 ? 0 : AVERROR(EIO);
}
