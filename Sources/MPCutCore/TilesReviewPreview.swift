import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension TilesReview {
    public func writePreview(at time: RationalTime, to output: URL,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        try writePreview(to: output, cancelled: cancelled) { media in
            try previewFrame(media, at: time, cancelled: cancelled)
        }
    }

    public func writePreview(issue: TilesIssue, to output: URL,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        try writePreview(to: output, cancelled: cancelled) { media in
            try issuePreview(media, issue: issue, cancelled: cancelled)
        }
    }

    private func issuePreview(_ media: MediaInfo, issue: TilesIssue,
                              cancelled: @escaping @Sendable () -> Bool) throws -> CGImage {
        guard let time = issue.sourceTime ?? issue.range?.from else {
            throw CutError(code: "no_frame", message: "This issue has no source timestamp.")
        }
        let after = try previewFrame(media, at: time, cancelled: cancelled)
        if let preceding = issue.precedingTime {
            let before = try previewFrame(media, at: preceding, cancelled: cancelled)
            return try TilesPreviewPicture.pair(before, after, titles: ("Before departure", "After return"))
        }
        guard issue.kind == .layoutChange, time > .zero else { return after }
        let before: CGImage
        do {
            before = try previewFrame(media, at: time, exclusiveEnd: true, cancelled: cancelled)
        } catch let error as CutError where error.code == "no_frame" {
            return after
        }
        return try TilesPreviewPicture.pair(before, after, titles: ("Before layout change", "After layout change"))
    }

    private func previewMedia(cancelled: @escaping @Sendable () -> Bool) throws -> MediaInfo {
        guard let mediaURL else {
            throw CutError(code: "missing_media", message: "This tile review has no source recording.")
        }
        let engine = CutEngine(cancelled: cancelled)
        if let index = try engine.cachedIndex(mediaURL) { return index }
        return try engine.inspectFresh(mediaURL, keyframes: true, allowAutomaticSave: { false })
    }

    private func previewFrame(_ media: MediaInfo, at time: RationalTime, exclusiveEnd: Bool = false,
                              cancelled: @escaping @Sendable () -> Bool) throws -> CGImage {
        guard time >= .zero else {
            throw CutError(code: "no_frame", message: "No picture covers negative source time \(time).")
        }
        let (jpeg, frame) = try JPEGExport.reviewFrame(media, at: time.adding(media.multicamClockOffset),
                                                       exclusiveEnd: exclusiveEnd, cancelled: cancelled)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CutError(code: "frame_export_failed", message: "Could not decode the tile review image.")
        }
        // Use the actual picture timestamp for the picture immediately preceding a
        // boundary. The tile intervals themselves are half-open.
        let tileTime = exclusiveEnd ? try frame.frameTime.subtracting(media.multicamClockOffset) : time
        return try TilesPreviewPicture.annotated(image, tiles: report(at: tileTime).tiles)
    }

    private func writePreview(to output: URL, cancelled: @escaping @Sendable () -> Bool,
                              picture: (MediaInfo) throws -> CGImage) throws {
        guard output.isFileURL, output.pathExtension.lowercased() == "png" else {
            throw CutError(code: "invalid_output", message: "Choose a PNG file for the tile review image.")
        }
        var entry = stat()
        guard lstat(output.path, &entry) != 0 else {
            throw CutError(code: "output_exists", message: "The tile review destination already exists.")
        }
        let folder = output.deletingLastPathComponent()
        try TilesISODelivery.validateReviewDestination(folder)
        let media = try previewMedia(cancelled: cancelled)
        let image = try picture(media)
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw CutError(code: "frame_export_failed", message: "Could not create the tile review PNG encoder.")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else {
            throw CutError(code: "frame_export_failed", message: "Could not encode the tile review PNG.")
        }
        let stage = folder.appendingPathComponent(".mpcut-tiles-preview-\(UUID().uuidString)")
        do {
            try (bytes as Data).write(to: stage, options: .withoutOverwriting)
        } catch {
            throw CutError(code: "write_failed", message: "Could not write the tile review PNG in the output folder.")
        }
        defer { try? FileManager.default.removeItem(at: stage) }
        guard !Task.isCancelled, !cancelled() else {
            throw CutError(code: "cancelled", message: "Tile preview was cancelled.")
        }
        guard media.identity.isCurrentSnapshot(at: media.url) else {
            throw CutError(code: "source_changed", message: "The source changed after indexing.")
        }
        try TilesISODelivery.validateReviewDestination(folder)
        let failure = publishExclusively(from: stage, to: output)
        guard failure == 0 else {
            let exists = failure == EEXIST || failure == ENOTEMPTY
            throw CutError(code: exists ? "output_exists" : "write_failed",
                           message: exists ? "The tile review destination already exists." : "Could not publish the tile review PNG.")
        }
    }
}

enum TilesPreviewPicture {
    private static func canvas(width: Int, height: Int) throws -> CGContext {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: color,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CutError(code: "frame_export_failed", message: "Could not create the tile review canvas.")
        }
        return context
    }

    private static func picture(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw CutError(code: "frame_export_failed", message: "Could not render the tile review image.")
        }
        return image
    }

    static func annotated(_ image: CGImage, tiles: [TilesTile]) throws -> CGImage {
        let context = try canvas(width: image.width, height: image.height)
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: frame)
        for tile in tiles {
            let bounds = tile.bounds
            let box = CGRect(x: bounds.x * frame.width, y: (1 - bounds.y - bounds.height) * frame.height,
                             width: bounds.width * frame.width, height: bounds.height * frame.height)
                .intersection(frame)
            guard !box.isEmpty else { continue }
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.85))
            context.setLineWidth(4)
            context.stroke(box)
            context.setStrokeColor(CGColor(red: 0.15, green: 0.93, blue: 0.85, alpha: 1))
            context.setLineWidth(2)
            context.stroke(box)
            let name = tile.feedID.map { "\(tile.tileID) · \($0)" } ?? tile.tileID
            label(name, in: box, context: context)
        }
        return try picture(context)
    }

    static func pair(_ before: CGImage, _ after: CGImage, titles: (String, String)) throws -> CGImage {
        let gap = 8
        let header = 26
        let contentHeight = max(before.height, after.height)
        let context = try canvas(width: before.width + gap + after.width, height: contentHeight + header)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let pictures = [(before, 0, titles.0), (after, before.width + gap, titles.1)]
        for (image, x, title) in pictures {
            context.draw(image, in: CGRect(x: x, y: contentHeight - image.height, width: image.width, height: image.height))
            label(title, in: CGRect(x: x, y: contentHeight, width: image.width, height: header), context: context)
        }
        return try picture(context)
    }

    private static func label(_ text: String, in box: CGRect, context: CGContext) {
        guard box.width >= 12, box.height >= 16 else { return }
        let attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = min(box.width, ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 8)
        let background = CGRect(x: box.minX, y: box.maxY - 16, width: width, height: 16)
        context.saveGState()
        context.clip(to: background)
        context.setFillColor(CGColor(gray: 0, alpha: 0.84))
        context.fill(background)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: background.minX + 4, y: background.minY + 4)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
