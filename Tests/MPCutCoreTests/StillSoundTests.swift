import AVFoundation
import XCTest
@testable import MPCutCore

final class StillSoundTests: XCTestCase {
    private func t(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        RationalTime(numerator: numerator, denominator: denominator)
    }

    private func withDirectory(_ work: (URL, URL) throws -> Void) throws {
        let helper: URL
        do { helper = try ReencodeEngine.findHelper(override: nil) }
        catch { throw XCTSkip("The FFmpeg helper is needed for real soundtrack fixtures.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try work(folder, helper)
    }

    private func run(_ helper: URL, _ arguments: [String], in folder: URL) throws {
        try ReencodeEngine().runHelper(helper, arguments: arguments, in: folder)
    }

    func testFiveFractionalFrameSilencesAddExactlyEightThousandEightSamples() throws {
        try withDirectory { folder, helper in
            let recording = folder.appendingPathComponent("source.wav")
            try run(helper, ["-f", "lavfi", "-i", "aevalsrc=0.5:s=48000:d=1",
                             "-c:a", "pcm_s32le", recording.path], in: folder)
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let clip = CutSequenceClip(id: "take", file: recording.lastPathComponent, from: .zero, to: t(1))
            let frame = t(1001, 30_000)
            var items: [StillSequenceItem] = (0..<5).map { index in
                .still(StillInsert(id: "insert-\(index)", assetID: asset.id, duration: frame, cadence: frame))
            }
            items.append(.source(clip))
            let project = CutProject.stillSequence(StillSequenceProject(items: items, stillAssets: [asset]))
            let planner = StillSoundPlanner()
            let plan = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                           timeline: project.resolveStills(), tracks: .audio, audioStream: nil,
                                           mode: .smart, audio: .auto, container: "mov")
            XCTAssertEqual(plan.actions.map(\.audio), [.pcm])
            guard case .convert(let pcm) = plan.treatments.first else { return XCTFail("Expected PCM zero fill") }
            XCTAssertEqual(pcm.inputs.filter(\.silence).reduce(0) { $0 + $1.count }, 8008)
            let output = try XCTUnwrap(planner.write(plan, in: folder).first)
            let raw = folder.appendingPathComponent("joined.raw")
            try run(helper, ["-i", output.path, "-c:a", "pcm_s32le", "-f", "s32le", raw.path], in: folder)
            let bytes = try Data(contentsOf: raw)
            XCTAssertEqual(bytes.count, (8008 + 48000) * 4)
            XCTAssertTrue(bytes.prefix(8008 * 4).allSatisfy { $0 == 0 })
            XCTAssertEqual(Array(bytes.dropFirst(8008 * 4).prefix(4)), [0, 0, 0, 64])
            let reference = folder.appendingPathComponent("source.raw")
            try run(helper, ["-i", recording.path, "-c:a", "pcm_s32le", "-f", "s32le", reference.path], in: folder)
            XCTAssertEqual(Data(bytes.dropFirst(8008 * 4)), try Data(contentsOf: reference))

            let format = StillTimelineFormat(width: 96, height: 64, cadence: frame, codec: .h264, container: "mov")
            var selected = StillSequenceProject(items: Array(items.dropLast()), stillAssets: [asset], stillFormat: format)
            selected.stillAudioReference = clip
            let selection = CutProject.stillSequence(selected)
            let silent = try planner.resolve(selection, relativeTo: folder.appendingPathComponent("show.cut"),
                                             timeline: selection.resolveStills(), tracks: .audio, audioStream: nil,
                                             mode: .smart, audio: .auto, container: "mov")
            let staging = folder.appendingPathComponent("selection")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let silentTrack = try XCTUnwrap(planner.write(silent, in: staging).first)
            let silentRaw = staging.appendingPathComponent("silence.raw")
            try run(helper, ["-i", silentTrack.path, "-c:a", "pcm_s32le", "-f", "s32le", silentRaw.path], in: staging)
            XCTAssertEqual(try Data(contentsOf: silentRaw), Data(repeating: 0, count: 8008 * 4))

        }
    }

    func testPictureReplacementPreservesBothAACTracksAndTheirPresentation() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("source.mov")
            try run(helper, ["-f", "lavfi", "-i", "color=s=96x64:r=30:d=2",
                             "-f", "lavfi", "-i", "sine=f=500:r=48000:d=2",
                             "-itsoffset", "0.125", "-f", "lavfi", "-i", "sine=f=900:r=48000:d=1.875",
                             "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                             "-c:a", "aac", "-movie_timescale", "705600000", "-timecode", "01:00:00:00",
                             source.path], in: folder)
            let clip = CutSequenceClip(id: "take", file: source.lastPathComponent, from: .zero, to: t(2),
                                       originalFile: "original.mov", replacementNames: [1: "Microphone"])
            let asset = StillAsset(id: "photo", file: "offline.png", displayName: "Photo", fingerprint: "offline")
            let replacement = StillReplacement(id: "cover", assetID: asset.id, coverage:
                .sequence([StillReplacementFragment(clipID: clip.id, range: MulticamRange(from: t(11, 30), to: t(7, 10)))]))
            let project = CutProject.stillSequence(StillSequenceProject(items: [.source(clip)],
                                                                       stillAssets: [asset], stillReplacements: [replacement]))
            let document = folder.appendingPathComponent("show.cut")
            XCTAssertThrowsError(try StillExportPlanner().resolve(project, relativeTo: document, mode: .smart,
                                                                 container: "mov")) {
                XCTAssertEqual(($0 as? CutError)?.code, "unsupported_still_ancillary_track")
            }
            let planner = StillSoundPlanner()
            let plan = try planner.resolve(project, relativeTo: document,
                                           timeline: project.resolveStills(), tracks: .audio, audioStream: nil,
                                           mode: .copy, audio: .copyOriginal, container: "mov")
            XCTAssertEqual(plan.actions.map(\.audio), [.copyOriginal, .copyOriginal])
            let staged = try planner.write(plan, in: folder)
            let result = folder.appendingPathComponent("joined.mov")
            let video = folder.appendingPathComponent("picture.mov")
            try run(helper, ["-i", source.path, "-map", "0:v:0", "-c:v", "copy", "-timecode", "01:00:00:00",
                             "-movie_timescale", "705600000", video.path], in: folder)
            try MulticamMOV.combine(picture: video, sounds: staged, output: result) { _ in }
            let written = try Probe.read(result)
            XCTAssertEqual(written.streams.filter { $0.codecTag == "tmcd" }.count, 1)
            let tracks = written.audio
            XCTAssertEqual(tracks.count, 2)

            let engine = CutEngine()
            let reference = folder.appendingPathComponent("reference.mov")
            try engine.export(engine.resolve([ClipRequest(file: source)], container: "mov"), to: reference)
            let originals = try Probe.read(reference).audio
            XCTAssertEqual(tracks.map { $0.presentationEdits.map(\.samples) },
                           originals.map { $0.presentationEdits.map(\.samples) })
            XCTAssertEqual(tracks.map { $0.presentationEdits.map(\.isAudible) },
                           originals.map { $0.presentationEdits.map(\.isAudible) })
            XCTAssertEqual(tracks.map(\.start), originals.map(\.start))
            XCTAssertEqual(tracks.map(\.end), originals.map(\.end))
            for (index, copy) in [true, false].enumerated() {
                func checksum(_ url: URL, name: String) throws -> Data {
                    let hashes = folder.appendingPathComponent("\(name)-\(index).txt")
                    let codec = copy ? ["-c:a", "copy"] : ["-c:a", "pcm_s32le"]
                    try run(helper, ["-i", url.path, "-map", "0:a"] + codec + ["-f", "streamhash", hashes.path], in: folder)
                    return try Data(contentsOf: hashes)
                }
                XCTAssertEqual(try checksum(reference, name: "reference"), try checksum(result, name: "written"))
            }
        }
    }

    func testAACFrontInteriorAndTailTitlesConvertTheSelectedTracks() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("source.m4a")
            try run(helper, ["-f", "lavfi", "-i", "sine=f=500:r=48000:d=1",
                             "-c:a", "aac", "-movie_timescale", "705600000", source.path], in: folder)
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let hold = t(1001, 6000)
            for (index, boundary) in [RationalTime.zero, t(1, 2), t(1), .zero].enumerated() {
                let title = StillInsert(id: "insert", assetID: asset.id, duration: hold, cadence: t(1001, 30_000))
                var parts: [StillSequenceItem] = [.still(title)]
                if boundary > .zero {
                    parts.insert(.source(CutSequenceClip(id: "head", file: source.lastPathComponent, from: .zero, to: boundary)), at: 0)
                }
                if boundary < t(1) {
                    parts.append(.source(CutSequenceClip(id: "tail", file: source.lastPathComponent, from: boundary, to: t(1))))
                }
                let project = CutProject.stillSequence(StillSequenceProject(items: parts, stillAssets: [asset]))
                let planner = StillSoundPlanner()
                let document = folder.appendingPathComponent("show.cut")
                let timeline = try project.resolveStills()
                let container = ["mp4", "mov", "mp4", "m4a"][index]
                XCTAssertThrowsError(try planner.resolve(project, relativeTo: document, timeline: timeline, tracks: .audio,
                                                         audioStream: nil, mode: .copy, audio: .copyOriginal, container: container)) {
                    XCTAssertEqual(($0 as? CutError)?.code, "generated_audio_required")
                }
                let plan = try planner.resolve(project, relativeTo: document, timeline: timeline, tracks: .audio,
                                               audioStream: nil, mode: .encode, audio: index == 3 ? .auto : .aac, container: container)
                let staging = folder.appendingPathComponent("trial-\(index)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                let track = try XCTUnwrap(planner.write(plan, in: staging).first)
                let sound = try XCTUnwrap(Probe.read(track).audio.first)
                XCTAssertEqual(sound.end, t(56008, 48000))
                let raw = staging.appendingPathComponent("sound.raw")
                try run(helper, ["-i", track.path, "-c:a", "pcm_s16le", "-f", "s16le", raw.path], in: staging)
                let pcm = try Data(contentsOf: raw)
                let silenceStart = Int(try boundary.roundedToSamples(48_000))
                let silenceEnd = silenceStart + 8008
                // Keep AAC's transform overlap clear of the silence measurement.
                let middle = (silenceStart + 2048)..<(silenceEnd - 2048)
                guard pcm.count >= (silenceEnd + (boundary < t(1) ? 1024 : 0)) * 2 else {
                    XCTFail("The decode ended before the planned title boundary.")
                    continue
                }
                XCTAssertTrue(pcm[(middle.lowerBound * 2)..<(middle.upperBound * 2)].allSatisfy { $0 == 0 })
                if boundary < t(1) {
                    XCTAssertTrue(pcm[(silenceEnd * 2)..<((silenceEnd + 1024) * 2)].contains { $0 != 0 })
                }
                let reader = try AVAudioFile(forReading: track)
                XCTAssertEqual(reader.length, 56008)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 256))
                func peak(seekingTo sample: Int) throws -> Float {
                    reader.framePosition = AVAudioFramePosition(sample)
                    try reader.read(into: buffer, frameCount: 256)
                    XCTAssertEqual(buffer.frameLength, 256)
                    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                    return UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)).map { abs($0) }.max() ?? 0
                }
                XCTAssertLessThan(try peak(seekingTo: silenceStart + 4096), 0.0001)
                if boundary < t(1) { XCTAssertGreaterThan(try peak(seekingTo: silenceEnd), 0.01) }

            }
        }
    }

    func testSmartTrimConvertsOnlyTheIncompatibleOutputTrack() throws {
        try withDirectory { folder, helper in
            var clips: [CutSequenceClip] = []
            for rate in [44_100, 48_000] {
                let source = folder.appendingPathComponent("audio-\(rate).mov")
                try run(helper, ["-f", "lavfi", "-i", "sine=f=500:r=48000:d=1",
                                 "-f", "lavfi", "-i", "sine=f=900:r=\(rate):d=1",
                                 "-map", "0:a", "-map", "1:a", "-c:a:0", "pcm_s32le", "-c:a:1", "aac",
                                 "-movie_timescale", "705600000", source.path], in: folder)
                clips.append(CutSequenceClip(id: "clip-\(rate)", file: source.lastPathComponent, from: .zero, to: t(1)))
            }
            let project = CutProject.sequence(clips)
            let planner = StillSoundPlanner()
            let plan = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                           timeline: project.resolveStills(), tracks: .audio, audioStream: nil,
                                           mode: .smart, audio: .pcm, container: "mov")
            XCTAssertEqual(plan.actions.map(\.audio), [.copyOriginal, .pcm])
            XCTAssertEqual(plan.actions[1].sources.count, 2)
            let staged = try planner.write(plan, in: folder)
            let result = folder.appendingPathComponent("joined.mov")
            try MulticamMOV.combine(picture: nil, sounds: staged, output: result) { _ in }
            let streams = try Probe.read(result).audio
            XCTAssertEqual(streams.map(\.end), [t(2), t(2)])
            XCTAssertEqual(streams.map { $0.stream.sampleRate }, [48_000, 48_000])
        }
    }
}
