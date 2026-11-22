import SwiftUI

@MainActor
protocol EditorPlayback: ObservableObject {
    var isPlaying: Bool { get }
    var hasBlockingIssue: Bool { get }
    var playbackRate: Float { get }
    var forwardSpeed: PlaybackSpeed { get }
    func selectPlaybackSpeed(_ speed: PlaybackSpeed)
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var scrubSoundEnabled: Bool { get set }
    func togglePlayback()
    func shuttle(_ direction: Int)
    func pause()
}

extension EditorPlayback {
    var displayedSpeed: PlaybackSpeed { PlaybackSpeed(rawValue: playbackRate) ?? forwardSpeed }

    func adjacentSpeed(_ direction: Int) -> PlaybackSpeed? {
        let speeds = PlaybackSpeed.allCases
        guard let current = speeds.firstIndex(of: displayedSpeed),
              speeds.indices.contains(current + direction) else { return nil }
        return speeds[current + direction]
    }

    func changeSpeed(_ direction: Int) {
        if let speed = adjacentSpeed(direction) { selectPlaybackSpeed(speed) }
    }

    func handleSpeedKey(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "[": changeSpeed(-1)
        case "]": changeSpeed(1)
        case "\\": selectPlaybackSpeed(.normal)
        default: return false
        }
        return true
    }
}

extension SequencePreview: EditorPlayback {}
extension MulticamPreview: EditorPlayback {
    var hasBlockingIssue: Bool { false }
}

struct EditorTransportCommands<Player: EditorPlayback>: View {
    @ObservedObject var preview: Player
    let canNavigate: Bool
    let canStep: Bool
    let canPlay: Bool
    var audioOnly = false
    let enterTime: () -> Void
    let seekBoundary: (_ end: Bool) -> Void
    let step: (Int) -> Void

    var body: some View {
        Button(preview.isPlaying ? "Pause" : "Play", action: preview.togglePlayback)
            .disabled(!canPlay)
            .help(preview.isPlaying ? "Pause playback" : "Start playback")
        Button("Shuttle Reverse (J)") { preview.shuttle(-1) }
            .disabled(!canPlay)
            .help("Play backward")
        Button("Stop Shuttle (K)", action: preview.pause)
            .disabled(!canNavigate || !preview.isPlaying)
            .help("Stop shuttle")
        Button("Shuttle Forward (L)") { preview.shuttle(1) }
            .disabled(!canPlay)
            .help("Play forward")
        Button("Slower Playback ([)") { preview.changeSpeed(-1) }
            .disabled(!canPlay || preview.adjacentSpeed(-1) == nil)
            .help("Slow down playback")
        Button("Faster Playback (])") { preview.changeSpeed(1) }
            .disabled(!canPlay || preview.adjacentSpeed(1) == nil)
            .help("Speed up playback")
        Button("Normal Playback Speed (\\)") { preview.selectPlaybackSpeed(.normal) }
            .disabled(!canPlay)
            .help("Reset playback speed")
        Divider()
        Button("Go to Time…", action: enterTime).disabled(!canNavigate)
            .help("Enter playhead time")
        Button("Go to Start") { seekBoundary(false) }.keyboardShortcut(.home, modifiers: []).disabled(!canNavigate)
            .help("Jump to start")
        Button("Go to End") { seekBoundary(true) }.keyboardShortcut(.end, modifiers: []).disabled(!canNavigate)
            .help("Jump to end")
        Button(audioOnly ? "Previous Audio Boundary" : "Previous Frame") { step(-1) }.disabled(!canStep)
            .help(audioOnly ? "Previous audio boundary" : "Previous frame")
        Button(audioOnly ? "Next Audio Boundary" : "Next Frame") { step(1) }.disabled(!canStep)
            .help(audioOnly ? "Next audio boundary" : "Next frame")
    }
}

struct EditorAudioCommands<Player: EditorPlayback>: View {
    @ObservedObject var preview: Player

    var body: some View {
        Toggle("Mute Preview Audio", isOn: $preview.isMuted)
            .help("Mute preview audio")
        Button("Increase Preview Volume") { changeVolume(by: 0.1) }
            .disabled(preview.volume >= 1 && !preview.isMuted)
            .help("Raise preview volume")
        Button("Decrease Preview Volume") { changeVolume(by: -0.1) }
            .disabled(preview.volume <= 0)
            .help("Lower preview volume")
        Toggle("Play Audio While Scrubbing", isOn: $preview.scrubSoundEnabled)
            .help("Hear audio while scrubbing")
    }

    private func changeVolume(by delta: Float) {
        preview.volume = min(1, max(0, preview.volume + delta))
        preview.isMuted = false
    }
}

struct EditorBoundaryCommands: View {
    let name: String
    var modifiers: EventModifiers? = nil
    let enabled: Bool
    let step: (Int) -> Void

    var body: some View {
        Group {
            boundary(-1, label: "Previous " + name, key: .leftArrow)
            boundary(1, label: "Next " + name, key: .rightArrow)
        }
        .disabled(!enabled)
    }

    @ViewBuilder
    private func boundary(_ direction: Int, label: String, key: KeyEquivalent) -> some View {
        let button = Button(label) { step(direction) }
            .help(label)
        if let modifiers { button.keyboardShortcut(key, modifiers: modifiers) }
        else { button }
    }
}
