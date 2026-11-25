#include "FFPreviewDecoder.h"
#include "LinkedAudioMix.h"

#include <AudioToolbox/AudioToolbox.h>
#include <libavcodec/videotoolbox.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/display.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <limits.h>
#include <libavutil/pixdesc.h>
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
    uint8_t *edge_sets;    /* Parameter sets the source holds at the edge's keyframe (mp_preview_prime_edge). */
    int edge_sets_size;
    int edge_length_size;
    bool prime_pending;    /* The next video packet sent is the edge's keyframe, which brings edge_sets first. */
    /* A MOV track can change its sample description at a keyframe. The demuxer reports the new one
     * (AV_PKT_DATA_NEW_EXTRADATA) on the first packet it reads under it, relative to the packet it read
     * before, whether or not that packet reached the decoder. */
    uint8_t *description;          /* The description of the video packets read last. */
    int description_size;
    uint8_t *decoder_description;  /* The description the video decoder was opened with. */
    int decoder_description_size;
    AVPacket *held;                /* A keyframe under a new description, held while the decoder drains. */
    bool switching;                /* The video decoder is draining before it reopens with `description`. */
    bool video_fed;                /* A packet reached the video decoder since it was opened or flushed. */
    bool unaligned_switch;         /* The description changed at a picture that is not a keyframe. */
    /* The decoder was reopened mid-stream at an HEVC CRA picture. libavcodec then starts a coded sequence there and
     * drops the CRA's RASL pictures, which predict from pictures the old decoder held. */
    bool watch_leading;
    int leading_count;             /* RASL pictures dropped that way since the last seek. */
    int64_t leading_key, leading_first, leading_last;
    char leading_notice[320];
    bool audio_damage;             /* The audio decoder rejected a packet, which is silent. */
    bool edge_metadata;
    bool sequence_metadata;
    /* Edge: presentation times of the samples sent from the first one since the keyframe with SEI an encode drops
     * (mp_preview_sample_keeps_sei) on. A frame's own packet is known by its presentation time. */
    int64_t *kept_sei_pts;
    int kept_sei_count, kept_sei_capacity;
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
            // FFmpeg's session description carries no color, so an RGB surface from it is
            // converted with the matrix VideoToolbox guesses from the picture size. 8-bit 4:2:0
            // stays YCbCr, and Core Animation applies the stream's own matrix, as in the
            // native preview. Deeper pictures keep VideoToolbox's choice; a Smart Trim edge
            // requests its own format.
            if (!preview->encoding_edge) {
                const AVPixFmtDescriptor *software = av_pix_fmt_desc_get(codec->sw_pix_fmt);
                const bool plain = software && software->comp[0].depth == 8 && software->log2_chroma_w == 1 &&
                    software->log2_chroma_h == 1 && !(software->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_ALPHA));
                preview->hardware.cv_pix_fmt_type = !plain ? 0 : codec->color_range == AVCOL_RANGE_JPEG
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            }
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

static bool same_bytes(const uint8_t *a, int a_size, const uint8_t *b, int b_size)
{
    return a_size == b_size && (a_size <= 0 || !memcmp(a, b, (size_t)a_size));
}

enum { MAX_DESCRIPTION_UNITS = 64 };

typedef struct {
    int length_size, count;
    const uint8_t *data[MAX_DESCRIPTION_UNITS];
    int size[MAX_DESCRIPTION_UNITS];
} DescriptionUnits;

/* The parameter sets of an avcC or hvcC record, which hold no other NAL units. False for another form. */
static bool description_units(enum AVCodecID codec, const uint8_t *p, int size, DescriptionUnits *units)
{
    const uint8_t *end = p + size;
    units->count = 0;
    if (size < (codec == AV_CODEC_ID_HEVC ? 23 : 7) || p[0] != 1)
        return false;
    int groups = codec == AV_CODEC_ID_HEVC ? p[22] : 2;
    units->length_size = (p[codec == AV_CODEC_ID_HEVC ? 21 : 4] & 3) + 1;
    p += codec == AV_CODEC_ID_HEVC ? 23 : 5;
    for (int group = 0; group < groups; group++) {
        int count;
        if (codec == AV_CODEC_ID_HEVC) {
            if (end - p < 3)
                return false;
            count = AV_RB16(p + 1);
            p += 3;
        } else {
            if (end - p < 1)
                return false;
            count = group ? p[0] : p[0] & 0x1f;
            p++;
        }
        for (int i = 0; i < count; i++) {
            if (end - p < 2 || end - p - 2 < AV_RB16(p) || units->count == MAX_DESCRIPTION_UNITS)
                return false;
            units->data[units->count] = p + 2;
            units->size[units->count++] = AV_RB16(p);
            p += 2 + AV_RB16(p);
        }
    }
    return true;
}

static bool holds_units(const DescriptionUnits *a, const DescriptionUnits *b)
{
    for (int i = 0; i < a->count; i++) {
        bool found = false;
        for (int j = 0; j < b->count && !found; j++)
            found = a->size[i] == b->size[j] && !memcmp(a->data[i], b->data[j], (size_t)a->size[i]);
        if (!found)
            return false;
    }
    return true;
}

