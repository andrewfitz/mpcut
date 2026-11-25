#include "PacketWriter.h"
#include "MediaProbe.h"
#include "timecode.h"
#include "aac_edits.h"
#include "avc_reorder.h"
#include "hevc_sets.h"
#include "mp3_crop.h"
#include "smart_edge.h"
#include "splice_headers.h"
#include "../CFFmpeg/copy_probe.h"
#include "../CFFmpeg/opus_packet.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/crc.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/sha.h>
#include <libavutil/spherical.h>
#include <libavutil/stereo3d.h>

typedef __int128 Wide;

void mpcut_normalize_flac_streaminfo(uint8_t *bytes, size_t size) {
    if (!bytes || size != 34)
        return;
    // The compressed frame sizes, total samples and MD5 describe one recording.
    // Zero denotes an unknown value. Preserve block sizes, rate, channels and bit depth.
    memset(bytes + 4, 0, 6);
    bytes[13] &= 0xf0;
    memset(bytes + 14, 0, 20);
}

static const int movie_timescale = 705600000;

typedef struct {
    int started;
    int finished;
    int copied;
    int64_t next_sample;
} OpusTrim;

typedef struct {
    MPCutEdgeRange plan;
    int64_t start_pts;
    int64_t end_pts;
    int64_t decode_pts;    /* The keyframe the edge's decoder starts from. */
    size_t consumed;
    MPCutEdge *encoded;
    int64_t *source_times;
    int64_t *encoded_times;
} EdgePatch;

typedef struct {
    AVFormatContext *output;
    AVPacket *packet;
    int has_first_packet;
    enum { MP3_HEADER_DEFAULT, MP3_HEADER_UNTAGGED, MP3_HEADER_GAPLESS } mp3_header;
    unsigned mp3_skip;        /* Samples a gapless header hides before the first audible one. */
    unsigned mp3_end_discard; /* Samples it hides after the last audible one. */
    MPCutAAC *aac_edits;
    MPCutAACSource *aac_source;
    OpusTrim *opus_trim;
    OpusTrim *opus_clock; /* Per input stream: Opus packets recounted on the sample clock for Ogg. */
    int64_t *last_dts;
    uint8_t *range_tracks;
    unsigned range_track_count;
    const MPCutTime *video_dts;
    size_t video_dts_count, video_dts_used;
    const char *output_path;
    MPCutProgress progress;
    void *progress_context;
    char *error;
    size_t error_capacity;
    double fraction;
    int tracks;
    int audio_stream;
    int *stream_map;
    unsigned selected_count;
    int has_timecode;
    AVRational timecode_rate;
    int smart_trim;
    int generated_stills;
    const uint32_t *still_mastering_display;
    struct AVSHA *picture_hash;
    uint8_t *picture_config;
    size_t picture_config_size;
    int restore_video_config;
    int edge_cancelled;
    int track_video_config;
    uint8_t *active_config;
    size_t active_config_size;
    int64_t video_origin_pts;
    EdgePatch patches[2];
    int delivered;      /* A file a person keeps: its chapters, and a sound-only source's cover art, travel with it. */
    int whole_sound;    /* Every audio track was selected, so a sound-only source is copied whole. */
    int keep_timecode;  /* A delivered picture-only movie keeps its MOV timecode track. */
    unsigned art_streams;
    uint8_t *art;       /* Per input stream of the first source: 1 when its cover picture is written. */
    int mov_chapter_clock; /* Nonzero when the MOV chapter track still counts milliseconds on this clock. */
    uint8_t *hvc1;         /* Per output stream: HEVC_ENTRY_* for a track the muxer labels 'hev1'. */
    int avc_reorder;       /* Reorder depth declared in H.264 parameter sets that lack one (plan_avc_reorder). */
    MPCutHevcSets **hevc_sets; /* Per output stream: the HEVC parameter sets active in an 'hvc1' track (check_hvc1). */
    unsigned hevc_set_count;
    int hevc_range_start;  /* The next retained HEVC sample is the first of a range. */
    uint8_t **hevc_early;  /* Per segment: picture parameter sets its range starts with (plan_hevc_sets). */
    int *hevc_early_size;
    int *hevc_videos;      /* Per segment: the input stream plan_hevc_sets read. */
    size_t hevc_early_count, hevc_range; /* hevc_range: the segment being written. */
    int hevc_range_video;  /* hevc_videos of that segment. */
    uint8_t **stream_sets; /* Per segment: the H.264/HEVC sets its source holds at the range start (plan_stream_sets). */
    int *stream_sets_size;
    size_t stream_set_count;
    MPCutHevcSets *output_sets; /* The sets the output's decoder holds (repeat_stream_sets). */
    MPCutHevcSets *description_sets; /* The sets of the sample description a reader starting at a keyframe has. */
    int sets_range_start;  /* The next copied picture of the primary video is the first of a range. */
    int sets_repeating;    /* The range started from repeated sets, which its later keyframes repeat too. */
    int sets_unfollowed;   /* The output's sets cannot be followed, so none are repeated. */
    int64_t *stream_start_pts; /* Per segment: the source packet stream_sets describe the decoder before. */
    MPCutHevcSets *smart_sets; /* Smart Trim: the sets the source's decoder holds, from stream_start_pts on. */
    int smart_unfollowed;  /* Smart Trim: the source's sets cannot be followed. */
    int smart_range_first; /* Smart Trim: the next copied picture is the first of its range. */
    int smart_repeating;   /* Smart Trim: the copied run repeats the source's sets at its keyframes (H.264). */
    int smart_dirty;       /* Smart Trim: the output's decoder may hold sets that the source description does not. */
    uint8_t *tail_sets;    /* Smart Trim: the sets at the tail edge's keyframe, for its decoder. */
    int tail_sets_size;
} Writer;

enum { HEVC_ENTRY_KEEP, HEVC_ENTRY_HVC1, HEVC_ENTRY_HEV1 };

static void plan_hvc1(Writer *writer, const AVStream *destination);

typedef struct {
    MPCutTime source_start;
    MPCutTime source_end;
    MPCutTime last_video_frame;
    MPCutTime output_start;
    MPCutTime output_end;
    MPCutTime shift;
    int keep_audio_start;
    int keep_audio_end;
    int whole_file;
    int whole_audio_selection;
    int opus_trim;
    int matroska_input;
} Range;

static int fail(Writer *writer, const char *format, ...) {
    if (writer->error && writer->error_capacity) {
        va_list args;
        va_start(args, format);
        vsnprintf(writer->error, writer->error_capacity, format, args);
        va_end(args);
    }
    return 1;
}

static int ff_error(Writer *writer, int code, const char *operation, const char *path) {
    char message[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, message, sizeof(message));
    return fail(writer, "%s %s: %s", operation, path, message);
}

static int progress_at(Writer *writer, double fraction) {
    if (fraction > writer->fraction) {
        writer->fraction = fraction > 1 ? 1 : fraction;
    }
    if (writer->progress && writer->progress(writer->progress_context, writer->fraction)) {
        fail(writer, "Export cancelled");
        return 2;
    }
    return 0;
}

static Wide gcd(Wide a, Wide b) {
    if (a < 0) {
        a = -a;
    }
    while (b) {
        Wide remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}

static MPCutTime time_make(Wide n, Wide d) {
    if (d <= 0) {
        return (MPCutTime){0, 0};
    }
    /* Reduce ordinary packet clocks without calling the wide-division
     * runtime. The wide path still handles intermediate products above 64 bits. */
    if (n >= INT64_MIN && n <= INT64_MAX && d <= INT64_MAX) {
        uint64_t a = (uint64_t)(n < 0 ? -n : n);
        uint64_t b = (uint64_t)d;
        while (b) {
            uint64_t remainder = a % b;
            a = b;
            b = remainder;
        }
        return (MPCutTime){(int64_t)n / (int64_t)a, (int64_t)d / (int64_t)a};
    }
    Wide divisor = gcd(n, d);
    n /= divisor;
    d /= divisor;
    if (n < INT64_MIN || n > INT64_MAX || d > INT64_MAX) {
        return (MPCutTime){0, 0};
    }
    return (MPCutTime){(int64_t)n, (int64_t)d};
}

static MPCutTime time_add(MPCutTime a, MPCutTime b, int sign) {
    if (a.denominator > 0 && a.denominator == b.denominator) {
        return time_make((Wide)a.numerator + sign * (Wide)b.numerator, a.denominator);
    }
    return time_make((Wide)a.numerator * b.denominator + sign * (Wide)b.numerator * a.denominator,
                     (Wide)a.denominator * b.denominator);
}

static MPCutTime time_ticks(int64_t ticks, AVRational base) {
    if (ticks == AV_NOPTS_VALUE) {
        return (MPCutTime){0, 0};
    }
    return time_make((Wide)ticks * base.num, base.den);
}

static int time_compare(MPCutTime a, MPCutTime b) {
    Wide left = (Wide)a.numerator * b.denominator;
    Wide right = (Wide)b.numerator * a.denominator;
    return (left > right) - (left < right);
}

/* FFmpeg's AV_ROUND_NEAR_INF, computed without reducing the clock to microseconds. */
static int64_t time_round(MPCutTime time, AVRational base) {
    if (time.denominator <= 0 || base.num <= 0 || base.den <= 0) {
        return AV_NOPTS_VALUE;
    }
    Wide n = (Wide)time.numerator * base.den;
    Wide d = (Wide)time.denominator * base.num;
    Wide rounded = n < 0 ? n - d / 2 : n + d / 2;
    if (rounded >= INT64_MIN && rounded <= INT64_MAX && d <= INT64_MAX)
        return (int64_t)rounded / (int64_t)d;
    Wide number = rounded / d;
    return number <= INT64_MIN || number > INT64_MAX ? AV_NOPTS_VALUE : (int64_t)number;
}

static double time_seconds(MPCutTime time) {
    return (double)time.numerator / time.denominator;
}

static int input_open(Writer *writer, AVFormatContext **input, const char *path) {
    int result = avformat_open_input(input, path, NULL, NULL);
    if (result < 0) {
        return ff_error(writer, result, "Cannot open", path);
    }
    const char *format = (*input)->iformat->name;
    if (av_match_name("mov", format) || av_match_name("matroska", format))
        return 0;
    if (av_match_name(format, "wav,aiff,flac") && (*input)->nb_streams > 0) {
        const AVCodecParameters *sound = (*input)->streams[0]->codecpar;
        if (sound->codec_type == AVMEDIA_TYPE_AUDIO && sound->sample_rate > 0 && sound->ch_layout.nb_channels > 0)
            return 0; // The file header supplies the codec and sample clock.
    }
    result = mpcut_probe_decoder_policy(*input);
    if (result < 0) {
        return ff_error(writer, result, "Cannot restrict decoder discovery for", path);
    }
    result = avformat_find_stream_info(*input, NULL);
    if (result < 0) {
        return ff_error(writer, result, "Cannot read stream information from", path);
    }
    return 0;
}

static int is_mov(const AVOutputFormat *format) {
    return av_match_name(format->name, "mov,mp4,ipod,3gp,3g2,ismv,f4v");
}

static int is_matroska(const AVOutputFormat *format) {
    return av_match_name(format->name, "matroska,webm");
}

static int mpegts_native_codec(enum AVCodecID codec) {
    switch (codec) {
        case AV_CODEC_ID_H264:
        case AV_CODEC_ID_HEVC:
        case AV_CODEC_ID_MPEG1VIDEO:
        case AV_CODEC_ID_MPEG2VIDEO:
        case AV_CODEC_ID_MPEG4:
        case AV_CODEC_ID_AAC:
        case AV_CODEC_ID_AAC_LATM:
        case AV_CODEC_ID_AC3:
        case AV_CODEC_ID_EAC3:
        case AV_CODEC_ID_MP2:
        case AV_CODEC_ID_MP3:
            return 1;
        default:
            return 0;
    }
}

static int primary_video(const AVStream *stream) {
    return stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
        !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC);
}

static int track_selection(int tracks) {
    switch (tracks) {
        case MPCUT_TRACKS_ALL:
        case MPCUT_TRACKS_VIDEO:
        case MPCUT_TRACKS_AUDIO:
            return tracks;
        case MPCUT_TRACKS_LINKED_AUDIO:
        case MPCUT_TRACKS_PROGRAM_AUDIO:
            return MPCUT_TRACKS_AUDIO;
        case MPCUT_TRACKS_DELIVERED_VIDEO:
        case MPCUT_TRACKS_DELIVERED_VIDEO_TIMECODE:
            return MPCUT_TRACKS_VIDEO;
        default:
            return -1;
    }
}

/* Record what the requested selection delivers before it is reduced to its primary tracks. */
static void set_delivery(Writer *writer, int tracks, int audio_stream) {
    writer->keep_timecode = tracks == MPCUT_TRACKS_DELIVERED_VIDEO_TIMECODE;
    writer->delivered = tracks == MPCUT_TRACKS_ALL || tracks == MPCUT_TRACKS_AUDIO ||
        tracks == MPCUT_TRACKS_DELIVERED_VIDEO || writer->keep_timecode;
    writer->whole_sound = tracks == MPCUT_TRACKS_AUDIO && audio_stream < 0;
}

static int timecode_track(const AVStream *stream) {
    return stream->codecpar->codec_type == AVMEDIA_TYPE_DATA && stream->codecpar->codec_tag == MPCUT_TIMECODE_TAG;
}

/* The MOV demuxer reads a track that other tracks name in a 'chap' reference into the
 * file's chapters, and marks the track itself as discarded binary data. The copy writes
 * those chapters into a new chapter track, so the source track is never copied as a stream.
 * This reads the demuxer's own mark: call it before the writer discards unmapped streams. */
static int chapter_track(const AVStream *stream) {
    const AVCodecParameters *codec = stream->codecpar;
    return codec->codec_type == AVMEDIA_TYPE_DATA && codec->codec_id == AV_CODEC_ID_BIN_DATA &&
        stream->discard == AVDISCARD_ALL;
}

/* Subtitle cues and timed data, such as camera telemetry, that travel beside the picture and sound of a movie.
 * The source's first MOV timecode track and a chapter list track are written by other means. */
static int extra_track(const AVStream *stream) {
    enum AVMediaType type = stream->codecpar->codec_type;
    return type == AVMEDIA_TYPE_SUBTITLE || (type == AVMEDIA_TYPE_DATA && !timecode_track(stream) && !chapter_track(stream));
}

/* Whether a copy into this container keeps an extra track whole: its packets and its sample description.
 * MOV keeps a 3GPP text description as it is, and GoPro telemetry ('gpmd'), whose description holds nothing
 * beyond its name. Other timed metadata, such as Apple's 'mebx', describes its keys in the sample description,
 * which the muxer does not write again, so it is left out and named. Matroska stores text cues by codec. */
static int carried_extra(const AVOutputFormat *format, const AVStream *stream) {
    const AVCodecParameters *codec = stream->codecpar;
    if (codec->codec_type == AVMEDIA_TYPE_DATA)
        return av_match_name(format->name, "mov,mp4") && codec->codec_tag == MKTAG('g', 'p', 'm', 'd');
    if (codec->codec_type != AVMEDIA_TYPE_SUBTITLE)
        return 0;
    switch (codec->codec_id) {
        case AV_CODEC_ID_MOV_TEXT:
            // QuickTime text ('text') keeps its own description only in a QuickTime movie.
            return (av_match_name(format->name, "mov,mp4,ipod") && codec->codec_tag == MKTAG('t', 'x', '3', 'g')) ||
                (!strcmp(format->name, "mov") && codec->codec_tag == MKTAG('t', 'e', 'x', 't'));
        case AV_CODEC_ID_WEBVTT:
            return is_matroska(format);
        case AV_CODEC_ID_SUBRIP:
        case AV_CODEC_ID_ASS:
        case AV_CODEC_ID_SSA:
            return !strcmp(format->name, "matroska");
        default:
            return 0;
    }
}

static int selected_stream(const Writer *writer, const AVStream *stream) {
    switch (writer->tracks) {
        case MPCUT_TRACKS_AUDIO:
            return stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                (writer->audio_stream < 0 || stream->index == writer->audio_stream);
        case MPCUT_TRACKS_VIDEO:
            // Timecode describes the picture, so a delivered picture-only movie can keep it.
            return primary_video(stream) || (writer->keep_timecode && timecode_track(stream));
        default:
            // Cover art and attached files travel as the art plan decides (plan_art, plan_files).
            if (chapter_track(stream) || stream->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT ||
                (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)))
                return 0;
            return !extra_track(stream) ||
                (writer->output && carried_extra(writer->output->oformat, stream));
    }
}

static int pcm_frame_size(const AVCodecParameters *codec);

static int validate_streams(Writer *writer, const AVFormatContext *input, int *timecode_index,
                            MPCutTimecode *timecode) {
    const AVOutputFormat *format = writer->output->oformat;
    int mov_color = av_match_name(format->name, "mov,mp4");
    unsigned video_count = 0;
    unsigned audio_count = 0;
    unsigned extra_count = 0;
    const AVStream *video = NULL;
    *timecode_index = -1;

    for (unsigned index = 0; index < input->nb_streams; index++) {
        const AVStream *stream = input->streams[index];
        const AVCodecParameters *codec = stream->codecpar;
        // A chapter track is left out only when its chapters were read and can be written again.
        if (writer->tracks == MPCUT_TRACKS_ALL && chapter_track(stream) &&
            (!input->nb_chapters || !av_match_name("mov", input->iformat->name)))
            return fail(writer, "Track %u in %s cannot be carried as linked video or audio", index, input->url);
        if (!selected_stream(writer, stream))
            continue;
        if (primary_video(stream)) {
            video_count++;
            video = stream;
        } else if (codec->codec_type == AVMEDIA_TYPE_DATA && codec->codec_tag == MPCUT_TIMECODE_TAG &&
                   av_match_name("mov", input->iformat->name) && *timecode_index < 0) {
            if (!av_match_name(format->name, "mov,mp4")) {
                return fail(writer, "%s cannot preserve the timecode track in %s", format->name, input->url);
            }
            const AVDictionaryEntry *reel = av_dict_get(stream->metadata, "reel_name", NULL, 0);
            if (reel && reel->value[0] && av_match_name(format->name, "mp4")) {
                return fail(writer, "mp4 cannot preserve the timecode reel name in %s", input->url);
            }
            *timecode_index = index;
            continue;
        } else if (codec->codec_type == AVMEDIA_TYPE_AUDIO) {
            audio_count++;
            if (!strcmp(format->name, "caf") && !pcm_frame_size(codec))
                return fail(writer, "CAF stream copy requires PCM on track %u.", index);
            if (writer->tracks == MPCUT_TRACKS_AUDIO && codec->codec_id == AV_CODEC_ID_MP3 &&
                av_match_name("mp3", input->iformat->name) && strcmp(format->name, "mp3") != 0 &&
                stream->start_time != AV_NOPTS_VALUE && stream->start_time > 0) {
                return fail(writer, "Use MP3 to preserve the encoder delay and trailing padding on track %u", index);
            }
        } else if (extra_track(stream)) {
            extra_count++; // carried_extra chose the container for it.
            continue;
        } else {
            return fail(writer, "Track %u in %s cannot be carried as linked video or audio", index, input->url);
        }

        int support = strcmp(format->name, "mpegts") == 0 ? mpegts_native_codec(codec->codec_id)
            : avformat_query_codec(format, codec->codec_id, FF_COMPLIANCE_NORMAL);
        // Ogg has no codec-tag table. query_codec can report zero for a valid
        // copy when that codec's encoder is absent from the FFmpeg build.
        if (writer->tracks == MPCUT_TRACKS_AUDIO && av_match_name(format->name, "ogg,oga"))
            support = codec->codec_id == AV_CODEC_ID_VORBIS || codec->codec_id == AV_CODEC_ID_OPUS ||
                codec->codec_id == AV_CODEC_ID_FLAC || codec->codec_id == AV_CODEC_ID_SPEEX;
        if (support <= 0 && format->audio_codec != codec->codec_id &&
            (!support || !format->codec_tag || !av_codec_get_tag(format->codec_tag, codec->codec_id))) {
            return fail(writer, "%s cannot carry track %u (%s) in %s",
                        format->name, index, avcodec_get_name(codec->codec_id), input->url);
        }

        // FFmpeg's Matroska writer keeps only base-layer sets in CodecPrivate, and Matroska has no place for an lhvC
        // record. A higher layer whose sets come only with the description could not be decoded from the copy.
        const char *layers = codec->codec_id == AV_CODEC_ID_HEVC && primary_video(stream)
            ? mpcut_hevc_layers(codec->extradata, codec->extradata_size) : NULL;
        if (layers && is_matroska(format))
            return fail(writer, "Choose MOV or MP4 to keep %s of track %u in %s. Matroska has no place for the "
                        "parameter sets of an additional HEVC layer, so that layer could not be decoded from the copy.",
                        layers, index, input->url);
        if (av_match_name("matroska", input->iformat->name) && !is_matroska(format)
            && (codec->codec_id == AV_CODEC_ID_VP8 || codec->codec_id == AV_CODEC_ID_VP9)) {
            const AVDictionaryEntry *alpha = av_dict_get(stream->metadata, "alpha_mode", NULL, 0);
            if (alpha && strcmp(alpha->value, "0") != 0) {
                return fail(writer, "%s cannot preserve separately coded alpha on track %u in %s",
                            format->name, index, input->url);
            }
        }
        for (int side_index = 0; side_index < codec->nb_coded_side_data; side_index++) {
            enum AVPacketSideDataType type = codec->coded_side_data[side_index].type;
            if (type == AV_PKT_DATA_STEREO3D && !is_matroska(format)) {
                const AVStereo3D *stereo = (const AVStereo3D *)codec->coded_side_data[side_index].data;
                // The MOV/MP4 muxer can reduce a packed eye layout to "unspecified"
                // when its eyes atom is read back, even if an st3d box is present.
                if (stereo->view == AV_STEREO3D_VIEW_PACKED && stereo->type != AV_STEREO3D_UNSPEC &&
                    stereo->type != AV_STEREO3D_2D)
                    return fail(writer, "Choose a compatible Matroska container to preserve the packed stereo layout on track %u in %s",
                                index, input->url);
            }
            if (type == AV_PKT_DATA_DOVI_CONF && strcmp(format->name, "mp4") != 0) {
                const AVDOVIDecoderConfigurationRecord *record =
                    (const AVDOVIDecoderConfigurationRecord *)codec->coded_side_data[side_index].data;
                // The Matroska muxer writes a Dolby Vision block mapping through profile 10.
                if (strcmp(format->name, "matroska") != 0 || record->dv_profile > 10)
                    return fail(writer, "Choose MP4 to preserve the Dolby Vision configuration on track %u in %s",
                                index, input->url);
            }
            if (type == AV_PKT_DATA_DISPLAYMATRIX && !is_mov(format)) {
                return fail(writer, "%s cannot preserve %s on track %u in %s", format->name,
                            av_packet_side_data_name(type), index, input->url);
            }
            if ((type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA || type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL)
                && !mov_color && !is_matroska(format)) {
                return fail(writer, "%s cannot preserve %s on track %u in %s", format->name,
                            av_packet_side_data_name(type), index, input->url);
            }
            if ((type == AV_PKT_DATA_ICC_PROFILE || type == AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT)
                && !mov_color) {
                return fail(writer, "%s cannot preserve %s on track %u in %s", format->name,
                            av_packet_side_data_name(type), index, input->url);
            }
        }
    }
    if (writer->tracks == MPCUT_TRACKS_AUDIO && audio_count == 0)
        return fail(writer, "%s has no audio tracks to copy", input->url);
    if (audio_count > 1 && av_match_name(format->name, "wav,aiff,caf,mp3,flac,adts,ac3,eac3"))
        return fail(writer, "%s carries only one audio track. Use a multitrack container.", format->name);
    if (writer->tracks != MPCUT_TRACKS_AUDIO && video_count != 1) {
        return fail(writer, "%s has %d primary video tracks. Exactly one is required", input->url, video_count);
    }
    if (*timecode_index >= 0 && mpcut_timecode_describe(input->streams[*timecode_index], video, timecode) < 0) {
        return fail(writer, "Unsupported MOV timecode description or frame rate in %s", input->url);
    }
    writer->selected_count = video_count + audio_count + extra_count;
    return 0;
}

static int prepare_output(Writer *writer) {
    int result = avformat_alloc_output_context2(&writer->output, NULL, NULL, writer->output_path);
    if (result < 0 || !writer->output) {
        return ff_error(writer, result < 0 ? result : AVERROR_MUXER_NOT_FOUND,
                        "Cannot choose an output container for", writer->output_path);
    }
    const AVOutputFormat *format = writer->output->oformat;
    if (format->flags & AVFMT_NOFILE || (!is_mov(format) && !is_matroska(format)
        && !av_match_name(format->name, "mpegts,avi,mxf,mxf_opatom,nut")
        && !(writer->tracks == MPCUT_TRACKS_AUDIO && av_match_name(format->name, "wav,aiff,caf,mp3,flac,ogg,oga,opus,adts,ac3,eac3")))) {
        return fail(writer, "%s is unsupported for single-file stream copy", writer->output->oformat->name);
    }
    return 0;
}

static int check_mux(Writer *writer, AVFormatContext **input, const char *input_path, int padded_opus_track)
{
    if (!input_path || !writer->output_path)
        return fail(writer, "Input and output paths are required");
    writer->tracks = track_selection(writer->tracks);
    if (writer->tracks < 0)
        return fail(writer, "Invalid track selection");
    int result = prepare_output(writer);
    if (!result && writer->tracks != MPCUT_TRACKS_VIDEO && padded_opus_track >= 0 &&
        (writer->tracks != MPCUT_TRACKS_AUDIO || writer->audio_stream < 0 || writer->audio_stream == padded_opus_track) &&
        is_mov(writer->output->oformat)) {
        result = fail(writer, "Copying Opus track %d to %s would change its audible range. "
                      "Use MKV for lossless audio or choose Re-encode with AAC.", padded_opus_track,
                      writer->output->oformat->name);
    }
    if (!result && !*input) {
        result = input_open(writer, input, input_path);
        if (result) avformat_close_input(input);
    }
    if (!result) {
        int timecode_index;
        MPCutTimecode timecode;
        result = validate_streams(writer, *input, &timecode_index, &timecode);
    }
    avformat_free_context(writer->output);
    return result;
}

int mpcut_check_mux(const char *input_path, const char *output_path, int padded_opus_track, int tracks, int audio_stream,
                    char *error, size_t error_capacity)
{
    Writer writer = {.output_path = output_path, .tracks = tracks, .audio_stream = audio_stream, .error = error, .error_capacity = error_capacity};
    AVFormatContext *input = NULL;
    int result = check_mux(&writer, &input, input_path, padded_opus_track);
    avformat_close_input(&input);
    return result;
}

void mpcut_check_muxes(const char *input_path, const char *const *output_paths, size_t count,
                      int padded_opus_track, int tracks, int audio_stream, uint8_t *supported)
{
    if (!output_paths || !supported)
        return;
    AVFormatContext *input = NULL;
    for (size_t i = 0; i < count; i++) {
        Writer writer = {.output_path = output_paths[i], .tracks = tracks, .audio_stream = audio_stream};
        supported[i] = output_paths[i] && !check_mux(&writer, &input, input_path, padded_opus_track);
    }
    avformat_close_input(&input);
}

/* Each input can put its selected tracks at different stream indices. */
static int map_streams(Writer *writer, AVFormatContext *input, int timecode_index) {
    av_freep(&writer->stream_map);
    writer->stream_map = av_malloc_array(input->nb_streams, sizeof(*writer->stream_map));
    if (!writer->stream_map)
        return fail(writer, "Cannot allocate track mapping");
    int destination = 0;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        if ((int)i != timecode_index && selected_stream(writer, input->streams[i])) {
            writer->stream_map[i] = destination++;
        } else {
            writer->stream_map[i] = -1;
        }
    }
    return 0;
}

/* Matroska statistics tags (for example mkvmerge's DURATION-eng) describe the whole source track.
 * The muxer filters only an exact DURATION key, so a copied stale value would describe the wrong length. */
