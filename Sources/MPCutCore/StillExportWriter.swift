import Darwin
import Foundation

extension StillExportPlanner {
    public func write(_ plan: StillExportPlan, to output: URL, progress: ((Double) -> Bool)? = nil) throws {
        let interruption = StillExportInterruption()
        let isCancelled: @Sendable () -> Bool = {
            cancelled?() == true || interruption.stopped
        }
        let engine = CutEngine(cancelled: isCancelled, useSidecar: useSidecar, tracks: .video)
        let destination = output.standardizedFileURL
        try engine.checkCancellation()
        try engine.checkDestination(destination)
        guard destination.pathExtension.isEmpty || destination.pathExtension.lowercased() == plan.container else {
            throw CutError(code: "invalid_output", message: "The destination extension must match the export plan.")
        }
        func update(_ fraction: Double) throws {
            if progress?(fraction) == false { interruption.stop() }
            try engine.checkCancellation()
        }

        try plan.verifySources(using: engine)
        try update(0)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let heldMatroska = plan.container == "mkv" && plan.report.pictureTiming == .held && !plan.pictures.isEmpty
        let picture: URL?
        if plan.pictures.isEmpty {
            picture = nil
        } else {
            let pictureContainer = heldMatroska ? "mov" : ExportRules.multicamMuxContainer(plan.container)
            let staged = staging.appendingPathComponent("picture.\(pictureContainer)")
            try writePicture(plan, to: staged, in: staging, engine: engine, cancelled: isCancelled) {
                do { try update($0 * 0.80); return true } catch { return false }
            }
            picture = heldMatroska ? try StillMatroska.stagePictureIfNeeded(plan, movie: staged, in: staging,
                                                                           cancelled: isCancelled) : staged
        }

        let sounds = try plan.sound.map {
            try StillSoundPlanner(cancelled: isCancelled).write($0, in: staging) { fraction in
                do { try update(0.80 + fraction * 0.12); return true } catch { return false }
            }
        } ?? []
        try update(0.92)
        let partial: URL
        let lanes = [picture].compactMap { $0 } + sounds
        if lanes.count == 1, let lane = lanes.first, !heldMatroska {
            partial = lane
        } else if !lanes.isEmpty {
            partial = staging.appendingPathComponent("program.\(plan.container)")
            if ["mov", "mp4", "m4v", "m4a"].contains(plan.container) {
                try MulticamMOV.combine(picture: picture, sounds: sounds, output: partial) {
                    try update(0.92 + $0 * 0.07)
                }
            } else {
                let muxer = plan.container == "mka" || plan.container == "mkv" ? "matroska" : plan.container
                let helper = try ReencodeEngine.findHelper(override: nil)
                let inputs = lanes.flatMap { ["-i", $0.path] }
                let firstSound = picture == nil ? 0 : 1
                let maps = (picture == nil ? [] : ["-map", "0:v:0"]) +
                    sounds.indices.flatMap { ["-map", "\(firstSound + $0):a:0"] }
                let dispositions = sounds.indices.flatMap { ["-disposition:a:\($0)", $0 == 0 ? "default" : "0"] }
                var arguments = ["-xerror", "-copyts"] + inputs + maps + dispositions
                arguments += ["-c", "copy", "-avoid_negative_ts", "disabled"]
                if heldMatroska { arguments += StillMatroska.heldMuxArguments }
                arguments += ["-f", muxer, "-n", partial.path]
                try ReencodeEngine(cancelled: isCancelled).runHelper(helper, arguments: arguments,
                                                                     in: staging, duration: plan.duration)
            }
        } else {
            throw CutError(code: "no_output_tracks", message: "The program has no selected output tracks.")
        }

        if heldMatroska {
            try StillMatroska.verifyPicture(plan, file: partial, cancelled: isCancelled)
        }
        if picture != nil {
            try verifyPicture(plan, file: partial, sounds: sounds, cancelled: isCancelled)
        } else {
            let audio = try Probe.read(partial, keyframes: false, cancelled: isCancelled)
            try verifyTrackSelection(plan, media: audio, staged: sounds, cancelled: isCancelled)
        }
        try update(1)
        try plan.verifySources(using: engine)
        guard chmod(partial.path, try publicationPermissions(0o666)) == 0 else {
            throw CutError(code: "write_failed", message: String(cString: strerror(errno)))
        }
        try engine.checkCancellation()
        let failure = publishExclusively(from: partial, to: destination)
        if failure == EEXIST {
            throw CutError(code: "output_exists", message: "A file already exists at the destination.")
        }
        guard failure == 0 else {
            throw CutError(code: "write_failed", message: String(cString: strerror(failure)))
        }
    }