/* Whether a decoder opened with one description decodes the samples of the other alike: the same bytes, or for
 * H.264 and HEVC the same parameter sets and NAL unit length, however they are listed. */
static bool same_description(const MPPreviewDecoder *preview, const uint8_t *a, int a_size, const uint8_t *b, int b_size)
{
    if (same_bytes(a, a_size, b, b_size))
        return true;
    enum AVCodecID codec = preview->format->streams[preview->video.index]->codecpar->codec_id;
    DescriptionUnits first, second;
    return (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC) &&
        description_units(codec, a, a_size, &first) && description_units(codec, b, b_size, &second) &&
        first.length_size == second.length_size && holds_units(&first, &second) && holds_units(&second, &first);
}

static bool copy_bytes(uint8_t **destination, int *destination_size, const uint8_t *source, int size)
{
    uint8_t *copy = NULL;
    if (size > 0 && !(copy = av_memdup(source, (size_t)size)))
        return false;
    av_free(*destination);
    *destination = copy;
    *destination_size = size > 0 ? size : 0;
    return true;
}

/* Opens a video decoder for the stream with `extradata` in place of the description it was probed with. */
static AVCodecContext *open_video_codec(MPPreviewDecoder *preview, const uint8_t *extradata, int size)
{
    const AVStream *source = preview->format->streams[preview->video.index];
    const AVCodec *decoder = find_video_decoder(source->codecpar->codec_id);
    AVCodecContext *codec = decoder ? avcodec_alloc_context3(decoder) : NULL;
    if (!codec)
        return NULL;
    if (avcodec_parameters_to_context(codec, source->codecpar) < 0)
        goto failure;
    av_freep(&codec->extradata);
    codec->extradata_size = 0;
    if (size > 0) {
        if (!(codec->extradata = av_mallocz((size_t)size + AV_INPUT_BUFFER_PADDING_SIZE)))
            goto failure;
        memcpy(codec->extradata, extradata, (size_t)size);
        codec->extradata_size = size;
    }
    codec->pkt_timebase = source->time_base;
    codec->thread_count = 1;
    codec->opaque = preview;
    codec->get_format = hardware_format;
    if (preview->encoding_edge)
        codec->err_recognition |= AV_EF_EXPLODE;
    if (avcodec_open2(codec, decoder, NULL) < 0)
        goto failure;
    return codec;

failure:
    avcodec_free_context(&codec);
    return NULL;
}

static bool open_stream(MPPreviewDecoder *preview, PreviewStream *stream, int index, enum AVMediaType type)
{
    const AVCodec *decoder = NULL;
    stream->index = index;
    if (stream->index < 0)
        return false;
    AVStream *source = preview->format->streams[stream->index];
    if (type == AVMEDIA_TYPE_VIDEO) {
        const AVCodecParameters *parameters = source->codecpar;
        if (!copy_bytes(&preview->description, &preview->description_size, parameters->extradata, parameters->extradata_size) ||
            !copy_bytes(&preview->decoder_description, &preview->decoder_description_size,
                        parameters->extradata, parameters->extradata_size))
            return false;
        stream->codec = open_video_codec(preview, parameters->extradata, parameters->extradata_size);
        return stream->codec != NULL;
    }
    decoder = avcodec_find_decoder(source->codecpar->codec_id);
    if (!decoder)
        return false;
    AVCodecContext *codec = avcodec_alloc_context3(decoder);
    if (!codec)
        return false;
    if (avcodec_parameters_to_context(codec, source->codecpar) < 0)
        goto failure;
    codec->pkt_timebase = source->time_base;
    codec->thread_count = 1;
    if (avcodec_open2(codec, decoder, NULL) < 0)
        goto failure;
    stream->codec = codec;
    return true;

failure:
    avcodec_free_context(&codec);
    return false;
}

/* Reopen the drained or flushed video decoder with the description of the packets read last. FFmpeg's
 * VideoToolbox decoder keeps the session it made from the parameter sets it held then, and an H.264
 * description or an HEVC one that keeps its sequence parameter set does not replace it, so the new
 * pictures would be decoded with the old picture or sequence parameter sets. */
