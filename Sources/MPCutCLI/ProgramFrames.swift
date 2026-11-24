import Foundation
import MPCutCore

struct ProgramFrameManifest: Encodable {
    struct Frame: Encodable {
        let requestNumber: Int
        let requestedTime: RationalTime
        let outputRange: MulticamRange
        let file: String
        let width: Int
        let height: Int
        var placementID: String?
        var assetID: String?
        var source: String?
        var sourceTime: RationalTime?
        var frameTime: RationalTime?
        var generatedGap: Bool?
    }

    let ok = true
    let schemaVersion = 2
    let selection = "program"
    let clock: String
    let projectPath: String
    let outputDirectory: String
    let duration: RationalTime
    let preset: JPEGPreset
    var format: FrameImageFormat? = nil
    let frames: [Frame]
}

func writeProgramFrames(_ project: CutProject, media: CutProjectMedia, projectPath: String, location: URL,
                        at times: [RationalTime], clock: StillOptions.Clock?, to output: URL, preset: JPEGPreset,
                        format: FrameImageFormat = .jpeg,
                        documentIdentity: SourceIdentity?,
                        useSidecar: Bool, cancelled: @escaping @Sendable () -> Bool) throws -> ProgramFrameManifest {
    guard project.participants.render == nil else {
        throw ParticipantProjectExport.unsupported("Program frame export")
    }
    let sequence = project.sequenceClips
    let requiredClock: StillOptions.Clock = sequence == nil ? .assembly : .sequence
    guard clock == nil || clock == requiredClock else {
        throw CLIError("invalid_arguments", "Use --clock \(requiredClock.rawValue) for program frames in this project.")
    }
    try media.validateDestination(output, relativeTo: location, includesContents: true)
    let timeline = try project.resolveStills()
    let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: .video)
    let clips = Dictionary(uniqueKeysWithValues: (sequence ?? []).map { ($0.id, $0) })

    var identities: [URL: SourceIdentity] = [:]
    if let documentIdentity { identities[location] = documentIdentity }
    func record(_ identity: SourceIdentity, at url: URL) throws {
        if let original = identities[url] {
            guard original.matchesSnapshot(identity) else {
                throw CutError(code: "source_changed", message: "‘\(url.path)’ changed while exporting review frames.")
            }
        } else {
            identities[url] = identity
        }
    }
    var indexed: [URL: MediaInfo] = [:]
    func inspect(_ url: URL, multicam: Bool) throws -> MediaInfo {
        if let cached = indexed[url] { return cached }
        let media = try multicam ? engine.inspectMulticamSource(url) : engine.inspect(url, keyframes: true)
        indexed[url] = media
        try record(media.identity, at: url)
        return media
    }

    var canvasReference: MediaInfo?
    func reference() throws -> MediaInfo? {
        if let canvasReference { return canvasReference }
        if let sequence {
            for clip in sequence {
                let url = CutProject.mediaURL(clip.file, relativeTo: location)
                guard (try? SourceIdentity(url)) != nil else { continue }
                let media = try engine.inspectSummary(url)
                if media.hasVideo {
                    try record(media.identity, at: url)
                    canvasReference = media
                    return media
                }
            }
        } else if case .multicam(let multicam) = project,
                  let source = multicam.angles.first(where: { $0.id == multicam.referenceAngle }) {
            let url = multicam.sourceURL(for: source, relativeTo: location)
            let media = try engine.inspectSummary(url)
            try record(media.identity, at: url)
            canvasReference = media
            return media
        }
        return nil
    }

    return try JPEGExport.writeProgramFrameDirectory(to: output, cancelled: cancelled, validate: {
        for (url, identity) in identities {
            guard identity.isCurrentSnapshot(at: url) else {
                throw CutError(code: "source_changed", message: "‘\(url.path)’ changed while exporting review frames.")
            }
        }
    }) { staging in
        struct CameraRequest {
            let ordinal: Int
            let name: String
            let requestedTime: RationalTime
            let outputRange: MulticamRange
            let sourceID: String
            let sourceTime: RationalTime
            let frameTime: RationalTime
        }
        var sourceBatchIndices: [URL: Int] = [:]
        var sourceBatches: [(media: MediaInfo, requests: [CameraRequest])] = []
        var renderedStills: [String: (url: URL, asset: String, width: Int, height: Int)] = [:]
        var renderedGap: (url: URL, width: Int, height: Int)?
        var recordingGaps: [MulticamRange]?
        var frames = try times.enumerated().map { ordinal, time -> ProgramFrameManifest.Frame? in
            if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
            guard let index = timeline.pictureIndex(at: time) else {
                throw CutError(code: "invalid_range", message: "Frame time \(time) is outside the program.")
            }
            let span = timeline.spans[index]
            let name = String(format: "frame-%06d.", ordinal + 1) + format.fileExtension
            let destination = staging.appendingPathComponent(name)
            if let placement = span.placementID {
                if let rendered = renderedStills[placement] {
                    try FileManager.default.copyItem(at: rendered.url, to: destination)
                    return ProgramFrameManifest.Frame(requestNumber: ordinal + 1, requestedTime: time, outputRange: span.output,
                                                      file: name, width: rendered.width, height: rendered.height,
                                                      placementID: placement, assetID: rendered.asset)
                }
                let frame = try project.stillReviewFrame(placementID: placement, interval: span.output, document: location,
                                                         canvas: project.stillFormat == nil ? reference() : nil)
                let jpeg = try frame.encoded(preset: preset, format: format, cancelled: cancelled)
                try jpeg.data.write(to: destination, options: .withoutOverwriting)
                renderedStills[placement] = (destination, frame.asset.id, jpeg.width, jpeg.height)
                try record(frame.identity, at: frame.url)
                return ProgramFrameManifest.Frame(requestNumber: ordinal + 1, requestedTime: time, outputRange: span.output,
                                                  file: name, width: jpeg.width, height: jpeg.height,
                                                  placementID: placement, assetID: frame.asset.id)
            }
            let local = try time.subtracting(span.output.from)
            let sourceID: String
            let sourceTime: RationalTime
            let sourceMedia: MediaInfo
            switch span.origin {
            case .source(let clipID, let range):
                guard let clip = clips[clipID] else { throw CutError(code: "no_frame", message: "The clip is unavailable.") }
                sourceID = clipID
                sourceTime = try range.from.adding(local)
                sourceMedia = try inspect(CutProject.checkedMediaURL(clip.file, relativeTo: location), multicam: false)
            case .group(let occurrence, let range):
                guard case .multicam(let multicam) = project else {
                    throw CutError(code: "no_frame", message: "The camera is unavailable.")
                }
                let groupTime = try range.from.adding(local)
                let atEnd = time == timeline.duration
                let angle = multicam.pictureAngle(at: groupTime, in: occurrence, exclusiveEnd: atEnd)
                guard let angle else {
                    throw CutError(code: "no_frame", message: "No camera is selected at group time \(groupTime).")
                }
                guard let camera = multicam.pictureSource(for: angle, at: groupTime, exclusiveEnd: atEnd) else {
                    let mapping = try recordingGaps == nil ? multicam.plan() : nil
                    if let mapping { recordingGaps = mapping.recordingGaps }
                    let rendered: (url: URL, width: Int, height: Int)
                    if let renderedGap {
                        try FileManager.default.copyItem(at: renderedGap.url, to: destination)
                        rendered = renderedGap
                    } else {
                        let canvas: MediaInfo?
                        if project.stillFormat == nil,
                           let referenceID = mapping?.picture.first?.source ?? mapping?.intervals.first?.angle,
                           let source = multicam.sources.first(where: { $0.id == referenceID }) {
                            let url = multicam.sourceURL(for: source, relativeTo: location)
                            let info = try indexed[url] ?? engine.inspectSummary(url)
                            try record(info.identity, at: url)
                            canvas = info
                        } else {
                            canvas = try project.stillFormat == nil ? reference() : nil
                        }
                        guard let geometry = project.stillReviewGeometry(reference: canvas) else {
                            throw CutError(code: "invalid_canvas", message: "The program needs a video reference for image dimensions.")
                        }
                        let asset = StillAsset(gapID: "recording-gap")
                        let frame = try StillReviewFrame(asset: asset, placementID: asset.id, framing: .fit,
                                                        interval: span.output, document: location, width: geometry.width,
                                                        height: geometry.height, displayAspect: geometry.aspect)
                        let jpeg = try frame.encoded(preset: preset, format: format, cancelled: cancelled)
                        try jpeg.data.write(to: destination, options: .withoutOverwriting)
                        try record(frame.identity, at: frame.url)
                        rendered = (destination, jpeg.width, jpeg.height)
                        renderedGap = rendered
                    }
                    let gaps = recordingGaps ?? []
                    let index = gaps.lowerBound { atEnd ? $0.to >= time : $0.to > time }
                    let gap = gaps.indices.contains(index) ? gaps[index] : span.output
                    let range = MulticamRange(from: max(gap.from, span.output.from), to: min(gap.to, span.output.to))
                    return ProgramFrameManifest.Frame(requestNumber: ordinal + 1, requestedTime: time, outputRange: range,
                                                      file: name, width: rendered.width, height: rendered.height, generatedGap: true)
                }
                sourceID = camera.id
                sourceMedia = try inspect(multicam.sourceURL(for: camera, relativeTo: location), multicam: true)
                sourceTime = try groupTime.subtracting(camera.offset)
            case .insert:
                throw CutError(code: "no_frame", message: "The still placement is unavailable.")
            }
            let exclusiveEnd = time == timeline.duration
            let frameTime = try JPEGExport.stillFrameTime(in: sourceMedia, at: sourceTime, exclusiveEnd: exclusiveEnd)
            let batchIndex: Int
            if let existing = sourceBatchIndices[sourceMedia.url] {
                batchIndex = existing
            } else {
                batchIndex = sourceBatches.count
                sourceBatchIndices[sourceMedia.url] = batchIndex
                sourceBatches.append((sourceMedia, []))
            }
            sourceBatches[batchIndex].requests.append(CameraRequest(
                ordinal: ordinal, name: name, requestedTime: time, outputRange: span.output,
                sourceID: sourceID, sourceTime: sourceTime, frameTime: frameTime))
            return nil
        }
        for (media, requests) in sourceBatches {
            let rendered = try JPEGExport.writeReviewFrames(media, at: requests.map(\.frameTime), preset: preset,
                                                            format: format,
                                                            cancelled: cancelled, fileName: { requests[$0].name }) { jpeg, name in
                try jpeg.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
            }
            for (request, frame) in zip(requests, rendered) {
                frames[request.ordinal] = ProgramFrameManifest.Frame(
                    requestNumber: request.ordinal + 1, requestedTime: request.requestedTime, outputRange: request.outputRange,
                    file: request.name, width: frame.width, height: frame.height, source: request.sourceID,
                    sourceTime: request.sourceTime, frameTime: request.frameTime)
            }
        }
        return ProgramFrameManifest(clock: requiredClock.rawValue, projectPath: projectPath, outputDirectory: output.path,
                                    duration: timeline.duration, preset: preset,
                                    format: format == .jpeg ? nil : format, frames: frames.compactMap { $0 })
    }
}
