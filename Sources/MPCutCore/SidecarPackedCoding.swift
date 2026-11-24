import Foundation

enum PackedCodingError: Error { case invalid }

/// The LEB128 and zigzag integers of the index rows, for packers that must predict a
/// row's exact bytes or copy one of its fields.
struct PackedWriter {
    var bytes: [UInt8] = []

    mutating func unsigned(_ value: UInt64) {
        var n = value
        while n >= 128 {
            bytes.append(UInt8(truncatingIfNeeded: n) | 0x80)
            n >>= 7
        }
        bytes.append(UInt8(n))
    }

    mutating func signed(_ value: Int64) {
        unsigned(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func time(_ value: RationalTime) {
        signed(value.numerator)
        unsigned(UInt64(value.denominator))
    }
}

/// Reads stored bytes, which may be damaged. Every failure is thrown.
struct PackedReader {
    let bytes: UnsafeRawBufferPointer
    var position = 0
    var remaining: Int { bytes.count - position }

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw PackedCodingError.invalid }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func unsigned() throws -> UInt64 {
        var n: UInt64 = 0
        var shift = 0
        while shift <= 63 {
            let next = try byte()
            guard shift != 63 || next <= 1 else { throw PackedCodingError.invalid }
            n |= UInt64(next & 0x7f) << shift
            if next < 128 { return n }
            shift += 7
        }
        throw PackedCodingError.invalid
    }

    mutating func signed() throws -> Int64 {
        let n = try unsigned()
        return Int64(bitPattern: n >> 1) ^ -Int64(n & 1)
    }

    /// A length or count that the remaining bytes could hold at `minimumBytes` each.
    mutating func count(minimumBytes: Int = 1) throws -> Int {
        guard let value = Int(exactly: try unsigned()), value <= remaining / minimumBytes else {
            throw PackedCodingError.invalid
        }
        return value
    }

    mutating func time() throws -> RationalTime {
        let top = try signed()
        guard let bottom = Int64(exactly: try unsigned()), bottom > 0 else { throw PackedCodingError.invalid }
        return RationalTime(numerator: top, denominator: bottom)
    }

    mutating func slice(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= remaining else { throw PackedCodingError.invalid }
        defer { position += count }
        return UnsafeRawBufferPointer(rebasing: bytes[position..<position + count])
    }
}