static int drop_statistics_tags(AVDictionary **metadata)
{
    static const char *const names[] = { "DURATION", "BPS", "NUMBER_OF_FRAMES", "NUMBER_OF_BYTES" };
    AVDictionary *kept = NULL;
    const AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_iterate(*metadata, entry))) {
        int stale = !av_strncasecmp(entry->key, "_STATISTICS_", 12);
        for (size_t i = 0; !stale && i < sizeof(names) / sizeof(names[0]); i++) {
            size_t length = strlen(names[i]);
            stale = !av_strncasecmp(entry->key, names[i], length)
                && (entry->key[length] == '\0' || entry->key[length] == '-');
        }
        if (!stale && av_dict_set(&kept, entry->key, entry->value, 0) < 0) {
            av_dict_free(&kept);
            return AVERROR(ENOMEM);
        }
    }
    av_dict_free(metadata);
    *metadata = kept;
    return 0;
}

/* Raw MP3 has no timing metadata apart from its optional gapless tag. Even a
 * zero LAME delay field hides 529 samples. Use the source packet's actual skip
 * so this also works for MP3 tracks extracted from another container. A source
 * without a skip still gets a Xing frame for its duration and seek table; its
 * LAME extension is cleared afterwards (mp3_finish_header). */
static int configure_whole_mp3(Writer *writer, AVFormatContext *input, const AVStream *source) {
    AVPacket *packet = writer->packet;
    int code;
    do {
        av_packet_unref(packet);
        int cancel = progress_at(writer, writer->fraction);
        if (cancel) return cancel;
        code = av_read_frame(input, packet);
    } while (code >= 0 && packet->stream_index != source->index);
    if (code < 0) return ff_error(writer, code, "Cannot read the first MP3 frame in", input->url);

    writer->has_first_packet = 1;
    size_t size = 0;
    const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &size);
    unsigned skip = side && size >= 10 ? AV_RL32(side) : 0;
    if (skip && (skip < 529 || skip > 529 + 4095))
        return fail(writer, "The MP3 header cannot preserve the original leading delay on track %d.", source->index);
    writer->mp3_header = skip ? MP3_HEADER_GAPLESS : MP3_HEADER_UNTAGGED;
    writer->mp3_skip = skip;
    return 0;
}

/* Finish the muxer's Xing frame. A source without a delay gets a plain one: frame count,
 * byte count and seek table, with no encoder ID or delay fields for a reader to act on.
 * A gapless header gets its two 12-bit LAME fields from the writer's own counts, because
 * the muxer's count of the trailing padding depends on the FFmpeg release: 9.0 stores the
 * last packet's value and always adds the decoder's 529 samples, 9.1 adds up consecutive
 * packets and stores zero when the last packet discards nothing. */
static int mp3_finish_header(Writer *writer) {
    enum { XING_FIELDS = 4 + 4 + 4 + 4 + 100 + 4, LAME_FIELDS = 36, LAME_DELAYS = 21, LAME_CHECKSUM = 34, CHECKED = 190 };
    static const uint8_t blank[LAME_FIELDS] = {0};
    uint8_t bytes[10];
    int gapless = writer->mp3_header == MP3_HEADER_GAPLESS;
    int failed = 1;
    FILE *file = fopen(writer->output_path, "r+b");
    if (!file)
        return fail(writer, "Cannot reopen %s to finish its MP3 header", writer->output_path);
    long frame = 0;
    if (fread(bytes, 1, 10, file) == 10 && !memcmp(bytes, "ID3", 3)) {
        frame = 10 + ((long)(bytes[6] & 0x7f) << 21 | (bytes[7] & 0x7f) << 14 | (bytes[8] & 0x7f) << 7 | (bytes[9] & 0x7f))
            + (bytes[5] & 0x10 ? 10 : 0);
    }
    if (fseek(file, frame, SEEK_SET) || fread(bytes, 1, 4, file) != 4 || bytes[0] != 0xff || (bytes[1] & 0xe0) != 0xe0) {
        failed = gapless; // No leading frame to finish.
        goto done;
    }
    int mpeg1 = (bytes[1] & 0x18) == 0x18;
    int mono = (bytes[3] & 0xc0) == 0xc0;
    long tag = frame + 4 + (mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17));
    if (fseek(file, tag, SEEK_SET) || fread(bytes, 1, 8, file) != 8
        || (memcmp(bytes, "Xing", 4) && memcmp(bytes, "Info", 4)) || AV_RB32(bytes + 4) != 0x0f) {
        failed = gapless; // The muxer wrote no Xing frame.
        goto done;
    }
    if (!gapless) {
        failed = fseek(file, tag + XING_FIELDS, SEEK_SET) || fwrite(blank, 1, LAME_FIELDS, file) != LAME_FIELDS;
        goto done;
    }
    /* The muxer's checksum covers 190 bytes of its own frame: everything before the checksum
     * field, then the zeros that fill the field and the rest of the frame at that moment. */
    uint8_t checked[CHECKED] = {0};
    size_t covered = (size_t)(tag - frame) + XING_FIELDS + LAME_CHECKSUM;
    AV_WB24(bytes, (writer->mp3_skip - 529) << 12 | (writer->mp3_end_discard + 529));
    if (writer->mp3_skip < 529 || writer->mp3_skip > 529 + 4095 || writer->mp3_end_discard > 4095 - 529
        || covered > CHECKED || fseek(file, tag + XING_FIELDS + LAME_DELAYS, SEEK_SET) || fwrite(bytes, 1, 3, file) != 3
        || fseek(file, frame, SEEK_SET) || fread(checked, 1, covered, file) != covered)
        goto done;
    AV_WB16(bytes, av_crc(av_crc_get_table(AV_CRC_16_ANSI_LE), 0, checked, CHECKED));
    failed = fseek(file, tag + XING_FIELDS + LAME_CHECKSUM, SEEK_SET) || fwrite(bytes, 1, 2, file) != 2;
done:
    if (fclose(file))
        failed = 1;
    return failed ? fail(writer, "Cannot finish the MP3 header in %s", writer->output_path) : 0;
}

static int set_still_hdr(Writer *writer, AVCodecParameters *codec)
{
    av_packet_side_data_remove(codec->coded_side_data, &codec->nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    const uint32_t *values = writer->still_mastering_display;
    if (!values)
        return 0;

    AVPacketSideData *side = av_packet_side_data_new(&codec->coded_side_data, &codec->nb_coded_side_data,
                                                     AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
                                                     sizeof(AVMasteringDisplayMetadata), 0);
    if (!side)
        return fail(writer, "Cannot set mastering-display metadata on the assembled picture track");
    AVMasteringDisplayMetadata *display = (AVMasteringDisplayMetadata *)side->data;
    memset(display, 0, sizeof(*display));
    for (int i = 0; i < 6; i++)
        display->display_primaries[(i / 2 + 1) % 3][i % 2] = (AVRational){(int)values[i], 50000};
    display->white_point[0] = (AVRational){(int)values[6], 50000};
    display->white_point[1] = (AVRational){(int)values[7], 50000};
    display->max_luminance = av_make_q((int)values[8], 10000);
    display->min_luminance = av_make_q((int)values[9], 10000);
    display->has_primaries = display->has_luminance = 1;
    return 0;
}

/* --- Cover art and chapters ---
 * A delivered copy keeps what describes the recording as a whole. Muxers store a
 * picture in different forms, and several containers store neither. */

enum { ART_NONE, ART_PICTURE_STREAM, ART_ATTACHMENT };

static int art_form(const AVOutputFormat *format) {
    // The MOV muxer writes cover atoms only into the iTunes metadata of MP4 and M4A, never into a QuickTime movie.
    if (!strcmp(format->name, "mp4") || !strcmp(format->name, "ipod") ||
        !strcmp(format->name, "mp3") || !strcmp(format->name, "flac"))
        return ART_PICTURE_STREAM;
    return strcmp(format->name, "matroska") ? ART_NONE : ART_ATTACHMENT;
}

static int attached_picture(const AVStream *stream) {
    return stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && (stream->disposition & AV_DISPOSITION_ATTACHED_PIC);
}

static int sound_only(const AVFormatContext *input) {
    for (unsigned i = 0; i < input->nb_streams; i++)
        if (primary_video(input->streams[i]))
            return 0;
    return 1;
}

static const char *picture_mime(const AVStream *stream) {
    const AVDictionaryEntry *named = av_dict_get(stream->metadata, "mimetype", NULL, 0);
    if (named && named->value[0])
        return named->value;
    const AVCodecDescriptor *codec = avcodec_descriptor_get(stream->codecpar->codec_id);
    return codec && codec->mime_types ? codec->mime_types[0] : NULL;
}

/* Whether the muxer has a picture type for this codec: MP4 cover atoms, ID3 and FLAC picture blocks. */
static int art_codec(const AVOutputFormat *format, const AVStream *stream) {
    int mp4 = !strcmp(format->name, "mp4") || !strcmp(format->name, "ipod");
    switch (stream->codecpar->codec_id) {
        case AV_CODEC_ID_MJPEG:
        case AV_CODEC_ID_PNG:
        case AV_CODEC_ID_BMP:
            return 1;
        case AV_CODEC_ID_GIF:
            return !mp4 && strcmp(format->name, "flac");
        case AV_CODEC_ID_TIFF:
        case AV_CODEC_ID_WEBP:
        case AV_CODEC_ID_JPEGXL:
            return !mp4;
        default:
            return 0;
    }
}

/* MOV cover atoms and ID3 pictures carry no pixel size, and these inputs are not decoded.
 * Read it from the picture's own header. */
static int picture_size(const AVStream *stream, int *width, int *height) {
    const uint8_t *data = stream->attached_pic.data;
    int size = stream->attached_pic.size;
    *width = stream->codecpar->width;
    *height = stream->codecpar->height;
    if (*width > 0 && *height > 0)
        return 1;
    *width = *height = 0;
    switch (stream->codecpar->codec_id) {
        case AV_CODEC_ID_PNG:
            if (size >= 24 && !memcmp(data, "\x89PNG\r\n\x1a\n", 8)) {
                *width = (int)AV_RB32(data + 16);
                *height = (int)AV_RB32(data + 20);
            }
            break;
        case AV_CODEC_ID_GIF:
            if (size >= 10 && !memcmp(data, "GIF8", 4)) {
                *width = AV_RL16(data + 6);
                *height = AV_RL16(data + 8);
            }
            break;
        case AV_CODEC_ID_BMP:
            if (size >= 26 && data[0] == 'B' && data[1] == 'M') {
                int32_t rows = (int32_t)AV_RL32(data + 22);
                *width = (int)AV_RL32(data + 18);
                *height = rows < 0 ? -rows : rows;
            }
            break;
        case AV_CODEC_ID_MJPEG:
            for (int at = 2; at + 9 <= size;) {
                if (data[at] != 0xff) {
                    break;
                }
                uint8_t marker = data[at + 1];
                if (marker == 0xff) {
                    at++; // Fill byte.
                } else if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
                    at += 2; // No payload.
                } else if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
                    *height = AV_RB16(data + at + 5);
                    *width = AV_RB16(data + at + 7);
                    break;
                } else if (marker == 0xda || marker == 0xd9) {
                    break; // Scan data follows, with no frame header before it.
                } else {
                    at += 2 + AV_RB16(data + at + 2);
                }
            }
            break;
        default:
            break;
    }
    return *width > 0 && *height > 0 && *width <= 65535 && *height <= 65535;
}

/* What describes the recording as a whole travels with a delivered copy of the whole recording:
 * every audio track of a sound-only source, or the picture and sound of a movie. */
static int whole_recording(const Writer *writer, const AVFormatContext *input) {
    if (!writer->delivered)
        return 0;
    return sound_only(input) ? writer->whole_sound : writer->tracks == MPCUT_TRACKS_ALL;
}

/* Cover art travels with the whole recording (whole_recording). Marks the
 * source pictures the output stores and returns how many it cannot store. */
static unsigned plan_art(const Writer *writer, const AVFormatContext *input, uint8_t *keep, unsigned *kept) {
    *kept = 0;
    if (!whole_recording(writer, input))
        return 0;
    const AVOutputFormat *format = writer->output->oformat;
    int form = art_form(format);
    int flac = !strcmp(format->name, "flac");
    unsigned dropped = 0, icons = 0;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        if (!attached_picture(stream))
            continue;
        int width = 0, height = 0;
        int usable = form != ART_NONE && stream->attached_pic.size > 0 &&
            !(stream->disposition & AV_DISPOSITION_TIMED_THUMBNAILS);
        if (usable && form == ART_ATTACHMENT)
            usable = picture_mime(stream) != NULL;
        if (usable && form == ART_PICTURE_STREAM)
            usable = art_codec(format, stream) && picture_size(stream, &width, &height);
        if (usable && flac) {
            // FLAC allows one of each file icon, and the standard icon is a 32x32 PNG.
            const AVDictionaryEntry *type = av_dict_get(stream->metadata, "comment", NULL, 0);
            unsigned icon = !type ? 0 : !av_strcasecmp(type->value, "32x32 pixels 'file icon' (PNG only)") ? 1
                : !av_strcasecmp(type->value, "Other file icon") ? 2 : 0;
            if ((icons & icon) || (icon == 1 && (stream->codecpar->codec_id != AV_CODEC_ID_PNG || width != 32 || height != 32)))
                usable = 0;
            icons |= icon;
        }
        if (usable) {
            if (keep)
                keep[i] = 1;
            (*kept)++;
        } else {
            dropped++;
        }
    }
    return dropped;
}

/* A file attached to a Matroska file that is not a picture, such as a font. */
static int attached_file(const AVStream *stream) {
    return stream->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT;
}

/* Attached files travel as cover art does, and only Matroska stores them. Marks the
 * source files the output stores and returns how many it cannot store. */
static unsigned plan_files(const Writer *writer, const AVFormatContext *input, uint8_t *keep, unsigned *kept) {
    *kept = 0;
    if (!whole_recording(writer, input))
        return 0;
    int stored = !strcmp(writer->output->oformat->name, "matroska");
    unsigned dropped = 0;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        if (!attached_file(input->streams[i]))
            continue;
        if (stored && keep)
            keep[i] = 1;
        *kept += stored;
        dropped += !stored;
    }
    return dropped;
}

static int add_art(Writer *writer, const AVFormatContext *input) {
    AVFormatContext *output = writer->output;
    unsigned kept = 0;
    writer->art = av_calloc(input->nb_streams ? input->nb_streams : 1, 1);
    if (!writer->art)
        return fail(writer, "Cannot allocate cover art state");
    plan_art(writer, input, writer->art, &kept);
    plan_files(writer, input, writer->art, &kept);
    int form = art_form(output->oformat);
    for (unsigned i = 0; i < input->nb_streams; i++) {
        if (!writer->art[i])
            continue;
        const AVStream *source = input->streams[i];
        AVStream *destination = avformat_new_stream(output, NULL);
        if (!destination)
            return fail(writer, "Cannot allocate a cover art track");
        AVCodecParameters *codec = destination->codecpar;
        int result = avcodec_parameters_copy(codec, source->codecpar);
        if (result >= 0)
            result = av_dict_copy(&destination->metadata, source->metadata, 0);
        codec->codec_tag = 0;
        destination->id = destination->index + 1;
        destination->time_base = (AVRational){1, 90000};
        if (result >= 0 && attached_file(source)) {
            // The copied parameters hold the file itself. Matroska requires a name and a MIME type with it.
            result = av_dict_set(&destination->metadata, "filename", "attachment", AV_DICT_DONT_OVERWRITE);
            if (result >= 0)
                result = av_dict_set(&destination->metadata, "mimetype", "application/octet-stream", AV_DICT_DONT_OVERWRITE);
        } else if (result >= 0 && form == ART_ATTACHMENT) {
            // Matroska stores a picture as an attached file. Its readers find cover art by MIME type.
            const char *mime = picture_mime(source);
            const char *subtype = strchr(mime, '/');
            char name[48];
            subtype = subtype ? subtype + 1 : "bin";
            snprintf(name, sizeof(name), "cover.%s", !strcmp(subtype, "jpeg") ? "jpg" : !strcmp(subtype, "x-ms-bmp") ? "bmp" : subtype);
            av_freep(&codec->extradata);
            codec->extradata_size = 0;
            codec->codec_type = AVMEDIA_TYPE_ATTACHMENT;
            codec->extradata = av_mallocz((size_t)source->attached_pic.size + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!codec->extradata)
                return fail(writer, "Cannot allocate cover art");
            memcpy(codec->extradata, source->attached_pic.data, (size_t)source->attached_pic.size);
            codec->extradata_size = source->attached_pic.size;
            result = av_dict_set(&destination->metadata, "mimetype", mime, AV_DICT_DONT_OVERWRITE);
            if (result >= 0)
                result = av_dict_set(&destination->metadata, "filename", name, AV_DICT_DONT_OVERWRITE);
        } else if (result >= 0) {
            destination->disposition = AV_DISPOSITION_ATTACHED_PIC;
            picture_size(source, &codec->width, &codec->height);
        }
        if (result < 0)
            return ff_error(writer, result, "Cannot copy cover art from", input->url);
        writer->art_streams++;
    }
    return 0;
}

/* Muxers that take a picture as a stream expect its one packet before the sound. */
static int write_art(Writer *writer, const AVFormatContext *input) {
    AVFormatContext *output = writer->output;
    if (!writer->art_streams || art_form(output->oformat) != ART_PICTURE_STREAM)
        return 0;
    int index = (int)(output->nb_streams - writer->art_streams);
    for (unsigned i = 0; i < input->nb_streams; i++) {
        if (!writer->art[i])
            continue;
        AVPacket *picture = av_packet_clone(&input->streams[i]->attached_pic);
        if (!picture)
            return fail(writer, "Cannot allocate cover art");
        picture->stream_index = index++;
        picture->pts = picture->dts = 0;
        picture->duration = 0;
        picture->pos = -1;
        picture->flags |= AV_PKT_FLAG_KEY;
        int result = av_interleaved_write_frame(output, picture);
        av_packet_free(&picture);
        if (result < 0)
            return ff_error(writer, result, "Cannot write cover art to", writer->output_path);
    }
    return 0;
}

typedef struct {
    MPCutTime start, end; /* On the output timeline. */
    AVDictionary *metadata;
    int64_t id;
    size_t source;        /* The first segment that names this chapter's file. */
    unsigned index;       /* Its position among that file's chapters. */
} Chapter;

typedef struct {
    Chapter *items;
    size_t count;
    int unplaced;         /* A range could not be placed on the output timeline. */
    int64_t moved_start;  /* Milliseconds by which a MOV chapter track moves the first chapter back to zero. */
    unsigned closed_gaps; /* Chapters that run on to the next one where the container stores no chapter end. */
} Chapters;

static void free_chapters(Chapters *chapters) {
    for (size_t i = 0; i < chapters->count; i++)
        av_dict_free(&chapters->items[i].metadata);
    av_freep(&chapters->items);
    chapters->count = 0;
}

enum { CHAPTERS_NONE, CHAPTERS_PLAIN, CHAPTERS_MOV };

static int chapter_form(const AVOutputFormat *format) {
    if (!strcmp(format->name, "mov") || !strcmp(format->name, "mp4") || !strcmp(format->name, "ipod"))
        return CHAPTERS_MOV; // A text track that the movie's other tracks reference.
    // The Ogg muxer lists chapters among an Opus stream's comments, and for no other codec.
    return is_matroska(format) || av_match_name(format->name, "mp3,opus") ? CHAPTERS_PLAIN : CHAPTERS_NONE;
}

static MPCutTime mov_audio_lead(const MPCutSegment *segment);

/* Place every source chapter on the output timeline: clip it to the kept ranges, move it by
 * each range's offset, and rejoin the pieces of one chapter that neighbouring ranges share.
 * A chapter that lies wholly in removed material has no place and is left out. */
static int plan_chapters(const Writer *writer, const MPCutSegment *segments, size_t count,
                         const AVFormatContext *first, MPCutTime first_origin, int movie_clock, Chapters *plan) {
    AVFormatContext *other = NULL;
    MPCutTime cursor = {0, 1};
    int result = 0;
    for (size_t at = 0; at < count && !result && !plan->unplaced; at++) {
        const MPCutSegment *segment = &segments[at];
        size_t source = 0;
        while (strcmp(segments[source].path, segment->path))
            source++;
        const AVFormatContext *input = first;
        if (source) {
            if (!other || strcmp(other->url, segment->path)) {
                avformat_close_input(&other);
                if (avformat_open_input(&other, segment->path, NULL, NULL) < 0) {
                    plan->unplaced = 1;
                    break;
                }
            }
            input = other;
        }
        MPCutTime origin = segment->source_origin.denominator > 0 ? segment->source_origin
            : source ? (MPCutTime){0, 0} : first_origin;
        MPCutTime source_start = time_add(origin, segment->start, 1);
        MPCutTime source_end = time_add(origin, segment->end, 1);
        MPCutTime shift = time_add(cursor, source_start, -1);
        int whole = count == 1 && segment->start.numerator == 0 && segment->reaches_end;
        if (whole && movie_clock && is_mov(writer->output->oformat))
            shift = time_add(shift, mov_audio_lead(segment), 1);
        // A whole MP3 keeps its frames and its decoder delay, so its chapter times still describe it.
        if (whole && !strcmp(writer->output->oformat->name, "mp3"))
            shift = (MPCutTime){0, 1};
        /* MP3 chapter times count from the first frame. A cropped MP3 starts with decoder history
         * that its header hides, so its first audible sample comes that much later. */
        MPCutTime lead = {0, 1};
        if (!whole && count == 1 && writer->tracks == MPCUT_TRACKS_AUDIO && source_start.denominator &&
            !strcmp(writer->output->oformat->name, "mp3") && !strcmp(input->iformat->name, "mp3")) {
            for (unsigned i = 0; i < input->nb_streams && !lead.numerator; i++) {
                int rate = input->streams[i]->codecpar->sample_rate;
                if (selected_stream(writer, input->streams[i]) && rate > 0)
                    lead = (MPCutTime){mpcut_mp3_crop_lead(time_round(source_start, (AVRational){1, rate}), rate), rate};
            }
            shift = time_add(shift, lead, 1);
        }
        cursor = time_add(cursor, time_add(segment->end, segment->start, -1), 1);
        if (origin.denominator <= 0 || !source_start.denominator || !source_end.denominator ||
            !shift.denominator || !cursor.denominator) {
            plan->unplaced = input->nb_chapters > 0;
            continue;
        }
        for (unsigned index = 0; index < input->nb_chapters && !result; index++) {
            const AVChapter *chapter = input->chapters[index];
            MPCutTime start = time_ticks(chapter->start, chapter->time_base);
            MPCutTime end = time_ticks(chapter->end, chapter->time_base);
            if (!start.denominator)
                continue;
            if (!end.denominator || time_compare(end, start) < 0) {
                // No stated end: the chapter runs to the next one, or to the end of the range.
                end = (MPCutTime){0, 0};
                for (unsigned next = 0; next < input->nb_chapters; next++) {
                    MPCutTime later = time_ticks(input->chapters[next]->start, input->chapters[next]->time_base);
                    if (later.denominator && time_compare(later, start) > 0 &&
                        (!end.denominator || time_compare(later, end) < 0))
                        end = later;
                }
                if (!end.denominator)
                    end = time_compare(source_end, start) > 0 ? source_end : start;
            }
            // The chapter that is playing where a cropped MP3 begins also covers its hidden history.
            int covers_lead = lead.numerator && time_compare(start, source_start) <= 0;
            if (!whole) {
                if (time_compare(start, source_start) < 0)
                    start = source_start;
                if (time_compare(end, source_end) > 0)
                    end = source_end;
                if (time_compare(end, start) <= 0)
                    continue;
            }
            start = covers_lead ? (MPCutTime){0, 1} : time_add(start, shift, 1);
            end = time_add(end, shift, 1);
            if (!start.denominator || !end.denominator) {
                plan->unplaced = 1;
                break;
            }
            if (start.numerator < 0)
                start = (MPCutTime){0, 1};
            if (time_compare(end, start) < 0)
                continue;
            Chapter *last = plan->count ? &plan->items[plan->count - 1] : NULL;
            if (last && last->source == source && last->index == index && time_compare(last->end, start) == 0) {
                last->end = end;
                continue;
            }
            if (last && last->source == source && !time_compare(last->start, start) && !time_compare(last->end, end)) {
                // A movie can list one chapter twice, in its chapter track and in a Nero chapter list.
                const AVDictionaryEntry *title = av_dict_get(chapter->metadata, "title", NULL, 0);
                const AVDictionaryEntry *listed = av_dict_get(last->metadata, "title", NULL, 0);
                if (!strcmp(title ? title->value : "", listed ? listed->value : ""))
                    continue;
            }
            Chapter *grown = av_realloc_array(plan->items, plan->count + 1, sizeof(*grown));
            if (!grown) {
                result = AVERROR(ENOMEM);
                break;
            }
            plan->items = grown;
            grown[plan->count] = (Chapter){.start = start, .end = end, .id = chapter->id, .source = source, .index = index};
            result = av_dict_copy(&grown[plan->count].metadata, chapter->metadata, 0);
            plan->count++;
        }
    }
    avformat_close_input(&other);
    if (plan->unplaced)
        free_chapters(plan);
    return result;
}

/* The MOV chapter track counts whole milliseconds and needs each chapter to start after the one before.
 * Its first sample always starts with the movie: the muxer places it at zero whatever time it is given. */
static int mov_chapter_times(const Chapter *chapter, int64_t previous_start, int64_t *start, int64_t *end) {
    const AVRational milliseconds = {1, 1000};
    *start = time_round(chapter->start, milliseconds);
    *end = time_round(chapter->end, milliseconds);
    if (*start == AV_NOPTS_VALUE || *end == AV_NOPTS_VALUE || *start <= previous_start || *end <= *start)
        return 0;
    if (previous_start < 0)
        *start = 0;
    return *end - *start < INT_MAX;
}

/* Hand the planned chapters to the muxer, or with no output only count those its container cannot hold. */
static int store_chapters(Writer *writer, Chapters *plan, int movie_timescale, int apply, unsigned *unstored) {
    AVFormatContext *output = writer->output;
    int form = chapter_form(output->oformat);
    int64_t previous = -1, previous_end = -1;
    // A MOV chapter sample lasts until the next one starts, and an Opus chapter comment states only a start.
    int abutting = form == CHAPTERS_MOV || !strcmp(output->oformat->name, "opus");
    *unstored = 0;
    plan->moved_start = 0;
    plan->closed_gaps = 0;
    for (size_t i = 0; i < plan->count; i++) {
        Chapter *planned = &plan->items[i];
        AVRational base = {1, 1000000000};
        int64_t start = time_round(planned->start, base);
        int64_t end = time_round(planned->end, base);
        int usable = form != CHAPTERS_NONE && start != AV_NOPTS_VALUE && end != AV_NOPTS_VALUE;
        if (usable && form == CHAPTERS_MOV) {
            /* The muxer copies these numbers onto its movie clock unchanged; the finished
             * track is then relabelled with the millisecond clock they were counted on. */
            base = (AVRational){1, movie_timescale};
            usable = mov_chapter_times(planned, previous, &start, &end);
            if (usable && previous < 0)
                plan->moved_start = time_round(planned->start, (AVRational){1, 1000});
        }
        if (!usable) {
            (*unstored)++;
            continue;
        }
        if (abutting) {
            if (previous_end >= 0 && time_round(planned->start, (AVRational){1, 1000}) > previous_end)
                plan->closed_gaps++;
            previous_end = time_round(planned->end, (AVRational){1, 1000});
        }
        previous = start;
        if (!apply)
            continue;
        AVChapter *chapter = av_mallocz(sizeof(*chapter));
        AVChapter **list = chapter ? av_realloc_array(output->chapters, output->nb_chapters + 1, sizeof(*list)) : NULL;
        if (!list) {
            av_free(chapter);
            return fail(writer, "Cannot allocate output chapters");
        }
        output->chapters = list;
        list[output->nb_chapters++] = chapter;
        chapter->id = planned->id;
        chapter->time_base = base;
        chapter->start = start;
        chapter->end = end;
        chapter->metadata = planned->metadata;
        planned->metadata = NULL;
        // The MOV muxer writes a text sample only for a titled chapter.
        if (form == CHAPTERS_MOV && av_dict_set(&chapter->metadata, "title", "", AV_DICT_DONT_OVERWRITE) < 0)
            return fail(writer, "Cannot allocate output chapters");
    }
    if (apply && form == CHAPTERS_MOV && output->nb_chapters) {
        // The Nero chapter list would repeat the millisecond counts as if they were movie ticks.
        int result = av_opt_set(output->priv_data, "movflags", "+disable_chpl", 0);
        if (result < 0)
            return ff_error(writer, result, "Cannot configure chapters for", writer->output_path);
        writer->mov_chapter_clock = movie_timescale;
    }
    return 0;
}