static bool reopen_video(MPPreviewDecoder *preview)
{
    AVCodecContext *codec = open_video_codec(preview, preview->description, preview->description_size);
    if (!codec || !copy_bytes(&preview->decoder_description, &preview->decoder_description_size,
                              preview->description, preview->description_size)) {
        avcodec_free_context(&codec);
        return false;
    }
    avcodec_free_context(&preview->video.codec);
    if (preview->verified_session) {
        CFRelease(preview->verified_session);
        preview->verified_session = NULL;
    }
    clear_hardware(&preview->hardware);
    preview->video.codec = codec;
    preview->video.drained = false;
    preview->video_fed = false;
    preview->switching = false;
    return true;
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
    preview->held = av_packet_alloc();
    preview->frame = av_frame_alloc();
    preview->format = avformat_alloc_context();
    if (!preview->packet || !preview->held || !preview->frame || !preview->format)
        goto failure;
    preview->cancelled = cancelled;
    preview->cancel_context = context;
    preview->format->interrupt_callback = (AVIOInterruptCB){preview_cancelled, preview};
    if (preview_cancelled(preview)) {
        *error = "Preview opening was cancelled.";
        goto failure;
    }
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
    if (preview_cancelled(preview)) {
        *error = "Preview opening was cancelled.";
        goto failure;
    }
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

bool mp_preview_prime_edge(MPPreviewDecoder *preview, const uint8_t *units, int size)
{
    if (!preview || !preview->encoding_edge || !units || size <= 0)
        return false;
    const AVCodecParameters *codec = preview->format->streams[preview->video.index]->codecpar;
    int offset = codec->codec_id == AV_CODEC_ID_HEVC ? 21 : codec->codec_id == AV_CODEC_ID_H264 ? 4 : -1;
    if (offset < 0 || codec->extradata_size <= offset || codec->extradata[0] != 1)
        return false;
    uint8_t *copy = av_memdup(units, (size_t)size);
    if (!copy)
        return false;
    av_free(preview->edge_sets);
    preview->edge_sets = copy;
    preview->edge_sets_size = size;
    preview->edge_length_size = (codec->extradata[offset] & 3) + 1;
    return true;
}

/* Put NAL units with 4-byte lengths into a sample whose NAL units have `width`-byte lengths, after any access
 * unit delimiter. */
static int insert_units(const MPPreviewDecoder *preview, AVPacket *packet, const uint8_t *units, int size, int width)
{
    const bool hevc = preview->format->streams[preview->video.index]->codecpar->codec_id == AV_CODEC_ID_HEVC;
    int total = 0;
    for (int at = 0; at <= size - 4; at += 4 + (int)AV_RB32(units + at)) {
        uint32_t length = AV_RB32(units + at);
        if ((width < 4 && length >> (8 * width)) || length > (uint32_t)(INT_MAX / 4))
            return AVERROR(ERANGE);
        total += width + (int)length;
    }
    int offset = 0;
    if (packet->size > width) {
        uint32_t length = 0;
        for (int i = 0; i < width; i++)
            length = length << 8 | packet->data[i];
        unsigned type = hevc ? (packet->data[width] >> 1) & 0x3f : packet->data[width] & 0x1f;
        if ((hevc ? type == 35 : type == 9) && length <= (uint32_t)(packet->size - width))
            offset = width + (int)length;
    }
    int old_size = packet->size;
    int result = total > INT_MAX / 2 - old_size ? AVERROR(ERANGE) : av_packet_make_writable(packet);
    if (result >= 0)
        result = av_grow_packet(packet, total);
    if (result < 0)
        return result;
    memmove(packet->data + offset + total, packet->data + offset, (size_t)(old_size - offset));
    uint8_t *q = packet->data + offset;
    for (int at = 0; at <= size - 4; at += 4 + (int)AV_RB32(units + at)) {
        uint32_t length = AV_RB32(units + at);
        for (int i = 0; i < width; i++)
            q[i] = (uint8_t)(length >> (8 * (width - 1 - i)));
        memcpy(q + width, units + at + 4, length);
        q += width + length;
    }
    return 0;
}

/* Put edge_sets into the keyframe packet an edge starts from. Its NAL units have the lengths of the description the
 * decoder holds, which the edge's keyframe may have just brought. */
static int prime_packet(MPPreviewDecoder *preview, AVPacket *packet)
{
    const bool hevc = preview->format->streams[preview->video.index]->codecpar->codec_id == AV_CODEC_ID_HEVC;
    const int at = hevc ? 21 : 4;
    const int width = preview->decoder_description_size > at && preview->decoder_description[0] == 1
        ? (preview->decoder_description[at] & 3) + 1 : preview->edge_length_size;
    return insert_units(preview, packet, preview->edge_sets, preview->edge_sets_size, width);
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
    av_free(preview->edge_sets);
    av_free(preview->kept_sei_pts);
    av_free(preview->description);
    av_free(preview->decoder_description);
    av_frame_free(&preview->frame);
    av_packet_free(&preview->packet);
    av_packet_free(&preview->held);
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

static bool note_description(MPPreviewDecoder *preview, const AVPacket *packet);

/* Empty the video decoder. FFmpeg's HEVC decoder keeps the pictures it has queued for output through a flush (its
 * output FIFO), so a picture from before a seek would be returned after it. Receive and drop them. */
static void flush_video(MPPreviewDecoder *preview)
{
    avcodec_flush_buffers(preview->video.codec);
    for (int i = 0; i < 64 && avcodec_receive_frame(preview->video.codec, preview->frame) == 0; i++)
        av_frame_unref(preview->frame);
}

/* Seek so that decoding starts at a keyframe presented at or before `desired`. MOV and MP4 index decode times, so
 * a backward seek can land on an HEVC CRA picture presented after the target, whose RASL pictures, the target
 * among them, a decoder starting there drops without a word. Step back until the first picture is not late. */
static int seek_keyframe(MPPreviewDecoder *preview, int64_t desired)
{
    int64_t timestamp = desired, landed = AV_NOPTS_VALUE;
    for (int attempt = 0; attempt < 8; attempt++) {
        int result = av_seek_frame(preview->format, preview->video.index, timestamp, AVSEEK_FLAG_BACKWARD);
        if (result < 0)
            return attempt ? av_seek_frame(preview->format, preview->video.index, desired, AVSEEK_FLAG_BACKWARD) : result;
        int64_t pts = AV_NOPTS_VALUE, dts = AV_NOPTS_VALUE;
        for (int read = 0; read < 256 && !preview_cancelled(preview) &&
             av_read_frame(preview->format, preview->packet) >= 0; read++) {
            bool video = preview->packet->stream_index == preview->video.index;
            bool key = preview->packet->flags & AV_PKT_FLAG_KEY;
            // The demuxer reports a new description relative to the packet it read last, this one included.
            bool noted = !video || note_description(preview, preview->packet);
            pts = preview->packet->pts;
            dts = preview->packet->dts;
            av_packet_unref(preview->packet);
            if (!noted)
                return AVERROR(ENOMEM);
            if (video) {
                if (!key)
                    pts = AV_NOPTS_VALUE;
                break;
            }
            pts = AV_NOPTS_VALUE;
        }
        if (pts == AV_NOPTS_VALUE || pts <= desired)
            return av_seek_frame(preview->format, preview->video.index, timestamp, AVSEEK_FLAG_BACKWARD);
        // Nothing earlier to start from (the stream's first keyframe): seek as before.
        if (pts == landed || dts == AV_NOPTS_VALUE || dts <= INT64_MIN + 1)
            break;
        landed = pts;
        timestamp = FFMIN(timestamp, dts) - 1;
    }
    return av_seek_frame(preview->format, preview->video.index, desired, AVSEEK_FLAG_BACKWARD);
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
        result = transport_stream ? seek_transport_stream(preview, target, desired) : seek_keyframe(preview, desired);
    }
    if (result < 0)
        return false;
    if (preview->video.codec)
        flush_video(preview);
    if (preview->audio.codec)
        avcodec_flush_buffers(preview->audio.codec);
    swr_free(&preview->resampler);
    preview->video.drained = false;
    preview->audio.drained = false;
    preview->receiving = NULL;
    preview->eof = false;
    preview->awaiting_keyframe = true;
    preview->prime_pending = preview->edge_sets != NULL;
    // The next keyframe reopens the flushed decoder if its description is not the one it holds.
    av_packet_unref(preview->held);
    preview->switching = false;
    preview->video_fed = false;
    preview->unaligned_switch = false;
    preview->watch_leading = false;
    preview->leading_count = 0;
    preview->audio_damage = false;
    preview->kept_sei_count = 0;
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

// The native preview shows a field a picture leaves unspecified the way VideoToolbox tags it
// from an MP4 or MOV description (measured on macOS 27; frame export in jpeg_frames.c keeps the
// same rule, and also names for Core Image the transfer Core Animation gives primaries recorded
// without one). With no color recorded at all it goes by size: larger than 704x576 is BT.709,
// smaller is BT.601 with SMPTE C primaries, or EBU Tech 3213 at exactly 704x576, with the BT.709
// transfer. When every recorded field is BT.709 or BT.601 (SMPTE 170M), a missing matrix is
// BT.709 for BT.709 primaries and otherwise BT.601, missing primaries follow the matrix and a
// missing transfer is BT.709. Other recorded values leave the missing primaries and transfer
// unspecified, and a missing matrix is BT.601, as Core Animation decodes it, also for BT.2020
// primaries. A PQ or HLG picture with recorded primaries takes BT.2020 for BT.2020 primaries and
// otherwise BT.709, as Core Animation decodes it and Core Image maps its SDR preview.
static void tag_unspecified_color(CVPixelBufferRef image, const AVFrame *frame)
{
    enum AVColorSpace matrix = frame->colorspace;
    enum AVColorPrimaries primaries = frame->color_primaries;
    bool fills = true;
    if (matrix == AVCOL_SPC_UNSPECIFIED && primaries == AVCOL_PRI_UNSPECIFIED && frame->color_trc == AVCOL_TRC_UNSPECIFIED) {
        const bool hd = frame->width > 704 || frame->height > 576;
        matrix = hd ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
        primaries = hd ? AVCOL_PRI_BT709 : frame->width == 704 && frame->height == 576 ? AVCOL_PRI_BT470BG : AVCOL_PRI_SMPTE170M;
    } else {
        fills = (matrix == AVCOL_SPC_UNSPECIFIED || matrix == AVCOL_SPC_BT709 || matrix == AVCOL_SPC_SMPTE170M) &&
            (primaries == AVCOL_PRI_UNSPECIFIED || primaries == AVCOL_PRI_BT709 || primaries == AVCOL_PRI_SMPTE170M) &&
            (frame->color_trc == AVCOL_TRC_UNSPECIFIED || frame->color_trc == AVCOL_TRC_BT709 ||
             frame->color_trc == AVCOL_TRC_SMPTE170M);
        const bool hdr = (frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67) &&
            primaries != AVCOL_PRI_UNSPECIFIED;
        if (matrix == AVCOL_SPC_UNSPECIFIED)
            matrix = hdr && primaries == AVCOL_PRI_BT2020 ? AVCOL_SPC_BT2020_NCL :
                hdr || (fills && primaries == AVCOL_PRI_BT709) ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
        if (fills && primaries == AVCOL_PRI_UNSPECIFIED)
            primaries = matrix == AVCOL_SPC_BT709 ? AVCOL_PRI_BT709 : AVCOL_PRI_SMPTE170M;
    }
    bool tagged = false;
    if (frame->colorspace == AVCOL_SPC_UNSPECIFIED) {
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
                              matrix == AVCOL_SPC_BT709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 :
                              matrix == AVCOL_SPC_BT2020_NCL ? kCVImageBufferYCbCrMatrix_ITU_R_2020 :
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
        tagged = true;
    }
    if (fills && frame->color_primaries == AVCOL_PRI_UNSPECIFIED) {
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey,
                              primaries == AVCOL_PRI_BT709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 :
                              primaries == AVCOL_PRI_BT470BG ? kCVImageBufferColorPrimaries_EBU_3213 :
                              kCVImageBufferColorPrimaries_SMPTE_C, kCVAttachmentMode_ShouldPropagate);
        tagged = true;
    }
    if (fills && frame->color_trc == AVCOL_TRC_UNSPECIFIED) {
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        tagged = true;
    }
    if (!tagged)
        return;
    // Core Animation reads an RGB surface's color from its color space, not the keys alone.
    CFDictionaryRef attachments = CVBufferCopyAttachments(image, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRef space = attachments ? CVImageBufferCreateColorSpaceFromAttachments(attachments) : NULL;
    if (space) {
        CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
        CGColorSpaceRelease(space);
    }
    if (attachments)
        CFRelease(attachments);
}

static CVPixelBufferRef video_picture(MPPreviewDecoder *preview, CMTime *pts, CMTime *duration)
{
    AVFrame *frame = preview->frame;
    CVPixelBufferRef image = (CVPixelBufferRef)frame->data[3];
    *pts = sample_time(preview, &preview->video);
    if (!image || !CMTIME_IS_NUMERIC(*pts))
        return NULL;
    av_vt_pixbuf_set_attachments(preview->video.codec, image, frame);
    // A Smart Trim edge keeps the source's own (absent) color description.
    if (!preview->encoding_edge)
        tag_unspecified_color(image, frame);
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
 * inside individual access units even when the container has no track flag.
 * Film grain parameters are not among them: without AV_CODEC_EXPORT_DATA_FILM_GRAIN
 * libavcodec never attaches them, and an edge that loses grain synthesis is
 * written with a plan warning (note_grain in smart_preflight.c). */
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
        // An H.264 picture timing or HEVC time code SEI. The encoder writes no time code.
        case AV_FRAME_DATA_S12M_TIMECODE:
            return false;
        default:
            break;
        }
    }
    return true;
}

