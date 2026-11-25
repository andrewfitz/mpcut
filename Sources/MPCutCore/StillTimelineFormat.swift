import Foundation

/// The delivery format and frame clock of a sequence without a camera source.
public struct StillTimelineFormat: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// The exact duration of one picture sample.
    public let cadence: RationalTime
    public let codec: ReencodeCodec
    public let container: String

    public init(width: Int, height: Int, cadence: RationalTime, codec: ReencodeCodec, container: String) {
        self.width = width
        self.height = height
        self.cadence = cadence
        self.codec = codec
        self.container = container
    }

    public static func containers(for codec: ReencodeCodec) -> [String] {
        ExportRules.stillMovieContainers.filter {
            ExportRules.reencodeContainers(codec).contains(ExportRules.multicamMuxContainer($0))
        }
    }

    var requiresExtendedStillSchema: Bool {
        codec == .jpeg || !["mov", "mp4"].contains(container)
    }

    public func validate() throws {
        guard (2...8192).contains(width), (2...8192).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2), width * height <= 16_777_216 else {
            throw CutError(code: "invalid_still_format", message: "Use even dimensions up to 8192 per side and 16,777,216 total pixels.")
        }
        guard cadence.numerator > 0, cadence.numerator <= Int64(Int32.max),
              cadence.denominator <= Int64(Int32.max),
              cadence >= .init(numerator: 1, denominator: 240) else {
            throw CutError(code: "invalid_still_format", message: "Use a positive frame rate up to 240 fps with 32-bit rational terms.")
        }
        guard Self.containers(for: codec).contains(container) else {
            throw CutError(code: "invalid_still_format",
                           message: "Choose a \(Self.containers(for: codec).joined(separator: " or ")) container for \(codec.rawValue).")
        }
    }

    public func frameCount(for duration: RationalTime) throws -> Int64 {
        try validate()
        let rate = RationalTime(numerator: cadence.denominator, denominator: cadence.numerator)
        let count = try duration.multiplied(by: rate)
        guard count.numerator > 0, count.numerator <= Int64(Int32.max), count.denominator == 1 else {
            throw CutError(code: "invalid_still_time", message: "The still duration must contain between 1 and 2,147,483,647 whole frames.")
        }
        return count.numerator
    }

    private enum CodingKeys: String, CodingKey { case width, height, cadence, codec, container }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_still_format")
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try fields.decode(Int.self, forKey: .width),
                  height: try fields.decode(Int.self, forKey: .height),
                  cadence: try ProjectField.time(fields, .cadence),
                  codec: try fields.decode(ReencodeCodec.self, forKey: .codec),
                  container: try fields.decode(String.self, forKey: .container))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(width, forKey: .width)
        try fields.encode(height, forKey: .height)
        try fields.encode(cadence.description, forKey: .cadence)
        try fields.encode(codec, forKey: .codec)
        try fields.encode(container, forKey: .container)
    }
}

extension StillTimelineFormat {
    public enum Color: String, CaseIterable, Sendable {
        case sdr, pq, hlg

        public var policy: StillProgramColorPolicy {
            if self == .sdr { return StillTimelineFormat.sdrColorPolicy }
            return StillProgramColorPolicy(transfer: self == .pq ? "smpte2084" : "arib-std-b67",
                                           primaries: "bt2020", matrix: "bt2020nc", range: "tv",
                                           viewingConditions: "Rec.2100 reference", diffuseWhiteNits: 203)
        }
    }

    public static let sdrColorPolicy = StillProgramColorPolicy(
        transfer: "bt709", primaries: "bt709", matrix: "bt709", range: "tv",
        viewingConditions: "rec709-reference", diffuseWhiteNits: 100
    )

    package func validate(color: StillProgramColorPolicy) throws {
        try validate()
        try color.validate()
        let hdr = ["smpte2084", "arib-std-b67"].contains(color.transfer)
        guard !hdr || codec == .hevc || codec == .prores else {
            throw CutError(code: "invalid_still_format", message: "Choose HEVC or ProRes for an HDR still timeline.")
        }
        guard !hdr || (color.primaries == "bt2020" && color.matrix == "bt2020nc" && color.range == "tv") else {
            throw CutError(code: "invalid_still_format", message: "PQ and HLG require limited-range Rec.2100 program color.")
        }
    }