    private func writePicture(_ plan: StillExportPlan, to output: URL, in staging: URL, engine: CutEngine,
                              cancelled: @escaping @Sendable () -> Bool,
                              progress: @escaping (Double) -> Bool) throws {
        let generator = StillVideoGenerator(cancelled: cancelled, colorPolicy: plan.report.colorPolicy,
                                            standalone: plan.pictures.allSatisfy {
                                                if case .still(_, _, let reference, _) = $0.content {
                                                    return reference.configuration.isEmpty
                                                }
                                                return false
                                            })
        let transcode = plan.report.mode == .encode
        let held = plan.report.pictureTiming == .held
        let container = output.pathExtension
        let pictureDuration = plan.pictures.last?.renderOutput.to ?? plan.duration
        var requests: [ClipRequest] = []
        var indexed: [URL: MediaInfo] = [:]
        var generatedInputs: Set<URL> = []
        var segments: [ResolvedSegment] = []
        var lead = RationalTime.zero
        for (index, picture) in plan.pictures.enumerated() {
            try engine.checkCancellation()
            let media: MediaInfo
            let input: MulticamRange
            let window: Range<Int>
            let generated: Bool
            let edges: [EncodedEdge]
            switch picture.content {
            case .camera(let original, let range, let frames, let repairs):
                media = original
                input = range
                window = frames
                generated = false
                edges = repairs
            case .still(let file, let framing, let reference, let schedule):
                guard let identity = plan.identities[file] else {
                    throw CutError(code: "source_changed", message: "The still has no verified preflight identity.")
                }
                let suffix = transcode ? "mov" : container
                let staged = staging.appendingPathComponent("still-\(index).\(suffix)")
                if transcode {
                    media = try generator.generateLossless(asset: file, identity: identity, framing: framing, reference: reference,
                                                           schedule: schedule, output: staged)
                } else {
                    media = try generator.generate(asset: file, identity: identity, framing: framing, reference: reference,
                                                   container: container, schedule: schedule,
                                                   output: staged)
                }
                input = .init(from: .zero, to: schedule.duration)
                window = media.frames.indices
                generated = true
                edges = []
            }
            indexed[media.url] = media
            if generated { generatedInputs.insert(media.url) }
            requests.append(.init(file: media.url, from: input.from, to: input.to))
            if !transcode {
                let kept = media.frames[window]
                let dts = kept.compactMap(\.dts).sorted()
                guard let last = kept.last, dts.count == kept.count else {
                    throw CutError(code: "unsafe_still_timing", message: "Picture span \(index + 1) has incomplete packet timestamps.")
                }
                let shift = try picture.renderOutput.from.subtracting(input.from)
                let times = try kept.map { try $0.time.adding(shift) }
                for (frame, decode) in zip(kept, dts) {
                    lead = max(lead, try frame.time.subtracting(decode))
                }
                segments.append(ResolvedSegment(file: media.url, from: input.from, to: input.to,
                                                outputStart: picture.renderOutput.from, tracks: [], sourceOrigin: media.origin,
                                                lastVideoFrame: last.time, reachesEnd: input.to == media.duration,
                                                multipleDescriptions: media.video.multipleDescriptions,
                                                generatedStill: generated, videoDecodeTimes: times,
                                                encodedEdges: edges.isEmpty ? nil : edges))
            }
            if !progress(0.30 * Double(index + 1) / Double(plan.pictures.count)) {
                throw CutError(code: "cancelled", message: "The operation was cancelled.")
            }
        }

        if transcode {
            let settings = ReencodeSettings(codec: plan.settings.codec, quality: plan.settings.quality, audio: .removeAudio)
            let tick = StillExportProgress(progress)
            let processor = ReencodeEngine(cancelled: cancelled)
            var conversion = try processor.resolveStillPictures(requests, output: output, media: indexed,
                                                                 generated: generatedInputs, container: container, settings: settings)
            if held && plan.container == "mkv" {
                conversion.timeScale = try StillMatroska.pictureConversionClock(plan.pictures, cancelled: cancelled)
            }
            if let color = plan.report.colorPolicy, let first = requests.first, let source = conversion.media[first.file]?.video {
                let width = conversion.width + conversion.width % 2
                let height = conversion.height + conversion.height % 2
                let frame = ReencodeVideo.Frame(width: width, height: height, deep: conversion.media.values.contains { $0.video.bitDepth > 8 })
                conversion.encoding = try ReencodeVideo(source, settings: settings, frame: frame, stillColor: color)
                conversion.canvas = ReencodeCanvas(width: width, height: height, pixelFormat: conversion.encoding.pixelFormat,
                                                    colorPrimaries: color.primaries, colorTransfer: color.transfer,
                                                    colorMatrix: color.matrix, colorRange: settings.codec == .jpeg ? "pc" : color.range, audio: [],
                                                    normalizesPicture: true, usesStillColor: true)
            }
            // The native sound lanes use the packet writer's movie clock. Use
            // the same clock whenever it can describe every video presentation.
            let sharedMovieClock = 705_600_000
            conversion.movieTimeScale = sharedMovieClock % conversion.timeScale == 0 ?
                sharedMovieClock : conversion.timeScale
            conversion.assemblesStillHDR = ["smpte2084", "arib-std-b67"].contains(plan.report.colorPolicy?.transfer)
            if held { conversion.independentStillInputs = generatedInputs }
            if held && plan.container == "mkv" {
                conversion.matroskaStillTiming = plan.pictures.map { picture in
                    let from: RationalTime
                    switch picture.content {
                    case .camera: from = picture.output.from
                    case .still: from = picture.renderOutput.from
                    }
                    return .init(from: from, to: picture.renderOutput.to)
                }
            }
            let writesJPEG = settings.codec == .jpeg
            let needsColorMux = plan.hdrMetadata != nil || writesJPEG
            let encoded = needsColorMux ? staging.appendingPathComponent("picture-encoded.\(container)") : output
            try processor.write(conversion, to: encoded) { fraction in
                tick.update(0.30 + fraction * (needsColorMux ? 0.60 : 0.70))
            }
            if needsColorMux {
                var args = ["-xerror", "-copyts"]
                if let mastering = plan.hdrMetadata?.masteringOption {
                    args += ["-mastering_display:v:0", mastering]
                }
                args += ["-i", encoded.path, "-map", "0:v:0", "-c:v", "copy", "-avoid_negative_ts", "disabled"]
                args += ["-movflags", "+write_colr", "-video_track_timescale", "\(conversion.timeScale)",
                         "-movie_timescale", "\(conversion.movieTimeScale)"]
                if settings.codec == .hevc { args += ["-tag:v", "hvc1"] }
                if writesJPEG, let color = plan.report.colorPolicy {
                    args += ["-color_range", "pc", "-color_primaries", color.primaries,
                             "-color_trc", color.transfer, "-colorspace", color.matrix]
                }
                try processor.runHelper(conversion.helper, arguments: args + ["-n", output.path],
                                        in: staging, duration: pictureDuration) { fraction in
                    tick.update(0.90 + fraction * 0.10)
                }
            }
        } else {
            for index in segments.indices {
                try engine.checkCancellation()
                segments[index].videoDecodeTimes = try segments[index].videoDecodeTimes.map { try $0.subtracting(lead) }
            }
            let edit = ResolvedEdit(segments: segments, duration: pictureDuration,
                                    container: container,
                                    identities: indexed.mapValues(\.identity), tracks: .video,
                                    stillMasteringDisplay: plan.hdrMetadata?.mastering ?? [])
            try engine.export(edit, to: output) { progress(0.30 + $0 * 0.70) }
        }
    }