/* SEI payloads mp_preview_sample_keeps_sei names, in one unescaped SEI message list. Stereo and display matrices also
 * come from the container, which the copy keeps, so the frame's side data cannot tell them apart. */
static bool sei_kept(bool hevc, const uint8_t *rbsp, size_t size)
{
    size_t pos = 0;
    while (pos + 2 <= size && !(size - pos == 1 && rbsp[pos] == 0x80)) {
        unsigned type = 0, length = 0;
        while (pos < size && rbsp[pos] == 0xFF)
            type += rbsp[pos++];
        if (pos >= size)
            break;
        type += rbsp[pos++];
        while (pos < size && rbsp[pos] == 0xFF)
            length += rbsp[pos++];
        if (pos >= size)
            break;
        length += rbsp[pos++];
        if (length > size - pos)
            break;
        const uint8_t *payload = rbsp + pos;
        pos += length;
        if (type == 45 && length > 0) {
            // frame_packing_arrangement_id is ue(v), then frame_packing_arrangement_cancel_flag.
            unsigned zeros = 0, bit = 0;
            while (bit < 8 * length && !(payload[bit >> 3] >> (7 - (bit & 7)) & 1))
                zeros++, bit++;
            bit += zeros + 1;
            if (bit < 8 * length && !(payload[bit >> 3] >> (7 - (bit & 7)) & 1))
                return true;
        } else if (type == 47 && length > 0) {
            if (!(payload[0] & 0x80)) // display_orientation_cancel_flag
                return true;
        } else if ((hevc && type == 136) || type == 147) {
            return true; // Time code; alternative transfer characteristics.
        } else if (type == 4 && length >= 8 && payload[0] == 0xB5 && AV_RB16(payload + 1) == 0x0031) {
            uint32_t user = AV_RB32(payload + 3);
            if (user == MKBETAG('D', 'T', 'G', '1') || (user == MKBETAG('G', 'A', '9', '4') && payload[7] == 0x06))
                return true; // Active format description; ATSC bar data.
        }
    }
    return false;
}

