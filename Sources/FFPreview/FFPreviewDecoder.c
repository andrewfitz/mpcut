#include "FFPreviewDecoder.h"

#include <AudioToolbox/AudioToolbox.h>
#include <libavcodec/videotoolbox.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/display.h>
#include <libswresample/swresample.h>
#include <math.h>

typedef struct {
    AVCodecContext *codec;
    int index;
    bool drained;
} PreviewStream;

struct MPPreviewDecoder {
    AVFormatContext *format;
    PreviewStream video;
    PreviewStream audio;
    PreviewStream *receiving;
    AVVideotoolboxContext hardware;
    AVPacket *packet;
    AVFrame *frame;
    SwrContext *resampler;
    AVChannelLayout audio_layout;
    int audio_rate;
    enum AVSampleFormat audio_format;
    bool audio_unavailable;
    bool eof;
    bool awaiting_keyframe;
    int64_t origin;
    CMTime timeline_origin;
    MPPreviewCancelled cancelled;
    void *cancel_context;
};

static int preview_cancelled(void *context)
{
    MPPreviewDecoder *preview = context;
    return preview->cancelled && preview->cancelled(preview->cancel_context);
}

static void clear_hardware(AVVideotoolboxContext *hardware)
{
    if (hardware->session) {
        VTDecompressionSessionInvalidate(hardware->session);
        CFRelease(hardware->session);
        hardware->session = NULL;
    }
    if (hardware->cm_fmt_desc) {
        CFRelease(hardware->cm_fmt_desc);
        hardware->cm_fmt_desc = NULL;
    }
}

// FFmpeg's explicit VideoToolbox context exposes the active session so each
// returned picture can be verified against VideoToolbox's hardware property.
static enum AVPixelFormat hardware_format(AVCodecContext *codec, const enum AVPixelFormat *formats)
{
    for (; *formats != AV_PIX_FMT_NONE; formats++) {
        if (*formats == AV_PIX_FMT_VIDEOTOOLBOX) {
            MPPreviewDecoder *preview = codec->opaque;
            // FFmpeg leaves the caller-owned session intact when changing
            // formats. Release it before initializing the replacement.
            clear_hardware(&preview->hardware);
            codec->hwaccel_context = &preview->hardware;
            return *formats;
        }
    }
    return AV_PIX_FMT_NONE;
}

