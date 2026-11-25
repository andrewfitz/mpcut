#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "layered_edge.h"
#include "hevc_sets.h"
#include "PacketWriter.h"

#include <libavutil/error.h>

int mpcut_layered_edge_supported(const AVCodecParameters *codec)
{
    if (!codec || codec->codec_id != AV_CODEC_ID_HEVC)
        return 0;
    int kind = mpcut_hevc_layer_kind(codec->extradata, codec->extradata_size);
    return kind == MPCUT_HEVC_ALPHA || kind == MPCUT_HEVC_VIEWS;
}

int mpcut_smart_trim_keeps_layers(const uint8_t *config, size_t size)
{
    if (!config || size > INT_MAX)
        return 0;
    int kind = mpcut_hevc_layer_kind(config, (int)size);
    return kind == MPCUT_HEVC_ALPHA || kind == MPCUT_HEVC_VIEWS;
}

typedef struct {
    MPCutLayeredPicture picture;
    void *context;
    AVRational time_base;
    int64_t offset;
    int failed;
    const char *message;
} Encoded;

/* Append each parameter set NAL unit of an hvcC (from byte 23) or lhvC (from byte 6) record with a start code. */
static bool append_sets(NSMutableData *out, CFDataRef record, size_t arrays_at)
{
    if (!record)
        return true;
    const uint8_t *data = CFDataGetBytePtr(record), *end = data + CFDataGetLength(record);
    if ((size_t)(end - data) < arrays_at)
        return false;
    const uint8_t *p = data + arrays_at;
    unsigned arrays = data[arrays_at - 1];
    static const uint8_t start[4] = {0, 0, 0, 1};
    for (unsigned array = 0; array < arrays; array++) {
        if (end - p < 3)
            return false;
        unsigned type = p[0] & 0x3f, count = (unsigned)p[1] << 8 | p[2];
        p += 3;
        for (unsigned i = 0; i < count; i++) {
            if (end - p < 2)
                return false;
            size_t length = (size_t)p[0] << 8 | p[1];
            if ((size_t)(end - p - 2) < length)
                return false;
            if (type >= 32 && type <= 34 && length) {
                [out appendBytes:start length:4];
                [out appendBytes:p + 2 length:length];
            }
            p += 2 + length;
        }
    }
    return true;
}

