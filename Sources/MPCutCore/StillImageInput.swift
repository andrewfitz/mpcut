import CoreGraphics
import Darwin
import Foundation

extension StillImage {
    /// Opening a named pipe or device as an image could block import or hash an
    /// endless stream. Check the opened descriptor so links to ordinary images work.
    static func openRegularImage(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else {
            throw error("still_format", "Choose a local image file.")
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw error("still_offline", "Cannot open still image \(url.lastPathComponent).")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw error("still_format", "Choose a regular image file at \(url.path).")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func imageDataProvider(_ file: FileHandle) -> CGDataProvider? {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, info.st_size > 0 else { return nil }
        let descriptor = fcntl(file.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return nil }
        // A lazy image may outlive the original handle. Give Image I/O a
        // separate descriptor to the same file and read without moving its offset.
        let reference = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        reference.initialize(to: descriptor)
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, offset, count in
                guard let info else { return 0 }
                let descriptor = info.assumingMemoryBound(to: Int32.self).pointee
                var read = 0
                while read < count {
                    let result = pread(descriptor, buffer.advanced(by: read), count - read, offset + off_t(read))
                    if result < 0, errno == EINTR { continue }
                    if result <= 0 { break }
                    read += result
                }
                return read
            },
            releaseInfo: { info in
                guard let info else { return }
                let reference = info.assumingMemoryBound(to: Int32.self)
                close(reference.pointee)
                reference.deallocate()
            }
        )
        let provider = CGDataProvider(directInfo: reference, size: info.st_size, callbacks: &callbacks)
        if provider == nil {
            close(descriptor)
            reference.deallocate()
        }
        return provider
    }

    static func imageFileBrands(_ file: FileHandle, header: Data) throws -> [String] {
        guard header.count >= 8, header[4..<8].elementsEqual("ftyp".utf8) else { return [] }
        var size = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var headerSize = 8
        if size == 1 {
            guard header.count >= 16 else { return [] }
            size = header[8..<16].reduce(0) { ($0 << 8) | UInt64($1) }
            headerSize = 16
        }
        // Ignore the minor version and read every compatible brand in the box.
        guard size >= UInt64(headerSize + 8), size <= 65_536,
              (size - UInt64(headerSize)).isMultiple(of: 4) else { return [] }
        let payloadSize = Int(size) - headerSize
        try file.seek(toOffset: UInt64(headerSize))
        guard let payload = try file.read(upToCount: payloadSize), payload.count == payloadSize else { return [] }
        return [String(decoding: payload.prefix(4), as: UTF8.self)]
            + stride(from: 8, to: payloadSize, by: 4).map {
                String(decoding: payload[$0..<($0 + 4)], as: UTF8.self)
            }
    }

    /// Use the extension for offline and damaged files so the caller can report
    /// an image-specific diagnostic. Recognize extensionless media by its bytes.
    public static func isImageInput(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if filenameExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let file = try? openRegularImage(url) else { return false }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 32) else { return false }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) || bytes.starts(with: [0xff, 0x0a]) ||
            bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) ||
            bytes.starts(with: [0x49, 0x49, 42, 0]) || bytes.starts(with: [0x4d, 0x4d, 0, 42]) ||
            bytes.starts(with: [0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 13, 10, 0x87, 10]) {
            return true
        }
        guard bytes.count >= 12 else { return false }
        if bytes.starts(with: "RIFF".utf8) { return bytes[8..<12].elementsEqual("WEBP".utf8) }
        let brands = (try? imageFileBrands(file, header: bytes)) ?? []
        return brands.contains { ["avif", "avis", "heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains($0) }
    }
}
