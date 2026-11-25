import AVFoundation
import MPCutCore
import XCTest
@testable import MPCutApp

/// A MOV or MP4 track can start a new sample description at a keyframe, as MPCut's own copies and joins do where the
/// parameter sets change, with no parameter sets inside the samples. FFmpeg's VideoToolbox decoder kept the session it
/// made from the first description, so an H.264 change, or an HEVC change of picture parameter sets, decoded every
/// later picture with the old sets: wrong pictures, or rejected pictures skipped to the next keyframe without a word.
/// The fallback preview now reopens its decoder at the keyframe and must match AVFoundation picture for picture.
final class PreviewDescriptionSwitchTests: XCTestCase {
    private var directory: URL!
    private static let rate: Int32 = 25

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("description-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    /// Two seconds of VideoToolbox H.264 High with B pictures and a keyframe every second. The entropy coder is
    /// recorded in the picture parameter set, so CABAC and CAVLC parts share a size and profile but not their sets.
    private func encodeH264(_ name: String, cabac: Bool, shade: Int) throws -> URL {
        let url = directory.appendingPathComponent(name + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 192,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: cabac ? AVVideoH264EntropyModeCABAC : AVVideoH264EntropyModeCAVLC,
                AVVideoAllowFrameReorderingKey: true, AVVideoMaxKeyFrameIntervalKey: Int(Self.rate),
                AVVideoAverageBitRateKey: 600_000,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 192,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), String(describing: writer.error))
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Int(2 * Self.rate) {
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &created)
            let picture = try XCTUnwrap(created)
            CVPixelBufferLockBaseAddress(picture, [])
            for plane in 0..<2 {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(picture, plane)).assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, plane)
                for y in 0..<CVPixelBufferGetHeightOfPlane(picture, plane) {
                    for x in 0..<stride {
                        // A moving pattern, so each picture is predicted from the ones around it.
                        base[y * stride + x] = plane == 0
                            ? UInt8(truncatingIfNeeded: (x * 3 + y * 2 + index * 5) ^ (x / 16 * 40))
                            : UInt8(truncatingIfNeeded: 128 + shade + (x + index) % 32 - 16)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(picture, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            XCTAssertTrue(adaptor.append(picture, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: Self.rate)))
        }
        input.markAsFinished()
        finish(writer)
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }

