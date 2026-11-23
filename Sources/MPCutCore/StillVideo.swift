import Foundation

/// Renders one normalized image, then gives that frame an exact picture-only
/// clock in the bundled helper. The original image remains the source asset.
struct StillVideoGenerator {
    var cancelled: (@Sendable () -> Bool)?
    var colorPolicy: StillProgramColorPolicy? = nil
    var standalone = false

    func check(reference: StreamInfo, container: String, schedule: StillSampleSchedule) throws {
        let settings = try Encoding(reference, container: container, policy: colorPolicy, standalone: standalone)
        try check(schedule, settings: settings)
        try verifyHelper(ReencodeEngine.findHelper(override: nil), settings: settings, schedule: schedule)
    }

    func checkLossless(reference: StreamInfo, schedule: StillSampleSchedule) throws {
        let settings = try Encoding(reference, container: "mov", lossless: true,
                                    sampleTimescale: schedule.exactTimescale(), policy: colorPolicy)
        try check(schedule, settings: settings)
        try verifyHelper(ReencodeEngine.findHelper(override: nil), settings: settings, schedule: schedule)
    }

    func generate(asset: URL, identity: SourceIdentity, framing: StillImageFraming, reference: StreamInfo, container: String,
                  schedule: StillSampleSchedule, output: URL) throws -> MediaInfo {
        let engine = CutEngine(cancelled: { Task.isCancelled || cancelled?() == true })
        try engine.checkCancellation()
        try engine.verifyIdentity(asset, identity: identity)
        let settings = try Encoding(reference, container: container, policy: colorPolicy, standalone: standalone)
        try check(schedule, settings: settings)
        let helper = try ReencodeEngine.findHelper(override: nil)
        let parameters = CacheParameters(framing: framing, width: settings.width, height: settings.height,
                                         configuration: reference.configuration, schedule: schedule,
                                         arguments: settings.outputArguments, packetFilters: settings.packetFilters,
                                         colorPolicy: colorPolicy, libraries: helperLibraries(helper),
                                         operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
        let key = try StillSegmentCache.Key(files: [asset, helper], parameters: parameters,
                                            cancelled: cancelled ?? { false })
        return try StillSegmentCache.shared.withSegment(
            key: key, outputExtension: container, cancelled: cancelled ?? { false },
            generate: {
                try encode(asset: asset, identity: identity, framing: framing, helper: helper, settings: settings, schedule: schedule, output: $0)
            }, validate: {
                _ = try validate($0, settings: settings, schedule: schedule)
            }, use: {
                // A cache hit skips encode(), which otherwise checks the planned
                // image generation before reading any pixels.
                try engine.verifyIdentity(asset, identity: identity)
                try FileManager.default.copyItem(at: $0, to: output)
                return try validate(output, settings: settings, schedule: schedule)
            })
    }

    func generateLossless(asset: URL, identity: SourceIdentity, framing: StillImageFraming, reference: StreamInfo,
                          schedule: StillSampleSchedule, output: URL) throws -> MediaInfo {
        let settings = try Encoding(reference, container: "mov", lossless: true,
                                    sampleTimescale: schedule.exactTimescale(), policy: colorPolicy)
        try check(schedule, settings: settings)
        try encode(asset: asset, identity: identity, framing: framing, helper: ReencodeEngine.findHelper(override: nil),
                   settings: settings, schedule: schedule, output: output)
        return try validate(output, settings: settings, schedule: schedule)
    }

    private func check(_ schedule: StillSampleSchedule, settings: Encoding) throws {
        guard schedule.count > 0, schedule.fits(timescale: settings.timescale) else { throw StillSampleSchedule.unsupported }
    }

    private func stagingCadence(for schedule: StillSampleSchedule, timescale: Int64) -> RationalTime {
        if timescale.isMultiple(of: schedule.cadence.denominator) { return schedule.cadence }
        return RationalTime(numerator: max(1, timescale / 30), denominator: timescale)
    }

    private func encode(asset: URL, identity: SourceIdentity, framing: StillImageFraming, helper: URL, settings: Encoding,
                        schedule: StillSampleSchedule, output: URL) throws {
        let runner = ReencodeEngine(cancelled: cancelled)
        try runner.checkCancellation()
        let directory = output.deletingLastPathComponent()
        let input = directory.appendingPathComponent("still-\(UUID().uuidString).rgb48")
        defer { try? FileManager.default.removeItem(at: input) }
        let pixels = try StillImage.render(asset, canvas: settings.canvas, framing: framing, expectedIdentity: identity, cancelled: cancelled).rgb48LE()
        try runner.checkCancellation()
        try pixels.write(to: input, options: .withoutOverwriting)
        try run(helper, settings: settings, schedule: schedule, output: output, input: [
            "-f", "rawvideo", "-pixel_format", "rgb48le", "-video_size", "\(settings.width)x\(settings.height)",
            "-framerate", frameRate(stagingCadence(for: schedule, timescale: settings.timescale)), "-i", input.path
        ])
        guard identity.isCurrentSnapshot(at: asset) else {
            throw CutError(code: "source_changed", message: "The still image changed while generating its video.")
        }
    }

    private func run(_ helper: URL, settings: Encoding, schedule: StillSampleSchedule, output: URL,
                     input: [String], timeout: Duration? = nil) throws {
        let directory = output.deletingLastPathComponent()
        let filters = settings.packetFilters
        let packetArguments = filters.isEmpty ? [] : ["-bsf:v", filters.joined(separator: ",")]
        try ReencodeEngine(cancelled: cancelled).runHelper(helper, arguments: ["-xerror"] + input
            + settings.outputArguments + packetArguments + ["-frames:v", String(schedule.count), "-n", output.path],
            in: directory, timeout: timeout, duration: schedule.duration)
        if schedule.requiresRetime(at: stagingCadence(for: schedule, timescale: settings.timescale)) {
            try ReencodeEngine(cancelled: cancelled).checkCancellation()
            try MulticamMOV.retimeStill(output, schedule: schedule, timescale: settings.timescale)
        }
    }

    private func verifyHelper(_ helper: URL, settings: Encoding, schedule: StillSampleSchedule) throws {
        let identity = try SourceIdentity(helper)
        // The full generated segment is independently validated. For preflight,
        // exercise at most two samples, including a duration change for VFR.
        let cadence = stagingCadence(for: schedule, timescale: settings.timescale)
        let template = try schedule.capabilityProbe(at: cadence)
        let arguments = ["-f", "lavfi", "-i",
                         "testsrc=size=\(settings.width)x\(settings.height):rate=\(frameRate(cadence))"]
        let key = Capability.Key(helper: helper, identity: identity,
                                 args: arguments + settings.outputArguments, packetFilters: settings.packetFilters,
                                 runs: template.runs)
        guard !Capability.shared.contains(key) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-still-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("verify.\(settings.container)")
        do {
            try run(helper, settings: settings, schedule: template, output: output, input: arguments, timeout: .seconds(20))
            _ = try validate(output, settings: settings, schedule: template)
        } catch let error as CutError where error.code != "cancelled" {
            throw CutError(code: "still_encoder_unavailable",
                           message: "The bundled \(settings.codec) encoder could not produce the required still description. \(error.message)")
        }
        Capability.shared.record(key)
    }

    private func validate(_ url: URL, settings: Encoding, schedule: StillSampleSchedule) throws -> MediaInfo {
        let media = try Probe.read(url, keyframes: true, conversion: settings.lossless, cancelled: cancelled)
        let video = media.video
        guard media.streams.count == 1, media.hasVideo, media.audio.isEmpty,
              video.codec == settings.codec, video.codecTag == settings.tag,
              settings.profile == nil || settings.profile == video.profile, video.width == settings.width,
              video.height == settings.height, video.sampleAspectRatio == settings.sar,
              video.timeBase == RationalTime(numerator: 1, denominator: settings.timescale),
              video.colorTransfer == settings.transfer, video.colorPrimaries == settings.primaries,
              video.colorMatrix == settings.matrix,
              settings.lossless || video.colorRange == settings.range,
              settings.lossless || video.bitDepth == settings.depth,
              settings.lossless || ReencodeVideo.chromaSampling(video.pixelFormat) == settings.chroma,
              !settings.lossless || video.pixelFormat == settings.pixelFormat,
              settings.chromaLocation == nil || video.chromaLocation == settings.chromaLocation,
              !video.multipleDescriptions, media.sourceStartSafe, media.frames.first?.canStart == true,
              media.origin == .zero, media.duration == schedule.duration, media.frames.count == schedule.count else {
            throw CutError(code: "still_description", message: "The generated still does not match the required picture description or duration.")
        }
        var position = RationalTime.zero
        var index = 0
        let engine = CutEngine(cancelled: { Task.isCancelled || cancelled?() == true })
        for run in schedule.runs {
            for _ in 0..<run.count {
                if index.isMultiple(of: 1_024) {
                    try engine.checkCancellation()
                }
                let frame = media.frames[index]
                guard frame.time == position, frame.dts == position, frame.duration == run.duration else {
                    throw CutError(code: "still_timing", message: "The generated picture clock changed at sample \(index + 1).")
                }
                position = try position.adding(run.duration)
                index += 1
            }
        }
        return media
    }

    private func frameRate(_ cadence: RationalTime) -> String { "\(cadence.denominator)/\(cadence.numerator)" }

    private func helperLibraries(_ helper: URL) -> [String: SourceIdentity] {
        let root = helper.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let prefixes = ["libavcodec.", "libavformat.", "libavutil.", "libavfilter.", "libswscale."]
        var identities: [String: SourceIdentity] = [:]
        for folder in ["Frameworks", "lib"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for entry in entries where entry.pathExtension == "dylib" &&
                prefixes.contains(where: entry.lastPathComponent.hasPrefix) {
                identities["\(folder)/\(entry.lastPathComponent)"] = try? SourceIdentity(entry)
            }
        }
        return identities
    }

    private struct CacheParameters: Encodable {
        let policyVersion = 4
        let framing: StillImageFraming
        let width: Int
        let height: Int
        let configuration: Data
        let schedule: StillSampleSchedule
        let arguments: [String]
        let packetFilters: [String]
        let colorPolicy: StillProgramColorPolicy?
        let libraries: [String: SourceIdentity]
        let operatingSystem: String
    }

    private final class Capability: @unchecked Sendable {
        struct Key: Equatable {
            let helper: URL
            let identity: SourceIdentity
            let args: [String]
            let packetFilters: [String]
            let runs: [StillSampleSchedule.Run]
        }
        static let shared = Capability()
        private let lock = NSLock()
        private var keys: [Key] = []
        func contains(_ key: Key) -> Bool { lock.withLock { keys.contains(key) } }
        func record(_ key: Key) {
            lock.withLock {
                if keys.count >= 32 { keys.removeFirst() }
                keys.append(key)
            }
        }
    }
}

extension StillVideoGenerator {
    private struct Encoding {
        let codec: String
        let tag: String
        let profile: Int?
        let profileName: String?
        let pixelFormat: String
        let depth: Int
        let chroma: Int
        let chromaLocation: String?
        let width: Int
        let height: Int
        let sar: RationalTime
        let range: String
        let transfer: String
        let primaries: String
        let matrix: String
        let container: String
        let timescale: Int64
        let lossless: Bool
        let diffuseWhiteNits: Int