/* Reads n bits, most significant first, or returns -1 past the end. */
static int64_t vp9_bits(const uint8_t *data, int size, int *position, int n) {
    int64_t value = 0;
    for (int i = 0; i < n; i++, (*position)++) {
        if (*position >= size * 8)
            return -1;
        value = (value << 1) | ((data[*position / 8] >> (7 - *position % 8)) & 1);
    }
    return value;
}

/* The picture format coded in a VP9 keyframe's uncompressed header (VP9 bitstream 6.2, 7.2). */
static enum AVPixelFormat vp9_keyframe_format(const uint8_t *data, int size, int *profile) {
    int at = 0;
    if (vp9_bits(data, size, &at, 2) != 2) /* frame_marker */
        return AV_PIX_FMT_NONE;
    int64_t low = vp9_bits(data, size, &at, 1), high = vp9_bits(data, size, &at, 1);
    if (low < 0 || high < 0)
        return AV_PIX_FMT_NONE;
    *profile = (int)(high << 1 | low);
    if (*profile == 3 && vp9_bits(data, size, &at, 1) != 0)
        return AV_PIX_FMT_NONE;
    /* show_existing_frame and frame_type are zero for a keyframe; then show_frame, error_resilient_mode
     * and the sync code. */
    if (vp9_bits(data, size, &at, 2) != 0 || vp9_bits(data, size, &at, 2) < 0
        || vp9_bits(data, size, &at, 24) != 0x498342)
        return AV_PIX_FMT_NONE;
    int depth = 8;
    if (*profile >= 2) {
        int64_t twelve = vp9_bits(data, size, &at, 1);
        if (twelve < 0)
            return AV_PIX_FMT_NONE;
        depth = twelve ? 12 : 10;
    }
    int64_t space = vp9_bits(data, size, &at, 3);
    if (space < 0)
        return AV_PIX_FMT_NONE;
    int rgb = space == 7, x = 1, y = 1;
    if (!rgb && vp9_bits(data, size, &at, 1) < 0) /* color_range */
        return AV_PIX_FMT_NONE;
    if (*profile == 1 || *profile == 3) {
        int64_t subsampling = rgb ? 0 : vp9_bits(data, size, &at, 2);
        if (subsampling < 0)
            return AV_PIX_FMT_NONE;
        x = (int)(subsampling >> 1);
        y = (int)(subsampling & 1);
    } else if (rgb) {
        return AV_PIX_FMT_NONE; /* RGB is coded in profiles 1 and 3 only. */
    }
    static const enum AVPixelFormat formats[3][5] = {
        {AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUV440P, AV_PIX_FMT_YUV444P, AV_PIX_FMT_GBRP},
        {AV_PIX_FMT_YUV420P10, AV_PIX_FMT_YUV422P10, AV_PIX_FMT_YUV440P10, AV_PIX_FMT_YUV444P10, AV_PIX_FMT_GBRP10},
        {AV_PIX_FMT_YUV420P12, AV_PIX_FMT_YUV422P12, AV_PIX_FMT_YUV440P12, AV_PIX_FMT_YUV444P12, AV_PIX_FMT_GBRP12},
    };
    int layout = rgb ? 4 : x && y ? 0 : x ? 1 : y ? 2 : 3;
    return formats[depth == 8 ? 0 : depth == 10 ? 1 : 2][layout];
}

/* The MOV muxer derives the vpcC box from the pixel format, which a MOV or Matroska source does not
 * report without decoding a picture. Unknown, the box is written empty and FFmpeg cannot open the copy. */
static int fill_vp_format(Writer *writer, const AVFormatContext *input, unsigned index, AVCodecParameters *codec) {
    if (codec->format != AV_PIX_FMT_NONE || (codec->codec_id != AV_CODEC_ID_VP8 && codec->codec_id != AV_CODEC_ID_VP9))
        return 0;
    if (codec->codec_id == AV_CODEC_ID_VP8) {
        codec->format = AV_PIX_FMT_YUV420P; /* VP8 codes 8-bit 4:2:0 only. */
        return 0;
    }
    AVFormatContext *scan = NULL;
    AVPacket *packet = av_packet_alloc();
    int result = packet ? avformat_open_input(&scan, input->url, input->iformat, NULL) : AVERROR(ENOMEM);
    enum AVPixelFormat format = AV_PIX_FMT_NONE;
    int profile = AV_PROFILE_UNKNOWN;
    if (result >= 0 && index < scan->nb_streams) {
        for (unsigned i = 0; i < scan->nb_streams; i++)
            if (i != index)
                scan->streams[i]->discard = AVDISCARD_ALL;
        for (int read = 0; format == AV_PIX_FMT_NONE && read < 4096 && av_read_frame(scan, packet) >= 0; read++) {
            if (packet->stream_index == (int)index && (packet->flags & AV_PKT_FLAG_KEY))
                format = vp9_keyframe_format(packet->data, packet->size, &profile);
            av_packet_unref(packet);
        }
    }
    avformat_close_input(&scan);
    av_packet_free(&packet);
    if (format == AV_PIX_FMT_NONE)
        return fail(writer, "Cannot read the VP9 picture format of track %u in %s", index, input->url);
    codec->format = format;
    if (codec->profile == AV_PROFILE_UNKNOWN)
        codec->profile = profile;
    return 0;
}

/* Describe an HEVC track's first sample entry with the sets the source holds where its first range starts
 * (plan_stream_sets), and add the picture parameter sets that range brings inside a picture group (plan_hevc_sets),
 * so the samples that bring them only repeat sets from the entry. */
static int describe_early_sets(Writer *writer, AVCodecParameters *codec, const uint8_t *stream, int stream_size,
                               const uint8_t *early, int early_size) {
    MPCutHevcSets *sets = mpcut_hevc_sets_create(codec->extradata, codec->extradata_size);
    if (!sets)
        return 0; // check_hvc1 withdraws 'hvc1' from a description it cannot read.
    uint8_t *record = NULL;
    int size = 0;
    int result = stream_size ? mpcut_hevc_sets_apply_sample(sets, stream, stream_size, 4) : 0;
    int added = result < 0 || !early_size ? 0 : mpcut_hevc_sets_apply_sample(sets, early, early_size, 4);
    result = result < 0 ? result : added < 0 ? added : result | added;
    if (result > 0)
        result = mpcut_hevc_sets_record(sets, &record, &size);
    mpcut_hevc_sets_free(sets);
    if (result < 0)
        return ff_error(writer, result, "Cannot describe the HEVC parameter sets of", writer->output_path);
    if (record) {
        av_free(codec->extradata); // The record is allocated with input padding.
        codec->extradata = record;
        codec->extradata_size = size;
    }
    return 0;
}

static int configure_output(Writer *writer, AVFormatContext *input, int whole_file,
                            int timecode_index, const MPCutTimecode *timecode, const char *initial_timecode,
                            const MPCutSegment *segment, Chapters *chapters) {
    AVFormatContext *output = writer->output;
    writer->has_timecode = timecode_index >= 0;
    if (writer->has_timecode) {
        writer->timecode_rate = timecode->rate;
    }
    unsigned output_count = writer->selected_count;
    writer->last_dts = av_calloc(output_count, sizeof(*writer->last_dts));
    if (!writer->last_dts) {
        return fail(writer, "Cannot allocate output track state");
    }
    if (is_mov(output->oformat) && !writer->generated_stills && (!(writer->hvc1 = av_calloc(output_count, 1))
        || !(writer->hevc_sets = av_calloc(output_count, sizeof(*writer->hevc_sets)))))
        return fail(writer, "Cannot allocate output track state");
    writer->hevc_set_count = writer->hevc_sets ? output_count : 0;

    int result = av_dict_copy(&output->metadata, input->metadata, 0);
    if (result < 0) {
        return ff_error(writer, result, "Cannot copy movie metadata from", input->url);
    }
    if (writer->has_timecode) {
        av_dict_set(&output->metadata, "timecode", NULL, 0);
    }
    for (unsigned index = 0; index < input->nb_streams; index++) {
        if (writer->stream_map[index] < 0) {
            continue;
        }
        AVStream *source = input->streams[index];
        AVStream *destination = avformat_new_stream(output, NULL);
        if (!destination) {
            return fail(writer, "Cannot allocate output track %u", index);
        }
        result = avcodec_parameters_copy(destination->codecpar, source->codecpar);
        if (result < 0) {
            return ff_error(writer, result, "Cannot copy stream configuration from", input->url);
        }
        if (is_mov(output->oformat) && (result = fill_vp_format(writer, input, index, destination->codecpar)))
            return result;
        if (writer->avc_reorder > 0 && primary_video(source) && source->codecpar->codec_id == AV_CODEC_ID_H264) {
            uint8_t *config = NULL;
            int size = 0;
            result = mpcut_avcc_declare_reorder(destination->codecpar->extradata, destination->codecpar->extradata_size,
                                                writer->avc_reorder, &config, &size);
            if (result < 0)
                return ff_error(writer, result, "Cannot declare the picture reorder depth for", input->url);
            if (result) {
                av_free(destination->codecpar->extradata);
                destination->codecpar->extradata = config;
                destination->codecpar->extradata_size = size;
            }
        }
        if (writer->generated_stills && destination->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            result = set_still_hdr(writer, destination->codecpar);
            if (result)
                return result;
        }
        // The MP4 muxer writes the Dolby Vision configuration box, and the sv3d and vexu boxes of 360° video,
        // only at this compliance level. Without it, the pictures survive but the muxer quietly drops the
        // display configuration or the projection.
        if (strcmp(output->oformat->name, "mp4") == 0 &&
            (av_packet_side_data_get(source->codecpar->coded_side_data, source->codecpar->nb_coded_side_data,
                                     AV_PKT_DATA_DOVI_CONF) ||
             av_packet_side_data_get(source->codecpar->coded_side_data, source->codecpar->nb_coded_side_data,
                                     AV_PKT_DATA_SPHERICAL)))
            output->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
        if (index < segment->opus_track_count && segment->opus_pre_skip[index] >= 0 && is_matroska(output->oformat)) {
            AVCodecParameters *codec = destination->codecpar;
            int skip = segment->opus_pre_skip[index];
            if (codec->codec_id != AV_CODEC_ID_OPUS || skip > UINT16_MAX
                || codec->extradata_size < 19 || memcmp(codec->extradata, "OpusHead", 8) != 0) {
                return fail(writer, "Invalid Opus trim header on track %u", index);
            }
            codec->initial_padding = skip;
            AV_WL16(codec->extradata + 10, skip);
        }
        if (!whole_file && destination->codecpar->codec_id == AV_CODEC_ID_FLAC)
            mpcut_normalize_flac_streaminfo(destination->codecpar->extradata,
                                            destination->codecpar->extradata_size);
        /* MOV sample entries carry semantics such as ProRes profile and HEVC parameter-set placement. */
        // A carried data track is known by its sample entry name alone (carried_extra).
        if ((!is_mov(output->oformat) || !output->oformat->codec_tag
             || av_codec_get_id(output->oformat->codec_tag, source->codecpar->codec_tag) != source->codecpar->codec_id)
            && !(source->codecpar->codec_type == AVMEDIA_TYPE_DATA && extra_track(source))) {
            destination->codecpar->codec_tag = 0;
        }
        if (writer->smart_trim && is_mov(output->oformat)) {
            if (source->codecpar->codec_id == AV_CODEC_ID_H264)
                destination->codecpar->codec_tag = MKTAG('a', 'v', 'c', '1');
            else if (source->codecpar->codec_id == AV_CODEC_ID_HEVC)
                destination->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
        }
        plan_hvc1(writer, destination);
        int early = writer->hevc_early_count && writer->hevc_early_size[0] > 0 && (int)index == writer->hevc_videos[0];
        int stream = writer->stream_set_count && writer->stream_sets_size[0] > 0 && primary_video(source);
        if ((early || stream) && writer->hvc1 && writer->hvc1[destination->index] == HEVC_ENTRY_HVC1
            && (result = describe_early_sets(writer, destination->codecpar,
                                             stream ? writer->stream_sets[0] : NULL, stream ? writer->stream_sets_size[0] : 0,
                                             early ? writer->hevc_early[0] : NULL, early ? writer->hevc_early_size[0] : 0)))
            return result;
        destination->id = destination->index + 1;
        destination->time_base = source->time_base;
        destination->avg_frame_rate = source->avg_frame_rate;
        destination->r_frame_rate = source->r_frame_rate;
        if (source->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            // MOV can provide the pixel aspect ratio on the stream at open. The
            // muxer writes the exact pasp box from the codec parameters.
            AVRational sar = av_guess_sample_aspect_ratio(input, source, NULL);
            destination->sample_aspect_ratio = destination->codecpar->sample_aspect_ratio = sar;
        }
        destination->disposition = source->disposition;
        // FFmpeg's hvcC writer keeps the sets of a higher layer only when it reads them from Annex B, so the sets of
        // the alpha layer that Apple's HEVC with alpha holds in hvcC would be dropped and AVFoundation could not read
        // the copy at all. A track marked multilayer gets them in an lhvC box, as an MV-HEVC view's come, which
        // AVFoundation reads for alpha too (with the alpha mode the stream's own alpha information gives).
        if (is_mov(output->oformat) && destination->codecpar->codec_id == AV_CODEC_ID_HEVC
            && mpcut_hevc_layers(destination->codecpar->extradata, destination->codecpar->extradata_size))
            destination->disposition |= AV_DISPOSITION_MULTILAYER;
        // The MP4 muxer writes the video extension (vexu) and field of view (hfov) boxes of stereo video, which say
        // which view is which eye, the camera baseline and the disparity adjustment, only at this compliance level,
        // as it does the Dolby Vision box. MOV always gets them.
        if (strcmp(output->oformat->name, "mp4") == 0
            && av_packet_side_data_get(source->codecpar->coded_side_data, source->codecpar->nb_coded_side_data,
                                       AV_PKT_DATA_STEREO3D))
            output->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;

        result = av_dict_copy(&destination->metadata, source->metadata, 0);
        if (result >= 0)
            result = drop_statistics_tags(&destination->metadata);
        // The MP3 muxer copies this tag into Xing's encoder ID. Use its own ID
        // for rewritten gapless headers so readers recognize the delay fields.
        if (result >= 0 && !strcmp(output->oformat->name, "mp3"))
            result = av_dict_set(&destination->metadata, "encoder", NULL, 0);
        if (result < 0) {
            return ff_error(writer, result, "Cannot copy track metadata from", input->url);
        }
        if (whole_file && !strcmp(output->oformat->name, "mp3") && source->codecpar->codec_id == AV_CODEC_ID_MP3) {
            result = configure_whole_mp3(writer, input, source);
            if (result) return result;
        }
        if (writer->has_timecode && source->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            destination->avg_frame_rate = timecode->rate;
            result = av_dict_set(&destination->metadata, "timecode", initial_timecode, 0);
            if (result < 0) {
                return ff_error(writer, result, "Cannot set output timecode from", input->url);
            }
            const AVDictionaryEntry *reel = av_dict_get(input->streams[timecode_index]->metadata, "reel_name", NULL, 0);
            if (reel) {
                result = av_dict_set(&destination->metadata, "reel_name", reel->value, 0);
                if (result < 0) {
                    return ff_error(writer, result, "Cannot copy reel name from", input->url);
                }
            }
        } else if (writer->has_timecode) {
            av_dict_set(&destination->metadata, "timecode", NULL, 0);
        }
        writer->last_dts[destination->index] = AV_NOPTS_VALUE;
    }

    if (is_mov(output->oformat)) {
        /* Preserve sub-millisecond edits and allow leading decode timestamps. */
        int output_movie_timescale = movie_timescale;
        if (writer->generated_stills && output_count == 1) {
            const AVRational base = output->streams[0]->time_base;
            // Generated-still picture lanes plan every boundary on this clock.
            // A different movie clock can round the track header and edit list
            // even when the video sample table describes the exact duration.
            if (base.num == 1 && base.den > 0 && movie_timescale % base.den != 0)
                output_movie_timescale = base.den;
        }
        // A muxer without one of these options would round the edit, drop the edit lists, renumber the tracks or
        // leave out the colour box. Stop rather than write that copy.
        if ((result = av_opt_set_int(output->priv_data, "movie_timescale", output_movie_timescale, 0)) < 0
            || (result = av_opt_set_int(output->priv_data, "use_editlist", 1, 0)) < 0
            || (result = av_opt_set_int(output->priv_data, "use_stream_ids_as_track_ids", 1, 0)) < 0)
            return ff_error(writer, result, "Cannot configure the movie clock and track IDs for", input->url);
        for (unsigned index = 0; index < output->nb_streams; index++) {
            const AVCodecParameters *codec = output->streams[index]->codecpar;
            if (codec->codec_type == AVMEDIA_TYPE_VIDEO
                && (codec->color_primaries != AVCOL_PRI_UNSPECIFIED
                    || codec->color_trc != AVCOL_TRC_UNSPECIFIED
                    || codec->color_space != AVCOL_SPC_UNSPECIFIED
                    || codec->color_range != AVCOL_RANGE_UNSPECIFIED)) {
                if ((result = av_opt_set(output->priv_data, "movflags", "+write_colr+prefer_icc", 0)) < 0)
                    return ff_error(writer, result, "Cannot configure the colour description for", input->url);
                break;
            }
        }
        result = av_opt_set_int(output->priv_data, "write_tmcd", writer->has_timecode, 0);
        if (writer->has_timecode) {
            if (result >= 0) {
                result = av_opt_set_int(output->priv_data, "video_track_timescale", timecode->output_timescale, 0);
            }
            if (result < 0) {
                return ff_error(writer, result, "Cannot configure output timecode for", input->url);
            }
        }
        output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
        if (!whole_file || writer->aac_source) {
            for (unsigned index = 0; index < input->nb_streams; index++) {
                if (writer->stream_map[index] >= 0 && input->streams[index]->codecpar->codec_id == AV_CODEC_ID_AAC) {
                    writer->aac_edits = mpcut_aac_create(output_count, movie_timescale);
                    if (!writer->aac_edits) {
                        return fail(writer, "Cannot allocate AAC edit state");
                    }
                    break;
                }
            }
        }
    }
    if (strcmp(output->oformat->name, "matroska") == 0) {
        output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    }

    if (!strcmp(output->oformat->name, "wav")) {
        result = av_opt_set(output->priv_data, "rf64", "auto", 0);
        if (result < 0)
            return ff_error(writer, result, "Cannot enable large WAV files for", writer->output_path);
    }
    if (writer->delivered) {
        // Cover art follows the copied tracks, so their output indices do not move.
        unsigned unstored;
        result = add_art(writer, input);
        if (!result)
            result = store_chapters(writer, chapters, movie_timescale, 1, &unstored);
        if (result)
            return result;
    }
    result = avio_open(&output->pb, writer->output_path, AVIO_FLAG_WRITE);
    if (result < 0) {
        return ff_error(writer, result, "Cannot create", writer->output_path);
    }
    result = avformat_write_header(output, NULL);
    if (result < 0) {
        return ff_error(writer, result, "Cannot write movie header to", writer->output_path);
    }
    return write_art(writer, input);
}

static int video_origin(Writer *writer, AVFormatContext **input, unsigned *video_index,
                        MPCutTime indexed_origin, MPCutTime *origin) {
    AVFormatContext *source = *input;
    unsigned index = 0;
    while (index < source->nb_streams && !primary_video(source->streams[index]))
        index++;
    if (index == source->nb_streams && writer->tracks == MPCUT_TRACKS_AUDIO) {
        for (index = 0; index < source->nb_streams; index++)
            if (selected_stream(writer, source->streams[index]))
                break;
    }
    if (index == source->nb_streams)
        return fail(writer, "No primary timeline stream in %s", source->url);

    *video_index = index;
    if (indexed_origin.denominator > 0) {
        *origin = indexed_origin;
        return 0;
    }

    const AVStream *video = source->streams[index];
    AVRational base = video->time_base;
    int64_t first = video->start_time;
    if (first == AV_NOPTS_VALUE) {
        int code;
        while ((code = av_read_frame(source, writer->packet)) >= 0) {
            const AVPacket *packet = writer->packet;
            if ((unsigned)packet->stream_index == index && packet->pts != AV_NOPTS_VALUE
                && (first == AV_NOPTS_VALUE || packet->pts < first)) {
                first = packet->pts;
            }
            av_packet_unref(writer->packet);
            int cancelled = progress_at(writer, writer->fraction);
            if (cancelled) {
                return cancelled;
            }
        }
        if (code != AVERROR_EOF) {
            return ff_error(writer, code, "Cannot read video origin from", source->url);
        }
        if (first == AV_NOPTS_VALUE) {
            return fail(writer, "Video track in %s has no presentation origin", source->url);
        }
        char *path = av_strdup(source->url);
        if (!path) {
            return fail(writer, "Cannot allocate input path");
        }
        avformat_close_input(input);
        int result = input_open(writer, input, path);
        av_free(path);
        if (result) {
            return result;
        }
    }
    *origin = time_ticks(first, base);
    return origin->denominator ? 0 : fail(writer, "Video origin cannot be represented");
}

/* MOV edit lists trim negative presentation time. A whole-file copy whose
 * linked audio leads the video therefore starts its video after zero. The
 * plan supplies that lead: stream start times are not available for every
 * source here, and the written file must match the reported plan. */
static MPCutTime mov_audio_lead(const MPCutSegment *segment) {
    MPCutTime lead = segment->output_start;
    return lead.denominator > 0 && lead.numerator > 0 ? lead : (MPCutTime){0, 1};
}

static int valid_segment_range(const MPCutSegment *segment) {
    return segment->path && segment->start.denominator > 0 && segment->end.denominator > 0
        && segment->start.numerator >= 0 && time_compare(segment->end, segment->start) > 0;
}

static int check_timecode_range(Writer *writer, const AVFormatContext *input, int timecode_index,
                                const MPCutTimecode *timecode, size_t index, MPCutTime duration,
                                MPCutTime start, MPCutTime output_start, MPCutTime total,
                                char value[AV_TIMECODE_STR_SIZE]) {
    if (index && writer->has_timecode && av_cmp_q(timecode->rate, writer->timecode_rate)) {
        return fail(writer, "Timecode rate changed in %s", input->url);
    }
    Wide frame_count = (Wide)duration.numerator * timecode->rate.num;
    Wide frame_denominator = (Wide)duration.denominator * timecode->rate.den;
    if (frame_count <= 0 || frame_denominator <= 0 || frame_count % frame_denominator) {
        return fail(writer, "Segment %zu does not cover a whole number of timecode frames", index + 1);
    }
    if (index != 0) {
        return 0;
    }
    if (!output_start.denominator || output_start.numerator != 0) {
        return fail(writer, "MOV timecode cannot cover the full video track when it starts after linked audio in %s",
                    input->url);
    }

    int code = mpcut_timecode_read(input, timecode_index, timecode, start, total,
                                   writer->progress, writer->progress_context, writer->fraction, value);
    if (code == AVERROR_EXIT) {
        fail(writer, "Export cancelled");
        return 2;
    }
    return code < 0 ? ff_error(writer, code, "Cannot preserve timecode at the selected start of", input->url) : 0;
}

static int check_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration, int tracks,
                          const char *output_path, size_t *failed_segment,
                          MPCutProgress progress, void *context, char *error, size_t error_capacity) {
    Writer writer = {.output_path = output_path, .progress = progress, .progress_context = context,
                     .error = error, .error_capacity = error_capacity, .tracks = track_selection(tracks)};
    set_delivery(&writer, tracks, -1);
    if (failed_segment)
        *failed_segment = 0;
    if (!segments || !count || !output_path)
        return fail(&writer, "An output path and at least one segment are required");
    if (duration.numerator <= 0 || duration.denominator <= 0)
        return fail(&writer, "A positive duration is required for timecode");
    AVFormatContext *input = NULL;
    int result = prepare_output(&writer);
    if (result) {
        goto cleanup;
    }
    writer.packet = av_packet_alloc();
    if (!writer.packet) {
        result = fail(&writer, "Cannot allocate working packet");
        goto cleanup;
    }
    for (size_t index = 0; index < count; index++) {
        if (failed_segment) {
            *failed_segment = index + 1;
        }
        result = progress_at(&writer, 0);
        if (result) {
            break;
        }
        const MPCutSegment *segment = &segments[index];
        if (!valid_segment_range(segment)) {
            result = fail(&writer, "Segment %zu has an invalid range", index + 1);
            break;
        }
        int timecode_index;
        MPCutTimecode timecode;
        result = input_open(&writer, &input, segment->path);
        if (!result) {
            result = validate_streams(&writer, input, &timecode_index, &timecode);
        }
        if (result) {
            break;
        }
        if (timecode_index < 0) {
            result = fail(&writer, "No supported timecode track in %s", input->url);
            break;
        }
        MPCutTime source_start = {0, 1};
        MPCutTime output_start = {0, 1};
        if (index == 0) {
            unsigned video_index;
            MPCutTime origin;
            result = video_origin(&writer, &input, &video_index, segment->source_origin, &origin);
            if (result) {
                break;
            }
            source_start = time_add(origin, segment->start, 1);
            if (!source_start.denominator) {
                result = fail(&writer, "Segment %zu timestamp cannot be represented", index + 1);
                break;
            }
            if (count == 1 && segment->start.numerator == 0 && segment->reaches_end && is_mov(writer.output->oformat)) {
                output_start = mov_audio_lead(segment);
            }
        }
        char value[AV_TIMECODE_STR_SIZE];
        result = check_timecode_range(&writer, input, timecode_index, &timecode, index,
                                      time_add(segment->end, segment->start, -1),
                                      source_start, output_start, duration, value);
        if (result) {
            break;
        }
        writer.has_timecode = 1;
        writer.timecode_rate = timecode.rate;
        avformat_close_input(&input);
    }

cleanup:
    if (!result && failed_segment)
        *failed_segment = 0;
    avformat_close_input(&input);
    av_packet_free(&writer.packet);
    avformat_free_context(writer.output);
    return result;
}

int mpcut_check_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                         const char *output_path, size_t *failed_segment,
                         MPCutProgress progress, void *context, char *error, size_t error_capacity) {
    return check_timecode(segments, count, duration, MPCUT_TRACKS_ALL, output_path, failed_segment,
                          progress, context, error, error_capacity);
}

int mpcut_check_video_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                               const char *output_path, size_t *failed_segment,
                               MPCutProgress progress, void *context, char *error, size_t error_capacity) {
    return check_timecode(segments, count, duration, MPCUT_TRACKS_DELIVERED_VIDEO_TIMECODE, output_path, failed_segment,
                          progress, context, error, error_capacity);
}

static int pcm_frame_size(const AVCodecParameters *codec) {
    const char *name = avcodec_get_name(codec->codec_id);
    int bits = av_get_exact_bits_per_sample(codec->codec_id);
    int channels = codec->ch_layout.nb_channels;
    if (codec->codec_type != AVMEDIA_TYPE_AUDIO || strncmp(name, "pcm_", 4) || strstr(name, "planar")
        || bits <= 0 || bits % 8 || channels <= 0 || channels > INT_MAX / (bits / 8)
        || codec->sample_rate <= 0) {
        return 0;
    }
    return channels * (bits / 8);
}

/* Samples one AC-3 or E-AC-3 packet decodes to: 1536 for an AC-3 frame, or 256 for each audio
 * block of the independent E-AC-3 frames of the first program. 0 when it is not understood. */
static int64_t dolby_packet_samples(const uint8_t *data, int size) {
    static const int blocks_for_code[] = {1, 2, 3, 6};
    int64_t samples = 0;
    while (size >= 6 && data[0] == 0x0b && data[1] == 0x77) {
        int bsid = data[5] >> 3;
        if (bsid <= 10)
            return samples + 1536;
        if (bsid > 16)
            return 0;
        int bytes = (((data[2] & 7) << 8 | data[3]) + 1) * 2;
        int blocks = data[4] >> 6 == 3 ? 6 : blocks_for_code[(data[4] >> 4) & 3];
        if ((data[2] >> 6) != 1 && !((data[2] >> 3) & 7))
            samples += 256 * blocks;
        if (bytes > size)
            return 0;
        data += bytes;
        size -= bytes;
    }
    return size ? 0 : samples;
}

