import AppKit
import SwiftUI

struct EditorWorkspace<Viewer: View, Transport: View, Timeline: View, Status: View>: View {
    let viewer: Viewer
    let transport: Transport
    let timeline: Timeline
    let status: Status
    let showsTimeline: Bool
    let showsStatus: Bool
    var allowsTimelineResize = false

    var body: some View {
        VStack(spacing: 0) {
            if showsTimeline && allowsTimelineResize {
                VSplitView {
                    previewAndTransport
                    timeline
                }
            } else {
                previewAndTransport
                if showsTimeline {
                    Divider()
                    timeline
                }
            }
            if showsStatus {
                Divider()
                status
            }
        }
    }

    private var previewAndTransport: some View {
        VStack(spacing: 0) {
            viewer
                .frame(minHeight: 180, maxHeight: .infinity)
            if showsTimeline { transport }
        }
    }
}

struct EditorPreview<Content: View>: View {
    let accessibilityTitle: String
    let issue: String?
    let audioWarning: String?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .accessibilityLabel(accessibilityTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .bottomLeading) {
                if let audioWarning, issue == nil {
                    Label(audioWarning, systemImage: "speaker.slash.fill")
                        .modifier(PreviewNoticeStyle())
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let issue {
                    Label(issue, systemImage: "video.slash")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                        .modifier(PreviewNoticeStyle())
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A caption drawn over the picture. It stays dark in both appearances because the viewer is always black.
struct PreviewNoticeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14))
            }
            .environment(\.colorScheme, .dark)
    }
}

struct EditorStepAction {
    let enabled: Bool
    let step: (Int) -> Void
}

struct EditorEditAction {
    let title: String
    var enabled: Bool = true
    let perform: () -> Void
}

struct EditorMarkActions {
    let hasIn: Bool
    let hasOut: Bool
    let setIn: () -> Void
    let setOut: () -> Void
    let clear: () -> Void
}

struct TimelineRangeTools {
    @Binding var active: Bool
    let canAct: Bool
    let canSplit: Bool
    let canDelete: Bool
    let split: () -> Void
    let export: () -> Void
    let delete: () -> Void
}

struct EditorCameraAction: Identifiable {
    let id: String
    let number: Int
    let name: String
    let active: Bool
    let perform: () -> Void
}

struct EditorTransportBar<Player: EditorPlayback, Accessory: View>: View {
    enum Navigation {
        case picture(scenes: EditorStepAction, keyframes: EditorStepAction)
        case audio(pauses: EditorStepAction)
    }

