import AppKit
import MPCutCore
import SwiftUI

/// One active request per recording preserves decoder seek order. A shared limit
/// also bounds simultaneous hardware sessions doing work across project windows.
@MainActor
private final class MulticamThumbnailWork {
    static let shared = MulticamThumbnailWork(limit: min(4, ProcessInfo.processInfo.activeProcessorCount))

    private struct Waiter {
        let id: UUID
        let url: URL
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = Set<URL>()
    private var waiting: [Waiter] = []

    init(limit: Int) { self.limit = limit }

    func run(url: URL, work: @MainActor () async -> CGImage?) async -> CGImage? {
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiting.append(Waiter(id: id, url: url, continuation: continuation))
                admitWaiting()
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: index).continuation.resume(returning: false)
            }
        }
        guard admitted else { return nil }
        defer {
            active.remove(url)
            admitWaiting()
        }
        guard !Task.isCancelled else { return nil }
        return await work()
    }

    private func admitWaiting() {
        while active.count < limit, let index = waiting.firstIndex(where: { !active.contains($0.url) }) {
            let next = waiting.remove(at: index)
            active.insert(next.url)
            next.continuation.resume(returning: true)
        }
    }
}

@MainActor
final class MulticamThumbnailService {
    @MainActor
    private struct Decoder {
        let id: UUID
        let preview = SequencePreview()
    }

    private struct CacheKey: Hashable {
        let source: UUID
        let section: String
        let reuseSidecar: Bool
        let indexed: Bool
    }

    private struct CachedTile {
        let tile: FilmstripTile
        let rendered: Bool

        var bytes: Int { tile.image.bytesPerRow * tile.image.height }
    }

    private struct CachedCoverage {
        let identity: SourceIdentity
        let clockOffset: RationalTime
        let gaps: [Range<Double>]
    }

    let sidecarPreference = SidecarPreference()
    private static let byteLimit = 16 * 1024 * 1024
    private var sources: [URL: (identity: SourceIdentity, id: UUID)] = [:]
    private var decoders: [URL: Decoder] = [:]
    private var decoderOrder: [URL] = []
    private var decoderUse: [URL: ContinuousClock.Instant] = [:]
    private let decoderLimit: Int
    private let decoderIdle: Duration
    private var decoderCleanup: Task<Void, Never>?

    /// Keep a decoder for every camera used within `decoderIdle`, and `decoderLimit` beyond those.
    init(decoderLimit: Int = 4, decoderIdle: Duration = .seconds(10)) {
        self.decoderLimit = decoderLimit
        self.decoderIdle = decoderIdle
    }
    private var images: [CacheKey: CachedTile] = [:]
    private var imageOrder: [CacheKey] = []
    private var cachedBytes = 0
    private var coverage: [URL: CachedCoverage] = [:]
    /// Each one opens the recording and a hardware decoding session.
    private(set) var decodersOpened = 0
    var openDecoders: Int { decoders.count }

    func pictureGaps(in media: MediaInfo) -> [Range<Double>] {
        guard !media.frames.isEmpty else { return [] }
        if let entry = coverage[media.url], entry.identity == media.identity,
           entry.clockOffset == media.multicamClockOffset {
            return entry.gaps
        }
        let gaps = MulticamFilmstrip.pictureGaps(in: media.frames)
        coverage[media.url] = CachedCoverage(identity: media.identity, clockOffset: media.multicamClockOffset, gaps: gaps)
        return gaps
    }