/* The demuxer marks the encoder padding after the last audible AC-3 or E-AC-3 sample on the final
 * packet. The MOV muxer honours that mark only for a stream that states its frame size, so the copy
 * would play the padding. End this sample, and with it the track's edit, at the last audible sample. */
static int trim_dolby_tail(Writer *writer, const AVStream *input_track, int64_t mapped_pts, int64_t *mapped_end) {
    const AVPacket *packet = writer->packet;
    size_t size = 0;
    const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &size);
    uint32_t discard = side && size >= 10 ? AV_RL32(side + 4) : 0;
    if (!discard)
        return 0;
    const AVStream *track = writer->output->streams[packet->stream_index];
    AVRational samples = {1, input_track->codecpar->sample_rate};
    if (samples.den <= 0)
        return 0;
    // A frame this does not read is measured by the packet's own length, so its padding is still cut.
    int64_t coded = dolby_packet_samples(packet->data, packet->size);
    int64_t full = coded > 0 ? av_rescale_q(coded, samples, track->time_base) : 0;
    // A Matroska block can already be shortened to its audible part, on a millisecond clock.
    if (*mapped_end - mapped_pts > full)
        full = *mapped_end - mapped_pts;
    if (full <= 0)
        return fail(writer, "The final Dolby audio packet on track %d has no length to end its audible samples",
                    packet->stream_index);
    int64_t audible = full - av_rescale_q(discard, samples, track->time_base);
    if (audible <= 0)
        return fail(writer, "The final Dolby audio packet on track %d has no audible samples", packet->stream_index);
    *mapped_end = mapped_pts + audible;
    return 0;
}

static int remux_packet(Writer *writer, const AVStream *input_track, const Range *range, int video,
                        int mov_video_timing) {
    AVPacket *packet = writer->packet;
    AVStream *track = writer->output->streams[packet->stream_index];
    const char *track_type = video ? "video" : "audio";
    MPCutTime pts = time_ticks(packet->pts, input_track->time_base);
    if (!pts.denominator) {
        return fail(writer, "Missing presentation timestamp on %s track %d", track_type, packet->stream_index);
    }

    if (!range->whole_file && (video || (!range->keep_audio_start || !range->keep_audio_end))) {
        int before = time_compare(pts, range->source_start) < 0;
        int after = time_compare(pts, range->source_end) >= 0;
        if ((before && (video || !range->keep_audio_start)) || (after && (video || !range->keep_audio_end))) {
            packet->size = 0;
            return 0;
        }
    }

    MPCutTime duration = time_ticks(packet->duration, input_track->time_base);
    MPCutTime packet_end = time_add(pts, duration, 1);
    /* MOV sample duration describes decode cadence. For reordered VFR it
     * may extend beyond the presentation end when added to this packet's PTS.
     * MOV and Matroska muxers use PTS + duration for presentation extent.
     * MOV derives intermediate decode durations from consecutive DTS values. */
    int last_picture = range->last_video_frame.denominator && time_compare(pts, range->last_video_frame) == 0;
    if (mov_video_timing && packet_end.denominator && time_compare(pts, range->source_end) < 0
        && (last_picture || time_compare(packet_end, range->source_end) > 0)) {
        packet_end = range->source_end;
    }
    if (video && range->matroska_input && last_picture && packet_end.denominator) {
        int64_t end_tick = time_round(range->source_end, input_track->time_base);
        Wide difference = (Wide)end_tick - packet->pts - packet->duration;
        if (end_tick != AV_NOPTS_VALUE && difference >= -1 && difference <= 1)
            packet_end = range->source_end; // Matroska's default frame duration can round off one tick.
    }
    if (!range->whole_file) {
        if (packet->duration <= 0 || !packet_end.denominator) {
            return fail(writer, "Missing duration on %s track %d", track_type, packet->stream_index);
        }
        if ((video || !range->keep_audio_end) && time_compare(packet_end, range->source_end) > 0) {
            return fail(writer, "Requested end crosses a packet on %s track %d", track_type, packet->stream_index);
        }
        if (!video) {
            size_t size = 0;
            const uint8_t *skip = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &size);
            if (skip && size >= 8
                && ((!range->keep_audio_start && AV_RL32(skip)) || (!range->keep_audio_end && AV_RL32(skip + 4)))) {
                return fail(writer, "Track %d has compressed audio priming or padding at a splice", packet->stream_index);
            }
        }
    }

    MPCutTime dts = time_ticks(packet->dts, input_track->time_base);
    if (range->shift.numerator) {
        pts = time_add(pts, range->shift, 1);
        dts = time_add(dts, range->shift, 1);
        packet_end = time_add(packet_end, range->shift, 1);
    }
    int64_t mapped_pts = time_round(pts, track->time_base);
    int64_t mapped_dts = time_round(dts, track->time_base);
    if (video && writer->video_dts) {
        if (writer->video_dts_used >= writer->video_dts_count)
            return fail(writer, "More video samples than indexed in the Smart Trim edit");
        mapped_dts = time_round(writer->video_dts[writer->video_dts_used++], track->time_base);
        if (mapped_dts == AV_NOPTS_VALUE || mapped_dts > mapped_pts)
            return fail(writer, "Cannot represent a Smart Trim decode slot on the output clock");
    }
    int64_t mapped_end = time_round(packet_end, track->time_base);
    if (!video && is_mov(writer->output->oformat) && mapped_end != AV_NOPTS_VALUE && mapped_pts != AV_NOPTS_VALUE
        && (input_track->codecpar->codec_id == AV_CODEC_ID_AC3 || input_track->codecpar->codec_id == AV_CODEC_ID_EAC3)) {
        int result = trim_dolby_tail(writer, input_track, mapped_pts, &mapped_end);
        if (result)
            return result;
    }
    if (mapped_pts == AV_NOPTS_VALUE || (packet->dts != AV_NOPTS_VALUE && mapped_dts == AV_NOPTS_VALUE)
        || (packet->duration > 0 && (mapped_end == AV_NOPTS_VALUE || mapped_end <= mapped_pts
                                    || (Wide)mapped_end - mapped_pts > INT64_MAX))) {
        return fail(writer, "Output clock cannot represent a %s packet on track %d", track_type, packet->stream_index);
    }
    enum AVCodecID codec = input_track->codecpar->codec_id;
    if (video && !writer->video_dts && packet->dts == AV_NOPTS_VALUE && strcmp(writer->output->oformat->name, "matroska") == 0
        && (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC)) {
        /* Matroska stores presentation timestamps. Supply ordering for the leading
           reordered packets whose decode timestamps its demuxer cannot recover. */
        int64_t previous = writer->last_dts[packet->stream_index];
        Wide fallback = previous == AV_NOPTS_VALUE
            ? (Wide)mapped_pts - 32 * (packet->duration > 0 ? (Wide)mapped_end - mapped_pts : 1)
            : (Wide)previous + 1;
        if (fallback <= INT64_MIN || fallback > mapped_pts) {
            return fail(writer, "Cannot recover decode order on video track %d", packet->stream_index);
        }
        mapped_dts = (int64_t)fallback;
    }
    packet->pts = mapped_pts;
    packet->dts = mapped_dts;
    packet->duration = packet->duration > 0 ? mapped_end - mapped_pts : 0;
    return 0;
}

/* Place a subtitle cue or a data sample of an extra track (extra_track) on the output timeline.
 * A cue that runs across a cut is shortened to the kept range; its text is not touched. A data sample
 * spreads its readings over its own duration, so it is kept only when it lies wholly inside the range.
 * A packet with no duration is kept when it starts inside the range. */
static int remux_extra(Writer *writer, const AVStream *input_track, const Range *range) {
    AVPacket *packet = writer->packet;
    AVStream *track = writer->output->streams[packet->stream_index];
    MPCutTime start = time_ticks(packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts, input_track->time_base);
    if (!start.denominator)
        return fail(writer, "Missing timestamp on track %d", packet->stream_index);
    int timed = packet->duration > 0;
    MPCutTime end = timed ? time_add(start, time_ticks(packet->duration, input_track->time_base), 1) : start;
    if (!end.denominator)
        return fail(writer, "Output clock cannot represent a packet on track %d", packet->stream_index);
    if (!range->whole_file) {
        int subtitle = input_track->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE;
        int keep = !timed ? time_compare(start, range->source_start) >= 0 && time_compare(start, range->source_end) < 0
            : subtitle ? time_compare(end, range->source_start) > 0 && time_compare(start, range->source_end) < 0
            : time_compare(start, range->source_start) >= 0 && time_compare(end, range->source_end) <= 0;
        if (!keep) {
            packet->size = 0;
            return 0;
        }
        if (time_compare(start, range->source_start) < 0)
            start = range->source_start;
        if (time_compare(end, range->source_end) > 0)
            end = range->source_end;
    }
    int64_t mapped = time_round(time_add(start, range->shift, 1), track->time_base);
    int64_t mapped_end = time_round(time_add(end, range->shift, 1), track->time_base);
    if (mapped == AV_NOPTS_VALUE || mapped_end == AV_NOPTS_VALUE || mapped_end < mapped)
        return fail(writer, "Output clock cannot represent a packet on track %d", packet->stream_index);
    if (timed && mapped_end == mapped) {
        packet->size = 0; // What is left of the cue is shorter than one tick of the output clock.
        return 0;
    }
    packet->pts = packet->dts = mapped;
    packet->duration = timed ? mapped_end - mapped : 0;
    return 0;
}

/* Muxers store a cue among the other tracks' packets near its start time; FFmpeg's default
 * interleaving window is 10 seconds. Once the picture and sound have passed the range, a sparse
 * track whose next cue lies far beyond it would otherwise be read to the end of the file.
 * Returns how many tracks this finishes. */
static unsigned finish_extras(Writer *writer, const AVFormatContext *input, const Range *range, MPCutTime read) {
    MPCutTime limit = time_add(range->source_end, (MPCutTime){10, 1}, 1);
    if (!read.denominator || !limit.denominator || time_compare(read, limit) < 0)
        return 0;
    unsigned open = 0;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        if (writer->stream_map[i] < 0 || writer->range_tracks[i])
            continue;
        if (!extra_track(input->streams[i]))
            return 0;
        open++;
    }
    for (unsigned i = 0; open && i < input->nb_streams; i++)
        if (writer->stream_map[i] >= 0 && !writer->range_tracks[i])
            writer->range_tracks[i] = 1;
    return open;
}

/* Count samples on the original decoder clock. OpusHead hides the retained
 * decoder preroll and DiscardPadding trims the final block. */
static int trim_opus_packet(Writer *writer, const AVStream *stream, const Range *range, OpusTrim *state) {
    AVPacket *packet = writer->packet;
    if (state->finished) {
        packet->size = 0;
        return 0;
    }

    const AVRational sample_base = {1, 48000};
    const AVCodecParameters *codec = stream->codecpar;
    int64_t pts = time_round(time_ticks(packet->pts, stream->time_base), sample_base);
    int64_t end = time_round(range->source_end, sample_base);
    int duration = mpcut_opus_samples(packet->data, packet->size);
    size_t side_size;
    uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &side_size);
    unsigned skip = side && side_size >= 10 ? AV_RL32(side) : 0;
    unsigned discard = side && side_size >= 10 ? AV_RL32(side + 4) : 0;
    // Ogg granule positions use the Opus sample clock. Matroska block timestamps
    // round each sample position to its nearest millisecond.
    int sample_clock = stream->time_base.num == 1 && stream->time_base.den == 48000;
    int tolerance = sample_clock ? 0 : 24;
    if (pts == AV_NOPTS_VALUE || end == AV_NOPTS_VALUE || packet->dts != packet->pts
        || (!sample_clock && (stream->time_base.num != 1 || stream->time_base.den != 1000)) || codec->sample_rate != 48000
        || codec->initial_padding < 0 || duration <= 0 || discard >= (unsigned)duration
        || skip != (state->started ? 0 : (unsigned)codec->initial_padding)
        || (!state->started && discard)) {
        return fail(writer, "Opus track %d has invalid packet timing at the trim", packet->stream_index);
    }

    Wide first = state->started ? state->next_sample :
        (sample_clock ? (Wide)pts : (Wide)pts + ((skip + 24) / 48) * 48 - skip);
    Wide last = first + duration;
    if ((Wide)pts - first < -tolerance || (Wide)pts - first > tolerance || last > INT64_MAX
        || (!range->keep_audio_end && (end <= first + skip || (discard && end > last - discard)))) {
        return fail(writer, "Opus track %d has discontinuous audio at the trim", packet->stream_index);
    }

    state->started = 1;
    state->next_sample = (int64_t)last;
    AVStream *output = writer->output->streams[packet->stream_index];
    if (!range->keep_audio_start) {
        int64_t cut = time_round(range->source_start, sample_base);
        int padding = output->codecpar->initial_padding;
        Wide first_retained = (Wide)cut - padding;
        if (first < first_retained) {
            packet->size = 0;
            return 0;
        }
        if (!state->copied && first != first_retained) {
            return fail(writer, "Opus track %d could not locate its decoder preroll", packet->stream_index);
        }
        // Matroska adds CodecDelay (rounded to its millisecond clock) to packet PTS.
        // Timestamp retained packets from the first block, avoiding double rounding.
        int64_t relative = (int64_t)(first - first_retained);
        int64_t ticks = av_rescale_q(relative, sample_base, output->time_base)
                      - av_rescale_q(padding, sample_base, output->time_base);
        packet->pts = packet->dts = ticks;
        if (sample_clock)
            packet->duration = av_rescale_q(duration, sample_base, output->time_base);
    }
    if (!range->keep_audio_end && end <= last - discard) {
        discard = (unsigned)(last - end);
        if (skip && discard) {
            return fail(writer, "Opus track %d needs trim padding at both ends of one packet", packet->stream_index);
        }
        if (discard) {
            if (!side || side_size < 10) {
                side = av_packet_new_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, 10);
                if (!side) {
                    return fail(writer, "Cannot allocate Opus trim padding");
                }
                memset(side, 0, 10);
            }
            AV_WL32(side + 4, discard);
        }
        state->finished = 1;
    }
    state->copied = 1;
    if (!range->keep_audio_start) {
        return 0;
    }
    Range packet_range = *range;
    packet_range.whole_file = 1;
    return remux_packet(writer, stream, &packet_range, 0, 0);
}

/* Matroska rounds each Opus block to its millisecond clock, so a copied
 * timestamp can sit up to half a millisecond (24 samples) off its sample, and
 * the final block's duration is rounded too. Ogg derives every granule position
 * from a packet's timestamp, its duration and the pre-skip, so the rounded
 * clock moved the start and end of a copied stream and changed how many
 * samples it decodes. Count the packets on the sample clock instead: the first
 * audible sample sits on the source's millisecond, as in trim_opus_packet, each
 * packet follows the previous one, and the final duration leaves out the
 * block's discard padding. A jump of more than a millisecond is a real gap in
 * the source, and the count restarts from that block's timestamp.
 * Call before remux_packet; *exact receives the source sample, or INT64_MIN. */
static int opus_sample_clock(Writer *writer, const AVStream *stream, OpusTrim *state, int64_t *exact) {
    AVPacket *packet = writer->packet;
    const AVRational sample_base = {1, 48000};
    *exact = INT64_MIN;
    int duration = mpcut_opus_samples(packet->data, packet->size);
    int64_t pts = time_round(time_ticks(packet->pts, stream->time_base), sample_base);
    if (stream->time_base.num != 1 || stream->time_base.den != 1000 || stream->codecpar->sample_rate != 48000
        || stream->codecpar->initial_padding < 0 || pts == AV_NOPTS_VALUE || duration <= 0)
        return 0; // A sample clock or an unreadable packet keeps the muxer's own timing.
    Wide first = (Wide)pts;
    if (!state->started) {
        int skip = stream->codecpar->initial_padding;
        first += ((Wide)(skip + 24) / 48) * 48 - skip;
    } else if ((Wide)pts - state->next_sample >= -48 && (Wide)pts - state->next_sample <= 48) {
        first = state->next_sample;
    }
    if (first + duration > INT64_MAX || first <= INT64_MIN)
        return fail(writer, "Opus track %d has timestamps out of range", packet->stream_index);
    state->started = 1;
    state->next_sample = (int64_t)(first + duration);
    *exact = (int64_t)first;
    return 0;
}

/* Apply opus_sample_clock's count to the remuxed packet on the Ogg sample clock. */
static int place_opus_samples(Writer *writer, const Range *range, int64_t exact) {
    AVPacket *packet = writer->packet;
    const AVStream *track = writer->output->streams[packet->stream_index];
    if (exact == INT64_MIN || packet->size <= 0 || track->time_base.num != 1 || track->time_base.den != 48000)
        return 0;
    int duration = mpcut_opus_samples(packet->data, packet->size);
    size_t size = 0;
    const uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &size);
    unsigned discard = side && size >= 10 ? AV_RL32(side + 4) : 0;
    MPCutTime start = time_add(time_ticks(exact, track->time_base), range->shift, 1);
    int64_t pts = time_round(start, track->time_base);
    if (duration <= 0 || discard >= (unsigned)duration || pts == AV_NOPTS_VALUE)
        return fail(writer, "Opus track %d cannot be placed on the Ogg sample clock", packet->stream_index);
    packet->pts = packet->dts = pts;
    packet->duration = duration - (int)discard; // Ogg ends the stream at the last audible sample.
    return 0;
}

/* Find `nal` among the hvcC parameter-set arrays. Returns -1 for a malformed
 * configuration, else whether it was found; *types collects bit 0, 1 and 2 for
 * a present video, sequence and picture parameter set. */
static int hvcc_find(const uint8_t *config, int size, const uint8_t *nal, size_t nal_size, unsigned *types) {
    if (!config || size < 23 || config[0] != 1)
        return -1;
    int found = 0;
    const uint8_t *p = config + 23, *end = config + size;
    for (unsigned array = 0; array < config[22]; array++) {
        if (end - p < 3)
            return -1;
        unsigned type = p[0] & 0x3f, count = AV_RB16(p + 1);
        p += 3;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2 || (size_t)(end - p - 2) < AV_RB16(p))
                return -1;
            size_t length = AV_RB16(p);
            p += 2;
            if (length && type >= 32 && type <= 34)
                *types |= 1u << (type - 32);
            found |= nal && length == nal_size && !memcmp(p, nal, length);
            p += length;
        }
    }
    return found;
}

/* FFmpeg labels HEVC without a MOV sample entry of its own (from Matroska, for
 * example) 'hev1', which allows parameter sets that appear only in the samples.
 * Apple's readers do not decode 'hev1'. 'hvc1' carries every parameter set in
 * the sample entry, and a copied sample may still repeat one byte for byte.
 * Choose 'hvc1' for a track whose sample entry holds video, sequence and
 * picture parameter sets in hvcC form. check_hvc1 follows the sets a decoder
 * holds through the copy (follow_hevc_sets), each range starting from the sets
 * its source holds there (plan_stream_sets). Where they change at a keyframe,
 * that sample starts a new sample entry holding every set then active, so the
 * samples still only repeat sets from their entry. A picture parameter set that
 * a range brings inside a picture group under an ID no set holds is put in the
 * entry the range starts with (plan_hevc_sets). Any other change at a sample
 * that is not a keyframe withdraws 'hvc1', and mpcut_copy_omissions reports it. */
static void plan_hvc1(Writer *writer, const AVStream *destination) {
    unsigned types = 0;
    const AVCodecParameters *codec = destination->codecpar;
    if (writer->hvc1 && destination->index < (int)writer->selected_count && codec->codec_id == AV_CODEC_ID_HEVC && !codec->codec_tag
        && hvcc_find(codec->extradata, codec->extradata_size, NULL, 0, &types) >= 0 && types == 7)
        writer->hvc1[destination->index] = HEVC_ENTRY_HVC1;
}

enum { HEVC_SETS_SAME, HEVC_SETS_NEW_ENTRY, HEVC_SETS_UNREADABLE, HEVC_SETS_GROUP_CHANGE };

/* Follow the parameter sets of an 'hvc1' track (`initial` is its first sample entry) through one copied sample
 * of `source`. `range_start` marks the first sample of a range, which starts from the sets its source holds there:
 * `stream` (plan_stream_sets) or else its source's description, and then from `early` (length-prefixed picture
 * parameter sets, plan_hevc_sets). Returns whether the sample keeps its entry, starts a new one, or cannot be
 * described by an 'hvc1' entry. */
static int follow_hevc_sets(MPCutHevcSets **sets, const AVCodecParameters *initial, const AVCodecParameters *source,
                            int *range_start, const uint8_t *stream, int stream_size, const uint8_t *early, int early_size,
                            const AVPacket *packet) {
    size_t extra = 0;
    // A MOV source's own change of description is its sample entry, which the muxer does not relabel here.
    if (av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &extra)
        || (!*sets && !(*sets = mpcut_hevc_sets_create(initial->extradata, initial->extradata_size))))
        return HEVC_SETS_UNREADABLE;
    int changed = 0;
    if (*range_start) {
        *range_start = 0;
        // `stream` holds every set of the description too, as the samples before the range left them.
        changed = stream_size ? mpcut_hevc_sets_apply_sample(*sets, stream, stream_size, 4)
                              : mpcut_hevc_sets_apply_config(*sets, source->extradata, source->extradata_size);
        int added = changed < 0 || !early_size ? 0 : mpcut_hevc_sets_apply_sample(*sets, early, early_size, 4);
        changed = changed < 0 ? changed : added < 0 ? added : changed | added;
    }
    int sample = changed < 0 ? changed
        : mpcut_hevc_sets_apply_sample(*sets, packet->data, packet->size, (initial->extradata[21] & 3) + 1);
    if (sample < 0)
        return HEVC_SETS_UNREADABLE;
    if ((changed |= sample) && !(packet->flags & AV_PKT_FLAG_KEY))
        return HEVC_SETS_GROUP_CHANGE;
    return changed ? HEVC_SETS_NEW_ENTRY : HEVC_SETS_SAME;
}

static int check_hvc1(Writer *writer, const AVStream *input_track) {
    AVPacket *packet = writer->packet;
    const int index = packet->stream_index;
    uint8_t *state = writer->hvc1 ? &writer->hvc1[index] : NULL;
    if (!state || *state != HEVC_ENTRY_HVC1)
        return 0;
    const AVCodecParameters *codec = writer->output->streams[index]->codecpar;
    MPCutHevcSets **sets = &writer->hevc_sets[index];
    // The picture plan_hevc_sets read also starts each range from the sets it brings inside its picture groups.
    int scanned = writer->hevc_early && input_track->index == writer->hevc_range_video && writer->hevc_range < writer->hevc_early_count;
    int stream = writer->stream_sets && primary_video(input_track) && writer->hevc_range < writer->stream_set_count;
    int followed = follow_hevc_sets(sets, codec, input_track->codecpar, &writer->hevc_range_start,
                                    stream ? writer->stream_sets[writer->hevc_range] : NULL,
                                    stream ? writer->stream_sets_size[writer->hevc_range] : 0,
                                    scanned ? writer->hevc_early[writer->hevc_range] : NULL,
                                    scanned ? writer->hevc_early_size[writer->hevc_range] : 0, packet);
    if (followed == HEVC_SETS_UNREADABLE || followed == HEVC_SETS_GROUP_CHANGE) {
        *state = HEVC_ENTRY_HEV1;
        return 0;
    }
    if (followed == HEVC_SETS_SAME)
        return 0;
    // The muxer starts a new sample entry for a description it has not written, or returns to one it has.
    uint8_t *record = NULL;
    int size = 0;
    int result = mpcut_hevc_sets_initial(*sets) ? 0 : mpcut_hevc_sets_record(*sets, &record, &size);
    if (result < 0)
        return ff_error(writer, result, "Cannot describe the HEVC parameter sets of", writer->output_path);
    const uint8_t *description = record ? record : codec->extradata;
    size = record ? size : codec->extradata_size;
    uint8_t *side = av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, (size_t)size);
    if (side)
        memcpy(side, description, (size_t)size);
    av_free(record);
    return side ? 0 : fail(writer, "Cannot attach an HEVC sample description");
}

static int label_hvc1(Writer *writer) {
    uint32_t ids[64];
    size_t count = 0;
    for (unsigned i = 0; writer->hvc1 && i < writer->selected_count && count < 64; i++)
        if (writer->hvc1[i] == HEVC_ENTRY_HVC1)
            ids[count++] = (uint32_t)writer->output->streams[i]->id;
    return mpcut_mov_label_hvc1(writer->output_path, ids, count, writer->error, writer->error_capacity);
}

/* The parameter sets of an H.264 or HEVC track's avcC or hvcC description, or NULL. */
static MPCutHevcSets *stream_sets_create(const AVCodecParameters *codec) {
    if (codec->codec_id == AV_CODEC_ID_HEVC)
        return mpcut_hevc_sets_create(codec->extradata, codec->extradata_size);
    return codec->codec_id == AV_CODEC_ID_H264 ? mpcut_avc_sets_create(codec->extradata, codec->extradata_size) : NULL;
}

/* The NAL unit length size of the samples of a track that stream_sets_create reads. */
static int sample_length_size(const AVCodecParameters *codec) {
    return (codec->extradata[codec->codec_id == AV_CODEC_ID_HEVC ? 21 : 4] & 3) + 1;
}

/* A keyframe that a source's encoder offers as a start may follow a change of parameter sets that its samples
 * bring in-band and later keyframes do not repeat: decoded from the start, it uses the changed sets, while a copy
 * that starts there would use those of the description. For each range, find the sets a decoder reading its source
 * from the first packet holds when it reaches the range's first copied picture (the first video packet presented at
 * or after the range start): those of the description, replaced or joined by every set the samples before it bring.
 * Where they are not the description's, stream_sets[i] receives every one of them as NAL units with 4-byte lengths,
 * which describe the range (check_hvc1) or are repeated in its first sample (repeat_stream_sets). Reads each source
 * once, from its first packet to its latest range start, for H.264 and HEVC with avcC or hvcC descriptions. A source
 * whose sets cannot be followed, or a range that a generated still or several sample descriptions handle, gets
 * nothing. With `start_pts`, a range with Smart Trim edges is planned too, at its head edge's keyframe if it has one,
 * and start_pts[i] receives the time of the packet its sets describe the decoder before (smart_following); without,
 * such a range gets nothing. Returns 0, or -2 when the progress callback cancels. */
static int plan_stream_sets(Writer *writer, const MPCutSegment *segments, size_t count, uint8_t **stream_sets, int *sizes,
                            int64_t *start_pts) {
    AVPacket *packet = av_packet_alloc();
    size_t *order = av_malloc_array(count, sizeof(*order));
    MPCutTime *starts = av_malloc_array(count, sizeof(*starts));
    int result = packet && order && starts ? 0 : -1;
    for (size_t first = 0; !result && first < count; first++) {
        size_t seen = 0;
        while (strcmp(segments[seen].path, segments[first].path))
            seen++;
        AVFormatContext *input = NULL;
        if (seen != first || input_open(writer, &input, segments[first].path)) {
            avformat_close_input(&input);
            continue; // Each source is read once, where it first appears.
        }
        unsigned index = 0;
        while (index < input->nb_streams && !primary_video(input->streams[index]))
            index++;
        const AVStream *track = index < input->nb_streams ? input->streams[index] : NULL;
        MPCutHevcSets *sets = track ? stream_sets_create(track->codecpar) : NULL;
        size_t pending = 0;
        for (size_t i = first; sets && i < count; i++) {
            const MPCutSegment *segment = &segments[i];
            int edges = segment->head_edge.frame_count || segment->tail_edge.frame_count;
            if (strcmp(segment->path, segments[first].path) || segment->multiple_descriptions || segment->generated_still
                || (edges && !start_pts) || (!edges && count == 1 && segment->start.numerator == 0 && segment->reaches_end))
                continue;
            MPCutTime origin = segment->source_origin.denominator > 0 ? segment->source_origin
                : track->start_time != AV_NOPTS_VALUE ? time_ticks(track->start_time, track->time_base)
                : (MPCutTime){0, 1};
            // A head edge's decoder, and the source's, start at the edge's keyframe.
            MPCutTime start = time_add(origin, segment->head_edge.frame_count ? segment->head_edge.decode_from
                                                                               : segment->start, 1);
            if (!start.denominator)
                continue;
            size_t at = pending++;
            for (; at && time_compare(starts[at - 1], start) > 0; at--) {
                starts[at] = starts[at - 1];
                order[at] = order[at - 1];
            }
            starts[at] = start;
            order[at] = i;
        }
        for (unsigned j = 0; j < input->nb_streams; j++)
            input->streams[j]->discard = j == index ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
        int length_size = pending ? sample_length_size(track->codecpar) : 0;
        size_t next = 0;
        for (unsigned read = 1; !result && next < pending && av_read_frame(input, packet) >= 0; read++) {
            if (!(read % 1024) && progress_at(writer, writer->fraction))
                result = -2; // Cancelled.
            MPCutTime pts = packet->pts == AV_NOPTS_VALUE ? (MPCutTime){0, 0} : time_ticks(packet->pts, track->time_base);
            if ((unsigned)packet->stream_index == index && packet->size > 0) {
                for (; pts.denominator && next < pending && time_compare(pts, starts[next]) >= 0; next++) {
                    if (start_pts)
                        start_pts[order[next]] = packet->pts;
                    if (!mpcut_hevc_sets_initial(sets)
                        && mpcut_hevc_sets_units(sets, &stream_sets[order[next]], &sizes[order[next]]) < 0)
                        result = -1;
                }
                // A source whose sets cannot be followed further leaves its later ranges as they were.
                if (av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, NULL)
                    || mpcut_hevc_sets_apply_sample(sets, packet->data, packet->size, length_size) < 0)
                    next = pending;
            }
            av_packet_unref(packet);
        }
        mpcut_hevc_sets_free(sets);
        avformat_close_input(&input);
    }
    av_free(starts);
    av_free(order);
    av_packet_free(&packet);
    return result == -2 ? -2 : 0;
}

