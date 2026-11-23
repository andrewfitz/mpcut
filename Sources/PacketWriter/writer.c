#include "PacketWriter.h"
#include "MediaProbe.h"
#include "timecode.h"
#include "aac_edits.h"
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
#include <libavutil/dovi_meta.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/sha.h>
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
    unsigned mp3_end_discard;
    MPCutAAC *aac_edits;
    MPCutAACSource *aac_source;
    OpusTrim *opus_trim;
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
} Writer;

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
        default:
            return -1;
    }
}

static int selected_stream(const Writer *writer, const AVStream *stream) {
    switch (writer->tracks) {
        case MPCUT_TRACKS_AUDIO:
            return stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                (writer->audio_stream < 0 || stream->index == writer->audio_stream);
        case MPCUT_TRACKS_VIDEO: return primary_video(stream);
        default: return 1;
    }
}

static int pcm_frame_size(const AVCodecParameters *codec);

static int validate_streams(Writer *writer, const AVFormatContext *input, int *timecode_index,
                            MPCutTimecode *timecode) {
    const AVOutputFormat *format = writer->output->oformat;
    int mov_color = av_match_name(format->name, "mov,mp4");
    unsigned video_count = 0;
    unsigned audio_count = 0;
    const AVStream *video = NULL;
    *timecode_index = -1;

    for (unsigned index = 0; index < input->nb_streams; index++) {
        const AVStream *stream = input->streams[index];
        const AVCodecParameters *codec = stream->codecpar;
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
    writer->selected_count = video_count + audio_count;
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
 * LAME extension is cleared afterwards (mp3_clear_lame_extension). */
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
    return 0;
}

/* Turn the muxer's Xing frame into a plain one: frame count, byte count and
 * seek table, with no encoder ID or delay fields for a reader to act on. */
static int mp3_clear_lame_extension(Writer *writer) {
    enum { XING_FIELDS = 4 + 4 + 4 + 4 + 100 + 4, LAME_FIELDS = 36 };
    static const uint8_t blank[LAME_FIELDS] = {0};
    uint8_t bytes[10];
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
        failed = 0; // No leading frame to finish.
        goto done;
    }
    int mpeg1 = (bytes[1] & 0x18) == 0x18;
    int mono = (bytes[3] & 0xc0) == 0xc0;
    long tag = frame + 4 + (mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17));
    if (fseek(file, tag, SEEK_SET) || fread(bytes, 1, 8, file) != 8
        || (memcmp(bytes, "Xing", 4) && memcmp(bytes, "Info", 4)) || AV_RB32(bytes + 4) != 0x0f) {
        failed = 0; // The muxer wrote no Xing frame.
        goto done;
    }
    failed = fseek(file, tag + XING_FIELDS, SEEK_SET) || fwrite(blank, 1, LAME_FIELDS, file) != LAME_FIELDS;
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

