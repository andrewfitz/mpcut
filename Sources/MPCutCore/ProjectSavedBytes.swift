import Compression
import Foundation

/// A project as it sits on disk: the saved layout's JSON, compressed. Eight bytes name the
/// form, eight more give the JSON's length as a little-endian integer, and a raw DEFLATE
/// stream follows. DEFLATE is what zlib reads, so a script can open a project without MPCut.
enum ProjectSavedBytes {
    /// A NUL first byte cannot begin JSON.
    static let magic: [UInt8] = [0x00, 0x4D, 0x50, 0x43, 0x55, 0x54, 0x31, 0x0A]
    static let headerSize = 16

    /// The compressed project, or nil when the text cannot be compressed.
    static func packed(_ json: Data) -> Data? {
        guard !json.isEmpty else { return nil }
        // A stream that cannot shrink its input grows it by a few bytes in each block.
        let capacity = json.count + json.count / 64 + 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let written = json.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(buffer, capacity, base, source.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        var result = Data(capacity: headerSize + written)
        result.append(contentsOf: magic)
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { result.append(contentsOf: $0) }
        result.append(buffer, count: written)
        return result
    }

    /// The JSON inside a compressed project, or nil for bytes that are not one.
    static func unpacked(_ data: Data, code: String) throws -> Data? {
        guard data.starts(with: magic) else { return nil }
        let damaged = CutError(code: code, message: "The compressed project is damaged.")
        guard data.count > headerSize else { throw damaged }
        let size = data.dropFirst(magic.count).prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // A project's document may not pass the size limit, and its saved layout adds at most
        // a few short lists to that, so nothing near twice the limit was ever written.
        guard size > 0, size <= UInt64(MulticamProject.maximumFileSize) * 2 else { throw damaged }
        let capacity = Int(size)
        // One spare byte shows a stream that holds more than it declares.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity + 1)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(buffer, capacity + 1, base + headerSize, source.count - headerSize,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written == capacity else {
            buffer.deallocate()
            throw damaged
        }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(buffer), count: capacity, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
    }
}

extension ProjectFile {
    /// The project document inside a file's bytes, as plain JSON: decompressed, with what the
    /// saved layout shares written out again. Bytes that are already a plain document come back as they are.
    package static func documentJSON(_ saved: Data, multicam: Bool = false) throws -> Data {
        let code = multicam ? "invalid_multicam_project" : "invalid_cut_project"
        let text = try ProjectSavedBytes.unpacked(saved, code: code) ?? saved
        return try ProjectSavedLayout.expanded(text, code: code) ?? text
    }
}

extension CutProject {
    /// The plain JSON document of a project file's bytes, for a tool that reads a project
    /// without loading it. A file MPCut saved is compressed and shares what it repeats.
    public static func documentJSON(saved: Data) throws -> Data {
        try ProjectFile.documentJSON(saved)
    }
}