/* Put parameter sets (NAL units with 4-byte lengths) into a sample whose NAL units have `length_size`-byte lengths,
 * after a leading access unit delimiter. */
static int insert_parameter_sets(AVPacket *packet, int length_size, int hevc, const uint8_t *units, int size) {
    int total = 0;
    for (int at = 0; at <= size - 4; at += 4 + (int)AV_RB32(units + at)) {
        uint32_t length = AV_RB32(units + at);
        if ((length_size < 4 && length >> (8 * length_size)) || length > (uint32_t)(INT_MAX / 2 - total - length_size))
            return AVERROR(ERANGE);
        total += length_size + (int)length;
    }
    int offset = 0;
    if (packet->size > length_size) {
        uint32_t length = 0;
        for (int i = 0; i < length_size; i++)
            length = length << 8 | packet->data[i];
        unsigned type = hevc ? (packet->data[length_size] >> 1) & 0x3f : packet->data[length_size] & 0x1f;
        if ((hevc ? type == 35 : type == 9) && length <= (uint32_t)(packet->size - length_size))
            offset = length_size + (int)length;
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
        for (int i = 0; i < length_size; i++)
            q[i] = (uint8_t)(length >> (8 * (length_size - 1 - i)));
        memcpy(q + length_size, units + at + 4, length);
        q += length_size + length;
    }
    return 0;
}

/* Give the output's decoder, at the first copied picture of each range, the sets the source's decoder holds there
 * (plan_stream_sets), if the sets it holds from the description and the samples copied before, with those this
 * keyframe brings itself, lack any of them. This also covers a join whose earlier range left changed sets in the
 * decoder. A range that starts this way repeats them at each later keyframe whose description and own sets lack
 * them, so a reader can start there too. The sets go into the keyframe's sample, after any access unit delimiter,
 * which hev1, avc1 and Matroska allow. An 'hvc1' track gets sample entries instead (check_hvc1). Follows every
 * copied sample of the primary picture; one whose sets cannot be followed ends the repetition for the copy. */
static int repeat_stream_sets(Writer *writer, const AVStream *input_track) {
    AVPacket *packet = writer->packet;
    const AVCodecParameters *codec = input_track->codecpar;
    int range_start = writer->sets_range_start;
    writer->sets_range_start = 0;
    if (writer->sets_unfollowed || writer->smart_trim || writer->generated_stills || writer->track_video_config)
        return 0;
    // The output's description is the first range's source's (configure_output), before plan_avc_reorder's depth.
    if (!writer->output_sets) {
        writer->output_sets = stream_sets_create(codec);
        writer->description_sets = stream_sets_create(codec);
        if (!writer->output_sets || !writer->description_sets) {
            writer->sets_unfollowed = 1;
            return 0;
        }
    }
    int length_size = sample_length_size(codec);
    int described = writer->hvc1 && writer->hvc1[packet->stream_index] == HEVC_ENTRY_HVC1;
    if (range_start)
        writer->sets_repeating = 0;
    if (!described && (packet->flags & AV_PKT_FLAG_KEY) && (range_start || writer->sets_repeating)) {
        // What a decoder must end up with, and what it has: at a range start, the source's sets and the output
        // decoder's; at a later keyframe, the output decoder's and a reader's that starts there with the description.
        int stream = range_start && writer->stream_sets && writer->hevc_range < writer->stream_set_count
            && writer->stream_sets_size[writer->hevc_range] > 0;
        MPCutHevcSets *want = range_start ? stream_sets_create(codec) : mpcut_hevc_sets_copy(writer->output_sets);
        MPCutHevcSets *have = mpcut_hevc_sets_copy(range_start ? writer->output_sets : writer->description_sets);
        uint8_t *units = NULL;
        int size = 0;
        int result = !want || !have ? AVERROR(ENOMEM)
            : stream ? mpcut_hevc_sets_apply_sample(want, writer->stream_sets[writer->hevc_range],
                                                  writer->stream_sets_size[writer->hevc_range], 4) : 0;
        if (result >= 0)
            result = mpcut_hevc_sets_units(want, &units, &size);
        // Compare them once this keyframe's own sets are applied.
        if (result >= 0)
            result = mpcut_hevc_sets_apply_sample(want, packet->data, packet->size, length_size);
        if (result >= 0)
            result = mpcut_hevc_sets_apply_sample(have, packet->data, packet->size, length_size);
        int lacking = result >= 0 && !mpcut_hevc_sets_holds(have, want);
        mpcut_hevc_sets_free(want);
        mpcut_hevc_sets_free(have);
        if (lacking) {
            result = insert_parameter_sets(packet, length_size, codec->codec_id == AV_CODEC_ID_HEVC, units, size);
            writer->sets_repeating = 1;
        }
        av_free(units);
        if (result == AVERROR(ENOMEM))
            return fail(writer, "Cannot repeat the parameter sets of %s", writer->output_path);
        if (result < 0)
            writer->sets_unfollowed = 1;
    }
    if (!writer->sets_unfollowed && mpcut_hevc_sets_apply_sample(writer->output_sets, packet->data, packet->size, length_size) < 0)
        writer->sets_unfollowed = 1;
    return 0;
}

/* One pass of plan_hevc_sets over the copied samples of the first video stream of each range, in order. With
 * `collect`, a sample inside a picture group that only brings picture parameter sets with IDs no set holds adds
 * them to early[i] of its range i instead of ending the pass. `video` receives the stream read in each range. */
static int scan_hevc_sets(Writer *writer, const MPCutSegment *segments, size_t count, uint8_t *const *stream,
                          const int *stream_size, uint8_t **early, int *early_size, int *video, int collect, size_t *found) {
    AVPacket *packet = av_packet_alloc();
    AVCodecParameters *initial = avcodec_parameters_alloc();
    MPCutHevcSets *sets = NULL;
    int verdict = packet && initial ? HEVC_SETS_SAME : -1; // -1: the samples could not be read
    for (size_t i = 0; i < count && verdict == HEVC_SETS_SAME; i++) {
        const MPCutSegment *segment = &segments[i];
        AVFormatContext *input = NULL;
        if (input_open(writer, &input, segment->path)) {
            avformat_close_input(&input);
            verdict = -1;
            break;
        }
        unsigned index = 0;
        while (index < input->nb_streams && !primary_video(input->streams[index]))
            index++;
        const AVStream *track = index < input->nb_streams ? input->streams[index] : NULL;
        const AVCodecParameters *codec = track ? track->codecpar : NULL;
        if (i == 0 && codec && avcodec_parameters_copy(initial, codec) < 0)
            codec = NULL;
        MPCutTime origin = segment->source_origin.denominator > 0 ? segment->source_origin
            : track && track->start_time != AV_NOPTS_VALUE ? time_ticks(track->start_time, track->time_base)
            : (MPCutTime){0, 1};
        MPCutTime start = time_add(origin, segment->start, 1), end = time_add(origin, segment->end, 1);
        int whole = count == 1 && segment->start.numerator == 0 && segment->reaches_end;
        if (!codec || codec->codec_id != AV_CODEC_ID_HEVC || !start.denominator || !end.denominator) {
            avformat_close_input(&input);
            verdict = -1;
            break;
        }
        video[i] = (int)index;
        for (unsigned j = 0; j < input->nb_streams; j++)
            input->streams[j]->discard = j == index ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
        // A range starts at a keyframe, which is decoded before every picture presented from it on.
        int64_t target = time_round(start, track->time_base);
        if (!whole && target != AV_NOPTS_VALUE)
            av_seek_frame(input, (int)index, target, AVSEEK_FLAG_BACKWARD);
        int range_start = 1;
        for (unsigned read = 1; verdict == HEVC_SETS_SAME && av_read_frame(input, packet) >= 0; read++) {
            if (!(read % 1024) && progress_at(writer, writer->fraction)) {
                verdict = -2; // Cancelled.
                av_packet_unref(packet);
                break;
            }
            MPCutTime pts = time_ticks(packet->pts, track->time_base);
            if ((unsigned)packet->stream_index == index && packet->size > 0 && pts.denominator) {
                if (!whole && time_compare(pts, end) >= 0) {
                    av_packet_unref(packet);
                    break;
                }
                // The same samples remux_packet keeps.
                if (whole || time_compare(pts, start) >= 0) {
                    uint8_t *added = NULL;
                    int added_size = 0, only_added = 0;
                    if (collect && sets && !range_start && !(packet->flags & AV_PKT_FLAG_KEY))
                        only_added = mpcut_hevc_sets_new_pictures(sets, packet->data, packet->size,
                                                                  (initial->extradata[21] & 3) + 1, &added, &added_size);
                    verdict = follow_hevc_sets(&sets, initial, codec, &range_start, stream ? stream[i] : NULL,
                                               stream ? stream_size[i] : 0, early[i], early_size[i], packet);
                    if (verdict == HEVC_SETS_GROUP_CHANGE && only_added == 1 && added_size > 0
                        && early_size[i] <= INT_MAX - added_size) {
                        uint8_t *grown = av_realloc(early[i], (size_t)(early_size[i] + added_size));
                        if (grown) {
                            memcpy(grown + early_size[i], added, (size_t)added_size);
                            early[i] = grown;
                            early_size[i] += added_size;
                            verdict = HEVC_SETS_SAME;
                        }
                    }
                    av_free(added);
                    if (verdict == HEVC_SETS_NEW_ENTRY)
                        verdict = HEVC_SETS_SAME;
                    *found = i;
                }
            }
            av_packet_unref(packet);
        }
        avformat_close_input(&input);
    }
    mpcut_hevc_sets_free(sets);
    avcodec_parameters_free(&initial);
    av_packet_free(&packet);
    return verdict;
}

/* Plan the 'hvc1' description of an HEVC picture copied into a MOV-family file, by following the parameter sets
 * of every copied sample with the writer's own rule (follow_hevc_sets) before anything is written. A new sample
 * entry may start only at a keyframe. A picture parameter set that a range brings inside a picture group with an
 * ID no set holds can still be described: the range starts with it (early[i]), so the entry in use holds it and
 * the sample only repeats it. A set that replaces another inside a group, or a video or sequence parameter set
 * there, withdraws 'hvc1' (check_hvc1). Reads only a picture that plan_hvc1 would describe as 'hvc1', and only
 * the packets of the copied ranges. Returns HEVC_SETS_SAME, the reason the copy keeps 'hev1' with the segment
 * where it is found, -1 when the samples cannot be read, or -2 when the progress callback cancels; early[] is
 * left empty unless HEVC_SETS_SAME. Each range starts from stream[i] (plan_stream_sets), which with `read_stream`
 * this plans first, only for a picture it reads. */
static int plan_hevc_sets(Writer *writer, const MPCutSegment *segments, size_t count, const AVFormatContext *first,
                          uint8_t **stream, int *stream_size, int read_stream,
                          uint8_t **early, int *early_size, int *video, size_t *found) {
    if (!is_mov(writer->output->oformat) || writer->tracks == MPCUT_TRACKS_AUDIO || !count)
        return HEVC_SETS_SAME;
    for (size_t i = 0; i < count; i++) {
        // Generated stills keep their own entries, and Smart Trim names its HEVC entry 'hvc1' itself.
        if (segments[i].generated_still || segments[i].head_edge.frame_count || segments[i].tail_edge.frame_count)
            return HEVC_SETS_SAME;
    }
    // The entry configure_output and plan_hvc1 give the picture copied from the first source (open as `first`).
    unsigned index = 0, types = 0;
    while (index < first->nb_streams && !primary_video(first->streams[index]))
        index++;
    const AVCodecParameters *codec = index < first->nb_streams ? first->streams[index]->codecpar : NULL;
    if (!codec || codec->codec_id != AV_CODEC_ID_HEVC
        || (writer->output->oformat->codec_tag
            && av_codec_get_id(writer->output->oformat->codec_tag, codec->codec_tag) == codec->codec_id)
        || hvcc_find(codec->extradata, codec->extradata_size, NULL, 0, &types) < 0 || types != 7)
        return HEVC_SETS_SAME;
    if (read_stream && stream && plan_stream_sets(writer, segments, count, stream, stream_size, NULL) == -2)
        return -2;
    int verdict = scan_hevc_sets(writer, segments, count, stream, stream_size, early, early_size, video, 1, found);
    int collected = 0;
    for (size_t i = 0; i < count; i++)
        collected |= early_size[i] > 0;
    // With every range starting from what it collected, no sample may still change a set inside a group.
    if (verdict == HEVC_SETS_SAME && collected)
        verdict = scan_hevc_sets(writer, segments, count, stream, stream_size, early, early_size, video, 0, found);
    if (verdict != HEVC_SETS_SAME) {
        for (size_t i = 0; i < count; i++) {
            av_freep(&early[i]);
            early_size[i] = 0;
        }
    }
    return verdict;
}

/* A zero-size packet marks a packet outside the selected range. */
static int slice_pcm(Writer *writer, const AVStream *input_track, const Range *range, int frame_size) {
    AVPacket *packet = writer->packet;
    AVStream *track = writer->output->streams[packet->stream_index];
    AVRational sample_base = {1, input_track->codecpar->sample_rate};
    int64_t input_ticks_per_sample = (int64_t)input_track->time_base.num * sample_base.den;
    int64_t output_ticks_per_sample = (int64_t)track->time_base.num * sample_base.den;
    if (input_ticks_per_sample <= 0 || input_track->time_base.den % input_ticks_per_sample != 0
        || output_ticks_per_sample <= 0 || track->time_base.den % output_ticks_per_sample != 0) {
        return fail(writer, "The input or output clock cannot represent exact PCM cuts on track %d",
                    packet->stream_index);
    }
    int64_t source_first = time_round(range->source_start, sample_base);
    int64_t output_first = time_round(range->output_start, sample_base);
    int64_t output_end = time_round(range->output_end, sample_base);
    MPCutTime timestamp = time_ticks(packet->pts, input_track->time_base);
    int64_t packet_first = time_round(timestamp, sample_base);

    if (packet_first == AV_NOPTS_VALUE || source_first == AV_NOPTS_VALUE || output_first == AV_NOPTS_VALUE
        || output_end == AV_NOPTS_VALUE || packet->size % frame_size) {
        return fail(writer, "Cannot map PCM samples on track %d", packet->stream_index);
    }

    if (input_track->start_time != AV_NOPTS_VALUE && input_track->duration > 0
        && (Wide)input_track->start_time + input_track->duration <= INT64_MAX) {
        int64_t track_first = time_round(time_ticks(input_track->start_time, input_track->time_base), sample_base);
        int64_t track_end = time_round(time_ticks(input_track->start_time + input_track->duration,
                                                  input_track->time_base), sample_base);
        Wide needed = (Wide)output_end - output_first;
        /* Independent source rounding can leave a final trim one sample short. */
        if (track_first != AV_NOPTS_VALUE && track_end != AV_NOPTS_VALUE && source_first > track_first
            && (Wide)source_first + needed == (Wide)track_end + 1) {
            source_first--;
        }
    }
    Wide packet_output_first = (Wide)packet_first - source_first + output_first;
    Wide packet_output_end = packet_output_first + packet->size / frame_size;
    Wide kept_first = packet_output_first > output_first ? packet_output_first : output_first;
    Wide kept_end = packet_output_end < output_end ? packet_output_end : output_end;
    if (kept_first >= kept_end) {
        packet->size = 0;
        return 0;
    }

    int64_t pts = time_round(time_ticks((int64_t)kept_first, sample_base), track->time_base);
    int64_t end = time_round(time_ticks((int64_t)kept_end, sample_base), track->time_base);
    if (pts == AV_NOPTS_VALUE || end == AV_NOPTS_VALUE || end <= pts || (Wide)end - pts > INT64_MAX) {
        return fail(writer, "Output clock cannot represent a PCM packet on track %d", packet->stream_index);
    }
    packet->data += (int)(kept_first - packet_output_first) * frame_size;
    packet->size = (int)(kept_end - kept_first) * frame_size;
    packet->pts = pts;
    packet->dts = pts;
    packet->duration = end - pts;
    return 0;
}

static int hash_picture(struct AVSHA *hash, const AVPacket *packet, uint8_t **config, size_t *config_size) {
    size_t size = 0;
    const uint8_t *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
    if (extra) {
        uint8_t *copy = av_memdup(extra, size);
        if (!copy)
            return AVERROR(ENOMEM);
        av_free(*config);
        *config = copy;
        *config_size = size;
    }
    int64_t fields[] = {packet->pts, packet->size, *config_size};
    av_sha_update(hash, (const uint8_t *)fields, sizeof(fields));
    if (*config_size)
        av_sha_update(hash, *config, *config_size);
    av_sha_update(hash, packet->data, packet->size);
    return 0;
}

/* Reopen the staged picture lane and confirm that the muxer selected the
 * expected descriptions and preserved each length-prefixed sample verbatim. */
static int verify_picture(Writer *writer, MPCutTime duration) {
    AVFormatContext *input = NULL;
    uint8_t *config = NULL;
    size_t config_size = 0;
    struct AVSHA *hash = av_sha_alloc();
    int result = hash ? input_open(writer, &input, writer->output_path) :
                        fail(writer, "Cannot allocate still picture verification");
    if (result)
        goto done;
    const AVStream *written = writer->output->streams[0];
    if (input->nb_streams != 1 || !primary_video(input->streams[0]) ||
        av_cmp_q(input->streams[0]->time_base, written->time_base) != 0 ||
        time_compare(time_ticks(input->streams[0]->duration, input->streams[0]->time_base), duration) != 0) {
        result = fail(writer, "Muxing changed the generated picture lane or its clock");
        goto done;
    }
    AVCodecParameters *codec = input->streams[0]->codecpar;
    if (codec->codec_id != written->codecpar->codec_id || codec->codec_tag != written->codecpar->codec_tag ||
        codec->width != written->codecpar->width || codec->height != written->codecpar->height) {
        result = fail(writer, "Muxing changed the generated picture lane's codec or dimensions");
        goto done;
    }
    /* ProRes decoder properties are in each frame. FFmpeg exposes the entire
     * sample entry as extradata even though it is not decoder configuration. */
    if (codec->codec_id == AV_CODEC_ID_H264 || codec->codec_id == AV_CODEC_ID_HEVC)
        config_size = codec->extradata_size;
    if (config_size && !(config = av_memdup(codec->extradata, config_size))) {
        result = fail(writer, "Cannot read generated picture descriptions");
        goto done;
    }
    av_sha_init(hash, 256);
    int64_t last_dts = AV_NOPTS_VALUE;
    int code;
    while ((code = av_read_frame(input, writer->packet)) >= 0) {
        const AVPacket *packet = writer->packet;
        if (packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE ||
            packet->dts > packet->pts || (last_dts != AV_NOPTS_VALUE && packet->dts <= last_dts) ||
            hash_picture(hash, packet, &config, &config_size) < 0) {
            result = fail(writer, "Cannot verify a sample in the muxed still picture lane");
            goto done;
        }
        last_dts = packet->dts;
        av_packet_unref(writer->packet);
        result = progress_at(writer, writer->fraction);
        if (result)
            goto done;
    }
    if (code != AVERROR_EOF) {
        result = ff_error(writer, code, "Cannot verify", writer->output_path);
        goto done;
    }
    uint8_t expected[32], actual[32];
    av_sha_final(writer->picture_hash, expected);
    av_sha_final(hash, actual);
    if (memcmp(expected, actual, sizeof(expected)))
        result = fail(writer, "Muxing changed a picture sample, presentation timestamp, or decoder description");
done:
    av_free(config);
    av_free(hash);
    avformat_close_input(&input);
    return result;
}

static int write_packet(Writer *writer, const char *path) {
    AVPacket *packet = writer->packet;
    int index = packet->stream_index;
    int64_t last = writer->last_dts[index];
    int strict = !(writer->output->oformat->flags & AVFMT_TS_NONSTRICT);
    if (packet->dts != AV_NOPTS_VALUE && last != AV_NOPTS_VALUE
        && (packet->dts < last || (strict && packet->dts == last))) {
        return fail(writer, "Decode timestamps cannot be spliced on track %d in %s (%" PRId64 " after %" PRId64 ")",
                    index, path, packet->dts, last);
    }
    if (packet->dts != AV_NOPTS_VALUE) {
        writer->last_dts[index] = packet->dts;
    }

    if (writer->picture_hash) {
        int result = hash_picture(writer->picture_hash, packet, &writer->picture_config, &writer->picture_config_size);
        if (result < 0)
            return fail(writer, "Cannot retain the generated picture configuration");
    }
    packet->pos = -1;
    int result = av_interleaved_write_frame(writer->output, packet);
    return result < 0 ? ff_error(writer, result, "Cannot write packet to", writer->output_path) : 0;
}

static MPCutTime range_preroll(const AVCodecParameters *codec) {
    if (codec->codec_type != AVMEDIA_TYPE_AUDIO || codec->sample_rate <= 0) {
        return (MPCutTime){0, 1};
    }
    /* Allow for AAC sample-clock rounding and a PCM start that moves back
     * by one sample when rounding the last trim. */
    int minimum = codec->codec_id == AV_CODEC_ID_AAC ? MPCUT_AAC_PREROLL_SAMPLES + 1 : 2;
    int samples = codec->seek_preroll > minimum ? codec->seek_preroll : minimum;
    return (MPCutTime){samples, codec->sample_rate};
}

static const MPCutAACSourceEdit *aac_source_track(const Writer *writer, const AVStream *stream,
                                                  size_t *count, int *sample_rate) {
    return stream->codecpar->codec_id == AV_CODEC_ID_AAC
        ? mpcut_aac_source_track(writer->aac_source, stream->id, count, sample_rate) : NULL;
}

/* Verify the first packet from every linked track before committing a seek.
 * The first indexed packet is also sufficient for a track that starts late.
 * Reopen on an unsupported seek or if read-ahead cannot prove coverage. */
static int position_range(Writer *writer, AVFormatContext **input, const char *path,
                          unsigned video_index, const Range *range) {
    AVFormatContext *source = *input;
    if (range->whole_file || range->keep_audio_start || !source->pb
        || !(source->pb->seekable & AVIO_SEEKABLE_NORMAL)
        || (!av_match_name("mov", source->iformat->name) &&
            !(writer->tracks == MPCUT_TRACKS_AUDIO && av_match_name(source->iformat->name, "wav,aiff,flac")))) {
        return 0;
    }

    AVStream *video = source->streams[video_index];
    const AVIndexEntry *first = avformat_index_get_entry(video, 0);
    /* Give audio a lead over the video seek point. The proof below checks
     * actual packet timestamps, including composition offsets and preroll. */
    MPCutTime lead = {1, 4};
    for (unsigned index = 0; index < source->nb_streams; index++) {
        MPCutTime preroll = range_preroll(source->streams[index]->codecpar);
        if (time_compare(preroll, lead) > 0) {
            lead = preroll;
        }
    }
    int64_t target = time_round(time_add(range->source_start, lead, -1), video->time_base);
    if (target == AV_NOPTS_VALUE || target <= (first ? first->timestamp : 0)) {
        return 0;
    }

    unsigned remaining = writer->selected_count;
    if (writer->aac_source) {
        for (unsigned index = 0; index < source->nb_streams; index++) {
            size_t count;
            int sample_rate;
            if (writer->stream_map[index] >= 0 && aac_source_track(writer, source->streams[index], &count, &sample_rate)) {
                writer->range_tracks[index] = 1;
                remaining--;
            }
        }
    }
    int flags = AVSEEK_FLAG_BACKWARD;
    if (av_seek_frame(source, video_index, target, flags) >= 0) {
        for (unsigned count = 0; remaining && count < 256; count++) {
            AVPacket *packet = writer->packet;
            int code = av_read_frame(source, packet);
            if (code < 0) {
                break;
            }
            unsigned index = packet->stream_index;
            if (source->nb_streams != writer->range_track_count || index >= writer->range_track_count) {
                return fail(writer, "Track layout changed while seeking %s", path);
            }
            if (writer->stream_map[index] >= 0 && !writer->range_tracks[index]) {
                AVStream *track = source->streams[index];
                const AVIndexEntry *entry = avformat_index_get_entry(track, 0);
                MPCutTime pts = time_ticks(packet->pts, track->time_base);
                MPCutTime required = time_add(range->source_start, range_preroll(track->codecpar), -1);
                if ((pts.denominator && required.denominator && time_compare(pts, required) <= 0)
                    || (entry && packet->pos >= 0 && packet->pos == entry->pos
                        && packet->dts == entry->timestamp)) {
                    writer->range_tracks[index] = 1;
                    remaining--;
                } else {
                    av_packet_unref(packet);
                    break;
                }
            }
            av_packet_unref(packet);
            int cancelled = progress_at(writer, writer->fraction);
            if (cancelled) {
                return cancelled;
            }
        }
        if (!remaining && av_seek_frame(source, video_index, target, flags) >= 0) {
            return 0;
        }
    }

    avformat_close_input(input);
    return input_open(writer, input, path);
}

static int write_aac_source_span(Writer *writer, AVFormatContext *raw, const AVStream *source,
                                 unsigned destination, int rate, int64_t media_start,
                                 int64_t output_start, int64_t output_end, int keep_tail_duration) {
    AVRational samples = {1, rate};
    int64_t duration = output_end - output_start;
    int64_t seek_sample = media_start > MPCUT_AAC_PREROLL_SAMPLES
        ? media_start - MPCUT_AAC_PREROLL_SAMPLES : 0;
    int64_t seek_tick = av_rescale_q_rnd(seek_sample, samples, source->time_base, AV_ROUND_DOWN);
    int result = av_seek_frame(raw, source->index, seek_tick, AVSEEK_FLAG_BACKWARD);
    if (result < 0) {
        return ff_error(writer, result, "Cannot seek the AAC media track in", raw->url);
    }
    result = mpcut_aac_begin(writer->aac_edits, destination, rate, (MPCutTime){media_start, rate},
                            (MPCutTime){output_start, rate}, (MPCutTime){output_end, rate},
                            writer->error, writer->error_capacity);
    if (result) {
        return result;
    }

    AVPacket *packet = writer->packet;
    AVRational output_base = writer->output->streams[destination]->time_base;
    while ((result = av_read_frame(raw, packet)) >= 0) {
        result = progress_at(writer, writer->fraction);
        if (result) {
            return result;
        }
        if (packet->stream_index == source->index) {
            int64_t position = av_rescale_q(packet->pts, source->time_base, samples);
            if (packet->pts != AV_NOPTS_VALUE && position >= media_start + duration) {
                av_packet_unref(packet);
                result = AVERROR_EOF;
                break;
            }
            packet->stream_index = destination;
            result = mpcut_aac_packet(writer->aac_edits, packet, source->time_base,
                                      output_base, keep_tail_duration, writer->error, writer->error_capacity);
            if (result) {
                return result;
            }
            if (packet->size > 0 && (result = write_packet(writer, raw->url))) {
                return result;
            }
        }
        av_packet_unref(packet);
    }
    if (result != AVERROR_EOF) {
        return ff_error(writer, result, "Cannot read the AAC media track in", raw->url);
    }
    return mpcut_aac_end(writer->aac_edits, destination, writer->error, writer->error_capacity);
}

