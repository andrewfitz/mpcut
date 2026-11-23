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

        let picture: URL?
        if plan.pictures.isEmpty {
            picture = nil
        } else {
            let pictureContainer = ExportRules.multicamMuxContainer(plan.container)
            let staged = staging.appendingPathComponent("picture.\(pictureContainer)")
            try writePicture(plan, to: staged, in: staging, engine: engine, cancelled: isCancelled) {
                do { try update($0 * 0.80); return true } catch { return false }
            }
            picture = staged
        }

        let sounds = try plan.sound.map {
            try StillSoundPlanner(cancelled: isCancelled).write($0, in: staging) { fraction in
                do { try update(0.80 + fraction * 0.12); return true } catch { return false }
            }
        } ?? []
        try update(0.92)
        let partial: URL
        let lanes = [picture].compactMap { $0 } + sounds
        if lanes.count == 1, let lane = lanes.first {
            partial = lane
        } else if lanes.count > 1 {
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
                try ReencodeEngine(cancelled: isCancelled).runHelper(helper, arguments:
                    ["-xerror", "-copyts"] + inputs + maps + dispositions +
                    ["-c", "copy", "-avoid_negative_ts", "disabled", "-f", muxer, "-n", partial.path],
                    in: staging, duration: plan.duration)
            }
        } else {
            throw CutError(code: "no_output_tracks", message: "The program has no selected output tracks.")
        }

        if picture != nil {
            try verifyPicture(plan, file: partial, cancelled: isCancelled)
        } else {
            let audio = try Probe.read(partial, keyframes: false, cancelled: isCancelled)
            try verifyTrackSelection(plan, media: audio)
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
                let suffix = transcode ? "mov" : plan.container
                let staged = staging.appendingPathComponent("still-\(index).\(suffix)")
                if transcode {
                    media = try generator.generateLossless(asset: file, identity: identity, framing: framing, reference: reference,
                                                           schedule: schedule, output: staged)
                } else {
                    media = try generator.generate(asset: file, identity: identity, framing: framing, reference: reference,
                                                   container: plan.container, schedule: schedule,
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
                let shift = try picture.output.from.subtracting(input.from)
                let times = try kept.map { try $0.time.adding(shift) }
                for (frame, decode) in zip(kept, dts) {
                    lead = max(lead, try frame.time.subtracting(decode))
                }
                segments.append(ResolvedSegment(file: media.url, from: input.from, to: input.to,
                                                outputStart: picture.output.from, tracks: [], sourceOrigin: media.origin,
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
            let container = ExportRules.multicamMuxContainer(plan.container)
            var conversion = try processor.resolveStillPictures(requests, output: output, media: indexed,
                                                                 generated: generatedInputs, container: container, settings: settings)
            if let color = plan.report.colorPolicy, let first = requests.first, let source = conversion.media[first.file]?.video {
                let width = conversion.width + conversion.width % 2
                let height = conversion.height + conversion.height % 2
                let frame = ReencodeVideo.Frame(width: width, height: height, deep: conversion.media.values.contains { $0.video.bitDepth > 8 })
                conversion.encoding = try ReencodeVideo(source, settings: settings, frame: frame, stillColor: color)
                conversion.canvas = ReencodeCanvas(width: width, height: height, pixelFormat: conversion.encoding.pixelFormat,
                                                    colorPrimaries: color.primaries, colorTransfer: color.transfer,
                                                    colorMatrix: color.matrix, colorRange: color.range, audio: [],
                                                    normalizesPicture: true, usesStillColor: true)
            }
            // The native sound lanes use the packet writer's movie clock. Use
            // the same clock whenever it can describe every video presentation.
            let sharedMovieClock = 705_600_000
            conversion.movieTimeScale = sharedMovieClock % conversion.timeScale == 0 ?
                sharedMovieClock : conversion.timeScale
            conversion.assemblesStillHDR = ["smpte2084", "arib-std-b67"].contains(plan.report.colorPolicy?.transfer)
            let needsHDRMux = plan.hdrMetadata != nil
            let encoded = needsHDRMux ? staging.appendingPathComponent("picture-encoded.\(container)") : output
            try processor.write(conversion, to: encoded) { fraction in
                tick.update(0.30 + fraction * (needsHDRMux ? 0.60 : 0.70))
            }
            if needsHDRMux {
                var args = ["-xerror", "-copyts"]
                if let mastering = plan.hdrMetadata?.masteringOption {
                    args += ["-mastering_display:v:0", mastering]
                }
                args += ["-i", encoded.path, "-map", "0:v:0", "-c:v", "copy", "-avoid_negative_ts", "disabled"]
                args += ["-movflags", "+write_colr", "-video_track_timescale", "\(conversion.timeScale)",
                         "-movie_timescale", "\(conversion.movieTimeScale)"]
                if settings.codec == .hevc { args += ["-tag:v", "hvc1"] }
                try processor.runHelper(conversion.helper, arguments: args + ["-n", output.path],
                                        in: staging, duration: plan.duration) { fraction in
                    tick.update(0.90 + fraction * 0.10)
                }
            }
        } else {
            for index in segments.indices {
                try engine.checkCancellation()
                segments[index].videoDecodeTimes = try segments[index].videoDecodeTimes.map { try $0.subtracting(lead) }
            }
            let edit = ResolvedEdit(segments: segments, duration: plan.duration,
                                    container: ExportRules.multicamMuxContainer(plan.container),
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

    private func verifyPicture(_ plan: StillExportPlan, file: URL,
                               cancelled: @escaping @Sendable () -> Bool) throws {
        let engine = CutEngine(cancelled: cancelled, useSidecar: false, tracks: .video)
        let result = try engine.inspect(file, keyframes: true)
        try verifyTrackSelection(plan, media: result)
        guard result.hasVideo, result.video.duration == plan.duration else {
            throw CutError(code: "write_failed", message: "The staged picture did not retain its planned duration.")
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
        var index = 0
        func verify(_ pts: RationalTime, _ duration: RationalTime, independent: Bool) throws {
            if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
            guard index < result.frames.count else {
                throw CutError(code: "write_failed", message: "The staged picture ended before the planned sample at \(pts).")
            }
            let frame = result.frames[index]
            guard frame.time == pts, frame.duration == duration, encoded || !independent || frame.canStart else {
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
                    try verify(frame.time.adding(shift), frame.duration, independent: frameIndex == frames.lowerBound)
                }
            case .still(_, _, _, let schedule):
                var cursor = picture.output.from
                for run in schedule.runs {
                    for _ in 0..<run.count {
                        try verify(cursor, run.duration, independent: cursor == picture.output.from)
                        cursor = try cursor.adding(run.duration)
                    }
                }
            }
        }
        guard index == result.frames.count else {
            throw CutError(code: "write_failed", message: "The staged picture includes samples outside the planned intervals.")
        }
    }

    private func verifyTrackSelection(_ plan: StillExportPlan, media: MediaInfo) throws {
        let expectedSoundTracks = plan.report.soundActions.count
        let soundTracks = media.streams.filter { $0.kind == "audio" }
        guard media.hasVideo == !plan.pictures.isEmpty, soundTracks.count == expectedSoundTracks else {
            throw CutError(code: "write_failed", message: "The staged program did not retain the selected picture and sound tracks.")
        }
        if soundTracks.count > 1 {
            for (stream, action) in zip(soundTracks, plan.report.soundActions) {
                guard action.codec.map({ $0 == stream.codec }) ?? true,
                      action.sampleRate.map({ $0 == stream.sampleRate }) ?? true else {
                    throw CutError(code: "write_failed", message: "The staged track differs from its planned format or order.",
                                   track: stream.index, laneID: action.laneID)
                }
            }
            if soundTracks.map({ $0.disposition & 1 }) != [1] + Array(repeating: 0, count: soundTracks.count - 1) {
                throw CutError(code: "write_failed", message: "The staged program did not retain the planned default soundtrack.")
            }
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
