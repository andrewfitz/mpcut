import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

public struct StillImageInfo: Codable, Sendable {
    public enum Codec: String, Codable, Sendable, CaseIterable {
        case jpeg, png, tiff, webp, heic, heif, avif, jxl
    }

    public enum Rendition: String, Codable, Sendable {
        case sdr, pq, hlg, linearHDR, gainMap
    }

    public let codec: Codec
    public let width: Int
    public let height: Int
    public let orientation: UInt32
    public let bitsPerComponent: Int
    public let hasAlpha: Bool
    public let colorSpace: String?
    public let embeddedProfile: String?
    public let auxiliaryImages: [String]
    public let rendition: Rendition
    public let headroom: Float?

    public var displayWidth: Int { orientation >= 5 ? height : width }
    public var displayHeight: Int { orientation >= 5 ? width : height }
}

public struct StillImageCanvas: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let displayAspect: Double?
    public let transfer: String
    public let primaries: String
    public let diffuseWhiteNits: Int

    public init(
        width: Int, height: Int, displayAspect: Double? = nil,
        transfer: String = "bt709", primaries: String = "bt709", diffuseWhiteNits: Int = 203
    ) {
        self.width = width
        self.height = height
        self.displayAspect = displayAspect
        self.transfer = transfer
        self.primaries = primaries
        self.diffuseWhiteNits = diffuseWhiteNits
    }
}

public enum StillImage {
    public static let filenameExtensions = ["avif", "heic", "heif", "jpe", "jpeg", "jpg", "jxl", "png", "tif", "tiff", "webp"]
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let linear2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let linear709 = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    public static func inspect(_ url: URL) throws -> StillImageInfo {
        try decode(url).info
    }