static int write_aac_source_track(Writer *writer, AVFormatContext *raw, const AVStream *input_track,
                                  const MPCutAACSourceEdit *edits, size_t count, int rate,
                                  const Range *range) {
    const AVStream *source = NULL;
    for (unsigned i = 0; i < raw->nb_streams; i++) {
        if (raw->streams[i]->id == input_track->id) {
            source = raw->streams[i];
            break;
        }
    }
    if (!source || source->codecpar->codec_id != AV_CODEC_ID_AAC
        || source->codecpar->sample_rate != rate) {
        return fail(writer, "Cannot identify media samples for AAC track %d in %s",
                    input_track->index, raw->url);
    }

    for (unsigned i = 0; i < raw->nb_streams; i++) {
        raw->streams[i]->discard = raw->streams[i] == source ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }

    AVRational samples = {1, rate};
    int64_t first = time_round(range->source_start, samples);
    int64_t output_first = time_round(range->output_start, samples);
    int64_t output_end = time_round(range->output_end, samples);
    unsigned destination = writer->stream_map[input_track->index];
    if (range->whole_file) {
        int64_t shift = time_round(range->shift, samples);
        int64_t track_start = 0;
        int64_t track_end = edits[count - 1].presentation_end;
        if (range->whole_audio_selection) {
            // A standalone soundtrack starts at its first audible sample. When
            // preserving several tracks, keep their relative delay.
            size_t head = 0, tail = count;
            while (head < tail && edits[head].media_start < 0) head++;
            while (tail > head && edits[tail - 1].media_start < 0) tail--;
            if (head == tail)
                return fail(writer, "AAC track %d has no audible media", input_track->index);
            track_start = edits[head].presentation_start;
            track_end = edits[tail - 1].presentation_end;
        }
        if (shift == INT64_MIN || shift > INT64_MAX - track_end) {
            return fail(writer, "Cannot represent the AAC presentation interval in %s", raw->url);
        }
        first = shift < 0 ? -shift : 0;
        if (first < track_start) first = track_start;
        output_first = first + shift;
        output_end = track_end + shift;
        if (output_first > 0) {
            int result = mpcut_aac_empty(writer->aac_edits, destination, rate,
                                         (MPCutTime){0, 1}, (MPCutTime){output_first, rate},
                                         writer->error, writer->error_capacity);
            if (result) {
                return result;
            }
        }
    }
    if (first < 0 || output_first < 0 || output_end <= output_first
        || first > INT64_MAX - (output_end - output_first)) {
        return fail(writer, "Cannot represent the AAC presentation interval in %s", raw->url);
    }
    int64_t end = first + (output_end - output_first);
    int64_t cursor = first;
    for (size_t i = 0; i < count && cursor < end; i++) {
        const MPCutAACSourceEdit *edit = &edits[i];
        if (cursor >= edit->presentation_end) {
            continue;
        }
        if (cursor < edit->presentation_start) {
            break;
        }
        int64_t span_end = end < edit->presentation_end ? end : edit->presentation_end;
        if (i == count - 1 && end - span_end == 1) {
            span_end = end;
        }
        int64_t output_span_start = output_first + (cursor - first);
        int64_t output_span_end = output_first + (span_end - first);
        int result;
        if (edit->media_start == -1) {
            result = mpcut_aac_empty(writer->aac_edits, destination, rate,
                                     (MPCutTime){output_span_start, rate},
                                     (MPCutTime){output_span_end, rate},
                                     writer->error, writer->error_capacity);
        } else {
            int64_t media_first = edit->media_start + (cursor - edit->presentation_start);
            if (media_first > INT64_MAX - (span_end - cursor)) {
                return fail(writer, "Cannot represent the AAC media interval in %s", raw->url);
            }
            result = write_aac_source_span(writer, raw, source, destination, rate, media_first,
                                           output_span_start, output_span_end, range->whole_file && span_end == end);
        }
        if (result) {
            return result;
        }
        cursor = span_end;
    }
    return cursor == end ? 0 : fail(writer, "AAC edit list does not cover the selected video range in %s", raw->url);
}

static int write_aac_source(Writer *writer, const AVFormatContext *input,
                            const Range *range, unsigned *remaining) {
    AVFormatContext *raw = NULL;
    AVDictionary *options = NULL;
    int code = av_dict_set(&options, "ignore_editlist", "1", 0);
    if (code >= 0) {
        code = avformat_open_input(&raw, input->url, input->iformat, &options);
    }
    av_dict_free(&options);
    if (code < 0) {
        return ff_error(writer, code, "Cannot read AAC media without applying old edits in", input->url);
    }

    int result = 0;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        size_t count;
        int rate;
        if (writer->stream_map[i] < 0) continue;
        const MPCutAACSourceEdit *edits = aac_source_track(writer, input->streams[i], &count, &rate);
        if (!edits) {
            continue;
        }
        result = write_aac_source_track(writer, raw, input->streams[i], edits, count, rate, range);
        if (result) {
            break;
        }
        writer->range_tracks[i] = 2;
        (*remaining)--;
    }
    avformat_close_input(&raw);
    return result;
}

static int prepare_patches(Writer *writer, const AVStream *video, const MPCutSegment *segment, MPCutTime origin) {
    const MPCutEdgeRange plan[] = {segment->head_edge, segment->tail_edge};
    writer->video_origin_pts = time_round(origin, video->time_base);
    for (unsigned i = 0; i < 2; i++) {
        EdgePatch *patch = &writer->patches[i];
        *patch = (EdgePatch){ .plan = plan[i] };
        if (!plan[i].frame_count)
            continue;
        if (plan[i].decode_from.denominator <= 0 || plan[i].from.denominator <= 0 || plan[i].to.denominator <= 0 ||
            plan[i].decode_from.numerator < 0 || time_compare(plan[i].decode_from, plan[i].from) > 0 ||
            time_compare(plan[i].from, segment->start) < 0 || time_compare(plan[i].to, segment->end) > 0 ||
            time_compare(plan[i].from, plan[i].to) >= 0 ||
            (i == 1 && plan[0].frame_count && time_compare(plan[0].to, plan[i].from) > 0))
            return fail(writer, "Invalid Smart Trim edge range in %s", segment->path);
        enum AVCodecID codec = video->codecpar->codec_id;
        if (!(((codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC) && is_mov(writer->output->oformat)) ||
              (codec == AV_CODEC_ID_AV1 && is_matroska(writer->output->oformat))))
            return fail(writer, "This video codec and container cannot carry a Smart Trim edge");
        patch->start_pts = time_round(time_add(origin, plan[i].from, 1), video->time_base);
        patch->end_pts = time_round(time_add(origin, plan[i].to, 1), video->time_base);
        patch->decode_pts = time_round(time_add(origin, plan[i].decode_from, 1), video->time_base);
        if (writer->video_origin_pts == AV_NOPTS_VALUE || patch->start_pts == AV_NOPTS_VALUE ||
            patch->end_pts == AV_NOPTS_VALUE || patch->end_pts <= patch->start_pts)
            return fail(writer, "The video clock cannot represent a Smart Trim edge in %s", segment->path);
    }
    return 0;
}

static int compare_pts(const void *lhs, const void *rhs) {
    int64_t a = *(const int64_t *)lhs;
    int64_t b = *(const int64_t *)rhs;
    return (a > b) - (a < b);
}

static int edge_progress(void *context, double fraction) {
    Writer *writer = context;
    if (!writer->edge_cancelled)
        writer->edge_cancelled = progress_at(writer, fraction) != 0;
    return writer->edge_cancelled;
}

static int pending_patches(const Writer *writer) {
    for (unsigned i = 0; i < 2; i++) {
        if (writer->patches[i].consumed < writer->patches[i].plan.frame_count)
            return 1;
    }
    return 0;
}

/* Smart Trim follows the sets a decoder of the source holds (plan_stream_sets) through every source picture it
 * reads, copied, replaced by an edge or outside the range, as the source's decoder would. Returns whether it does. */
static int smart_following(Writer *writer, const AVStream *video, int64_t pts) {
    enum AVCodecID codec = video->codecpar->codec_id;
    if (!writer->smart_trim || writer->smart_unfollowed || (codec != AV_CODEC_ID_H264 && codec != AV_CODEC_ID_HEVC))
        return 0;
    if (!writer->smart_sets && writer->stream_start_pts && writer->hevc_range < writer->stream_set_count
        && pts == writer->stream_start_pts[writer->hevc_range]) {
        // The packet the planned sets describe the decoder before: the range's first picture or its head edge's keyframe.
        const uint8_t *units = writer->stream_sets[writer->hevc_range];
        writer->smart_sets = stream_sets_create(video->codecpar);
        if (!writer->smart_sets || (units && mpcut_hevc_sets_apply_sample(writer->smart_sets, units,
                                                                         writer->stream_sets_size[writer->hevc_range], 4) < 0))
            writer->smart_unfollowed = 1;
    }
    return !writer->smart_unfollowed && writer->smart_sets;
}

/* Apply the sets of the source picture just read, the original of one an edge replaces included. Returns whether
 * they changed what the decoder holds. */
static int smart_follow(Writer *writer, const AVStream *video, const AVPacket *packet) {
    int changed = mpcut_hevc_sets_apply_sample(writer->smart_sets, packet->data, packet->size,
                                               sample_length_size(video->codecpar));
    writer->smart_unfollowed |= changed < 0;
    return changed > 0;
}

/* The source's sets where the output switches back from an encoded edge, or from another range, to copied pictures:
 * an 'hvc1' sample entry of their own, or for H.264 the source's entry with the sets repeated in the sample. The
 * edge's entry holds only its encoder's sets, and the description's may be stale. */
static int smart_restore(Writer *writer, const AVFormatContext *input, const AVStream *video, const uint8_t *extra, int size) {
    AVPacket *packet = writer->packet;
    const AVCodecParameters *codec = video->codecpar;
    int following = smart_following(writer, video, packet->pts);
    int changed = following && !mpcut_hevc_sets_initial(writer->smart_sets);
    uint8_t *record = NULL, *units = NULL;
    int record_size = 0, units_size = 0, code = 0;
    // Where an earlier switch left other sets in the decoder, the description's entry alone may not be a switch at all.
    if (changed || (following && writer->smart_dirty))
        code = codec->codec_id == AV_CODEC_ID_HEVC ? mpcut_hevc_sets_record(writer->smart_sets, &record, &record_size)
                                                    : mpcut_hevc_sets_units(writer->smart_sets, &units, &units_size);
    if (code >= 0)
        code = mpcut_splice_restore(packet, codec, record ? record : extra, record ? record_size : size);
    if (code >= 0 && units)
        code = insert_parameter_sets(packet, sample_length_size(codec), 0, units, units_size);
    int repeated = units != NULL;
    av_free(record);
    av_free(units);
    if (code == AVERROR_INVALIDDATA && codec->codec_id == AV_CODEC_ID_AV1)
        return fail(writer, "The copied AV1 sequence in %s needs a key packet and a recoverable sequence header", input->url);
    if (code < 0)
        return ff_error(writer, code, "Cannot restore source decoder configuration at the Smart Trim splice in", input->url);
    writer->smart_repeating = repeated;
    writer->smart_dirty = changed;
    writer->restore_video_config = 0;
    return 0;
}

/* A later keyframe of an H.264 run that smart_restore repeated the source's sets in, if the source's entry and the
 * keyframe's own sets lack them: so a reader can start there too. */
static int smart_repeat(Writer *writer, const AVStream *video) {
    AVPacket *packet = writer->packet;
    const AVCodecParameters *codec = video->codecpar;
    MPCutHevcSets *have = stream_sets_create(codec), *want = mpcut_hevc_sets_copy(writer->smart_sets);
    int length_size = sample_length_size(codec);
    uint8_t *units = NULL;
    int size = 0;
    int code = have && want ? mpcut_hevc_sets_units(want, &units, &size) : AVERROR(ENOMEM);
    if (code >= 0)
        code = mpcut_hevc_sets_apply_sample(have, packet->data, packet->size, length_size);
    if (code >= 0)
        code = mpcut_hevc_sets_apply_sample(want, packet->data, packet->size, length_size);
    if (code >= 0 && !mpcut_hevc_sets_holds(have, want))
        code = insert_parameter_sets(packet, length_size, 0, units, size);
    mpcut_hevc_sets_free(have);
    mpcut_hevc_sets_free(want);
    av_free(units);
    if (code == AVERROR(ENOMEM))
        return fail(writer, "Cannot repeat the parameter sets of %s", writer->output_path);
    writer->smart_unfollowed |= code < 0;
    return 0;
}

/* Map display-ordered replacement pictures onto the retained source decode slots.
 * The source index proves that copied runs start and end outside the patched GOPs.
 * Keeping the original DTS slots preserves decode order on either side of a patch. */
static int splice_video(Writer *writer, const AVFormatContext *input, const AVStream *video, const Range *range) {
    AVPacket *packet = writer->packet;
    const int64_t pts = packet->pts;
    if (pts == AV_NOPTS_VALUE)
        return fail(writer, "A Smart Trim video packet has no presentation timestamp");
    int following = smart_following(writer, video, pts);
    EdgePatch *tail = &writer->patches[1];
    if (following && tail->plan.frame_count && !tail->encoded && !tail->consumed && pts == tail->decode_pts
        && !writer->tail_sets && !mpcut_hevc_sets_initial(writer->smart_sets)
        && mpcut_hevc_sets_units(writer->smart_sets, &writer->tail_sets, &writer->tail_sets_size) < 0)
        return fail(writer, "Cannot keep the parameter sets of the Smart Trim edge in %s", input->url);
    if (writer->track_video_config) {
        size_t size = 0;
        const uint8_t *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
        if (extra) {
            if (size == 0 || size > INT_MAX)
                return fail(writer, "Invalid source sample description in %s", input->url);
            uint8_t *copy = av_memdup(extra, size);
            if (!copy)
                return fail(writer, "Cannot retain the active source sample description");
            av_free(writer->active_config);
            writer->active_config = copy;
            writer->active_config_size = size;
            writer->restore_video_config = 1;
        }
    }
    for (unsigned i = 0; i < 2; i++) {
        EdgePatch *patch = &writer->patches[i];
        if (!patch->plan.frame_count || pts < patch->start_pts || pts >= patch->end_pts)
            continue;
        if (patch->consumed >= patch->plan.frame_count)
            return fail(writer, "More source pictures than indexed in a Smart Trim edge");
        if (!patch->encoded) {
            patch->source_times = av_malloc_array(patch->plan.frame_count, sizeof(int64_t));
            patch->encoded_times = av_malloc_array(patch->plan.frame_count, sizeof(int64_t));
            if (!patch->source_times || !patch->encoded_times)
                return fail(writer, "Cannot verify the presentation times of the Smart Trim edge");
            // The edge's decoder starts at its keyframe with the sets the source's decoder holds there.
            const uint8_t *sets = i ? writer->tail_sets : writer->stream_sets && writer->hevc_range < writer->stream_set_count
                ? writer->stream_sets[writer->hevc_range] : NULL;
            int sets_size = !sets || writer->smart_unfollowed ? 0
                : i ? writer->tail_sets_size : writer->stream_sets_size[writer->hevc_range];
            patch->encoded = mpcut_edge_open(input->url, video, writer->video_origin_pts, patch->plan.decode_from,
                patch->plan.from, patch->plan.to, patch->plan.frame_count, sets, sets_size, patch->plan.target_bit_rate,
                edge_progress, writer, writer->fraction, writer->error, writer->error_capacity);
            if (!patch->encoded)
                return writer->edge_cancelled ? 2 : 1;
        }
        int index = packet->stream_index;
        int64_t dts = packet->dts;
        if (following)
            smart_follow(writer, video, packet);
        av_packet_unref(packet);
        if (mpcut_edge_next(patch->encoded, packet) != 0)
            return fail(writer, "The Smart Trim encoder did not produce the indexed pictures");
        int code = mpcut_splice_encoded(packet, video->codecpar, patch->consumed == 0);
        if (code < 0)
            return ff_error(writer, code, "Cannot package encoded edge headers for", input->url);
        Wide absolute = (Wide)packet->pts + writer->video_origin_pts;
        if (packet->pts == AV_NOPTS_VALUE || absolute < patch->start_pts || absolute >= patch->end_pts ||
            (!writer->video_dts && dts != AV_NOPTS_VALUE && dts > absolute))
            return fail(writer, "A replacement picture cannot fit the source decode timestamps in %s", input->url);
        packet->pts = (int64_t)absolute;
        packet->dts = dts;
        packet->stream_index = index;
        patch->source_times[patch->consumed] = pts;
        patch->encoded_times[patch->consumed] = packet->pts;
        if (++patch->consumed == patch->plan.frame_count) {
            qsort(patch->source_times, patch->consumed, sizeof(int64_t), compare_pts);
            if (memcmp(patch->source_times, patch->encoded_times, patch->consumed * sizeof(int64_t)))
                return fail(writer, "Smart Trim changed a source picture’s presentation time in %s", input->url);
            av_freep(&patch->source_times);
            av_freep(&patch->encoded_times);
            mpcut_edge_free(patch->encoded);
            patch->encoded = NULL;
        }
        writer->restore_video_config = 1;
        return 0;
    }
    MPCutTime time = time_ticks(pts, video->time_base);
    if (!range->whole_file && (time_compare(time, range->source_start) < 0 || time_compare(time, range->source_end) >= 0)) {
        if (following)
            smart_follow(writer, video, packet);
        return 0;
    }
    // A range that starts from sets another range or the description does not hold switches to them.
    if (following && writer->smart_range_first && !writer->restore_video_config
        && (writer->smart_dirty || !mpcut_hevc_sets_initial(writer->smart_sets)))
        writer->restore_video_config = 1;
    writer->smart_range_first = 0;
    const uint8_t *extra = writer->active_config ? writer->active_config : video->codecpar->extradata;
    int size = writer->active_config ? (int)writer->active_config_size : video->codecpar->extradata_size;
    if (writer->smart_trim || writer->generated_stills) {
        int code = mpcut_splice_check_copy(packet, video->codecpar, extra, size);
        if (code == AVERROR(ENOTSUP))
            return fail(writer, "Smart Trim cannot preserve in-band parameter sets in copied AVC/HEVC samples from %s", input->url);
        if (code < 0)
            return ff_error(writer, code, "Invalid copied video sample or configuration in", input->url);
    }
    if (writer->generated_stills && video->codecpar->codec_id == AV_CODEC_ID_HEVC) {
        int code = mp_probe_check_still_hevc(packet->data, packet->size, extra, size);
        if (code == AVERROR(ENOTSUP))
            return fail(writer, "Generated stills require HEVC without Dolby Vision, HDR10+ or additional picture layers in %s", input->url);
        if (code < 0)
            return ff_error(writer, code, "Cannot verify HEVC sample metadata in", input->url);
    }
    int result = 0;
    if (writer->restore_video_config)
        result = smart_restore(writer, input, video, extra, size);
    else if (following && writer->smart_repeating && (packet->flags & AV_PKT_FLAG_KEY))
        result = smart_repeat(writer, video);
    if (result)
        return result;
    if (smart_following(writer, video, pts) && smart_follow(writer, video, packet))
        writer->smart_dirty = !mpcut_hevc_sets_initial(writer->smart_sets);
    return 0;
}

static int write_range(Writer *writer, AVFormatContext *input, const Range *range, double total_duration) {
    if (input->nb_streams != writer->range_track_count) {
        return fail(writer, "Track layout changed while reopening %s", input->url);
    }
    AVPacket *packet = writer->packet;
    int written_video = 0;
    int result;
    unsigned remaining = writer->selected_count;
    /* Neither source gives a held picture its presentation width: a MOV sample's duration is a
     * decode interval, and a Matroska block usually takes its track's default duration. The
     * index widens each picture to the next one, so the last picture of a range runs to its end. */
    int mov_video_timing = (av_match_name("mov", input->iformat->name) || av_match_name("matroska", input->iformat->name))
        && (is_mov(writer->output->oformat) || is_matroska(writer->output->oformat));
    double progress_shift = time_seconds(range->output_start) - time_seconds(range->source_start);
    double progress_end = time_seconds(range->output_end);
    memset(writer->range_tracks, 0, input->nb_streams);
    writer->hevc_range_start = 1;
    writer->sets_range_start = 1;
    // Smart Trim follows each range's source from the packet plan_stream_sets planned it at.
    mpcut_hevc_sets_free(writer->smart_sets);
    writer->smart_sets = NULL;
    writer->smart_unfollowed = 0;
    writer->smart_range_first = 1;
    writer->smart_repeating = 0;
    av_freep(&writer->tail_sets);
    writer->tail_sets_size = 0;
    if (writer->aac_source) {
        result = write_aac_source(writer, input, range, &remaining);
        if (result) {
            return result;
        }
    }

    if (range->opus_trim) {
        av_freep(&writer->opus_trim);
        writer->opus_trim = av_calloc(input->nb_streams, sizeof(*writer->opus_trim));
        if (!writer->opus_trim) {
            return fail(writer, "Cannot allocate Opus trim state");
        }
    }
    if (av_match_name(writer->output->oformat->name, "ogg,oga,opus")) {
        av_freep(&writer->opus_clock);
        writer->opus_clock = av_calloc(input->nb_streams, sizeof(*writer->opus_clock));
        if (!writer->opus_clock)
            return fail(writer, "Cannot allocate Opus sample clock");
    }

    for (unsigned index = 0; writer->aac_edits && index < input->nb_streams; index++) {
        const AVCodecParameters *codec = input->streams[index]->codecpar;
        if (writer->stream_map[index] >= 0 && codec->codec_id == AV_CODEC_ID_AAC && !range->whole_file && writer->range_tracks[index] != 2) {
            result = mpcut_aac_begin(writer->aac_edits, writer->stream_map[index], codec->sample_rate, range->source_start,
                                    range->output_start, range->output_end, writer->error, writer->error_capacity);
            if (result) {
                return result;
            }
        }
    }

    result = AVERROR_EOF;
    while (remaining && (writer->has_first_packet || (result = av_read_frame(input, packet)) >= 0)) {
        writer->has_first_packet = 0;
        if (input->nb_streams != writer->range_track_count || packet->stream_index < 0
            || (unsigned)packet->stream_index >= writer->range_track_count) {
            return fail(writer, "Track layout changed while reading %s", input->url);
        }
        if (writer->stream_map[packet->stream_index] < 0 || writer->range_tracks[packet->stream_index] == 2) {
            result = progress_at(writer, writer->fraction);
            if (result) {
                return result;
            }
            av_packet_unref(packet);
            continue;
        }
        unsigned input_index = packet->stream_index;
        if (writer->mp3_header != MP3_HEADER_DEFAULT) {
            size_t size = 0;
            uint8_t *side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &size);
            unsigned discard = side && size >= 10 ? AV_RL32(side + 4) : 0;
            // Demuxers distribute end padding over every affected frame. Its total goes
            // into the 12-bit LAME tag when the file is finished (mp3_finish_header).
            if (writer->mp3_end_discard) {
                const AVCodecParameters *codec = input->streams[input_index]->codecpar;
                unsigned frame_samples = codec->sample_rate > 24000 ? 1152 : 576;
                if (discard != frame_samples)
                    return fail(writer, "MP3 cannot preserve an interior gap on track %u.", input_index);
            }
            if (discard > 4095 - 529 - writer->mp3_end_discard || (discard && writer->mp3_header == MP3_HEADER_UNTAGGED))
                return fail(writer, "The MP3 header cannot preserve the trailing padding on track %u.", input_index);
            if (discard) {
                writer->mp3_end_discard += discard;
                AV_WL32(side + 4, 0);
            }
        }
        const AVStream *input_track = input->streams[input_index];
        int video = primary_video(input_track);
        packet->stream_index = writer->stream_map[input_index];
        int64_t source_pts = packet->pts;
        double fraction = writer->fraction;
        if (writer->progress && (video || writer->tracks == MPCUT_TRACKS_AUDIO) && source_pts != AV_NOPTS_VALUE) {
            // Only the progress estimate uses floating point. Muxed timestamps
            // and cut boundaries are still calculated on their rational clocks.
            double seconds = (double)source_pts * av_q2d(input_track->time_base) + progress_shift;
            fraction = (seconds < progress_end ? seconds : progress_end) / total_duration;
        }

        result = progress_at(writer, fraction);
        if (result) {
            return result;
        }

        if (video && (writer->smart_trim || writer->track_video_config)) {
            result = splice_video(writer, input, input_track, range);
            if (result)
                return result;
        }

        if (writer->aac_edits && !range->whole_file && input_track->codecpar->codec_id == AV_CODEC_ID_AAC) {
            AVRational output_base = writer->output->streams[packet->stream_index]->time_base;
            result = mpcut_aac_packet(writer->aac_edits, packet, input_track->time_base,
                                     output_base, 0, writer->error, writer->error_capacity);
        } else if (extra_track(input_track)) {
            result = remux_extra(writer, input_track, range);
        } else if (writer->opus_trim && input_track->codecpar->codec_id == AV_CODEC_ID_OPUS) {
            result = trim_opus_packet(writer, input_track, range, &writer->opus_trim[input_index]);
        } else if (writer->opus_clock && input_track->codecpar->codec_id == AV_CODEC_ID_OPUS) {
            int64_t exact;
            result = opus_sample_clock(writer, input_track, &writer->opus_clock[input_index], &exact);
            if (!result)
                result = remux_packet(writer, input_track, range, 0, 0);
            if (!result)
                result = place_opus_samples(writer, range, exact);
        } else {
            int frame_size = range->whole_file ? 0 : pcm_frame_size(input_track->codecpar);
            result = frame_size ? slice_pcm(writer, input_track, range, frame_size)
                                : remux_packet(writer, input_track, range, video, video && mov_video_timing);
        }
        if (result) {
            return result;
        }
        int retained = packet->size > 0;
        enum AVCodecID codec_id = input_track->codecpar->codec_id;
        if (retained && video && (codec_id == AV_CODEC_ID_H264 || codec_id == AV_CODEC_ID_HEVC)
            && (result = repeat_stream_sets(writer, input_track)))
            return result;
        if (retained && video && writer->avc_reorder > 0 && input_track->codecpar->codec_id == AV_CODEC_ID_H264
            && input_track->codecpar->extradata_size >= 5 && input_track->codecpar->extradata[0] == 1) {
            // A parameter set repeated in a sample declares the same depth as the track's (plan_avc_reorder).
            result = mpcut_avc_packet_declare_reorder(packet, (input_track->codecpar->extradata[4] & 3) + 1,
                                                      writer->avc_reorder);
            if (result < 0)
                return ff_error(writer, result, "Cannot declare the picture reorder depth in a sample from", input->url);
        }
        if (retained) {
            written_video |= video;
            if (input_track->codecpar->codec_id == AV_CODEC_ID_HEVC && (result = check_hvc1(writer, input_track)))
                return result;
            size_t entry_size = 0;
            const uint8_t *entry = video && writer->output_sets && !writer->sets_unfollowed
                ? av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &entry_size) : NULL;
            // A new sample entry (check_hvc1) gives the decoder its sets too, and is what a reader starting later has.
            if (entry) {
                int read = entry_size <= INT_MAX
                    && mpcut_hevc_sets_apply_config(writer->output_sets, entry, (int)entry_size) >= 0;
                mpcut_hevc_sets_free(writer->description_sets);
                writer->description_sets = !read ? NULL : codec_id == AV_CODEC_ID_HEVC
                    ? mpcut_hevc_sets_create(entry, (int)entry_size) : mpcut_avc_sets_create(entry, (int)entry_size);
                writer->sets_unfollowed |= !writer->description_sets;
            }
            result = write_packet(writer, input->url);
            if (result) {
                return result;
            }
        }
        if (!range->whole_file && !range->keep_audio_end && !writer->range_tracks[input_index]) {
            /* Validated video end edges split decode order as well as PTS.
             * Audio PTS is monotonic, and testing after selection preserves
             * packets still needed by a rounded sample-clock boundary. */
            MPCutTime pts = retained ? (MPCutTime){0, 0} : time_ticks(source_pts, input_track->time_base);
            int opus_finished = writer->opus_trim && input_track->codecpar->codec_id == AV_CODEC_ID_OPUS
                                && writer->opus_trim[input_index].finished;
            if (opus_finished || (pts.denominator && time_compare(pts, range->source_end) >= 0
                                  && (!video || !pending_patches(writer)))) {
                writer->range_tracks[input_index] = 1;
                remaining--;
            }
        }
        if (!range->whole_file && !range->keep_audio_end)
            remaining -= finish_extras(writer, input, range, time_ticks(source_pts, input_track->time_base));
        av_packet_unref(packet);
        if (!remaining) {
            result = AVERROR_EOF;
            break;
        }
    }

    if (result != AVERROR_EOF) {
        return ff_error(writer, result, "Cannot read packet from", input->url);
    }
    if (pending_patches(writer))
        return fail(writer, "The source ended before every Smart Trim edge picture was written");
    if (writer->tracks != MPCUT_TRACKS_AUDIO && !written_video) {
        return fail(writer, "No video samples in the selected range of %s", input->url);
    }
    for (unsigned index = 0; writer->opus_trim && index < input->nb_streams; index++) {
        if (writer->stream_map[index] >= 0 && input->streams[index]->codecpar->codec_id == AV_CODEC_ID_OPUS && (!writer->opus_trim[index].copied
                || (!range->keep_audio_end && !writer->opus_trim[index].finished))) {
            return fail(writer, "Opus track %u ends before the requested trim", index);
        }
    }
    for (unsigned index = 0; writer->aac_edits && index < input->nb_streams; index++) {
        if (writer->stream_map[index] >= 0 && input->streams[index]->codecpar->codec_id == AV_CODEC_ID_AAC && !range->whole_file
            && writer->range_tracks[index] != 2) {
            result = mpcut_aac_end(writer->aac_edits, writer->stream_map[index],
                                  writer->error, writer->error_capacity);
            if (result) {
                return result;
            }
        }
    }
    return 0;
}