    /// `deep` selects HEVC Main 10 for an SDR program whose images have more than 8 bits, and
    /// `quality` the ProRes profile (422 LT, 422 or 422 HQ). Without them the stream is HEVC Main
    /// for SDR and ProRes 422.
    func targetStream(color: StillProgramColorPolicy, duration: RationalTime,
                      pictureClock: Int64? = nil, deep: Bool = false,
                      quality: ReencodeQuality? = nil) throws -> StreamInfo {
        try validate(color: color)
        guard duration > .zero else {
            throw CutError(code: "invalid_still_time", message: "The still duration must be positive.")
        }
        let hdr = ["smpte2084", "arib-std-b67"].contains(color.transfer)
        let codecTag: String
        let profile: Int
        let pixelFormat: String
        let bitDepth: Int
        switch codec {
        case .h264:
            (codecTag, profile, pixelFormat, bitDepth) = ("avc1", 100, "yuv420p", 8)
        case .hevc:
            let ten = hdr || deep
            (codecTag, profile, pixelFormat, bitDepth) = ("hvc1", ten ? 2 : 1, ten ? "yuv420p10le" : "yuv420p", ten ? 10 : 8)
        case .jpeg:
            (codecTag, profile, pixelFormat, bitDepth) = ("jpeg", 192, "yuvj420p", 8)
        case .prores:
            switch quality {
            case .proresLT: (codecTag, profile) = ("apcs", 1)
            case .proresHQ: (codecTag, profile) = ("apch", 3)
            default: (codecTag, profile) = ("apcn", 2)
            }
            (pixelFormat, bitDepth) = ("yuv422p10le", 10)
        }
        return StreamInfo(index: 0, trackID: 1, kind: "video", codec: codec == .jpeg ? "mjpeg" : codec.rawValue, codecTag: codecTag,
                          profile: profile, width: width, height: height, displayWidth: width, displayHeight: height,
                          rotation: 0, rotationOnly: true, bitDepth: bitDepth, pixelFormat: pixelFormat,
                          alphaBits: 0, hasAdditionalVideoLayers: false,
                          frameRate: .init(numerator: cadence.denominator, denominator: cadence.numerator),
                          sampleAspectRatio: .init(numerator: 1),
                          timeBase: .init(numerator: 1, denominator: pictureClock ?? cadence.denominator),
                          start: .zero, hasDeclaredStart: true, duration: duration,
                          sampleRate: 0, channels: 0, channelLayout: "", language: "und", disposition: 0,
                          isPCM: false, initialPadding: 0, trailingPadding: 0, seekPreroll: 0,
                          colorPrimaries: color.primaries, colorTransfer: color.transfer, colorMatrix: color.matrix,
                          fieldOrder: "progressive", chromaLocation: "left", colorRange: codec == .jpeg ? "pc" : color.range,
                          configuration: Data(), codecMetadata: Data(), multipleDescriptions: false,
                          complexPicture: false, reconstructedDTS: false)
    }
}

extension CutProject {
    package static func makeStillTimeline(format: StillTimelineFormat, asset: StillAsset,
                                          placementID: String, duration: RationalTime,
                                          framing: StillImageFraming = .fit,
                                          colorPolicy: StillProgramColorPolicy = StillTimelineFormat.sdrColorPolicy) throws -> CutProject {
        _ = try format.frameCount(for: duration)
        try format.validate(color: colorPolicy)
        let still = StillInsert(id: placementID, assetID: asset.id, duration: duration,
                                cadence: format.cadence, framing: framing)
        let result = CutProject.stillSequence(StillSequenceProject(
            items: [.still(still)], stillAssets: [asset], programColorPolicy: colorPolicy,
            stillFormat: format
        ))
        try result.validate()
        return result
    }
}
