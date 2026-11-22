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

    package init(asset: StillAsset, placementID: String, framing: StillImageFraming,
                 interval: MulticamRange, document: URL?, width: Int, height: Int) throws {
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

    package func image(maximumDimension: Int?, cancelled: @escaping () -> Bool) throws -> CGImage {
        try checkCancellation(cancelled)
        try validateIdentity()
        guard try StillImage.fingerprint(url, cancelled: cancelled) == asset.fingerprint else {
            throw CutError(code: "source_changed", message: "Relink the changed image \(asset.displayName).")
        }
        try checkCancellation(cancelled)
        let aspect = Double(width) / Double(height)
        let scale = maximumDimension.map { min(1, Double($0) / Double(max(width, height))) } ?? 1
        let renderWidth = max(1, Int((Double(width) * scale).rounded()))
        let renderHeight = max(1, Int((Double(height) * scale).rounded()))
        let image = try StillImage.render(url, canvas: StillImageCanvas(width: renderWidth, height: renderHeight, displayAspect: aspect),
                                          framing: framing, forceSDR: true, preview: maximumDimension != nil,
                                          cancelled: cancelled).sdrImage()
        try checkCancellation(cancelled)
        try validateIdentity()
        return image
    }

    package func jpeg(preset: JPEGPreset, cancelled: @escaping () -> Bool) throws -> (data: Data, width: Int, height: Int) {
        let image = try image(maximumDimension: preset == .review ? 640 : nil, cancelled: cancelled)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CutError(code: "frame_export_failed", message: "Could not create a JPEG encoder.")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: preset == .review ? 0.62 : 0.95] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CutError(code: "frame_export_failed", message: "Could not encode the still review JPEG.")
        }
        try checkCancellation(cancelled)
        guard preset != .review || data.length <= 1_048_576 else {
            throw CutError(code: "image_too_large", message: "The review JPEG exceeds 1 MiB.")
        }
        return (data as Data, image.width, image.height)
    }

    package func write(to output: URL, replacing identity: SourceIdentity? = nil,
                       preset: JPEGPreset = .full, cancelled: @escaping @Sendable () -> Bool) throws {
        try checkCancellation(cancelled)
        try JPEGExport.validateStillDestination(output, source: url, sourceIdentity: self.identity, replacing: identity)
        let jpeg = try jpeg(preset: preset, cancelled: cancelled)
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
        let width: Int
        let height: Int
        if let format = stillFormat {
            (width, height) = (format.width, format.height)
        } else if let geometry = canvas?.videoStream {
            width = geometry.displayWidth > 0 ? geometry.displayWidth : geometry.width
            height = geometry.displayHeight > 0 ? geometry.displayHeight : geometry.height
        } else {
            throw CutError(code: "invalid_canvas", message: "The program needs a video reference for image dimensions.")
        }
        return try StillReviewFrame(asset: asset, placementID: placementID, framing: framing, interval: interval,
                                    document: document, width: width, height: height)
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
        let version = 1
        let selection = "program"
        let preset: JPEGPreset
        let frames: [Frame]
    }

    package func writeDirectory(to directory: URL, preset: JPEGPreset,
                                cancelled: @escaping @Sendable () -> Bool) throws {
        _ = try JPEGExport.writeProgramFrameDirectory(to: directory, cancelled: cancelled, validate: validateIdentity) { staging in
            let jpeg = try jpeg(preset: preset, cancelled: cancelled)
            let name = "000001.jpg"
            try jpeg.data.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
            return Manifest(preset: preset, frames: [.init(file: name, asset: asset.id, placement: placementID,
                                                           from: interval.from, to: interval.to,
                                                           width: jpeg.width, height: jpeg.height)])
        }
    }
}