bool mp_preview_sample_keeps_sei(int codec, int length_size, const uint8_t *data, int size)
{
    const bool hevc = codec == AV_CODEC_ID_HEVC;
    if ((!hevc && codec != AV_CODEC_ID_H264) || length_size < 1 || length_size > 4 || !data)
        return false;
    for (int pos = 0; pos + length_size <= size;) {
        uint32_t length = 0;
        for (int i = 0; i < length_size; i++)
            length = length << 8 | data[pos++];
        if (length < (hevc ? 2U : 1U) || length > (uint32_t)(size - pos))
            break;
        const uint8_t *nal = data + pos;
        pos += (int)length;
        int type = hevc ? nal[0] >> 1 & 63 : nal[0] & 31;
        if (!(hevc ? type == 39 || type == 40 : type == 6))
            continue;
        const int header = hevc ? 2 : 1;
        uint8_t *rbsp = av_malloc(length);
        if (!rbsp)
            return true;
        size_t count = 0, zeros = 0;
        for (uint32_t i = (uint32_t)header; i < length; i++) {
            if (zeros >= 2 && nal[i] == 3) {
                zeros = 0;
                continue;
            }
            zeros = nal[i] ? 0 : zeros + 1;
            rbsp[count++] = nal[i];
        }
        bool kept = sei_kept(hevc, rbsp, count);
        av_free(rbsp);
        if (kept)
            return true;
    }
    return false;
}

