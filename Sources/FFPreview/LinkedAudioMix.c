#include "LinkedAudioMix.h"
#include "MPProgramMixPCM.h"

#include <AudioToolbox/AudioToolbox.h>
#include <libswresample/swresample.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <math.h>

// Each track keeps an independent demux cursor. One packet of lookahead per
// track lets us mix overlapping PCM at its presentation time without buffering
// an entire gap while waiting for a later-starting track.
enum { mix_rate = 48000, block_frames = 1024, max_mix_channels = 128 };

typedef struct {
    MPPreviewDecoder *decoder;
    AVRational timestamp_base;
    SwrContext *converter;
    int input_rate;
    int channels;
    AudioChannelLabel labels[max_mix_channels];
    int64_t expected_input;
    int64_t next_output;
    float *pcm;
    size_t capacity;
    const float *output;
    CMSampleBufferRef output_sample;
    int count;
    int64_t start;
    CMSampleBufferRef pending;
    bool eof, failed;
    bool discontinuity;
    CMTime tick;
    int64_t source_samples;
    int64_t pending_start, pending_end, output_end;
    double matrix[2 * max_mix_channels];
    double pending_matrix[2 * max_mix_channels];
} AudioLane;

struct LinkedAudioMix {
    CMAudioFormatDescriptionRef format;
    int channels;
    AudioChannelLabel labels[max_mix_channels];
    int count;
    bool program;
    int requested_lane;
    int64_t cursor;
    AudioLane lanes[];
};

LinkedAudioMix *linked_mix_create(int count)
{
    LinkedAudioMix *mix = calloc(1, sizeof(*mix) + (size_t)count * sizeof(AudioLane));
    if (!mix)
        return NULL;
    mix->count = count;
    mix->cursor = INT64_MIN;
    return mix;
}

void linked_mix_set_lane(LinkedAudioMix *mix, int index, MPPreviewDecoder *decoder, AVRational timestamp_base)
{
    mix->lanes[index].decoder = decoder;
    mix->lanes[index].timestamp_base = timestamp_base;
}

void linked_mix_preserve_surround(LinkedAudioMix *mix)
{
    for (int i = 0; i < mix->count; i++)
        if (mix->lanes[i].decoder)
            mp_preview_preserve_surround(mix->lanes[i].decoder);
}

static void clear_lane(AudioLane *lane)
{
    if (lane->pending)
        CFRelease(lane->pending);
    lane->pending = NULL;
    if (lane->output_sample)
        CFRelease(lane->output_sample);
    lane->output_sample = NULL;
    swr_free(&lane->converter);
    lane->input_rate = 0;
    lane->count = 0;
    lane->eof = false;
    lane->failed = false;
}

void linked_mix_close(LinkedAudioMix *mix)
{
    if (!mix)
        return;
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        clear_lane(lane);
        free(lane->pcm);
        mp_preview_close(lane->decoder);
    }
    if (mix->format)
        CFRelease(mix->format);
    free(mix);
}

bool linked_mix_has_audio(const LinkedAudioMix *mix)
{
    for (int i = 0; i < mix->count; i++) {
        const AudioLane *lane = &mix->lanes[i];
        if (lane->decoder && !lane->failed && mp_preview_has_audio(lane->decoder))
            return true;
    }
    return false;
}

bool linked_mix_unavailable(const LinkedAudioMix *mix)
{
    for (int i = 0; i < mix->count; i++) {
        const AudioLane *lane = &mix->lanes[i];
        if (!lane->decoder || lane->failed || mp_preview_has_unavailable_audio(lane->decoder))
            return true;
    }
    return false;
}

bool linked_mix_met_audio_damage(const LinkedAudioMix *mix)
{
    for (int i = 0; i < mix->count; i++) {
        const AudioLane *lane = &mix->lanes[i];
        if (lane->decoder && mp_preview_met_audio_damage(lane->decoder))
            return true;
    }
    return false;
}

