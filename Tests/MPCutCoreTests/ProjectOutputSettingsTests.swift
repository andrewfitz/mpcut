import Foundation
import XCTest
@testable import MPCutCore

final class ProjectOutputSettingsTests: XCTestCase {
    func testStillOutputFormatChangePreservesTimelineDuration() throws {
        let duration = RationalTime(numerator: 1, denominator: 30)
        let format = StillTimelineFormat(width: 1920, height: 1080, cadence: duration, codec: .h264, container: "mov")
        let asset = StillAsset(id: "image", file: "image.png", displayName: "Image", fingerprint: "digest")
        let original = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: "still", duration: duration)
        let canvas = ParticipantCanvas(width: 1080, height: 1920, frameRate: .init(numerator: 60_000, denominator: 1001))

        let changed = try original.settingProjectOutputCanvas(canvas)

        XCTAssertEqual(changed.projectOutputSettings.canvas, canvas)
        XCTAssertEqual(changed.stillFormat?.cadence, .init(numerator: 1001, denominator: 60_000))
        XCTAssertEqual(changed.stillInserts.first?.cadence, changed.stillFormat?.cadence)
        XCTAssertEqual(changed.stillInserts.first?.usesExactDuration, true)
        XCTAssertEqual(try changed.stillTimelineDuration(), duration)
        XCTAssertNil(changed.participants.tileOutput)
        XCTAssertEqual(try CutProject.decode(JSONEncoder().encode(changed)), changed)
    }

    func testSelectingDefaultDimensionsAuthorsAnOutputCanvas() throws {
        let clip = CutSequenceClip(id: "clip", file: "clip.mov", from: .zero, to: .init(numerator: 3))
        let original = CutProject.sequence([clip])
        let changed = try original.settingProjectOutputCanvas(.init())

        XCTAssertFalse(original.requiresPictureProcessing)
        XCTAssertTrue(changed.requiresPictureProcessing)
        XCTAssertEqual(try changed.tileRenderPlan()?.canvas, ParticipantCanvas())
    }

    func testSoundtrackChangeRetainsTheChosenCanvas() throws {
        let clip = CutSequenceClip(id: "clip", file: "clip.mov", from: .zero, to: .init(numerator: 3))
        let canvas = ParticipantCanvas(width: 1280, height: 720)
        let silent = try CutProject.sequence([clip]).settingProjectOutputAudio(.init(mode: .silence), defaultCanvas: canvas)
        let restored = try silent.settingProjectOutputAudio(.init(mode: .program), defaultCanvas: .init())

        XCTAssertEqual(silent.projectOutputSettings.audio.mode, .silence)
        XCTAssertEqual(restored.projectOutputSettings.audio.mode, .program)
        XCTAssertEqual(restored.projectOutputSettings.canvas, canvas)
    }

    func testTreatmentsKeepTheRecordingCanvasUntilExplicitlyChanged() throws {
        let clip = CutSequenceClip(id: "clip", file: "clip.mov", from: .zero, to: .init(numerator: 3))
        var original = CutProject.sequence([clip])
        original.participants.people = [.init(id: "feed", name: "Feed", treatment: .init(mode: .blur))]
        XCTAssertTrue(original.requiresPictureProcessing)
        XCTAssertFalse(original.hasStoredOutputCanvas)

        let sourceCanvas = ParticipantCanvas(width: 640, height: 480, frameRate: .init(numerator: 25))
        let silent = try original.settingProjectOutputAudio(.init(mode: .silence), defaultCanvas: sourceCanvas)
        let covered = try original.settingProjectOutputPrivacy(.cover, defaultCanvas: sourceCanvas)
        XCTAssertEqual(silent.projectOutputSettings.canvas, sourceCanvas)
        XCTAssertEqual(covered.projectOutputSettings.canvas, sourceCanvas)

        let changed = try original.settingProjectOutputCanvas(.init())
        XCTAssertTrue(changed.hasStoredOutputCanvas)
        XCTAssertEqual(changed.participants.tileOutput?.canvas, ParticipantCanvas())
    }

    func testSourceDefaultsAndAtomicPatchUseNativeCanvasAndAudioValidation() throws {
        let clip = CutSequenceClip(id: "clip", file: "recording.mov", from: .zero, to: .init(numerator: 2))
        let project = CutProject.sequence([clip])
        let rate = RationalTime(numerator: 30_000, denominator: 1_001)
        let source = try XCTUnwrap(project.sourceOutputCanvas(width: 1279, height: 719, frameRate: rate))
        XCTAssertEqual(project.sourceOutputCanvas(width: 16_384, height: 8_192, frameRate: rate),
                       .init(width: 8192, height: 4096, frameRate: rate))
        let initial = ProjectOutputSettingsSnapshot(project: project, defaultCanvas: source)
        XCTAssertFalse(initial.hasStoredCanvas)
        XCTAssertEqual(initial.settings.canvas, .init(width: 1280, height: 720, frameRate: rate))
        XCTAssertEqual(initial.settings.audio.mode, .program)

        let edited = try project.settingProjectOutput(width: 960, height: nil, frameRate: nil, background: 0x123456,
                                                       audio: .init(mode: .silence), privacy: .cover, defaultCanvas: source)
        XCTAssertTrue(edited.hasStoredOutputCanvas)
        XCTAssertEqual(edited.projectOutputSettings.canvas, .init(width: 960, height: 720, frameRate: rate, background: 0x123456))
        XCTAssertEqual(edited.projectOutputSettings.audio.mode, .silence)
        XCTAssertEqual(edited.projectOutputSettings.unresolvedPrivacy, .cover)
        XCTAssertEqual(edited.sequenceClips, [clip])
        XCTAssertEqual(try CutProject.decode(JSONEncoder().encode(edited)), edited)
        XCTAssertThrowsError(try project.settingProjectOutput(width: 960, height: nil, frameRate: nil, background: nil,
                                                               audio: .init(mode: .follow, ids: ["missing"]), privacy: nil, defaultCanvas: source)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_project_output_audio")
        }
        XCTAssertEqual(try project.settingProjectOutput(width: nil, height: nil, frameRate: nil, background: nil,
                                                         audio: .init(mode: .program), privacy: .stop, defaultCanvas: source), project)
    }
}