static const AVCodec *find_video_decoder(enum AVCodecID codec_id)
{
    void *iterator = NULL;
    const AVCodec *codec;
    while ((codec = av_codec_iterate(&iterator))) {
        if (!av_codec_is_decoder(codec) || codec->id != codec_id)
            continue;
        const AVCodecHWConfig *config;
        for (int index = 0; (config = avcodec_get_hw_config(codec, index)); index++) {
            if (config->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
                return codec;
        }
    }
    return NULL;
}

static CMTime timestamp_time(int64_t timestamp, AVRational base)
{
    return CMTimeMultiplyByRatio(CMTimeMake(timestamp, base.den), base.num, 1);
}

static bool open_stream(MPPreviewDecoder *preview, PreviewStream *stream, enum AVMediaType type)
{
    const AVCodec *decoder = NULL;
    stream->index = av_find_best_stream(preview->format, type, -1, -1, NULL, 0);
    if (stream->index < 0)
        return false;
    AVStream *source = preview->format->streams[stream->index];
    decoder = type == AVMEDIA_TYPE_VIDEO
        ? find_video_decoder(source->codecpar->codec_id)
        : avcodec_find_decoder(source->codecpar->codec_id);
    if (!decoder)
        return false;
    AVCodecContext *codec = avcodec_alloc_context3(decoder);
    if (!codec)
        return false;
    if (avcodec_parameters_to_context(codec, source->codecpar) < 0)
        goto failure;
    codec->pkt_timebase = source->time_base;
    codec->thread_count = 1;
    if (type == AVMEDIA_TYPE_VIDEO) {
        codec->opaque = preview;
        codec->get_format = hardware_format;
    }
    if (avcodec_open2(codec, decoder, NULL) < 0)
        goto failure;
    stream->codec = codec;
    return true;

failure:
    avcodec_free_context(&codec);
    return false;
}

MPPreviewDecoder *mp_preview_open(const char *path, MPPreviewCancelled cancelled,
                                 void *context, const char **error)
{
    *error = "Could not allocate the preview decoder.";
    MPPreviewDecoder *preview = calloc(1, sizeof(*preview));
    if (!preview)
        return NULL;
    preview->packet = av_packet_alloc();
    preview->frame = av_frame_alloc();
    preview->format = avformat_alloc_context();
    if (!preview->packet || !preview->frame || !preview->format)
        goto failure;
    preview->cancelled = cancelled;
    preview->cancel_context = context;
    preview->format->interrupt_callback = (AVIOInterruptCB){preview_cancelled, preview};
    *error = "FFmpeg could not open this media for preview.";
    if (avformat_open_input(&preview->format, path, NULL, NULL) < 0)
        goto failure;
    preview->format->probesize = 2 * 1024 * 1024;
    preview->format->max_analyze_duration = 2 * AV_TIME_BASE;
    if (avformat_find_stream_info(preview->format, NULL) < 0)
        goto failure;
    *error = "This video stream has no compatible VideoToolbox decoder.";
    if (!open_stream(preview, &preview->video, AVMEDIA_TYPE_VIDEO))
        goto failure;
    if (!open_stream(preview, &preview->audio, AVMEDIA_TYPE_AUDIO))
        preview->audio_unavailable = preview->audio.index >= 0;
    AVStream *video = preview->format->streams[preview->video.index];
    preview->origin = video->start_time == AV_NOPTS_VALUE ? preview->format->start_time
        : av_rescale_q(video->start_time, video->time_base, AV_TIME_BASE_Q);
    if (preview->origin == AV_NOPTS_VALUE)
        preview->origin = 0;
    preview->timeline_origin = video->start_time == AV_NOPTS_VALUE
        ? CMTimeMake(preview->origin, AV_TIME_BASE)
        : timestamp_time(video->start_time, video->time_base);
    preview->awaiting_keyframe = true;
    *error = NULL;
    return preview;

failure:
    mp_preview_close(preview);
    return NULL;
}

void mp_preview_close(MPPreviewDecoder *preview)
{
    if (!preview)
        return;
    preview->cancelled = NULL;
    clear_hardware(&preview->hardware);
    avcodec_free_context(&preview->video.codec);
    avcodec_free_context(&preview->audio.codec);
    av_frame_free(&preview->frame);
    av_packet_free(&preview->packet);
    swr_free(&preview->resampler);
    av_channel_layout_uninit(&preview->audio_layout);
    if (preview->format && !preview->format->iformat)
        avformat_free_context(preview->format);
    else
        avformat_close_input(&preview->format);
    free(preview);
}

bool mp_preview_has_audio(const MPPreviewDecoder *preview)
{
    return preview->audio.codec && !preview->audio_unavailable;
}

bool mp_preview_has_unavailable_audio(const MPPreviewDecoder *preview)
{
    return preview->audio_unavailable;
}

CGAffineTransform mp_preview_transform(const MPPreviewDecoder *preview)
{
    const AVStream *stream = preview->format->streams[preview->video.index];
    const AVPacketSideData *side = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (!side || side->size < 9 * sizeof(int32_t))
        return CGAffineTransformIdentity;
    int32_t matrix[9];
    memcpy(matrix, side->data, sizeof(matrix));
    if (matrix[2] || matrix[5] || matrix[8] != (1 << 30))
        return CGAffineTransformIdentity;
    return CGAffineTransformMake(matrix[0] / 65536.0, matrix[1] / 65536.0,
        matrix[3] / 65536.0, matrix[4] / 65536.0,
        matrix[6] / 65536.0, matrix[7] / 65536.0);
}

static int seek_transport_stream(MPPreviewDecoder *preview, int64_t target)
{
    const AVRational base = preview->video.codec->pkt_timebase;
    const int64_t desired = av_rescale_q(target + preview->origin, AV_TIME_BASE_Q, base);
    // The transport stream demuxer indexes decode timestamps, which need not
    // belong to random-access packets. Confirm a keyframe before the target.
    for (int64_t preroll = 2 * AV_TIME_BASE; preroll < target; ) {
        int64_t timestamp = av_rescale_q(target - preroll + preview->origin, AV_TIME_BASE_Q, base);
        if (av_seek_frame(preview->format, preview->video.index, timestamp, AVSEEK_FLAG_BACKWARD) >= 0) {
            int64_t replay_position = INT64_MAX;
            while (!preview_cancelled(preview) && av_read_frame(preview->format, preview->packet) >= 0) {
                AVPacket *packet = preview->packet;
                bool video = packet->stream_index == preview->video.index;
                bool key = video && (packet->flags & AV_PKT_FLAG_KEY);
                int64_t position = packet->pos;
                int64_t pts = packet->pts;
                int64_t dts = packet->dts;
                av_packet_unref(packet);
                if (position >= 0 && position < replay_position)
                    replay_position = position;
                if (key && pts != AV_NOPTS_VALUE && pts <= desired && position >= 0) {
                    // Replay from the byte position so indexes populated during
                    // this scan cannot shift the seek past the confirmed key.
                    return av_seek_frame(preview->format, -1, replay_position, AVSEEK_FLAG_BYTE);
                }
                if (video && dts != AV_NOPTS_VALUE && dts > desired)
                    break;
            }
        }
        if (preview_cancelled(preview))
            return AVERROR_EXIT;
        if (preroll > target / 2)
            break;
        preroll *= 2;
    }
    return av_seek_frame(preview->format, -1, 0, AVSEEK_FLAG_BYTE);
}

bool mp_preview_seek(MPPreviewDecoder *preview, double seconds)
{
    if (!isfinite(seconds) || seconds < 0 || seconds >= (double)INT64_MAX / AV_TIME_BASE)
        return false;
    int64_t target = llround(seconds * AV_TIME_BASE);
    if (preview->origin > 0 && target > INT64_MAX - preview->origin)
        return false;
    int result;
    if (strcmp(preview->format->iformat->name, "mpegts") == 0) {
        result = seek_transport_stream(preview, target);
    } else {
        int64_t preroll = mp_preview_has_audio(preview) ? AV_TIME_BASE / 4 : 0;
        int64_t timestamp = av_rescale_q(FFMAX(0, target - preroll) + preview->origin, AV_TIME_BASE_Q,
            preview->video.codec->pkt_timebase);
        result = av_seek_frame(preview->format, preview->video.index, timestamp, AVSEEK_FLAG_BACKWARD);
    }
    if (result < 0)
        return false;
    avcodec_flush_buffers(preview->video.codec);
    if (preview->audio.codec)
        avcodec_flush_buffers(preview->audio.codec);
    swr_free(&preview->resampler);
    preview->video.drained = false;
    preview->audio.drained = false;
    preview->receiving = NULL;
    preview->eof = false;
    preview->awaiting_keyframe = true;
    av_packet_unref(preview->packet);
    av_frame_unref(preview->frame);
    return true;
}

static CMTime sample_time(const MPPreviewDecoder *preview, const PreviewStream *stream)
{
    const int64_t pts = preview->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE)
        return kCMTimeInvalid;
    return CMTimeSubtract(timestamp_time(pts, stream->codec->pkt_timebase), preview->timeline_origin);
}