/* For an edge, remember the sample about to be sent if it, or a sample sent before it since the keyframe, carries
 * SEI an encode drops. False when that cannot be recorded. */
static bool note_kept_sei(MPPreviewDecoder *preview, const AVPacket *packet)
{
    if (packet->pts == AV_NOPTS_VALUE)
        return true;
    if (!preview->kept_sei_count) {
        const enum AVCodecID codec = preview->format->streams[preview->video.index]->codecpar->codec_id;
        const int at = codec == AV_CODEC_ID_HEVC ? 21 : 4;
        if (preview->decoder_description_size <= at || preview->decoder_description[0] != 1 ||
            !mp_preview_sample_keeps_sei(codec, (preview->decoder_description[at] & 3) + 1, packet->data, packet->size))
            return true;
    }
    if (preview->kept_sei_count == preview->kept_sei_capacity) {
        int capacity = preview->kept_sei_capacity ? 2 * preview->kept_sei_capacity : 64;
        int64_t *grown = capacity > 0 ? av_realloc_array(preview->kept_sei_pts, (size_t)capacity, sizeof(*grown)) : NULL;
        if (!grown)
            return false;
        preview->kept_sei_pts = grown;
        preview->kept_sei_capacity = capacity;
    }
    preview->kept_sei_pts[preview->kept_sei_count++] = packet->pts;
    return true;
}

/* Whether the edge picture just decoded came from a sample that note_kept_sei recorded. */
static bool kept_sei(const MPPreviewDecoder *preview)
{
    const int64_t pts = preview->frame->pts != AV_NOPTS_VALUE ? preview->frame->pts : preview->frame->best_effort_timestamp;
    for (int i = 0; i < preview->kept_sei_count; i++)
        if (preview->kept_sei_pts[i] == pts)
            return true;
    // A picture whose sample time is unknown cannot be shown to precede the SEI.
    return preview->kept_sei_count && pts == AV_NOPTS_VALUE;
}

/* Colour volume, light level and viewing environment describe a whole coded sequence. HEVC and
 * AV1 decoders attach them to every picture of it; the H.264 decoder only to the picture whose
 * access unit carries the SEI. */
static bool sequence_metadata(const AVFrame *frame)
{
    return av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) ||
           av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) ||
           av_frame_get_side_data(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT);
}