    func image(media: MediaInfo, key: FilmstripTileKey, reuseSidecar: Bool) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let url = media.url
        let sourceID = sources[url].flatMap { $0.identity == media.identity ? $0.id : nil } ?? UUID()
        sources[url] = (media.identity, sourceID)
        let cacheKey = CacheKey(source: sourceID, section: key.section,
                                reuseSidecar: reuseSidecar && sidecarPreference.permits(media.url),
                                indexed: media.hasFullEditIndex)
        if let image = cachedImage(cacheKey) { return image }
        return await MulticamThumbnailWork.shared.run(url: url) {
            guard self.sources[url]?.id == sourceID else { return nil }
            // Another tile can request the same frame and size while this request waits.
            if let image = self.cachedImage(cacheKey) { return image }
            return await self.render(media: media, key: key, cacheKey: cacheKey)
        }
    }

    private func cachedImage(_ cacheKey: CacheKey) -> CGImage? {
        if let entry = images[cacheKey] {
            imageOrder.removeAll { $0 == cacheKey }
            imageOrder.append(cacheKey)
            return entry.tile.image
        }
        return nil
    }

    private func render(media: MediaInfo, key: FilmstripTileKey, cacheKey: CacheKey) async -> CGImage? {
        let url = media.url
        let sourceID = cacheKey.source
        let decoder: Decoder
        if let open = decoders[url], open.id == sourceID {
            decoder = open
        } else {
            decoder = Decoder(id: sourceID)
            decodersOpened += 1
        }
        decoders[url] = decoder
        decoderOrder.removeAll { $0 == url }
        decoderUse[url] = nil
        defer {
            if decoders[url]?.id == sourceID {
                decoderOrder.append(url)
                decoderUse[url] = .now
                releaseIdleDecoders()
            }
        }

        let saved = cacheKey.reuseSidecar && cacheKey.indexed ? (AnalysisSidecar(media: media), key) : nil
        var rendered = false
        let image = await decoder.preview.thumbnail(source: decoder.id, url: url, at: key.time, size: key.size,
                                                    saved: saved, cacheEnabled: { [sidecarPreference] in sidecarPreference.permits(url) },
                                                    preserveAlpha: media.video.hasAlpha ||
                                                        media.video.hasAdditionalVideoLayers) { _ in rendered = true }
        guard let image, sources[url]?.id == sourceID else { return nil }
        let entry = CachedTile(tile: FilmstripTile(key: key, image: image), rendered: rendered)
        if entry.bytes <= Self.byteLimit {
            remove(cacheKey)
            while cachedBytes + entry.bytes > Self.byteLimit || imageOrder.count >= FilmstripTileBuffer.countLimit {
                guard let oldest = imageOrder.first else { break }
                remove(oldest)
            }
            images[cacheKey] = entry
            imageOrder.append(cacheKey)
            cachedBytes += entry.bytes
        }
        return image
    }

    private func releaseIdleDecoders() {
        decoderCleanup?.cancel()
        decoderCleanup = nil
        let now = ContinuousClock.now
        // Only completed requests are in decoderOrder. Keep recently used cameras
        // open for interleaved tiles, even when they exceed the usual decoder limit.
        while decoders.count > decoderLimit, let oldest = decoderOrder.first,
              let lastUse = decoderUse[oldest] {
            let expires = lastUse + decoderIdle
            guard expires <= now else {
                decoderCleanup = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: expires) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.releaseIdleDecoders()
                }
                return
            }
            decoderOrder.removeFirst()
            decoders[oldest] = nil
            decoderUse[oldest] = nil
        }
    }

    private func remove(_ key: CacheKey) {
        if let entry = images.removeValue(forKey: key) {
            cachedBytes -= entry.bytes
            imageOrder.removeAll { $0 == key }
        }
    }

    func reset() {
        decoderCleanup?.cancel()
        decoderCleanup = nil
        sources.removeAll()
        decoders.removeAll()
        decoderOrder.removeAll()
        decoderUse.removeAll()
        images.removeAll()
        imageOrder.removeAll()
        cachedBytes = 0
        coverage.removeAll()
    }

    func snapshot(for media: MediaInfo) -> [FilmstripTile] {
        guard let source = sources[media.url], source.identity == media.identity else { return [] }
        var seen = Set<String>()
        return imageOrder.reversed().compactMap { key in
            guard key.source == source.id, key.indexed, let entry = images[key], entry.rendered,
                  seen.insert(key.section).inserted else { return nil }
            return entry.tile
        }.reversed()
    }
}

enum MulticamFilmstrip {
    static func tileTimeRange(_ index: Int, count: Int, coverage: Range<Double>) -> Range<Double> {
        // The pixel coordinate round-trip can put an exact boundary just after its indexed frame.
        let duration = coverage.upperBound - coverage.lowerBound
        func edge(_ index: Int) -> Double {
            if index == count { return coverage.upperBound }
            return min(coverage.upperBound, coverage.lowerBound + duration * (Double(index) / Double(count)))
        }
        return edge(index)..<edge(index + 1)
    }