    public static func fingerprint(_ url: URL, cancelled: (() -> Bool)? = nil) throws -> String {
        if cancelled?() == true { throw CancellationError() }
        let file = try openRegularImage(url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            if cancelled?() == true { throw CancellationError() }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func error(_ code: String, _ message: String) -> CutError {
        CutError(code: code, message: message)
    }

    static func validateDimensions(_ width: Int, _ height: Int, maximumPixels: Int) throws {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= maximumPixels / height else {
            throw error("still_dimensions", "Image dimensions \(width)×\(height) exceed the still image allocation limit.")
        }
    }

    private static func codec(_ type: String, header: [UInt8]) -> StillImageInfo.Codec? {
        if header.count >= 12, header[4..<8].elementsEqual("ftyp".utf8),
           header[8..<12].elementsEqual("avif".utf8) || header[8..<12].elementsEqual("avis".utf8) {
            return .avif
        }
        switch type {
        case "public.jpeg": return .jpeg
        case "public.png": return .png
        case "public.tiff": return .tiff
        case "org.webmproject.webp", "public.webp": return .webp
        case "public.heic", "public.heics": return .heic
        case "public.heif": return .heif
        case "public.avif": return .avif
        case "public.jpeg-xl", "org.jpeg.jpegxl", "public.jxl": return .jxl
        default: return nil
        }
    }

    private static func jxlHDRColorSpace(_ codec: StillImageInfo.Codec, profile: String?) -> CGColorSpace? {
        guard codec == .jxl, let profile else { return nil }
        let parts = profile.split(separator: "_")
        guard let transfer = parts.last, transfer == "PeQ" || transfer == "HLG" else { return nil }
        let name: CFString
        if parts.contains("P3") {
            name = transfer == "PeQ" ? CGColorSpace.displayP3_PQ : CGColorSpace.displayP3_HLG
        } else if parts.contains("SRG") {
            name = transfer == "PeQ" ? CGColorSpace.itur_709_PQ : CGColorSpace.itur_709_HLG
        } else {
            name = transfer == "PeQ" ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG
        }
        return CGColorSpace(name: name)
    }

    static func decode(
        _ url: URL, previewDimension: Int? = nil, forceISOGainMapFallback: Bool = false
    ) throws -> (image: CGImage, info: StillImageInfo, colorSpace: CGColorSpace) {
        try Task.checkCancellation()
        let name = url.lastPathComponent
        let file = try openRegularImage(url)
        defer { try? file.close() }
        let header = Array((try? file.read(upToCount: 32)) ?? Data())
        let webpAnimated = header.count > 20 && header[8..<16].elementsEqual("WEBPVP8X".utf8)
            && header[20] & 0x02 != 0
        let avifAnimated = header.count >= 12 && header[4..<12].elementsEqual("ftypavis".utf8)
        guard !webpAnimated, !avifAnimated else {
            throw error("still_animated", "\(name) contains an image sequence.")
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source) as String?,
              let codec = codec(type, header: header) else {
            throw error("still_format", "\(name) is not a supported static image.")
        }
        if codec == .jxl, try jpegXLHasAnimation(file) {
            throw error("still_animated", "\(name) contains a JPEG XL animation.")
        }
        let count = CGImageSourceGetCount(source)
        guard count <= 1, type != "public.heics" else {
            throw error("still_animated", "\(name) contains multiple independent images or animation.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard count == 1, index < count,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw error("still_decode", "Cannot read primary image dimensions for \(name).")
        }
        try validateDimensions(width, height, maximumPixels: 64_000_000)

        var auxiliaryImages: [String] = []
        if codec == .jpeg || codec == .heic || codec == .heif || codec == .avif {
            var auxiliaryTypes: [(CFString, String)] = [
                (kCGImageAuxiliaryDataTypeHDRGainMap, "appleGainMap"),
                (kCGImageAuxiliaryDataTypeDepth, "depth"),
                (kCGImageAuxiliaryDataTypeDisparity, "disparity"),
                (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "portraitMatte"),
            ]
            if #available(macOS 15, *) {
                auxiliaryTypes.append((kCGImageAuxiliaryDataTypeISOGainMap, "isoGainMap"))
            }
            auxiliaryImages = auxiliaryTypes.compactMap { type, name in
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) == nil ? nil : name
            }
        }
        if !auxiliaryImages.contains("isoGainMap"), try hasISOGainMapSignature(codec, file: file) {
            auxiliaryImages.append("isoGainMap")
        }
        let hasISO = auxiliaryImages.contains("isoGainMap")
        let useNativeHDR: Bool
        if #available(macOS 15, *) {
            useNativeHDR = !hasISO || !forceISOGainMapFallback
        } else {
            useNativeHDR = !hasISO
        }
        var decodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: previewDimension == nil,
        ]
        if useNativeHDR {
            decodeOptions[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        } else {
            decodeOptions[kCGImageSourceShouldAllowFloat] = true
        }

        let native = CGImageSourceCreateImageAtIndex(source, index, decodeOptions as CFDictionary)
        let profile = properties[kCGImagePropertyProfileName] as? String
        let image: CGImage
        var colorSpace: CGColorSpace
        var headroom: Float?
        if useNativeHDR, #available(macOS 15, *), let value = native?.contentHeadroom, value > 0 {
            headroom = value
        }
        let nativeRecoversGainMap = native.map {
            let space = $0.colorSpace ?? sRGB
            return CGColorSpaceIsPQBased(space) || CGColorSpaceIsHLGBased(space)
                || ($0.bitmapInfo.contains(.floatComponents) && CGColorSpaceUsesExtendedRange(space))
                || (headroom ?? 0) > 1
        } ?? false
        if hasISO, !useNativeHDR || !nativeRecoversGainMap {
            decodeOptions.removeValue(forKey: kCGImageSourceDecodeRequest)
            decodeOptions[kCGImageSourceShouldAllowFloat] = true
            guard let base = useNativeHDR
                    ? CGImageSourceCreateImageAtIndex(source, index, decodeOptions as CFDictionary)
                    : native,
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                throw error("still_decode", "Cannot decode the base image in \(name).")
            }
            try validateDimensions(base.width, base.height, maximumPixels: 64_000_000)
            (image, colorSpace, headroom) = try StillISOGainMap.decode(url, codec: codec, base: base)
        } else {
            guard let native, CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                throw error("still_decode", "Cannot decode the complete primary image in \(name).")
            }
            image = native
            colorSpace = native.colorSpace ?? sRGB
        }
        try validateDimensions(image.width, image.height, maximumPixels: 64_000_000)
        // Older Image I/O versions expose JPEG XL's synthesized ICC profile
        // but treat its PQ transfer as SDR. The name records the codestream encoding.
        if !CGColorSpaceIsPQBased(colorSpace), !CGColorSpaceIsHLGBased(colorSpace),
           let signaledSpace = jxlHDRColorSpace(codec, profile: profile) {
            colorSpace = signaledSpace
        }
        let isPQ = CGColorSpaceIsPQBased(colorSpace)
        let isHLG = CGColorSpaceIsHLGBased(colorSpace)
        if codec == .jxl, isPQ || isHLG { headroom = nil }

        let rendition: StillImageInfo.Rendition
        if auxiliaryImages.contains(where: { $0.hasSuffix("GainMap") }) {
            guard CGColorSpaceUsesExtendedRange(colorSpace) || isPQ || isHLG || (headroom ?? 0) > 1 else {
                throw error("still_gain_map", "Image I/O could not reconstruct the HDR gain map in \(name).")
            }
            rendition = .gainMap
        } else if isPQ {
            rendition = .pq
        } else if isHLG {
            rendition = .hlg
        } else if (headroom ?? 0) > 1 {
            rendition = .linearHDR
        } else {
            rendition = .sdr
        }

        let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        let precision = properties[kCGImagePropertyDepth] as? Int ?? image.bitsPerComponent
        let alpha = (properties[kCGImagePropertyHasAlpha] as? Bool)
            ?? [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        let info = StillImageInfo(
            codec: codec, width: width, height: height, orientation: orientation,
            bitsPerComponent: precision, hasAlpha: alpha,
            colorSpace: colorSpace.name as String?, embeddedProfile: profile,
            auxiliaryImages: auxiliaryImages, rendition: rendition, headroom: headroom
        )
        if let previewDimension, rendition == .sdr, precision <= 8, max(width, height) > previewDimension {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: previewDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary),
               thumbnail.colorSpace == colorSpace {
                return (thumbnail, info, colorSpace)
            }
        }
        return (image, info, colorSpace)
    }

    private static func hasISOGainMapSignature(_ codec: StillImageInfo.Codec, file: FileHandle) throws -> Bool {
        switch codec {
        case .jpeg:
            try file.seek(toOffset: 0)
            guard let header = try file.read(upToCount: 2), header.elementsEqual([0xff, 0xd8]) else { return false }
            let identifier = StillISOGainMap.jpegNamespace
            for _ in 0..<65_536 {
                guard let marker = try file.read(upToCount: 2), marker.count == 2, marker[0] == 0xff else { break }
                var code = marker[1]
                while code == 0xff { code = try file.read(upToCount: 1)?.first ?? 0 }
                if code == 0xda || code == 0xd9 || code == 0 { break }
                if code == 1 || (0xd0...0xd7).contains(code) { continue }
                guard let size = try file.read(upToCount: 2), size.count == 2 else { break }
                let length = 256 * Int(size[0]) + Int(size[1]) - 2
                guard length >= 0 else { break }
                let offset = try file.offset()
                if code == 0xe2, length >= identifier.count,
                   try file.read(upToCount: identifier.count) == identifier {
                    return true
                }
                try file.seek(toOffset: offset + UInt64(length))
            }
        case .heic, .heif, .avif:
            try file.seek(toOffset: 0)
            if let brand = try file.read(upToCount: 8), brand.count == 8, brand[4..<8].elementsEqual("ftyp".utf8) {
                let size = brand.prefix(4).reduce(0) { $0 * 256 + Int($1) }
                if (16...65_536).contains(size), let payload = try file.read(upToCount: size - 8), payload.count >= 8 {
                    if payload.prefix(4).elementsEqual("tmap".utf8) { return true }
                    for offset in stride(from: 8, through: payload.count - 4, by: 4) {
                        if payload[offset..<(offset + 4)].elementsEqual("tmap".utf8) { return true }
                    }
                }
            }
        default: break
        }
        return false
    }
}
