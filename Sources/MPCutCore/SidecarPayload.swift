import Compression
import Foundation

/// A zero logical size denotes verbatim SQLite storage. Otherwise the first byte
/// selects plain LZFSE (1), packed activity (2/3), packed packet runs (4/5), packed
/// provider activity in durable job artifacts (6/7), packed frame rows (8/9), or transposed
/// samples (11). Odd tags apply LZFSE after packing. Transposing alone saves nothing,
/// so its even tag (10) is reserved and never stored.
struct SidecarPayload {
    let bytes: Data
    let logicalSize: Int
    static let minimumSize = 4096

    static func encode(_ value: Data, key: String = "", providerActivity: Bool = false, cancelled: () -> Bool) throws -> Self {
        guard value.count <= Int(Int32.max) else { throw sidecarError("Section exceeds the maximum logical size.") }
        let raw = Self(bytes: value, logicalSize: 0)
        guard value.count >= minimumSize else { return raw }
        let packed: Data?
        let tag: UInt8
        // Frame rows that all break the pattern, or samples without shared high bytes,
        // can pack to more than plain compression gives. Those must beat it to be kept.
        var contested = false
        if key.hasPrefix("transcript_activity.v1.") {
            let local = try SidecarActivityPacking.pack(value, cancelled: cancelled)
            if local == nil, providerActivity {
                packed = try SidecarActivityPacking.packProviderLayout(value, cancelled: cancelled)
                tag = 6
            } else {
                packed = local
                tag = 2
            }
        } else if key == "media_index_audio.v1" {
            packed = try SidecarPacketPacking.pack(value, cancelled: cancelled)
            tag = 4
        } else if key == "media_index_frames.v1" {
            packed = try SidecarFramePacking.pack(value, cancelled: cancelled)
            tag = 8
            contested = true
        } else if key.hasPrefix("waveform_peaks.v1.") || key.hasPrefix("waveform_envelope.v1.") {
            packed = try SidecarSamplePacking.pack(value, cancelled: cancelled)
            tag = 10
            contested = true
        } else {
            packed = nil
            tag = 0
        }
        let input = packed ?? value
        // Avoid spending space on framing for incompressible data such as JPEGs.
        // Transposed samples are slightly longer than the section they must undercut.
        let size = min(input.count, value.count)
        var limit = size - size / 50
        var plain: Data?
        if packed != nil, contested {
            plain = try compress(value, limit: limit, tag: 1, cancelled: cancelled)
            if let plain { limit = plain.count - 1 }
        }
        if let compressed = try compress(input, limit: limit, tag: packed == nil ? 1 : tag + 1, cancelled: cancelled) {
            return Self(bytes: compressed, logicalSize: value.count)
        }
        if let plain { return Self(bytes: plain, logicalSize: value.count) }
        if let packed, packed.count + 1 < value.count {
            return Self(bytes: Data([tag]) + packed, logicalSize: value.count)
        }
        return raw
    }

    func decode(cancelled: () -> Bool) throws -> Data? {
        guard logicalSize != 0 else { return bytes }
        do {
            return try decodeStoredBytes(cancelled: cancelled)
        } catch let error as CutError where error.code == "cancelled" {
            throw error
        } catch {
            // A damaged cache entry is a miss, including for a repairing update.
            return nil
        }
    }

    private func decodeStoredBytes(cancelled: () -> Bool) throws -> Data? {
        guard logicalSize > bytes.count, logicalSize <= Int(Int32.max), let tag = bytes.first else { return nil }
        switch tag {
        case 1:
            let result = try Self.decompress(bytes.dropFirst(), limit: logicalSize, cancelled: cancelled)
            return result?.count == logicalSize ? result : nil
        case 2...9, 11:
            let packed: Data
            if tag.isMultiple(of: 2) {
                packed = bytes.dropFirst()
            } else {
                // Only transposed samples expand to more than the section: its bytes and a region list.
                let limit = tag == 11 ? logicalSize + SidecarSamplePacking.maximumHeaderBytes : logicalSize
                guard let value = try Self.decompress(bytes.dropFirst(), limit: limit, cancelled: cancelled) else { return nil }
                packed = value
            }
            if tag < 4 {
                return try SidecarActivityPacking.unpack(packed, logicalSize: logicalSize, cancelled: cancelled)
            }
            if tag < 6 {
                return try SidecarPacketPacking.unpack(packed, logicalSize: logicalSize, cancelled: cancelled)
            }
            if tag < 8 {
                return try SidecarActivityPacking.unpackProviderLayout(packed, logicalSize: logicalSize, cancelled: cancelled)
            }
            if tag < 10 {
                return try SidecarFramePacking.unpack(packed, logicalSize: logicalSize, cancelled: cancelled)
            }
            return try SidecarSamplePacking.unpack(packed, logicalSize: logicalSize, cancelled: cancelled)
        default:
            return nil
        }
    }

    private static func decompress(_ input: Data, limit: Int, cancelled: () -> Bool) throws -> Data? {
        try input.withUnsafeBytes { source in
            guard source.count > 1, let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let capacity = min(limit + 1, 64 * 1024)
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { scratch.deallocate() }
            var stream = compression_stream(dst_ptr: scratch, dst_size: 0, src_ptr: base, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
                return nil
            }
            defer { compression_stream_destroy(&stream) }
            // The framework can consume bytes beyond the end marker into its own
            // buffer. Withhold the last byte to detect a stream that ends early.
            stream.src_ptr = base
            stream.src_size = source.count - 1
            var final = false
            var output = Data()
            while true {
                try checkSidecarCancellation(cancelled)
                stream.dst_ptr = scratch
                stream.dst_size = capacity
                let before = stream.src_size
                let status = compression_stream_process(&stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                let produced = capacity - stream.dst_size
                guard status != COMPRESSION_STATUS_ERROR, produced <= limit - output.count else { return nil }
                output.append(scratch, count: produced)
                if status == COMPRESSION_STATUS_END { return final ? output : nil }
                if !final && stream.src_size == 0 && stream.dst_size > 0 {
                    stream.src_ptr = base + source.count - 1
                    stream.src_size = 1
                    final = true
                } else if produced == 0 && stream.src_size == before {
                    return nil
                }
            }
        }
    }

    private enum FilterError: Error { case exceedsLimit }

    private static func compress(_ input: Data, limit: Int, tag: UInt8,
                                 cancelled: () -> Bool) throws -> Data? {
        try withoutActuallyEscaping(cancelled) { check in
            var output = Data([tag])
            do {
                let stream = try OutputFilter(.compress, using: .lzfse, bufferCapacity: 64 * 1024) { chunk in
                    try checkSidecarCancellation(check)
                    guard let chunk else { return }
                    guard chunk.count <= limit - output.count else { throw FilterError.exceedsLimit }
                    output.append(chunk)
                }
                var offset = input.startIndex
                while offset < input.endIndex {
                    try checkSidecarCancellation(check)
                    let end = min(offset + 64 * 1024, input.endIndex)
                    try stream.write(input[offset..<end])
                    offset = end
                }
                try stream.finalize()
                return output
            } catch is FilterError {
                return nil
            }
        }
    }
}
