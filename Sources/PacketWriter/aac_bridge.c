#include "aac_bridge.h"

#include <AudioToolbox/AudioToolbox.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* An AAC bridge joins two copied runs of AAC frames whose 1024-sample grids do not line up on the output clock.
 *
 * Output coordinates below count samples from x, the end of the earlier range's last copied frame. The cut sits
 * at `join` (at least one frame after x, so the last copied frame's overlap reaches only sound of its own range),
 * and the later range's first copied frame starts at g, on its own grid, at or after the cut. The bridge fills
 * [0, g) with n = ceil(g / 1024) frames. Their total is 1024 n samples, r more than g, so frame n - 2 discards its
 * last r samples: the frames before it lie on the earlier grid and the last one on the later grid. The last frame
 * then encodes the same sound, on the same grid, as the frame that preceded the later run in its source, and its
 * overlap carries into that run as the source's did.
 *
 * The encoder is given the sound the output should play, with r samples inserted where the trim removes them. The
 * inserted samples crossfade from the sound that follows the trim point to the sound that precedes it, so the
 * encoder sees no step there. It starts `warm` frames before x on the earlier range's own sound, and runs `ahead`
 * frames past g on the later range's, so its first and last kept frames are coded as in a continuous stream. */

enum { WARM_FRAMES = 2, AHEAD_FRAMES = 2, HISTORY_FRAMES = 3 };

static int errorf(char *error, size_t capacity, const char *format, ...) {
    if (error && capacity) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, capacity, format, args);
        va_end(args);
    }
    return 1;
}

static int64_t floor_div(int64_t value, int64_t divisor) {
    int64_t quotient = value / divisor;
    return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient;
}

int64_t mpcut_aac_bridge_position(int64_t pts, AVRational time_base, MPCutTime origin, int sample_rate, int64_t grid) {
    if (pts == AV_NOPTS_VALUE || time_base.den <= 0 || origin.denominator <= 0 || sample_rate <= 0)
        return INT64_MIN;
    __int128 denominator = (__int128)time_base.den * origin.denominator;
    __int128 numerator = ((__int128)pts * time_base.num * origin.denominator - (__int128)origin.numerator * time_base.den) * sample_rate;
    __int128 half = denominator / 2;
    __int128 samples = (numerator < 0 ? numerator - half : numerator + half) / denominator;
    if (samples < INT64_MIN / 2 || samples > INT64_MAX / 2)
        return INT64_MIN;
    int64_t offset = (int64_t)samples - grid;
    return grid + MPCUT_AAC_FRAME * floor_div(offset + MPCUT_AAC_FRAME / 2, MPCUT_AAC_FRAME);
}

/* Consecutive frames of one track and their decoded sound. */
typedef struct {
    AVCodecParameters *codec;
    AVPacket **packets;
    int64_t first;       /* Frame start of packets[0]. */
    size_t count;
    float **sound;       /* Per channel, count * 1024 samples decoded with the source's own history. */
    int channels;
} Run;

static void run_free(Run *run) {
    for (size_t i = 0; i < run->count; i++)
        av_packet_free(&run->packets[i]);
    av_freep(&run->packets);
    for (int c = 0; run->sound && c < run->channels; c++)
        av_freep(&run->sound[c]);
    av_freep(&run->sound);
    avcodec_parameters_free(&run->codec);
    memset(run, 0, sizeof(*run));
}

/* The run's decoded sample at a position, or silence outside the frames it holds. */
static float run_sample(const Run *run, int channel, int64_t position) {
    int64_t index = position - run->first;
    if (index < 0 || index >= (int64_t)run->count * MPCUT_AAC_FRAME)
        return 0;
    return run->sound[channel][index];
}

/* Decode frames with a new decoder, dropping the last trims[i] samples of frame i, into planar sound. */
static int decode_frames(const AVCodecParameters *parameters, AVPacket *const *packets, size_t count, const int *trims,
                         float ***sound, int64_t *length, char *error, size_t capacity) {
    const AVCodec *decoder = avcodec_find_decoder(AV_CODEC_ID_AAC);
    AVCodecContext *context = decoder ? avcodec_alloc_context3(decoder) : NULL;
    AVFrame *frame = av_frame_alloc();
    AVPacket *copy = av_packet_alloc();
    int channels = parameters->ch_layout.nb_channels;
    int result = 1;
    *sound = NULL;
    *length = 0;
    if (!context || !frame || !copy || channels <= 0
        || avcodec_parameters_to_context(context, parameters) < 0) {
        errorf(error, capacity, "Cannot prepare an AAC decoder");
        goto done;
    }
    // Frames are compared in full: priming at a source's start is the caller's to skip.
    context->flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL;
    if (avcodec_open2(context, decoder, NULL) < 0) {
        errorf(error, capacity, "Cannot open an AAC decoder");
        goto done;
    }
    *sound = av_calloc(channels, sizeof(**sound));
    for (int c = 0; *sound && c < channels; c++)
        if (!((*sound)[c] = av_calloc(count ? count * MPCUT_AAC_FRAME : 1, sizeof(float))))
            break;
    if (!*sound || (channels && !(*sound)[channels - 1])) {
        errorf(error, capacity, "Cannot allocate decoded AAC sound");
        goto done;
    }
    for (size_t i = 0; i < count; i++) {
        av_packet_unref(copy);
        if (av_packet_ref(copy, packets[i]) < 0) {
            errorf(error, capacity, "Cannot read an AAC frame");
            goto done;
        }
        av_packet_side_data_remove(copy->side_data, &copy->side_data_elems, AV_PKT_DATA_SKIP_SAMPLES);
        if (avcodec_send_packet(context, copy) < 0 || avcodec_receive_frame(context, frame) < 0) {
            errorf(error, capacity, "An AAC frame does not decode");
            goto done;
        }
        if (frame->nb_samples != MPCUT_AAC_FRAME || frame->sample_rate != parameters->sample_rate
            || frame->format != AV_SAMPLE_FMT_FLTP || frame->ch_layout.nb_channels != channels) {
            errorf(error, capacity, frame->nb_samples == 2 * MPCUT_AAC_FRAME || frame->sample_rate == 2 * parameters->sample_rate
                   ? "The AAC track uses spectral band replication (HE-AAC), which Smart Trim cannot encode at a join"
                   : "The AAC track does not decode to 1024-sample frames at its own rate and layout");
            goto done;
        }
        int keep = MPCUT_AAC_FRAME - (trims ? trims[i] : 0);
        for (int c = 0; c < channels; c++)
            memcpy((*sound)[c] + *length, frame->extended_data[c], (size_t)keep * sizeof(float));
        *length += keep;
        av_frame_unref(frame);
    }
    result = 0;
done:
    if (result && *sound) {
        for (int c = 0; c < channels; c++)
            av_freep(&(*sound)[c]);
        av_freep(sound);
    }
    av_packet_free(&copy);
    av_frame_free(&frame);
    avcodec_free_context(&context);
    return result;
}

