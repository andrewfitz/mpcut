import SwiftUI

@MainActor
protocol EditorPlayback: ObservableObject {
    var isPlaying: Bool { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var scrubSoundEnabled: Bool { get set }
    func togglePlayback()
    func shuttle(_ direction: Int)
    func pause()
}

extension SequencePreview: EditorPlayback {}
extension MulticamPreview: EditorPlayback {}

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
        Button("Shuttle Reverse (J)") { preview.shuttle(-1) }
            .disabled(!canPlay)
        Button("Stop Shuttle (K)", action: preview.pause)
            .disabled(!canNavigate || !preview.isPlaying)
        Button("Shuttle Forward (L)") { preview.shuttle(1) }
            .disabled(!canPlay)
        Divider()
        Button("Go to Time…", action: enterTime).disabled(!canNavigate)
        Button("Go to Start") { seekBoundary(false) }.disabled(!canNavigate)
        Button("Go to End") { seekBoundary(true) }.disabled(!canNavigate)
        Button(audioOnly ? "Previous Audio Boundary" : "Previous Frame") { step(-1) }.disabled(!canStep)
        Button(audioOnly ? "Next Audio Boundary" : "Next Frame") { step(1) }.disabled(!canStep)
    }
}

struct EditorAudioCommands<Player: EditorPlayback>: View {
    @ObservedObject var preview: Player

    var body: some View {
        Toggle("Mute Preview Audio", isOn: $preview.isMuted)
        Button("Increase Preview Volume") { changeVolume(by: 0.1) }
            .disabled(preview.volume >= 1 && !preview.isMuted)
        Button("Decrease Preview Volume") { changeVolume(by: -0.1) }
            .disabled(preview.volume <= 0)
        Toggle("Play Audio While Scrubbing", isOn: $preview.scrubSoundEnabled)
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
        if let modifiers { button.keyboardShortcut(key, modifiers: modifiers) }
        else { button }
    }
}
