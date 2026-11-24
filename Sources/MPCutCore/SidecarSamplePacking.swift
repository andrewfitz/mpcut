import Foundation

/// Peaks and envelopes are Float32 samples held in a binary property list. Neighbouring
/// samples share a sign, an exponent and their leading mantissa bits, while the low
/// mantissa bytes are noise, so the general compressor finds little in the interleaved
/// bytes. Storing all first bytes of a run of samples, then all second bytes, and so on,
/// puts the bytes that repeat side by side. The stored form lists the transposed regions
/// and is otherwise the section byte for byte: reading it needs no knowledge of the
/// property list, and a region chosen badly costs space, never the content.
enum SidecarSamplePacking {
    private static let sampleBytes = 4
    private static let minimumRegion = 1024
    private static let maximumRegions = 16
    // The count, then two integers of at most five bytes for each region.
    static let maximumHeaderBytes = 1 + maximumRegions * 10

    /// The data objects of a binary property list that are long enough to hold samples.
    private static func sampleRegions(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        let trailer = 32
        guard bytes.count >= 8 + trailer, bytes.prefix(8).elementsEqual("bplist00".utf8) else { return [] }
        func integer(at offset: Int, bytes count: Int) -> Int? {
            guard (1...8).contains(count), offset >= 0, offset <= bytes.count - count else { return nil }
            var value: UInt64 = 0
            for index in 0..<count { value = value << 8 | UInt64(bytes[offset + index]) }
            return Int(exactly: value)
        }
        let end = bytes.count - trailer
        let offsetBytes = Int(bytes[end + 6])
        guard let objects = integer(at: end + 8, bytes: 8), let table = integer(at: end + 24, bytes: 8),
              (1...8).contains(offsetBytes), table >= 8, table <= end,
              objects <= (end - table) / offsetBytes else { return [] }
        var regions: [Range<Int>] = []
        for object in 0..<objects {
            guard let marker = integer(at: table + object * offsetBytes, bytes: offsetBytes),
                  marker >= 8, marker < table, bytes[marker] >> 4 == 4 else { continue }
            var start = marker + 1
            var length = Int(bytes[marker] & 15)
            if length == 15 {
                // A longer object states its length as an integer of 1, 2, 4 or 8 bytes.
                guard start < table, bytes[start] >> 4 == 1, bytes[start] & 15 <= 3 else { continue }
                let width = 1 << Int(bytes[start] & 15)
                guard let stated = integer(at: start + 1, bytes: width) else { continue }
                start += 1 + width
                length = stated
            }
            guard start <= table, length <= table - start, length >= minimumRegion else { continue }
            regions.append(start..<start + length / sampleBytes * sampleBytes)
        }
        regions.sort { $0.lowerBound < $1.lowerBound }
        guard regions.count <= maximumRegions,
              zip(regions, regions.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { return [] }
        return regions
    }

    private static func transposed(_ source: UnsafeRawBufferPointer, regions: [Range<Int>], restoring: Bool,
                                   cancelled: () -> Bool) throws -> Data {
        var result = Data(source)
        try result.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            for region in regions {
                let samples = region.count / sampleBytes
                var index = 0
                while index < samples {
                    try checkSidecarCancellation(cancelled)
                    let end = min(samples, index + 65536)
                    for plane in 0..<sampleBytes {
                        let grouped = region.lowerBound + plane * samples
                        let interleaved = region.lowerBound + plane
                        if restoring {
                            for sample in index..<end { target[interleaved + sample * sampleBytes] = source[grouped + sample] }
                        } else {
                            for sample in index..<end { target[grouped + sample] = source[interleaved + sample * sampleBytes] }
                        }
                    }
                    index = end
                }
            }
        }
        return result
    }

    /// The region count, each region's distance from the previous one and its sample count,
    /// then the section with those regions transposed.
    static func pack(_ data: Data, cancelled: () -> Bool) throws -> Data? {
        let packed: Data? = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let regions = sampleRegions(bytes)
            guard !regions.isEmpty else { return nil }
            var header = PackedWriter()
            header.unsigned(UInt64(regions.count))
            var cursor = 0
            for region in regions {
                header.unsigned(UInt64(region.lowerBound - cursor))
                header.unsigned(UInt64(region.count / sampleBytes))
                cursor = region.upperBound
            }
            var result = Data(header.bytes)
            result.append(try transposed(bytes, regions: regions, restoring: false, cancelled: cancelled))
            return result
        }
        guard let packed, try unpack(packed, logicalSize: data.count, cancelled: cancelled) == data else { return nil }
        return packed
    }

    static func unpack(_ data: Data, logicalSize: Int, cancelled: () -> Bool) throws -> Data? {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            do {
                var input = PackedReader(bytes)
                let count = try input.count(minimumBytes: 2)
                guard (1...maximumRegions).contains(count) else { return nil }
                var regions: [Range<Int>] = []
                var cursor = 0
                for _ in 0..<count {
                    let gap = try input.count()
                    let samples = try input.count(minimumBytes: sampleBytes)
                    guard samples > 0, gap <= logicalSize - cursor,
                          samples <= (logicalSize - cursor - gap) / sampleBytes else { return nil }
                    let start = cursor + gap
                    cursor = start + samples * sampleBytes
                    regions.append(start..<cursor)
                }
                guard input.remaining == logicalSize else { return nil }
                return try transposed(try input.slice(logicalSize), regions: regions, restoring: true, cancelled: cancelled)
            } catch is PackedCodingError {
                return nil
            }
        }
    }
}