bool linked_mix_seek(LinkedAudioMix *mix, double seconds)
{
    bool positioned = true;
    mix->cursor = INT64_MIN;
    mix->channels = 0;
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        clear_lane(lane);
        if (lane->decoder && !mp_preview_seek_timeline(lane->decoder, seconds))
            positioned = false;
    }
    return positioned;
}

static bool reserve_pcm(AudioLane *lane, int frames)
{
    size_t values = (size_t)frames * lane->channels;
    if (values > lane->capacity) {
        float *pcm = realloc(lane->pcm, values * sizeof(float));
        if (!pcm)
            return false;
        lane->pcm = pcm;
        lane->capacity = values;
    }
    return true;
}

static int place_pcm(AudioLane *lane, int frames, bool program)
{
    lane->count = frames;
    lane->start = lane->next_output;
    if (lane->count > 0) {
        lane->next_output += lane->count;
        if (program)
            lane->count = (int)FFMAX(0, FFMIN(lane->count, lane->output_end - lane->start));
    }
    return lane->count;
}

static int convert(AudioLane *lane, const uint8_t *input, int frames, bool program)
{
    int size = swr_get_out_samples(lane->converter, frames);
    if (size <= 0)
        return size;
    if (!reserve_pcm(lane, size))
        return -1;
    uint8_t *out = (uint8_t *)lane->pcm;
    lane->output = lane->pcm;
    return place_pcm(lane, swr_convert(lane->converter, &out, size, input ? &input : NULL, frames), program);
}

static void sample_labels(CMAudioFormatDescriptionRef format, int channels, AudioChannelLabel *labels)
{
    const AudioChannelLayout *layout = CMAudioFormatDescriptionGetChannelLayout(format, NULL);
    if (layout && layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions &&
               layout->mNumberChannelDescriptions == (UInt32)channels) {
        for (int i = 0; i < channels; i++)
            labels[i] = layout->mChannelDescriptions[i].mChannelLabel;
    } else if (channels == 2) {
        labels[0] = kAudioChannelLabel_Left;
        labels[1] = kAudioChannelLabel_Right;
    } else {
        for (int i = 0; i < channels; i++)
            labels[i] = kAudioChannelLabel_Discrete_0 + i;
    }
}