// The decoder drops a packet it rejects, so one damaged packet is a brief
// dropout. About two seconds of consecutive failures is an undecodable stream.
static bool damaged_audio_packet(MPPreviewDecoder *preview, int result)
{
    bool damaged = result == AVERROR_INVALIDDATA && ++preview->audio_failures <= 100;
    preview->audio_damage |= damaged;
    return damaged;
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

bool mp_preview_edge_metadata(const MPPreviewDecoder *preview)
{
    return preview->edge_metadata;
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
    flush_video(preview);
    preview->recovering = false;
    preview->awaiting_keyframe = true;
    // A keyframe held for a new description (always a keyframe) reaches the emptied decoder next.
    preview->switching = false;
    preview->video_fed = false;
    preview->watch_leading = false;
}

static const char *const description_failure =
    "FFmpeg could not reopen the preview decoder with the video's new sample description.";

/* Keep the description the demuxer reports for a video packet, which the decoder may not hold. */
static bool note_description(MPPreviewDecoder *preview, const AVPacket *packet)
{
    size_t size = 0;
    const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
    if (!side || !size)
        return true;
    return size <= INT_MAX && copy_bytes(&preview->description, &preview->description_size, side, (int)size);
}

/* Whether the video decoder must be reopened for the description of the packets read last: 1 when it holds other
 * parameter sets, 0 when it holds the same, -1 when that cannot be recorded. */
static int needs_new_decoder(MPPreviewDecoder *preview)
{
    if (same_bytes(preview->description, preview->description_size,
                   preview->decoder_description, preview->decoder_description_size))
        return 0;
    if (!same_description(preview, preview->description, preview->description_size,
                          preview->decoder_description, preview->decoder_description_size))
        return 1;
    return copy_bytes(&preview->decoder_description, &preview->decoder_description_size,
                      preview->description, preview->description_size) ? 0 : -1;
}

/* The NAL unit type of the first picture unit of an HEVC sample, or -1. */
static int first_picture_unit(const MPPreviewDecoder *preview, const AVPacket *packet)
{
    if (preview->format->streams[preview->video.index]->codecpar->codec_id != AV_CODEC_ID_HEVC ||
        preview->decoder_description_size <= 21 || preview->decoder_description[0] != 1)
        return -1;
    const int width = (preview->decoder_description[21] & 3) + 1;
    for (int pos = 0; pos + width < packet->size;) {
        uint32_t length = 0;
        for (int i = 0; i < width; i++)
            length = length << 8 | packet->data[pos++];
        if (length < 2 || length > (uint32_t)(packet->size - pos))
            return -1;
        int type = packet->data[pos] >> 1 & 63;
        if (type < 32)
            return type;
        pos += (int)length;
    }
    return -1;
}

/* At an HEVC CRA picture under a new description with the same NAL unit length, put every set of the new description
 * into the sample and keep the decoder, which keeps the pictures its RASL pictures predict from. 1 when done, 0
 * when the decoder must be reopened instead, -1 on failure. */
static int carry_description(MPPreviewDecoder *preview, AVPacket *packet)
{
    DescriptionUnits now, held;
    if (first_picture_unit(preview, packet) != 21 ||
        !description_units(AV_CODEC_ID_HEVC, preview->description, preview->description_size, &now) ||
        !description_units(AV_CODEC_ID_HEVC, preview->decoder_description, preview->decoder_description_size, &held) ||
        now.length_size != held.length_size)
        return 0;
    int size = 0;
    for (int i = 0; i < now.count; i++)
        size += 4 + now.size[i];
    uint8_t *units = av_malloc((size_t)size + 1);
    if (!units)
        return -1;
    for (int i = 0, at = 0; i < now.count; at += 4 + now.size[i++]) {
        AV_WB32(units + at, (uint32_t)now.size[i]);
        memcpy(units + at + 4, now.data[i], (size_t)now.size[i]);
    }
    int result = insert_units(preview, packet, units, size, now.length_size);
    av_free(units);
    if (result < 0 || !copy_bytes(&preview->decoder_description, &preview->decoder_description_size,
                                  preview->description, preview->description_size))
        return -1;
    return 1;
}

static double timeline_seconds(const MPPreviewDecoder *preview, int64_t pts)
{
    return CMTimeGetSeconds(CMTimeSubtract(timestamp_time(pts, preview->video.codec->pkt_timebase),
                                           preview->timeline_origin));
}

/* After a reopen at a CRA picture, the samples before its first trailing picture: a RASL picture is dropped, so
 * record it for mp_preview_notice and treat its absence as a gap, as for damage. A Smart Trim edge must not lose a
 * picture, so it returns false there. */
static bool note_leading(MPPreviewDecoder *preview, const AVPacket *packet)
{
    int type = first_picture_unit(preview, packet);
    if (type != 8 && type != 9) { // RASL_N, RASL_R
        // RADL pictures decode from the CRA itself. Leading pictures precede every trailing one.
        preview->watch_leading = type == 6 || type == 7;
        return true;
    }
    if (preview->encoding_edge)
        return false;
    preview->met_damage = true;
    if (packet->pts != AV_NOPTS_VALUE) {
        if (!preview->leading_count || packet->pts < preview->leading_first)
            preview->leading_first = packet->pts;
        if (!preview->leading_count || packet->pts > preview->leading_last)
            preview->leading_last = packet->pts;
    }
    preview->leading_count++;
    snprintf(preview->leading_notice, sizeof(preview->leading_notice),
             "The video changes its sample description at an open keyframe at %.3f s. %d leading picture%s from "
             "%.3f s to %.3f s predict%s from pictures before it and could not be decoded, so %s omitted.",
             timeline_seconds(preview, preview->leading_key), preview->leading_count,
             preview->leading_count == 1 ? "" : "s", timeline_seconds(preview, preview->leading_first),
             timeline_seconds(preview, preview->leading_last), preview->leading_count == 1 ? "s" : "",
             preview->leading_count == 1 ? "it is" : "they are");
    return true;
}

int mp_preview_omission(const MPPreviewDecoder *preview)
{
    if (!preview)
        return MPPreviewOmitsNothing;
    if (preview->unaligned_switch)
        return MPPreviewOmitsUnalignedSwitch;
    if (preview->leading_count)
        return MPPreviewOmitsLeadingPictures;
    return preview->met_damage ? MPPreviewOmitsDamagedPicture : MPPreviewOmitsNothing;
}

const char *mp_preview_notice(const MPPreviewDecoder *preview)
{
    switch (mp_preview_omission(preview)) {
    case MPPreviewOmitsUnalignedSwitch:
        return "The video changes its sample description at a picture that is not a keyframe. "
               "Preview skipped to the next keyframe.";
    case MPPreviewOmitsLeadingPictures:
        return preview->leading_notice;
    case MPPreviewOmitsDamagedPicture:
        return "A damaged picture could not be decoded. Preview skipped to the next keyframe.";
    default:
        return NULL;
    }
}

bool mp_preview_met_audio_damage(const MPPreviewDecoder *preview)
{
    return preview && (preview->mix ? linked_mix_met_audio_damage(preview->mix) : preview->audio_damage);
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
                    // The edge encoder refuses only its own pictures. The pictures decoded before
                    // and after an edge are copied with their metadata, but sequence metadata
                    // seen since the last keyframe also describes the edge's pictures.
                    if (preview->encoding_edge) {
                        bool sequence = sequence_metadata(preview->frame);
                        preview->sequence_metadata = (preview->frame->flags & AV_FRAME_FLAG_KEY)
                            ? sequence : preview->sequence_metadata || sequence;
                        preview->edge_metadata = preview->sequence_metadata ||
                                                 !edge_metadata_supported(preview->frame) || kept_sei(preview);
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
            if (result == AVERROR_EOF && stream == &preview->video && preview->switching) {
                // Every picture of the old description has been returned. The held keyframe is sent next.
                if (!reopen_video(preview)) {
                    *error = description_failure;
                    return MPPreviewError;
                }
                preview->watch_leading = first_picture_unit(preview, preview->held) == 21; // CRA_NUT
                preview->leading_key = preview->held->pts;
            } else if (result == AVERROR_EOF && stream == &preview->video && preview->recovering)
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
        // A keyframe held for a new description follows the pictures the decoder had left.
        const bool held = !preview->switching && (preview->held->data || preview->held->side_data_elems);
        int result = 0;
        if (held) {
            av_packet_move_ref(preview->packet, preview->held);
        } else {
            result = av_read_frame(preview->format, preview->packet);
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
        }
        PreviewStream *stream = NULL;
        if (!preview->audio_only && preview->packet->stream_index == preview->video.index) {
            if (!held && !note_description(preview, preview->packet)) {
                av_packet_unref(preview->packet);
                *error = description_failure;
                return MPPreviewError;
            }
            if (!preview->awaiting_keyframe || (preview->packet->flags & AV_PKT_FLAG_KEY)) {
                preview->awaiting_keyframe = false;
                stream = &preview->video;
            }
        } else if (preview->packet->stream_index == preview->audio.index && mp_preview_has_audio(preview))
            stream = &preview->audio;
        const int renew = stream == &preview->video && preview->video.codec ? needs_new_decoder(preview) : 0;
        if (renew < 0) {
            av_packet_unref(preview->packet);
            *error = description_failure;
            return MPPreviewError;
        }
        // A description with other parameter sets needs a decoder of its own, from a keyframe on.
        if (renew) {
            if (!(preview->packet->flags & AV_PKT_FLAG_KEY)) {
                // The pictures from here to the next keyframe would be decoded with the old description.
                av_packet_unref(preview->packet);
                preview->unaligned_switch = true;
                if (damaged_video_picture(preview, AVERROR_INVALIDDATA, true))
                    continue;
                *error = preview->encoding_edge
                    ? "Smart Trim cannot follow a change of video sample description at a picture that is not a keyframe."
                    : "The video changes its sample description at a picture that is not a keyframe.";
                return MPPreviewError;
            }
            // A CRA picture's RASL pictures predict from pictures the decoder holds, which a reopened decoder would
            // drop. Give this session the new sets inside the sample instead, as a copy with in-band sets does.
            if (preview->video_fed) {
                const int carried = carry_description(preview, preview->packet);
                if (carried < 0) {
                    av_packet_unref(preview->packet);
                    *error = description_failure;
                    return MPPreviewError;
                }
                if (carried)
                    goto send;
            }
            if (preview->video_fed) {
                // Return the pictures decoded under the old description before reopening.
                av_packet_move_ref(preview->held, preview->packet);
                preview->switching = true;
                result = avcodec_send_packet(preview->video.codec, NULL);
                if (result >= 0) {
                    preview->receiving = &preview->video;
                    continue;
                }
                av_packet_unref(preview->held);
                preview->switching = false;
                *error = "VideoToolbox could not finish the pictures before the video's new sample description.";
                return MPPreviewError;
            }
            if (!reopen_video(preview)) {
                av_packet_unref(preview->packet);
                *error = description_failure;
                return MPPreviewError;
            }
        }
send:
        if (stream == &preview->video && preview->watch_leading && !held && !note_leading(preview, preview->packet)) {
            av_packet_unref(preview->packet);
            *error = "Smart Trim cannot decode the leading pictures of an open keyframe where the video sample "
                     "description changes.";
            return MPPreviewError;
        }
        if (stream == &preview->video && preview->encoding_edge && !note_kept_sei(preview, preview->packet)) {
            av_packet_unref(preview->packet);
            *error = "Could not allocate the Smart Trim edge decoder.";
            return MPPreviewError;
        }
        if (stream == &preview->video && preview->prime_pending) {
            preview->prime_pending = false;
            if (prime_packet(preview, preview->packet) < 0) {
                av_packet_unref(preview->packet);
                *error = "Cannot give the Smart Trim edge decoder the source's parameter sets.";
                return MPPreviewError;
            }
        }
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
            preview->video_fed |= stream == &preview->video;
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