/* Read the frames of a track that start in [from, to) on its sample clock, and decode them with their history. */
static int load_run(const char *path, int stream, MPCutTime origin, int64_t grid, int64_t from, int64_t to,
                    Run *run, char *error, size_t capacity) {
    AVFormatContext *input = NULL;
    AVPacket *packet = av_packet_alloc();
    int result = 1;
    memset(run, 0, sizeof(*run));
    if (!packet || avformat_open_input(&input, path, NULL, NULL) < 0) {
        errorf(error, capacity, "Cannot open %s for an AAC bridge", path);
        goto done;
    }
    if (stream < 0 || (unsigned)stream >= input->nb_streams
        || input->streams[stream]->codecpar->codec_id != AV_CODEC_ID_AAC) {
        errorf(error, capacity, "Track %d of %s is not AAC", stream, path);
        goto done;
    }
    AVStream *track = input->streams[stream];
    if (track->codecpar->sample_rate <= 0 && avformat_find_stream_info(input, NULL) < 0) {
        errorf(error, capacity, "Cannot read the AAC track of %s", path);
        goto done;
    }
    int rate = track->codecpar->sample_rate;
    if (rate <= 0 || !(run->codec = avcodec_parameters_alloc()) || avcodec_parameters_copy(run->codec, track->codecpar) < 0) {
        errorf(error, capacity, "Cannot read the AAC track of %s", path);
        goto done;
    }
    for (unsigned i = 0; i < input->nb_streams; i++)
        input->streams[i]->discard = i == (unsigned)stream ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    int64_t load_from = from - HISTORY_FRAMES * MPCUT_AAC_FRAME;
    // Seek a little earlier than the history needs: a Matroska cue can name a block after its time.
    double seconds = (double)(load_from - 4 * MPCUT_AAC_FRAME) / rate + (double)origin.numerator / origin.denominator;
    int64_t target = (int64_t)floor(seconds * track->time_base.den / track->time_base.num);
    if (av_seek_frame(input, stream, target, AVSEEK_FLAG_BACKWARD) < 0)
        av_seek_frame(input, stream, INT64_MIN, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY);
    size_t capacity_packets = 0;
    int64_t expected = INT64_MIN;
    int read;
    while ((read = av_read_frame(input, packet)) >= 0) {
        if (packet->stream_index != stream) {
            av_packet_unref(packet);
            continue;
        }
        int64_t position = mpcut_aac_bridge_position(packet->pts, track->time_base, origin, rate, grid);
        if (position == INT64_MIN) {
            errorf(error, capacity, "An AAC frame of %s has no presentation time", path);
            goto done;
        }
        if (position >= to)
            break;
        if (position < load_from) {
            av_packet_unref(packet);
            continue;
        }
        if (expected != INT64_MIN && position != expected) {
            errorf(error, capacity, "The AAC frames of %s are not consecutive near %.3f s", path, (double)position / rate);
            goto done;
        }
        expected = position + MPCUT_AAC_FRAME;
        if (run->count == capacity_packets) {
            size_t grown = capacity_packets ? capacity_packets * 2 : 16;
            AVPacket **packets = av_realloc_array(run->packets, grown, sizeof(*packets));
            if (!packets) {
                errorf(error, capacity, "Cannot allocate AAC frames");
                goto done;
            }
            run->packets = packets;
            capacity_packets = grown;
        }
        if (!run->count)
            run->first = position;
        run->packets[run->count] = av_packet_clone(packet);
        if (!run->packets[run->count]) {
            errorf(error, capacity, "Cannot allocate AAC frames");
            goto done;
        }
        run->count++;
        av_packet_unref(packet);
    }
    if (read < 0 && read != AVERROR_EOF) {
        errorf(error, capacity, "Cannot read the AAC frames of %s", path);
        goto done;
    }
    if (!run->count) {
        errorf(error, capacity, "%s has no AAC frames near %.3f s", path, (double)from / rate);
        goto done;
    }
    int64_t length;
    if (decode_frames(run->codec, run->packets, run->count, NULL, &run->sound, &length, error, capacity))
        goto done;
    run->channels = run->codec->ch_layout.nb_channels;
    result = 0;
done:
    av_packet_free(&packet);
    avformat_close_input(&input);
    if (result)
        run_free(run);
    return result;
}

