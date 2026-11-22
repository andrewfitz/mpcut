import CoreGraphics
import Foundation
import ImageIO
import MPCutCore
import UniformTypeIdentifiers

/// The clock and requested backing-pixel size are serialized exactly. A tile from another
/// zoom level or display scale can have the same timestamp and different geometry.
struct FilmstripTileKey: Equatable, Sendable {
    static let sectionPrefix = "filmstrip.v1."
    let time: Double
    let size: CGSize

    init?(time: Double, size: CGSize) {
        guard time.isFinite, time >= 0, size.width > 0, size.width <= 1024,
              size.height > 0, size.height <= 1024 else { return nil }
        self.time = time
        self.size = size
    }

    private var header: Data {
        [time.bitPattern.littleEndian, Double(size.width).bitPattern.littleEndian,
         Double(size.height).bitPattern.littleEndian].withUnsafeBytes { Data($0) }
    }

    var section: String {
        let parts = [time, Double(size.width), Double(size.height)].map { String($0.bitPattern, radix: 16) }
        return Self.sectionPrefix + parts.joined(separator: ".")
    }

    private static let maxBytes = 256 * 1024

    func image(in sidecar: AnalysisSidecar, cancelled: () -> Bool = { Task.isCancelled }) -> CGImage? {
        let key = header
        guard let data = sidecar.read(section, maxBytes: Self.maxBytes + key.count, cancelled: cancelled),
              data.count > key.count,
              data.starts(with: key),
              let source = CGImageSourceCreateWithData(data.dropFirst(key.count) as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              type == UTType.jpeg.identifier || type == UTType.png.identifier,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, CGFloat(width) <= size.width.rounded(.up) + 1,
              height > 0, CGFloat(height) <= size.height.rounded(.up) + 1, !cancelled() else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    func encoded(_ image: CGImage, preserveAlpha: Bool) -> Data? {
        let encoded = NSMutableData()
        let type = preserveAlpha ? UTType.png : .jpeg
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else { return nil }
        let options = preserveAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination), encoded.length <= Self.maxBytes else { return nil }
        return header + (encoded as Data)
    }
}

struct FilmstripTile: Sendable {
    let key: FilmstripTileKey
    let image: CGImage
}

/// Hold references to recent rendered images. Explicit saves can include these even when automatic sidecars are disabled.
struct FilmstripTileBuffer {
    static let countLimit = 256
    private static let byteLimit = 16 * 1024 * 1024
    private struct Entry {
        let source: UUID
        let tile: FilmstripTile
        let cost: Int
    }
    private var entries: [Entry] = []
    private var bytes = 0

    mutating func remember(_ tile: FilmstripTile, source: UUID) {
        let cost = tile.image.bytesPerRow * tile.image.height
        guard cost <= Self.byteLimit else { return }
        if let old = entries.firstIndex(where: { $0.source == source && $0.tile.key == tile.key }) {
            bytes -= entries.remove(at: old).cost
        }
        entries.append(Entry(source: source, tile: tile, cost: cost))
        bytes += cost
        while entries.count > Self.countLimit || bytes > Self.byteLimit {
            bytes -= entries.removeFirst().cost
        }
    }

    func snapshot(for source: UUID) -> [FilmstripTile] {
        entries.compactMap { $0.source == source ? $0.tile : nil }
    }

    mutating func removeSource(_ source: UUID) {
        entries.removeAll { $0.source == source }
        bytes = entries.reduce(0) { $0 + $1.cost }
    }

    mutating func keepSources(_ sources: Set<UUID>) {
        entries.removeAll { !sources.contains($0.source) }
        bytes = entries.reduce(0) { $0 + $1.cost }
    }
}

/// Optional disk writes must never hold the serial decoder queue behind a SQLite writer.
final class FilmstripTileWriter: @unchecked Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "mpcut.filmstrip.persistence"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let lock = NSLock()
    private var retainedBytes = 0
    private var retainedCount = 0

    func submit(_ image: CGImage, key: FilmstripTileKey, sidecar: AnalysisSidecar,
                preserveAlpha: Bool, cancelled: @escaping @Sendable () -> Bool) {
        let cost = image.bytesPerRow * image.height
        let accepted = lock.withLock {
            guard retainedCount < 32, cost <= 16 * 1024 * 1024 - retainedBytes else { return false }
            retainedCount += 1
            retainedBytes += cost
            return true
        }
        guard accepted else { return }
        queue.addOperation { [self] in
            defer {
                lock.withLock {
                    retainedCount -= 1
                    retainedBytes -= cost
                }
            }
            guard !cancelled(), let data = key.encoded(image, preserveAlpha: preserveAlpha) else { return }
            sidecar.saveAutomatically([key.section: data],
                retainingLatest: [FilmstripTileKey.sectionPrefix: FilmstripTileBuffer.countLimit],
                cancelled: cancelled)
        }
    }
}