static bool using_hardware(const MPPreviewDecoder *preview)
{
    if (!preview->hardware.session)
        return false;
    CFTypeRef property = NULL;
    OSStatus status = VTSessionCopyProperty(preview->hardware.session,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &property);
    bool hardware = status == noErr && property == kCFBooleanTrue;
    if (property)
        CFRelease(property);
    return hardware;
}

static CMSampleBufferRef video_sample(MPPreviewDecoder *preview)
{
    AVFrame *frame = preview->frame;
    CVPixelBufferRef image = (CVPixelBufferRef)frame->data[3];
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    CMTime pts = sample_time(preview, &preview->video);
    if (!image || !CMTIME_IS_VALID(pts))
        return NULL;
    av_vt_pixbuf_set_attachments(preview->video.codec, image, frame);
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, image, &description) != noErr)
        return NULL;
    AVRational base = preview->video.codec->pkt_timebase;
    CMTime duration = frame->duration > 0 ? timestamp_time(frame->duration, base) : kCMTimeInvalid;
    CMSampleTimingInfo timing = {duration, pts, kCMTimeInvalid};
    CMSampleBufferCreateReadyWithImageBuffer(NULL, image, description, &timing, &sample);
    CFRelease(description);
    return sample;
}

static bool configure_resampler(MPPreviewDecoder *preview)
{
    AVFrame *frame = preview->frame;
    if (preview->resampler && preview->audio_format == frame->format &&
        preview->audio_rate == frame->sample_rate &&
        av_channel_layout_compare(&preview->audio_layout, &frame->ch_layout) == 0)
        return true;

    swr_free(&preview->resampler);
    av_channel_layout_uninit(&preview->audio_layout);
    if (av_channel_layout_copy(&preview->audio_layout, &frame->ch_layout) < 0)
        return false;
    preview->audio_format = frame->format;
    preview->audio_rate = frame->sample_rate;
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    if (swr_alloc_set_opts2(&preview->resampler, &stereo, AV_SAMPLE_FMT_FLT, frame->sample_rate,
                           &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL) < 0 ||
        swr_init(preview->resampler) < 0) {
        swr_free(&preview->resampler);
        return false;
    }
    return true;
}