/* The AudioSpecificConfig fields an encoded frame must share with the source: object type, rate and channels. */
static int config_fields(const AVCodecParameters *codec, int *object, int *rate_index, int *channels) {
    if (!codec->extradata || codec->extradata_size < 2)
        return -1;
    const uint8_t *bytes = codec->extradata;
    *object = bytes[0] >> 3;
    *rate_index = ((bytes[0] & 7) << 1) | (bytes[1] >> 7);
    *channels = (bytes[1] >> 3) & 15;
    return 0;
}

/* Why the bridge encoder cannot reproduce this track's coding, or NULL. */
static const char *config_issue(const AVCodecParameters *codec) {
    int object, rate_index, channels;
    if (config_fields(codec, &object, &rate_index, &channels))
        return "it has no AAC decoder configuration";
    if (object == 5 || object == 29)
        return "it uses HE-AAC (spectral band replication or parametric stereo)";
    if (object != 2)
        return "it is not AAC Low Complexity";
    if (rate_index == 15)
        return "its sample rate is not a standard AAC rate";
    if (channels == 0 || channels > 7)
        return "its channel layout is described by a program configuration element";
    // Bytes past the first two can signal SBR explicitly: sync extension 0x2b7, object type 5, then sbrPresentFlag.
    // Encoders also write that extension with the flag clear to say there is no SBR.
    if (codec->extradata_size >= 5) {
        const uint8_t *b = codec->extradata;
        unsigned bits = (unsigned)b[2] << 16 | (unsigned)b[3] << 8 | b[4];
        unsigned sync = bits >> 13, extension = (bits >> 8) & 31, present = (bits >> 7) & 1;
        if (sync == 0x2b7 && extension == 5 && present)
            return "it signals HE-AAC (spectral band replication or parametric stereo)";
    }
    return NULL;
}

typedef struct {
    int64_t join, gap, end; /* Output coordinates from x: the cut, and g. */
    int frames, trimmed, trim;
    int64_t trim_point;     /* Where frame `trimmed` ends after its trim. */
} Layout;

static int layout(const MPCutAACBridge *bridge, Layout *plan, char *error, size_t capacity) {
    plan->join = bridge->previous_cut - bridge->previous_copy_end;
    plan->gap = bridge->copy_start - bridge->cut;
    plan->end = plan->join + plan->gap;
    if (plan->join < MPCUT_AAC_FRAME || plan->gap < 0 || plan->end <= MPCUT_AAC_FRAME || plan->end > 16 * MPCUT_AAC_FRAME)
        return errorf(error, capacity, "The AAC bridge copy points are not usable");
    plan->frames = (int)((plan->end + MPCUT_AAC_FRAME - 1) / MPCUT_AAC_FRAME);
    plan->trim = (int)((int64_t)plan->frames * MPCUT_AAC_FRAME - plan->end);
    plan->trimmed = plan->frames - 2;
    plan->trim_point = (int64_t)(plan->trimmed + 1) * MPCUT_AAC_FRAME - plan->trim;
    return 0;
}

/* The sound the output plays at an output coordinate: the earlier range before the cut, the later one after. */
static float wanted(const MPCutAACBridge *bridge, const Layout *plan, const Run *before, const Run *after,
                    int channel, int64_t at) {
    return at < plan->join ? run_sample(before, channel, bridge->previous_copy_end + at)
                           : run_sample(after, channel, bridge->cut + at - plan->join);
}

typedef struct {
    AVPacket **packets;
    size_t count;
    size_t capacity;
} Encoded;

static void encoded_free(Encoded *encoded) {
    for (size_t i = 0; i < encoded->count; i++)
        av_packet_free(&encoded->packets[i]);
    av_freep(&encoded->packets);
    memset(encoded, 0, sizeof(*encoded));
}

static int append_packet(Encoded *encoded, AVPacket *packet) {
    if (encoded->count == encoded->capacity) {
        size_t grown = encoded->capacity ? encoded->capacity * 2 : 16;
        AVPacket **packets = av_realloc_array(encoded->packets, grown, sizeof(*packets));
        if (!packets)
            return -1;
        encoded->packets = packets;
        encoded->capacity = grown;
    }
    encoded->packets[encoded->count++] = packet;
    return 0;
}

/* An open bridge encoder. `lead` is the samples of priming it decodes before its first input sample. */
typedef struct {
    int kind;
    int channels;
    int64_t lead;
    AVCodecContext *context;    /* FFmpeg's encoder */
    AudioConverterRef converter; /* Apple's encoder */
    UInt32 largest_packet;
} Encoder;

static void encoder_close(Encoder *encoder) {
    avcodec_free_context(&encoder->context);
    if (encoder->converter)
        AudioConverterDispose(encoder->converter);
    memset(encoder, 0, sizeof(*encoder));
}

