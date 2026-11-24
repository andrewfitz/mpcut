import AppKit
import AVFoundation
import XCTest
@testable import MPCutApp

/// MPCutTestSupport sets MPCUT_MUTED=1 as this bundle loads, so the tests run MPCut muted.
final class MutedTestRun: XCTestCase {
    func testMutedLaunchSilencesDeviceOutputsButKeepsOfflineRenders() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MPCUT_MUTED"] == "0", "An audible run was requested")
        XCTAssertTrue(MutedLaunch.isEnabled, "MPCut's tests must not be heard")

        let player = AVPlayer()
        player.volume = 0.8
        MutedLaunch.mute(player)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0.8, "The mute must leave the preview volume alone")

        let renderer = AVSampleBufferAudioRenderer()
        MutedLaunch.mute(renderer)
        XCTAssertTrue(renderer.isMuted)
        XCTAssertEqual(renderer.volume, 1)

        let device = AVAudioEngine()
        MutedLaunch.mute(device)
        XCTAssertEqual(device.mainMixerNode.outputVolume, 0)

        let offline = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try offline.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        MutedLaunch.mute(offline)
        XCTAssertEqual(offline.mainMixerNode.outputVolume, 1, "Tests read offline renders at full level")

        // The unhandled-key guard is installed without sending a key, which could beep if it were not.
        let method = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.noResponder(for:))))
        XCTAssertNotNil(imp_getBlock(method_getImplementation(method)), "A muted MPCut must drop the unhandled-key beep")
        NSResponder().noResponder(for: #selector(NSResponder.mouseDown(with:)))
    }
}
