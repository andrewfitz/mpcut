import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

// Make and inspect layered HEVC movies with Apple's own encoder and reader.
//
//   LayeredVideo make-stereo OUT.mov   MV-HEVC spatial video: two views (layer 0 left, layer 1 right), 4 s at 30 fps,
//                                       a keyframe every second. Each view carries an 8-bit frame barcode, and the
//                                       right view is inverted so a decoder that shows the base layer twice is caught.
//   LayeredVideo make-stereo-reordered OUT.mov   The same with B-frames (frame reordering allowed).
//   LayeredVideo make-alpha OUT.mov    HEVC with alpha: 4 s at 30 fps, a keyframe every second, a barcode in colour
//                                       and the frame number again in the alpha of the right half.
//   LayeredVideo make-alpha-straight OUT.mov   The same with straight (not premultiplied) alpha.
//   LayeredVideo inspect FILE          One JSON line: what AVFoundation sees in the first video track, and what it
//                                       decodes from every frame (both views, or the alpha plane).
@main
struct LayeredVideo {
    static let width = 256, height = 144, frames = 120, rate: Int32 = 30

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: LayeredVideo make-stereo|make-stereo-reordered|make-alpha|make-alpha-straight|inspect FILE\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[2])
        switch arguments[1] {
        case "make-stereo": try await makeStereo(url, reordered: false)
        case "make-stereo-reordered": try await makeStereo(url, reordered: true)
        case "make-alpha": try await makeAlpha(url, straight: false)
        case "make-alpha-straight": try await makeAlpha(url, straight: true)
        case "inspect": try await inspect(url)
        default: exit(2)
        }
    }

    // MARK: Making

    static func pixelBuffer(format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
        return buffer!
    }

    /// BGRA with an 8-bit barcode of `id` in a band at the top, a moving gradient below, and `alpha` per column.
    static func paint(_ buffer: CVPixelBuffer, id: Int, invert: Bool, alpha: (Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8
                if y < 16 { value = x < 128 && id >> (x / 16) & 1 == 1 ? 235 : 16 }
                else { value = UInt8((x + y + id * 3) & 0xff) / 2 + 32 }
                if invert { value = 255 - value }
                let pixel = base + y * stride + x * 4
                pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = alpha(x)
            }
        }
    }

    static func writer(_ url: URL, codec: AVVideoCodecType, compression: [String: Any],
                       reordered: Bool = false) throws -> (AVAssetWriter, AVAssetWriterInput) {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var properties = compression
        properties[AVVideoMaxKeyFrameIntervalKey] = Int(rate)
        properties[AVVideoAllowFrameReorderingKey] = reordered
        properties[AVVideoAverageBitRateKey] = 2_000_000
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: properties
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return (writer, input)
    }

    static func finish(_ writer: AVAssetWriter, _ input: AVAssetWriterInput) async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func makeStereo(_ url: URL, reordered: Bool) async throws {
        let (writer, input) = try writer(url, codec: .hevc, compression: [
            kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String: [0, 1],
            kVTCompressionPropertyKey_MVHEVCViewIDs as String: [0, 1],
            kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs as String: [0, 1],
            kVTCompressionPropertyKey_HasLeftStereoEyeView as String: true,
            kVTCompressionPropertyKey_HasRightStereoEyeView as String: true,
            kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String: 200,
            kCMFormatDescriptionExtension_HorizontalFieldOfView as String: 63_400,
            kVTCompressionPropertyKey_StereoCameraBaseline as String: 19_240,
        ], reordered: reordered)
        let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(assetWriterInput: input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let left = pixelBuffer(format: kCVPixelFormatType_32BGRA), right = pixelBuffer(format: kCVPixelFormatType_32BGRA)
            paint(left, id: frame, invert: false) { _ in 255 }
            paint(right, id: frame, invert: true) { _ in 255 }
            let group = [
                CMTaggedBuffer(tags: [.stereoView(.leftEye), .videoLayerID(0)], pixelBuffer: left),
                CMTaggedBuffer(tags: [.stereoView(.rightEye), .videoLayerID(1)], pixelBuffer: right),
            ]
            let time = CMTime(value: CMTimeValue(frame), timescale: rate)
            guard adaptor.appendTaggedBuffers(group, withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        try await finish(writer, input)
    }

    static func makeAlpha(_ url: URL, straight: Bool) async throws {
        let (writer, input) = try writer(url, codec: .hevcWithAlpha, compression: [
            kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0,
            kVTCompressionPropertyKey_AlphaChannelMode as String:
                straight ? kVTAlphaChannelMode_StraightAlpha : kVTAlphaChannelMode_PremultipliedAlpha,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let buffer = pixelBuffer(format: kCVPixelFormatType_32BGRA)
            // Opaque left half; the right half's alpha holds the frame number's barcode, 16 columns per bit.
            paint(buffer, id: frame, invert: false) { x in
                x < 128 ? 255 : (frame >> ((x - 128) / 16) & 1 == 1 ? 255 : 0)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: rate)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        try await finish(writer, input)
    }

    // MARK: Inspecting

    static func barcode(_ row: UnsafePointer<UInt8>, step: Int, invert: Bool) -> Int {
        var id = 0
        for bit in 0..<8 {
            let value = Int(row[(bit * 16 + 8) * step])
            if invert ? value < 120 : value > 120 { id |= 1 << bit }
        }
        return id
    }

    static func inspect(_ url: URL) async throws {
        var report: [String: Any] = ["file": url.lastPathComponent]
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            report["error"] = "no video track"
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            return
        }
        let characteristics = try await track.load(.mediaCharacteristics)
        let stereo = characteristics.contains(.containsStereoMultiviewVideo)
        report["stereo_multiview"] = stereo
        report["contains_alpha_characteristic"] = characteristics.contains(.containsAlphaChannel)
        if let description = try await track.load(.formatDescriptions).first {
            report["codec"] = FourCharCode(CMFormatDescriptionGetMediaSubType(description)).string
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
            if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
                report["sample_entry_boxes"] = atoms.keys.sorted()
            }
            report["alpha_in_description"] = extensions["ContainsAlphaChannel"] as? Bool ?? false
            if let mode = extensions[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String {
                report["alpha_mode"] = mode
            }
            for key in ["HasLeftStereoEyeView", "HasRightStereoEyeView", "HeroEye", "StereoCameraBaseline",
                        "HorizontalDisparityAdjustment", "HorizontalFieldOfView"] where extensions[key] != nil {
                report["stereo_" + key] = extensions[key]
            }
        }
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if stereo {
            settings[AVVideoDecompressionPropertiesKey] = [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: [0, 1]
            ]
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        var ids: [Int] = [], rightIds: [Int] = [], alphaIds: [Int] = [], views: [Int] = []
        var translucent = 0
        func read(_ buffer: CVPixelBuffer, into list: inout [Int], invert: Bool) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            list.append(barcode(base + 8 * stride, step: 4, invert: invert))
            if !stereo && !invert {
                // Alpha of the right half, row 40.
                let row = base + 40 * stride + 128 * 4 + 3
                var id = 0, partial = false
                for bit in 0..<8 {
                    let alpha = row[(bit * 16 + 8) * 4]
                    if alpha > 120 { id |= 1 << bit }
                    if alpha < 250 { partial = true }
                }
                alphaIds.append(id)
                if partial { translucent += 1 }
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            if let group = sample.taggedBuffers {
                views.append(group.count)
                for tagged in group {
                    guard case let .pixelBuffer(buffer) = tagged.buffer else { continue }
                    if tagged.tags.contains(.stereoView(.rightEye)) || tagged.tags.contains(.videoLayerID(1)) {
                        read(buffer, into: &rightIds, invert: true)
                    } else {
                        read(buffer, into: &ids, invert: false)
                    }
                }
            } else if let buffer = sample.imageBuffer {
                views.append(1)
                read(buffer, into: &ids, invert: false)
            }
        }
        report["read_status"] = reader.status == .completed ? "completed" : (reader.error?.localizedDescription ?? "failed")
        report["frames"] = ids.count
        report["ids"] = ids
        if stereo {
            report["right_ids"] = rightIds
            report["views_per_frame"] = Array(Set(views)).sorted()
        } else {
            report["alpha_ids"] = alphaIds
            report["translucent_frames"] = translucent
        }
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}

extension FourCharCode {
    var string: String {
        String(bytes: [24, 16, 8, 0].map { UInt8(self >> $0 & 0xff) }, encoding: .ascii) ?? "\(self)"
    }
}
