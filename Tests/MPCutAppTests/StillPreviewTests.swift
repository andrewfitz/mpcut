import AVFoundation
import ImageIO
import MPCutCore
import UniformTypeIdentifiers
import XCTest
@testable import MPCutApp

final class StillPreviewTests: XCTestCase {
    func testProgramPictureUsesOccurrenceAndInlineClock() throws {
        let asset = StillAsset(id: "artwork", file: "media/photo.png", displayName: "Photo", fingerprint: "fixture")
        let first = CutSequenceClip(id: "first", file: "camera.mov", from: .zero, to: .init(numerator: 6))
        let second = CutSequenceClip(id: "second", file: first.file, from: first.from, to: first.to)
        let card = StillInsert(id: "card", assetID: asset.id, duration: .init(numerator: 1),
                               cadence: .init(numerator: 1, denominator: 30))
        let cover = StillReplacement(id: "cover", assetID: asset.id, coverage: .sequence([
            .init(clipID: second.id, range: .init(from: .init(numerator: 2), to: .init(numerator: 4)))
        ]))
        let project = CutProject.stillSequence(.init(items: [.source(first), .still(card), .source(second)],
                                                    stillAssets: [asset], stillReplacements: [cover]))
        let document = URL(fileURLWithPath: "/tmp/sequence/session.cut")
        let program = try XCTUnwrap(ProgramPreviewStills(project: project, reference: nil, document: document))
        XCTAssertNil(program.picture(at: RationalTime(numerator: 2)))
        XCTAssertEqual(program.picture(at: 6.0)?.output, .init(from: .init(numerator: 6), to: .init(numerator: 7)))
        XCTAssertNil(program.picture(at: 7.0))
        XCTAssertEqual(program.picture(at: RationalTime(numerator: 9))?.url.path, "/tmp/sequence/media/photo.png")
        XCTAssertNil(program.picture(at: RationalTime(numerator: 11)))
        XCTAssertEqual(program.duration, .init(numerator: 13))
    }

