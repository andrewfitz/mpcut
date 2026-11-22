import CoreImage
import Foundation
import ImageIO

// ISO 21496-1 metadata and its JPEG MPF / HEIF item bindings. Image I/O
// still decodes both rasters, including their underlying JPEG or HEVC coding.
enum StillISOGainMap {
    private struct Invalid: Error {}
    static let jpegNamespace = Data("urn:iso:std:iso:ts:21496:-1\0".utf8)

    private struct Reader {
        let data: Data
        var offset: Int
        let end: Int

        init(_ data: Data, _ range: Range<Int>? = nil) {
            self.data = data
            self.offset = range?.lowerBound ?? data.startIndex
            self.end = range?.upperBound ?? data.endIndex
        }

        mutating func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, offset >= data.startIndex, end <= data.endIndex, offset <= end, count <= end - offset else {
                throw Invalid()
            }
            let start = offset
            offset += count
            return start..<offset
        }

        mutating func integer(_ count: Int, littleEndian: Bool = false) throws -> Int {
            guard count <= 8 else { throw Invalid() }
            let bytes = data[try take(count)]
            var value: UInt64 = 0
            if littleEndian {
                for byte in bytes.reversed() { value = value << 8 | UInt64(byte) }
            } else {
                for byte in bytes { value = value << 8 | UInt64(byte) }
            }
            guard let result = Int(exactly: value) else { throw Invalid() }
            return result
        }

