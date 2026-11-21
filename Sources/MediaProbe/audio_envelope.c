#include "audio_envelope.h"
#include <Accelerate/Accelerate.h>
#include <float.h>
#include <libavutil/error.h>
#include <math.h>

static int plane_extrema(enum AVSampleFormat format, const uint8_t *data, int count,
                         float *low, float *high)
{
    // Integer comparisons vectorize without allocating or converting a PCM buffer.
#define INTEGER_EXTREMA(type, midpoint, divisor) do { \
    const type *p = (const type *)data; \
    type minimum = p[0], maximum = p[0]; \
    for (int i = 1; i < count; ++i) { \
        if (p[i] < minimum) minimum = p[i]; \
        if (p[i] > maximum) maximum = p[i]; \
    } \
    *low = ((float)minimum - midpoint) / divisor; \
    *high = ((float)maximum - midpoint) / divisor; \
    return 0; \
} while (0)
    switch (format) {
        case AV_SAMPLE_FMT_U8: INTEGER_EXTREMA(uint8_t, 128.f, 0x1p7f);
        case AV_SAMPLE_FMT_S16: INTEGER_EXTREMA(int16_t, 0.f, 0x1p15f);
        case AV_SAMPLE_FMT_S32: INTEGER_EXTREMA(int32_t, 0.f, 0x1p31f);
        case AV_SAMPLE_FMT_S64: INTEGER_EXTREMA(int64_t, 0.f, 0x1p63f);
        case AV_SAMPLE_FMT_FLT:
            vDSP_minv((const float *)data, 1, low, count);
            vDSP_maxv((const float *)data, 1, high, count);
            break;
        case AV_SAMPLE_FMT_DBL: {
            double minimum, maximum;
            vDSP_minvD((const double *)data, 1, &minimum, count);
            vDSP_maxvD((const double *)data, 1, &maximum, count);
            *low = (float)minimum;
            *high = (float)maximum;
            break;
        }
        default: return AVERROR_INVALIDDATA;
    }
#undef INTEGER_EXTREMA
    if (!isfinite(*low)) *low = isnan(*low) ? 0 : copysignf(FLT_MAX, *low);
    if (!isfinite(*high)) *high = isnan(*high) ? 0 : copysignf(FLT_MAX, *high);
    return 0;
}

static int column(const MPAudioEnvelope *w, double time, int upper)
{
    double position = (time - w->from) / (w->to - w->from) * w->columns;
    double integral = nearbyint(position);
    if (fabs(position - integral) < 1e-7) position = integral;
    return (int)fmax(0, fmin(w->columns, upper ? ceil(position) : floor(position)));
}

void mp_envelope_silence(MPAudioEnvelope *w, double from, double to)
{
    if (to <= from) return;
    int end = column(w, to, 1);
    for (int i = column(w, from, 0); i < end; i++) {
        w->low[i] = fminf(w->low[i], 0);
        w->high[i] = fmaxf(w->high[i], 0);
    }
}

int mp_envelope_frame(uint8_t *const *planes, enum AVSampleFormat sample_format,
                      int frames, int channels, int rate, double start, MPAudioEnvelope *w)
{
    if (rate <= 0 || channels <= 0 || !isfinite(start)) return AVERROR_INVALIDDATA;
    const double end = start + (double)frames / rate;
    if (frames == 0 || start >= w->to || end <= w->from) return 0;
    if (start - w->through > 0.5 / rate) mp_envelope_silence(w, w->through, start);
    w->through = fmax(w->through, end);
    int first = column(w, start, 0), last = column(w, end, 1);
    const int planar = av_sample_fmt_is_planar(sample_format);
    const int stride = planar ? 1 : channels;
    const int bytes = av_get_bytes_per_sample(sample_format);
    const enum AVSampleFormat format = av_get_packed_sample_fmt(sample_format);
    if (bytes <= 0) return AVERROR_INVALIDDATA;
    const double samples_per_column = (w->to - w->from) * rate / w->columns;
    const double offset = (w->from - start) * rate;
    for (int i = first; i < last; i++) {
        const double left = ceil(fma(i, samples_per_column, offset) - 1e-7);
        const double right = ceil(fma(i + 1, samples_per_column, offset) - 1e-7);
        int a = (int)fmin(frames, fmax(0, left));
        int b = (int)fmin(frames, fmax(0, right));
        // Hold the preceding sample only when the column contains no sample
        // on the PCM clock. A sample in the next frame still owns the column.
        if (a == b) {
            if (left != right || left < 1 || left > frames) continue;
            a--;
        }
        for (int ch = 0; ch < (planar ? channels : 1); ch++) {
            float low, high;
            int status = plane_extrema(format, planes[ch] + (size_t)a * stride * bytes,
                                       (b - a) * stride, &low, &high);
            if (status < 0) return status;
            w->low[i] = fminf(w->low[i], low);
            w->high[i] = fmaxf(w->high[i], high);
        }
    }
    return 0;
}

int mp_float_pcm_envelope(const float *samples, int frames, int channels, int rate,
                          double start, MPAudioEnvelope *window)
{
    uint8_t *plane = (uint8_t *)samples;
    return mp_envelope_frame(&plane, AV_SAMPLE_FMT_FLT, frames, channels, rate, start, window);
}