    let navigation: Navigation
    let frames: EditorStepAction
    let canNavigate: Bool
    let canEdit: Bool
    let marks: EditorMarkActions
    var cameras: [EditorCameraAction] = []
    let addRange: EditorEditAction
    let split: EditorEditAction
    let delete: EditorEditAction
    let undo: EditorEditAction
    let redo: EditorEditAction
    let rangeTools: TimelineRangeTools
    let preview: Player
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Group {
            if cameras.isEmpty && !rangeTools.active {
                tools(compact: false)
            } else {
                ViewThatFits(in: .horizontal) {
                    tools(compact: false)
                    tools(compact: true)
                }
            }
        }
        .frame(height: 43)
        .background(.bar)
    }

    private func tools(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 10) {
            HStack(spacing: 4) {
                steps(-1)
                PreviewPlayButton(preview: preview)
                steps(1)
                PreviewSpeedMenu(preview: preview)
            }
            .disabled(!canNavigate)

            separator

            // Clear Marks keeps its place so the tools after it never shift.
            HStack(spacing: compact ? 2 : 4) {
                ClipTool(icon: "text.cursor", label: "Range Selection Tool", shortcut: "R",
                         active: rangeTools.active) { rangeTools.active.toggle() }
                    .accessibilityValue(rangeTools.active ? "On" : "Off")
                    .help("Drag to select a timeline range (R). Return to the pointer with A.")
                ClipTool(icon: nil, label: "Mark In", visibleTitle: compact ? "In" : nil,
                         shortcut: "I", active: marks.hasIn, action: marks.setIn)
                    .fixedSize(horizontal: true, vertical: false)
                ClipTool(icon: nil, label: "Mark Out", visibleTitle: compact ? "Out" : nil,
                         shortcut: "O", active: marks.hasOut, action: marks.setOut)
                    .fixedSize(horizontal: true, vertical: false)
                if !cameras.isEmpty {
                    separator.padding(.horizontal, compact ? 4 : 6)
                    if cameras.count > 4 || (compact && cameras.count > 2) {
                        ScrollView(.horizontal) { cameraButtons }
                            .frame(minWidth: compact ? 56 : 124, idealWidth: compact ? 56 : 124, maxWidth: 124)
                            .frame(height: 28)
                    } else {
                        cameraButtons.fixedSize()
                    }
                }
                ClipTool(icon: "xmark.circle", label: "Clear Marks", shortcut: "⌥X or Esc", action: marks.clear)
                    .disabled(!marks.hasIn && !marks.hasOut)
                editTool(addRange, icon: "text.badge.plus", shortcut: "⇧⌘A")
            }
            .disabled(!canEdit)

            separator

            HStack(spacing: 4) {
                if rangeTools.active {
                    ClipTool(icon: "scissors", label: "Split at Selection Edges", shortcut: "⌘B", action: rangeTools.split)
                        .disabled(!rangeTools.canSplit)
                    ClipTool(icon: "square.and.arrow.up", label: "Export Selection…", shortcut: "⌥⌘E", action: rangeTools.export)
                    ClipTool(icon: "trash", label: "Delete Selection", shortcut: "⌫", action: rangeTools.delete)
                        .disabled(!rangeTools.canDelete)
                } else {
                    editTool(split, icon: "scissors", shortcut: "⌘B", visibleTitle: compact ? nil : "Split")
                    editTool(delete, icon: "trash", shortcut: "⌫")
                }
            }
            .disabled(!canEdit || (rangeTools.active && !rangeTools.canAct))

            Spacer(minLength: 0)
            accessory
            HStack(spacing: 4) {
                editTool(undo, icon: "arrow.uturn.backward", shortcut: "⌘Z")
                editTool(redo, icon: "arrow.uturn.forward", shortcut: "⇧⌘Z")
            }
        }
        .padding(.horizontal, EditorMetrics.barInset - ClipTool.iconInset)
        .controlSize(compact ? .small : .regular)
    }

    private var separator: some View {
        Divider().frame(height: 18)
    }

    private var cameraButtons: some View {
        HStack(spacing: 4) {
            ForEach(cameras) { camera in
                ClipTool(icon: nil, label: "Camera \(camera.number), \(camera.name)",
                         visibleTitle: camera.number.formatted(), shortcut: camera.number <= 9 ? String(camera.number) : "",
                         active: camera.active, outlined: true, action: camera.perform)
            }
        }
    }

    @ViewBuilder private func steps(_ direction: Int) -> some View {
        if direction < 0 { boundaryStep(direction) }
        if case let .picture(_, keys) = navigation, direction < 0 {
            stepTool(keys, direction: direction, symbol: "end.fill", unit: "Keyframe", modifiers: "⌥")
        }
        stepTool(frames, direction: direction, symbol: "frame", unit: frameUnit)
        if case let .picture(_, keys) = navigation, direction > 0 {
            stepTool(keys, direction: direction, symbol: "end.fill", unit: "Keyframe", modifiers: "⌥")
        }
        if direction > 0 { boundaryStep(direction) }
    }

    private var frameUnit: String {
        if case .audio = navigation { return "Audio Boundary" }
        return "Frame"
    }

    @ViewBuilder private func boundaryStep(_ direction: Int) -> some View {
        switch navigation {
        case let .picture(scenes, _):
            stepTool(scenes, direction: direction, symbol: "end.alt", unit: "Scene", modifiers: "⇧")
        case let .audio(pauses):
            stepTool(pauses, direction: direction, symbol: "end.alt", unit: "Pause", modifiers: "⌃⌥")
        }
    }

    private func stepTool(_ action: EditorStepAction, direction: Int, symbol: String,
                          unit: String, modifiers: String = "") -> some View {
        let backward = direction < 0
        return ClipTool(icon: "\(backward ? "backward" : "forward").\(symbol)",
                        label: "\(backward ? "Previous" : "Next") \(unit)",
                        shortcut: modifiers + (backward ? "←" : "→")) {
            action.step(direction)
        }
        .disabled(!action.enabled)
    }

    private func editTool(_ action: EditorEditAction, icon: String, shortcut: String,
                          visibleTitle: String? = nil) -> some View {
        ClipTool(icon: icon, label: action.title, visibleTitle: visibleTitle,
                 shortcut: shortcut, action: action.perform)
            .disabled(!action.enabled)
    }
}

struct EditorStatusBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, EditorMetrics.barInset)
        .frame(height: 32)
        .background(.bar)
    }
}

/// Shared insets so the bars, the timeline header, and the ruler start on one vertical line.
enum EditorMetrics {
    /// Matches the timeline surface's own leading margin.
    static let barInset: CGFloat = 16
    static let sheetPadding: CGFloat = 20
    static let cornerRadius: CGFloat = 6
}

func progressPercent(_ fraction: Double) -> String {
    min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(0)))
}

struct StatusBarDivider: View {
    var body: some View {
        Divider().frame(height: 14)
    }
}

/// A compact icon button for the status bar and the timeline header.
struct StatusIconButton: View {
    let title: String
    let symbol: String
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(ToolButtonStyle())
        .accessibilityLabel(title)
        .help(help ?? title)
    }
}

struct EditorToolbarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }
    }
}

/// The queue button shows its count only when there is something to export.
struct ExportQueueToolbarButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(count == 0 ? "Queue" : "Queue (\(count))", systemImage: "list.number")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        .help("Review and export queued ranges (⇧⌘E)")
    }
}

