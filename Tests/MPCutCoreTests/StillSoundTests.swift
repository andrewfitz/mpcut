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

    func testSoundtrackEncodersRetainNativeSamplesAndRefuseUnrepresentablePrecision() throws {
        try withDirectory { folder, helper in
            let frames = 48_001
            for (sourceCodec, rawFormat) in [("pcm_s24le", "s32le"), ("pcm_s32le", "s32le"), ("pcm_f64le", "f64le")] {
                let source = folder.appendingPathComponent("\(sourceCodec).mov")
                let rawCodec = "pcm_\(rawFormat)"
                try run(helper, ["-f", "lavfi", "-i", "aevalsrc=0.333333333+sin(n)*0.123456789|cos(n)*0.23232323:s=48000",
                                 "-af", "atrim=end_sample=\(frames)", "-c:a", sourceCodec, source.path], in: folder)
                let media = try Probe.read(source)
                let clip = try StillSoundtrack.reference(media: media)
                let format = StillTimelineFormat(width: 96, height: 64, cadence: t(1, 30), codec: .h264, container: "mov")
                let asset = StillAsset(id: "cover", file: "offline.png", displayName: "Cover", fingerprint: "offline")
                let insert = StillInsert(id: "hold", assetID: asset.id, duration: t(1), cadence: t(1, 30))
                let project = try CutProject.stillSequence(.init(items: [.still(insert)], stillAssets: [asset], stillFormat: format))
                    .attachingStillSoundtrack(clip).fittingStillToSoundtrack()
                let planner = StillSoundPlanner()
                let timeline = try project.resolveStills()
                let document = folder.appendingPathComponent("show.cut")
                let reference = folder.appendingPathComponent("source-\(sourceCodec).raw")
                try run(helper, ["-i", source.path, "-c:a", rawCodec, "-f", rawFormat, reference.path], in: folder)

                for (container, action) in [("mov", ReencodeAudio.alac), ("mp4", .flac), ("mkv", .flac), ("mov", .pcm)] {
                    func resolve() throws -> StillSoundPlan {
                        try planner.resolve(project, relativeTo: document, timeline: timeline, tracks: .audio,
                                            audioStream: nil, mode: .encode, audio: action, container: container,
                                            independentAudio: true)
                    }
                    if action != .pcm && sourceCodec != "pcm_s24le" {
                        XCTAssertThrowsError(try resolve()) {
                            XCTAssertEqual(($0 as? CutError)?.code, "unsupported_audio")
                            XCTAssertTrue(($0 as? CutError)?.message.contains("Choose PCM in MOV") == true)
                        }
                        continue
                    }
                    let plan = try resolve()
                    let staging = folder.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                    let written = try XCTUnwrap(planner.write(plan, in: staging).first)
                    let output = staging.appendingPathComponent("result.raw")
                    try run(helper, ["-i", written.path, "-c:a", rawCodec, "-f", rawFormat, output.path], in: staging)
                    XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: reference), "\(sourceCodec) to \(action) in \(container)")
                }
            }
        }
    }

    func testDefaultMOVKeepsFloatSoundtrackSamplesWhenPictureTrimsOrExtendsAudio() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("float.wav")
            try run(helper, ["-f", "lavfi", "-i", "aevalsrc=sin(n)/31|cos(n)/7:s=48000",
                             "-af", "atrim=end_sample=48001", "-c:a", "pcm_f32le", source.path], in: folder)
            let reference = folder.appendingPathComponent("source.raw")
            try run(helper, ["-i", source.path, "-c:a", "pcm_f32le", "-f", "f32le", reference.path], in: folder)
            let sourceSamples = try Data(contentsOf: reference)
            let clip = try StillSoundtrack.reference(media: Probe.read(source))
            let format = StillTimelineFormat(width: 96, height: 64, cadence: t(1, 30), codec: .h264, container: "mov")
            let planner = StillExportPlanner()
            for (duration, frames) in [(t(1, 2), 24_000), (t(2), 96_000)] {
                let project = try CutProject.makeStillTimeline(format: format, asset: .init(gapID: "gap"),
                                                               placementID: "hold", duration: duration)
                    .attachingStillSoundtrack(clip)
                let output = folder.appendingPathComponent("result-\(frames).mov")
                let plan = try planner.resolve(project, output: output, offerAlternatives: false)
                XCTAssertEqual(plan.report.soundActions.map(\.codec), ["pcm_f32le"])
                XCTAssertThrowsError(try planner.resolve(project, output: output, offerAlternatives: false, audioAction: .alac)) {
                    XCTAssertEqual(($0 as? CutError)?.code, "unsupported_audio")
                }
                try planner.write(plan, to: output)
                let raw = folder.appendingPathComponent("result-\(frames).raw")
                try run(helper, ["-i", output.path, "-c:a", "pcm_f32le", "-f", "f32le", raw.path], in: folder)
                let retained = sourceSamples.prefix(frames * 8)
                let expected = retained + Data(count: frames * 8 - retained.count)
                XCTAssertEqual(try Data(contentsOf: raw), expected)
            }
        }
    }

    func testDirectWAVEncodingUsesAnExactSampleClock() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("source.wav")
            try run(helper, ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=2",
                             "-c:a", "pcm_s24le", source.path], in: folder)
            let media = try Probe.read(source)
            let range = MulticamRange(from: .zero, to: t(2))
            let converter = MulticamEngine()
            let plan = try converter.resolveConvertedSound(
                [.init(media: media, stream: media.audio.first?.stream.index, input: range, output: range)],
                duration: range.to, container: "mov", action: .alac, preserveSamples: true) { issue, _ in issue }
            XCTAssertTrue(plan.inputs.first?.seekablePCM == true)
            let output = folder.appendingPathComponent("exact.mov")
            try converter.writeConvertedSound(plan, to: output)
            let sound = try XCTUnwrap(Probe.read(output).audio.first)
            XCTAssertEqual(sound.packets.dropFirst(15).first?.time, t(61_440, 44_100))
            XCTAssertEqual(sound.end, range.to)
        }
    }

    func testFractionalCutsPreserveWholeSamplesWithoutAccumulatingDrift() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("samples.wav")
            try run(helper, ["-f", "lavfi", "-i", "aevalsrc=n/128:s=44100", "-af", "atrim=end_sample=32",
                             "-c:a", "pcm_s24le", source.path], in: folder)
            // Each edit is 4/3 samples. Independent duration rounding would drop the second sample
            // from the middle edit. The middle edit's exact source start must stay fixed.
            let clips = [(1, 5), (9, 13), (1, 5)].enumerated().map { index, edges in
                CutSequenceClip(id: "clip-\(index)", file: source.lastPathComponent,
                                from: t(Int64(edges.0), 132_300), to: t(Int64(edges.1), 132_300))
            }
            let project = CutProject.sequence(clips)
            let planner = StillSoundPlanner()
            let plan = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                           timeline: project.resolveStills(), tracks: .audio, audioStream: nil,
                                           mode: .encode, audio: .alac, container: "mov", independentAudio: true)
            guard case .convert(let conversion) = plan.treatments.first else { return XCTFail("Expected lossless conversion") }
            XCTAssertEqual(conversion.inputs.map(\.count), [1, 2, 1])
            XCTAssertEqual(conversion.inputs.map(\.samples), [0..<1, 3..<5, 0..<1])
            XCTAssertTrue(plan.actions.first?.warnings.contains(where: { $0.contains("Fractional audio cuts") }) == true)
            let output = try XCTUnwrap(planner.write(plan, in: folder).first)
            let pcm = folder.appendingPathComponent("result.raw")
            try run(helper, ["-i", output.path, "-c:a", "pcm_s32le", "-f", "s32le", pcm.path], in: folder)
            let expected = [Int32(0), 3 << 24, 4 << 24, 0].map(\.littleEndian)
            XCTAssertEqual(try Data(contentsOf: pcm), expected.withUnsafeBytes { Data($0) })
        }
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

    func testMixStillInsertAndRecordingGapGiveEachLaneItsOwnTreatment() throws {
        try withDirectory { folder, helper in
            func recording(_ name: String, samples: Int) throws -> String {
                let file = folder.appendingPathComponent(name + ".wav")
                try run(helper, ["-f", "lavfi", "-i", "sine=r=48000",
                                 "-af", "atrim=end_sample=\(samples)", "-c:a", "pcm_s24le", file.path], in: folder)
                return file.lastPathComponent
            }
            let a = try MulticamSource(id: "a", file: recording("a", samples: 48_000), audioStream: 0)
            let second = try MulticamSource(id: "b2", file: recording("b2", samples: 12_000),
                                           offset: t(3, 4), audioStream: 0, coverage: .init(from: t(3, 4), to: t(1)))
            let b = try MulticamSource(id: "b", file: recording("b", samples: 12_000), audioStream: 0,
                                      coverage: .init(from: .zero, to: t(1, 4)), additionalRecordings: [second])
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let title = StillInsert(id: "insert", assetID: asset.id, duration: t(1, 10), cadence: t(1, 30))
            let project = CutProject.multicam(.init(
                referenceAngle: a.id, range: .init(from: .zero, to: t(1)), angles: [a, b], audio: .mix,
                switches: [.init(at: .zero, angle: a.id)],
                assemblyItems: [.group(.init(from: .zero, to: t(1))), .still(title)], stillAssets: [asset],
                mixLanes: [
                    .init(id: "mic-a", target: .camera(a.id), label: "Microphone A", colorSlot: 0),
                    .init(id: "mic-b", target: .camera(b.id), label: "Microphone B", colorSlot: 1),
                ]))
            let planner = StillExportPlanner()
            let document = folder.appendingPathComponent("show.cut")
            XCTAssertThrowsError(try planner.resolve(project, relativeTo: document, tracks: .audio, mode: .copy,
                                                     container: "mov", offerAlternatives: false)) {
                let issue = $0 as? CutError
                XCTAssertEqual(issue?.code, "generated_audio_required")
                XCTAssertEqual(issue?.laneID, "mic-a")
                XCTAssertTrue(issue?.message.contains("1–11/10") == true)
            }
            let plan = try planner.resolve(project, relativeTo: document, tracks: .audio, mode: .copy,
                                           container: "mov", audioAction: .auto)
            let actions = plan.report.soundActions
            XCTAssertEqual(actions.compactMap(\.laneID), ["mic-a", "mic-b"])
            XCTAssertEqual(actions.compactMap(\.codec), ["pcm_s24le", "pcm_s24le"])
            XCTAssertEqual(actions.compactMap(\.treatment), Array(repeating: "retained PCM samples + generated silence", count: 2))
            XCTAssertEqual(actions.map(\.generatedSilence), [
                [.init(from: t(1), to: t(11, 10))],
                [.init(from: t(1, 4), to: t(3, 4)), .init(from: t(1), to: t(11, 10))],
            ])
            let rendered = folder.appendingPathComponent("separate.mov")
            try planner.write(plan, to: rendered)
            XCTAssertEqual(try Probe.read(rendered).audio.map(\.end), [t(11, 10), t(11, 10)])

            let downmix = try planner.resolve(project, relativeTo: document, tracks: .audio, mode: .copy,
                                              container: "mov", audioOutput: .downmixMono, audioAction: .pcm)
            XCTAssertEqual(downmix.report.soundActions.compactMap(\.channelLayout), ["mono"])
            XCTAssertEqual(downmix.report.soundActions.first?.generatedSilence, [.init(from: t(1), to: t(11, 10))])
            let output = folder.appendingPathComponent("downmix.mov")
            try planner.write(downmix, to: output)
            XCTAssertEqual(try Probe.read(output).audio.first?.end, t(11, 10))

        }
    }

    func testMixStillExportDoesNotOpenReplacedOffAirScratch() throws {
        try withDirectory { folder, helper in
            let audio = folder.appendingPathComponent("replacement.wav")
            try run(helper, ["-f", "lavfi", "-i", "sine=r=48000:d=1", "-c:a", "pcm_s16le", audio.path], in: folder)
            let recorded = MulticamSource(id: "recorded", file: audio.lastPathComponent, audioStream: 0)
            let scratch = MulticamSource(id: "scratch", file: "unavailable.wav", audioStream: 0)
            let primary = MulticamSource(id: "main", file: audio.lastPathComponent)
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let title = StillInsert(id: "insert", assetID: asset.id, duration: t(1, 10), cadence: t(1, 30))
            let range = MulticamRange(from: .zero, to: t(1))
            var multicam = MulticamProject(referenceAngle: primary.id, range: range, angles: [primary, scratch],
                audioSources: [recorded], audio: .mix, switches: [.init(at: .zero, angle: primary.id)],
                assemblyItems: [.group(range), .still(title)], stillAssets: [asset],
                mixLanes: [.init(id: "selected", target: .camera(scratch.id), label: "Microphone", colorSlot: 0)],
                audioReplacements: [.init(id: "binding", original: .init(source: scratch.id, stream: 0),
                    replacement: .init(source: recorded.id, stream: 0), relativeOffset: .zero, uncovered: .leaveUncovered)])
            let planner = StillExportPlanner()
            let document = folder.appendingPathComponent("show.cut")
            let plan = try planner.resolve(multicam, relativeTo: document, tracks: .audio, mode: .copy,
                                           container: "mov", audioAction: .auto)
            XCTAssertEqual(plan.report.soundActions.first?.sources.map(\.file.lastPathComponent), [audio.lastPathComponent])
            let output = folder.appendingPathComponent("resolved.mov")
            try planner.write(plan, to: output)
            XCTAssertEqual(try Probe.read(output).audio.first?.end, t(11, 10))

            multicam.audioReplacements[0].uncovered = .keepOriginal
            _ = try planner.resolve(multicam, relativeTo: document, tracks: .audio, mode: .copy,
                                    container: "mov", audioAction: .auto)
            multicam.audioReplacements[0].relativeOffset = t(1, 4)
            XCTAssertThrowsError(try planner.resolve(multicam, relativeTo: document, tracks: .audio, mode: .copy,
                                                    container: "mov", offerAlternatives: false, audioAction: .auto)) {
                let issue = $0 as? CutError
                XCTAssertEqual(issue?.laneID, "selected")
                XCTAssertTrue(issue?.message.contains("0–1/4") == true)
            }
        }
    }

    func testStillPictureReplacementKeepsBoundPCMDeclaredLeadingDelay() throws {
        try withDirectory { folder, helper in
            let file = folder.appendingPathComponent("delayed.mov")
            try run(helper, ["-itsoffset", "0.125", "-f", "lavfi", "-i", "sine=r=48000:d=0.875",
                             "-c:a", "pcm_s16le", "-movie_timescale", "705600000", file.path], in: folder)
            let replacement = MulticamSource(id: "recorded", file: file.lastPathComponent, audioStream: 0)
            let original = MulticamSource(id: "scratch", file: "unavailable.wav", audioStream: 0)
            let range = MulticamRange(from: .zero, to: t(1))
            let asset = StillAsset(id: "still", file: "offline.png", displayName: "Still", fingerprint: "offline")
            let project = MulticamProject(referenceAngle: original.id, range: range, angles: [original],
                audioSources: [replacement], audio: .mix, switches: [.init(at: .zero, angle: original.id)],
                stillAssets: [asset], stillReplacements: [
                    .init(id: "cover", assetID: asset.id, coverage: .group(.init(from: t(1, 3), to: t(2, 3)))),
                ], mixLanes: [.init(id: "selected", target: .camera(original.id), label: "Microphone", colorSlot: 0)],
                audioReplacements: [.init(id: "binding", original: .init(source: original.id, stream: 0),
                    replacement: .init(source: replacement.id, stream: 0), relativeOffset: .zero, uncovered: .leaveUncovered)])
            let planner = StillExportPlanner()
            let document = folder.appendingPathComponent("show.cut")
            let plan = try planner.resolve(project, relativeTo: document, tracks: .audio, mode: .copy,
                                           container: "mov", audioAction: .copyOriginal)
            XCTAssertEqual(plan.report.soundActions.map(\.audio), [.copyOriginal])
            XCTAssertEqual(plan.report.soundActions.first?.generatedSilence, [])
            let output = folder.appendingPathComponent("sound.mov")
            try planner.write(plan, to: output)
            let track = try XCTUnwrap(CutEngine().inspectMulticamSource(output).audio.first)
            XCTAssertEqual(track.start, t(1, 8))
            XCTAssertEqual(track.end, t(1))
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

    func testConversionCanFillAnIntervalBeforeTheSelectedSoundBegins() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("offset.mov")
            try run(helper, ["-f", "lavfi", "-i", "color=s=96x64:r=30:d=2",
                             "-itsoffset", "1", "-f", "lavfi", "-i", "sine=r=48000:d=1",
                             "-map", "0:v", "-map", "1:a", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                             "-c:a", "pcm_s16le", source.path], in: folder)
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let clip = CutSequenceClip(id: "take", file: source.lastPathComponent, from: .zero, to: t(1, 2))
            let title = StillInsert(id: "insert", assetID: asset.id, duration: t(1, 2), cadence: t(1, 30))
            let project = CutProject.stillSequence(StillSequenceProject(items: [.source(clip), .still(title)], stillAssets: [asset]))
            let planner = StillSoundPlanner()
            let plan = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                           timeline: project.resolveStills(), tracks: .audio, audioStream: nil,
                                           mode: .encode, audio: .pcm, container: "mov")
            XCTAssertEqual(plan.actions.first?.generatedSilence, [MulticamRange(from: .zero, to: t(1, 2)),
                                                                  MulticamRange(from: t(1, 2), to: t(1))])
            let output = try XCTUnwrap(planner.write(plan, in: folder).first)
            let raw = folder.appendingPathComponent("silence.raw")
            try run(helper, ["-i", output.path, "-c:a", "pcm_s32le", "-f", "s32le", raw.path], in: folder)
            XCTAssertEqual(try Data(contentsOf: raw), Data(repeating: 0, count: 48_000 * 4))
        }
    }

    func testSmartSilencePreservesSamplesFromBigEndianPCM() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("recording.aiff")
            do {
                let recording = try AVAudioFile(forWriting: source, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true
                ], commonFormat: .pcmFormatInt16, interleaved: true)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: recording.processingFormat, frameCapacity: 4800))
                buffer.frameLength = 4800
                let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
                for index in 0..<4800 { samples[index] = Int16(index) - 2400 }
                try recording.write(from: buffer)
            }
            XCTAssertEqual(try Probe.read(source).audio.first?.stream.codec, "pcm_s16be")
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let title = StillInsert(id: "insert", assetID: asset.id, duration: t(1, 10), cadence: t(1, 30))
            let clip = CutSequenceClip(id: "take", file: source.lastPathComponent, from: .zero, to: t(1, 10))
            let project = CutProject.stillSequence(StillSequenceProject(items: [.still(title), .source(clip)], stillAssets: [asset]))
            let planner = StillSoundPlanner()
            let plan = try planner.resolve(project, relativeTo: folder.appendingPathComponent("show.cut"),
                                           timeline: project.resolveStills(), tracks: .audio, audioStream: nil,
                                           mode: .smart, audio: .auto, container: "mov")
            XCTAssertEqual(plan.actions.map(\.audio), [.pcm])
            let output = try XCTUnwrap(planner.write(plan, in: folder).first)
            XCTAssertEqual(try Probe.read(output).audio.first?.stream.codec, "pcm_s16le")
            let reference = folder.appendingPathComponent("reference.raw")
            let written = folder.appendingPathComponent("written.raw")
            for (input, raw) in [(source, reference), (output, written)] {
                try run(helper, ["-i", input.path, "-c:a", "pcm_s16le", "-f", "s16le", raw.path], in: folder)
            }
            let expected = try Data(repeating: 0, count: 4800 * 2) + Data(contentsOf: reference)
            XCTAssertEqual(try Data(contentsOf: written), expected)
        }
    }

    func testCombineRetainsEditLengthsWithIncompatibleStagingClocks() throws {
        try withDirectory { folder, helper in
            let first = folder.appendingPathComponent("first.mov")
            let second = folder.appendingPathComponent("second.mov")
            for (file, clock, samples) in [(first, 705_600_002, 24_000), (second, 705_600_003, 16_000)] {
                try run(helper, ["-f", "lavfi", "-i", "sine=r=48000",
                                 "-af", "atrim=end_sample=\(samples)", "-c:a", "aac",
                                 "-movie_timescale", "\(clock)", file.path], in: folder)
            }
            let output = folder.appendingPathComponent("program.mov")
            try MulticamMOV.combine(picture: nil, sounds: [first, second], output: output) { _ in }
            let inputs = try [first, second].map { try XCTUnwrap(Probe.read($0).audio.first) }
            let tracks = try Probe.read(output).audio
            XCTAssertEqual(tracks.map(\.start), [.zero, .zero])
            XCTAssertEqual(tracks.map(\.end), [t(1, 2), t(1, 3)])
            XCTAssertEqual(tracks.map { $0.presentationEdits.map(\.samples) },
                           inputs.map { $0.presentationEdits.map(\.samples) })
            XCTAssertEqual(tracks.map { $0.presentationEdits.map(\.isAudible) },
                           inputs.map { $0.presentationEdits.map(\.isAudible) })
        }
    }

    func testAutomaticConversionPreservesSideSpeakerLayoutWithPCM() throws {
        try withDirectory { folder, helper in
            let source = folder.appendingPathComponent("surround.mov")
            try run(helper, ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=5.1(side):d=1",
                             "-c:a", "pcm_s24le", source.path], in: folder)
            let asset = StillAsset(id: "title", file: "offline.png", displayName: "Title", fingerprint: "offline")
            let title = StillInsert(id: "insert", assetID: asset.id, duration: t(1, 10), cadence: t(1, 30))
            let clip = CutSequenceClip(id: "take", file: source.lastPathComponent, from: .zero, to: t(1))
            let project = CutProject.stillSequence(StillSequenceProject(items: [.still(title), .source(clip)], stillAssets: [asset]))
            let planner = StillSoundPlanner()
            let timeline = try project.resolveStills()
            let document = folder.appendingPathComponent("show.cut")
            XCTAssertThrowsError(try planner.resolve(project, relativeTo: document, timeline: timeline,
                tracks: .audio, audioStream: nil, mode: .encode, audio: .aac, container: "mov")) {
                XCTAssertEqual(($0 as? CutError)?.code, "unsupported_audio")
            }
            let plan = try planner.resolve(project, relativeTo: document, timeline: timeline,
                                           tracks: .audio, audioStream: nil, mode: .encode, audio: .auto, container: "mov")
            XCTAssertEqual(plan.actions.map(\.audio), [.pcm])
            let output = try XCTUnwrap(planner.write(plan, in: folder).first)
            let track = try XCTUnwrap(Probe.read(output).audio.first)
            XCTAssertEqual(track.stream.channelLayout, "5.1(side)")
            XCTAssertEqual(track.end, t(11, 10))
        }
    }
}
