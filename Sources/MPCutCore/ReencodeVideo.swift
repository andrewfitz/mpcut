import Foundation

struct ReencodeVideo: Sendable {
    let width: Int
    let height: Int
    let codedWidth: Int
    let codedHeight: Int
    let pixelFormat: String
    let arguments: [String]
    let warning: String?

    /// The picture a mixed timeline is fitted into. A uniform timeline has none and keeps its source's picture.
    struct Frame: Sendable {
        let width: Int
        let height: Int
        /// True when any source has more than eight bits, so HEVC keeps ten.
        let deep: Bool
    }

    init(_ stream: StreamInfo, settings: ReencodeSettings, frame: Frame? = nil,
         stillColor: StillProgramColorPolicy? = nil) throws {
        guard !stream.hasAlpha else {
            throw CutError(code: "unsupported_format", message: "The selected hardware profiles do not preserve the source’s alpha channel.")
        }
        guard stream.rotation.isMultiple(of: 90) else {
            throw CutError(code: "unsupported_format", message: "Re-encode supports display rotations in 90-degree increments.")
        }
        guard ["progressive", "unknown"].contains(stream.fieldOrder) else {
            throw CutError(code: "unsupported_format", message: "Re-encode cannot preserve this source’s interlaced field order.")
        }
        width = frame?.width ?? stream.displayWidth
        height = frame?.height ?? stream.displayHeight
        let turn = !stream.rotation.isMultiple(of: 180)
        codedWidth = frame?.width ?? (turn ? stream.height : stream.width)
        codedHeight = frame?.height ?? (turn ? stream.width : stream.height)
        guard codedWidth > 0, codedHeight > 0, codedWidth.isMultiple(of: 2),
              settings.codec == .prores || codedHeight.isMultiple(of: 2) else {
            throw CutError(code: "unsupported_format", message: "The selected hardware profile cannot preserve these picture dimensions.")
        }
        let transfer = stillColor?.transfer ?? stream.colorTransfer
        let hdr = ["smpte2084", "arib-std-b67"].contains(transfer)
        let maximumDepth = settings.codec == .h264 ? 8 : 10
        guard !hdr || maximumDepth >= 10 else {
            throw CutError(code: "unsupported_format", message: "The selected hardware profile cannot preserve the source’s HDR transfer function.")
        }
        var reductions: [String] = []
        if stream.bitDepth > maximumDepth {
            reductions.append("from \(stream.bitDepth)-bit to \(maximumDepth)-bit")
        }
        let targetChroma = settings.codec == .prores ? 422 : 420
        if let sourceChroma = Self.chromaSampling(stream.pixelFormat), sourceChroma > targetChroma {
            reductions.append("chroma from \(Self.chromaName(sourceChroma)) to \(Self.chromaName(targetChroma))")
        }
        warning = reductions.isEmpty ? nil
            : "The selected profile will reduce video \(reductions.joined(separator: " and "))."

        let quality: [String]
        switch (settings.codec, settings.quality) {
        case (.prores, .proresLT): quality = ["-profile:v", "lt"]
        case (.prores, .prores422): quality = ["-profile:v", "standard"]
        case (.prores, .proresHQ): quality = ["-profile:v", "hq"]
        case (.h264, .smallerFile), (.hevc, .smallerFile): quality = ["-q:v", "45"]
        case (.h264, .balanced), (.hevc, .balanced): quality = ["-q:v", "60"]
        case (.h264, .highQuality), (.hevc, .highQuality): quality = ["-q:v", "75"]
        default:
            throw CutError(code: "unsupported_quality", message: "Choose a quality available for the selected video codec.")
        }

        if settings.codec == .prores {
            pixelFormat = "p210le"
        } else if settings.codec == .hevc, stream.bitDepth > 8 || hdr || frame?.deep == true {
            pixelFormat = "p010le"
        } else {
            pixelFormat = "nv12"
        }
        let matrix = stillColor?.matrix ?? (stream.colorMatrix == "gbr" ? "bt709" : stream.colorMatrix)
        let values = [("-color_primaries", stillColor?.primaries ?? stream.colorPrimaries), ("-color_trc", transfer),
                      ("-colorspace", matrix), ("-color_range", stillColor?.range ?? stream.colorRange)]
        let color = values.flatMap { option, value in
            value.isEmpty || ["unknown", "unspecified", "reserved"].contains(value) ? [] : [option, value]
        }
        arguments = ["-c:v", settings.codec.encoder, "-allow_sw", "0", "-bf", "0"]
            + quality + color
    }

    /// Chroma sampling of an FFmpeg pixel format name, ordered so that a larger value keeps more chroma.
    static func chromaSampling(_ format: String) -> Int? {
        let name = format.lowercased()
        if ["gbr", "rgb", "bgr", "argb", "abgr", "rgba", "bgra", "x2rgb", "x2bgr", "ayuv", "vuya", "xv3", "xv4", "y410", "y412"]
            .contains(where: name.hasPrefix) || name.contains("444") { return 444 }
        if name.contains("422") || name.hasPrefix("p21") || name.hasPrefix("p22") || ["uyvy", "yuyv", "yvyu", "y210", "y212", "nv16", "nv20"]
            .contains(where: name.hasPrefix) { return 422 }
        if name.contains("440") { return 440 }
        if name.contains("420") || ["nv12", "nv21", "p010", "p012", "p016"].contains(where: name.hasPrefix) { return 420 }
        return nil
    }

