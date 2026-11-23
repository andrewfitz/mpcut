import Foundation
import MPCutCore
import XCTest

final class MulticamAudioLaneTests: XCTestCase {
    private func t(_ value: Int64) -> RationalTime { .init(numerator: value) }
    private func r(_ from: Int64, _ to: Int64) -> MulticamRange { .init(from: t(from), to: t(to)) }

    private var multicam: MulticamProject {
        .init(referenceAngle: "a", range: r(0, 16),
              angles: [.init(id: "a", file: "a.mov", name: "Camera A", audioStream: 1),
                       .init(id: "b", file: "b.mov", offset: t(1), audioStream: 2, coverage: r(1, 7),
                             additionalRecordings: [.init(id: "b2", file: "b2.mov", offset: t(8),
                                                          audioStream: 3, coverage: r(8, 16))])],
              audioSources: [.init(id: "external", file: "external.wav", offset: t(42))],
              audio: .fixed(.init(source: "a", stream: 1)),
              switches: [.init(at: .zero, angle: "a", audio: .init(source: "b", stream: 2))])
    }

    func testCameraLanesRollIndependentlyAndKeepStableOrderAcrossAssembly() throws {
        var project = multicam
        project.mixLanes = project.defaultMixLanes.reversed()
        project.audio = .mix
        project.assembly = [r(5, 10), r(2, 3), r(8, 9)]
        let restored = try MulticamProject.decode(JSONEncoder().encode(project))
        let plan = try restored.plan()
        XCTAssertEqual(plan.picture.map(\.source), ["a", "a", "a"])
        XCTAssertTrue(plan.intervals.allSatisfy { $0.audio == nil })
        XCTAssertEqual(plan.audioLanes.map(\.id), ["camera:b", "camera:a"])
        XCTAssertEqual(plan.audioLanes.map(\.colorSlot), [1, 0])
        XCTAssertEqual(plan.audioLanes[1].label, "Camera A")
        XCTAssertEqual(plan.audioLanes[0].spans.map(\.source), ["b", "b2", "b", "b2"])
        XCTAssertEqual(plan.audioLanes[0].spans.map(\.input), [r(4, 6), r(0, 2), r(1, 2), r(0, 1)])
        XCTAssertEqual(plan.audioLanes[0].spans.map(\.output), [r(0, 2), r(3, 5), r(5, 6), r(6, 7)])
        XCTAssertEqual(plan.audioLanes[0].gaps, [r(2, 3)])
        XCTAssertEqual(plan.audioLanes[1].spans.map(\.input), [r(5, 10), r(2, 3), r(8, 9)])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        XCTAssertNil(json["audio"])
        XCTAssertNotNil(json["audio_lanes"])

        var toggled = restored
        toggled.audio = .follow
        XCTAssertEqual(toggled.switches, multicam.switches)
        XCTAssertEqual(toggled.fixedAudio, multicam.fixedAudio)
        toggled.audio = .mix
        XCTAssertEqual(try toggled.plan(), plan)

        toggled.mixLanes.append(.init(id: "duplicate", target: .recording(.init(source: "b2", stream: 3)),
                                      label: "Duplicate", colorSlot: 3))
        XCTAssertThrowsError(try toggled.validate())
    }

    func testReplacementShiftUsesRecordingClockAndRequiresAnIndex() throws {
        var project = multicam
        project.mixLanes = [project.defaultMixLanes[1]]
        project.audio = .mix
        project.audioReplacements = [
            .init(id: "second", original: .init(source: "b2", stream: 3), replacement: .init(source: "external", stream: 0),
                  relativeOffset: t(2), uncovered: .keepOriginal)
        ]
        let projectBytes = try JSONEncoder().encode(project)
        XCTAssertEqual(try MulticamProject.decode(projectBytes), project)
        let plan = try project.plan(ranges: [r(8, 16)])
        XCTAssertThrowsError(try project.resolveAudioLanes(plan: plan, indexedSources: [:])) {
            XCTAssertEqual(($0 as? CutError)?.laneID, "camera:b")
            XCTAssertEqual(($0 as? CutError)?.multicam?.output, r(0, 8))
        }
        let offline = try project.resolveAudioLanes(plan: plan, indexedSources: [:], unavailableAsGap: true)
        XCTAssertEqual(offline[0].unavailableSpans?.first?.source, "external")
        XCTAssertEqual(offline[0].gaps, [r(0, 8)])
        let provisional = try project.resolveAudioLanes(plan: plan, indexedSources: [:], assumeUnindexedCoverage: true)
        XCTAssertEqual(provisional[0].spans.first?.input, r(-2, 6))
        XCTAssertEqual(provisional[0].spans.first?.replacementBindingID, "second")
        XCTAssertEqual(project.requiredAudioSelections(for: plan), [.init(source: "b2", stream: 3), .init(source: "external", stream: 0)])
    }

