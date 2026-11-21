#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include "scene_reader.h"

static OSType surface_format(const AVCodecParameters *video)
{
    bool full = video->color_range == AVCOL_RANGE_JPEG || video->format == AV_PIX_FMT_YUVJ420P;
    switch (video->format) {
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P:
        return full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    case AV_PIX_FMT_YUV420P10LE:
        return full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    default:
        return 0;
    }
}

static bool supported_description(const AVAssetTrack *track, const AVCodecParameters *video)
{
    if (track.formatDescriptions.count != 1) return false;
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    return CMFormatDescriptionGetMediaSubType(format) == CFSwapInt32HostToBig(video->codec_tag) &&
           dimensions.width == video->width && dimensions.height == video->height;
}

// An empty segment, a rate change, or multiple edits can place decoded pictures
// on a different clock from libavformat. Use the demuxer for those tracks.
static bool single_forward_edit(const AVAssetTrack *track)
{
    NSArray<AVAssetTrackSegment *> *segments = track.segments;
    if (segments.count != 1 || segments.firstObject.empty) return false;
    CMTimeMapping map = segments.firstObject.timeMapping;
    return CMTIME_IS_NUMERIC(map.source.start) && CMTimeCompare(map.source.start, kCMTimeZero) >= 0 &&
           CMTIME_IS_NUMERIC(map.target.start) && CMTimeCompare(map.target.start, kCMTimeZero) == 0 &&
           CMTIME_IS_NUMERIC(map.source.duration) && CMTIME_IS_NUMERIC(map.target.duration) &&
           CMTimeCompare(map.source.duration, map.target.duration) == 0;
}

static int compare_pts(const void *left, const void *right)
{
    int64_t a = *(const int64_t *)left, b = *(const int64_t *)right;
    return (a > b) - (a < b);
}

// Validate irregular display times against the same demuxer as the fallback.
// A separate context leaves the fallback positioned at its first packet.
static int64_t *packet_times(const char *path, const AVStream *stream,
                             MPProbeCancelled cancelled, void *context)
{
    AVFormatContext *input = avformat_alloc_context();
    AVPacket *packet = av_packet_alloc();
    int64_t *times = NULL;
    int64_t count = 0;
    int status = 0;
    if (!input || !packet) goto done;
    input->interrupt_callback = (AVIOInterruptCB){ cancelled, context };
    if (avformat_open_input(&input, path, NULL, NULL) < 0) goto done;
    if ((unsigned)stream->index >= input->nb_streams ||
        av_cmp_q(input->streams[stream->index]->time_base, stream->time_base)) goto done;
    // Bound temporary storage even when the sample table is malformed.
    if (stream->nb_frames > 8 * 1024 * 1024) goto done;
    for (unsigned i = 0; i < input->nb_streams; ++i)
        if (i != stream->index) input->streams[i]->discard = AVDISCARD_ALL;
    times = av_malloc_array(stream->nb_frames, sizeof(*times));
    if (!times) goto done;
    while (!cancelled(context) && (status = av_read_frame(input, packet)) >= 0) {
        if (packet->stream_index == stream->index) {
            if (count >= stream->nb_frames || packet->pts < 0 ||
                packet->pts >= stream->duration || packet->duration <= 0 ||
                packet->flags & (AV_PKT_FLAG_DISCARD | AV_PKT_FLAG_CORRUPT)) break;
            times[count++] = packet->pts;
        }
        av_packet_unref(packet);
    }
    if (status != AVERROR_EOF || count != stream->nb_frames) {
        av_freep(&times);
    } else {
        psort(times, count, sizeof(*times), compare_pts);
        for (int64_t i = 0; i < count; ++i) {
            if (i ? times[i] <= times[i - 1] : times[0] != 0) {
                av_freep(&times);
                break;
            }
        }
    }
done:
    av_packet_free(&packet);
    avformat_close_input(&input);
    return times;
}

