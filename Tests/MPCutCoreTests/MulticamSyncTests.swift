import XCTest
@testable import MPCutCore

final class MulticamSyncTests: XCTestCase {
    private func signal(_ count: Int) -> [Float] {
        var seed: UInt32 = 1234
        return (0..<count).map { _ in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Float(seed >> 16) / 65_535
        }
    }

    func testWaveformShiftUsesGroupOffsetAndChecksLaterWindows() throws {
        let reference = signal(5_000)
        let shift = 110
        let extraShift = 6
        let target = (0..<4_800).map { index in
            reference[index + shift + (index > 2_400 ? extraShift : 0)] * 0.6
        }
        let offset = RationalTime(numerator: 3)
        let matches = try MulticamSync.match(reference, target, referenceOffset: offset, baselines: [.zero])
        let expectedInitial = try offset.adding(RationalTime(numerator: Int64(shift), denominator: 50))
        let expectedLate = try offset.adding(RationalTime(numerator: Int64(shift + extraShift), denominator: 50))
        let first = try XCTUnwrap(matches.first)
        let last = try XCTUnwrap(matches.last)
        XCTAssertEqual(first.offset, expectedInitial)
        XCTAssertEqual(last.offset, expectedLate)
        XCTAssertGreaterThan(last.referenceTime.seconds - first.referenceTime.seconds, 30)
    }

    func testShortTakeMatchesBetweenReferenceWindows() throws {
        let reference = signal(8_000)
        let target = Array(reference[1_367..<1_567])
        let matches = try MulticamSync.match(reference, target, referenceOffset: .zero, baselines: [.zero])
        XCTAssertEqual(matches.first?.offset, RationalTime(numerator: 1_367, denominator: 50))
        XCTAssertEqual(matches.first?.referenceTime, RationalTime(numerator: 1_467, denominator: 50))
    }

    func testReferencePreprocessingCanBeReusedAcrossUnequalTargets() throws {
        let reference = signal(5_000)
        let shorter = Array(reference[150..<4_900])
        let longer = Array(repeating: Float(-1), count: 100) + reference
        let targets = [(shorter, RationalTime(numerator: 3)),
                       (longer, RationalTime(numerator: -2)),
                       (shorter, RationalTime(numerator: 3))]
        var matcher = MulticamSync.Matcher(reference)
        for (target, expected) in targets {
            let matches = try matcher.match(target, referenceOffset: .zero, baselines: [.zero],
                                            cancelled: { false })
            XCTAssertFalse(matches.isEmpty)
            XCTAssertTrue(matches.allSatisfy { $0.offset == expected })
        }
    }

    func testSilenceRepeatedPatternAndMissingBinsAreRejected() throws {
        let repeated = Array(repeating: [0.1, 0.8, 0.2, 0.9] as [Float], count: 800).flatMap { $0 }
        for signal in [repeated, Array(repeating: Float(0), count: 3_200),
                       Array(repeating: Float(-1), count: 3_200)] {
            XCTAssertTrue(try MulticamSync.match(signal, signal, referenceOffset: .zero, baselines: [.zero]).isEmpty)
        }
    }

    func testShortPeriodicRecordingIsRejectedEvenWithOnlyOneCandidate() throws {
        let repeating: [Float] = [0.1, 0.8, 0.2, 0.9]
        let reference = (0..<200).map { repeating[$0 % repeating.count] }
        let target = (0..<200).map { repeating[($0 + 1) % repeating.count] }
        let matches = try MulticamSync.match(reference, target, referenceOffset: .zero, baselines: [.zero])
        XCTAssertTrue(matches.isEmpty)
    }