    func testIndexedReplacementUsesOriginalAtUncoveredEdges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Two PCM recordings at 8 kHz, with the replacement covering two seconds.
        func sound(_ id: String, seconds: UInt32) throws -> MediaInfo {
            let byteCount = seconds * 8_000 * 2
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            append(UInt32(36) + byteCount)
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(8_000))
            append(UInt32(16_000))
            append(UInt16(2))
            append(UInt16(16))
            data.append(contentsOf: "data".utf8)
            append(byteCount)
            data.append(Data(repeating: 0, count: Int(byteCount)))
            let url = folder.appendingPathComponent(id).appendingPathExtension("wav")
            try data.write(to: url)
            return try CutEngine(useSidecar: false).inspectMulticamSource(url)
        }

        var project = multicam
        project.angles[1].additionalRecordings[0].audioStream = 0
        project.mixLanes = [project.defaultMixLanes[1]]
        project.audio = .mix
        project.audioReplacements = [
            .init(id: "second", original: .init(source: "b2", stream: 0), replacement: .init(source: "external", stream: 0),
                  relativeOffset: t(2), uncovered: .keepOriginal)
        ]
        let plan = try project.plan(ranges: [r(8, 16)])
        let media = try ["b2": sound("original", seconds: 8), "external": sound("replacement", seconds: 2)]
        let filled = try XCTUnwrap(project.resolveAudioLanes(plan: plan, indexedSources: media).first)
        XCTAssertEqual(filled.spans.map(\.source), ["b2", "external", "b2"])
        XCTAssertEqual(filled.spans.map(\.output), [r(0, 2), r(2, 4), r(4, 8)])
        XCTAssertEqual(filled.spans.map(\.input), [r(0, 2), r(0, 2), r(4, 8)])
        XCTAssertTrue(filled.gaps.isEmpty)

        project.audioReplacements[0].uncovered = .leaveUncovered
        let partial = try XCTUnwrap(project.resolveAudioLanes(plan: plan, indexedSources: media).first)
        XCTAssertEqual(partial.spans.map(\.replacementBindingID), ["second"])
        XCTAssertEqual(partial.gaps, [r(0, 2), r(4, 8)])
    }

    func testBoundSourcesCannotUseDirectGroupOffsets() throws {
        var project = multicam
        let external = MulticamAudioSelection(source: "external", stream: 0)
        project.audioReplacements = [
            .init(id: "first", original: .init(source: "b", stream: 2), replacement: external,
                  relativeOffset: t(2), uncovered: .leaveUncovered),
            .init(id: "second", original: .init(source: "b2", stream: 3), replacement: external,
                  relativeOffset: t(-1), uncovered: .leaveUncovered)
        ]
        XCTAssertNoThrow(try project.validate())

        var fixed = project
        fixed.audio = .fixed(external)
        XCTAssertThrowsError(try fixed.validate())
        fixed.audio = .follow
        XCTAssertThrowsError(try fixed.validate())

        var override = project
        override.switches[0].audio = external
        XCTAssertThrowsError(try override.validate())

        project.mixLanes = [.init(id: "pinned", target: .recording(external), label: "Direct", colorSlot: 0)]
        XCTAssertThrowsError(try project.validate())
        project.audioSources.append(.init(id: "direct", file: "external.wav"))
        project.mixLanes[0].target = .recording(.init(source: "direct", stream: 0))
        XCTAssertNoThrow(try project.validate())
    }

    func testV3PreservesFixedOverridesAndHistoryUntilExplicitV4Save() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edit.cut")
        let original = multicam
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        old["schema_version"] = 3
        old.removeValue(forKey: "fixed_audio")
        old["history"] = ["undo": [["action": "Fixed audio", "audio": ["mode": "follow"]]]]
        let v3 = try JSONSerialization.data(withJSONObject: old)
        try v3.write(to: url)
        let opened = try CutProject.loadDocument(from: url, limit: 10)
        XCTAssertEqual(opened.project, .multicam(original))
        XCTAssertEqual(try Data(contentsOf: url), v3)
        guard case .multicam(let follow) = opened.undo.first?.project else { return XCTFail("Expected Follow history state") }
        XCTAssertEqual(follow.audio, .follow)
        XCTAssertNil(follow.fixedAudio)

        var mix = original
        mix.mixLanes = original.defaultMixLanes
        mix.audio = .mix
        let undo = opened.undo + [CutHistoryState(action: "Mix", project: opened.project)]
        try CutProject.multicam(mix).save(to: url, undo: undo, redo: [])
        let reopened = try CutProject.loadDocument(from: url, limit: 10)
        XCTAssertEqual(reopened.project, .multicam(mix))
        XCTAssertEqual(reopened.undo, undo)
        var v4 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(v4["schema_version"] as? Int, 4)
        v4["schema_version"] = 3
        XCTAssertThrowsError(try CutProject.decode(JSONSerialization.data(withJSONObject: v4)))
    }
}