        mutating func tag() throws -> String {
            String(decoding: data[try take(4)], as: UTF8.self)
        }
    }

    private struct Metadata {
        let headroom: Float
        let alternateHeadroom: Float
        let usesBaseColorSpace: Bool
        let minimum: CIVector
        let maximum: CIVector
        let inverseGamma: CIVector
        let baseOffset: CIVector
        let alternateOffset: CIVector

        init(_ data: Data) throws {
            var reader = Reader(data)
            guard try reader.integer(2) == 0 else { throw Invalid() }
            _ = try reader.take(2)
            let flags = try reader.integer(1)
            usesBaseColorSpace = flags & 0x40 != 0
            let denominator = flags & 8 != 0 ? try reader.integer(4) : nil

            func fraction(signed: Bool = false) throws -> CGFloat {
                let raw = try reader.integer(4)
                let numerator = signed ? Int(Int32(bitPattern: UInt32(raw))) : raw
                let divisor = try denominator ?? reader.integer(4)
                guard divisor > 0 else { throw Invalid() }
                return CGFloat(numerator) / CGFloat(divisor)
            }

            let base = try fraction()
            let alternate = try fraction()
            guard base <= 15, alternate <= 15 else { throw Invalid() }
            headroom = exp2(Float(base))
            alternateHeadroom = exp2(Float(alternate))
            var parameters = [[CGFloat]]()
            for _ in 0..<(flags & 0x80 == 0 ? 1 : 3) {
                let low = try fraction(signed: true)
                let high = try fraction(signed: true)
                let gamma = try fraction()
                let baseOffset = try fraction(signed: true)
                let alternateOffset = try fraction(signed: true)
                guard low >= -32, high <= 32, low <= high, gamma > 0 else { throw Invalid() }
                parameters.append([low, high, 1 / gamma, baseOffset, alternateOffset])
            }

            func vector(_ key: Int) -> CIVector {
                let r = parameters[0][key]
                return CIVector(x: r, y: parameters.count == 1 ? r : parameters[1][key],
                                z: parameters.count == 1 ? r : parameters[2][key])
            }
            minimum = vector(0)
            maximum = vector(1)
            inverseGamma = vector(2)
            baseOffset = vector(3)
            alternateOffset = vector(4)
        }
    }

    private static let kernel = CIColorKernel(source: """
        kernel vec4 reconstruct(__sample base, __sample gain, vec3 low, vec3 high,
                                vec3 inverseGamma, vec3 baseOffset, vec3 alternateOffset) {
            vec3 encoded = clamp(gain.rgb, 0.0, 1.0);
            vec3 boost = exp2(mix(low, high, pow(encoded, inverseGamma)));
            vec3 linear = (unpremultiply(base).rgb + baseOffset) * boost - alternateOffset;
            return vec4(linear * base.a, base.a);
        }
        """)

    static func decode(
        _ url: URL, codec: StillImageInfo.Codec, base: CGImage
    ) throws -> (CGImage, CGColorSpace, Float) {
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard data.count <= 256 * 1_024 * 1_024 else { throw Invalid() }
            let (metadataBytes, gainData, alternateSpace): (Data, Data, CGColorSpace?)
            switch codec {
            case .jpeg:
                (metadataBytes, gainData) = try jpeg(data)
                alternateSpace = nil
            case .heic, .heif, .avif:
                (metadataBytes, gainData, alternateSpace) = try heif(data)
            default:
                throw Invalid()
            }
            let metadata = try Metadata(metadataBytes)

            // For an HDR base, the requested HDR rendition already exists.
            if metadata.headroom >= metadata.alternateHeadroom, metadata.headroom > 1,
               let baseSpace = base.colorSpace,
               CGColorSpaceIsPQBased(baseSpace) || CGColorSpaceIsHLGBased(baseSpace)
                    || CGColorSpaceUsesExtendedRange(baseSpace) {
                return (base, baseSpace, metadata.headroom)
            }
            try Task.checkCancellation()
            guard metadata.headroom < metadata.alternateHeadroom,
                  let source = CGImageSourceCreateWithData(gainData as CFData, nil) else { throw Invalid() }
            let index = CGImageSourceGetPrimaryImageIndex(source)
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Invalid() }
            try StillImage.validateDimensions(width, height, maximumPixels: 64_000_000)
            let options = [kCGImageSourceShouldAllowFloat: true] as CFDictionary
            guard let gain = CGImageSourceCreateImageAtIndex(source, index, options),
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else { throw Invalid() }
            try StillImage.validateDimensions(gain.width, gain.height, maximumPixels: 64_000_000)
            let space: CGColorSpace
            if metadata.usesBaseColorSpace {
                space = try linearSpace(base.colorSpace ?? StillImage.sRGB)
            } else {
                guard let alternate = alternateSpace ?? (codec == .jpeg ? gain.colorSpace : nil) else { throw Invalid() }
                space = try linearSpace(alternate)
            }

            let baseImage = CIImage(cgImage: base, options: [.colorSpace: base.colorSpace ?? StillImage.sRGB])
            let scale = CGAffineTransform(scaleX: CGFloat(base.width) / CGFloat(gain.width),
                                          y: CGFloat(base.height) / CGFloat(gain.height))
            let gainImage = CIImage(cgImage: gain, options: [.colorSpace: NSNull()])
                .clampedToExtent().transformed(by: scale)
            let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
            guard let reconstructed = kernel?.apply(extent: baseImage.extent, arguments: [
                baseImage, gainImage, metadata.minimum, metadata.maximum, metadata.inverseGamma,
                metadata.baseOffset, metadata.alternateOffset,
            ]), let output = context.createCGImage(reconstructed, from: baseImage.extent, format: .RGBAh, colorSpace: space) else {
                throw Invalid()
            }
            return (output, space, metadata.alternateHeadroom)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StillImage.error("still_gain_map", "Cannot reconstruct the ISO HDR gain map in \(url.lastPathComponent).")
        }
    }

    private static func linearSpace(_ space: CGColorSpace) throws -> CGColorSpace {
        if space.model == .monochrome { return StillImage.linear709 }
        guard let linear = CGColorSpaceCreateExtendedLinearized(space) else { throw Invalid() }
        return linear
    }
}

extension StillISOGainMap {
    private static func jpegSegments(_ data: Data) throws -> [(Int, Range<Int>)] {
        var reader = Reader(data)
        guard try reader.integer(2) == 0xffd8 else { throw Invalid() }
        var segments: [(Int, Range<Int>)] = []
        while reader.offset < reader.end {
            guard try reader.integer(1) == 0xff else { throw Invalid() }
            var marker = try reader.integer(1)
            while marker == 0xff { marker = try reader.integer(1) }
            if marker == 0xda || marker == 0xd9 { break }
            if marker == 1 || (0xd0...0xd7).contains(marker) { continue }
            let length = try reader.integer(2)
            segments.append((marker, try reader.take(length - 2)))
            guard segments.count <= 65_536 else { throw Invalid() }
        }
        return segments
    }

