import Foundation

/// MPCut's 16 kHz activity document has a regular 320-sample clock. Store its final
/// sample and the exact decimal spelling of each level. Two symbols fit in a byte.
/// The suffix (including provider evidence) is opaque. Other JSON layouts fall back
/// to ordinary lossless compression, including irregular or future window formats.
enum SidecarActivityPacking {
    private static let prefix = Array(#"{"activity":["#.utf8)
    private static let frame = Array(#"{"end_sample":"#.utf8)
    private static let level = Array(#","level":"#.utf8)
    private static let start = Array(#","start_sample":"#.utf8)
    private static let alphabet = Array("0123456789.-+eE".utf8)
    private static let symbol: [UInt8] = {
        var table = [UInt8](repeating: 255, count: 256)
        for (index, byte) in alphabet.enumerated() { table[Int(byte)] = UInt8(index) }
        return table
    }()

    static func pack(_ data: Data, cancelled: () -> Bool) throws -> Data? {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var position = 0
            func consume(_ token: [UInt8]) -> Bool {
                guard bytes.count - position >= token.count,
                      bytes[position..<position + token.count].elementsEqual(token) else { return false }
                position += token.count
                return true
            }
            func sample() -> Int64? {
                let first = position
                var value: Int64 = 0
                while position < bytes.count, (48...57).contains(bytes[position]) {
                    let digit = Int64(bytes[position] - 48)
                    guard value <= (Int64.max - digit) / 10 else { return nil }
                    value = value * 10 + digit
                    position += 1
                }
                guard position > first, position == first + 1 || bytes[first] != 48 else { return nil }
                return value
            }

            guard consume(prefix) else { return nil }
            var packed = [UInt8](repeating: 0, count: 8)
            packed.reserveCapacity(max(8, data.count / 12))
            var previous: Int64 = 0
            var count = 0
            repeat {
                if count.isMultiple(of: 1024) { try checkSidecarCancellation(cancelled) }
                guard consume(frame), let end = sample(), end > previous, end - previous <= 320,
                      consume(level) else { return nil }
                let first = position
                var high: UInt8?
                while position < bytes.count {
                    if position.isMultiple(of: 65536) { try checkSidecarCancellation(cancelled) }
                    let code = symbol[Int(bytes[position])]
                    if code == 255 { break }
                    if let top = high {
                        packed.append(top << 4 | code)
                        high = nil
                    } else { high = code }
                    position += 1
                }
                guard position > first, consume(start), sample() == previous,
                      position < bytes.count, bytes[position] == 125 else { return nil }
                packed.append((high ?? 15) << 4 | 15)
                position += 1
                previous = end
                count += 1
                guard position < bytes.count else { return nil }
                if bytes[position] == 93 { break }
                guard bytes[position] == 44, end.isMultiple(of: 320) else { return nil }
                position += 1
            } while true
            var duration = previous.littleEndian
            withUnsafeBytes(of: &duration) { packed.replaceSubrange(0..<8, with: $0) }
            packed.append(contentsOf: bytes[position...])
            return Data(packed)
        }
    }

    static func unpack(_ data: Data, logicalSize: Int, cancelled: () -> Bool) throws -> Data? {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count > 8 else { return nil }
            let duration = Int64(littleEndian: bytes.loadUnaligned(as: Int64.self))
            guard duration > 0, (duration - 1) / 320 < Int64(bytes.count - 8) else { return nil }
            var result = prefix
            result.reserveCapacity(min(logicalSize, 8 << 20))
            var position = 8
            var cursor: Int64 = 0
            var startText = "0"
            while cursor < duration {
                if (cursor / 320).isMultiple(of: 1024) { try checkSidecarCancellation(cancelled) }
                let end = cursor + min(320, duration - cursor)
                if cursor > 0 { result.append(44) }
                result.append(contentsOf: frame)
                let endText = String(end)
                result.append(contentsOf: endText.utf8)
                result.append(contentsOf: level)
                while true {
                    guard position < bytes.count, result.count < logicalSize else { return nil }
                    if position.isMultiple(of: 65536) { try checkSidecarCancellation(cancelled) }
                    let byte = bytes[position]
                    position += 1
                    if byte >> 4 < 15 { result.append(alphabet[Int(byte >> 4)]) }
                    if byte & 15 == 15 { break }
                    guard byte >> 4 < 15 else { return nil }
                    result.append(alphabet[Int(byte & 15)])
                }
                result.append(contentsOf: start)
                result.append(contentsOf: startText.utf8)
                startText = endText
                result.append(125)
                cursor = end
            }
            guard bytes.count - position == logicalSize - result.count,
                  position < bytes.count, bytes[position] == 93 else { return nil }
            result.append(contentsOf: bytes[position...])
            return Data(result)
        }
    }
}
