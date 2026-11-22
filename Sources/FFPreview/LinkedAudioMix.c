#include "LinkedAudioMix.h"

#include <AudioToolbox/AudioToolbox.h>
#include <libswresample/swresample.h>
#include <libavutil/mathematics.h>

// Each track keeps an independent demux cursor. One packet of lookahead per
// track lets us mix overlapping PCM at its presentation time without buffering
// an entire gap while waiting for a later-starting track.
enum { mix_rate = 48000, block_frames = 1024 };

typedef struct {
    MPPreviewDecoder *decoder;
    AVRational timestamp_base;
    SwrContext *converter;
    int input_rate;
    int64_t expected_input;
    int64_t next_output;
    float *pcm;
    int capacity, count;
    int64_t start;
    CMSampleBufferRef pending;
    bool eof, failed;
} AudioLane;

struct LinkedAudioMix {
    CMAudioFormatDescriptionRef format;
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
    AudioStreamBasicDescription format = {
        .mSampleRate = mix_rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8,
        .mChannelsPerFrame = 2, .mBitsPerChannel = 32
    };
    if (CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &mix->format) != noErr) {
        free(mix);
        return NULL;
    }
    return mix;
}

void linked_mix_set_lane(LinkedAudioMix *mix, int index, MPPreviewDecoder *decoder, AVRational timestamp_base)
{
    mix->lanes[index].decoder = decoder;
    mix->lanes[index].timestamp_base = timestamp_base;
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
    if (size > lane->capacity) {
        float *pcm = realloc(lane->pcm, (size_t)size * 2 * sizeof(float));
        if (!pcm)
            return -1;
        lane->pcm = pcm;
        lane->capacity = size;
    }
    uint8_t *out = (uint8_t *)lane->pcm;
    lane->count = swr_convert(lane->converter, &out, size, input ? &input : NULL, frames);
    lane->start = lane->next_output;
    if (lane->count > 0)
        lane->next_output += lane->count;
    return lane->count;
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
    int rate = 0;
    int64_t timestamp = 0;
    if (sample) {
        const AudioStreamBasicDescription *format =
            CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        rate = (int)format->mSampleRate;
        timestamp = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), rate,
                                       kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    }
    int64_t tolerance = av_rescale_q_rnd(1, lane->timestamp_base, (AVRational){1, FFMAX(rate, 1)}, AV_ROUND_UP) - 1;
    if (lane->converter && (!sample || rate != lane->input_rate ||
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
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (swr_alloc_set_opts2(&lane->converter, &stereo, AV_SAMPLE_FMT_FLT, mix_rate,
                                &stereo, AV_SAMPLE_FMT_FLT, rate, 0, NULL) < 0 ||
            swr_init(lane->converter) < 0)
            return MPPreviewError;
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
    mix->cursor = FFMAX(mix->cursor, first);
    int64_t end = mix->cursor + block_frames;
    for (int i = 0; i < mix->count; i++) {
        AudioLane *lane = &mix->lanes[i];
        if (lane->count > 0 && !lane->failed)
            end = FFMIN(end, lane->start > mix->cursor ? lane->start : lane->start + lane->count);
    }
    int frames = (int)(end - mix->cursor);
    CMBlockBufferRef data = NULL;
    size_t bytes = frames * 2 * sizeof(float);
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
            const float *source = lane->pcm + 2 * (mix->cursor - lane->start);
            for (int j = 0; j < frames * 2; j++)
                ((float *)raw)[j] += source[j];
        }
    }
    OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, mix->format, frames,
                                                                           CMTimeMake(mix->cursor, mix_rate), NULL, sample);
    CFRelease(data);
    mix->cursor = end;
    return status == noErr ? MPPreviewAudio : MPPreviewError;
}