        init(_ video: StreamInfo, container: String, lossless: Bool = false, sampleTimescale: Int64? = nil,
             policy: StillProgramColorPolicy?, standalone: Bool = false) throws {
            self.container = container
            self.lossless = lossless
            try policy?.validate()
            let hdr = ["smpte2084", "arib-std-b67"].contains(policy?.transfer ?? video.colorTransfer)
            func normalized(_ value: String, fallback: String) -> String {
                ["", "unknown", "unspecified", "reserved"].contains(value) ? fallback : value
            }
            transfer = normalized(policy?.transfer ?? video.colorTransfer, fallback: "bt709")
            primaries = normalized(policy?.primaries ?? video.colorPrimaries, fallback: hdr ? "bt2020" : "bt709")
            diffuseWhiteNits = policy?.diffuseWhiteNits ?? 203
            let turn = lossless && !video.rotation.isMultiple(of: 180)
            width = turn ? video.height : video.width
            height = turn ? video.width : video.height
            sar = turn ? RationalTime(numerator: video.sampleAspectRatio.denominator,
                                      denominator: max(1, video.sampleAspectRatio.numerator)) : video.sampleAspectRatio
            try StillImage.validateDimensions(width, height, maximumPixels: 8_192 * 4_320)
            guard sar > .zero, sar.numerator <= Int32.max, sar.denominator <= Int32.max,
                  ["bt709", "smpte170m", "bt2020", "smpte432"].contains(primaries),
                  ["bt709", "smpte170m", "iec61966-2-1", "smpte2084", "arib-std-b67"].contains(transfer) else {
                throw Self.unsupported("The picture geometry or color interpretation is unsupported.")
            }
            if lossless {
                codec = "rawvideo"
                tag = "b48r"
                profile = nil
                profileName = nil
                pixelFormat = "rgb48be"
                depth = 16
                chroma = 444
                chromaLocation = nil
                matrix = "gbr"
                range = "pc"
                timescale = sampleTimescale ?? 0
                return
            }

            guard video.rotation == 0, (!video.complexPicture || (!video.codecMetadata.isEmpty && video.hasOnlyHDRStaticMetadata)),
                  !video.hasAlpha, !video.hasAdditionalVideoLayers,
                  ["progressive", "unknown"].contains(video.fieldOrder), !video.multipleDescriptions,
                  video.timeBase.numerator == 1, video.timeBase.denominator <= Int32.max,
                  width.isMultiple(of: 2), height.isMultiple(of: 2),
                  ["mov", "mp4", "m4v"].contains(container) else {
                throw Self.unsupported("This picture geometry, stream layout, metadata or output container needs conversion.")
            }
            timescale = video.timeBase.denominator
            range = normalized(policy?.range ?? video.colorRange, fallback: "tv")
            matrix = normalized(policy?.matrix ?? video.colorMatrix, fallback: hdr ? "bt2020nc" : "bt709")
            guard ["tv", "pc"].contains(range), ["bt709", "smpte170m", "bt470bg", "bt2020nc"].contains(matrix) else {
                throw Self.unsupported("The camera color matrix or range is unsupported.")
            }
            if hdr {
                guard video.colorPrimaries == "bt2020", video.colorMatrix == "bt2020nc",
                      video.colorRange == "tv" else {
                    throw Self.unsupported("Specify a complete compatible Rec.2100 color interpretation before generating HDR stills.")
                }
            }
            codec = video.codec
            tag = video.codecTag
            profile = video.profile
            depth = video.bitDepth
            switch (video.codec, video.profile, hdr) {
            case ("prores", 2, _) where container == "mov" && tag == "apcn" && depth == 10 && (!hdr || standalone):
                profileName = "standard"
                pixelFormat = "p210le"
                chroma = 422
                chromaLocation = nil
            case ("h264", 100, false), ("h264", 77, false), ("h264", 66, false):
                guard tag == "avc1", depth == 8, standalone || !video.configuration.isEmpty else {
                    throw Self.unsupported("Still generation requires an 8-bit AVC sample description with an avc1 tag.")
                }
                profileName = video.profile == 100 ? "high" : video.profile == 77 ? "main" : "baseline"
                pixelFormat = "nv12"
                chroma = 420
                chromaLocation = normalized(video.chromaLocation, fallback: "left")
            case ("hevc", 2, true) where (container == "mov" || standalone) && tag == "hvc1" && depth == 10 &&
                (standalone || !video.configuration.isEmpty):
                profileName = "main10"
                pixelFormat = "p010le"
                chroma = 420
                chromaLocation = normalized(video.chromaLocation, fallback: "left")
            case ("hevc", 1, false) where standalone && tag == "hvc1" && depth == 8:
                profileName = "main"
                pixelFormat = "nv12"
                chroma = 420
                chromaLocation = normalized(video.chromaLocation, fallback: "left")
            default:
                throw Self.unsupported("Still generation is unavailable for \(video.codec) profile \(video.profile) in \(container).")
            }
            guard ReencodeVideo.chromaSampling(video.pixelFormat) == chroma,
                  chromaLocation == nil || chromaLocation == "left" else {
                throw Self.unsupported("The camera chroma geometry does not match the still encoder.")
            }
        }

