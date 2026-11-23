#include "FFPreviewDecoder.h"
#include "LinkedAudioMix.h"

#include <AudioToolbox/AudioToolbox.h>
#include <libavcodec/videotoolbox.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/display.h>
#include <libswresample/swresample.h>
#include <math.h>
#include <float.h>

typedef struct {
    AVCodecContext *codec;
    int index;
    bool drained;
} PreviewStream;

struct MPPreviewDecoder {
    AVFormatContext *format;
    LinkedAudioMix *mix;
    CMSampleBufferRef mixed_audio, mixed_picture;
    bool mix_video_end, mix_audio_end, linked_lane;
    PreviewStream video;
    PreviewStream audio;
    PreviewStream *receiving;
    AVVideotoolboxContext hardware;
    VTDecompressionSessionRef verified_session;
    AVPacket *packet;
    AVFrame *frame;
    CMVideoFormatDescriptionRef video_description;
    CMAudioFormatDescriptionRef audio_description;
    bool preserve_surround;
    bool preserve_audio_channels;
    SwrContext *resampler;
    AVChannelLayout audio_layout;
    int audio_rate;
    enum AVSampleFormat audio_format;
    bool audio_unavailable;
    int audio_failures;
    int video_failures;
    bool met_damage;
    bool late_damage;
    bool recovering;
    bool audio_enabled;
    bool audio_only;
    bool eof;
    bool awaiting_keyframe;
    bool encoding_edge;
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
            if (preview->verified_session) {
                CFRelease(preview->verified_session);
                preview->verified_session = NULL;
            }
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

static int find_stream(const AVFormatContext *format, enum AVMediaType type, int ordinal)
{
    for (unsigned index = 0; index < format->nb_streams; index++) {
        const AVStream *stream = format->streams[index];
        if (stream->codecpar->codec_type != type || (stream->disposition & AV_DISPOSITION_ATTACHED_PIC))
            continue;
        if (ordinal-- == 0)
            return (int)index;
    }
    return -1;
}

static bool open_stream(MPPreviewDecoder *preview, PreviewStream *stream, int index, enum AVMediaType type)
{
    const AVCodec *decoder = NULL;
    stream->index = index;
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

MPPreviewDecoder *mp_preview_open(const char *path, enum MPPreviewTracks tracks, int audio_ordinal, CMTime origin,
                                 MPPreviewCancelled cancelled,
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
    preview->audio_only = tracks == MPPreviewSoundOnly;
    preview->audio_enabled = tracks != MPPreviewPictureOnly;
    preview->video.index = -1;
    preview->audio.index = -1;
    int picture = find_stream(preview->format, AVMEDIA_TYPE_VIDEO, 0);
    // Match the index's picture selection. A default cover image is still
    // attached artwork and must not replace the timed stream or its clock.
    if (!preview->audio_only && !open_stream(preview, &preview->video, picture, AVMEDIA_TYPE_VIDEO)) {
        *error = "This video stream has no compatible VideoToolbox decoder.";
        goto failure;
    }
    int first_audio = find_stream(preview->format, AVMEDIA_TYPE_AUDIO, 0);
    int audio = audio_ordinal >= 0 ? find_stream(preview->format, AVMEDIA_TYPE_AUDIO, audio_ordinal) :
        picture < 0 ? first_audio : av_find_best_stream(preview->format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    int lane_count = 0;
    if (picture >= 0 && audio_ordinal < 0 && preview->audio_enabled) {
        for (unsigned i = 0; i < preview->format->nb_streams; i++)
            if (preview->format->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
                lane_count++;
    }
    // An explicit ordinal and a standalone audio file each monitor one track.
    if (lane_count > 1) {
        preview->mix = linked_mix_create(lane_count);
        if (!preview->mix) {
            *error = "Could not allocate the linked preview audio mix.";
            goto failure;
        }
        int ordinal = 0;
        for (unsigned i = 0; i < preview->format->nb_streams; i++) {
            AVStream *lane = preview->format->streams[i];
            if (lane->codecpar->codec_type != AVMEDIA_TYPE_AUDIO)
                continue;
            const char *lane_error = NULL;
            MPPreviewDecoder *child = mp_preview_open(path, MPPreviewSoundOnly, ordinal, origin, cancelled, context,
                                                      &lane_error);
            if (child)
                child->linked_lane = true;
            linked_mix_set_lane(preview->mix, ordinal++, child, lane->time_base);
            if (preview_cancelled(preview)) {
                *error = "Preview opening was cancelled.";
                goto failure;
            }
        }
    } else if (preview->audio_enabled && !open_stream(preview, &preview->audio, audio, AVMEDIA_TYPE_AUDIO)) {
        preview->audio_unavailable = preview->audio.index >= 0;
        if (preview->audio_only && preview->audio_unavailable) {
            *error = "This audio stream has no compatible decoder.";
            goto failure;
        }
    }
    for (unsigned i = 0; i < preview->format->nb_streams; i++) {
        if ((int)i != preview->video.index && (int)i != preview->audio.index)
            preview->format->streams[i]->discard = AVDISCARD_ALL;
    }

    // A scrub of a movie's audio uses its picture clock even when decoding sound alone.
    int clock = preview->video.index;
    if (clock < 0)
        clock = picture >= 0 ? picture : first_audio;
    if (clock < 0) {
        *error = "The source contains no playable stream.";
        goto failure;
    }
    AVStream *stream = preview->format->streams[clock];
    if (CMTIME_IS_NUMERIC(origin))
        preview->timeline_origin = origin;
    else if (stream->start_time != AV_NOPTS_VALUE)
        preview->timeline_origin = timestamp_time(stream->start_time, stream->time_base);
    else
        preview->timeline_origin = CMTimeMake(preview->format->start_time == AV_NOPTS_VALUE ?
                                              0 : preview->format->start_time, AV_TIME_BASE);
    preview->origin = CMTimeConvertScale(preview->timeline_origin, AV_TIME_BASE,
                                         kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    preview->awaiting_keyframe = true;
    *error = NULL;
    return preview;

failure:
    mp_preview_close(preview);
    return NULL;
}

const AVStream *mp_preview_prepare_edge(MPPreviewDecoder *preview)
{
    if (!preview || !preview->video.codec || preview->hardware.session)
        return NULL;
    const AVStream *stream = preview->format->streams[preview->video.index];
    const AVCodecParameters *codec = stream->codecpar;
    bool full_range = codec->color_range == AVCOL_RANGE_JPEG || codec->format == AV_PIX_FMT_YUVJ420P;
    bool main10 = codec->codec_id == AV_CODEC_ID_HEVC && codec->profile == AV_PROFILE_HEVC_MAIN_10 &&
                  codec->format == AV_PIX_FMT_YUV420P10LE;
    if (!main10 && codec->format != AV_PIX_FMT_YUV420P && codec->format != AV_PIX_FMT_YUVJ420P)
        return NULL;
    preview->encoding_edge = true;
    preview->video.codec->err_recognition |= AV_EF_EXPLODE;
    if (main10)
        preview->hardware.cv_pix_fmt_type = full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                                                       : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    else
        preview->hardware.cv_pix_fmt_type = full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                  : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    return stream;
}

void mp_preview_coded_size(const MPPreviewDecoder *preview, int *width, int *height)
{
    *width = preview->video.codec ? preview->video.codec->coded_width : 0;
    *height = preview->video.codec ? preview->video.codec->coded_height : 0;
}

void mp_preview_close(MPPreviewDecoder *preview)
{
    if (!preview)
        return;
    preview->cancelled = NULL;
    linked_mix_close(preview->mix);
    if (preview->mixed_audio)
        CFRelease(preview->mixed_audio);
    if (preview->mixed_picture)
        CFRelease(preview->mixed_picture);
    if (preview->verified_session)
        CFRelease(preview->verified_session);
    clear_hardware(&preview->hardware);
    avcodec_free_context(&preview->video.codec);
    avcodec_free_context(&preview->audio.codec);
    av_frame_free(&preview->frame);
    av_packet_free(&preview->packet);
    if (preview->video_description)
        CFRelease(preview->video_description);
    if (preview->audio_description)
        CFRelease(preview->audio_description);
    swr_free(&preview->resampler);
    av_channel_layout_uninit(&preview->audio_layout);
    if (preview->format && !preview->format->iformat)
        avformat_free_context(preview->format);
    else
        avformat_close_input(&preview->format);
    free(preview);
}

void mp_preview_enable_audio(MPPreviewDecoder *preview, bool enabled)
{
    if (preview->mix)
        preview->audio_enabled = enabled;
    if (preview->audio.index >= 0) {
        preview->format->streams[preview->audio.index]->discard = enabled ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
        preview->audio_enabled = enabled;
    }
}

bool mp_preview_has_audio(const MPPreviewDecoder *preview)
{
    if (preview->mix)
        return preview->audio_enabled && linked_mix_has_audio(preview->mix);
    return preview->audio_enabled && preview->audio.codec && !preview->audio_unavailable;
}

bool mp_preview_has_unavailable_audio(const MPPreviewDecoder *preview)
{
    return preview->mix ? linked_mix_unavailable(preview->mix) : preview->audio_unavailable;
}

CGAffineTransform mp_preview_transform(const MPPreviewDecoder *preview)
{
    if (preview->video.index < 0)
        return CGAffineTransformIdentity;
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

static int seek_transport_stream(MPPreviewDecoder *preview, int64_t target, int64_t desired)
{
    const AVRational base = preview->video.codec->pkt_timebase;
    // The transport stream demuxer indexes decode timestamps, which need not
    // belong to random-access packets. Confirm a keyframe before the target.
    for (int64_t preroll = 2 * AV_TIME_BASE; preroll < target; ) {
        int64_t preroll_ticks = av_rescale_q(preroll, AV_TIME_BASE_Q, base);
        if (preroll_ticks < 0 || desired < INT64_MIN + preroll_ticks)
            break;
        int64_t timestamp = desired - preroll_ticks;
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

static bool seek_preview(MPPreviewDecoder *preview, double seconds, bool from_timeline_origin)
{
    if (!isfinite(seconds) || seconds < 0 || seconds * AV_TIME_BASE >= 0x1p63)
        return false;
    int64_t target = llround(seconds * AV_TIME_BASE);
    if (preview->mix) {
        if (preview->mixed_audio)
            CFRelease(preview->mixed_audio);
        if (preview->mixed_picture)
            CFRelease(preview->mixed_picture);
        preview->mixed_audio = preview->mixed_picture = NULL;
        preview->mix_audio_end = preview->mix_video_end = false;
        if (preview->audio_enabled && !linked_mix_seek(preview->mix, seconds))
            return false;
        if (preview->audio_only)
            return true;
    }
    int result;
    if (preview->audio_only) {
        if (!preview->audio.codec)
            return !preview->audio_unavailable;
        if (preview->origin > 0 && target > INT64_MAX - preview->origin)
            return false;
        // Decode a little audio preroll for transform codecs, independently of the video GOP.
        int64_t absolute = preview->origin + FFMAX(0, target - AV_TIME_BASE / 4);
        // The raw MP3 demuxer gives encoded packet zero PTS zero, but the
        // first audible sample can be several reservoir frames later.
        if (target <= AV_TIME_BASE / 4 && strcmp(preview->format->iformat->name, "mp3") == 0)
            absolute = 0;
        int64_t ticks = av_rescale_q(absolute, AV_TIME_BASE_Q, preview->format->streams[preview->audio.index]->time_base);
        result = av_seek_frame(preview->format, preview->audio.index, ticks, AVSEEK_FLAG_BACKWARD);
    } else {
        const AVStream *video = preview->format->streams[preview->video.index];
        bool transport_stream = strcmp(preview->format->iformat->name, "mpegts") == 0;
        double relative = !transport_stream && mp_preview_has_audio(preview) ? fmax(0, seconds - 0.25) : seconds;
        long double ticks = (long double)relative * video->time_base.den / video->time_base.num;
        // Keep exact rational frame times that passed through Double. A real
        // fractional tick must round down or a backward seek can return a future keyframe.
        long double nearest = roundl(ticks);
        if (fabsl(ticks - nearest) <= fminl(0.000001L, 2 * DBL_EPSILON * fmaxl(1, ticks)))
            ticks = nearest;
        int64_t start = video->start_time != AV_NOPTS_VALUE ? video->start_time :
            av_rescale_q(preview->origin, AV_TIME_BASE_Q, video->time_base);
        // Presented times count from the timeline origin. A caller can place it before
        // the first picture, as multicam does for a movie whose picture starts late.
        // Round down so the backward seek cannot start after the requested picture.
        CMTime origin = preview->timeline_origin;
        if (from_timeline_origin && CMTIME_IS_NUMERIC(origin) && origin.timescale > 0)
            start = av_rescale_q_rnd(origin.value, (AVRational){1, origin.timescale}, video->time_base,
                                     AV_ROUND_DOWN | AV_ROUND_PASS_MINMAX);
        if (ticks >= 0x1p63L || (start > 0 && (int64_t)ticks > INT64_MAX - start))
            return false;
        int64_t desired = start + (int64_t)ticks;
        result = transport_stream ? seek_transport_stream(preview, target, desired) :
            av_seek_frame(preview->format, preview->video.index, desired, AVSEEK_FLAG_BACKWARD);
    }
    if (result < 0)
        return false;
    if (preview->video.codec)
        avcodec_flush_buffers(preview->video.codec);
    if (preview->audio.codec)
        avcodec_flush_buffers(preview->audio.codec);
    swr_free(&preview->resampler);
    preview->video.drained = false;
    preview->audio.drained = false;
    preview->receiving = NULL;
    preview->eof = false;
    preview->awaiting_keyframe = true;
    // A damaged packet silences the rest of that pass only. A missing decoder stays unavailable.
    if (preview->audio.codec)
        preview->audio_unavailable = false;
    preview->audio_failures = 0;
    preview->video_failures = 0;
    preview->met_damage = false;
    preview->late_damage = false;
    preview->recovering = false;
    av_packet_unref(preview->packet);
    av_frame_unref(preview->frame);
    return true;
}

/* Seconds count from the video track's first picture, whatever origin was given to mp_preview_open. */
bool mp_preview_seek(MPPreviewDecoder *preview, double seconds)
{
    return seek_preview(preview, seconds, false);
}

/* Seconds count from the origin that presented sample times are measured from. */
bool mp_preview_seek_timeline(MPPreviewDecoder *preview, double seconds)
{
    return seek_preview(preview, seconds, true);
}

static CMTime sample_time(const MPPreviewDecoder *preview, const PreviewStream *stream)
{
    const int64_t pts = preview->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE)
        return kCMTimeInvalid;
    return CMTimeSubtract(timestamp_time(pts, stream->codec->pkt_timebase), preview->timeline_origin);
}

static bool using_hardware(MPPreviewDecoder *preview)
{
    if (!preview->hardware.session)
        return false;
    // Retain the verified session so a replacement cannot reuse its address.
    if (preview->verified_session == preview->hardware.session)
        return true;
    if (preview->verified_session) {
        CFRelease(preview->verified_session);
        preview->verified_session = NULL;
    }
    CFTypeRef property = NULL;
    OSStatus status = VTSessionCopyProperty(preview->hardware.session,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &property);
    bool hardware = status == noErr && property == kCFBooleanTrue;
    if (property)
        CFRelease(property);
    if (hardware)
        preview->verified_session = (VTDecompressionSessionRef)CFRetain(preview->hardware.session);
    return hardware;
}

static CVPixelBufferRef video_picture(MPPreviewDecoder *preview, CMTime *pts, CMTime *duration)
{
    AVFrame *frame = preview->frame;
    CVPixelBufferRef image = (CVPixelBufferRef)frame->data[3];
    *pts = sample_time(preview, &preview->video);
    if (!image || !CMTIME_IS_NUMERIC(*pts))
        return NULL;
    av_vt_pixbuf_set_attachments(preview->video.codec, image, frame);
    AVRational base = preview->video.codec->pkt_timebase;
    *duration = frame->duration > 0 ? timestamp_time(frame->duration, base) : kCMTimeInvalid;
    return image;
}

static CMSampleBufferRef video_sample(MPPreviewDecoder *preview)
{
    CMTime pts, duration;
    CVPixelBufferRef image = video_picture(preview, &pts, &duration);
    CMSampleBufferRef sample = NULL;
    if (!image)
        return NULL;
    if (!preview->video_description || !CMVideoFormatDescriptionMatchesImageBuffer(preview->video_description, image)) {
        CMVideoFormatDescriptionRef description = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, image, &description) != noErr)
            return NULL;
        if (preview->video_description)
            CFRelease(preview->video_description);
        preview->video_description = description;
    }
    CMSampleTimingInfo timing = {duration, pts, kCMTimeInvalid};
    CMSampleBufferCreateReadyWithImageBuffer(NULL, image, preview->video_description, &timing, &sample);
    return sample;
}

void mp_preview_preserve_surround(MPPreviewDecoder *preview)
{
    if (preview->preserve_surround)
        return;
    preview->preserve_surround = true;
    swr_free(&preview->resampler);
    if (preview->mix)
        linked_mix_preserve_surround(preview->mix);
}

void mp_preview_preserve_audio_channels(MPPreviewDecoder *preview)
{
    preview->preserve_audio_channels = true;
    swr_free(&preview->resampler);
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
    if (preview->audio_description) {
        CFRelease(preview->audio_description);
        preview->audio_description = NULL;
    }
    if (av_channel_layout_copy(&preview->audio_layout, &frame->ch_layout) < 0)
        return false;
    preview->audio_format = frame->format;
    preview->audio_rate = frame->sample_rate;
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    bool surround = preview->preserve_audio_channels || (preview->preserve_surround && frame->ch_layout.nb_channels > 2);
    // Convert packing without rematrixing speakers or imposing a default order.
    AVChannelLayout discrete = { .order = AV_CHANNEL_ORDER_UNSPEC, .nb_channels = frame->ch_layout.nb_channels };
    AVChannelLayout *input = surround ? &discrete : &frame->ch_layout;
    AVChannelLayout *output = surround ? &discrete : &stereo;
    if (swr_alloc_set_opts2(&preview->resampler, output, AV_SAMPLE_FMT_FLT, frame->sample_rate,
                           input, frame->format, frame->sample_rate, 0, NULL) < 0 ||
        // AVAssetReaderAudioMixOutput duplicates a linked mono track into both channels at unity.
        (preview->linked_lane && !surround && frame->ch_layout.nb_channels == 1 &&
         swr_set_matrix(preview->resampler, (double[]){1.0, 1.0}, 1) < 0) ||
        swr_init(preview->resampler) < 0) {
        swr_free(&preview->resampler);
        return false;
    }
    return true;
}

static AudioChannelLabel audio_channel_label(enum AVChannel channel, int index)
{
    switch (channel) {
    // Distinguish rear surrounds from the main surround pair in Core Audio.
    case AV_CHAN_BACK_LEFT: return kAudioChannelLabel_RearSurroundLeft;
    case AV_CHAN_BACK_RIGHT: return kAudioChannelLabel_RearSurroundRight;
    case AV_CHAN_SIDE_LEFT: return kAudioChannelLabel_LeftSurround;
    case AV_CHAN_SIDE_RIGHT: return kAudioChannelLabel_RightSurround;
    case AV_CHAN_STEREO_LEFT: return kAudioChannelLabel_LeftTotal;
    case AV_CHAN_STEREO_RIGHT: return kAudioChannelLabel_RightTotal;
    case AV_CHAN_WIDE_LEFT: return kAudioChannelLabel_LeftWide;
    case AV_CHAN_WIDE_RIGHT: return kAudioChannelLabel_RightWide;
    case AV_CHAN_SURROUND_DIRECT_LEFT: return kAudioChannelLabel_LeftSurroundDirect;
    case AV_CHAN_SURROUND_DIRECT_RIGHT: return kAudioChannelLabel_RightSurroundDirect;
    case AV_CHAN_LOW_FREQUENCY_2: return kAudioChannelLabel_LFE2;
    case AV_CHAN_TOP_SIDE_LEFT: return kAudioChannelLabel_LeftTopMiddle;
    case AV_CHAN_TOP_SIDE_RIGHT: return kAudioChannelLabel_RightTopMiddle;
    case AV_CHAN_BOTTOM_FRONT_CENTER: return kAudioChannelLabel_CenterBottom;
    case AV_CHAN_BOTTOM_FRONT_LEFT: return kAudioChannelLabel_LeftBottom;
    case AV_CHAN_BOTTOM_FRONT_RIGHT: return kAudioChannelLabel_RightBottom;
    case AV_CHAN_SIDE_SURROUND_LEFT: return kAudioChannelLabel_LeftSideSurround;
    case AV_CHAN_SIDE_SURROUND_RIGHT: return kAudioChannelLabel_RightSideSurround;
    case AV_CHAN_TOP_SURROUND_LEFT: return kAudioChannelLabel_LeftTopSurround;
    case AV_CHAN_TOP_SURROUND_RIGHT: return kAudioChannelLabel_RightTopSurround;
    case AV_CHAN_BINAURAL_LEFT: return kAudioChannelLabel_BinauralLeft;
    case AV_CHAN_BINAURAL_RIGHT: return kAudioChannelLabel_BinauralRight;
    default:
        if (channel >= AV_CHAN_FRONT_LEFT && channel <= AV_CHAN_TOP_BACK_RIGHT)
            return (AudioChannelLabel)channel + 1;
        if (channel >= AV_CHAN_AMBISONIC_BASE && channel <= AV_CHAN_AMBISONIC_END)
            return kAudioChannelLabel_HOA_ACN_0 + (channel - AV_CHAN_AMBISONIC_BASE);
        return kAudioChannelLabel_Discrete_0 + index;
    }
}

static CMAudioFormatDescriptionRef make_audio_description(const AudioStreamBasicDescription *format,
                                                          const AVChannelLayout *source,
                                                          bool preserve_channels)
{
    CMAudioFormatDescriptionRef description = NULL;
    AudioChannelLayout *layout = NULL;
    size_t layout_size = 0;
    if (preserve_channels || format->mChannelsPerFrame > 2) {
        layout_size = offsetof(AudioChannelLayout, mChannelDescriptions) +
            format->mChannelsPerFrame * sizeof(AudioChannelDescription);
        layout = calloc(1, layout_size);
        if (!layout)
            return NULL;
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = format->mChannelsPerFrame;
        for (int i = 0; i < source->nb_channels; i++) {
            enum AVChannel channel = av_channel_layout_channel_from_index(source, (unsigned)i);
            AudioChannelLabel label = audio_channel_label(channel, i);
            for (int j = 0; j < i; j++) {
                if (layout->mChannelDescriptions[j].mChannelLabel == label) {
                    label = kAudioChannelLabel_Discrete_0 + i;
                    break;
                }
            }
            layout->mChannelDescriptions[i].mChannelLabel = label;
        }
    }
    OSStatus status = CMAudioFormatDescriptionCreate(NULL, format, layout_size, layout, 0, NULL, NULL, &description);
    free(layout);
    return status == noErr ? description : NULL;
}

static CMSampleBufferRef audio_sample(MPPreviewDecoder *preview)
{
    AVFrame *frame = preview->frame;
    CMTime pts = sample_time(preview, &preview->audio);
    if (!CMTIME_IS_NUMERIC(pts) || frame->nb_samples <= 0 || frame->nb_samples > 65536 ||
        frame->sample_rate <= 0 || frame->ch_layout.nb_channels <= 0 || !configure_resampler(preview))
        return NULL;

    const int channels = preview->preserve_audio_channels || (preview->preserve_surround && frame->ch_layout.nb_channels > 2)
        ? frame->ch_layout.nb_channels : 2;
    if ((unsigned)channels > UINT32_MAX / sizeof(float))
        return NULL;
    const UInt32 stride = (UInt32)channels * (UInt32)sizeof(float);
    if (!preview->audio_description) {
        AudioStreamBasicDescription format = {
            .mSampleRate = frame->sample_rate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
            .mBytesPerPacket = stride,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = stride,
            .mChannelsPerFrame = channels,
            .mBitsPerChannel = 8 * sizeof(float),
        };
        preview->audio_description = make_audio_description(&format, &frame->ch_layout, preview->preserve_audio_channels);
        if (!preview->audio_description)
            return NULL;
    }
    size_t bytes = (size_t)frame->nb_samples * stride;
    CMBlockBufferRef data = NULL;
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
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, preview->audio_description, samples,
                                                        pts, NULL, &sample);
finish:
    CFRelease(data);
    return sample;
}

/* Replacing a coded picture would discard these payloads. They can occur
 * inside individual access units even when the container has no track flag. */
static bool edge_metadata_supported(const AVFrame *frame)
{
    for (int i = 0; i < frame->nb_side_data; i++) {
        switch (frame->side_data[i]->type) {
        case AV_FRAME_DATA_A53_CC:
        case AV_FRAME_DATA_MASTERING_DISPLAY_METADATA:
        case AV_FRAME_DATA_CONTENT_LIGHT_LEVEL:
        case AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT:
        case AV_FRAME_DATA_DYNAMIC_HDR_PLUS:
        case AV_FRAME_DATA_DYNAMIC_HDR_VIVID:
        case AV_FRAME_DATA_DOVI_RPU_BUFFER:
        case AV_FRAME_DATA_DOVI_METADATA:
        case AV_FRAME_DATA_ICC_PROFILE:
        case AV_FRAME_DATA_FILM_GRAIN_PARAMS:
            return false;
        default:
            break;
        }
    }
    return true;
}

// The decoder drops a packet it rejects, so one damaged packet is a brief
// dropout. About two seconds of consecutive failures is an undecodable stream.
static bool damaged_audio_packet(MPPreviewDecoder *preview, int result)
{
    return result == AVERROR_INVALIDDATA && ++preview->audio_failures <= 100;
}

static const char *const damaged_edge_picture =
    "A source picture needed to re-encode this cut is damaged and could not be decoded. "
    "Move the cut to a keyframe or away from the damage.";

bool mp_preview_met_damage(const MPPreviewDecoder *preview)
{
    return preview->met_damage;
}

bool mp_preview_edge_intact_before_damage(const MPPreviewDecoder *preview)
{
    return preview->met_damage && !preview->late_damage;
}

// libavcodec reports a packet it cannot parse as invalid data. VideoToolbox reports a picture
// it cannot decode as an unknown or external error. Later pictures can be predicted from the
// rejected one, so no further packet is sent. The decoder is drained of the pictures that
// came from earlier packets. A preview then resumes at the next keyframe. A Smart Trim edge
// must not lose a picture, so it ends with an error. A session that keeps failing is a
// decoder fault rather than damage.
static bool is_picture_damage(int result)
{
    return result == AVERROR_INVALIDDATA || result == AVERROR_UNKNOWN || result == AVERROR_EXTERNAL;
}

static void resume_at_keyframe(MPPreviewDecoder *preview)
{
    avcodec_flush_buffers(preview->video.codec);
    preview->recovering = false;
    preview->awaiting_keyframe = true;
}

static bool damaged_video_picture(MPPreviewDecoder *preview, int result, bool sending)
{
    if (preview->encoding_edge || !is_picture_damage(result) || ++preview->video_failures > 32)
        return false;
    preview->met_damage = true;
    if (preview->recovering) {
        // The rejected picture can surface while the earlier pictures drain.
        preview->receiving = &preview->video;
    } else if (sending && avcodec_send_packet(preview->video.codec, NULL) >= 0) {
        preview->recovering = true;
        preview->receiving = &preview->video;
    } else {
        // A failure first reported with a picture can follow packets that were already sent.
        resume_at_keyframe(preview);
    }
    return true;
}

static int next_stream_sample(MPPreviewDecoder *preview, CMSampleBufferRef *sample,
                              CVPixelBufferRef *image, CMTime *pts, CMTime *duration, const char **error)
{
    if (sample)
        *sample = NULL;
    if (image) {
        *image = NULL;
        *pts = kCMTimeInvalid;
        *duration = kCMTimeInvalid;
    }
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
                    bool corrupt = preview->frame->decode_error_flags ||
                        (preview->frame->flags & AV_FRAME_FLAG_CORRUPT);
                    if (preview->encoding_edge && (corrupt || (preview->frame->flags & AV_FRAME_FLAG_INTERLACED))) {
                        av_frame_unref(preview->frame);
                        *error = "Smart Trim requires intact, progressive source pictures.";
                        return MPPreviewError;
                    }
                    if (corrupt) {
                        av_frame_unref(preview->frame);
                        preview->receiving = NULL;
                        if (damaged_video_picture(preview, AVERROR_INVALIDDATA, false))
                            continue;
                        *error = "VideoToolbox repeatedly returned damaged pictures.";
                        return MPPreviewError;
                    }
                    if (preview->encoding_edge && !edge_metadata_supported(preview->frame)) {
                        av_frame_unref(preview->frame);
                        *error = "This picture carries embedded captions, colour, or grain metadata that requires copying.";
                        return MPPreviewError;
                    }
                    if (preview->frame->format != AV_PIX_FMT_VIDEOTOOLBOX || !using_hardware(preview)) {
                        av_frame_unref(preview->frame);
                        *error = "VideoToolbox could not decode this stream in hardware.";
                        return MPPreviewError;
                    }
                    preview->video_failures = 0;
                    if (image) {
                        CVPixelBufferRef picture = video_picture(preview, pts, duration);
                        if (picture)
                            *image = CVPixelBufferRetain(picture);
                    } else {
                        *sample = video_sample(preview);
                    }
                } else if (sample) {
                    preview->audio_failures = 0;
                    *sample = audio_sample(preview);
                }
                av_frame_unref(preview->frame);
                if ((sample && *sample) || (image && *image))
                    return kind;
                if (kind == MPPreviewVideo) {
                    *error = "A decoded video frame could not be presented.";
                    return MPPreviewError;
                }
                preview->audio_unavailable = true;
                preview->receiving = NULL;
                continue;
            }
            preview->receiving = NULL;
            if (result == AVERROR_EOF && stream == &preview->video && preview->recovering)
                resume_at_keyframe(preview);
            else if (result == AVERROR_EOF)
                stream->drained = true;
            else if (result != AVERROR(EAGAIN)) {
                if (stream == &preview->video) {
                    if (damaged_video_picture(preview, result, false))
                        continue;
                    // While an edge drains after a rejected packet, the rejected picture can
                    // surface here ahead of intact pictures that were decoded before it.
                    if (preview->encoding_edge && preview->eof && preview->met_damage && !preview->late_damage &&
                        is_picture_damage(result) && ++preview->video_failures <= 32) {
                        preview->receiving = stream;
                        continue;
                    }
                    // A failure reported first here can follow packets that were already sent,
                    // so an edge has no later picture that is known to be intact.
                    if (is_picture_damage(result)) {
                        preview->late_damage = preview->late_damage || !preview->met_damage;
                        preview->met_damage = true;
                    }
                    *error = preview->encoding_edge && preview->met_damage
                        ? damaged_edge_picture : "VideoToolbox could not decode this stream.";
                    return MPPreviewError;
                }
                if (damaged_audio_packet(preview, result)) {
                    preview->receiving = stream;
                    continue;
                }
                preview->audio_unavailable = true;
            }
        }
        if (preview->eof) {
            PreviewStream *stream = &preview->video;
            if (preview->encoding_edge && preview->met_damage && stream->drained) {
                *error = damaged_edge_picture;
                return MPPreviewError;
            }
            if (preview->audio_only || stream->drained)
                stream = &preview->audio;
            if (stream->drained || !stream->codec || (stream == &preview->audio && !mp_preview_has_audio(preview)))
                return MPPreviewEnd;
            int result = avcodec_send_packet(stream->codec, NULL);
            if (result == AVERROR_EOF) {
                stream->drained = true;
            } else if (result == 0 || result == AVERROR(EAGAIN)) {
                preview->receiving = stream;
            } else if (stream == &preview->video) {
                if (is_picture_damage(result)) {
                    preview->met_damage = true;
                    stream->drained = true;
                    continue;
                }
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
        if (result == AVERROR(EAGAIN) || (result == AVERROR_EXIT && preview_cancelled(preview)))
            return MPPreviewAgain;
        if (result < 0) {
            *error = "FFmpeg could not read the next preview packet.";
            return MPPreviewError;
        }
        PreviewStream *stream = NULL;
        if (!preview->audio_only && preview->packet->stream_index == preview->video.index) {
            if (!preview->awaiting_keyframe || (preview->packet->flags & AV_PKT_FLAG_KEY)) {
                preview->awaiting_keyframe = false;
                stream = &preview->video;
            }
        } else if (preview->packet->stream_index == preview->audio.index && mp_preview_has_audio(preview))
            stream = &preview->audio;
        if (stream && stream->codec)
            result = avcodec_send_packet(stream->codec, preview->packet);
        av_packet_unref(preview->packet);
        if (!stream || !stream->codec)
            continue;
        if (result < 0) {
            if (stream == &preview->video) {
                if (damaged_video_picture(preview, result, true))
                    continue;
                if (preview->encoding_edge && is_picture_damage(result)) {
                    // Nothing after the rejected packet is sent. The pictures still held by
                    // the decoder came from earlier packets and are returned before the error.
                    preview->met_damage = true;
                    preview->eof = true;
                    continue;
                }
                *error = "VideoToolbox could not decode this stream.";
                return MPPreviewError;
            }
            if (!damaged_audio_packet(preview, result))
                preview->audio_unavailable = true;
        } else {
            preview->receiving = stream;
        }
    }
    return MPPreviewAgain;
}

int mp_preview_next(MPPreviewDecoder *preview, CMSampleBufferRef *sample, const char **error)
{
    if (!preview->mix || !preview->audio_enabled)
        return next_stream_sample(preview, sample, NULL, NULL, NULL, error);
    *sample = NULL;
    *error = NULL;
    if (!preview->mixed_audio && !preview->mix_audio_end) {
        int result = linked_mix_next(preview->mix, &preview->mixed_audio);
        if (result == MPPreviewError)
            *error = "Could not create the linked preview audio mix.";
        if (result == MPPreviewAgain || result == MPPreviewError)
            return result;
        preview->mix_audio_end = result == MPPreviewEnd;
    }
    if (!preview->audio_only && !preview->mixed_picture && !preview->mix_video_end) {
        int result = next_stream_sample(preview, &preview->mixed_picture, NULL, NULL, NULL, error);
        if (result == MPPreviewAgain || result == MPPreviewError)
            return result;
        preview->mix_video_end = result == MPPreviewEnd;
    }
    if (preview->mixed_audio && (!preview->mixed_picture ||
        CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(preview->mixed_audio),
                      CMSampleBufferGetPresentationTimeStamp(preview->mixed_picture)) <= 0)) {
        *sample = preview->mixed_audio;
        preview->mixed_audio = NULL;
        return MPPreviewAudio;
    }
    if (preview->mixed_picture) {
        *sample = preview->mixed_picture;
        preview->mixed_picture = NULL;
        return MPPreviewVideo;
    }
    return MPPreviewEnd;
}

int mp_preview_next_picture(MPPreviewDecoder *preview, CVPixelBufferRef *image, CMTime *pts,
                            CMTime *duration, const char **error)
{
    if (!preview || mp_preview_has_audio(preview) || preview->encoding_edge) {
        *image = NULL;
        *pts = kCMTimeInvalid;
        *duration = kCMTimeInvalid;
        *error = "Direct picture decoding requires picture-only preview.";
        return MPPreviewError;
    }
    return next_stream_sample(preview, NULL, image, pts, duration, error);
}
