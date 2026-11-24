import CoreGraphics
import ImageIO
import MPCutCore
import SwiftUI

struct TilesThumbnailSource: Hashable, Sendable {
    let url: URL
    let identity: SourceIdentity
    let changeTime: SourceIdentity.ChangeTime?
    let stream: Int?
    let offset: RationalTime

    init(_ media: MediaInfo) {
        url = media.url
        identity = media.identity
        changeTime = media.identity.changeTime
        stream = media.videoStream?.index
        offset = media.multicamClockOffset
    }
}

actor TilesThumbnailRenderer {
    static let shared = TilesThumbnailRenderer()

    private struct FrameKey: Hashable {
        let source: TilesThumbnailSource
        let time: RationalTime
    }

    private var frames = TilesThumbnailCache<FrameKey>(limit: 8 * 1024 * 1024)
    private var provisionalIndex: (TilesThumbnailSource, MediaInfo)?
    private var releaseIndex: Task<Void, Never>?

    func image(media: MediaInfo, time: RationalTime, bounds: CGRect) throws -> CGImage? {
        try Task.checkCancellation()
        let source = TilesThumbnailSource(media)
        guard source.identity.isCurrentSnapshot(at: source.url) else {
            discardSource(source.url)
            return nil
        }
        let indexed = try indexedMedia(media, source: source)
        let clock = try time.adding(indexed.multicamClockOffset)
        let target = try JPEGExport.stillFrameTime(in: indexed, at: clock)
        let key = FrameKey(source: TilesThumbnailSource(indexed), time: target)
        frames.remove { $0.source.url == source.url && $0.source != key.source }
        let frame: CGImage
        if let saved = frames.image(for: key) {
            frame = saved
        } else {
            let (jpeg, _) = try JPEGExport.reviewFrame(indexed, at: clock, exclusiveEnd: false,
                                                       cancelled: { Task.isCancelled })
            try Task.checkCancellation()
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, options) else { return nil }
            frame = decoded
            frames.insert(decoded, for: key)
        }
        let result = Self.crop(frame, bounds: bounds)
        try Task.checkCancellation()
        guard source.identity.isCurrentSnapshot(at: source.url) else {
            discardSource(source.url)
            return nil
        }
        return result
    }

    private func indexedMedia(_ media: MediaInfo, source: TilesThumbnailSource) throws -> MediaInfo {
        if media.hasFullEditIndex {
            if provisionalIndex?.0 == source {
                releaseIndex?.cancel()
                provisionalIndex = nil
            }
            return media
        }
        let index: MediaInfo
        if let saved = provisionalIndex, saved.0 == source {
            index = saved.1
        } else {
            index = try CutEngine(cancelled: { Task.isCancelled }).inspect(
                media.url, keyframes: true, expectedIdentity: source.identity
            )
            guard index.identity.matchesSnapshot(source.identity) else { throw CancellationError() }
            provisionalIndex = (source, index)
        }
        releaseIndex?.cancel()
        releaseIndex = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await self?.expireProvisionalIndex()
        }
        return index
    }

    private func expireProvisionalIndex() {
        guard !Task.isCancelled else { return }
        provisionalIndex = nil
        releaseIndex = nil
    }

    private func discardSource(_ url: URL) {
        frames.remove { $0.source.url == url }
        if provisionalIndex?.0.url == url {
            releaseIndex?.cancel()
            provisionalIndex = nil
        }
    }

    static func crop(_ image: CGImage, bounds: CGRect) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let minX = max(0, ceil(bounds.minX * width)), maxX = min(width, floor(bounds.maxX * width))
        let minY = max(0, ceil(bounds.minY * height)), maxY = min(height, floor(bounds.maxY * height))
        guard maxX > minX, maxY > minY,
              let crop = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)) else {
            return nil
        }
        let scale = min(1, 160 / CGFloat(max(crop.width, crop.height)))
        let size = CGSize(width: max(1, (CGFloat(crop.width) * scale).rounded()),
                          height: max(1, (CGFloat(crop.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.draw(crop, in: CGRect(origin: .zero, size: size))
        return bitmap.makeImage()
    }
}

struct TilesThumbnailCache<Key: Hashable> {
    let limit: Int
    let countLimit: Int
    private(set) var bytes = 0
    private var entries: [Key: CGImage] = [:]
    private var order: [Key] = []

    init(limit: Int, countLimit: Int = 32) {
        self.limit = limit
        self.countLimit = countLimit
    }

    mutating func image(for key: Key) -> CGImage? {
        guard let image = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    mutating func insert(_ image: CGImage, for key: Key) {
        let cost = image.bytesPerRow * image.height
        guard cost <= limit, countLimit > 0 else { return }
        if let existing = entries.removeValue(forKey: key) {
            bytes -= existing.bytesPerRow * existing.height
            order.removeAll { $0 == key }
        }
        while bytes + cost > limit || order.count >= countLimit {
            if let oldest = entries.removeValue(forKey: order.removeFirst()) {
                bytes -= oldest.bytesPerRow * oldest.height
            }
        }
        entries[key] = image
        order.append(key)
        bytes += cost
    }

    mutating func remove(where shouldRemove: (Key) -> Bool) {
        order.removeAll { key in
            guard shouldRemove(key), let image = entries.removeValue(forKey: key) else { return false }
            bytes -= image.bytesPerRow * image.height
            return true
        }
    }
}

struct TilesReviewThumbnail: View {
    let time: RationalTime
    let bounds: CGRect
    let media: MediaInfo

    init(card: TilesReviewCard, media: MediaInfo) {
        self.time = card.time
        let rect = card.representative.rect
        self.bounds = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        self.media = media
    }

    init(tile: ParticipantAppearance, media: MediaInfo) {
        self.time = tile.range.from
        self.bounds = tile.bounds.rect
        self.media = media
    }

    private struct Snapshot: Equatable {
        let source: TilesThumbnailSource
        let indexed: Bool
        let time: RationalTime
        let bounds: CGRect
    }

    @State private var loaded: (Snapshot, CGImage)?

    var body: some View {
        let request = Snapshot(source: TilesThumbnailSource(media), indexed: media.hasFullEditIndex, time: time, bounds: bounds)
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let (cached, image) = loaded, cached == request {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 54, height: 36)
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: request, priority: .utility) {
            guard let image = try? await TilesThumbnailRenderer.shared.image(media: media, time: time, bounds: bounds),
                  !Task.isCancelled else {
                if !Task.isCancelled { loaded = nil }
                return
            }
            loaded = (request, image)
        }
    }
}