static int open_ffmpeg(Encoder *encoder, const AVCodecParameters *source, int64_t bit_rate, char *error, size_t capacity) {
    const AVCodec *codec = avcodec_find_encoder_by_name("aac");
    AVCodecContext *context = codec ? avcodec_alloc_context3(codec) : NULL;
    if (!context)
        return errorf(error, capacity, "FFmpeg's AAC encoder is unavailable");
    encoder->context = context;
    context->sample_fmt = AV_SAMPLE_FMT_FLTP;
    context->sample_rate = source->sample_rate;
    context->time_base = (AVRational){1, source->sample_rate};
    context->bit_rate = bit_rate;
    context->profile = AV_PROFILE_AAC_LOW;
    if (source->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC)
        av_channel_layout_default(&context->ch_layout, encoder->channels);
    else if (av_channel_layout_copy(&context->ch_layout, &source->ch_layout) < 0)
        return errorf(error, capacity, "Cannot copy the AAC channel layout");
    // Noise substitution would differ between decoders; a bridge must decode the same everywhere.
    av_opt_set_int(context->priv_data, "aac_pns", 0, 0);
    if (avcodec_open2(context, codec, NULL) < 0)
        return errorf(error, capacity, "FFmpeg's AAC encoder does not accept the track's rate and layout");
    if (context->frame_size != MPCUT_AAC_FRAME)
        return errorf(error, capacity, "FFmpeg's AAC encoder does not code 1024-sample frames");
    encoder->lead = context->initial_padding;
    return 0;
}

static int open_apple(Encoder *encoder, const AVCodecParameters *source, int64_t bit_rate, char *error, size_t capacity) {
    // Apple's channel order for more than two channels differs from FFmpeg's decoded order. Keep to mono and stereo.
    if (encoder->channels > 2)
        return errorf(error, capacity, "Apple's AAC encoder is used here only for mono and stereo");
    AudioStreamBasicDescription input = {
        .mSampleRate = source->sample_rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * (UInt32)encoder->channels, .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * (UInt32)encoder->channels, .mChannelsPerFrame = (UInt32)encoder->channels, .mBitsPerChannel = 32
    };
    AudioStreamBasicDescription output = {
        .mSampleRate = source->sample_rate, .mFormatID = kAudioFormatMPEG4AAC, .mFormatFlags = kMPEG4Object_AAC_LC,
        .mFramesPerPacket = MPCUT_AAC_FRAME, .mChannelsPerFrame = (UInt32)encoder->channels
    };
    if (AudioConverterNew(&input, &output, &encoder->converter) != noErr)
        return errorf(error, capacity, "Apple's AAC encoder does not accept the track's rate and layout");
    // The nearest rate the encoder offers at or above the source's, else its highest.
    UInt32 size = 0;
    if (AudioConverterGetPropertyInfo(encoder->converter, kAudioConverterApplicableEncodeBitRates, &size, NULL) == noErr && size) {
        AudioValueRange *rates = av_malloc(size);
        if (rates && AudioConverterGetProperty(encoder->converter, kAudioConverterApplicableEncodeBitRates, &size, rates) == noErr) {
            UInt32 chosen = 0, highest = 0;
            for (UInt32 i = 0; i < size / sizeof(*rates); i++) {
                UInt32 rate = (UInt32)rates[i].mMaximum;
                if (rate > highest)
                    highest = rate;
                if (rate >= bit_rate && (!chosen || rate < chosen))
                    chosen = rate;
            }
            chosen = chosen ? chosen : highest;
            if (chosen)
                AudioConverterSetProperty(encoder->converter, kAudioConverterEncodeBitRate, sizeof(chosen), &chosen);
        }
        av_free(rates);
    }
    AudioConverterPrimeInfo prime = {0};
    size = sizeof(prime);
    if (AudioConverterGetProperty(encoder->converter, kAudioConverterPrimeInfo, &size, &prime) != noErr)
        return errorf(error, capacity, "Apple's AAC encoder does not state its priming");
    encoder->lead = prime.leadingFrames;
    size = sizeof(encoder->largest_packet);
    if (AudioConverterGetProperty(encoder->converter, kAudioConverterPropertyMaximumOutputPacketSize, &size,
                                  &encoder->largest_packet) != noErr || !encoder->largest_packet)
        encoder->largest_packet = 8192;
    return 0;
}

static int encoder_open(Encoder *encoder, int kind, const AVCodecParameters *source, int64_t bit_rate,
                        char *error, size_t capacity) {
    memset(encoder, 0, sizeof(*encoder));
    encoder->kind = kind;
    encoder->channels = source->ch_layout.nb_channels;
    int result = kind == MPCUT_AAC_BRIDGE_APPLE ? open_apple(encoder, source, bit_rate, error, capacity)
                                                : open_ffmpeg(encoder, source, bit_rate, error, capacity);
    if (!result && encoder->lead < 0)
        result = errorf(error, capacity, "The AAC encoder states negative priming");
    if (result)
        encoder_close(encoder);
    return result;
}