// Keep one PCM block per lane. The resampler carries phase between packets,
// including packets whose presentation timestamps are rounded to container ticks.
static int fill_lane(AudioLane *lane, bool program)
{
    if (lane->failed)
        return MPPreviewEnd;
    if (lane->count > 0)
        return MPPreviewAudio;
    if (lane->output_sample) {
        CFRelease(lane->output_sample);
        lane->output_sample = NULL;
    }
    if (!lane->pending && !lane->eof) {
        if (program)
            return MPPreviewAgain;
        if (!lane->decoder)
            return MPPreviewEnd;
        const char *error;
        int result = mp_preview_next(lane->decoder, &lane->pending, &error);
        if (result == MPPreviewAgain)
            return result;
        if (result == MPPreviewError)
            return MPPreviewError;
        lane->eof = result == MPPreviewEnd;
    }
    CMSampleBufferRef sample = lane->pending;
    int rate = 0, channels = 0;
    AudioChannelLabel labels[max_mix_channels];
    int64_t timestamp = 0;
    if (sample) {
        CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
        if (!description || CMFormatDescriptionGetMediaType(description) != kCMMediaType_Audio)
            return MPPreviewError;
        const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
        if (!format || format->mChannelsPerFrame == 0 || format->mChannelsPerFrame > max_mix_channels ||
            !isfinite(format->mSampleRate) || format->mSampleRate < 1 || format->mSampleRate > INT_MAX ||
            (program && (format->mFormatID != kAudioFormatLinearPCM ||
                         (format->mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved |
                                                  kAudioFormatFlagIsBigEndian)) != kAudioFormatFlagIsFloat ||
                         format->mBitsPerChannel != 32 ||
                         format->mBytesPerFrame != sizeof(float) * format->mChannelsPerFrame)))
            return MPPreviewError;
        channels = (int)format->mChannelsPerFrame;
        rate = (int)format->mSampleRate;
        sample_labels(description, channels, labels);
        timestamp = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), rate,
                                       kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    }
    int64_t tolerance = program
        ? FFMAX(0, av_rescale_rnd(lane->tick.value, FFMAX(rate, 1), FFMAX(lane->tick.timescale, 1), AV_ROUND_UP) - 1)
        : av_rescale_q_rnd(1, lane->timestamp_base, (AVRational){1, FFMAX(rate, 1)}, AV_ROUND_UP) - 1;
    if (lane->input_rate && (!sample || lane->discontinuity || rate != lane->input_rate ||
                            channels != lane->channels ||
                            memcmp(labels, lane->labels, (size_t)channels * sizeof(*labels)) != 0 ||
                            llabs(timestamp - lane->expected_input) > tolerance)) {
        if (lane->converter) {
            int count = convert(lane, NULL, 0, program);
            if (count < 0)
                return MPPreviewError;
            if (count > 0)
                return MPPreviewAudio;
            swr_free(&lane->converter);
        }
        lane->input_rate = 0;
    }
    if (!sample)
        return MPPreviewEnd;
    bool direct = program && rate == mix_rate;
    if (!lane->input_rate) {
        if (!direct) {
            AVChannelLayout discrete = { .order = AV_CHANNEL_ORDER_UNSPEC, .nb_channels = channels };
            // A single rounded source sample already supplies the nearest value
            // for a kept sub-sample edit. Downsampling it can discard it entirely.
            int converter_rate = program && lane->source_samples == 1 && rate > mix_rate ? mix_rate : rate;
            if (swr_alloc_set_opts2(&lane->converter, &discrete, AV_SAMPLE_FMT_FLT, mix_rate,
                                    &discrete, AV_SAMPLE_FMT_FLT, converter_rate, 0, NULL) < 0)
                return MPPreviewError;
            // A short resampled edit may finish before swr's usual filter has
            // enough samples for its first output on flush.
            if (program && converter_rate != mix_rate && lane->source_samples < 64 &&
                av_opt_set_int(lane->converter, "filter_size", FFMAX(1, lane->source_samples / 2), 0) < 0)
                return MPPreviewError;
            if (swr_init(lane->converter) < 0)
                return MPPreviewError;
        }
        lane->channels = channels;
        memcpy(lane->labels, labels, (size_t)channels * sizeof(*labels));
        lane->input_rate = rate;
        lane->next_output = program
            ? CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), mix_rate,
                                kCMTimeRoundingMethod_RoundHalfAwayFromZero).value
            : av_rescale(timestamp, mix_rate, rate);
        if (program) {
            lane->output_end = lane->pending_end;
            // A coarse packet clock can round the first cropped input sample
            // away from the selected edit edge. Use the known program edge
            // when the difference fits in the input clock's quantization.
            int64_t start_tolerance = av_rescale_rnd(tolerance, mix_rate, rate, AV_ROUND_UP);
            if (lane->discontinuity && llabs(lane->next_output - lane->pending_start) <= start_tolerance)
                lane->next_output = lane->pending_start;
        }
        lane->expected_input = timestamp;
    }
    lane->discontinuity = false;
    if (program)
        memcpy(lane->matrix, lane->pending_matrix, (size_t)channels * 2 * sizeof(*lane->matrix));
    CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(sample);
    char *pcm;
    size_t contiguous;
    CMItemCount sample_count = CMSampleBufferGetNumSamples(sample);
    if (sample_count <= 0 || sample_count > INT_MAX ||
        (uint64_t)sample_count > SIZE_MAX / sizeof(float) / channels)
        return MPPreviewError;
    int frames = (int)sample_count;
    size_t bytes = (size_t)frames * channels * sizeof(float);
    size_t total;
    if (!buffer || CMBlockBufferGetDataPointer(buffer, 0, &contiguous, &total, &pcm) != noErr || total < bytes)
        return MPPreviewError;
    bool copy_needed = contiguous < bytes || (uintptr_t)pcm % _Alignof(float) != 0;
    if (direct) {
        // Retain contiguous PCM until every overlapping mix block has consumed it.
        if (!copy_needed) {
            lane->output = (const float *)pcm;
            lane->output_sample = lane->pending;
        } else {
            if (!reserve_pcm(lane, frames) ||
                CMBlockBufferCopyDataBytes(buffer, 0, bytes, lane->pcm) != noErr)
                return MPPreviewError;
            lane->output = lane->pcm;
            CFRelease(lane->pending);
        }
        lane->pending = NULL;
        lane->expected_input += frames;
        return place_pcm(lane, frames, program) > 0 ? MPPreviewAudio : MPPreviewAgain;
    }
    void *copy = NULL;
    if (copy_needed) {
        copy = malloc(bytes);
        if (!copy || CMBlockBufferCopyDataBytes(buffer, 0, bytes, copy) != noErr) {
            free(copy);
            return MPPreviewError;
        }
        pcm = copy;
    }
    int count = convert(lane, (const uint8_t *)pcm, frames, program);
    free(copy);
    CFRelease(lane->pending);
    lane->pending = NULL;
    lane->expected_input += frames;
    return count < 0 ? MPPreviewError : count == 0 ? MPPreviewAgain : MPPreviewAudio;
}

