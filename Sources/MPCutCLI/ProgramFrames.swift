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
    }

    let ok = true
    let version = 1
    let selection = "program"
    let clock: String
    let project: String
    let outputDirectory: String
    let duration: RationalTime
    let preset: JPEGPreset
    let frames: [Frame]
}

func writeProgramFrames(_ project: CutProject, media: CutProjectMedia, projectPath: String, location: URL,
                        at times: [RationalTime], clock: StillOptions.Clock?, to output: URL, preset: JPEGPreset,
                        documentIdentity: SourceIdentity?,
                        useSidecar: Bool, cancelled: @escaping @Sendable () -> Bool) throws -> ProgramFrameManifest {
    let timeline = try project.resolveStills()
    let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: .video)
    let sequence = project.sequenceClips
    let clips = Dictionary(uniqueKeysWithValues: (sequence ?? []).map { ($0.id, $0) })
    let requiredClock: StillOptions.Clock = sequence == nil ? .assembly : .sequence
    guard clock == nil || clock == requiredClock else {
        throw CLIError("invalid_arguments", "Use --clock \(requiredClock.rawValue) for program frames in this project.")
    }
    try media.validateDestination(output, relativeTo: location, includesContents: true)

    var identities: [URL: SourceIdentity] = [:]
    if let documentIdentity { identities[location] = documentIdentity }
    var indexed: [URL: MediaInfo] = [:]
    func inspect(_ url: URL, multicam: Bool) throws -> MediaInfo {
        if let cached = indexed[url] { return cached }
        let media = try multicam ? engine.inspectMulticamSource(url) : engine.inspect(url, keyframes: true)
        indexed[url] = media
        identities[url] = media.identity
        return media
    }

    func reference() throws -> MediaInfo? {
        if let sequence {
            for clip in sequence {
                let url = CutProject.mediaURL(clip.file, relativeTo: location)
                guard (try? SourceIdentity(url)) != nil else { continue }
                let media = try engine.inspectSummary(url)
                if media.hasVideo {
                    identities[url] = media.identity
                    return media
                }
            }
        } else if case .multicam(let multicam) = project,
                  let source = multicam.angles.first(where: { $0.id == multicam.referenceAngle }) {
            let url = multicam.sourceURL(for: source, relativeTo: location)
            return try inspect(url, multicam: true)
        }
        return nil
    }

    return try JPEGExport.writeProgramFrameDirectory(to: output, cancelled: cancelled, validate: {
        for (url, identity) in identities {
            guard (try? SourceIdentity(url)) == identity else {
                throw CutError(code: "source_changed", message: "‘\(url.path)’ changed while exporting review frames.")
            }
        }
    }) { staging in
        let frames = try times.enumerated().map { ordinal, time in
            guard let index = timeline.pictureIndex(at: time) else {
                throw CutError(code: "invalid_range", message: "Frame time \(time) is outside the program.")
            }
            let span = timeline.spans[index]
            let name = String(format: "frame-%06d.jpg", ordinal + 1)
            let destination = staging.appendingPathComponent(name)
            if let placement = span.placementID {
                let frame = try project.stillReviewFrame(placementID: placement, interval: span.output, document: location,
                                                         canvas: project.stillFormat == nil ? reference() : nil)
                let jpeg = try frame.jpeg(preset: preset, cancelled: cancelled)
                try jpeg.data.write(to: destination, options: .withoutOverwriting)
                identities[frame.url] = frame.identity
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
            case .group(_, let range):
                guard case .multicam(let multicam) = project else {
                    throw CutError(code: "no_frame", message: "The camera is unavailable.")
                }
                let groupTime = try range.from.adding(local)
                let angle = time == timeline.duration ? multicam.switches.last { $0.at < groupTime }?.angle :
                    multicam.selection(at: groupTime)?.angle
                guard let camera = multicam.angles.first(where: { $0.id == angle }) else {
                    throw CutError(code: "no_frame", message: "No camera is selected at group time \(groupTime).")
                }
                sourceID = camera.id
                sourceMedia = try inspect(multicam.sourceURL(for: camera, relativeTo: location), multicam: true)
                sourceTime = try groupTime.subtracting(camera.offset)
            case .insert:
                throw CutError(code: "no_frame", message: "The still placement is unavailable.")
            }
            let (jpeg, frame) = try JPEGExport.reviewFrame(sourceMedia, at: sourceTime, exclusiveEnd: time == timeline.duration,
                                                           preset: preset, cancelled: cancelled)
            try jpeg.write(to: destination, options: .withoutOverwriting)
            return ProgramFrameManifest.Frame(requestNumber: ordinal + 1, requestedTime: time, outputRange: span.output,
                                              file: name, width: frame.width, height: frame.height,
                                              source: sourceID, sourceTime: sourceTime, frameTime: frame.frameTime)
        }
        return ProgramFrameManifest(clock: requiredClock.rawValue, project: projectPath, outputDirectory: output.path,
                                    duration: timeline.duration, preset: preset, frames: frames)
    }
}
