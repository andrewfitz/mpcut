import Compression
import CryptoKit
import Foundation

/// Version 2 of the recognition file that MPCut and a standalone Transcriberrr exchange.
/// Version 1 is JSON holding base64 of each JSON document. This is the same two documents,
/// byte for byte, behind the same digest:
///
///     0   4  "MPCX"
///     4   1  version, 2
///     5   1  flags: bit 0 is set when levels follow the result, and the others are zero
///     6   2  zero
///     8  32  SHA-256 over the result, a zero byte and the levels
///    40      the result, then the levels when flagged, each as
///            1  method   4  length of the document   4  stored length   the stored bytes
///
/// Both lengths are little-endian. Method 0 stores the document, 1 is its raw DEFLATE
/// stream, and 2 and 3 are the raw DEFLATE stream of the levels packing that the analysis
/// sidecar uses for MPCut's layout and for Transcriberrr's. Nothing follows the last
/// document. A reader that finds anything else treats the file as absent.
enum TranscriptRecognitionExchange {
    /// The highest version this build reads. It reads every earlier one.
    static let version = 2
    static let fileExtension = "mpx"
    static let legacyExtension = "json"
    /// A file of this name in the shared folder holds the highest version that the MPCut
    /// preparing sessions there reads. The provider's session manifest rejects unknown
    /// fields, so a field there would stop every earlier provider.
    static let readerName = "exchange-version"

    private static let magic = Array("MPCX".utf8)
    private static let header = 40
    private static let maximumSize = Int(Int32.max)

    private enum Method: UInt8 {
        case stored, deflated, packed, packedProviderLayout
    }

    static func digest(result: Data, activity: Data?) -> [UInt8] {
        var hash = SHA256()
        hash.update(data: result)
        hash.update(data: Data([0]))
        if let activity { hash.update(data: activity) }
        return Array(hash.finalize())
    }

    static func encode(result: Data, activity: Data?, cancelled: () -> Bool) throws -> Data? {
        var file = Data(magic)
        file.append(contentsOf: [UInt8(version), activity == nil ? 0 : 1, 0, 0])
        file.append(contentsOf: digest(result: result, activity: activity))
        for document in [result, activity].compactMap({ $0 }) {
            try checkSidecarCancellation(cancelled)
            guard document.count <= maximumSize else { return nil }
            let (method, stored) = try payload(document, cancelled: cancelled)
            file.append(method.rawValue)
            for length in [document.count, stored.count] {
                withUnsafeBytes(of: UInt32(length).littleEndian) { file.append(contentsOf: $0) }
            }
            file.append(stored)
        }
        return file
    }

    static func decode(_ file: Data, cancelled: () -> Bool) throws -> (result: Data, activity: Data?)? {
        let file = file.startIndex == 0 ? file : Data(file)
        guard file.count >= header, file.prefix(4).elementsEqual(magic), file[4] == UInt8(version),
              file[5] <= 1, file[6] == 0, file[7] == 0 else { return nil }
        var position = header
        func document() throws -> Data? {
            try checkSidecarCancellation(cancelled)
            guard file.count - position >= 9, let method = Method(rawValue: file[position]) else { return nil }
            func length(at offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(file[offset + $1]) << (8 * $1) }
            }
            let size = length(at: position + 1), storedSize = length(at: position + 5)
            position += 9
            guard size <= maximumSize, storedSize <= file.count - position else { return nil }
            let stored = file[position..<position + storedSize]
            position += storedSize
            let value: Data?
            switch method {
            case .stored:
                value = Data(stored)
            case .deflated:
                value = inflate(stored, limit: size)
            case .packed:
                value = try inflate(stored, limit: size).flatMap {
                    try SidecarActivityPacking.unpack($0, logicalSize: size, cancelled: cancelled)
                }
            case .packedProviderLayout:
                value = try inflate(stored, limit: size).flatMap {
                    try SidecarActivityPacking.unpackProviderLayout($0, logicalSize: size, cancelled: cancelled)
                }
            }
            return value?.count == size ? value : nil
        }
        guard let result = try document() else { return nil }
        var activity: Data?
        if file[5] == 1 {
            guard let levels = try document() else { return nil }
            activity = levels
        }
        try checkSidecarCancellation(cancelled)
        guard position == file.count,
              file[8..<header].elementsEqual(digest(result: result, activity: activity)) else { return nil }
        return (result, activity)
    }

    /// Records in the shared folder that this build reads the current version.
    static func declareReader(in directory: URL) {
        let url = directory.appendingPathComponent(readerName)
        let text = Data("\(version)\n".utf8)
        if (try? Data(contentsOf: url)) != text { try? text.write(to: url, options: .atomic) }
    }

    /// Packed levels are a small fraction of their document, so they are tried first. A
    /// document is stored in a form only after that form has reproduced it.
    private static func payload(_ document: Data, cancelled: () -> Bool) throws -> (Method, Data) {
        if let packed = try SidecarActivityPacking.pack(document, cancelled: cancelled) {
            if try SidecarActivityPacking.unpack(packed, logicalSize: document.count, cancelled: cancelled) == document,
               let stored = deflate(packed) { return (.packed, stored) }
        } else if let packed = try SidecarActivityPacking.packProviderLayout(document, cancelled: cancelled),
                  try SidecarActivityPacking.unpackProviderLayout(packed, logicalSize: document.count,
                                                                  cancelled: cancelled) == document,
                  let stored = deflate(packed) {
            return (.packedProviderLayout, stored)
        }
        try checkSidecarCancellation(cancelled)
        if let stored = deflate(document) { return (.deflated, stored) }
        return (.stored, document)
    }

    /// The raw DEFLATE stream of the input, when that is smaller than the input.
    private static func deflate(_ input: Data) -> Data? {
        guard input.count > 1, let buffer = malloc(input.count) else { return nil }
        let written = input.withUnsafeBytes { source in
            compression_encode_buffer(buffer.assumingMemoryBound(to: UInt8.self), input.count - 1,
                                      source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else {
            free(buffer)
            return nil
        }
        return Data(bytesNoCopy: buffer, count: written, deallocator: .free)
    }

    private static func inflate(_ input: Data, limit: Int) -> Data? {
        guard !input.isEmpty, limit > 0 else { return nil }
        // DEFLATE expands a stream at most 1032 times, which keeps a damaged length from
        // reserving more than the file can fill.
        let capacity = min(limit, input.count * 1032 + 64) + 1
        guard let buffer = malloc(capacity) else { return nil }
        let written = input.withUnsafeBytes { source in
            compression_decode_buffer(buffer.assumingMemoryBound(to: UInt8.self), capacity,
                                      source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written <= limit else {
            free(buffer)
            return nil
        }
        return Data(bytesNoCopy: buffer, count: written, deallocator: .free)
    }
}
