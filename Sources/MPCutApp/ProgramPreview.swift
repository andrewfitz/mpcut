import AVFoundation
import MPCutCore

struct ProgramPreviewStills: Equatable, Sendable {
    struct Picture: Equatable, Sendable {
        let output: MulticamRange
        let asset: StillAsset
        let placementID: String
        let url: URL
        let document: URL?
        let framing: StillImageFraming
    }

    let pictures: [Picture]
    let duration: RationalTime
    let canvas: StillImageCanvas

    init?(project: CutProject?, reference: MediaInfo?, document: URL? = nil) {
        guard let project, !project.stillAssets.isEmpty, let resolved = try? project.resolveStills() else { return nil }
        let assets = Dictionary(project.stillAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inserts = Dictionary(project.stillInserts.map { ($0.id, ($0.assetID, $0.framing)) },
                                 uniquingKeysWith: { first, _ in first })
        let replacements = Dictionary(project.stillReplacements.map { ($0.id, ($0.assetID, $0.framing)) },
                                       uniquingKeysWith: { first, _ in first })
        pictures = resolved.spans.compactMap { span in
            guard let id = span.placementID, let (assetID, framing) = inserts[id] ?? replacements[id],
                  let asset = assets[assetID] else { return nil }
            let url = document.map { CutProject.mediaURL(asset.file, relativeTo: $0) } ?? URL(fileURLWithPath: asset.file)
            return Picture(output: span.output, asset: asset, placementID: id, url: url, document: document, framing: framing)
        }
        guard !pictures.isEmpty else { return nil }
        let stream = reference?.videoStream
        let geometry = project.stillReviewGeometry(reference: reference) ?? (1920, 1080, 16.0 / 9)
        let (width, height, aspect) = geometry
        let scale = min(1, 1920.0 / Double(max(width, height)))
        let transfer = project.programColorPolicy?.transfer ?? stream?.colorTransfer
        let primaries = project.programColorPolicy?.primaries ?? stream?.colorPrimaries
        canvas = StillImageCanvas(width: max(1, Int(Double(width) * scale)),
                                  height: max(1, Int(Double(height) * scale)),
                                  displayAspect: aspect,
                                  transfer: transfer == "unknown" ? "bt709" : transfer ?? "bt709",
                                  primaries: primaries == "unknown" ? "bt709" : primaries ?? "bt709",
                                  diffuseWhiteNits: project.programColorPolicy?.diffuseWhiteNits ?? 203)
        duration = resolved.duration
    }

    func picture(at time: Double) -> Picture? {
        let index = pictures.lowerBound { $0.output.to.seconds > time }
        if time == duration.seconds, pictures.last?.output.to == duration { return pictures.last }
        guard pictures.indices.contains(index), pictures[index].output.from.seconds <= time else { return nil }
        return pictures[index]
    }

    func picture(at time: RationalTime) -> Picture? {
        let index = pictures.lowerBound { $0.output.to > time }
        if time == duration, pictures.last?.output.to == duration { return pictures.last }
        guard pictures.indices.contains(index), pictures[index].output.from <= time else { return nil }
        return pictures[index]
    }
}

/// One normalized still is shared by the viewers. A result from a retired seek
/// can never return to the program, including while the source is still decoding.
@MainActor
final class ProgramStillPreview {
    private let renderer = ProgramPreviewRenderer()
    private var request: Task<Void, Never>?
    private var generation = 0
    private var current: ProgramPreviewStills.Picture?
    private var canvas: StillImageCanvas?

    deinit { request?.cancel() }

    func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        current = nil
        canvas = nil
    }

    func show(_ picture: ProgramPreviewStills.Picture, canvas: StillImageCanvas,
              onPending: () -> Void, complete: @escaping (Result<PreviewFrame, Error>) -> Void) {
        guard current != picture || self.canvas != canvas else { return }
        cancel()
        onPending()
        current = picture
        self.canvas = canvas
        let generation = generation
        let renderer = renderer
        request = Task { [weak self] in
            let result: Result<PreviewFrame, Error>
            do {
                result = .success(try await renderer.render(picture, canvas: canvas))
            } catch {
                result = .failure(error)
            }
            guard self?.generation == generation, !Task.isCancelled else { return }
            complete(result)
        }
    }
}

actor ProgramPreviewRenderer {
    func render(_ picture: ProgramPreviewStills.Picture, canvas: StillImageCanvas) throws -> PreviewFrame {
        try Task.checkCancellation()
        let review = try StillReviewFrame(asset: picture.asset, placementID: picture.placementID,
                                         framing: picture.framing, interval: picture.output, document: picture.document,
                                         width: canvas.width, height: canvas.height,
                                         displayAspect: canvas.displayAspect ?? Double(canvas.width) / Double(canvas.height))
        try review.validateAsset(cancelled: { Task.isCancelled })
        let surface = try StillImage.render(review.url, canvas: canvas, framing: picture.framing, preview: true, expectedIdentity: review.identity,
                                            cancelled: { Task.isCancelled })
        let buffer = try surface.pixelBuffer
        try Task.checkCancellation()
        try review.validateIdentity()
        return PreviewFrame(buffer: buffer, time: previewTime(picture.output.from), transform: .identity,
                            programTransfer: canvas.transfer, sourceRendition: label(surface.sourceInfo.rendition))
    }

    private func label(_ rendition: StillImageInfo.Rendition) -> String {
        switch rendition {
        case .sdr: "SDR"
        case .pq: "PQ"
        case .hlg: "HLG"
        case .linearHDR: "Linear HDR"
        case .gainMap: "HDR gain map"
        }
    }
}