    private func hdrTagsMatch(_ video: StreamInfo, policy: StillProgramColorPolicy?) -> Bool {
        guard let policy, ["smpte2084", "arib-std-b67"].contains(policy.transfer) else {
            return DynamicRange(video) == .sdr
        }
        return video.bitDepth >= 10 && video.colorTransfer == policy.transfer &&
            video.colorPrimaries == policy.primaries && video.colorMatrix == policy.matrix &&
            video.colorRange == policy.range
    }

    private func verifyPicture(_ plan: StillExportPlan, file: URL, sounds: [URL],
                               cancelled: @escaping @Sendable () -> Bool) throws {
        let engine = CutEngine(cancelled: cancelled, useSidecar: false, tracks: .video)
        let result = try engine.inspect(file, keyframes: true)
        try verifyTrackSelection(plan, media: result, staged: sounds, cancelled: cancelled)
        let pictureDuration = plan.pictures.last?.renderOutput.to ?? plan.duration
        let duration = plan.container == "mkv" ? result.duration : result.video.duration
        guard result.hasVideo, result.video.codec == plan.report.videoCodec,
              duration == pictureDuration else {
            throw CutError(code: "write_failed", message: "The staged picture did not retain its planned codec or duration.")
        }
        if result.video.codec == "mjpeg", let color = plan.report.colorPolicy {
            guard result.video.colorRange == color.range, result.video.colorMatrix == color.matrix,
                  result.video.colorTransfer == color.transfer, result.video.colorPrimaries == color.primaries else {
                throw CutError(code: "write_failed", message: "The staged JPEG picture did not retain its planned color description.")
            }
        }
        if DynamicRange(result.video) != .sdr || result.video.complexPicture ||
            plan.hdrMetadata != nil || ["smpte2084", "arib-std-b67"].contains(plan.report.colorPolicy?.transfer) {
            let hdr = try StillHDRMetadata.inspect(result, cancelled: cancelled)
            guard hdr.mastering == plan.hdrMetadata?.mastering, !hdr.hasConflictingMastering,
                  !hdr.hasContentLight, !hdr.hasInBandContentLight, !hdr.hasHDR10Plus,
                  !hdr.hasDolbyVision, !hdr.hasAdditionalLayers,
                  hdrTagsMatch(result.video, policy: plan.report.colorPolicy) else {
                throw StillHDRMetadata.unverifiable(file, reason: "The staged HDR signaling differs from the export plan")
            }
        }
        let encoded = plan.report.mode == .encode
        let held = plan.report.pictureTiming == .held
        var index = 0
        func verify(_ pts: RationalTime, _ duration: RationalTime, independent: Bool) throws {
            if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
            guard index < result.frames.count else {
                throw CutError(code: "write_failed", message: "The staged picture ended before the planned sample at \(pts).")
            }
            let frame = result.frames[index]
            guard frame.time == pts, frame.duration == duration, !independent || frame.canStart else {
                throw CutError(code: "write_failed", message: "The staged sample at \(pts) differs from its planned timing or independence.")
            }
            index += 1
        }
        for picture in plan.pictures {
            switch picture.content {
            case .camera(let media, let input, let frames, _):
                let shift = try picture.output.from.subtracting(input.from)
                for frameIndex in frames {
                    let frame = media.frames[frameIndex]
                    var pts = try frame.time.adding(shift)
                    var duration = frame.duration
                    if held && plan.container == "mkv" {
                        let end = try frameIndex == frames.upperBound - 1 ? picture.renderOutput.to :
                            StillSampleSchedule.matroskaBoundary(pts.adding(duration), final: false)
                        pts = try StillSampleSchedule.matroskaBoundary(pts, final: false)
                        duration = try end.subtracting(pts)
                    }
                    try verify(pts, duration, independent: !encoded && frameIndex == frames.lowerBound)
                }
            case .still(_, _, _, let schedule):
                var cursor = picture.renderOutput.from
                for run in schedule.runs {
                    for _ in 0..<run.count {
                        try verify(cursor, run.duration, independent: (held || !encoded) && cursor == picture.renderOutput.from)
                        cursor = try cursor.adding(run.duration)
                    }
                }
            }
        }
        guard index == result.frames.count else {
            throw CutError(code: "write_failed", message: "The staged picture includes samples outside the planned intervals.")
        }
    }