static int encode_ffmpeg(Encoder *encoder, float *const *sound, int frames, Encoded *encoded, char *error, size_t capacity) {
    AVCodecContext *context = encoder->context;
    AVFrame *frame = av_frame_alloc();
    int result = 1;
    if (!frame)
        return errorf(error, capacity, "Cannot allocate an AAC encoder frame");
    frame->format = AV_SAMPLE_FMT_FLTP;
    frame->nb_samples = MPCUT_AAC_FRAME;
    frame->sample_rate = context->sample_rate;
    if (av_channel_layout_copy(&frame->ch_layout, &context->ch_layout) < 0 || av_frame_get_buffer(frame, 0) < 0) {
        errorf(error, capacity, "Cannot allocate an AAC encoder frame");
        goto done;
    }
    for (int i = 0; i <= frames; i++) {
        int sent;
        if (i < frames) {
            if (av_frame_make_writable(frame) < 0) {
                errorf(error, capacity, "Cannot allocate an AAC encoder frame");
                goto done;
            }
            for (int c = 0; c < encoder->channels; c++)
                memcpy(frame->extended_data[c], sound[c] + (size_t)i * MPCUT_AAC_FRAME, MPCUT_AAC_FRAME * sizeof(float));
            frame->pts = (int64_t)i * MPCUT_AAC_FRAME;
            sent = avcodec_send_frame(context, frame);
        } else {
            sent = avcodec_send_frame(context, NULL);
        }
        if (sent < 0) {
            errorf(error, capacity, "FFmpeg's AAC encoder failed");
            goto done;
        }
        for (;;) {
            AVPacket *packet = av_packet_alloc();
            int received = packet ? avcodec_receive_packet(context, packet) : AVERROR(ENOMEM);
            if (received == AVERROR(EAGAIN) || received == AVERROR_EOF) {
                av_packet_free(&packet);
                break;
            }
            if (received < 0 || append_packet(encoded, packet) < 0) {
                av_packet_free(&packet);
                errorf(error, capacity, "FFmpeg's AAC encoder failed");
                goto done;
            }
        }
    }
    result = 0;
done:
    av_frame_free(&frame);
    return result;
}

typedef struct {
    const float *samples; /* Interleaved. */
    UInt32 frames, offset, channels;
} Feed;

static OSStatus feed_apple(AudioConverterRef converter, UInt32 *packets, AudioBufferList *data,
                           AudioStreamPacketDescription **descriptions, void *user) {
    (void)converter;
    Feed *feed = user;
    UInt32 left = feed->frames - feed->offset;
    UInt32 count = *packets < left ? *packets : left;
    data->mNumberBuffers = 1;
    data->mBuffers[0].mNumberChannels = feed->channels;
    data->mBuffers[0].mData = count ? (void *)(feed->samples + (size_t)feed->offset * feed->channels) : NULL;
    data->mBuffers[0].mDataByteSize = count * feed->channels * (UInt32)sizeof(float);
    if (descriptions)
        *descriptions = NULL;
    feed->offset += count;
    *packets = count;
    return noErr;
}

static int encode_apple(Encoder *encoder, float *const *sound, int frames, Encoded *encoded, char *error, size_t capacity) {
    size_t total = (size_t)frames * MPCUT_AAC_FRAME;
    float *interleaved = av_malloc_array(total * (size_t)encoder->channels, sizeof(float));
    enum { BATCH = 16 };
    uint8_t *buffer = av_malloc((size_t)encoder->largest_packet * BATCH);
    AudioStreamPacketDescription descriptions[BATCH];
    int result = 1;
    if (!interleaved || !buffer) {
        errorf(error, capacity, "Cannot allocate Apple's AAC encoder buffers");
        goto done;
    }
    for (size_t i = 0; i < total; i++)
        for (int c = 0; c < encoder->channels; c++)
            interleaved[i * encoder->channels + c] = sound[c][i];
    Feed feed = {.samples = interleaved, .frames = (UInt32)total, .channels = (UInt32)encoder->channels};
    for (;;) {
        UInt32 packets = BATCH;
        AudioBufferList list = {.mNumberBuffers = 1};
        list.mBuffers[0].mNumberChannels = (UInt32)encoder->channels;
        list.mBuffers[0].mDataByteSize = encoder->largest_packet * BATCH;
        list.mBuffers[0].mData = buffer;
        OSStatus status = AudioConverterFillComplexBuffer(encoder->converter, feed_apple, &feed, &packets, &list, descriptions);
        if (status != noErr) {
            errorf(error, capacity, "Apple's AAC encoder failed (%d)", (int)status);
            goto done;
        }
        if (!packets)
            break;
        for (UInt32 i = 0; i < packets; i++) {
            AVPacket *packet = av_packet_alloc();
            if (!packet || av_new_packet(packet, (int)descriptions[i].mDataByteSize) < 0) {
                av_packet_free(&packet);
                errorf(error, capacity, "Cannot allocate an AAC frame");
                goto done;
            }
            memcpy(packet->data, buffer + descriptions[i].mStartOffset, descriptions[i].mDataByteSize);
            if (append_packet(encoded, packet) < 0) {
                av_packet_free(&packet);
                errorf(error, capacity, "Cannot allocate an AAC frame");
                goto done;
            }
        }
    }
    result = 0;
done:
    av_free(interleaved);
    av_free(buffer);
    return result;
}

/* Encode `frames` frames of sound given per channel. */
static int encode(Encoder *encoder, float *const *sound, int frames, Encoded *encoded, char *error, size_t capacity) {
    memset(encoded, 0, sizeof(*encoded));
    int result = encoder->kind == MPCUT_AAC_BRIDGE_APPLE ? encode_apple(encoder, sound, frames, encoded, error, capacity)
                                                         : encode_ffmpeg(encoder, sound, frames, encoded, error, capacity);
    if (result)
        encoded_free(encoded);
    return result;
}