    func testDraftSyncUsesNondefaultStreamsAndTheirPresentationStarts() throws {
        let candidates = [ProcessInfo.processInfo.environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg",
                          "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let ffmpeg = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Requires FFmpeg to build the multi-stream sync fixture.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func raw(_ basename: String, _ levels: [Float]) throws -> String {
            let url = dir.appendingPathComponent(basename)
            var samples: [Int16] = []
            for level in levels {
                let magnitude = Int16(800 + level * 24_000)
                for _ in 0..<80 { samples.append(magnitude); samples.append(-magnitude) }
            }
            try samples.withUnsafeBytes { try Data($0).write(to: url) }
            return url.path
        }
        func make(_ options: [String], at file: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + options + [file.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let levels = signal(1000)
        let scratch = try raw("scratch.raw", levels)
        let silence = try raw("quiet.raw", Array(repeating: 0, count: levels.count))
        let primaryIncoming = try raw("first.raw", Array(levels.dropFirst(50)))
        let selectedIncoming = try raw("selected.raw", Array(levels.dropFirst(100)))
        let cameraURL = dir.appendingPathComponent("camera.mov")
        let incomingURL = dir.appendingPathComponent("external.mov")
        let rawOptions = ["-f", "s16le", "-ar", "8000", "-ac", "1", "-i"]
        try make(["-f", "lavfi", "-i", "color=black:s=32x32:r=25:d=22"] +
                 rawOptions + [silence] + rawOptions + [scratch] +
                 ["-filter_complex", "[2:a]asetpts=PTS+1/TB[scratch]",
                  "-map", "0:v", "-map", "1:a", "-map", "[scratch]", "-c:v", "libx264",
                  "-preset", "ultrafast", "-threads", "1", "-c:a", "pcm_s16le"], at: cameraURL)
        try make(rawOptions + [primaryIncoming] + rawOptions + [selectedIncoming] +
                 ["-filter_complex", "[1:a]asetpts=PTS+0.5/TB[selected]",
                  "-map", "0:a", "-map", "[selected]", "-c:a", "pcm_s16le"], at: incomingURL)

        let cameraOffset = RationalTime(numerator: 7)
        let reference = MulticamSource(id: "close", file: cameraURL.path, offset: cameraOffset, audioStream: 1)
        let incoming = MulticamSource(id: "draft", file: incomingURL.path, audioStream: 0)
        let original = MulticamAudioSelection(source: reference.id, stream: 2)
        let project = MulticamProject(referenceAngle: "wide", range: .init(from: .zero, to: .init(numerator: 22)),
                                     angles: [.init(id: "wide", file: cameraURL.path), reference],
                                     audio: .fixed(original), switches: [.init(at: .zero, angle: "wide")])
        let engine = CutEngine(useSidecar: false)
        let scratchIndex = try engine.inspectMulticamSource(cameraURL)
        let incomingIndex = try engine.inspectMulticamSource(incomingURL)
        XCTAssertEqual(scratchIndex.audio.first { $0.stream.index == 2 }?.start, .init(numerator: 1))
        XCTAssertEqual(incomingIndex.audio.first { $0.stream.index == 1 }?.start, .init(numerator: 1, denominator: 2))
        let indexed = [reference.id: scratchIndex, incoming.id: incomingIndex]
        let selected = try MulticamSync.analyzeReplacement(project,
            request: .init(reference: original, source: incoming, stream: 1),
            relativeTo: nil, indexed: indexed, useSidecar: false)
        let aligned = try XCTUnwrap(selected.suggestions.first)
        XCTAssertEqual(selected.referenceSourceID, "close")
        XCTAssertEqual(selected.referenceAudioStream, 2)
        XCTAssertEqual(aligned.audioStream, 1)
        XCTAssertEqual(aligned.waveformOffset, RationalTime(numerator: 19, denominator: 2))
        XCTAssertEqual(aligned.drift, .zero)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalReport = try encoder.encode(selected)
        for stream in [2, 1] {
            let cached = try AudioAnalysis.scan(scratchIndex, stream: stream, useSidecar: false)
            let report = try MulticamSync.analyzeReplacement(project,
                request: .init(reference: original, source: incoming, stream: 1),
                relativeTo: nil, indexed: indexed, useSidecar: false, cachedReferenceWaveform: cached)
            // The completed scratch waveform is reusable. A waveform for a
            // different stream of the same file must fall back to decoding.
            XCTAssertEqual(try encoder.encode(report), originalReport)
        }

        let kept: [MulticamRange] = [.init(from: .init(numerator: 3), to: .init(numerator: 8)),
                                     .init(from: .init(numerator: 15), to: .init(numerator: 20))]
        let retained = try MulticamSync.analyzeReplacement(project,
            request: .init(reference: original, source: incoming, stream: 1, referenceRanges: kept),
            relativeTo: nil, indexed: indexed, useSidecar: false)
        let endEvidence = try XCTUnwrap(retained.suggestions.first)
        XCTAssertEqual(endEvidence.waveformOffset, aligned.waveformOffset)
        XCTAssertEqual(endEvidence.drift, .zero)
        XCTAssertTrue(endEvidence.matches.contains { kept[0].contains($0.referenceTime) })
        XCTAssertTrue(endEvidence.matches.contains { kept[1].contains($0.referenceTime) })

        let primary = try MulticamSync.analyzeReplacement(project,
            request: .init(reference: original, source: incoming, stream: 0),
            relativeTo: nil, indexed: indexed, useSidecar: false)
        XCTAssertEqual(primary.suggestions.first?.waveformOffset, RationalTime(numerator: 9))

        let relativeOffset = try XCTUnwrap(aligned.waveformOffset).subtracting(cameraOffset)
        let incomingTrack = try XCTUnwrap(incomingIndex.audio.first { $0.stream.index == 1 })
        let coverage = try MulticamSync.replacementCoverage(in: [.init(from: .zero, to: .init(numerator: 22))],
                                                             track: incomingTrack, relativeOffset: relativeOffset)
        XCTAssertEqual(coverage.incoming.from, .init(numerator: 3))
        XCTAssertEqual(coverage.incoming.to, .init(numerator: 21))
        XCTAssertEqual(coverage.uncovered, [.init(from: .zero, to: .init(numerator: 3)),
                                            .init(from: .init(numerator: 21), to: .init(numerator: 22))])

        XCTAssertThrowsError(try MulticamSync.confirmedProgramOffset(project: project, referenceSourceID: reference.id,
                                                                   track: incomingTrack, relativeOffset: relativeOffset))
        var coveredProgram = project
        coveredProgram.assembly = [.init(from: .init(numerator: 10), to: .init(numerator: 20))]
        XCTAssertEqual(try MulticamSync.confirmedProgramOffset(project: coveredProgram, referenceSourceID: reference.id,
                                                               track: incomingTrack, relativeOffset: relativeOffset),
                       aligned.waveformOffset)

        var bound = project
        bound.audioSources = [incoming]
        bound.audioReplacements = [.init(id: "binding", original: original,
                                         replacement: .init(source: incoming.id, stream: 1),
                                         relativeOffset: relativeOffset, uncovered: .keepOriginal)]
        let group = try MulticamSync.analyze(bound, relativeTo: nil, indexed: ["wide": scratchIndex, reference.id: scratchIndex],
                                             waveform: false, useSidecar: false)
        XCTAssertEqual(group.suggestions.map(\.sourceID), [reference.id])
    }

    func testDisjointRetainedRangesMatchOnlyInsideKeptMaterial() throws {
        let reference = signal(3_000)
        let ranges: [MulticamRange] = [.init(from: .zero, to: .init(numerator: 8)),
                                       .init(from: .init(numerator: 50), to: .init(numerator: 60))]
        var matcher = MulticamSync.Matcher(reference)
        var incoming = reference
        incoming.replaceSubrange(0..<400, with: repeatElement(0, count: 400))
        incoming.replaceSubrange(2_500..<3_000, with: repeatElement(0, count: 500))
        XCTAssertTrue(try matcher.match(incoming, referenceOffset: .zero, baselines: [.zero],
                                        referenceRanges: ranges, cancelled: { false }).isEmpty)
        incoming.replaceSubrange(0..<400, with: reference[0..<400])
        incoming.replaceSubrange(2_500..<3_000, with: reference[2_500..<3_000])
        let matches = try matcher.match(incoming, referenceOffset: .zero, baselines: [.zero],
                                        referenceRanges: ranges, cancelled: { false })
        XCTAssertTrue(matches.contains { ranges[0].contains($0.referenceTime) })
        XCTAssertTrue(matches.contains { ranges[1].contains($0.referenceTime) })
        XCTAssertTrue(matches.allSatisfy { match in ranges.contains { $0.contains(match.referenceTime) } })
    }

    func testManualSeedCanFindAnOtherwiseOutOfRangeMatch() throws {
        let reference = signal(4_000)
        let start = 2_100
        let incoming = Array(reference[start..<(start + 300)])
        XCTAssertTrue(try MulticamSync.match(reference, incoming, referenceOffset: .zero, baselines: [.zero]).isEmpty)
        let anchor = RationalTime(numerator: Int64(start), denominator: Int64(AudioWaveform.rate))
        let matches = try MulticamSync.match(reference, incoming, referenceOffset: .zero, baselines: [anchor])
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.allSatisfy { $0.offset == anchor })
    }

    func testWaveformMatchingChecksCancellation() {
        let recording = signal(3_000)
        XCTAssertThrowsError(try MulticamSync.match(recording, recording, referenceOffset: .zero,
                                                     baselines: [.zero], cancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