    private func verifyTrackSelection(_ plan: StillExportPlan, media: MediaInfo, staged: [URL],
                                      cancelled: @escaping @Sendable () -> Bool) throws {
        let actions = plan.report.soundActions
        let soundTracks = media.audio
        guard media.hasVideo == !plan.pictures.isEmpty, soundTracks.count == actions.count,
              soundTracks.count == staged.count else {
            throw CutError(code: "write_failed", message: "The staged program did not retain the selected picture and sound tracks.")
        }
        for (ordinal, sound) in soundTracks.enumerated() {
            let action = actions[ordinal]
            let stream = sound.stream
            func failure() -> CutError {
                CutError(code: "write_failed", message: "The final sound track changed its codec, precision, channel order, or audible range.",
                         track: stream.index, laneID: action.laneID)
            }
            guard action.codec.map({ $0 == stream.codec }) ?? true,
                  action.sampleRate.map({ $0 == stream.sampleRate }) ?? true,
                  // FLAC and ALAC state their word length in the codec header where the container states none.
                  AudioExportEngine.declaredDepth(stream).flatMap({ depth in action.bitDepth.map { $0 == depth } }) ?? true else {
                throw failure()
            }
            if case .convert(let conversion) = plan.sound?.treatments[ordinal], conversion.exactEncoding != nil {
                try conversion.verifyExactSound(sound, origin: media.origin)
                continue
            }
            guard staged[ordinal] != media.url else { continue }
            let lane = try Probe.read(staged[ordinal], keyframes: false, cancelled: cancelled)
            let depths = (AudioExportEngine.declaredDepth(lane.audio.first?.stream ?? stream), AudioExportEngine.declaredDepth(stream))
            guard let original = lane.audio.first, original.stream.channels == stream.channels,
                  original.stream.canonicalChannelLayout == stream.canonicalChannelLayout,
                  original.stream.bitDepth == stream.bitDepth,
                  depths.0 == nil || depths.1 == nil || depths.0 == depths.1 else {
                throw failure()
            }
            let start = try media.origin.adding(sound.start)
            let end = try media.origin.adding(sound.end)
            let plannedStart = try lane.origin.adding(original.start)
            let plannedEnd = try lane.origin.adding(original.end)
            // MKV can report inherited PCM on its millisecond packet clock.
            let tolerance = plan.container == "mkv" && stream.isPCM ? stream.timeBase : .zero
            guard try start >= plannedStart.subtracting(tolerance), try start <= plannedStart.adding(tolerance),
                  try end >= plannedEnd.subtracting(tolerance), try end <= plannedEnd.adding(tolerance) else {
                throw failure()
            }
        }
        if soundTracks.count > 1,
           soundTracks.map({ $0.stream.disposition & 1 }) != [1] + Array(repeating: 0, count: soundTracks.count - 1) {
            throw CutError(code: "write_failed", message: "The staged program did not retain the planned default soundtrack.")
        }
    }
}

private final class StillExportInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var stoppedValue = false
    var stopped: Bool { lock.withLock { stoppedValue } }
    func stop() { lock.withLock { stoppedValue = true } }
}

private final class StillExportProgress: @unchecked Sendable {
    private let progress: (Double) -> Bool
    init(_ progress: @escaping (Double) -> Bool) { self.progress = progress }
    func update(_ fraction: Double) { _ = progress(fraction) }
}