int mp_scene_read_asset(const char *path, const AVStream *stream,
                        MPSceneSurfaceVisit visit, MPProbeCancelled cancelled, void *context)
{
    const AVCodecParameters *video = stream->codecpar;
    if (video->codec_id != AV_CODEC_ID_H264 && video->codec_id != AV_CODEC_ID_HEVC) return 0;
    // AssetReader may deinterlace mixed-field and interlaced inputs even when
    // it returns the requested surface format and the original timestamps.
    if (video->field_order != AV_FIELD_PROGRESSIVE) return 0;
    // avc1/hvc1 store their configuration in the sample entry. hev1 can
    // change it in-band and Apple's reader can reject the track at startup.
    if (video->codec_tag != MKTAG('a','v','c','1') && video->codec_tag != MKTAG('h','v','c','1')) return 0;
    if (stream->start_time != 0 || stream->time_base.num != 1 || stream->time_base.den <= 0 ||
        stream->nb_frames <= 0 || stream->duration < stream->nb_frames ||
        video->width <= 0 || video->height <= 0) return 0;
    if (av_packet_side_data_get(video->coded_side_data, video->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF) ||
        av_packet_side_data_get(video->coded_side_data, video->nb_coded_side_data, AV_PKT_DATA_STEREO3D)) return 0;
    OSType pixel_format = surface_format(video);
    CMVideoCodecType codec = video->codec_id == AV_CODEC_ID_H264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC;
    if (!pixel_format || !VTIsHardwareDecodeSupported(codec)) return 0;

    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path isDirectory:NO relativeToURL:nil];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];
        AVAssetTrack *track = [asset trackWithTrackID:stream->id];
        // AVFoundation can composite an alpha layer or select a stereo eye
        // when asked to deliver a single opaque pixel buffer.
        if (!track || [track hasMediaCharacteristic:AVMediaCharacteristicContainsAlphaChannel] ||
            [track hasMediaCharacteristic:AVMediaCharacteristicContainsStereoMultiviewVideo] ||
            track.naturalTimeScale != stream->time_base.den ||
            !supported_description(track, video) || !single_forward_edit(track)) return 0;

        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
             outputSettings:@{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(pixel_format) }];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return 0;
        [reader addOutput:output];
        if (![reader startReading]) return 0;

        int result = 0;
        int64_t count = 0;
        int64_t step = stream->duration / stream->nb_frames;
        int64_t *times = NULL;
        if (stream->duration % stream->nb_frames) {
            times = packet_times(path, stream, cancelled, context);
            if (!times) {
                [reader cancelReading];
                return cancelled(context) ? AVERROR_EXIT : 0;
            }
        }
        for (;;) {
            if (cancelled(context)) {
                [reader cancelReading];
                av_free(times);
                return AVERROR_EXIT;
            }
            @autoreleasepool {
                CMSampleBufferRef sample = [output copyNextSampleBuffer];
                if (!sample) break;
                // Checking each timestamp also catches irregular cadence with a
                // nominal CFR header, clipped preroll, and hidden or missing frames.
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
                CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
                int64_t expected = times && count < stream->nb_frames ? times[count] : count * step;
                bool matches = count < stream->nb_frames && image && CMTIME_IS_NUMERIC(pts) &&
                    CMTimeCompare(pts, CMTimeMake(expected, stream->time_base.den)) == 0 &&
                    CVPixelBufferGetPixelFormatType(image) == pixel_format &&
                    CVPixelBufferGetWidth(image) == (size_t)video->width &&
                    CVPixelBufferGetHeight(image) == (size_t)video->height;
                result = matches ? visit(context, image, expected) : AVERROR_INVALIDDATA;
                CFRelease(sample);
            }
            if (result < 0) {
                [reader cancelReading];
                av_free(times);
                return result == AVERROR_EXIT ? result : 0;
            }
            count++;
        }
        av_free(times);
        return count == stream->nb_frames && reader.status == AVAssetReaderStatusCompleted;
    }
}