    static func chromaName(_ sampling: Int) -> String {
        switch sampling {
        case 444: "4:4:4"
        case 440: "4:4:0"
        case 422: "4:2:2"
        default: "4:2:0"
        }
    }
}

extension ReencodeEngine {
    static func findHelper(override: URL?) throws -> URL {
        if let override {
            guard override.isFileURL, FileManager.default.isExecutableFile(atPath: override.path) else {
                throw CutError(code: "helper_unavailable", message: "The selected FFmpeg helper is unavailable.")
            }
            return override.standardizedFileURL
        }

        // A launcher may pass just "mpcut" as argv[0] when resolving it on PATH.
        guard let executable = Bundle.main.executableURL else {
            throw CutError(code: "helper_unavailable", message: "Could not locate the running MPCut executable.")
        }
        let folder = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = folder.deletingLastPathComponent()
        if folder.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" {
            let bundled = contents.appendingPathComponent("Helpers/ffmpeg")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
            throw CutError(code: "helper_unavailable", message: "The bundled arm64 FFmpeg helper is unavailable.")
        }

        var candidates = [folder.appendingPathComponent("ffmpeg")]
        var ancestor = folder
        while ancestor.path != "/" {
            if ancestor.lastPathComponent == ".build" {
                candidates.append(ancestor.appendingPathComponent("mpcut-ffmpeg/install/bin/ffmpeg"))
                break
            }
            ancestor.deleteLastPathComponent()
        }
        if let development = ProcessInfo.processInfo.environment["MPCUT_FFMPEG_HELPER"], development.hasPrefix("/") {
            candidates.insert(URL(fileURLWithPath: development), at: 0)
        }
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw CutError(code: "helper_unavailable", message: "The arm64 FFmpeg helper is unavailable. Run scripts/build-ffmpeg.sh for a development build.")
    }

    func verifyAV1Decoder(_ helper: URL, media: MediaInfo) throws {
        let args = ["-xerror"] + ReencodeDecode.compatible.options(for: media.video) + [
            "-i", media.url.path, "-map", "0:\(media.video.index)", "-frames:v", "1", "-f", "null", "-"
        ]
        let key = ReencodeCapabilityKey(helper: helper, identity: try? SourceIdentity(helper),
                                       source: media.identity, args: args)
        if ReencodeCapabilities.shared.contains(key) { return }
        do {
            try runHelper(helper, arguments: args, in: FileManager.default.temporaryDirectory)
        } catch let error as CutError where error.code != "cancelled" {
            throw CutError(code: "decoder_unavailable",
                           message: "This Mac could not decode the AV1 source with VideoToolbox. \(error.message)")
        }
        ReencodeCapabilities.shared.insert(key)
    }

    func verifyHardware(_ helper: URL, encoding: ReencodeVideo, container: String, actions: [ReencodeAudioAction],
                        audio: [StreamInfo], exactPCM: Set<Int>, canvas: ReencodeCanvas? = nil) throws {
        try checkCancellation()
        var args = ["-xerror",
                    "-f", "lavfi", "-i", "testsrc=size=\(encoding.codedWidth)x\(encoding.codedHeight):rate=30:duration=0.1"]
        // The sound formats the encoder is asked for: the first clip's, or the canvas of a mixed timeline.
        struct Sound { let rate: Int; let channels: Int; let layout: String; let index: Int; let options: [String] }
        var converted: [Sound] = []
        if let canvas {
            for (action, sound) in zip(actions, canvas.audio) where [.aac, .pcm].contains(action.action) {
                converted.append(Sound(rate: sound.sampleRate, channels: sound.channels, layout: sound.layout, index: action.track,
                                       options: audioOptions(action.action, sound: sound, outputIndex: converted.count)))
            }
        } else {
            for (action, track) in zip(actions, audio) where [.aac, .pcm].contains(action.action) || exactPCM.contains(action.track) {
                converted.append(Sound(rate: track.sampleRate, channels: track.channels, layout: try audioLayout(track), index: track.index,
                                       options: audioOptions(action.action, track: track, outputIndex: converted.count,
                                                             exactPCM: exactPCM.contains(action.track))))
            }
        }
        for track in converted {
            args += ["-f", "lavfi", "-i",
                     "anullsrc=r=\(track.rate):cl=\(track.layout):d=0.1"]
        }
        args += ["-map", "0:v:0"]
        for (position, _) in converted.enumerated() { args += ["-map", "\(position + 1):a:0"] }
        args += encoding.arguments + ["-pix_fmt", encoding.pixelFormat]
        for track in converted { args += track.options }
        args += ["-f", muxerName(container), "verify.\(container)"]
        let key = ReencodeCapabilityKey(helper: helper, identity: try? SourceIdentity(helper), args: args)
        if ReencodeCapabilities.shared.contains(key) { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-check-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try runHelper(helper, arguments: args, in: directory, timeout: .seconds(20))
        } catch let error as CutError where error.code != "cancelled" {
            throw CutError(code: "encoder_unavailable",
                           message: "The selected hardware encoder and output settings are unavailable on this Mac. \(error.message)")
        }
        let verification = try Probe.read(directory.appendingPathComponent("verify.\(container)"), keyframes: false,
                                          cancelled: cancelled)
        guard verification.video.width == encoding.codedWidth, verification.video.height == encoding.codedHeight else {
            throw CutError(code: "unsupported_format", message: "The selected hardware profile could not preserve the picture dimensions.")
        }
        guard verification.audio.count == converted.count else {
            throw CutError(code: "unsupported_audio", message: "The selected container could not preserve the requested audio tracks.")
        }
        for (source, output) in zip(converted, verification.audio.map(\.stream)) {
            // Some PCM muxers omit channel-order tags for standard mono or stereo.
            let expected = source.layout
            let actual = try? audioLayout(output)
            guard output.sampleRate == source.rate, output.channels == source.channels, actual == expected else {
                throw CutError(code: "unsupported_audio",
                               message: "The selected format cannot preserve the sample rate and channel layout of audio track \(source.index).",
                               track: source.index)
            }
        }
        ReencodeCapabilities.shared.insert(key)
    }
}