typedef struct {
    double bridge_rms, bridge_peak; /* Splice error over [0, g). */
    double head_rms, head_peak;     /* Over the first two copied frames of the later range. */
    double coded_rms, coded_peak;   /* The bridge encoder's own error, decoded without a splice. */
    double noise_rms, noise_peak;   /* How differently the later range's copied frames decode from another start. */
} Measures;

static void measure(double *rms, double *peak, double difference, size_t *count) {
    *rms += difference * difference;
    if (fabs(difference) > *peak)
        *peak = fabs(difference);
    (*count)++;
}

/* Encode one layout of the bridge and measure its splice. */
static int attempt(const MPCutAACBridge *bridge, const Run *before, const Run *after, Layout *plan,
                   MPCutAACBridgeFrames *frames, Measures *measures, char *error, size_t capacity) {
    int channels = before->channels;
    Encoder encoder;
    memset(measures, 0, sizeof(*measures));
    if (encoder_open(&encoder, bridge->encoder, before->codec, bridge->bit_rate, error, capacity))
        return 1;
    // The encoder's frame p decodes to the sound from x on: it follows its priming and `warm` frames of the earlier range.
    int64_t first_frame = WARM_FRAMES + (encoder.lead + MPCUT_AAC_FRAME - 1) / MPCUT_AAC_FRAME;
    int64_t origin = encoder.lead - first_frame * MPCUT_AAC_FRAME; /* Input coordinate of the first input sample. */
    int64_t span = -origin + plan->end + plan->trim + (int64_t)AHEAD_FRAMES * MPCUT_AAC_FRAME;
    int input_frames = (int)((span + MPCUT_AAC_FRAME - 1) / MPCUT_AAC_FRAME);
    float **sound = av_calloc(channels, sizeof(*sound));
    Encoded encoded = {0};
    AVPacket **sequence = NULL;
    int *trims = NULL;
    float **spliced = NULL, **coded = NULL, **reference = NULL;
    int64_t spliced_length = 0, coded_length = 0, reference_length = 0;
    int result = 1;
    if (!sound) {
        errorf(error, capacity, "Cannot allocate the AAC bridge sound");
        goto done;
    }
    for (int c = 0; c < channels; c++) {
        if (!(sound[c] = av_calloc((size_t)input_frames * MPCUT_AAC_FRAME, sizeof(float)))) {
            errorf(error, capacity, "Cannot allocate the AAC bridge sound");
            goto done;
        }
        for (int64_t i = 0; i < (int64_t)input_frames * MPCUT_AAC_FRAME; i++) {
            int64_t at = origin + i; /* Encoder input coordinate, from x. */
            float value;
            if (at < plan->trim_point) {
                value = wanted(bridge, plan, before, after, c, at);
            } else if (at < plan->trim_point + plan->trim) {
                int64_t k = at - plan->trim_point;
                double w = 0.5 - 0.5 * cos(M_PI * ((double)k + 0.5) / plan->trim);
                value = (float)((1 - w) * wanted(bridge, plan, before, after, c, plan->trim_point + k)
                                + w * wanted(bridge, plan, before, after, c, plan->trim_point - plan->trim + k));
            } else {
                value = wanted(bridge, plan, before, after, c, at - plan->trim);
            }
            sound[c][i] = value;
        }
    }
    if (encode(&encoder, sound, input_frames, &encoded, error, capacity))
        goto done;
    size_t first = (size_t)first_frame;
    if (encoded.count < first + (size_t)plan->frames) {
        errorf(error, capacity, "The AAC encoder returned too few frames");
        goto done;
    }
    if (encoder.context) {
        AVCodecParameters config = {.extradata = encoder.context->extradata, .extradata_size = encoder.context->extradata_size};
        int object, rate_index, layout_channels, encoded_object, encoded_rate, encoded_channels;
        if (config_fields(before->codec, &object, &rate_index, &layout_channels)
            || config_fields(&config, &encoded_object, &encoded_rate, &encoded_channels)
            || object != encoded_object || rate_index != encoded_rate || layout_channels != encoded_channels) {
            errorf(error, capacity, "The AAC encoder cannot reproduce the track's decoder configuration");
            goto done;
        }
    }

    // The splice as a reader decodes it: three copied frames, the bridge, three copied frames.
    size_t before_from = 0, after_count = 0;
    while (before_from < before->count && before->first + (int64_t)before_from * MPCUT_AAC_FRAME
           < bridge->previous_copy_end - HISTORY_FRAMES * MPCUT_AAC_FRAME)
        before_from++;
    size_t before_to = before_from;
    while (before_to < before->count && before->first + (int64_t)before_to * MPCUT_AAC_FRAME < bridge->previous_copy_end)
        before_to++;
    size_t after_from = 0;
    while (after_from < after->count && after->first + (int64_t)after_from * MPCUT_AAC_FRAME < bridge->copy_start)
        after_from++;
    after_count = after->count - after_from < HISTORY_FRAMES ? after->count - after_from : HISTORY_FRAMES;
    if (before_to != before_from + HISTORY_FRAMES || before->first + (int64_t)before_to * MPCUT_AAC_FRAME != bridge->previous_copy_end
        || after_count < 2 || after->first + (int64_t)after_from * MPCUT_AAC_FRAME != bridge->copy_start) {
        errorf(error, capacity, "The copied AAC frames around the join cannot be read");
        goto done;
    }
    size_t total = HISTORY_FRAMES + (size_t)plan->frames + after_count;
    sequence = av_calloc(total, sizeof(*sequence));
    trims = av_calloc(total, sizeof(*trims));
    if (!sequence || !trims) {
        errorf(error, capacity, "Cannot allocate the AAC splice");
        goto done;
    }
    for (size_t i = 0; i < HISTORY_FRAMES; i++)
        sequence[i] = before->packets[before_from + i];
    for (int i = 0; i < plan->frames; i++)
        sequence[HISTORY_FRAMES + i] = encoded.packets[first + i];
    for (size_t i = 0; i < after_count; i++)
        sequence[HISTORY_FRAMES + plan->frames + i] = after->packets[after_from + i];
    trims[HISTORY_FRAMES + plan->trimmed] = plan->trim;
    if (decode_frames(before->codec, sequence, total, trims, &spliced, &spliced_length, error, capacity))
        goto done;
    if (decode_frames(before->codec, encoded.packets, encoded.count, NULL, &coded, &coded_length, error, capacity))
        goto done;
    // The later run decoded from frames that are copied and history it never had in the source.
    size_t reference_from = after_from >= HISTORY_FRAMES ? after_from - HISTORY_FRAMES : 0;
    if (decode_frames(after->codec, after->packets + reference_from, after_from + after_count - reference_from, NULL,
                      &reference, &reference_length, error, capacity))
        goto done;

    size_t bridge_count = 0, head_count = 0, coded_count = 0, noise_count = 0;
    int64_t base = HISTORY_FRAMES * MPCUT_AAC_FRAME; /* Spliced index of x. */
    for (int c = 0; c < channels; c++) {
        for (int64_t at = 0; at < plan->end + 2 * MPCUT_AAC_FRAME && base + at < spliced_length; at++) {
            double difference = spliced[c][base + at] - wanted(bridge, plan, before, after, c, at);
            if (at < plan->end)
                measure(&measures->bridge_rms, &measures->bridge_peak, difference, &bridge_count);
            else
                measure(&measures->head_rms, &measures->head_peak, difference, &head_count);
        }
        // The encoder's continuous decode: input index i comes out after `lead` samples of priming.
        for (int64_t at = 0; at < plan->end + plan->trim; at++) {
            if (at >= plan->trim_point && at < plan->trim_point + plan->trim)
                continue;
            int64_t index = at - origin + encoder.lead;
            if (index >= coded_length)
                break;
            measure(&measures->coded_rms, &measures->coded_peak, coded[c][index] - sound[c][at - origin], &coded_count);
        }
        int64_t offset = (int64_t)(after_from - reference_from) * MPCUT_AAC_FRAME;
        for (int64_t i = 0; i < 2 * MPCUT_AAC_FRAME && offset + i < reference_length; i++)
            measure(&measures->noise_rms, &measures->noise_peak,
                    reference[c][offset + i] - run_sample(after, c, bridge->copy_start + i), &noise_count);
    }
    measures->bridge_rms = bridge_count ? sqrt(measures->bridge_rms / bridge_count) : 0;
    measures->head_rms = head_count ? sqrt(measures->head_rms / head_count) : 0;
    measures->coded_rms = coded_count ? sqrt(measures->coded_rms / coded_count) : 0;
    measures->noise_rms = noise_count ? sqrt(measures->noise_rms / noise_count) : 0;

    if (frames) {
        frames->packets = av_calloc(plan->frames, sizeof(*frames->packets));
        if (!frames->packets) {
            errorf(error, capacity, "Cannot allocate the AAC bridge");
            goto done;
        }
        frames->count = plan->frames;
        frames->trimmed = plan->trimmed;
        frames->trim = plan->trim;
        for (int i = 0; i < plan->frames; i++) {
            frames->packets[i] = encoded.packets[first + i];
            encoded.packets[first + i] = NULL;
            AVPacket *packet = frames->packets[i];
            av_packet_side_data_remove(packet->side_data, &packet->side_data_elems, AV_PKT_DATA_SKIP_SAMPLES);
            packet->duration = MPCUT_AAC_FRAME;
            if (i == plan->trimmed && plan->trim) {
                uint8_t *side = av_packet_new_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, 10);
                if (!side) {
                    errorf(error, capacity, "Cannot allocate the AAC bridge trim");
                    goto done;
                }
                memset(side, 0, 10);
                side[4] = plan->trim & 0xff;
                side[5] = (plan->trim >> 8) & 0xff;
            }
        }
    }
    result = 0;
