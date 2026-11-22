#include "LinkedAudioMix.h"

#include <AudioToolbox/AudioToolbox.h>
#include <libswresample/swresample.h>
#include <libavutil/mathematics.h>

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
    int count;
    int64_t start;
    CMSampleBufferRef pending;
    bool eof, failed;
} AudioLane;

struct LinkedAudioMix {
    CMAudioFormatDescriptionRef format;
    int channels;
    AudioChannelLabel labels[max_mix_channels];
    int count;
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
    swr_free(&lane->converter);
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

static int convert(AudioLane *lane, const uint8_t *input, int frames)
{
    int size = swr_get_out_samples(lane->converter, frames);
    if (size <= 0)
        return size;
    size_t values = (size_t)size * lane->channels;
    if (values > lane->capacity) {
        float *pcm = realloc(lane->pcm, values * sizeof(float));
        if (!pcm)
            return -1;
        lane->pcm = pcm;
        lane->capacity = values;
    }
    uint8_t *out = (uint8_t *)lane->pcm;
    lane->count = swr_convert(lane->converter, &out, size, input ? &input : NULL, frames);
    lane->start = lane->next_output;
    if (lane->count > 0)
        lane->next_output += lane->count;
    return lane->count;
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

// Keep one converted block per lane. The resampler carries phase between packets,
// including packets whose presentation timestamps are rounded to container ticks.
static int fill_lane(AudioLane *lane)
{
    if (!lane->decoder || lane->failed)
        return MPPreviewEnd;
    if (lane->count > 0)
        return MPPreviewAudio;
    if (!lane->pending && !lane->eof) {
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
        const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
        if (!format || format->mChannelsPerFrame == 0 || format->mChannelsPerFrame > max_mix_channels)
            return MPPreviewError;
        channels = (int)format->mChannelsPerFrame;
        rate = (int)format->mSampleRate;
        sample_labels(description, channels, labels);
        timestamp = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), rate,
                                       kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    }
    int64_t tolerance = av_rescale_q_rnd(1, lane->timestamp_base, (AVRational){1, FFMAX(rate, 1)}, AV_ROUND_UP) - 1;
    if (lane->converter && (!sample || rate != lane->input_rate ||
                            channels != lane->channels ||
                            memcmp(labels, lane->labels, (size_t)channels * sizeof(*labels)) != 0 ||
                            llabs(timestamp - lane->expected_input) > tolerance)) {
        int count = convert(lane, NULL, 0);
        if (count < 0)
            return MPPreviewError;
        if (count > 0)
            return MPPreviewAudio;
        swr_free(&lane->converter);
    }
    if (!sample)
        return MPPreviewEnd;
    if (!lane->converter) {
        AVChannelLayout discrete = { .order = AV_CHANNEL_ORDER_UNSPEC, .nb_channels = channels };
        if (swr_alloc_set_opts2(&lane->converter, &discrete, AV_SAMPLE_FMT_FLT, mix_rate,
                                &discrete, AV_SAMPLE_FMT_FLT, rate, 0, NULL) < 0 ||
            swr_init(lane->converter) < 0)
            return MPPreviewError;
        lane->channels = channels;
        memcpy(lane->labels, labels, (size_t)channels * sizeof(*labels));
        lane->input_rate = rate;
        lane->next_output = av_rescale(timestamp, mix_rate, rate);
        lane->expected_input = timestamp;
    }
    char *pcm;
    int frames = (int)CMSampleBufferGetNumSamples(sample);
    if (CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sample), 0, NULL, NULL, &pcm) != noErr)
        return MPPreviewError;
    int count = convert(lane, (const uint8_t *)pcm, frames);
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
    for (int i = 0; i < mix->count; i++) {
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
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (lane->count && lane->start + lane->count <= mix->cursor)
            lane->count = 0;
        int result = fill_lane(lane);
        if (result == MPPreviewAgain)
            return result;
        if (result == MPPreviewError)
            lane->failed = true;
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
    memset(raw, 0, bytes);
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (!lane->failed && lane->count > 0 && lane->start <= mix->cursor) {
            const float *source = lane->pcm + lane->channels * (mix->cursor - lane->start);
            int positions[max_mix_channels];
            for (int channel = 0; channel < lane->channels; channel++)
                positions[channel] = mix_channel(mix, lane->labels[channel]);
            for (int frame = 0; frame < frames; frame++)
                for (int channel = 0; channel < lane->channels; channel++)
                    ((float *)raw)[frame * mix->channels + positions[channel]] += source[frame * lane->channels + channel];
        }
    }
    OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, mix->format, frames,
                                                                           CMTimeMake(mix->cursor, mix_rate), NULL, sample);
    CFRelease(data);
    mix->cursor = end;
    return status == noErr ? MPPreviewAudio : MPPreviewError;
}