static int validate_layout(Writer *writer, const AVFormatContext *input, int timecode_index) {
    int has_timecode = timecode_index >= 0;
    if (has_timecode != writer->has_timecode) {
        return fail(writer, "Timecode track presence changed in %s", input->url);
    }
    if (writer->selected_count + writer->art_streams != writer->output->nb_streams) {
        return fail(writer, "Track count changed in %s", input->url);
    }

    for (unsigned index = 0; index < input->nb_streams; index++) {
        if (writer->stream_map[index] < 0) {
            continue;
        }
        const AVCodecParameters *destination = writer->output->streams[writer->stream_map[index]]->codecpar;
        const AVCodecParameters *source = input->streams[index]->codecpar;
        if (source->codec_type != destination->codec_type || source->codec_id != destination->codec_id) {
            return fail(writer, "Track %u has a different codec in %s", index, input->url);
        }
    }
    return 0;
}

typedef struct {
    const char *path;
    MPCutAACTrackClock *clocks;
    unsigned track_count;
    MPCutAACSource *source;
} AACSourceCache;

static int selected_aac(const Writer *writer, const AVStream *stream) {
    return selected_stream(writer, stream) && stream->codecpar->codec_id == AV_CODEC_ID_AAC;
}

static int load_aac_source(Writer *writer, const AVFormatContext *input, const char *path,
                           AACSourceCache *cache) {
    writer->aac_source = NULL;
    if (writer->tracks == MPCUT_TRACKS_VIDEO || !av_match_name("mov", input->iformat->name))
        return 0;

    int matches = cache->path && !strcmp(cache->path, path);
    unsigned count = 0;
    for (unsigned index = 0; index < input->nb_streams; index++) {
        const AVStream *stream = input->streams[index];
        if (!selected_aac(writer, stream))
            continue;
        matches = matches && count < cache->track_count &&
            cache->clocks[count].track_id == stream->id &&
            cache->clocks[count].sample_rate == stream->codecpar->sample_rate;
        count++;
    }
    if (!count)
        return 0;

    if (!matches || count != cache->track_count) {
        av_freep(&cache->clocks);
        mpcut_aac_source_free(cache->source);
        *cache = (AACSourceCache){0};
        cache->clocks = av_calloc(count, sizeof(*cache->clocks));
        if (!cache->clocks)
            return fail(writer, "Cannot allocate AAC track clocks");
        unsigned track = 0;
        for (unsigned index = 0; index < input->nb_streams; index++) {
            const AVStream *stream = input->streams[index];
            if (selected_aac(writer, stream))
                cache->clocks[track++] = (MPCutAACTrackClock){stream->id, stream->codecpar->sample_rate};
        }
        int result = mpcut_aac_source_open(path, cache->clocks, count, &cache->source,
                                          writer->error, writer->error_capacity);
        if (result)
            return result;
        cache->path = path;
        cache->track_count = count;
    }
    writer->aac_source = cache->source;
    if (writer->aac_source && !is_mov(writer->output->oformat))
        return fail(writer, "Multiple AAC media edits in %s require MOV or MP4 output", path);
    return 0;
}

/* The reorder depth of the H.264 pictures one source can contribute. A MOV source states it for
 * the whole track in the composition offsets of its movie box (mov_estimate_video_delay). Other sources are read up
 * to `limit`, the furthest planned end, or to their end when it is invalid: write_range finishes a
 * video track at its first unretained packet presented at or after a range's end. */
static int source_reorder(Writer *writer, const char *path, MPCutTime limit, int *depth) {
    AVFormatContext *source = NULL;
    int result = input_open(writer, &source, path);
    if (result)
        return result;
    unsigned video = 0;
    while (video < source->nb_streams && !primary_video(source->streams[video]))
        video++;
    if (video == source->nb_streams || source->streams[video]->codecpar->codec_id != AV_CODEC_ID_H264) {
        avformat_close_input(&source);
        return 0; // validate_layout reports a source that does not match the first.
    }
    // Fragments are not in that estimate, so a MOV source that shows no reordering is read like any other.
    int delay = source->streams[video]->codecpar->video_delay;
    if (av_match_name("mov", source->iformat->name) && delay > 0) {
        *depth = delay > 16 ? 16 : delay;
        avformat_close_input(&source);
        return 0;
    }
    for (unsigned i = 0; i < source->nb_streams; i++)
        source->streams[i]->discard = i == video ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    AVRational base = source->streams[video]->time_base;
    AVPacket *packet = av_packet_alloc();
    MPCutReorderScan scan = {0};
    int code = packet ? 0 : AVERROR(ENOMEM);
    while (!code && (code = av_read_frame(source, packet)) >= 0) {
        code = 0;
        if ((unsigned)packet->stream_index == video && packet->pts != AV_NOPTS_VALUE) {
            if (limit.denominator > 0 && time_compare(time_ticks(packet->pts, base), limit) >= 0)
                code = AVERROR_EOF;
            else
                mpcut_reorder_scan_add(&scan, packet->pts);
        }
        av_packet_unref(packet);
        if (!code && (result = progress_at(writer, writer->fraction)))
            break;
    }
    av_packet_free(&packet);
    avformat_close_input(&source);
    if (result)
        return result;
    if (code != AVERROR_EOF)
        return ff_error(writer, code, "Cannot read the picture order of", path);
    *depth = scan.depth;
    return 0;
}

/* Matroska keeps no composition offsets. A reader of an H.264 track whose sequence parameter set
 * does not declare its reorder depth guesses it from the first pictures, and libavcodec drops a
 * picture where a later range reorders deeper. Find the depth that the copied pictures can need,
 * so that configure_output and write_range declare it in those parameter sets. */
static int plan_avc_reorder(Writer *writer, const MPCutSegment *segments, size_t count, const AVStream *video,
                            MPCutTime origin) {
    writer->avc_reorder = 0;
    const AVCodecParameters *codec = video->codecpar;
    if (!is_matroska(writer->output->oformat) || writer->tracks == MPCUT_TRACKS_AUDIO || !primary_video(video)
        || codec->codec_id != AV_CODEC_ID_H264 || !mpcut_avcc_needs_reorder(codec->extradata, codec->extradata_size))
        return 0;
    int depth = 0;
    for (size_t i = 0; i < count; i++) {
        size_t first = 0;
        while (strcmp(segments[first].path, segments[i].path))
            first++;
        if (first != i)
            continue; // Each source is read once, up to the furthest of its ends.
        MPCutTime limit = {0, 0};
        for (size_t j = i; j < count; j++) {
            if (strcmp(segments[j].path, segments[i].path))
                continue;
            MPCutTime start = !strcmp(segments[j].path, segments[0].path) ? origin : segments[j].source_origin;
            MPCutTime end = start.denominator > 0 ? time_add(start, segments[j].end, 1) : (MPCutTime){0, 0};
            if (segments[j].reaches_end || !end.denominator) {
                limit = (MPCutTime){0, 0};
                break;
            }
            if (!limit.denominator || time_compare(end, limit) > 0)
                limit = end;
        }
        int source_depth = 0;
        int result = source_reorder(writer, segments[i].path, limit, &source_depth);
        if (result)
            return result;
        if (source_depth > depth)
            depth = source_depth;
    }
    writer->avc_reorder = depth;
    return 0;
}

int mpcut_write(const MPCutSegment *segments, size_t count, const char *output_path, int tracks, int audio_stream,
                const uint32_t *still_mastering_display,
                MPCutProgress progress, void *context, char *error, size_t error_capacity) {
    Writer writer = {
        .still_mastering_display = still_mastering_display,
        .output_path = output_path,
        .progress = progress,
        .progress_context = context,
        .error = error,
        .error_capacity = error_capacity
    };
    const int program_audio = tracks == MPCUT_TRACKS_PROGRAM_AUDIO;
    const int linked_movie_clock = tracks == MPCUT_TRACKS_ALL || tracks == MPCUT_TRACKS_LINKED_AUDIO || program_audio;
    const int movie_chapters = tracks == MPCUT_TRACKS_ALL;
    set_delivery(&writer, tracks, audio_stream);
    tracks = track_selection(tracks);
    writer.tracks = tracks;
    writer.audio_stream = audio_stream;
    AVFormatContext *input = NULL;
    Chapters chapters = {0};
    // Cache the last selected AAC track set, including movies with no special edit list.
    AACSourceCache aac_cache = {0};
    int result;

    if (!segments || !count || !output_path) {
        return fail(&writer, "An output path and at least one segment are required");
    }
    if (tracks < 0)
        return fail(&writer, "Invalid track selection");
    MPCutTime total = {0, 1};
    for (size_t index = 0; index < count; index++) {
        const MPCutSegment *segment = &segments[index];
        if (!valid_segment_range(segment)) {
            return fail(&writer, "Segment %zu has an invalid range", index + 1);
        }
        if ((segment->opus_track_count && !segment->opus_pre_skip)
            || (segment->video_dts_count && !segment->video_dts)
            || (tracks == MPCUT_TRACKS_AUDIO && segment->audio_stream_override &&
                segment->audio_stream_override - 1 > INT_MAX)) {
            return fail(&writer, "Segment %zu has invalid track timing or selection", index + 1);
        }
        if (segment->audio_stream_override)
            writer.whole_sound = 0; // One chosen track per source is not the whole recording.
        writer.track_video_config |= segment->multiple_descriptions;
        writer.generated_stills |= segment->generated_still;
        writer.smart_trim |= segment->head_edge.frame_count > 0 || segment->tail_edge.frame_count > 0;
        total = time_add(total, time_add(segment->end, segment->start, -1), 1);
        if (!total.denominator) {
            return fail(&writer, "The requested duration cannot be represented");
        }
    }

    result = progress_at(&writer, 0);
    if (result) {
        return result;
    }
    result = prepare_output(&writer);
    if (result) {
        goto cleanup;
    }
    if (writer.generated_stills && (tracks != MPCUT_TRACKS_VIDEO || !is_mov(writer.output->oformat))) {
        result = fail(&writer, "Generated still spans require a separate MOV-family picture lane");
        goto cleanup;
    }
    if (writer.generated_stills && !writer.smart_trim) {
        writer.picture_hash = av_sha_alloc();
        if (!writer.picture_hash) {
            result = fail(&writer, "Cannot allocate still picture verification");
            goto cleanup;
        }
        av_sha_init(writer.picture_hash, 256);
    }
    if (!strcmp(writer.output->oformat->name, "flac") &&
        (count != 1 || segments[0].start.numerator != 0 || !segments[0].reaches_end)) {
        result = fail(&writer, "Use Matroska Audio (.mka) to preserve FLAC packets across edits.");
        goto cleanup;
    }
    writer.packet = av_packet_alloc();
    if (!writer.packet) {
        result = fail(&writer, "Cannot allocate working packet");
        goto cleanup;
    }

    MPCutTime cursor = {0, 1};
    for (size_t index = 0; index < count; index++) {
        const MPCutSegment *segment = &segments[index];
        writer.audio_stream = tracks == MPCUT_TRACKS_AUDIO && segment->audio_stream_override
            ? (int)(segment->audio_stream_override - 1) : audio_stream;
        result = input_open(&writer, &input, segment->path);
        if (result) {
            goto cleanup;
        }
        result = load_aac_source(&writer, input, segment->path, &aac_cache);
        if (result)
            goto cleanup;
        int timecode_index;
        MPCutTimecode timecode;
        result = validate_streams(&writer, input, &timecode_index, &timecode);
        if (result) {
            goto cleanup;
        }
        unsigned video_index = 0;
        MPCutTime origin = {0, 0};
        result = video_origin(&writer, &input, &video_index, segment->source_origin, &origin);
        if (result) {
            goto cleanup;
        }

        result = map_streams(&writer, input, timecode_index);
        if (result)
            goto cleanup;
        if (!index && (result = plan_avc_reorder(&writer, segments, count, input->streams[video_index], origin)))
            goto cleanup;
        if (!index && tracks != MPCUT_TRACKS_AUDIO && !writer.generated_stills) {
            writer.stream_sets = av_calloc(count, sizeof(*writer.stream_sets));
            writer.stream_sets_size = av_calloc(count, sizeof(*writer.stream_sets_size));
            writer.stream_start_pts = av_malloc_array(count, sizeof(*writer.stream_start_pts));
            if (!writer.stream_sets || !writer.stream_sets_size || !writer.stream_start_pts) {
                result = fail(&writer, "Cannot allocate output track state");
                goto cleanup;
            }
            for (size_t i = 0; i < count; i++)
                writer.stream_start_pts[i] = AV_NOPTS_VALUE;
            writer.stream_set_count = count;
            // A source that cannot be read here adds no sets; the copy reports its own failure to read it.
            if (plan_stream_sets(&writer, segments, count, writer.stream_sets, writer.stream_sets_size,
                                 writer.smart_trim ? writer.stream_start_pts : NULL) == -2) {
                result = 2;
                goto cleanup;
            }
            if (writer.error && writer.error_capacity)
                writer.error[0] = '\0';
        }
        if (!index && is_mov(writer.output->oformat) && tracks != MPCUT_TRACKS_AUDIO) {
            writer.hevc_early = av_calloc(count, sizeof(*writer.hevc_early));
            writer.hevc_early_size = av_calloc(count, sizeof(*writer.hevc_early_size));
            writer.hevc_videos = av_calloc(count, sizeof(*writer.hevc_videos));
            if (!writer.hevc_early || !writer.hevc_early_size || !writer.hevc_videos) {
                result = fail(&writer, "Cannot allocate output track state");
                goto cleanup;
            }
            writer.hevc_early_count = count;
            size_t found = 0;
            // A read that fails adds no sets, and each sample still meets check_hvc1's own rule.
            if (plan_hevc_sets(&writer, segments, count, input, writer.stream_sets, writer.stream_sets_size, 0,
                               writer.hevc_early, writer.hevc_early_size, writer.hevc_videos, &found) == -2) {
                result = 2;
                goto cleanup;
            }
            if (writer.error && writer.error_capacity)
                writer.error[0] = '\0';
        }
        Range range = {
            .matroska_input = av_match_name("matroska", input->iformat->name),
            .source_start = time_add(origin, segment->start, 1),
            .source_end = time_add(origin, segment->end, 1),
            .last_video_frame = time_add(origin, segment->last_video_frame, 1),
            .output_start = cursor,
            .output_end = time_add(cursor, time_add(segment->end, segment->start, -1), 1),
            .keep_audio_start = !program_audio && index == 0 && segment->start.numerator == 0,
            .keep_audio_end = !program_audio && index == count - 1 && segment->reaches_end,
            .whole_file = !program_audio && count == 1 && segment->start.numerator == 0 && segment->reaches_end,
            .whole_audio_selection = !linked_movie_clock && tracks == MPCUT_TRACKS_AUDIO,
            .opus_trim = count == 1 && (segment->start.numerator != 0 || !segment->reaches_end)
                && is_matroska(writer.output->oformat) &&
                (av_match_name("matroska", input->iformat->name) || av_match_name("ogg", input->iformat->name))
        };
        range.shift = time_add(range.output_start, range.source_start, -1);
        if (range.whole_file && linked_movie_clock && is_mov(writer.output->oformat)) {
            range.shift = time_add(range.shift, mov_audio_lead(segment), 1);
        }
        if (!range.shift.denominator || !range.source_start.denominator ||
            !range.source_end.denominator || !range.output_end.denominator) {
            result = fail(&writer, "Segment %zu timestamp cannot be represented", index + 1);
            goto cleanup;
        }
        if (segment->last_video_frame.denominator > 0
            && (!range.last_video_frame.denominator
                || time_compare(range.last_video_frame, range.source_start) < 0
                || time_compare(range.last_video_frame, range.source_end) >= 0)) {
            result = fail(&writer, "Segment %zu has invalid final video timing", index + 1);
            goto cleanup;
        }

        char initial_timecode[AV_TIMECODE_STR_SIZE] = {0};
        if (timecode_index >= 0) {
            result = check_timecode_range(&writer, input, timecode_index, &timecode, index,
                                          time_add(segment->end, segment->start, -1),
                                          range.source_start, time_add(range.source_start, range.shift, 1),
                                          total, initial_timecode);
            if (result) {
                goto cleanup;
            }
        }
        av_freep(&writer.range_tracks);
        writer.range_track_count = input->nb_streams;
        writer.range_tracks = av_calloc(writer.range_track_count, sizeof(*writer.range_tracks));
        if (!writer.range_tracks) {
            result = fail(&writer, "Cannot allocate track read state");
            goto cleanup;
        }
        /* A MOV description change can occur on a packet preceding the selected
         * range. Scan multi-description sources from their initial state so the
         * first retained picture gets the active configuration even after a trim. */
        if (segment->multiple_descriptions && !is_mov(writer.output->oformat)) {
            result = fail(&writer, "Multiple video sample descriptions require MOV or MP4 output");
            goto cleanup;
        }
        av_freep(&writer.active_config);
        writer.active_config_size = 0;
        if (writer.generated_stills && (input->streams[video_index]->codecpar->codec_id == AV_CODEC_ID_H264 ||
                input->streams[video_index]->codecpar->codec_id == AV_CODEC_ID_HEVC))
            writer.track_video_config = 1;
        if (writer.track_video_config)
            writer.restore_video_config = 1;
        result = segment->multiple_descriptions ? 0 :
            position_range(&writer, &input, segment->path, video_index, &range);
        if (result) {
            goto cleanup;
        }
        if (input->nb_streams != writer.range_track_count) {
            result = fail(&writer, "Track layout changed while seeking %s", segment->path);
            goto cleanup;
        }
        for (unsigned i = 0; i < input->nb_streams; i++)
            if (writer.stream_map[i] < 0)
                input->streams[i]->discard = AVDISCARD_ALL;
        if (!index && writer.delivered && plan_chapters(&writer, segments, count, input, origin, movie_chapters, &chapters) < 0) {
            result = fail(&writer, "Cannot allocate output chapters");
            goto cleanup;
        }
        result = index ? validate_layout(&writer, input, timecode_index)
                       : configure_output(&writer, input, range.whole_file, timecode_index, &timecode, initial_timecode,
                                          segment, &chapters);
        if (result) {
            goto cleanup;
        }
        result = tracks == MPCUT_TRACKS_AUDIO ? 0 : prepare_patches(&writer, input->streams[video_index], segment, origin);
        if (result)
            goto cleanup;
        writer.video_dts = segment->video_dts;
        writer.video_dts_count = segment->video_dts_count;
        writer.video_dts_used = 0;
        if (tracks == MPCUT_TRACKS_AUDIO && count == 1 && !range.whole_file &&
            !strcmp(input->iformat->name, "mp3") && !strcmp(writer.output->oformat->name, "mp3")) {
            AVRational samples = {1, input->streams[video_index]->codecpar->sample_rate};
            result = mpcut_write_mp3_crop(input, video_index, writer.output,
                                          time_round(range.source_start, samples), time_round(range.source_end, samples),
                                          segment->mp3_anchor, progress, context,
                                          &writer.mp3_skip, &writer.mp3_end_discard, error, error_capacity);
            writer.mp3_header = MP3_HEADER_GAPLESS;
        } else {
            writer.hevc_range = index;
            writer.hevc_range_video = writer.hevc_videos ? writer.hevc_videos[index] : -1;
            result = write_range(&writer, input, &range, time_seconds(total));
        }
        if (result) {
            goto cleanup;
        }

        if (tracks != MPCUT_TRACKS_AUDIO && writer.video_dts_used != writer.video_dts_count) {
            result = fail(&writer, "Fewer video samples than indexed in the Smart Trim edit");
            goto cleanup;
        }

        avformat_close_input(&input);
        cursor = range.output_end;
    }

    {
        int code = av_write_trailer(writer.output);
        if (code < 0) {
            result = ff_error(&writer, code, "Cannot finish writing", output_path);
            goto cleanup;
        }
        code = avio_closep(&writer.output->pb);
        if (code < 0) {
            result = ff_error(&writer, code, "Cannot close", output_path);
            goto cleanup;
        }
    }
    if (writer.mp3_header != MP3_HEADER_DEFAULT) {
        result = mp3_finish_header(&writer);
        if (result) {
            goto cleanup;
        }
    }
    if (writer.mov_chapter_clock) {
        result = mpcut_mov_finish_chapters(output_path, writer.mov_chapter_clock, error, error_capacity);
        if (result) {
            goto cleanup;
        }
    }
    if (writer.aac_edits) {
        result = mpcut_aac_finalize(writer.aac_edits, output_path, error, error_capacity);
        if (result) {
            goto cleanup;
        }
    }
    // After every pass that rewrites the movie box, so that it is still the file's last box.
    if (is_mov(writer.output->oformat) && tracks != MPCUT_TRACKS_AUDIO &&
        (result = mpcut_mov_cover_edits(output_path, total, error, error_capacity)))
        goto cleanup;
    if (writer.hvc1 && (result = label_hvc1(&writer)))
        goto cleanup;
    if (writer.picture_hash && (result = verify_picture(&writer, total)))
        goto cleanup;
    result = progress_at(&writer, 1);

cleanup:
    for (unsigned i = 0; i < 2; i++) {
        mpcut_edge_free(writer.patches[i].encoded);
        av_free(writer.patches[i].source_times);
        av_free(writer.patches[i].encoded_times);
    }
    av_free(writer.active_config);
    av_free(writer.picture_hash);
    av_free(writer.picture_config);
    avformat_close_input(&input);
    av_packet_free(&writer.packet);
    av_free(aac_cache.clocks);
    mpcut_aac_source_free(aac_cache.source);
    mpcut_aac_free(writer.aac_edits);
    av_free(writer.last_dts);
    av_free(writer.opus_trim);
    av_free(writer.opus_clock);
    for (unsigned i = 0; writer.hevc_sets && i < writer.hevc_set_count; i++)
        mpcut_hevc_sets_free(writer.hevc_sets[i]);
    av_free(writer.hevc_sets);
    for (size_t i = 0; writer.hevc_early && i < writer.hevc_early_count; i++)
        av_free(writer.hevc_early[i]);
    av_free(writer.hevc_early);
    av_free(writer.hevc_early_size);
    av_free(writer.hevc_videos);
    for (size_t i = 0; writer.stream_sets && i < writer.stream_set_count; i++)
        av_free(writer.stream_sets[i]);
    av_free(writer.stream_sets);
    av_free(writer.stream_sets_size);
    mpcut_hevc_sets_free(writer.output_sets);
    mpcut_hevc_sets_free(writer.description_sets);
    av_free(writer.stream_start_pts);
    mpcut_hevc_sets_free(writer.smart_sets);
    av_free(writer.tail_sets);
    av_free(writer.hvc1);
    av_free(writer.range_tracks);
    av_free(writer.stream_map);
    av_free(writer.art);
    free_chapters(&chapters);
    if (writer.output) {
        avio_closep(&writer.output->pb);
        avformat_free_context(writer.output);
    }
    return result;
}

static void add_note(char *notes, size_t capacity, const char *format, ...) {
    size_t used = strlen(notes);
    if (used + 2 >= capacity)
        return;
    if (used)
        notes[used++] = '\n';
    va_list args;
    va_start(args, format);
    vsnprintf(notes + used, capacity - used, format, args);
    va_end(args);
}

/* The bytes of a cover picture, or of an attached file. */
static const uint8_t *carried(const AVStream *stream, int files, int *size) {
    if (!(files ? attached_file(stream) : attached_picture(stream)))
        return NULL;
    *size = files ? stream->codecpar->extradata_size : stream->attached_pic.size;
    return files ? stream->codecpar->extradata : stream->attached_pic.data;
}

/* Pictures, or attached files, in a later source that the first source, whose own the copy keeps, does not also carry. */
static unsigned unmatched(const AVFormatContext *first, const AVFormatContext *later, int files) {
    unsigned count = 0;
    for (unsigned i = 0; i < later->nb_streams; i++) {
        int size = 0, kept_size = 0;
        const uint8_t *data = carried(later->streams[i], files, &size);
        if (!data)
            continue;
        int matched = 0;
        for (unsigned j = 0; j < first->nb_streams && !matched; j++) {
            const uint8_t *kept = carried(first->streams[j], files, &kept_size);
            matched = kept && kept_size == size && size > 0 && !memcmp(kept, data, (size_t)size);
        }
        count += !matched;
    }
    return count;
}

/* Say when an HEVC picture copied into MOV or MP4 keeps an 'hev1' description (plan_hevc_sets), with the ranges
 * starting from the sets their sources hold there as the copy does (plan_stream_sets). */
/* What a copy into MOV or MP4 does not keep of a source's timecode: breaks inside a kept range, which the single
   output sample counts over; the 24-hour wrap and negative flags, which the muxer cannot set; a count per field pair,
   which becomes a count per frame; and a timecode tag of a source without a timecode track, for which no track is
   written. Readings inside the kept ranges stay the same except across a break. */
static void note_timecode(const Writer *writer, const MPCutSegment *segments, size_t count, int tracks,
                          const char *container, char *notes, size_t capacity) {
    if (!av_match_name(writer->output->oformat->name, "mov,mp4") || (tracks != MPCUT_TRACKS_ALL && !writer->keep_timecode))
        return;
    unsigned breaks = 0, flags = 0, pairs = 0, tags = 0;
    for (size_t at = 0; at < count; at++) {
        AVFormatContext *input = NULL;
        if (avformat_open_input(&input, segments[at].path, NULL, NULL) < 0)
            continue;
        const AVStream *video = NULL, *track = NULL;
        for (unsigned i = 0; i < input->nb_streams; i++) {
            if (!video && input->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !attached_picture(input->streams[i]))
                video = input->streams[i];
            if (!track && timecode_track(input->streams[i]))
                track = input->streams[i];
        }
        // The MOV header states the picture rate the timecode is described with, as the writer reads it.
        MPCutTimecode timecode;
        if (track && video && av_match_name("mov", input->iformat->name) && !mpcut_timecode_describe(track, video, &timecode)) {
            MPCutTime origin = segments[at].source_origin.denominator > 0 ? segments[at].source_origin : (MPCutTime){0, 1};
            breaks += mpcut_timecode_breaks(segments[at].path, (unsigned)track->index, &timecode,
                                            time_add(origin, segments[at].start, 1), time_add(origin, segments[at].end, 1));
            flags += (timecode.flags & (AV_TIMECODE_FLAG_24HOURSMAX | AV_TIMECODE_FLAG_ALLOWNEGATIVE)) != 0;
            pairs += timecode.frames_per_count > 1;
        } else if (!track && (av_dict_get(input->metadata, "timecode", NULL, 0)
                              || (video && av_dict_get(video->metadata, "timecode", NULL, 0)))) {
            tags++;
        }
        avformat_close_input(&input);
    }
    if (breaks)
        add_note(notes, capacity, "The source timecode has %u break%s inside the kept range%s. The copied timecode track "
                 "counts on from each range start and does not keep %s.", breaks, breaks == 1 ? "" : "s",
                 count == 1 ? "" : "s", breaks == 1 ? "it" : "them");
    if (flags)
        add_note(notes, capacity, "%s timecode cannot state the source's 24-hour wrap or negative-time flag, which is not copied.",
                 container);
    if (pairs)
        add_note(notes, capacity, "The source timecode counts once per field pair. The copy counts once per frame and shows the same readings.");
    if (tags)
        add_note(notes, capacity, "The source's timecode tag has no timecode track to come from, so %s keeps no timecode for it.",
                 container);
}