done:
    for (int c = 0; sound && c < channels; c++)
        av_freep(&sound[c]);
    av_freep(&sound);
    for (int c = 0; spliced && c < channels; c++)
        av_freep(&spliced[c]);
    av_freep(&spliced);
    for (int c = 0; coded && c < channels; c++)
        av_freep(&coded[c]);
    av_freep(&coded);
    for (int c = 0; reference && c < channels; c++)
        av_freep(&reference[c]);
    av_freep(&reference);
    av_freep(&sequence);
    av_freep(&trims);
    encoded_free(&encoded);
    encoder_close(&encoder);
    return result;
}

/* A splice passes when it adds no more than the bridge encoder's own error, and the copied frames after it decode
 * as they do from another start, to within that error. The floors keep silence from failing on rounding. */
static int splice_passes(const Measures *m) {
    return m->bridge_rms <= 1.5 * m->coded_rms + 1e-4 && m->bridge_peak <= 2 * m->coded_peak + 1e-3
        && m->head_rms <= 1.5 * (m->coded_rms + m->noise_rms) + 1e-4
        && m->head_peak <= 2 * (m->coded_peak + m->noise_peak) + 1e-3;
}

static int load_sides(const MPCutAACBridge *bridge, Run *before, Run *after, char *error, size_t capacity) {
    // Room for the warm-up, one frame of crossfade that can reach behind x, and a frame moved by planning.
    int64_t before_from = bridge->previous_copy_end - (WARM_FRAMES + 2) * MPCUT_AAC_FRAME;
    if (load_run(bridge->previous_path, bridge->previous_stream, bridge->previous_origin, bridge->previous_grid,
                 before_from, bridge->previous_cut + MPCUT_AAC_FRAME, before, error, capacity))
        return 1;
    if (load_run(bridge->path, bridge->stream, bridge->origin, bridge->grid, bridge->cut,
                 bridge->copy_start + (AHEAD_FRAMES + HISTORY_FRAMES + 3) * MPCUT_AAC_FRAME, after, error, capacity)) {
        run_free(before);
        return 1;
    }
    const char *issue = config_issue(before->codec);
    if (!issue)
        issue = config_issue(after->codec);
    if (issue) {
        run_free(before);
        run_free(after);
        return errorf(error, capacity, "Smart Trim cannot encode AAC frames at this join because %s", issue);
    }
    if (before->codec->sample_rate != after->codec->sample_rate || before->channels != after->channels) {
        run_free(before);
        run_free(after);
        return errorf(error, capacity, "The AAC tracks on either side of the join have different rates or channels");
    }
    return 0;
}

