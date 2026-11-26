import Foundation
import ImageIO
import UniformTypeIdentifiers

package struct StillReviewFrame: Sendable {
    package let asset: StillAsset
    package let placementID: String
    package let framing: StillImageFraming
    package let interval: MulticamRange
    package let url: URL
    package let identity: SourceIdentity
    package let width: Int
    package let height: Int
    package let displayAspect: Double

    package init(asset: StillAsset, placementID: String, framing: StillImageFraming,
                 interval: MulticamRange, document: URL?, width: Int, height: Int, displayAspect: Double) throws {
        self.asset = asset
        self.placementID = placementID
        self.framing = framing
        self.interval = interval
        do {
            if let document {
                url = try CutProject.checkedMediaURL(asset.file, relativeTo: document)
            } else {
                guard (asset.file as NSString).isAbsolutePath else { throw Self.unavailable(asset, placementID) }
                url = URL(fileURLWithPath: asset.file)
            }
            identity = try SourceIdentity(url)
        } catch {
            throw Self.unavailable(asset, placementID)
        }
        self.width = width
        self.height = height
        self.displayAspect = displayAspect
        guard width > 0, height > 0 else {
            throw CutError(code: "invalid_canvas", message: "No program picture dimensions are available.")
        }
    }

    private static func unavailable(_ asset: StillAsset, _ placement: String) -> CutError {
        CutError(code: "still_offline", message: "Image \(asset.displayName) (asset \(asset.id), placement \(placement)) is unavailable.")
    }

    package func validateIdentity() throws {
        guard identity.isCurrentSnapshot(at: url) else {
            throw CutError(code: "source_changed", message: "Relink the changed image \(asset.displayName).")
        }
    }

    package func validateAsset(cancelled: @escaping () -> Bool) throws {
        try checkCancellation(cancelled)
        try validateIdentity()
        guard try StillImage.fingerprint(url, expectedIdentity: identity, cancelled: cancelled) == asset.fingerprint else {
            throw CutError(code: "source_changed", message: "Relink the changed image \(asset.displayName).")
        }
        try checkCancellation(cancelled)
    }

    package func image(maximumDimension: Int?, cancelled: @escaping () -> Bool) throws -> CGImage {
        try validateAsset(cancelled: cancelled)
        // A review can ask for part of the picture. Render enough of the whole for that part to fill the limit.
        let region = maximumDimension == nil ? nil : JPEGReviewSize.region
        let part = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let scale = maximumDimension.map {
            min(1, Double($0) / max(Double(width) * part.width, Double(height) * part.height))
        } ?? 1
        let renderWidth = max(1, Int((Double(width) * scale).rounded()))
        let renderHeight = max(1, Int((Double(height) * scale).rounded()))
        let image = try StillImage.render(url, canvas: StillImageCanvas(width: renderWidth, height: renderHeight, displayAspect: displayAspect),
                                          framing: framing, forceSDR: true, preview: maximumDimension != nil, expectedIdentity: identity,
                                          cancelled: cancelled).sdrImage()
        try checkCancellation(cancelled)
        try validateIdentity()
        guard region != nil else { return image }
        // A bitmap measures down from its top edge, as the region does.
        let crop = CGRect(x: (part.minX * Double(image.width)).rounded(), y: (part.minY * Double(image.height)).rounded(),
                          width: max(1, (part.width * Double(image.width)).rounded()),
                          height: max(1, (part.height * Double(image.height)).rounded()))
        guard let cropped = image.cropping(to: crop) else {
            throw CutError(code: "frame_export_failed", message: "Could not crop the still review picture.")
        }
        return cropped
    }

    package func jpeg(preset: JPEGPreset, cancelled: @escaping () -> Bool) throws -> (data: Data, width: Int, height: Int) {
        let image = try image(maximumDimension: preset == .review ? JPEGReviewSize.maxEdge : nil, cancelled: cancelled)
        func make(_ quality: Double) throws -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CutError(code: "frame_export_failed", message: "Could not create a JPEG encoder.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw CutError(code: "frame_export_failed", message: "Could not encode the still review JPEG.")
            }
            return data as Data
        }
        let data = try preset == .review ? JPEGReviewSize.encode(make) : make(0.95) ?? Data()
        try checkCancellation(cancelled)
        guard preset != .review || data.count <= JPEGReviewSize.byteLimit else {
            throw CutError(code: "image_too_large", message: JPEGReviewSize.tooLarge)
        }
        try validateIdentity()
        return (data, image.width, image.height)
    }

    /// The review picture in the requested file format. PNG and TIFF hold the 16-bit sRGB rendition
    /// that the JPEG is compressed from.
    package func encoded(preset: JPEGPreset, format: FrameImageFormat,
                         cancelled: @escaping () -> Bool) throws -> (data: Data, width: Int, height: Int) {
        guard format != .jpeg else { return try jpeg(preset: preset, cancelled: cancelled) }
        let image = try image(maximumDimension: preset == .review ? JPEGReviewSize.maxEdge : nil, cancelled: cancelled)
        let data = try format.encode(image)
        try checkCancellation(cancelled)
        try validateIdentity()
        return (data, image.width, image.height)
    }

    package func write(to output: URL, replacing identity: SourceIdentity? = nil,
                       preset: JPEGPreset = .full, format: FrameImageFormat = .jpeg,
                       cancelled: @escaping @Sendable () -> Bool) throws {
        try checkCancellation(cancelled)
        try JPEGExport.validateStillDestination(output, source: url, sourceIdentity: self.identity, replacing: identity)
        let jpeg = try encoded(preset: preset, format: format, cancelled: cancelled)
        try JPEGExport.publishStillJPEG(jpeg.data, source: url, sourceIdentity: self.identity, to: output,
                                        replacing: identity, cancelled: cancelled, validate: validateIdentity)
    }

    private func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CutError(code: "cancelled", message: "Frame export was cancelled.") }
    }
}