    func testStillProgramUsesExplicitCanvasAndRejectsReplacedImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("card.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 2, height: 2))
        let png = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(png))
        let asset = StillAsset(id: "image", file: "card.png", displayName: "Card",
                               fingerprint: try StillImage.fingerprint(source))
        let cadence = RationalTime(numerator: 1, denominator: 30)
        let card = StillInsert(id: "card", assetID: asset.id, duration: .init(numerator: 1), cadence: cadence)
        let format = StillTimelineFormat(width: 96, height: 64, cadence: cadence, codec: .h264, container: "mov")
        let project = CutProject.stillSequence(.init(items: [.still(card)], stillAssets: [asset], stillFormat: format))
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: "mov",
                                                    subdirectory: "Fixtures"))
        let reference = try CutEngine(useSidecar: false).inspect(movie, keyframes: false)
        let document = directory.appendingPathComponent("project.cut")
        let program = try XCTUnwrap(ProgramPreviewStills(project: project, reference: reference, document: document))
        let picture = try XCTUnwrap(program.picture(at: RationalTime.zero))
        let renderer = ProgramPreviewRenderer()
        let frame = try await renderer.render(picture, canvas: program.canvas)
        XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), 96)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.buffer), 64)
        let review = try project.stillReviewFrame(placementID: card.id, interval: picture.output,
                                                document: document, canvas: reference)
        let jpeg = try review.jpeg(preset: .review, cancelled: { false })
        XCTAssertEqual(jpeg.width, 96)
        XCTAssertEqual(jpeg.height, 64)

        try Data("replacement".utf8).write(to: source, options: .atomic)
        do {
            _ = try await renderer.render(picture, canvas: program.canvas)
            XCTFail("The changed still should require relinking.")
        } catch let error as CutError {
            XCTAssertEqual(error.code, "source_changed")
        }
        XCTAssertThrowsError(try review.jpeg(preset: .review, cancelled: { false })) {
            XCTAssertEqual(($0 as? CutError)?.code, "source_changed")
        }
    }

    @MainActor
    func testHeadAndInteriorInsertsShiftAudioWithoutOpeningTheImageAsMedia() async throws {
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Shuttle-Chirp", withExtension: "mov",
                                                    subdirectory: "Fixtures"))
        let card = PreviewRange(url: URL(fileURLWithPath: "/stills/offline.png"), exactStart: .zero,
                                exactEnd: .init(numerator: 1, denominator: 2), isAudioOnly: true, isSilentInsert: true)
        let beginning = PreviewRange(url: movie, exactStart: .zero, exactEnd: .init(numerator: 1))
        let end = PreviewRange(url: movie, exactStart: .init(numerator: 1), exactEnd: .init(numerator: 2))
        let composition = try await SequencePreview.makeAudioComposition([card, beginning, card, end])
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let segments = try await track.load(.segments).filter { !$0.isEmpty }

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map { $0.timeMapping.target.start.seconds }, [0.5, 2])
        XCTAssertEqual(segments.map { $0.timeMapping.target.end.seconds }, [1.5, 3])
        XCTAssertEqual(segments.map { $0.timeMapping.source.start.seconds }, [0, 1])
    }

    func testSDRPresentationDoesNotChangeSharedHDRPicture() throws {
        var source: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_ARGB2101010LEPacked, attributes, &source),
                       kCVReturnSuccess)
        let input = try XCTUnwrap(source)
        let frame = PreviewFrame(buffer: input, time: .zero, transform: .identity, programTransfer: "smpte2084")
        XCTAssertFalse(PreviewTransfer(frame: frame).isVerified)
        XCTAssertFalse(PreviewTransfer(frame: frame.tagged(transfer: "smpte2084", cameraTransfer: "smpte2084")).isVerified)
        let untaggedCamera = PreviewTransfer(frame: frame.tagged(transfer: "smpte2084", cameraTransfer: "unknown"))
        XCTAssertTrue(untaggedCamera.isVerified)
        XCTAssertTrue(untaggedCamera.usesSDRCameraPreview)
        XCTAssertEqual(untaggedCamera.program, "PQ")

        let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, pq, .shouldPropagate)
        XCTAssertTrue(PreviewTransfer(frame: frame).isVerified)
        XCTAssertEqual(PreviewTransfer(frame: frame).actualHDR, "PQ")

        CVPixelBufferLockBaseAddress(input, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(input))
        for row in 0..<16 {
            let pixels = base.advanced(by: row * CVPixelBufferGetBytesPerRow(input)).assumingMemoryBound(to: UInt32.self)
            for column in 0..<16 {
                let value: UInt32 = column < 8 ? 590 : 770
                pixels[column] = 0xc0000000 | (value << 20) | (value << 10) | value
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])

        let mapped = try XCTUnwrap(PreviewTransfer.mapToSDR(input))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(mapped), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVBufferCopyAttachment(mapped, kCVImageBufferTransferFunctionKey, nil) as? String,
                       kCVImageBufferTransferFunction_sRGB as String)
        CVPixelBufferLockBaseAddress(mapped, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mapped, .readOnly) }
        let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddress(mapped)).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixel[40], pixel[0])
        XCTAssertEqual(CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil) as? String, pq as String)
    }

    func testSDRPresentationReadsBT2020PictureWithoutMatrixAsBT2020() throws {
        // VideoToolbox leaves the matrix of a PQ BT.2020 picture that records none unset. The HDR
        // preview decodes it as BT.2020; Core Image alone would read BT.709 (225 instead of 242 here).
        func picture(matrix: CFString?) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                               attributes, &buffer), kCVReturnSuccess)
            let picture = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(picture, [])
            // A saturated green in 10-bit limited range, high-aligned as VideoToolbox stores it.
            for (plane, values) in [(0, [UInt16(400)]), (1, [UInt16(300), UInt16(300)])] {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(picture, plane))
                for row in 0..<CVPixelBufferGetHeightOfPlane(picture, plane) {
                    let line = base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(picture, plane))
                        .assumingMemoryBound(to: UInt16.self)
                    for sample in 0..<CVPixelBufferGetWidthOfPlane(picture, plane) * values.count {
                        line[sample] = values[sample % values.count] << 6
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(picture, [])
            CVBufferSetAttachment(picture, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(picture, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            if let matrix { CVBufferSetAttachment(picture, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
            return picture
        }
        func firstPixel(_ buffer: CVPixelBuffer?) throws -> [UInt8] {
            let buffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            return [bytes[2], bytes[1], bytes[0]]
        }
        let untagged = try picture(matrix: nil)
        let mapped = try firstPixel(PreviewTransfer.mapToSDR(untagged))
        XCTAssertEqual(mapped, try firstPixel(PreviewTransfer.mapToSDR(picture(matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020))))
        XCTAssertNotEqual(mapped, try firstPixel(PreviewTransfer.mapToSDR(picture(matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))))
        // The shared picture keeps its own description.
        XCTAssertNil(CVBufferCopyAttachment(untagged, kCVImageBufferYCbCrMatrixKey, nil))
    }

    @MainActor
    func testSoundtrackPreviewKeepsOneSelectedAudioRangeAcrossStills() async throws {
        let movie = try XCTUnwrap(Bundle.module.url(forResource: "Standalone-Multitrack", withExtension: "mov",
                                                    subdirectory: "Fixtures"))
        let media = try CutEngine(useSidecar: false).inspect(movie, keyframes: false)
        let stream = try XCTUnwrap(media.audio.dropFirst().first?.stream)
        let clip = try StillSoundtrack.reference(media: media, stream: stream.index,
                                                 from: .init(numerator: 1, denominator: 16),
                                                 to: .init(numerator: 3, denominator: 16))
        let cadence = RationalTime(numerator: 1, denominator: 30)
        let asset = StillAsset(gapID: "black")
        let first = StillInsert(id: "first", assetID: asset.id, duration: .init(numerator: 1, denominator: 15),
                                cadence: cadence)
        let second = StillInsert(id: "second", assetID: asset.id, duration: .init(numerator: 14, denominator: 15),
                                 cadence: cadence)
        let format = StillTimelineFormat(width: 96, height: 64, cadence: cadence, codec: .h264, container: "mov")
        let project = CutProject.stillSequence(.init(items: [.still(first), .still(second)],
                                                    stillAssets: [asset], stillFormat: format, stillSoundtrack: clip))
        let suite = "StillPreviewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = EditorModel(defaults: defaults)
        editor.useAnalysisSidecars = false
        defer { editor.endSession() }
        editor.cacheStillSoundtrackMedia(media)
        try editor.applyStillProject(project, action: "Attach Soundtrack")
        let waveform = try XCTUnwrap(editor.stillSoundtrackWaveform)
        XCTAssertEqual(waveform.source, .init(from: clip.from, to: clip.to))
        XCTAssertEqual(waveform.output, .init(from: .zero, to: .init(numerator: 1, denominator: 8)))
        let preview = editor.preview
        preview.scrubSoundEnabled = false

        XCTAssertEqual(preview.ranges.count, 2)
        XCTAssertEqual(preview.ranges.first?.audioTrack, 1)
        XCTAssertEqual(preview.ranges.last?.isSilentInsert, true)
        XCTAssertEqual(preview.ranges.last?.exactEnd, .init(numerator: 7, denominator: 8))
        let composition = try await SequencePreview.makeAudioComposition(preview.ranges)
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual((segments.first as? AVCompositionTrackSegment)?.sourceTrackID, stream.trackID)
        XCTAssertEqual(segments.first?.timeMapping.source.start.seconds, 0.0625)
        XCTAssertEqual(segments.first?.timeMapping.target.end.seconds, 0.125)

        editor.scrub(0.1)
        XCTAssertEqual(editor.playhead, 0.1)
        editor.scrub(0.75)
        XCTAssertEqual(editor.playhead, 0.75)
        editor.scrub(0.05)
        XCTAssertEqual(editor.playhead, 0.05)
        preview.endScrub()
    }
}