    /// Two seconds of x265 HEVC with B pictures, closed picture groups of one second and no parameter sets in the
    /// samples. `extra` changes only the picture parameter set, which keeps FFmpeg's session from being replaced.
    private func encodeHEVC(_ name: String, extra: String) throws -> URL {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile)
        guard let ffmpeg else { throw XCTSkip("Needs ffmpeg with libx265 to make an HEVC fixture.") }
        let url = directory.appendingPathComponent(name + ".mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x96:rate=25:duration=2",
                             "-c:v", "libx265", "-tag:v", "hvc1", "-x265-params",
                             "keyint=25:min-keyint=25:scenecut=0:open-gop=0:bframes=3:b-adapt=0:pools=1:log-level=error" + extra,
                             url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("Needs ffmpeg with libx265 to make an HEVC fixture.") }
        return url
    }

    private func finish(_ writer: AVAssetWriter) {
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }

    /// Join the parts into one MOV track, which starts a sample description wherever its samples' description
    /// changes. `relabel` gives a sample (by part and index) another description for the same data.
    private func join(_ parts: [URL], name: String,
                      relabel: (_ part: Int, _ sample: Int, CMFormatDescription) -> CMFormatDescription? = { _, _, _ in nil })
        throws -> URL {
        let url = directory.appendingPathComponent(name + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), String(describing: writer.error))
        writer.startSession(atSourceTime: .zero)
        var offset = CMTime.zero
        for (part, source) in parts.enumerated() {
            let asset = AVURLAsset(url: source)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
                                                  outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var samples: [CMSampleBuffer] = []
            while let sample = output.copyNextSampleBuffer() {
                if sample.numSamples > 0 { samples.append(sample) }
            }
            // Each part starts at its own first picture, whatever its encoder's reordering delay.
            let start = try XCTUnwrap(samples.map(\.presentationTimeStamp).min())
            var end = offset
            for (index, sample) in samples.enumerated() {
                var timing = try sample.sampleTimingInfos()
                for i in timing.indices {
                    timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - start + offset
                    if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - start + offset }
                    end = max(end, timing[i].presentationTimeStamp + timing[i].duration)
                }
                var copy = try CMSampleBuffer(copying: sample, withNewTiming: timing)
                if let description = sample.formatDescription, let other = relabel(part, index, description) {
                    var sizes = try sample.sampleSizes()
                    var relabeled: CMSampleBuffer?
                    XCTAssertEqual(CMSampleBufferCreateReady(
                        allocator: nil, dataBuffer: try XCTUnwrap(sample.dataBuffer), formatDescription: other,
                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &relabeled), noErr)
                    copy = try XCTUnwrap(relabeled)
                    // Keep the keyframe flags.
                    if let from = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary],
                       let into = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true) as? [NSMutableDictionary],
                       let flags = from.first, let target = into.first {
                        target.addEntries(from: flags as! [AnyHashable: Any])
                    }
                }
                while !input.isReadyForMoreMediaData { usleep(1000) }
                XCTAssertTrue(input.append(copy), String(describing: writer.error))
            }
            offset = end
        }
        input.markAsFinished()
        finish(writer)
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }

    /// The H.264 description with one more picture parameter set: a copy of the first under ID 1.
    private func withExtraPictureSet(_ description: CMFormatDescription) throws -> CMFormatDescription {
        var count = 0
        XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil), noErr)
        var sets: [[UInt8]] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            sets.append(Array(UnsafeBufferPointer(start: try XCTUnwrap(pointer), count: size)))
        }
        let pps = try XCTUnwrap(sets.last)
        // pic_parameter_set_id is the first Exp-Golomb code: 1 for ID 0, 010 for ID 1.
        var payload: [UInt8] = []
        for (i, byte) in pps.dropFirst().enumerated() {
            let dropped = i >= 2 && byte == 3 && payload.suffix(2) == [0, 0]
            if !dropped { payload.append(byte) }
        }
        var bits = payload.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 } }
        XCTAssertEqual(bits.first, 1)
        let last = try XCTUnwrap(bits.lastIndex(of: 1))
        bits = [0, 1, 0] + bits[1..<last] + [1]
        bits += Array(repeating: 0, count: (8 - bits.count % 8) % 8)
        var renumbered: [UInt8] = [pps[0]]
        for start in stride(from: 0, to: bits.count, by: 8) {
            let byte = bits[start..<start + 8].reduce(0) { $0 << 1 | $1 }
            if renumbered.count >= 3, renumbered.suffix(2) == [0, 0], byte <= 3 { renumbered.append(3) }
            renumbered.append(byte)
        }
        sets.append(renumbered)
        var result: CMFormatDescription?
        let pointers = sets.map { set -> UnsafePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            copy.initialize(from: set, count: set.count)
            return UnsafePointer(copy)
        }
        defer { pointers.forEach { $0.deallocate() } }
        XCTAssertEqual(CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    // MARK: Pictures

    private func planes(_ buffer: CVPixelBuffer) -> [Data] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<CVPixelBufferGetPlaneCount(buffer)).map { plane in
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            var data = Data(capacity: width * CVPixelBufferGetHeightOfPlane(buffer, plane))
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) { data.append(base + y * stride, count: width) }
            return data
        }
    }

    private func index(_ time: CMTime) -> Int { Int((time.seconds * Double(Self.rate)).rounded()) }

    /// Every picture as AVFoundation decodes it, by picture number from the first. (AVFoundation can report a MOV
    /// track's media times, which a reordering delay puts after the presented times the preview counts from.)
    private func nativePictures(_ url: URL) throws -> [Int: [Data]] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var pictures: [(time: CMTime, planes: [Data])] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = sample.imageBuffer else { continue }
            pictures.append((sample.presentationTimeStamp, planes(image)))
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        let first = try XCTUnwrap(pictures.map(\.time).min())
        return Dictionary(pictures.map { (index($0.time - first), $0.planes) }) { first, _ in first }
    }

    /// The picture numbers where the track's description changes, and whether that sample carries parameter sets.
    private func switches(_ url: URL) throws -> [(picture: Int, inBandSets: Bool)] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let hevc = track.formatDescriptions.contains { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) == kCMVideoCodecType_HEVC }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.numSamples > 0 { samples.append(sample) }
        }
        let first = try XCTUnwrap(samples.map(\.presentationTimeStamp).min())
        var previous: CMFormatDescription?
        var found: [(Int, Bool)] = []
        for sample in samples {
            guard let description = sample.formatDescription else { continue }
            defer { previous = description }
            guard let previous, !CMFormatDescriptionEqual(previous, otherFormatDescription: description) else { continue }
            let data = try sample.dataBuffer!.dataBytes()
            var at = 0, sets = false
            while at + 4 < data.count {
                let length = data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
                let type = hevc ? Int(data[at + 4] >> 1) & 0x3f : Int(data[at + 4]) & 0x1f
                sets = sets || (hevc ? (32...34).contains(type) : type == 7 || type == 8)
                at += 4 + length
            }
            found.append((index(sample.presentationTimeStamp - first), sets))
        }
        return found
    }

    /// Play the whole track with the fallback preview and compare every picture with AVFoundation's.
    private func assertPlaybackMatches(_ url: URL, pictures expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let native = try nativePictures(url)
        XCTAssertEqual(native.count, expected, file: file, line: line)
        let reader = FFPreviewReader(videoOnly: true)
        try reader.seek(url: url, to: 0)
        var seen: [Int] = []
        let end = Double(expected) / Double(Self.rate)
        for _ in 0..<400 {
            let batch = try reader.batch(from: 0, end: end, timelineOffset: 0.0, first: seen.isEmpty, cancelled: { false })
            XCTAssertNil(batch.pictureNotice, file: file, line: line)
            XCTAssertFalse(batch.hasPictureGap, file: file, line: line)
            for frame in batch.video {
                let number = index(frame.time)
                seen.append(number)
                XCTAssertTrue(planes(frame.buffer) == native[number], "picture \(number) differs from AVFoundation's",
                              file: file, line: line)
            }
            if batch.end { break }
        }
        XCTAssertEqual(seen, Array(0..<expected), file: file, line: line)

        // Seek and scrub across the change in both directions, as reverse play and the skimmer do.
        let still = FFPreviewReader(videoOnly: true)
        for number in [expected - 1, 52, 51, 50, 49, 48, 26, 0, 99, 50, 1, 75, 49] where number < expected {
            let time = Double(number) / Double(Self.rate)
            try still.seek(url: url, to: time)
            let frame = try XCTUnwrap(try still.still(at: time, before: end) { false }, "no picture \(number) after a seek",
                                      file: file, line: line)
            XCTAssertEqual(index(frame.time), number, file: file, line: line)
            XCTAssertTrue(planes(frame.buffer) == native[number], "picture \(number) differs after a seek", file: file, line: line)
        }
    }

    // MARK: Tests

    func testH264DescriptionSwitchPlaysEveryPictureExactly() throws {
        let cabac = try encodeH264("cabac", cabac: true, shade: 0)
        let cavlc = try encodeH264("cavlc", cabac: false, shade: 20)
        let joined = try join([cabac, cavlc, cabac], name: "h264-switch")
        XCTAssertEqual(AVURLAsset(url: joined).tracks(withMediaType: .video).first?.formatDescriptions.count, 2)
        let changes = try switches(joined)
        XCTAssertEqual(changes.map(\.picture), [50, 100])
        // Only the description holds the new sets; this is what FFmpeg's VideoToolbox decoder missed.
        XCTAssertEqual(changes.map(\.inBandSets), [false, false])
        try assertPlaybackMatches(joined, pictures: 150)
    }

    func testHEVCPictureSetSwitchPlaysEveryPictureExactly() throws {
        let plain = try encodeHEVC("plain", extra: "")
        let offsets = try encodeHEVC("offsets", extra: ":cbqpoffs=3:crqpoffs=-2")
        let joined = try join([plain, offsets, plain], name: "hevc-switch")
        let changes = try switches(joined)
        XCTAssertEqual(changes.map(\.picture), [50, 100])
        XCTAssertEqual(changes.map(\.inBandSets), [false, false])
        try assertPlaybackMatches(joined, pictures: 150)
    }

    /// A description that only lists the same sets again is the same description. One that adds a set at a picture
    /// that is not a keyframe cannot be followed there: the preview resumes at the next keyframe and says so.
    func testDescriptionChangeBetweenKeyframesIsReported() throws {
        let cabac = try encodeH264("cabac", cabac: true, shade: 0)
        var extra: CMFormatDescription?
        let aligned = try join([cabac, cabac], name: "aligned") { part, _, description in
            if extra == nil { extra = try? self.withExtraPictureSet(description) }
            return part == 1 ? extra : nil
        }
        XCTAssertEqual(try switches(aligned).map(\.picture), [50])
        try assertPlaybackMatches(aligned, pictures: 100)

        let unaligned = try join([cabac, cabac], name: "unaligned") { part, sample, _ in
            part == 1 && sample >= 3 ? extra : nil
        }
        let changes = try switches(unaligned)
        XCTAssertEqual(changes.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(changes.first).picture, 50)
        let native = try nativePictures(unaligned)
        let reader = FFPreviewReader(videoOnly: true)
        try reader.seek(url: unaligned, to: 0)
        var seen: [Int] = []
        var notice: String?
        for _ in 0..<400 {
            let batch = try reader.batch(from: 0, end: 4, timelineOffset: 0.0, first: seen.isEmpty, cancelled: { false })
            notice = batch.pictureNotice ?? notice
            for frame in batch.video {
                seen.append(index(frame.time))
                XCTAssertTrue(planes(frame.buffer) == native[index(frame.time)], "picture \(index(frame.time)) differs")
            }
            if batch.end { break }
        }
        XCTAssertEqual(notice, "The video changes its sample description at a picture that is not a keyframe. "
                       + "Preview skipped to the next keyframe.")
        // Every picture before the change, then every picture from the next keyframe.
        XCTAssertEqual(Array(seen.prefix(50)), Array(0..<50))
        XCTAssertEqual(Array(seen.suffix(25)), Array(75..<100))
        XCTAssertLessThan(seen.count, 100)

        // A still in that stretch names the change, not damage, and leaves playback available.
        let still = FFPreviewReader(videoOnly: true)
        try still.seek(url: unaligned, to: 2.4)
        XCTAssertThrowsError(try still.still(at: 2.4, before: 4) { false }) {
            XCTAssertEqual($0.localizedDescription, WebSequencePlayback.descriptionChangePicture)
        }
        XCTAssertTrue(WebSequencePlayback.omittedPictures.contains(WebSequencePlayback.descriptionChangePicture))
        try still.seek(url: unaligned, to: 3.2)
        XCTAssertEqual(index(try XCTUnwrap(try still.still(at: 3.2, before: 4) { false }).time), 80)
    }

    /// Damage-H264.mp4 with the P picture at 1.6 s overwritten (as in DamagedPicturePreviewTests).
    private func damagedFixture() throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Damage-H264", withExtension: "mp4", subdirectory: "Fixtures"))
        var data = try Data(contentsOf: source)
        let track = try XCTUnwrap(AVURLAsset(url: source).tracks(withMediaType: .video).first)
        let origin = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder()).presentationTimeStamp
        let cursor = try XCTUnwrap(track.makeSampleCursor(presentationTimeStamp: origin + CMTime(value: 40, timescale: 25)))
        let range = cursor.currentSampleStorageRange
        for i in Int(range.offset) + 24..<Int(range.offset + range.length) - 8 {
            data[i] = UInt8(truncatingIfNeeded: i &* 197 &+ 91)
        }
        let url = directory.appendingPathComponent("damaged.mp4")
        try data.write(to: url)
        return url
    }

    /// Playback that skips a damaged picture's group used to show nothing about it.
    func testPlaybackPastADamagedPictureCarriesANotice() throws {
        let url = try damagedFixture()
        let reader = FFPreviewReader(videoOnly: true)
        try reader.seek(url: url, to: 0)
        var notices: [String?] = []
        var first = true
        for _ in 0..<200 {
            let batch = try reader.batch(from: 0, end: 4, timelineOffset: 0.0, first: first, cancelled: { false })
            first = first && batch.video.isEmpty
            notices.append(batch.pictureNotice)
            if batch.end { break }
        }
        XCTAssertNil(notices.first ?? nil, "The first pictures precede the damage.")
        XCTAssertEqual(notices.last ?? nil, "A damaged picture could not be decoded. Preview skipped to the next keyframe.")
        // A seek starts a new pass.
        try reader.seek(url: url, to: 0.4)
        let batch = try reader.batch(from: 0.4, end: 4, timelineOffset: 0.0, first: true, cancelled: { false })
        XCTAssertNil(batch.pictureNotice)
    }

    /// The notice reaches the transport's owner during playback, and a seek withdraws it.
    @MainActor
    func testPlaybackReportsTheSkippedPicturesUntilTheNextSeek() async throws {
        let url = try damagedFixture()
        let range = PreviewRange(url: url, exactStart: .zero, exactEnd: .init(numerator: 4))
        var notices: [String?] = []
        var position = 0.0
        let player = WebSequencePlayback(ranges: [range], onFrame: { _ in }, onTime: { position = $0 },
                                         onIssue: { XCTFail($0) }, onAudioWarning: { _ in },
                                         onPictureNotice: { notices.append($0) })
        player.setGain(0)
        player.park(at: 1.2)
        player.play()
        let clock = ContinuousClock.now
        while position < 2.3, clock.duration(to: .now) < .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
        }
        player.pause()
        XCTAssertGreaterThanOrEqual(position, 2.3)
        XCTAssertEqual(notices.compactMap { $0 }, ["A damaged picture could not be decoded. Preview skipped to the next keyframe."])
        player.seek(to: 0)
        XCTAssertEqual(notices.count, 2)
        XCTAssertNil(try XCTUnwrap(notices.last))
    }

    @MainActor
    func testEditorStateReportsThePreviewDecoderAndNotices() {
        let preview = SequencePreview()
        let state = preview.mcpState
        XCTAssertEqual(state["decoder"] as? String, "avfoundation")
        XCTAssertEqual(state["blocking"] as? Bool, false)
        XCTAssertNil(state["picture_notice"])
        XCTAssertNil(state["fallback_reason"])
    }
}