        var canvas: StillImageCanvas {
            StillImageCanvas(width: width, height: height, displayAspect: Double(width) * sar.seconds / Double(height),
                             transfer: transfer, primaries: primaries, diffuseWhiteNits: diffuseWhiteNits)
        }

        var outputArguments: [String] {
            // The renderer supplies encoded RGB in the selected transfer and
            // primaries. Scale converts the matrix and range only. Set frame
            // properties before VT so its codec headers agree with the container.
            var filters = ["format=rgb48le", "loop=loop=-1:size=1:start=0"]
            if !lossless {
                let coefficients = matrix == "bt2020nc" ? "bt2020" : matrix
                let position = chromaLocation == "left" ? ":out_h_chr_pos=0:out_v_chr_pos=128" : ""
                filters.append("scale=in_range=full:out_range=\(range):out_color_matrix=\(coefficients)\(position)")
            }
            filters += ["format=\(pixelFormat)", "setsar=sar=\(sar):max=2147483647",
                        "setparams=range=\(range):color_primaries=\(primaries):color_trc=\(transfer):colorspace=\(matrix)"]
            var result = ["-map", "0:v:0", "-an", "-sn", "-dn", "-vf", filters.joined(separator: ",")]
            if let profileName {
                result += ["-c:v", "\(codec)_videotoolbox", "-allow_sw", "0", "-profile:v", profileName, "-bf", "0"]
                if codec != "prores" { result += ["-g", "60", "-q:v", "75"] }
            } else {
                result += ["-c:v", "rawvideo"]
            }
            return result + ["-pix_fmt", pixelFormat, "-tag:v", tag, "-color_range", range,
                             "-color_trc", transfer, "-color_primaries", primaries, "-colorspace", lossless ? "rgb" : matrix,
                             "-movflags", "+write_colr", "-video_track_timescale", String(timescale),
                             "-movie_timescale", String(timescale), "-use_editlist", "0",
                             "-write_tmcd", "0", "-f", container == "m4v" ? "mp4" : container]
        }

        var packetFilters: [String] {
            // VideoToolbox can add Dolby Vision RPU to HLG. The authored
            // color policy requests plain HLG for these generated samples.
            codec == "hevc" && transfer == "arib-std-b67" ? ["filter_units=remove_types=62|63"] : []
        }

        static func unsupported(_ reason: String) -> CutError {
            CutError(code: "still_generation_unavailable", message: reason)
        }
    }
}