enum ReencodeDecode {
    case surfaces, hardware, compatible

    /// `surfaces` is false when each source is fitted into a canvas: the fitting filters read decoded buffers.
    static func preferred(for streams: [StreamInfo], output: String, surfaces: Bool = true) -> Self {
        let codecs = ["h264", "hevc", "av1", "vp9", "prores", "mpeg2video", "mpeg4"]
        guard !streams.isEmpty, streams.allSatisfy({ codecs.contains($0.codec) && nativeFormat($0) != nil }) else {
            return .compatible
        }
        guard surfaces else { return .hardware }
        // Quarter-turn camera matrices can be baked into a hardware surface.
        // The surface encoder can tag full-range input as video-range. Let FFmpeg
        // supply a buffer with the explicit range for those clips and conversions.
        if streams.allSatisfy({ stream in
            nativeFormat(stream) == output && stream.colorRange != "pc" && stream.pixelFormat != "yuvj420p" &&
                !stream.multipleDescriptions &&
                (stream.codecMetadata.isEmpty || (stream.rotationOnly && !stream.complexPicture))
        }) { return .surfaces }
        return .hardware
    }

    private static func nativeFormat(_ stream: StreamInfo) -> String? {
        switch stream.pixelFormat {
        case "yuv420p", "yuvj420p", "nv12": return "nv12"
        case "yuv420p10le", "p010le": return "p010le"
        case "yuv422p10le", "p210le": return "p210le"
        case "yuv422p", "yuvj422p": return "nv16"
        case "yuv444p", "yuvj444p": return "nv24"
        case "yuv444p10le": return "p410le"
        case "yuv444p12le": return "p416le"
        default: return nil
        }
    }

    func rotationFilter(for stream: StreamInfo) -> String? {
        guard self == .surfaces, stream.rotationOnly, stream.rotation != 0 else { return nil }
        if abs(stream.rotation) == 180 { return "transpose_vt=reversal" }
        let turn = stream.rotation == 90 ? "cclock" : "clock"
        let sar = stream.sampleAspectRatio
        let aspect = sar.numerator > 0 ? ",setsar=\(sar.denominator)/\(sar.numerator):max=2147483647" : ""
        return "transpose_vt=\(turn)" + aspect
    }

    func options(for stream: StreamInfo) -> [String] {
        guard self != .compatible || stream.codec == "av1" else { return [] }
        var args = ["-hwaccel", "videotoolbox"]
        if self == .surfaces { args += ["-hwaccel_output_format", "videotoolbox_vld"] }
        if rotationFilter(for: stream) != nil { args += ["-display_rotation:v:0", "0"] }
        if stream.codec == "av1" { args += ["-c:v", "av1"] }
        return args
    }
}

private struct ReencodeCapabilityKey: Equatable {
    let helper: URL
    let identity: SourceIdentity?
    var source: SourceIdentity? = nil
    let args: [String]
}

private final class ReencodeCapabilities: @unchecked Sendable {
    static let shared = ReencodeCapabilities()

    private let lock = NSLock()
    private var verified: [ReencodeCapabilityKey] = []

    func contains(_ key: ReencodeCapabilityKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return verified.contains(key)
    }

    func insert(_ key: ReencodeCapabilityKey) {
        lock.lock()
        defer { lock.unlock() }
        if verified.count >= 32 { verified.removeFirst() }
        verified.append(key)
    }
}