extension StillTimelinePlan {
    package func pictureIndex(at time: RationalTime) -> Int? {
        guard time >= .zero, time <= duration else { return nil }
        let atEnd = time == duration
        let index = spans.lowerBound { $0.output.to > time } - (atEnd ? 1 : 0)
        guard spans.indices.contains(index) else { return nil }
        let output = spans[index].output
        guard time >= output.from, atEnd ? time == output.to : time < output.to else { return nil }
        return index
    }
}

extension CutProject {
    package func stillReviewGeometry(reference: MediaInfo?) -> (width: Int, height: Int, aspect: Double)? {
        if let format = stillFormat, format.width > 0, format.height > 0 {
            return (format.width, format.height, Double(format.width) / Double(format.height))
        }
        guard let video = reference?.videoStream, video.width > 0, video.height > 0 else { return nil }
        let rotated = !video.rotation.isMultiple(of: 180)
        let sar = video.sampleAspectRatio > .zero ? video.sampleAspectRatio.seconds : 1
        let codedAspect = Double(video.width) * sar / Double(video.height)
        let width = video.displayWidth > 0 ? video.displayWidth : rotated ? video.height : video.width
        let height = video.displayHeight > 0 ? video.displayHeight : rotated ? video.width : video.height
        return (width, height, rotated ? 1 / codedAspect : codedAspect)
    }

    package func stillReviewFrame(placementID: String, interval: MulticamRange,
                                  document: URL?, canvas: MediaInfo?) throws -> StillReviewFrame {
        let assetID: String
        let framing: StillImageFraming
        if let replacement = stillReplacements.first(where: { $0.id == placementID }) {
            assetID = replacement.assetID
            framing = replacement.framing
        } else if let insert = stillInserts.first(where: { $0.id == placementID }) {
            assetID = insert.assetID
            framing = insert.framing
        } else {
            throw CutError(code: "invalid_target", message: "No still placement has ID \(placementID).")
        }
        guard let asset = stillAssets.first(where: { $0.id == assetID }) else {
            throw CutError(code: "invalid_target", message: "No image asset has ID \(assetID).")
        }
        guard let geometry = stillReviewGeometry(reference: canvas) else {
            throw CutError(code: "invalid_canvas", message: "The program needs a video reference for image dimensions.")
        }
        return try StillReviewFrame(asset: asset, placementID: placementID, framing: framing, interval: interval,
                                    document: document, width: geometry.width, height: geometry.height,
                                    displayAspect: geometry.aspect)
    }
}

extension StillReviewFrame {
    private struct Manifest: Encodable {
        struct Frame: Encodable {
            let file: String
            let asset, placement: String
            let from, to: RationalTime
            let width, height: Int
        }
        let schemaVersion = 2
        let selection = "program"
        let preset: JPEGPreset
        let format: FrameImageFormat?
        let frames: [Frame]
    }

    package func writeDirectory(to directory: URL, preset: JPEGPreset, format: FrameImageFormat = .jpeg,
                                cancelled: @escaping @Sendable () -> Bool) throws {
        _ = try JPEGExport.writeProgramFrameDirectory(to: directory, cancelled: cancelled, validate: validateIdentity) { staging in
            let jpeg = try encoded(preset: preset, format: format, cancelled: cancelled)
            let name = "000001." + format.fileExtension
            try jpeg.data.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
            return Manifest(preset: preset, format: format == .jpeg ? nil : format,
                            frames: [.init(file: name, asset: asset.id, placement: placementID,
                                           from: interval.from, to: interval.to,
                                           width: jpeg.width, height: jpeg.height)])
        }
    }
}
