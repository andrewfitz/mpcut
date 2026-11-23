import CoreGraphics
import Foundation
import ImageIO
import MPCutCore
import UniformTypeIdentifiers

/// The clock and requested backing-pixel size are serialized exactly. A tile from another
/// zoom level or display scale can have the same timestamp and different geometry.
struct FilmstripTileKey: Equatable, Sendable {
    static let sectionPrefix = "timeline_filmstrip.v1."
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
    private struct Request {
        let image: CGImage
        let key: FilmstripTileKey
        let sidecar: AnalysisSidecar
        let preserveAlpha: Bool
        let cancelled: @Sendable () -> Bool
        var cost: Int { image.bytesPerRow * image.height }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "mpcut.filmstrip.persistence"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let lock = NSLock()
    private var pending: [Request] = []
    private var draining = false
    private var retainedBytes = 0
    private var retainedCount = 0

    func submit(_ image: CGImage, key: FilmstripTileKey, sidecar: AnalysisSidecar,
                preserveAlpha: Bool, cancelled: @escaping @Sendable () -> Bool) {
        let cost = image.bytesPerRow * image.height
        let startDrain = lock.withLock {
            guard retainedCount < 32, cost <= 16 * 1024 * 1024 - retainedBytes else { return false }
            retainedCount += 1
            retainedBytes += cost
            pending.append(Request(image: image, key: key, sidecar: sidecar, preserveAlpha: preserveAlpha,
                                   cancelled: cancelled))
            guard !draining else { return false }
            draining = true
            return true
        }
        if startDrain { queue.addOperation { [self] in drain() } }
    }

    private func drain() {
        while let batch = takeBatch() {
            save(batch)
            lock.withLock {
                retainedCount -= batch.count
                retainedBytes -= batch.reduce(0) { $0 + $1.cost }
            }
        }
    }

    private func takeBatch() -> [Request]? {
        lock.withLock {
            guard let first = pending.first else {
                draining = false
                return nil
            }
            // Commit promptly and cap the time a burst can hold the SQLite write lock.
            let batch = pending.prefix(8).prefix {
                $0.sidecar.source == first.sidecar.source &&
                    $0.sidecar.identity == first.sidecar.identity &&
                    $0.sidecar.identity.changeTime == first.sidecar.identity.changeTime
            }
            let requests = Array(batch)
            pending.removeFirst(requests.count)
            return requests
        }
    }

    private func save(_ batch: [Request]) {
        guard let sidecar = batch.first?.sidecar else { return }
        let encoded = batch.compactMap { request -> (key: String, value: Data, cancelled: @Sendable () -> Bool)? in
            guard !request.cancelled(),
                  let data = autoreleasepool(invoking: { request.key.encoded(request.image, preserveAlpha: request.preserveAlpha) })
            else { return nil }
            return (request.key.section, data, request.cancelled)
        }
        let active = encoded.filter { !$0.cancelled() }
        let prefix = FilmstripTileKey.sectionPrefix
        let limit = FilmstripTileBuffer.countLimit
        do {
            try sidecar.saveOrderedCacheEntries(active.map { ($0.key, $0.value) }, prefix: prefix, keepingLatest: limit,
                                                 cancelled: { active.contains { $0.cancelled() } })
        } catch let error as CutError where error.code == "cancelled" {
            // A request can be cancelled independently of the other tiles in its transaction.
            for entry in active {
                sidecar.saveAutomatically([entry.key: entry.value], retainingLatest: [prefix: limit],
                                          cancelled: entry.cancelled)
            }
        } catch {
            // Filmstrip persistence is best effort.
        }
    }
}