static int mix_channel(const LinkedAudioMix *mix, AudioChannelLabel label)
{
    int i = 0;
    while (i < mix->channels && mix->labels[i] < label)
        i++;
    return i;
}

static bool update_mix_format(LinkedAudioMix *mix)
{
    int count = mix->channels;
    // Keep known speakers across gaps and ends so the renderer keeps their positions.
    for (int i = 0; !mix->program && i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (lane->failed || lane->count <= 0)
            continue;
        for (int j = 0; j < lane->channels; j++) {
            AudioChannelLabel label = lane->labels[j];
            int index = mix_channel(mix, label);
            if (index < mix->channels && mix->labels[index] == label)
                continue;
            if (mix->channels == max_mix_channels)
                return false;
            memmove(&mix->labels[index + 1], &mix->labels[index],
                    (size_t)(mix->channels - index) * sizeof(label));
            mix->labels[index] = label;
            mix->channels++;
        }
    }
    if (mix->format && count == mix->channels)
        return true;
    UInt32 stride = (UInt32)mix->channels * sizeof(float);
    AudioStreamBasicDescription format = {
        .mSampleRate = mix_rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = stride, .mFramesPerPacket = 1, .mBytesPerFrame = stride,
        .mChannelsPerFrame = mix->channels, .mBitsPerChannel = 32
    };
    // Label each output channel in the same order as the interleaved PCM.
    size_t layout_size = offsetof(AudioChannelLayout, mChannelDescriptions) +
        (size_t)mix->channels * sizeof(AudioChannelDescription);
    AudioChannelLayout *layout = calloc(1, layout_size);
    if (!layout)
        return false;
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = (UInt32)mix->channels;
    for (int i = 0; i < mix->channels; i++)
        layout->mChannelDescriptions[i].mChannelLabel = mix->labels[i];
    CMAudioFormatDescriptionRef description = NULL;
    OSStatus status = CMAudioFormatDescriptionCreate(NULL, &format,
        mix->channels > 2 ? layout_size : 0, mix->channels > 2 ? layout : NULL,
        0, NULL, NULL, &description);
    free(layout);
    if (status != noErr)
        return false;
    if (mix->format)
        CFRelease(mix->format);
    mix->format = description;
    return true;
}