static void encoded(void *refcon, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)frame;
    Encoded *work = refcon;
    if (work->failed)
        return;
    if (status != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped)) {
        work->failed = AVERROR_EXTERNAL;
        work->message = "VideoToolbox could not encode a picture of the Smart Trim edge with every layer";
        return;
    }
    @autoreleasepool {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        CFDictionaryRef first = attachments && CFArrayGetCount(attachments) ? CFArrayGetValueAtIndex(attachments, 0) : NULL;
        bool key = !(first && CFDictionaryGetValue(first, kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue);
        NSMutableData *out = [NSMutableData data];
        if (key) {
            CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
            CFDictionaryRef atoms = format ? CMFormatDescriptionGetExtension(
                format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
            CFDataRef hvcc = atoms ? CFDictionaryGetValue(atoms, CFSTR("hvcC")) : NULL;
            CFDataRef lhvc = atoms ? CFDictionaryGetValue(atoms, CFSTR("lhvC")) : NULL;
            if (!hvcc || CFGetTypeID(hvcc) != CFDataGetTypeID() || (lhvc && CFGetTypeID(lhvc) != CFDataGetTypeID())
                || !append_sets(out, hvcc, 23) || !append_sets(out, lhvc, 6)) {
                work->failed = AVERROR_INVALIDDATA;
                work->message = "The Smart Trim edge encoder gave no readable HEVC parameter sets";
                return;
            }
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t size = block ? CMBlockBufferGetDataLength(block) : 0;
        NSMutableData *coded = [NSMutableData dataWithLength:size];
        if (!size || CMBlockBufferCopyDataBytes(block, 0, size, coded.mutableBytes) != kCMBlockBufferNoErr) {
            work->failed = AVERROR_INVALIDDATA;
            work->message = "The Smart Trim edge encoder gave an empty picture";
            return;
        }
        static const uint8_t start[4] = {0, 0, 0, 1};
        const uint8_t *p = coded.bytes, *end = p + size;
        while (p < end) {
            if (end - p < 4) {
                work->failed = AVERROR_INVALIDDATA;
                break;
            }
            size_t length = (size_t)p[0] << 24 | (size_t)p[1] << 16 | (size_t)p[2] << 8 | p[3];
            if (!length || (size_t)(end - p - 4) < length) {
                work->failed = AVERROR_INVALIDDATA;
                break;
            }
            [out appendBytes:start length:4];
            [out appendBytes:p + 4 length:length];
            p += 4 + length;
        }
        CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
        __int128 dividend = (__int128)time.value * work->time_base.den;
        __int128 divisor = (__int128)time.timescale * work->time_base.num;
        if (work->failed || !CMTIME_IS_NUMERIC(time) || !divisor || dividend % divisor || out.length > INT_MAX) {
            work->failed = work->failed ? work->failed : AVERROR_INVALIDDATA;
            work->message = "The Smart Trim edge encoder gave a picture the source clock cannot place";
            return;
        }
        int64_t pts = (int64_t)(dividend / divisor) + work->offset;
        if (work->picture(work->context, out.bytes, (int)out.length, key, pts)) {
            work->failed = AVERROR_INVALIDDATA;
            work->message = "The decoded Smart Trim range differs from the frame index";
        }
    }
}

static void set(VTCompressionSessionRef session, CFStringRef key, CFTypeRef value)
{
    if (value)
        VTSessionSetProperty(session, key, value);
}

/* As scene_reader.m: an empty segment, a rate change or several edits put AVFoundation's pictures on another clock. */
static bool single_forward_edit(AVAssetTrack *track)
{
    NSArray<AVAssetTrackSegment *> *segments = track.segments;
    if (segments.count != 1 || segments.firstObject.empty)
        return false;
    CMTimeMapping map = segments.firstObject.timeMapping;
    return CMTIME_IS_NUMERIC(map.source.start) && CMTimeCompare(map.source.start, kCMTimeZero) >= 0 &&
           CMTIME_IS_NUMERIC(map.target.start) && CMTimeCompare(map.target.start, kCMTimeZero) == 0 &&
           CMTIME_IS_NUMERIC(map.source.duration) && CMTIME_IS_NUMERIC(map.target.duration) &&
           CMTimeCompare(map.source.duration, map.target.duration) == 0;
}

/* The layer ID and eye of each view, from the tag collections of an MV-HEVC description. */
static bool view_layers(CMFormatDescriptionRef format, NSMutableArray<NSNumber *> *layers, int64_t *left, int64_t *right)
{
    CFArrayRef collections = NULL;
    if (CMVideoFormatDescriptionCopyTagCollectionArray(format, &collections) != noErr || !collections)
        return false;
    *left = *right = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(collections); i++) {
        CMTagCollectionRef collection = CFArrayGetValueAtIndex(collections, i);
        CMTag layer, eye;
        CMItemCount found = 0;
        if (CMTagCollectionGetTagsWithCategory(collection, kCMTagCategory_VideoLayerID, &layer, 1, &found) != noErr || !found)
            continue;
        int64_t identifier = CMTagGetSInt64Value(layer);
        [layers addObject:@(identifier)];
        found = 0;
        if (CMTagCollectionGetTagsWithCategory(collection, kCMTagCategory_StereoView, &eye, 1, &found) == noErr && found) {
            CMStereoViewComponents view = (CMStereoViewComponents)CMTagGetFlagsValue(eye);
            if (view & kCMStereoView_LeftEye)
                *left = identifier;
            if (view & kCMStereoView_RightEye)
                *right = identifier;
        }
    }
    CFRelease(collections);
    return layers.count == 2 && *left >= 0 && *right >= 0 && *left != *right;
}

/* A copy of a decoded group whose buffers carry both their layer ID and their eye, as the encoder takes them. */
static CMTaggedBufferGroupRef tagged_views(CMTaggedBufferGroupRef group, int64_t left, int64_t right)
{
    CMItemCount count = CMTaggedBufferGroupGetCount(group);
    if (count != 2)
        return NULL;
    NSMutableArray *collections = [NSMutableArray array], *buffers = [NSMutableArray array];
    for (CMItemCount i = 0; i < count; i++) {
        CMTagCollectionRef tags = CMTaggedBufferGroupGetTagCollectionAtIndex(group, i);
        CVPixelBufferRef image = CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, i);
        if (!tags || !image)
            return NULL;
        CMTag found;
        CMItemCount n = 0;
        int64_t layer = -1;
        if (CMTagCollectionGetTagsWithCategory(tags, kCMTagCategory_VideoLayerID, &found, 1, &n) == noErr && n)
            layer = CMTagGetSInt64Value(found);
        n = 0;
        if (layer < 0 && CMTagCollectionGetTagsWithCategory(tags, kCMTagCategory_StereoView, &found, 1, &n) == noErr && n)
            layer = CMTagGetFlagsValue(found) & kCMStereoView_LeftEye ? left : right;
        if (layer != left && layer != right)
            return NULL;
        CMTag both[2] = {CMTagMakeWithSInt64Value(kCMTagCategory_VideoLayerID, layer),
                         layer == left ? kCMTagStereoLeftEye : kCMTagStereoRightEye};
        CMTagCollectionRef collection = NULL;
        if (CMTagCollectionCreate(kCFAllocatorDefault, both, 2, &collection) != noErr || !collection)
            return NULL;
        [collections addObject:(__bridge_transfer id)collection];
        [buffers addObject:(__bridge id)image];
    }
    CMTaggedBufferGroupRef copy = NULL;
    if (CMTaggedBufferGroupCreate(kCFAllocatorDefault, (__bridge CFArrayRef)collections, (__bridge CFArrayRef)buffers,
                                  &copy) != noErr)
        return NULL;
    return copy;
}