int mpcut_plan_aac_bridge(MPCutAACBridge *bridge, MPCutAACBridgeReport *report, char *error, size_t capacity) {
    Run before, after;
    if (load_sides(bridge, &before, &after, error, capacity))
        return 1;
    const int64_t moves[][2] = {{0, 0}, {-MPCUT_AAC_FRAME, 0}, {0, MPCUT_AAC_FRAME}, {-MPCUT_AAC_FRAME, MPCUT_AAC_FRAME}};
    int64_t copy_end = bridge->previous_copy_end, copy_start = bridge->copy_start;
    int result = 1;
    int tried = 0;
    if (error && capacity)
        error[0] = '\0';
    for (size_t i = 0; i < sizeof(moves) / sizeof(moves[0]); i++) {
        MPCutAACBridge candidate = *bridge;
        candidate.previous_copy_end = copy_end + moves[i][0];
        candidate.copy_start = copy_start + moves[i][1];
        if (candidate.previous_copy_end < candidate.previous_floor || candidate.copy_start > candidate.ceiling)
            continue;
        Layout plan;
        if (layout(&candidate, &plan, error, capacity))
            continue;
        for (int kind = MPCUT_AAC_BRIDGE_FFMPEG; kind <= MPCUT_AAC_BRIDGE_APPLE && result; kind++) {
        candidate.encoder = kind;
        MPCutAACBridgeFrames frames = {0};
        Measures measures;
        char reason[256] = {0};
        if (attempt(&candidate, &before, &after, &plan, &frames, &measures, reason, sizeof(reason))) {
            if (!tried)
                errorf(error, capacity, "%s", reason);
            continue;
        }
        tried++;
        if (splice_passes(&measures)) {
            uint64_t bytes = 0;
            for (int f = 0; f < frames.count; f++)
                bytes += (uint64_t)frames.packets[f]->size;
            mpcut_aac_bridge_frames_free(&frames);
            *bridge = candidate;
            if (report)
                *report = (MPCutAACBridgeReport){.frames = plan.frames, .trim = plan.trim, .bytes = bytes};
            result = 0;
            break;
        }
        mpcut_aac_bridge_frames_free(&frames);
        errorf(error, capacity, "The encoded AAC frames at this join would not decode within the codec's own error "
               "(splice error %.1f dB, encoder error %.1f dB)",
               20 * log10(fmax(fmax(measures.bridge_rms, measures.head_rms), 1e-9)), 20 * log10(fmax(measures.coded_rms, 1e-9)));
        }
        if (!result)
            break;
    }
    if (result && !tried && !(error && *error))
        errorf(error, capacity, "The ranges at this join are too short for encoded AAC frames");
    run_free(&before);
    run_free(&after);
    return result;
}

int mpcut_build_aac_bridge(const MPCutAACBridge *bridge, MPCutAACBridgeFrames *frames, char *error, size_t capacity) {
    memset(frames, 0, sizeof(*frames));
    Run before, after;
    if (load_sides(bridge, &before, &after, error, capacity))
        return 1;
    Layout plan;
    Measures measures;
    int result = layout(bridge, &plan, error, capacity)
        || attempt(bridge, &before, &after, &plan, frames, &measures, error, capacity);
    if (!result && !splice_passes(&measures)) {
        mpcut_aac_bridge_frames_free(frames);
        result = errorf(error, capacity, "The encoded AAC frames at a join no longer decode within the codec's own error");
    }
    run_free(&before);
    run_free(&after);
    return result;
}

void mpcut_aac_bridge_frames_free(MPCutAACBridgeFrames *frames) {
    for (int i = 0; frames->packets && i < frames->count; i++)
        av_packet_free(&frames->packets[i]);
    av_freep(&frames->packets);
    memset(frames, 0, sizeof(*frames));
}
