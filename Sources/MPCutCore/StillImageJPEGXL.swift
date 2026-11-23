import Foundation

extension StillImage {
    // Image I/O returns one image for animated JPEG XL, so check the
    // codestream's animation flag before accepting it as a still.
    static func jpegXLHasAnimation(_ file: FileHandle) throws -> Bool {
        let fileSize = try file.seekToEnd()
        try file.seek(toOffset: 0)
        let signature = try file.read(upToCount: 12) ?? Data()
        var prefix = Data()
        if signature.starts(with: [0xff, 0x0a]) {
            prefix = signature
            prefix.append(try file.read(upToCount: 64 - signature.count) ?? Data())
        } else if signature.elementsEqual([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 0x0d, 0x0a, 0x87, 0x0a]) {
            var nextPart: UInt32 = 0
            for _ in 0..<4_096 {
                try Task.checkCancellation()
                guard let box = try file.read(upToCount: 8), box.count == 8 else { break }
                let type = box[4..<8]
                var size = bigEndianInteger(box.prefix(4))
                var headerSize: UInt64 = 8
                if size == 1 {
                    guard let extendedSize = try file.read(upToCount: 8), extendedSize.count == 8 else { break }
                    size = bigEndianInteger(extendedSize)
                    headerSize = 16
                }
                guard size == 0 || size >= headerSize else { break }
                let offset = try file.offset()
                guard offset <= fileSize else { break }
                let payloadLength = size == 0 ? fileSize - offset : size - headerSize
                guard payloadLength <= fileSize - offset else { break }
                let remaining = UInt64(64 - prefix.count)
                if type.elementsEqual("jxlc".utf8) {
                    guard nextPart == 0 else { break }
                    prefix.append(try file.read(upToCount: Int(min(remaining, payloadLength))) ?? Data())
                    break
                }
                if type.elementsEqual("jxlp".utf8), payloadLength >= 4,
                   let part = try file.read(upToCount: 4), part.count == 4 {
                    let index = UInt32(bigEndianInteger(part))
                    guard index & 0x7fff_ffff == nextPart else { break }
                    prefix.append(try file.read(upToCount: Int(min(remaining, payloadLength - 4))) ?? Data())
                    if prefix.count >= 64 || index & 0x8000_0000 != 0 { break }
                    nextPart += 1
                }
                guard size != 0 else { break }
                try file.seek(toOffset: offset + payloadLength)
            }
        }
        guard prefix.starts(with: [0xff, 0x0a]) else {
            throw error("still_decode", "Cannot read the primary JPEG XL codestream.")
        }
        var header = JPEGXLHeader(bytes: Array(prefix.dropFirst(2)))
        guard let animated = header.hasAnimation else {
            throw error("still_decode", "Cannot read the primary JPEG XL codestream header.")
        }
        return animated
    }

    private static func bigEndianInteger(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private struct JPEGXLHeader {
    let bytes: [UInt8]
    private var bitOffset = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var hasAnimation: Bool? {
        mutating get {
            guard skipSize(), let defaults = read(1) else { return nil }
            if defaults == 1 { return false }
            guard let extra = read(1) else { return nil }
            if extra == 0 { return false }
            guard read(3) != nil, let intrinsic = read(1) else { return nil }
            if intrinsic == 1, !skipSize() { return nil }
            guard let preview = read(1) else { return nil }
            if preview == 1, !skipPreviewSize() { return nil }
            return read(1).map { $0 == 1 }
        }
    }

    private mutating func skipSize() -> Bool {
        guard let small = read(1), skipDimension(small: small == 1),
              let ratio = read(3) else { return false }
        return ratio != 0 || skipDimension(small: small == 1)
    }

    private mutating func skipDimension(small: Bool) -> Bool {
        if small { return read(5) != nil }
        return skipVariable([9, 13, 18, 30])
    }

    private mutating func skipPreviewSize() -> Bool {
        guard let divisibleByEight = read(1) else { return false }
        let lengths = divisibleByEight == 1 ? [0, 0, 5, 9] : [6, 8, 10, 12]
        guard skipVariable(lengths), let ratio = read(3) else { return false }
        return ratio != 0 || skipVariable(lengths)
    }

    private mutating func skipVariable(_ lengths: [Int]) -> Bool {
        guard let size = read(2) else { return false }
        return read(lengths[size]) != nil
    }

    private mutating func read(_ count: Int) -> Int? {
        guard bitOffset + count <= bytes.count * 8 else { return nil }
        var result = 0
        for bit in 0..<count {
            result |= Int((bytes[bitOffset / 8] >> (bitOffset % 8)) & 1) << bit
            bitOffset += 1
        }
        return result
    }
}
