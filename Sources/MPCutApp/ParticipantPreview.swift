import AVFoundation
import Combine
import MPCutCore

struct ParticipantPreviewCells: Equatable, Sendable {
    struct Cell: Equatable, Sendable {
        let slot: ParticipantSlot
        let rect: CGRect
    }

    let time: RationalTime
    let size: CGSize
    let cells: [Cell]
}

/// Converts decoded video to program pictures before it reaches any Output surface.
/// A slow render can drop intermediate requests while playback and audio continue.
@MainActor
final class ParticipantPreview {
    private struct Request: Sendable {
        let frame: PreviewFrame
        let time: RationalTime
        let sourceID: String?
        let sourceTime: RationalTime?
    }

    private struct Output: Sendable {
        let frame: PreviewFrame
        let cells: ParticipantPreviewCells?
    }

    private actor Renderer {
        let project: CutProject
        let document: URL
        let sidecars: ProjectSidecarWork
        private var picture: Result<ParticipantOutputPicture, Error>?

        init(project: CutProject, document: URL?) {
            self.project = project
            self.document = document ?? LiveProjectMediaArchive.untitledURL
            sidecars = ProjectSidecarWork(project: document)
        }

        func render(_ request: Request) throws -> Output {
            try Task.checkCancellation()
            if picture == nil {
                let prepared = Result {
                    try SidecarLocations.$storageDirectory.withValue(sidecars.storageDirectory) {
                        try SidecarLocations.$projectURL.withValue(sidecars.project) {
                            try ParticipantOutputPicture(project: project, document: document)
                        }
                    }
                }
                try Task.checkCancellation()
                picture = prepared
            }
            guard let picture else { throw CancellationError() }
            let decoded: ParticipantDecodedPicture? = if let sourceID = request.sourceID, let sourceTime = request.sourceTime,
                                                         let identity = request.frame.sourcePicture?.identity {
                .init(buffer: request.frame.buffer, sourceID: sourceID, sourceTime: sourceTime,
                      sourceIdentity: identity, displayTransform: request.frame.displayTransform)
            } else { nil }
            let compositor = try picture.get()
            let time = min(request.time, compositor.duration)
            let size = CGSize(width: compositor.canvas.width, height: compositor.canvas.height)
            var cells: [ParticipantPreviewCells.Cell] = []
            let buffer = try compositor.frame(at: time, decoded: decoded, exact: true) { slot, rect in
                cells.append(.init(slot: slot, rect: .init(x: rect.minX, y: size.height - rect.maxY,
                                                          width: rect.width, height: rect.height)))
            }
            var frame = PreviewFrame(buffer: buffer, time: request.frame.time, transform: .identity,
                                     sourceRendition: PreviewTransfer(frame: request.frame).source)
            if project.participants.hasEffectiveTreatments,
               let issue = try compositor.privacyIssues(at: time, exact: true).first {
                frame.privacyCoverNote = "Review the recording at \(issue.source.from) before showing output at \(issue.output.from)."
            }
            let geometry = cells.isEmpty ? nil : ParticipantPreviewCells(time: time, size: size, cells: cells)
            return Output(frame: frame, cells: geometry)
        }
    }

    private var project: CutProject?
    private var document: URL?
    private var renderer: Renderer?
    private var task: Task<Void, Never>?
    private var queued: Request?
    private var generation = 0
    let cells = CurrentValueSubject<ParticipantPreviewCells?, Never>(nil)
    private var result: Result<Output, Error>?
    private var pendingBuffer: CVPixelBuffer?
    private var pendingTime: RationalTime?
    var source = false

    deinit { task?.cancel() }

    var enabled: Bool { renderer != nil }

    @discardableResult
    func configure(project: CutProject?, document: URL?) -> Bool {
        let next = project.flatMap { $0.requiresPictureProcessing ? $0 : nil }
        guard next != self.project || (next != nil && self.document != document) else { return false }
        clear()
        self.project = next
        self.document = document
        renderer = next.map { Renderer(project: $0, document: document) }
        return true
    }

    func invalidateMedia() {
        guard let project else { return }
        clear()
        renderer = Renderer(project: project, document: document)
    }

    func clear() {
        generation += 1
        task?.cancel()
        task = nil
        queued = nil
        result = nil
        if cells.value != nil { cells.send(nil) }
        pendingBuffer = nil
        pendingTime = nil
    }

    func display(_ frame: PreviewFrame, at time: RationalTime?, sourceID: String?, sourceTime: RationalTime?, programStill: Bool = false,
                 on surfaces: [PreviewSurface], completion: @escaping @MainActor () -> [PreviewSurface]) {
        guard let renderer else {
            surfaces.forEach { surface in
                surface.display(source && !surface.isVideoMonitor && !programStill ? sourcePicture(frame) : frame)
            }
            return
        }
        for surface in surfaces where source && !surface.isVideoMonitor { surface.display(sourcePicture(frame)) }
        guard let time else {
            clear()
            for surface in surfaces where !source || surface.isVideoMonitor {
                surface.unavailable("Choose Source to review the untreated recording.")
            }
            return
        }
        guard pendingBuffer !== frame.buffer || pendingTime != time else {
            if let result { show(result, on: surfaces) }
            return
        }
        pendingBuffer = frame.buffer
        pendingTime = time
        queued = Request(frame: frame, time: time, sourceID: sourceID, sourceTime: sourceTime)
        start(renderer, surfaces: completion)
    }

    func attach(_ surface: PreviewSurface, frame: PreviewFrame) {
        if source && !surface.isVideoMonitor { surface.display(sourcePicture(frame)) }
        else if !enabled { surface.display(frame) }
        else if let result { show(result, on: [surface]) }
    }

    private func sourcePicture(_ frame: PreviewFrame) -> PreviewFrame {
        var source = frame
        source.programTransfer = nil
        source.cameraTransfer = nil
        return source
    }

    private func start(_ renderer: Renderer, surfaces: @escaping @MainActor () -> [PreviewSurface]) {
        guard task == nil, let request = queued else { return }
        queued = nil
        let generation = generation
        task = Task { [weak self] in
            let result: Result<Output, Error>
            do { result = .success(try await renderer.render(request)) }
            catch { result = .failure(error) }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.task = nil
            self.result = result
            self.show(result, on: surfaces())
            let displayed = (try? result.get())?.cells
            if self.cells.value != displayed { self.cells.send(displayed) }
            self.start(renderer, surfaces: surfaces)
        }
    }

    private func show(_ result: Result<Output, Error>, on surfaces: [PreviewSurface]) {
        for surface in surfaces where !source || surface.isVideoMonitor {
            switch result {
            case .success(let output): surface.display(output.frame)
            case .failure(let error): surface.unavailable(error.localizedDescription)
            }
        }
    }
}