static int configure_output(Writer *writer, AVFormatContext *input, int whole_file,
                            int timecode_index, const MPCutTimecode *timecode, const char *initial_timecode,
                            const MPCutSegment *segment) {
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
        if (writer->generated_stills && destination->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            result = set_still_hdr(writer, destination->codecpar);
            if (result)
                return result;
        }
        // The MP4 muxer writes the Dolby Vision configuration box only at this
        // compliance level. Without it, the base-layer pictures survive but the
        // muxer quietly drops the display configuration.
        if (strcmp(output->oformat->name, "mp4") == 0 &&
            av_packet_side_data_get(source->codecpar->coded_side_data, source->codecpar->nb_coded_side_data,
                                    AV_PKT_DATA_DOVI_CONF))
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
        if (!is_mov(output->oformat) || !output->oformat->codec_tag
            || av_codec_get_id(output->oformat->codec_tag, source->codecpar->codec_tag) != source->codecpar->codec_id) {
            destination->codecpar->codec_tag = 0;
        }
        if (writer->smart_trim && is_mov(output->oformat)) {
            if (source->codecpar->codec_id == AV_CODEC_ID_H264)
                destination->codecpar->codec_tag = MKTAG('a', 'v', 'c', '1');
            else if (source->codecpar->codec_id == AV_CODEC_ID_HEVC)
                destination->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
        }
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
        av_opt_set_int(output->priv_data, "movie_timescale", movie_timescale, 0);
        av_opt_set_int(output->priv_data, "use_editlist", 1, 0);
        av_opt_set_int(output->priv_data, "use_stream_ids_as_track_ids", 1, 0);
        for (unsigned index = 0; index < output->nb_streams; index++) {
            const AVCodecParameters *codec = output->streams[index]->codecpar;
            if (codec->codec_type == AVMEDIA_TYPE_VIDEO
                && (codec->color_primaries != AVCOL_PRI_UNSPECIFIED
                    || codec->color_trc != AVCOL_TRC_UNSPECIFIED
                    || codec->color_space != AVCOL_SPC_UNSPECIFIED
                    || codec->color_range != AVCOL_RANGE_UNSPECIFIED)) {
                av_opt_set(output->priv_data, "movflags", "+write_colr+prefer_icc", 0);
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
    result = avio_open(&output->pb, writer->output_path, AVIO_FLAG_WRITE);
    if (result < 0) {
        return ff_error(writer, result, "Cannot create", writer->output_path);
    }
    result = avformat_write_header(output, NULL);
    if (result < 0) {
        return ff_error(writer, result, "Cannot write movie header to", writer->output_path);
    }
    return 0;
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

int mpcut_check_timecode(const MPCutSegment *segments, size_t count, MPCutTime duration,
                         const char *output_path, size_t *failed_segment,
                         MPCutProgress progress, void *context, char *error, size_t error_capacity) {
    Writer writer = {.output_path = output_path, .progress = progress, .progress_context = context,
                     .error = error, .error_capacity = error_capacity};
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

/* Map display-ordered replacement pictures onto the retained source decode slots.
 * The source index proves that copied runs start and end outside the patched GOPs.
 * Keeping the original DTS slots preserves decode order on either side of a patch. */
static int splice_video(Writer *writer, const AVFormatContext *input, const AVStream *video, const Range *range) {
    AVPacket *packet = writer->packet;
    const int64_t pts = packet->pts;
    if (pts == AV_NOPTS_VALUE)
        return fail(writer, "A Smart Trim video packet has no presentation timestamp");
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
            patch->encoded = mpcut_edge_open(input->url, video, writer->video_origin_pts, patch->plan.decode_from,
                patch->plan.from, patch->plan.to, patch->plan.frame_count, patch->plan.target_bit_rate, edge_progress,
                writer, writer->fraction, writer->error, writer->error_capacity);
            if (!patch->encoded)
                return writer->edge_cancelled ? 2 : 1;
        }
        int index = packet->stream_index;
        int64_t dts = packet->dts;
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
    if (!range->whole_file && (time_compare(time, range->source_start) < 0 || time_compare(time, range->source_end) >= 0))
        return 0;
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
    if (writer->restore_video_config) {
        int code = mpcut_splice_restore(packet, video->codecpar, extra, size);
        if (code == AVERROR_INVALIDDATA && video->codecpar->codec_id == AV_CODEC_ID_AV1)
            return fail(writer, "The copied AV1 sequence in %s needs a key packet and a recoverable sequence header", input->url);
        if (code < 0)
            return ff_error(writer, code, "Cannot restore source decoder configuration at the Smart Trim splice in", input->url);
        writer->restore_video_config = 0;
    }
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
    int mov_video_timing = av_match_name("mov", input->iformat->name)
        && (is_mov(writer->output->oformat) || is_matroska(writer->output->oformat));
    double progress_shift = time_seconds(range->output_start) - time_seconds(range->source_start);
    double progress_end = time_seconds(range->output_end);
    memset(writer->range_tracks, 0, input->nb_streams);
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
            // Demuxers distribute end padding over every affected frame. The MP3
            // muxer records only the last packet's value in the 12-bit LAME tag.
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
                AV_WL32(side + 4, writer->mp3_end_discard);
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
        } else if (writer->opus_trim && input_track->codecpar->codec_id == AV_CODEC_ID_OPUS) {
            result = trim_opus_packet(writer, input_track, range, &writer->opus_trim[input_index]);
        } else {
            int frame_size = range->whole_file ? 0 : pcm_frame_size(input_track->codecpar);
            result = frame_size ? slice_pcm(writer, input_track, range, frame_size)
                                : remux_packet(writer, input_track, range, video, video && mov_video_timing);
        }
        if (result) {
            return result;
        }
        int retained = packet->size > 0;
        if (retained) {
            written_video |= video;
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
    if (writer->selected_count != writer->output->nb_streams) {
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
    tracks = track_selection(tracks);
    writer.tracks = tracks;
    writer.audio_stream = audio_stream;
    AVFormatContext *input = NULL;
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
        result = index ? validate_layout(&writer, input, timecode_index)
                       : configure_output(&writer, input, range.whole_file, timecode_index, &timecode, initial_timecode, segment);
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
                                          segment->mp3_anchor, progress, context, error, error_capacity);
        } else {
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
    if (writer.mp3_header == MP3_HEADER_UNTAGGED) {
        result = mp3_clear_lame_extension(&writer);
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
    av_free(writer.range_tracks);
    av_free(writer.stream_map);
    if (writer.output) {
        avio_closep(&writer.output->pb);
        avformat_free_context(writer.output);
    }
    return result;
}