    private static func jpeg(_ data: Data) throws -> (Data, Data) {
        let app2 = try jpegSegments(data).filter { $0.0 == 0xe2 }
        guard app2.contains(where: { data[$0.1].starts(with: jpegNamespace) }) else { throw Invalid() }
        guard let mpf = app2.first(where: { data[$0.1].starts(with: [0x4d, 0x50, 0x46, 0]) })?.1 else {
            throw Invalid()
        }
        let tiff = mpf.lowerBound + 4
        var index = Reader(data, tiff..<mpf.upperBound)
        let order = try index.integer(2)
        guard order == 0x4949 || order == 0x4d4d else { throw Invalid() }
        let little = order == 0x4949
        guard try index.integer(2, littleEndian: little) == 42 else { throw Invalid() }
        let offset = try index.integer(4, littleEndian: little)
        index.offset = tiff + offset
        let count = try index.integer(2, littleEndian: little)
        var entriesOffset: Int?
        var entriesLength: Int?
        for _ in 0..<count {
            let tag = try index.integer(2, littleEndian: little)
            let type = try index.integer(2, littleEndian: little)
            let count = try index.integer(4, littleEndian: little)
            let value = try index.integer(4, littleEndian: little)
            if tag == 0xb002, type == 7 {
                entriesLength = count
                entriesOffset = value
            }
        }
        guard let entriesOffset, let entriesLength, entriesLength.isMultiple(of: 16) else { throw Invalid() }
        index.offset = tiff + entriesOffset
        let entries = try index.take(entriesLength)
        index = Reader(data, entries)
        while index.offset < index.end {
            _ = try index.take(4)
            let length = try index.integer(4, littleEndian: little)
            let offset = try index.integer(4, littleEndian: little)
            _ = try index.take(4)
            guard offset > 0, length > 0, tiff + offset <= data.count,
                  length <= data.count - tiff - offset else { continue }
            let gain = data.subdata(in: (tiff + offset)..<(tiff + offset + length))
            for (marker, range) in try jpegSegments(gain) where marker == 0xe2 {
                if gain[range].starts(with: jpegNamespace) {
                    return (gain.subdata(in: (range.lowerBound + jpegNamespace.count)..<range.upperBound), gain)
                }
            }
        }
        throw Invalid()
    }

    private struct Box {
        let tag: String
        let payload: Range<Int>

        func children(_ data: Data, skipping: Int = 0) throws -> [Box] {
            guard skipping <= payload.count else { throw Invalid() }
            return try boxes(data, (payload.lowerBound + skipping)..<payload.upperBound)
        }
    }

    private static func boxes(_ data: Data, _ range: Range<Int>) throws -> [Box] {
        var reader = Reader(data, range)
        var result: [Box] = []
        while reader.offset < reader.end {
            let start = reader.offset
            var size = try reader.integer(4)
            let tag = try reader.tag()
            if size == 1 { size = try reader.integer(8) }
            if size == 0 { size = reader.end - start }
            let payload = try reader.take(size - (reader.offset - start))
            result.append(Box(tag: tag, payload: payload))
            guard result.count <= 65_536 else { throw Invalid() }
        }
        return result
    }

    private static func heif(_ data: Data) throws -> (Data, Data, CGColorSpace?) {
        let top = try boxes(data, 0..<data.count)
        guard let meta = top.first(where: { $0.tag == "meta" }) else { throw Invalid() }
        let children = try meta.children(data, skipping: 4)
        guard let primary = children.first(where: { $0.tag == "pitm" }),
              let info = children.first(where: { $0.tag == "iinf" }),
              let references = children.first(where: { $0.tag == "iref" }),
              let locations = children.first(where: { $0.tag == "iloc" }),
              !info.payload.isEmpty, !references.payload.isEmpty else { throw Invalid() }

        var primaryReader = Reader(data, primary.payload)
        let primaryVersion = try primaryReader.integer(1)
        guard primaryVersion <= 1 else { throw Invalid() }
        _ = try primaryReader.take(3)
        let primaryIDRange = try primaryReader.take(primaryVersion == 0 ? 2 : 4)
        var primaryIDReader = Reader(data, primaryIDRange)
        let primaryID = try primaryIDReader.integer(primaryIDRange.count)
        let infoVersion = data[info.payload.lowerBound]
        var items: [Int: (tag: String, flagOffset: Int)] = [:]
        for entry in try info.children(data, skipping: infoVersion == 0 ? 6 : 8) where entry.tag == "infe" {
            var reader = Reader(data, entry.payload)
            let version = try reader.integer(1)
            guard version == 2 || version == 3 else { continue }
            let flags = try reader.take(3)
            let id = try reader.integer(version == 2 ? 2 : 4)
            _ = try reader.take(2)
            items[id] = (try reader.tag(), flags.upperBound - 1)
        }
        let relationshipIDSize = data[references.payload.lowerBound] == 0 ? 2 : 4
        for reference in try references.children(data, skipping: 4) where reference.tag == "dimg" {
            var reader = Reader(data, reference.payload)
            let toneID = try reader.integer(relationshipIDSize)
            guard items[toneID]?.tag == "tmap", try reader.integer(2) == 2,
                  try reader.integer(relationshipIDSize) == primaryID else { continue }
            let gainID = try reader.integer(relationshipIDSize)
            guard let gain = items[gainID], gainID < (1 << (primaryIDRange.count * 8)) else { throw Invalid() }
            var metadata = try itemData(data, locations: locations, idat: children.first { $0.tag == "idat" }, id: toneID)
            guard metadata.first == 0 else { throw Invalid() }
            metadata.removeFirst()
            // Expose the gain raster as a primary item in a scratch copy of
            // the HEIF container with all original item offsets intact.
            var gainData = data
            for (byte, position) in primaryIDRange.reversed().enumerated() {
                gainData[position] = UInt8(truncatingIfNeeded: gainID >> (byte * 8))
            }
            gainData[gain.flagOffset] &= 0xfe
            let alternate = try colorSpace(data, properties: children.first { $0.tag == "iprp" }, id: toneID)
            return (metadata, gainData, alternate)
        }
        throw Invalid()
    }