    static func pictureCoverage(in media: MediaInfo) -> Range<Double>? {
        let start: Double
        let end: Double
        if let first = media.frames.first, let last = media.frames.last,
           let lastEnd = try? last.time.adding(last.duration) {
            start = max(0, first.time.seconds)
            end = min(lastEnd, media.duration).seconds
        } else {
            guard !media.hasFullEditIndex, let stream = media.videoStream,
                  stream.duration > .zero, let streamEnd = try? stream.start.adding(stream.duration) else { return nil }
            start = max(0, stream.start.seconds)
            end = min(streamEnd, media.duration).seconds
        }
        return start < end ? start..<end : nil
    }

    static func thumbnailTime(in media: MediaInfo, from start: Double, to end: Double) -> Double? {
        if media.hasFullEditIndex || !media.frames.isEmpty {
            return thumbnailTime(in: media.frames, from: start, to: end, clockOffset: media.multicamClockOffset)
        }
        guard let coverage = pictureCoverage(in: media) else { return nil }
        let lower = max(start, coverage.lowerBound)
        let upper = min(end, coverage.upperBound)
        guard lower < upper else { return nil }
        let time = end - start < 0.5 ? lower + (upper - lower) / 2 : lower
        return max(0, time - media.multicamClockOffset.seconds)
    }

    static func pictureGaps(in frames: [FrameInfo]) -> [Range<Double>] {
        var coveredThrough: RationalTime?
        var gaps: [Range<Double>] = []
        for frame in frames {
            guard let end = try? frame.time.adding(frame.duration) else { continue }
            if let coveredThrough, coveredThrough < frame.time {
                gaps.append(coveredThrough.seconds..<frame.time.seconds)
            }
            coveredThrough = max(coveredThrough ?? end, end)
        }
        return gaps
    }

    static func thumbnailTime(in frames: [FrameInfo], from start: Double, to end: Double,
                              clockOffset: RationalTime) -> Double? {
        guard start < end else { return nil }
        let first = frames.lowerBound { $0.time.seconds >= start }
        let middle = start + (end - start) / 2
        let middleIndex = frames.lowerBound { $0.time.seconds > middle } - 1
        let candidate: FrameInfo
        if end - start < 0.5, frames.indices.contains(middleIndex),
           let frameEnd = try? frames[middleIndex].time.adding(frames[middleIndex].duration),
           middle < frameEnd.seconds {
            candidate = frames[middleIndex]
        } else if frames.indices.contains(first), frames[first].time.seconds < end {
            candidate = frames[first]
        } else if first > 0,
                  let frameEnd = try? frames[first - 1].time.adding(frames[first - 1].duration),
                  start < frameEnd.seconds {
            candidate = frames[first - 1]
        } else { return nil }
        // The single-source decoder and existing sidecar tiles measure from
        // the first picture when a movie begins with an empty edit.
        return (try? candidate.time.subtracting(clockOffset)).map { max(0, $0.seconds) }
    }
}

@MainActor
struct MulticamThumbnail: View {
    let service: MulticamThumbnailService
    let media: MediaInfo
    let time: Double
    let size: CGSize
    let useAnalysisSidecars: Bool

    private struct Request: Equatable {
        let url: URL
        let identity: SourceIdentity
        let indexed: Bool
        let tile: FilmstripTileKey?
        let useAnalysisSidecars: Bool

        func displaysSameTile(as other: Self) -> Bool {
            url == other.url && identity == other.identity && tile == other.tile
                && useAnalysisSidecars == other.useAnalysisSidecars
        }
    }

    @State private var loaded: (request: Request, image: CGImage)?

    var body: some View {
        let request = Request(url: media.url, identity: media.identity, indexed: media.hasFullEditIndex,
                              tile: FilmstripTileKey(time: time, size: size),
                              useAnalysisSidecars: useAnalysisSidecars)
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let loaded, loaded.request.displaysSameTile(as: request) {
                    let width = media.videoStream?.displayWidth ?? 0
                    let height = media.videoStream?.displayHeight ?? 0
                    let aspect = width > 0 && height > 0
                        ? CGFloat(width) / CGFloat(height) : CGFloat(loaded.image.width) / CGFloat(loaded.image.height)
                    Image(decorative: loaded.image, scale: 1)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipped()
        }
        .task(id: request) {
            guard let key = request.tile,
                  let image = await service.image(media: media, key: key, reuseSidecar: request.useAnalysisSidecars),
                  !Task.isCancelled else { return }
            loaded = (request, image)
        }
        .accessibilityHidden(true)
    }
}