/* Matroska carries HDR10+ and SMPTE 2094 dynamic metadata, LCEVC enhancement data and other block additions with each
   picture. Only a Matroska copy writes them, so another container leaves them out. */
static void note_block_data(const Writer *writer, const AVFormatContext *input, const char *container,
                            char *notes, size_t capacity) {
    if (writer->tracks == MPCUT_TRACKS_AUDIO || is_matroska(writer->output->oformat)
        || !av_match_name("matroska", input->iformat->name))
        return;
    AVFormatContext *reader = NULL;
    AVPacket *packet = av_packet_alloc();
    if (!packet || avformat_open_input(&reader, input->url, NULL, NULL) < 0) {
        av_packet_free(&packet);
        return;
    }
    static const struct { enum AVPacketSideDataType type; const char *name; } kinds[] = {
        {AV_PKT_DATA_DYNAMIC_HDR10_PLUS, "HDR10+ dynamic metadata"},
        {AV_PKT_DATA_DYNAMIC_HDR_SMPTE_2094_APP5, "SMPTE 2094 dynamic HDR metadata"},
        {AV_PKT_DATA_LCEVC, "LCEVC enhancement data"},
        {AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL, "Matroska block additions"},
    };
    unsigned found[sizeof(kinds) / sizeof(kinds[0])] = {0};
    int track[sizeof(kinds) / sizeof(kinds[0])] = {0};
    unsigned pictures = 0;
    // The first pictures show whether a stream carries them.
    while (pictures < 48 && av_read_frame(reader, packet) >= 0) {
        const AVStream *stream = reader->streams[packet->stream_index];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !attached_picture(stream)) {
            pictures++;
            for (size_t k = 0; k < sizeof(kinds) / sizeof(kinds[0]); k++) {
                if (!found[k] && av_packet_side_data_get(packet->side_data, packet->side_data_elems, kinds[k].type)) {
                    found[k] = 1;
                    track[k] = packet->stream_index;
                }
            }
        }
        av_packet_unref(packet);
    }
    for (size_t k = 0; k < sizeof(kinds) / sizeof(kinds[0]); k++) {
        if (found[k])
            add_note(notes, capacity, "%s cannot carry the %s of track %d, which %s not copied.", container, kinds[k].name,
                     track[k], k == 3 ? "are" : "is");
    }
    av_packet_free(&packet);
    avformat_close_input(&reader);
}

/* A QuickTime movie describes a 360° projection only in its vexu box, which has no cube map or tiled
   equirectangular form, so the muxer leaves such a projection out with only a log line. MP4 and Matroska keep it. */
static void note_projection(const Writer *writer, const AVFormatContext *input, const char *container,
                            char *notes, size_t capacity) {
    if (writer->tracks == MPCUT_TRACKS_AUDIO || strcmp(writer->output->oformat->name, "mov") != 0)
        return;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        const AVCodecParameters *codec = input->streams[i]->codecpar;
        const AVPacketSideData *side = av_packet_side_data_get(codec->coded_side_data, codec->nb_coded_side_data,
                                                               AV_PKT_DATA_SPHERICAL);
        if (codec->codec_type != AVMEDIA_TYPE_VIDEO || !side)
            continue;
        const AVSphericalMapping *mapping = (const AVSphericalMapping *)side->data;
        if (mapping->projection == AV_SPHERICAL_CUBEMAP || mapping->projection == AV_SPHERICAL_EQUIRECTANGULAR_TILE)
            add_note(notes, capacity, "%s cannot describe the 360° projection of track %u, which is not copied. "
                     "Choose MP4 or MKV to keep it.", container, i);
    }
}

/* A QuickTime or MP4 colour box holds one description. With an ICC profile the copy writes the profile, and the
   primaries, transfer and matrix tags beside it are left out of the container (the coded stream keeps its own). */
static void note_color_box(const Writer *writer, const AVFormatContext *input, const char *container,
                           char *notes, size_t capacity) {
    if (writer->tracks == MPCUT_TRACKS_AUDIO || !av_match_name(writer->output->oformat->name, "mov,mp4,ipod"))
        return;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        const AVCodecParameters *codec = input->streams[i]->codecpar;
        if (codec->codec_type != AVMEDIA_TYPE_VIDEO || attached_picture(input->streams[i]))
            continue;
        if (!av_packet_side_data_get(codec->coded_side_data, codec->nb_coded_side_data, AV_PKT_DATA_ICC_PROFILE))
            continue;
        if (codec->color_primaries == AVCOL_PRI_UNSPECIFIED && codec->color_trc == AVCOL_TRC_UNSPECIFIED
            && codec->color_space == AVCOL_SPC_UNSPECIFIED)
            continue;
        add_note(notes, capacity, "%s keeps one colour description for track %u: its ICC profile is copied and its "
                 "primaries, transfer and matrix tags are not.", container, i);
    }
    // A QuickTime nclc box has no range byte. H.264, HEVC and JPEG pictures state their range themselves.
    if (strcmp(writer->output->oformat->name, "mov") != 0)
        return;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        const AVCodecParameters *codec = input->streams[i]->codecpar;
        if (codec->codec_type != AVMEDIA_TYPE_VIDEO || attached_picture(input->streams[i])
            || codec->color_range != AVCOL_RANGE_JPEG || codec->codec_id == AV_CODEC_ID_H264
            || codec->codec_id == AV_CODEC_ID_HEVC || codec->codec_id == AV_CODEC_ID_MJPEG)
            continue;
        add_note(notes, capacity, "%s colour tags have no range, so the full-range flag of track %u is not copied.",
                 container, i);
    }
}

/* Movie metadata the MOV or MP4 muxer has no field for. Without the mdta form, a QuickTime movie keeps only the
   classic user-data keys and an MP4 only the iTunes list, so camera keys such as com.apple.quicktime.make are left
   out even of a copy into the same container. Keys the muxer writes itself (brands, creation time, the writing
   tool) are not named. */
static void note_metadata(const Writer *writer, const AVFormatContext *input, const char *container,
                          char *notes, size_t capacity) {
    static const char *const managed[] = {"major_brand", "minor_version", "compatible_brands", "creation_time",
                                          "encoder", "encoding_tool", "software", "timecode", NULL};
    static const char *const mov_keys[] = {"artist", "title", "author", "album", "date", "comment", "genre", "copyright",
                                           "make", "model", "location", "keywords", "xmp", NULL};
    static const char *const mp4_keys[] = {"title", "artist", "album_artist", "composer", "album", "date", "encoding_tool",
                                           "comment", "genre", "copyright", "grouping", "lyrics", "description", "synopsis",
                                           "show", "episode_id", "network", "keywords", "episode_sort", "season_number",
                                           "media_type", "hd_video", "gapless_playback", "compilation", "track", "disc",
                                           "tmpo", "disc_subtitle", "location", NULL};
    const char *name = writer->output->oformat->name;
    const char *const *kept = !strcmp(name, "mov") ? mov_keys : (!strcmp(name, "mp4") || !strcmp(name, "ipod")) ? mp4_keys : NULL;
    if (!kept)
        return;
    char omitted[512] = "";
    unsigned count = 0;
    const AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_iterate(input->metadata, entry))) {
        char key[128];
        snprintf(key, sizeof(key), "%s", entry->key);
        // A language variant ("title-eng") is written with its key.
        size_t length = strlen(key);
        if (length > 4 && key[length - 4] == '-')
            key[length - 4] = '\0';
        int known = 0;
        for (const char *const *item = managed; *item && !known; item++)
            known = !av_strcasecmp(key, *item);
        for (const char *const *item = kept; *item && !known; item++)
            known = !av_strcasecmp(key, *item);
        if (known)
            continue;
        if (count < 6)
            av_strlcatf(omitted, sizeof(omitted), "%s%s", count ? ", " : "", entry->key);
        count++;
    }
    if (count > 6)
        av_strlcatf(omitted, sizeof(omitted), " and %u more", count - 6);
    if (count)
        add_note(notes, capacity, "%s cannot hold the movie metadata %s, which %s not copied.",
                 container, omitted, count == 1 ? "is" : "are");
}

static void note_hevc_entry(Writer *writer, const MPCutSegment *segments, size_t count, const AVFormatContext *input,
                            char *notes, size_t capacity) {
    size_t at = 0;
    uint8_t **early = av_calloc(count, sizeof(*early)), **stream = av_calloc(count, sizeof(*stream));
    int *early_size = av_calloc(count, sizeof(*early_size)), *videos = av_calloc(count, sizeof(*videos));
    int *stream_size = av_calloc(count, sizeof(*stream_size));
    int fallback = early && early_size && videos && stream && stream_size
        ? plan_hevc_sets(writer, segments, count, input, stream, stream_size, 1, early, early_size, videos, &at)
        : HEVC_SETS_SAME;
    for (size_t i = 0; i < count; i++) {
        av_free(early ? early[i] : NULL);
        av_free(stream ? stream[i] : NULL);
    }
    av_free(early);
    av_free(early_size);
    av_free(videos);
    av_free(stream);
    av_free(stream_size);
    if (fallback == HEVC_SETS_GROUP_CHANGE || fallback == HEVC_SETS_UNREADABLE) {
        const char *name = strrchr(segments[at].path, '/');
        name = name ? name + 1 : segments[at].path;
        if (fallback == HEVC_SETS_GROUP_CHANGE)
            add_note(notes, capacity, "HEVC parameter sets change mid-picture-group in %s, so the copy uses an hev1 "
                     "description that AVFoundation and QuickTime cannot play; FFmpeg-based players can.", name);
        else
            add_note(notes, capacity, "The HEVC parameter sets in the samples of %s cannot be followed, so the copy uses an "
                     "hev1 description that AVFoundation and QuickTime cannot play; FFmpeg-based players can.", name);
    } else if (fallback == -1) {
        // The copy reads the same samples with the same rule (check_hvc1); here they could not be read at all.
        add_note(notes, capacity, "The HEVC samples could not be read to check their parameter sets before writing, so "
                 "the copy may use an hev1 description that AVFoundation and QuickTime cannot play.");
    }
}

/* Whether a sample with `length_size`-byte NAL lengths carries a parameter set (`sets`), or a NAL unit of a picture
 * layer above the base layer: for HEVC one with a nonzero layer ID, for H.264 a sequence parameter set extension, a
 * subset sequence parameter set, a prefix unit, an auxiliary picture or an MVC/SVC slice. */
static int sample_carries(const AVCodecParameters *codec, const AVPacket *packet, int length_size, int sets) {
    int hevc = codec->codec_id == AV_CODEC_ID_HEVC;
    for (int i = 0; i + length_size < packet->size;) {
        uint32_t length = 0;
        for (int k = 0; k < length_size; k++)
            length = length << 8 | packet->data[i + k];
        i += length_size;
        if (!length || length > (uint32_t)(packet->size - i))
            return 0;
        const uint8_t *nal = packet->data + i;
        unsigned type = hevc ? (nal[0] >> 1) & 0x3f : nal[0] & 0x1f;
        if (sets ? (hevc ? type >= 32 && type <= 34 : type == 7 || type == 8 || type == 13 || type == 15)
                 : (hevc ? length >= 2 && ((nal[0] & 1) << 5 | nal[1] >> 3) != 0
                         : type == 13 || type == 14 || type == 15 || type == 19 || type == 20 || type == 21))
            return 1;
        i += (int)length;
    }
    return 0;
}

/* Whether an avcC record of a high profile lists sequence parameter set extensions after its picture parameter
 * sets, which describe an auxiliary picture. */
static int avcc_extensions(const uint8_t *config, int size) {
    if (!config || size < 7 || config[0] != 1 || config[1] == 66 || config[1] == 77 || config[1] == 88)
        return 0;
    const uint8_t *p = config + 5, *end = config + size;
    for (int kind = 0; kind < 2; kind++) {
        if (end - p < 1)
            return 0;
        unsigned count = kind ? p[0] : p[0] & 0x1f;
        p++;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2 || end - p - 2 < AV_RB16(p))
                return 0;
            p += 2 + AV_RB16(p);
        }
    }
    return end - p >= 7 && p[3] > 0 && (p[6] & 0x1f) == 13;
}

/* Say when the parameter sets of an H.264 or HEVC picture cannot be followed through the samples the copy reads
 * (plan_stream_sets, repeat_stream_sets), which then start each range from its source's description and stop
 * repeating sets at later keyframes. Reads on only for a source whose sets could need following: one whose
 * description the tracker cannot read, whose first sample carries parameter sets, or whose description or first
 * sample shows another layer (HEVC with the sets of a higher layer, such as an MV-HEVC view or an alpha layer, or
 * H.264 with auxiliary pictures, MVC or SVC). Its video packets are read up to the latest range end, and the note
 * is given only when a sample there carries a parameter set that is not followed. A single copy of a whole file
 * starts nothing mid-stream and is not read. */
static void note_unfollowed_sets(const MPCutSegment *segments, size_t count, char *notes, size_t capacity) {
    AVPacket *packet = av_packet_alloc();
    for (size_t first = 0; packet && first < count; first++) {
        size_t seen = 0;
        while (strcmp(segments[seen].path, segments[first].path))
            seen++;
        if (seen != first || (count == 1 && segments[0].start.numerator == 0 && segments[0].reaches_end))
            continue;
        // The file header gives each track's description; a plan reads no more of an ordinary source than its first
        // video packet.
        AVFormatContext *input = NULL;
        if (avformat_open_input(&input, segments[first].path, NULL, NULL) < 0)
            continue;
        unsigned index = 0;
        while (index < input->nb_streams && !primary_video(input->streams[index]))
            index++;
        const AVStream *track = index < input->nb_streams ? input->streams[index] : NULL;
        const AVCodecParameters *codec = track ? track->codecpar : NULL;
        int hevc = codec && codec->codec_id == AV_CODEC_ID_HEVC;
        if (!codec || (!hevc && codec->codec_id != AV_CODEC_ID_H264) || codec->extradata_size < (hevc ? 23 : 7)
            || codec->extradata[0] != 1) {
            avformat_close_input(&input);
            continue;
        }
        for (unsigned j = 0; j < input->nb_streams; j++)
            input->streams[j]->discard = j == index ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
        MPCutTime end = {0, 0};
        for (size_t i = first; i < count; i++) {
            if (strcmp(segments[i].path, segments[first].path) || segments[i].generated_still)
                continue;
            MPCutTime origin = segments[i].source_origin.denominator > 0 ? segments[i].source_origin
                : track->start_time != AV_NOPTS_VALUE ? time_ticks(track->start_time, track->time_base)
                : (MPCutTime){0, 1};
            MPCutTime range_end = time_add(origin, segments[i].end, 1);
            if (range_end.denominator && (!end.denominator || time_compare(range_end, end) > 0))
                end = range_end;
        }
        int length_size = sample_length_size(codec);
        const char *layers = hevc ? mpcut_hevc_layers(codec->extradata, codec->extradata_size) : NULL;
        int layered = layers || (!hevc && avcc_extensions(codec->extradata, codec->extradata_size));
        MPCutHevcSets *sets = stream_sets_create(codec);
        int unfollowed = 0, followed = layered || !sets;
        for (int read = 0; end.denominator && !unfollowed && av_read_frame(input, packet) >= 0; read++) {
            MPCutTime pts = packet->pts == AV_NOPTS_VALUE ? (MPCutTime){0, 0} : time_ticks(packet->pts, track->time_base);
            if ((unsigned)packet->stream_index == index && packet->size > 0) {
                if (!read && !followed) {
                    layered = sample_carries(codec, packet, length_size, 0);
                    followed = layered || sample_carries(codec, packet, length_size, 1);
                }
                if (!followed) {
                    av_packet_unref(packet);
                    break;
                }
                if (pts.denominator && time_compare(pts, end) >= 0) {
                    av_packet_unref(packet);
                    break;
                }
                unfollowed = sets ? mpcut_hevc_sets_apply_sample(sets, packet->data, packet->size, length_size) < 0
                                  : sample_carries(codec, packet, length_size, 1);
            }
            av_packet_unref(packet);
        }
        mpcut_hevc_sets_free(sets);
        avformat_close_input(&input);
        if (unfollowed) {
            const char *name = strrchr(segments[first].path, '/');
            const char *what = layers ? layers : !layered ? NULL
                : hevc ? "its additional picture layers" : "its auxiliary, MVC or SVC pictures";
            add_note(notes, capacity, "MPCut cannot follow the parameter sets that the samples of %s carry%s%s, so a "
                     "range that starts after the source changes them starts from the sets of its description instead, "
                     "and its first pictures may not decode.", name ? name + 1 : segments[first].path,
                     what ? " for " : "", what ? what : "");
        }
    }
    av_packet_free(&packet);
}

/* Say when a Matroska copy of H.264 with reordered pictures cannot declare their reorder depth (plan_avc_reorder),
 * because a sequence parameter set of the description leaves it undeclared in a form that cannot be rewritten. A
 * Matroska reader then guesses the depth from the first pictures and can drop one where a later group reorders
 * deeper. Reads the file headers only. */
static void note_avc_reorder(const char *output_format, const MPCutSegment *segments, size_t count, char *notes,
                             size_t capacity) {
    if (!av_match_name(output_format, "matroska,webm"))
        return;
    for (size_t first = 0; first < count; first++) {
        size_t seen = 0;
        while (strcmp(segments[seen].path, segments[first].path))
            seen++;
        AVFormatContext *input = NULL;
        if (seen != first || avformat_open_input(&input, segments[first].path, NULL, NULL) < 0)
            continue;
        for (unsigned i = 0; i < input->nb_streams; i++) {
            const AVCodecParameters *codec = input->streams[i]->codecpar;
            if (!primary_video(input->streams[i]) || codec->codec_id != AV_CODEC_ID_H264 || codec->video_delay <= 0
                || !mpcut_avcc_reorder_unknown(codec->extradata, codec->extradata_size))
                continue;
            const char *name = strrchr(segments[first].path, '/');
            add_note(notes, capacity, "The H.264 picture of %s reorders pictures without declaring how deeply, in a form "
                     "MPCut cannot add the declaration to, so a Matroska reader may drop a picture where a later group "
                     "reorders deeper. MOV and MP4 keep every picture.", name ? name + 1 : segments[first].path);
            break;
        }
        avformat_close_input(&input);
    }
}

int mpcut_copy_omissions(const MPCutSegment *segments, size_t count, const char *output_path,
                         int tracks, int audio_stream, char *notes, size_t capacity) {
    if (!notes || !capacity)
        return 1;
    notes[0] = '\0';
    Writer writer = {.output_path = output_path, .tracks = track_selection(tracks), .audio_stream = audio_stream};
    if (!segments || !count || !output_path || writer.tracks < 0)
        return 1;
    set_delivery(&writer, tracks, audio_stream);
    for (size_t i = 0; i < count; i++) {
        if (!valid_segment_range(&segments[i]))
            return 1;
        if (segments[i].audio_stream_override)
            writer.whole_sound = 0;
    }
    if (!writer.delivered && writer.tracks != MPCUT_TRACKS_VIDEO)
        return 0;
    if (!writer.delivered) {
        // A staged picture (a multicam program's lane) carries neither chapters nor art, but its copied HEVC samples
        // and their description go on into the delivered file.
        AVFormatContext *input = NULL;
        int result = prepare_output(&writer) || avformat_open_input(&input, segments[0].path, NULL, NULL) < 0;
        if (!result) {
            note_hevc_entry(&writer, segments, count, input, notes, capacity);
            note_unfollowed_sets(segments, count, notes, capacity);
        }
        avformat_close_input(&input);
        avformat_free_context(writer.output);
        return result;
    }

    AVFormatContext *input = NULL;
    Chapters chapters = {0};
    int result = prepare_output(&writer) || avformat_open_input(&input, segments[0].path, NULL, NULL) < 0;
    if (!result) {
        char container[16] = "this format";
        const char *extension = strrchr(output_path, '.');
        if (extension && extension[1] && strlen(extension + 1) < sizeof(container)) {
            size_t length = strlen(extension + 1);
            for (size_t i = 0; i <= length; i++)
                container[i] = (char)av_toupper(extension[1 + i]);
        }

        unsigned kept = 0, kept_files = 0;
        unsigned dropped = plan_art(&writer, input, NULL, &kept);
        unsigned dropped_files = plan_files(&writer, input, NULL, &kept_files);
        unsigned later = 0, later_files = 0;
        int movie = !sound_only(input);
        if (!whole_recording(&writer, input)) {
            // One chosen audio track, or the picture or the sound of a movie, is copied on its own.
            unsigned pictures = 0, files = 0, extras = 0;
            for (unsigned i = 0; i < input->nb_streams; i++) {
                pictures += attached_picture(input->streams[i]);
                files += attached_file(input->streams[i]);
                extras += movie && extra_track(input->streams[i]);
            }
            const char *whole = movie ? "both the picture and the sound of a movie" : "all the audio tracks of a sound-only file";
            if (pictures) {
                add_note(notes, capacity, "Cover art is copied only with %s. "
                         "%u embedded picture%s not copied.", whole, pictures, pictures == 1 ? " is" : "s are");
            }
            if (files) {
                add_note(notes, capacity, "Attached files are copied only with %s. "
                         "%u attached file%s not copied.", whole, files, files == 1 ? " is" : "s are");
            }
            if (extras) {
                add_note(notes, capacity, "Subtitle and data tracks are copied only with %s. "
                         "%u track%s not copied.", whole, extras, extras == 1 ? " is" : "s are");
            }
        } else if (movie) {
            // Name each subtitle or data track that this container, or the copy, cannot keep whole (carried_extra).
            int whole = count == 1 && segments[0].start.numerator == 0 && segments[0].reaches_end;
            for (unsigned i = 0; i < input->nb_streams; i++) {
                const AVStream *stream = input->streams[i];
                if (!extra_track(stream))
                    continue;
                const AVCodecParameters *codec = stream->codecpar;
                int data = codec->codec_type == AVMEDIA_TYPE_DATA;
                char name[AV_FOURCC_MAX_STRING_SIZE];
                if (data && codec->codec_tag)
                    av_fourcc_make_string(name, codec->codec_tag);
                else
                    snprintf(name, sizeof(name), "%s", avcodec_get_name(codec->codec_id));
                if (!carried_extra(writer.output->oformat, stream)) {
                    add_note(notes, capacity, "%s track %u (%s) cannot be copied to %s and is left out.",
                             data ? "Data" : "Subtitle", i, name, container);
                } else if (data && !whole) {
                    add_note(notes, capacity, "Data track %u (%s) keeps only the samples that lie wholly inside the kept ranges.",
                             i, name);
                }
            }
        }
        if (whole_recording(&writer, input)) {
            for (size_t at = 1; at < count; at++) {
                size_t source = 0;
                while (strcmp(segments[source].path, segments[at].path))
                    source++;
                if (source != at)
                    continue; // Counted where this file first appears.
                AVFormatContext *other = NULL;
                if (avformat_open_input(&other, segments[at].path, NULL, NULL) < 0)
                    continue;
                if (sound_only(other) == !movie) {
                    later += unmatched(input, other, 0);
                    later_files += unmatched(input, other, 1);
                }
                avformat_close_input(&other);
            }
        }
        if (!kept)
            dropped += later;
        if (dropped && art_form(writer.output->oformat) == ART_NONE) {
            add_note(notes, capacity, "Cover art cannot be written to %s. %u embedded picture%s not copied.",
                     container, dropped, dropped == 1 ? " is" : "s are");
        } else if (dropped) {
            add_note(notes, capacity, "%u embedded picture%s cannot be written to %s and %s not copied.",
                     dropped, dropped == 1 ? "" : "s", container, dropped == 1 ? "is" : "are");
        }
        if (kept && later) {
            add_note(notes, capacity, "Cover art comes from the first clip. %u different picture%s in later clips %s not copied.",
                     later, later == 1 ? "" : "s", later == 1 ? "is" : "are");
        }
        if (!kept_files)
            dropped_files += later_files;
        if (dropped_files) {
            add_note(notes, capacity, "Attached files cannot be written to %s. %u attached file%s not copied.",
                     container, dropped_files, dropped_files == 1 ? " is" : "s are");
        } else if (later_files) {
            add_note(notes, capacity, "Attached files come from the first clip. %u different file%s in later clips %s not copied.",
                     later_files, later_files == 1 ? "" : "s", later_files == 1 ? "is" : "are");
        }

        note_hevc_entry(&writer, segments, count, input, notes, capacity);
        note_metadata(&writer, input, container, notes, capacity);
        note_color_box(&writer, input, container, notes, capacity);
        note_projection(&writer, input, container, notes, capacity);
        note_block_data(&writer, input, container, notes, capacity);
        note_timecode(&writer, segments, count, tracks, container, notes, capacity);

        // A join writes one timecode track, which counts on from the first range.
        if (count > 1 && (tracks == MPCUT_TRACKS_ALL || writer.keep_timecode) &&
            av_match_name(writer.output->oformat->name, "mov,mp4") && av_match_name("mov", input->iformat->name)) {
            unsigned jumps = 0;
            for (size_t at = 1; at < count; at++)
                jumps += strcmp(segments[at].path, segments[at - 1].path) || time_compare(segments[at].start, segments[at - 1].end);
            for (unsigned i = 0; jumps && i < input->nb_streams; i++) {
                if (!timecode_track(input->streams[i]))
                    continue;
                add_note(notes, capacity, "The timecode track counts on from the first range. %u later range%s not keep %s source timecode.",
                         jumps, jumps == 1 ? " does" : "s do", jumps == 1 ? "its" : "their");
                break;
            }
        }

        MPCutTime origin = segments[0].source_origin.denominator > 0 ? segments[0].source_origin : (MPCutTime){0, 1};
        result = plan_chapters(&writer, segments, count, input, origin, tracks == MPCUT_TRACKS_ALL, &chapters) < 0;
        unsigned unstored = 0;
        if (!result && chapters.unplaced) {
            add_note(notes, capacity, "The chapters could not be placed on the output timeline and are not copied.");
        } else if (!result && chapters.count) {
            store_chapters(&writer, &chapters, movie_timescale, 0, &unstored);
            if (unstored && chapter_form(writer.output->oformat) == CHAPTERS_NONE) {
                add_note(notes, capacity, "Chapters cannot be written to %s. %u chapter%s not copied.",
                         container, unstored, unstored == 1 ? " is" : "s are");
            } else if (unstored) {
                add_note(notes, capacity, "%u chapter%s cannot be written to %s and %s not copied.",
                         unstored, unstored == 1 ? "" : "s", container, unstored == 1 ? "is" : "are");
            }
            if (chapters.moved_start > 0) {
                add_note(notes, capacity, "%s chapters begin with the file, so the first chapter starts at 0 instead of %"
                         PRId64 ".%03" PRId64 " s.", container, chapters.moved_start / 1000, chapters.moved_start % 1000);
            }
            if (chapters.closed_gaps) {
                add_note(notes, capacity, "%s chapters follow one another without a gap, so %u chapter%s on to the start of the next.",
                         container, chapters.closed_gaps, chapters.closed_gaps == 1 ? " runs" : "s run");
            }
        }
        // What the copy's parameter-set planning cannot keep (layered pictures, sets it cannot follow, reorder depth).
        if (writer.tracks != MPCUT_TRACKS_AUDIO) {
            note_unfollowed_sets(segments, count, notes, capacity);
            note_avc_reorder(writer.output->oformat->name, segments, count, notes, capacity);
        }
    }
    free_chapters(&chapters);
    avformat_close_input(&input);
    avformat_free_context(writer.output);
    return result;
}