static CMSampleBufferRef audio_sample(MPPreviewDecoder *preview)
{
    AVFrame *frame = preview->frame;
    CMTime pts = sample_time(preview, &preview->audio);
    if (!CMTIME_IS_VALID(pts) || frame->nb_samples <= 0 || frame->nb_samples > 65536 ||
        frame->sample_rate <= 0 || !configure_resampler(preview))
        return NULL;

    const size_t stride = 2 * sizeof(float);
    size_t bytes = (size_t)frame->nb_samples * stride;
    CMBlockBufferRef data = NULL;
    CMAudioFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes,
                                           kCMBlockBufferAssureMemoryNowFlag, &data) != noErr)
        return NULL;
    char *destination = NULL;
    if (CMBlockBufferGetDataPointer(data, 0, NULL, NULL, &destination) != noErr)
        goto finish;
    uint8_t *output = (uint8_t *)destination;
    int samples = swr_convert(preview->resampler, &output, frame->nb_samples,
                              (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (samples <= 0)
        goto finish;
    AudioStreamBasicDescription format = {
        .mSampleRate = frame->sample_rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = stride,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = stride,
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 8 * sizeof(float),
    };
    if (CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &description) == noErr)
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, description, samples,
                                                            pts, NULL, &sample);
finish:
    if (description)
        CFRelease(description);
    CFRelease(data);
    return sample;
}

int mp_preview_next(MPPreviewDecoder *preview, CMSampleBufferRef *sample, const char **error)
{
    *sample = NULL;
    *error = NULL;
    // Yield periodically even when an edited or damaged container has long gaps.
    for (int step = 0; step < 32; step++) {
        if (preview_cancelled(preview))
            return MPPreviewAgain;
        if (preview->receiving) {
            PreviewStream *stream = preview->receiving;
            int result = avcodec_receive_frame(stream->codec, preview->frame);
            if (result == 0) {
                int kind = stream == &preview->video ? MPPreviewVideo : MPPreviewAudio;
                if (kind == MPPreviewVideo) {
                    if (preview->frame->format != AV_PIX_FMT_VIDEOTOOLBOX || !using_hardware(preview)) {
                        av_frame_unref(preview->frame);
                        *error = "VideoToolbox could not decode this stream in hardware.";
                        return MPPreviewError;
                    }
                    *sample = video_sample(preview);
                } else {
                    *sample = audio_sample(preview);
                }
                av_frame_unref(preview->frame);
                if (*sample)
                    return kind;
                if (kind == MPPreviewVideo) {
                    *error = "A decoded video frame could not be presented.";
                    return MPPreviewError;
                }
                preview->audio_unavailable = true;
                continue;
            }
            preview->receiving = NULL;
            if (result == AVERROR_EOF)
                stream->drained = true;
            else if (result != AVERROR(EAGAIN)) {
                if (stream == &preview->video) {
                    *error = "VideoToolbox could not decode this stream.";
                    return MPPreviewError;
                }
                preview->audio_unavailable = true;
            }
        }
        if (preview->eof) {
            PreviewStream *stream = &preview->video;
            if (stream->drained)
                stream = &preview->audio;
            if (stream->drained || !stream->codec || (stream == &preview->audio && preview->audio_unavailable))
                return MPPreviewEnd;
            int result = avcodec_send_packet(stream->codec, NULL);
            if (result == AVERROR_EOF) {
                stream->drained = true;
            } else if (result == 0 || result == AVERROR(EAGAIN)) {
                preview->receiving = stream;
            } else if (stream == &preview->video) {
                *error = "VideoToolbox could not finish decoding this stream.";
                return MPPreviewError;
            } else {
                stream->drained = true;
                preview->audio_unavailable = true;
            }
            continue;
        }
        int result = av_read_frame(preview->format, preview->packet);
        if (result == AVERROR_EOF) {
            preview->eof = true;
            continue;
        }
        if (result < 0) {
            *error = "FFmpeg could not read the next preview packet.";
            return MPPreviewError;
        }
        PreviewStream *stream = NULL;
        if (preview->packet->stream_index == preview->video.index) {
            if (!preview->awaiting_keyframe || (preview->packet->flags & AV_PKT_FLAG_KEY)) {
                preview->awaiting_keyframe = false;
                stream = &preview->video;
            }
        } else if (preview->packet->stream_index == preview->audio.index && !preview->audio_unavailable)
            stream = &preview->audio;
        if (stream && stream->codec)
            result = avcodec_send_packet(stream->codec, preview->packet);
        av_packet_unref(preview->packet);
        if (!stream || !stream->codec)
            continue;
        if (result < 0) {
            if (stream == &preview->video) {
                *error = "VideoToolbox could not decode this stream.";
                return MPPreviewError;
            }
            preview->audio_unavailable = true;
        } else {
            preview->receiving = stream;
        }
    }
    return MPPreviewAgain;
}