    private static func itemData(_ data: Data, locations: Box, idat: Box?, id: Int) throws -> Data {
        var reader = Reader(data, locations.payload)
        let version = try reader.integer(1)
        guard version <= 2 else { throw Invalid() }
        _ = try reader.take(3)
        let sizes = try reader.integer(2)
        let offsetSize = sizes >> 12
        let lengthSize = sizes >> 8 & 15
        let baseSize = sizes >> 4 & 15
        let indexSize = version == 0 ? 0 : sizes & 15
        let itemIDSize = version < 2 ? 2 : 4
        let itemCount = try reader.integer(itemIDSize)
        guard itemCount <= 65_536 else { throw Invalid() }
        for _ in 0..<itemCount {
            let itemID = try reader.integer(itemIDSize)
            let method = version == 0 ? 0 : try reader.integer(2) & 15
            let dataReference = try reader.integer(2)
            let base = try reader.integer(baseSize)
            let extentCount = try reader.integer(2)
            var result = Data()
            for _ in 0..<extentCount {
                _ = try reader.take(indexSize)
                let offset = try reader.integer(offsetSize)
                let length = try reader.integer(lengthSize)
                guard itemID == id else { continue }
                let storage: Range<Int>
                if method == 1, let idat {
                    storage = idat.payload
                } else if method == 0 {
                    storage = 0..<data.count
                } else {
                    throw Invalid()
                }
                guard dataReference == 0, base <= storage.count, offset <= storage.count - base,
                      length <= storage.count - base - offset, length <= 65_536 - result.count else { throw Invalid() }
                let start = storage.lowerBound + base + offset
                result.append(data[start..<(start + length)])
            }
            if itemID == id, !result.isEmpty { return result }
        }
        throw Invalid()
    }

    private static func colorSpace(_ data: Data, properties: Box?, id: Int) throws -> CGColorSpace? {
        guard let properties else { return nil }
        let children = try properties.children(data)
        guard let container = children.first(where: { $0.tag == "ipco" }) else { return nil }
        let entries = try container.children(data)
        for associations in children where associations.tag == "ipma" {
            var reader = Reader(data, associations.payload)
            let version = try reader.integer(1)
            let flags = try reader.integer(3)
            let wide = flags & 1 != 0
            let count = try reader.integer(4)
            guard count <= 65_536 else { throw Invalid() }
            for _ in 0..<count {
                let itemID = try reader.integer(version == 0 ? 2 : 4)
                let associationsCount = try reader.integer(1)
                for _ in 0..<associationsCount {
                    let index = try reader.integer(wide ? 2 : 1) & (wide ? 0x7fff : 0x7f)
                    guard itemID == id, index > 0, index <= entries.count, entries[index - 1].tag == "colr" else { continue }
                    var color = Reader(data, entries[index - 1].payload)
                    switch try color.tag() {
                    case "prof", "rICC":
                        if let space = CGColorSpace(iccData: data.subdata(in: color.offset..<color.end) as CFData) { return space }
                    case "nclx":
                        switch try color.integer(2) {
                        case 1: return StillImage.linear709
                        case 9: return StillImage.linear2020
                        case 12: return StillImage.linearP3
                        default: continue
                        }
                    default: continue
                    }
                }
            }
        }
        return nil
    }
}
