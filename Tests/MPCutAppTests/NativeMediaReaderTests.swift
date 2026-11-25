import CoreMedia
import CoreVideo
import FFPreview
import MediaProbe
import XCTest

final class NativeMediaReaderTests: XCTestCase {
    private func movie() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: "mov",
                                       subdirectory: "Fixtures"))
    }

    func testCancelledOpenStopsBeforeReadingTheMovie() throws {
        let url = try movie()
        var probeError = [CChar](repeating: 0, count: 256)
        let probe = mp_probe_read(url.path, 0, 1, 0, 0, { _ in 1 }, nil, nil, &probeError, probeError.count)
        defer { mp_probe_free(probe) }
        XCTAssertNil(probe)
        XCTAssertEqual(String(cString: probeError), "Immediate exit requested")

        var previewError: UnsafePointer<CChar>?
        let preview = mp_preview_open(url.path, MPPreviewSoundOnly, 0, .invalid, { _ in true }, nil, &previewError)
        defer { mp_preview_close(preview) }
        XCTAssertNil(preview)
        XCTAssertEqual(previewError.map { String(cString: $0) }, "Preview opening was cancelled.")
    }

    func testJPEGReaderRequiresTimedVideoAndCanDecodeWithoutCancellationCallback() throws {
        let url = try movie()
        var error = [CChar](repeating: 0, count: 256)
        let soundReader = mp_jpeg_open(url.path, 1, nil, nil, &error, error.count)
        defer { mp_jpeg_close(soundReader) }
        XCTAssertNil(soundReader)

        let cover = try XCTUnwrap(Bundle.module.url(forResource: "Covered-Audio", withExtension: "mp3",
                                                    subdirectory: "Fixtures"))
        let coverReader = mp_jpeg_open(cover.path, 1, nil, nil, &error, error.count)
        defer { mp_jpeg_close(coverReader) }
        XCTAssertNil(coverReader)

        let reader = try XCTUnwrap(mp_jpeg_open(url.path, 0, nil, nil, &error, error.count))
        defer { mp_jpeg_close(reader) }
        var image: CVPixelBuffer?
        XCTAssertEqual(mp_jpeg_frame(reader, 0, .min, 64, &image, &error, error.count), 0)
        XCTAssertNotNil(image)
    }
}
