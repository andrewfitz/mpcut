import Darwin
import Foundation

extension StillImage {
    /// Opening a named pipe or device as an image could block import or hash an
    /// endless stream. Check the opened descriptor so links to ordinary images work.
    static func openRegularImage(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else {
            throw error("still_format", "Choose a local image file.")
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
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
        guard bytes[4..<8].elementsEqual("ftyp".utf8) else { return false }
        return ["avif", "avis", "heic", "heix", "hevc", "hevx", "mif1", "msf1"]
            .contains(String(decoding: bytes[8..<12], as: UTF8.self))
    }
}