int linked_mix_next(LinkedAudioMix *mix, CMSampleBufferRef *sample)
{
    int64_t first = INT64_MAX;
    mix->requested_lane = -1;
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (lane->count && lane->start + lane->count <= mix->cursor)
            lane->count = 0;
        int result = fill_lane(lane, mix->program);
        if (result == MPPreviewAgain) {
            // A converter may consume a packet without producing output yet.
            if (mix->program && !lane->pending && !lane->eof)
                mix->requested_lane = i;
            return result;
        }
        if (result == MPPreviewError) {
            lane->failed = true;
            if (mix->program)
                return result;
        }
        if (lane->count > 0 && !lane->failed) {
            if (lane->start + lane->count <= mix->cursor)
                return MPPreviewAgain;
            first = FFMIN(first, lane->start);
        }
    }
    if (first == INT64_MAX)
        return MPPreviewEnd;
    if (!update_mix_format(mix))
        return MPPreviewError;
    mix->cursor = FFMAX(mix->cursor, first);
    int64_t end = mix->cursor + block_frames;
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (lane->count > 0 && !lane->failed)
            end = FFMIN(end, lane->start > mix->cursor ? lane->start : lane->start + lane->count);
    }
    int frames = (int)(end - mix->cursor);
    CMBlockBufferRef data = NULL;
    size_t bytes = (size_t)frames * mix->channels * sizeof(float);
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes,
                                           kCMBlockBufferAssureMemoryNowFlag, &data) != noErr)
        return MPPreviewError;
    char *raw;
    if (CMBlockBufferGetDataPointer(data, 0, NULL, NULL, &raw) != noErr) {
        CFRelease(data);
        return MPPreviewError;
    }
    double program_pcm[block_frames * 2];
    if (mix->program)
        memset(program_pcm, 0, (size_t)frames * 2 * sizeof(double));
    else
        memset(raw, 0, bytes);
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (!lane->failed && lane->count > 0 && lane->start <= mix->cursor) {
            const float *source = lane->output + lane->channels * (mix->cursor - lane->start);
            if (mix->program) {
                mp_program_mix_accumulate(source, program_pcm, frames, lane->channels, 2, lane->matrix, mix->count);
                continue;
            }
            int positions[max_mix_channels];
            for (int channel = 0; channel < lane->channels; channel++)
                positions[channel] = mix_channel(mix, lane->labels[channel]);
            for (int frame = 0; frame < frames; frame++)
                for (int channel = 0; channel < lane->channels; channel++)
                    ((float *)raw)[frame * mix->channels + positions[channel]] += source[frame * lane->channels + channel];
        }
    }
    if (mix->program)
        for (int i = 0; i < frames * 2; i++)
            ((float *)raw)[i] = (float)program_pcm[i];
    OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, mix->format, frames,
                                                                           CMTimeMake(mix->cursor, mix_rate), NULL, sample);
    CFRelease(data);
    mix->cursor = end;
    return status == noErr ? MPPreviewAudio : MPPreviewError;
}

MPProgramAudioMix *mp_program_mix_create(int lanes)
{
    if (lanes <= 0)
        return NULL;
    LinkedAudioMix *mix = linked_mix_create(lanes);
    if (mix) {
        mix->program = true;
        mix->channels = 2;
        mix->labels[0] = kAudioChannelLabel_Left;
        mix->labels[1] = kAudioChannelLabel_Right;
    }
    return mix;
}

void mp_program_mix_close(MPProgramAudioMix *mix)
{
    linked_mix_close(mix);
}