struct EditorKeyboardMonitor: NSViewRepresentable {
    let handle: (NSEvent, NSEvent.ModifierFlags) -> NSEvent?

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handle = handle
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var handle: ((NSEvent, NSEvent.ModifierFlags) -> NSEvent?)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow, window.attachedSheet == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl),
                      let handle = self.handle else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                return handle(event, modifiers)
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct PreviewSoundControls: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool
    @Binding var scrubSoundEnabled: Bool
    @State private var showVolume = false

    private var isSilent: Bool { isMuted || volume == 0 }

    var body: some View {
        Button {
            showVolume.toggle()
        } label: {
            Label {
                Text("Preview Audio")
            } icon: {
                if isSilent {
                    Image(systemName: "speaker.slash.fill")
                } else {
                    Image(systemName: "speaker.wave.3.fill", variableValue: Double(volume))
                }
            }
        }
        .help("Preview volume, mute, and audio scrubbing")
        .popover(isPresented: $showVolume, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button { isMuted.toggle() } label: {
                        Image(systemName: isSilent ? "speaker.slash.fill" : "speaker.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(ToolButtonStyle(active: isMuted))
                    .accessibilityLabel(isMuted ? "Unmute preview" : "Mute preview")
                    .help(isMuted ? "Unmute preview" : "Mute preview")
                    Slider(value: Binding(get: { volume }, set: {
                        volume = $0
                        isMuted = false
                    }), in: 0...1)
                    .accessibilityLabel("Preview volume")
                    Text(progressPercent(Double(isMuted ? 0 : volume)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Divider()
                Toggle("Play audio while scrubbing", isOn: $scrubSoundEnabled)
            }
            .padding(16)
            .frame(width: 264)
        }
    }
}

struct PreviewPlayButton<Player: EditorPlayback>: View {
    @ObservedObject var preview: Player

    var body: some View {
        ClipTool(icon: preview.isPlaying ? "pause.fill" : "play.fill",
                 label: preview.isPlaying ? "Pause" : "Play",
                 shortcut: "Space · J / K / L", prominent: true, action: preview.togglePlayback)
            .disabled(preview.hasBlockingIssue)
    }
}

struct PreviewSpeedMenu<Player: EditorPlayback>: View {
    @ObservedObject var preview: Player

    var body: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { preview.displayedSpeed },
                                                       set: preview.selectPlaybackSpeed)) {
                ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                    Text(speed.label).tag(speed)
                }
            }
        } label: {
            Text(preview.playbackRate < 0 ? PlaybackSpeed.label(for: preview.playbackRate) : preview.displayedSpeed.label)
                .monospacedDigit()
        }
        .fixedSize()
        .accessibilityLabel("Playback Speed")
        .help("Playback speed · [ slower · ] faster · backslash normal")
        .disabled(preview.hasBlockingIssue)
    }
}

/// Tool chrome with hover, pressed, and selected states.
struct ToolButtonStyle: ButtonStyle {
    var active = false
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, active: active, outlined: outlined)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let active: Bool
        let outlined: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .opacity(isEnabled ? 1 : 0.32)
                .background(background, in: RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous))
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous)
                            .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.24), lineWidth: active ? 2 : 1)
                            .opacity(isEnabled ? 1 : 0.32)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var background: Color {
            guard isEnabled else { return active ? Color.accentColor.opacity(0.10) : .clear }
            if active { return Color.accentColor.opacity(configuration.isPressed ? 0.32 : hovering ? 0.26 : 0.20) }
            if configuration.isPressed { return Color.primary.opacity(0.16) }
            return hovering ? Color.primary.opacity(0.08) : .clear
        }
    }
}

struct ClipTool: View {
    @Environment(\.controlSize) private var controlSize

    /// The space between a 28-point icon button's edge and its glyph.
    static let iconInset: CGFloat = 7

    let icon: String?
    let label: String
    var visibleTitle: String? = nil
    let shortcut: String
    var active = false
    var prominent = false
    var outlined = false
    let action: () -> Void

    var body: some View {
        let title = visibleTitle ?? (icon == nil ? label : nil)
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: prominent ? 15 : 13, weight: .medium))
                }
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, title == nil ? 0 : 8)
            .frame(minWidth: controlSize == .small ? 24 : 28, minHeight: 28)
        }
        .buttonStyle(ToolButtonStyle(active: active, outlined: outlined))
        .help(shortcut.isEmpty ? label : "\(label) (\(shortcut))")
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

struct EditorMediaDrop: ViewModifier {
    let enabled: Bool
    let importFiles: ([URL]) -> Void
    @State private var isTargeted = false
    @Environment(\.openDroppedProjects) private var openDroppedProjects

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                if files.count > 1, files.contains(where: { $0.pathExtension.lowercased() == "csv" }) { return false }
                // A project opens the way File → Open does, also while this editor is busy.
                let media = openDroppedProjects(files)
                if enabled, !media.isEmpty { importFiles(media) }
                return media.count < files.count || (enabled && !media.isEmpty)
            } isTargeted: {
                isTargeted = $0
            }
    }
}
