import AppKit
import AVFoundation
import ObjectiveC

/// Launching with `MPCUT_MUTED=1` silences every MPCut audio output and alert sound, so tests and
/// agents can drive the app without being heard. Players keep decoding and advancing their clocks.
/// The mute is separate from the preview's volume and mute settings, which keep their saved values.
/// Without the variable, MPCut sounds as usual.
enum MutedLaunch {
    /// Read once, at launch or on first use.
    static let isEnabled: Bool = {
        let muted = ProcessInfo.processInfo.environment["MPCUT_MUTED"] == "1"
        if muted { quietUnhandledKeys() }
        return muted
    }()

    /// Call at launch so a muted app also drops AppKit's unhandled-key beep from the start.
    static func activate() { _ = isEnabled }

    static func mute(_ player: AVPlayer) {
        if isEnabled { player.isMuted = true }
    }

    static func mute(_ renderer: AVSampleBufferAudioRenderer) {
        if isEnabled { renderer.isMuted = true }
    }

    /// Call before starting an engine. An offline (manual rendering) engine has no output device
    /// and keeps its full level, so its rendered samples can still be read.
    static func mute(_ engine: AVAudioEngine) {
        if isEnabled, !engine.isInManualRenderingMode { engine.mainMixerNode.outputVolume = 0 }
    }

    static func beep() {
        if !isEnabled { NSSound.beep() }
    }

    /// AppKit plays its alert through the system sound server when a key event reaches the end of
    /// the responder chain. When muted, such an event is dropped quietly. Other
    /// `noResponder(for:)` calls keep AppKit's behaviour.
    private static func quietUnhandledKeys() {
        let selector = #selector(NSResponder.noResponder(for:))
        guard let method = class_getInstanceMethod(NSResponder.self, selector) else { return }
        typealias Implementation = @convention(c) (NSResponder, Selector, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        let keyDown = #selector(NSResponder.keyDown(with:))
        let quiet: @convention(block) (NSResponder, Selector) -> Void = { responder, eventSelector in
            if eventSelector != keyDown { original(responder, selector, eventSelector) }
        }
        method_setImplementation(method, imp_implementationWithBlock(quiet))
    }
}