void mp_program_mix_submit(MPProgramAudioMix *mix, int index, CMSampleBufferRef sample,
                           const double *matrix, bool discontinuity, CMTime timestamp_tick,
                           int64_t source_samples, CMTime output_start, CMTime output_end)
{
    AudioLane *lane = &mix->lanes[index];
    if (sample) {
        const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(
            CMSampleBufferGetFormatDescription(sample));
        if (format && format->mChannelsPerFrame <= max_mix_channels)
            memcpy(lane->pending_matrix, matrix, format->mChannelsPerFrame * 2 * sizeof(*matrix));
        lane->pending = (CMSampleBufferRef)CFRetain(sample);
        lane->discontinuity = discontinuity;
        lane->tick = timestamp_tick;
        lane->source_samples = source_samples;
        lane->pending_start = CMTimeConvertScale(output_start, mix_rate, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
        lane->pending_end = CMTimeConvertScale(output_end, mix_rate, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    } else {
        lane->eof = true;
    }
}

int mp_program_mix_next(MPProgramAudioMix *mix, CMSampleBufferRef *sample, int *lane)
{
    int result = linked_mix_next(mix, sample);
    *lane = mix->requested_lane;
    return result;
}

const char *mp_program_mix_speaker(CMAudioFormatDescriptionRef format, int channel)
{
    const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!description || channel < 0 || (UInt32)channel >= description->mChannelsPerFrame ||
        description->mChannelsPerFrame > max_mix_channels)
        return "";
    AudioChannelLabel labels[max_mix_channels];
    int channels = (int)description->mChannelsPerFrame;
    sample_labels(format, channels, labels);
    AudioChannelLabel label = labels[channel];
    const AudioChannelLayout *layout = CMAudioFormatDescriptionGetChannelLayout(format, NULL);
    if (layout && layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
        AudioFormatPropertyID property = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag;
        UInt32 key = property == kAudioFormatProperty_ChannelLayoutForBitmap
            ? layout->mChannelBitmap : layout->mChannelLayoutTag;
        union {
            AudioChannelLayout layout;
            char bytes[offsetof(AudioChannelLayout, mChannelDescriptions) +
                       max_mix_channels * sizeof(AudioChannelDescription)];
        } expanded;
        UInt32 size = sizeof(expanded);
        if (AudioFormatGetProperty(property, sizeof(key), &key, &size, &expanded) == noErr &&
            expanded.layout.mNumberChannelDescriptions == (UInt32)channels) {
            const AudioChannelDescription *speakers = (const AudioChannelDescription *)
                (expanded.bytes + offsetof(AudioChannelLayout, mChannelDescriptions));
            label = speakers[channel].mChannelLabel;
        }
    }
    switch (label) {
    case kAudioChannelLabel_Left: return "FL";
    case kAudioChannelLabel_Right: return "FR";
    case kAudioChannelLabel_LeftTotal: return "DL";
    case kAudioChannelLabel_RightTotal: return "DR";
    case kAudioChannelLabel_Center: return "FC";
    case kAudioChannelLabel_LFEScreen: return "LFE";
    case kAudioChannelLabel_LFE2: return "LFE2";
    case kAudioChannelLabel_RearSurroundLeft: return "BL";
    case kAudioChannelLabel_RearSurroundRight: return "BR";
    case kAudioChannelLabel_LeftSurround: return "SL";
    case kAudioChannelLabel_RightSurround: return "SR";
    case kAudioChannelLabel_CenterSurround: return "BC";
    case kAudioChannelLabel_LeftCenter: return "FLC";
    case kAudioChannelLabel_RightCenter: return "FRC";
    case kAudioChannelLabel_TopCenterSurround: return "TC";
    case kAudioChannelLabel_VerticalHeightLeft: return "TFL";
    case kAudioChannelLabel_VerticalHeightCenter: return "TFC";
    case kAudioChannelLabel_VerticalHeightRight: return "TFR";
    case kAudioChannelLabel_TopBackLeft: return "TBL";
    case kAudioChannelLabel_TopBackCenter: return "TBC";
    case kAudioChannelLabel_TopBackRight: return "TBR";
    case kAudioChannelLabel_LeftTopRear: return "TBL";
    case kAudioChannelLabel_CenterTopRear: return "TBC";
    case kAudioChannelLabel_RightTopRear: return "TBR";
    case kAudioChannelLabel_LeftTopMiddle: return "TML";
    case kAudioChannelLabel_RightTopMiddle: return "TMR";
    case kAudioChannelLabel_LeftWide: return "WL";
    case kAudioChannelLabel_RightWide: return "WR";
    case kAudioChannelLabel_LeftSurroundDirect: return "SDL";
    case kAudioChannelLabel_RightSurroundDirect: return "SDR";
    case kAudioChannelLabel_LeftSideSurround: return "SSL";
    case kAudioChannelLabel_RightSideSurround: return "SSR";
    case kAudioChannelLabel_CenterBottom: return "BFC";
    case kAudioChannelLabel_LeftBottom: return "BFL";
    case kAudioChannelLabel_RightBottom: return "BFR";
    default: return description->mChannelsPerFrame == 1 ? "FC" : "";
    }
}