int mpcut_layered_edge_encode(const char *path, const AVStream *video, int64_t offset, int64_t first, int64_t end,
                              int64_t bit_rate, MPCutLayeredPicture picture, void *context,
                              MPCutLayeredCancelled cancelled, void *cancel_context, const char **message)
{
    const AVCodecParameters *codec = video->codecpar;
    int kind = mpcut_hevc_layer_kind(codec->extradata, codec->extradata_size);
    *message = "Smart Trim cannot encode an edge with every layer of this picture";
    if (kind != MPCUT_HEVC_ALPHA && kind != MPCUT_HEVC_VIEWS)
        return AVERROR(ENOTSUP);
    bool alpha = kind == MPCUT_HEVC_ALPHA;
    AVRational base = video->time_base;
    int result = 0;
    VTCompressionSessionRef session = NULL;
    Encoded work = {.picture = picture, .context = context, .time_base = base, .offset = offset};
    @autoreleasepool {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(path)] options:nil];
        // FFmpeg numbers a MOV track by its track ID. AVFoundation's clock is the demuxer's only for a track with one
        // forward edit in its own time scale; the frame index check in smart_edge refuses any other difference.
        AVAssetTrack *track = [asset trackWithTrackID:(CMPersistentTrackID)video->id];
        *message = "AVFoundation cannot read the picture of this Smart Trim edge on the source's clock";
        if (!track || track.formatDescriptions.count != 1 || track.naturalTimeScale != base.den || base.num != 1
            || !single_forward_edit(track))
            return AVERROR(ENOTSUP);
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format);
        NSMutableArray<NSNumber *> *layers = [NSMutableArray array];
        int64_t left = -1, right = -1;
        if (!alpha && !view_layers(format, layers, &left, &right)) {
            *message = "The views of this MV-HEVC picture do not name a left and a right eye, so Smart Trim cannot encode them";
            return AVERROR(ENOTSUP);
        }

        NSError *error = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        if (!reader)
            return AVERROR_EXTERNAL;
        reader.timeRange = CMTimeRangeFromTimeToTime(CMTimeMake((first - offset) * base.num, base.den),
                                                     CMTimeMake((end - offset) * base.num, base.den));
        bool full = codec->color_range == AVCOL_RANGE_JPEG;
        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
        // Alpha comes as its own plane beside the source's 4:2:0 picture, so neither is converted on the way.
        settings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] =
            @(alpha ? kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar
                    : full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        if (!alpha)
            settings[AVVideoDecompressionPropertiesKey] =
                @{(__bridge NSString *)kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs: layers};
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                                                      outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output])
            return AVERROR_EXTERNAL;
        [reader addOutput:output];

        *message = "Cannot start the VideoToolbox encoder for the Smart Trim edge";
        NSDictionary *specification = @{
            (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
        OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, size.width, size.height,
                                                     alpha ? kCMVideoCodecType_HEVCWithAlpha : kCMVideoCodecType_HEVC,
                                                     (__bridge CFDictionaryRef)specification, NULL, NULL,
                                                     encoded, &work, &session);
        if (status != noErr || !session)
            return AVERROR_EXTERNAL;
        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(INT32_MAX));
        set(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bit_rate));
        // The picture's colour description, as the source's sample entry gives it.
        const CFStringRef colour[][2] = {
            {kCMFormatDescriptionExtension_ColorPrimaries, kVTCompressionPropertyKey_ColorPrimaries},
            {kCMFormatDescriptionExtension_TransferFunction, kVTCompressionPropertyKey_TransferFunction},
            {kCMFormatDescriptionExtension_YCbCrMatrix, kVTCompressionPropertyKey_YCbCrMatrix}};
        for (size_t i = 0; i < sizeof(colour) / sizeof(colour[0]); i++)
            set(session, colour[i][1], CMFormatDescriptionGetExtension(format, colour[i][0]));
        if (alpha) {
            // The source's own alpha mode (premultiplied when its sample entry names none, as VideoToolbox assumes).
            CFTypeRef mode = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_AlphaChannelMode);
            set(session, kVTCompressionPropertyKey_AlphaChannelMode,
                mode ? mode : kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha);
            set(session, kVTCompressionPropertyKey_TargetQualityForAlpha, (__bridge CFTypeRef)@1.0);
        } else {
            set(session, kVTCompressionPropertyKey_MVHEVCVideoLayerIDs, (__bridge CFArrayRef)layers);
            set(session, kVTCompressionPropertyKey_MVHEVCViewIDs, (__bridge CFArrayRef)layers);
            set(session, kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs, (__bridge CFArrayRef)@[@(left), @(right)]);
            set(session, kVTCompressionPropertyKey_HasLeftStereoEyeView, kCFBooleanTrue);
            set(session, kVTCompressionPropertyKey_HasRightStereoEyeView, kCFBooleanTrue);
            const CFStringRef stereo[][2] = {
                {kCMFormatDescriptionExtension_HeroEye, kVTCompressionPropertyKey_HeroEye},
                {kCMFormatDescriptionExtension_StereoCameraBaseline, kVTCompressionPropertyKey_StereoCameraBaseline},
                {kCMFormatDescriptionExtension_HorizontalDisparityAdjustment,
                 kVTCompressionPropertyKey_HorizontalDisparityAdjustment},
                {kCMFormatDescriptionExtension_HorizontalFieldOfView, kCMFormatDescriptionExtension_HorizontalFieldOfView}};
            for (size_t i = 0; i < sizeof(stereo) / sizeof(stereo[0]); i++)
                set(session, stereo[i][1], CMFormatDescriptionGetExtension(format, stereo[i][0]));
        }
        if (VTCompressionSessionPrepareToEncodeFrames(session) != noErr)
            result = AVERROR_EXTERNAL;
        if (!result)
            *message = "AVFoundation cannot read the picture of this Smart Trim edge";
        if (!result && ![reader startReading])
            result = AVERROR_EXTERNAL;
        bool started = false;
        CMSampleBufferRef sample;
        while (!result && !work.failed && (sample = [output copyNextSampleBuffer])) {
            @autoreleasepool {
                if (cancelled && cancelled(cancel_context)) {
                    CFRelease(sample);
                    result = AVERROR_EXIT;
                    break;
                }
                CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
                __int128 dividend = (__int128)time.value * base.den, divisor = (__int128)time.timescale * base.num;
                int64_t pts = divisor && !(dividend % divisor) ? (int64_t)(dividend / divisor) + offset : INT64_MIN;
                if (pts == INT64_MIN) {
                    CFRelease(sample);
                    result = AVERROR_INVALIDDATA;
                    *message = "The source picture timestamp cannot be represented";
                    break;
                }
                if (pts < first || pts >= end) {
                    CFRelease(sample);
                    continue;
                }
                CMTime duration = CMSampleBufferGetDuration(sample);
                NSDictionary *frame = started ? nil : @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
                started = true;
                if (alpha) {
                    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
                    status = image ? VTCompressionSessionEncodeFrame(session, image, time, duration,
                                                                     (__bridge CFDictionaryRef)frame, NULL, NULL)
                                   : kVTParameterErr;
                } else {
                    CMTaggedBufferGroupRef group = CMSampleBufferGetTaggedBufferGroup(sample);
                    CMTaggedBufferGroupRef views = group ? tagged_views(group, left, right) : NULL;
                    status = views ? VTCompressionSessionEncodeMultiImageFrame(session, views, time, duration,
                                                                               (__bridge CFDictionaryRef)frame, NULL, NULL)
                                   : kVTParameterErr;
                    if (views)
                        CFRelease(views);
                }
                CFRelease(sample);
                if (status != noErr) {
                    result = AVERROR_EXTERNAL;
                    *message = alpha ? "VideoToolbox could not encode the alpha layer of the Smart Trim edge"
                                     : "VideoToolbox could not encode both views of the Smart Trim edge";
                    break;
                }
            }
        }
        if (!result && !work.failed && reader.status == AVAssetReaderStatusFailed) {
            result = AVERROR_EXTERNAL;
            *message = "AVFoundation could not decode every layer of the Smart Trim edge";
        }
        if (!result && VTCompressionSessionCompleteFrames(session, kCMTimeInvalid) != noErr)
            result = AVERROR_EXTERNAL;
        if (reader.status == AVAssetReaderStatusReading)
            [reader cancelReading];
    }
    if (session) {
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
    }
    if (!result && work.failed) {
        result = work.failed;
        if (work.message)
            *message = work.message;
    }
    return result;
}
