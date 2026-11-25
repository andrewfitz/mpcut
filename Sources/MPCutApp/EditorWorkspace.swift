import AppKit
import SwiftUI

struct EditorWorkspace<Viewer: View, Transport: View, Timeline: View, Status: View, Sidebar: View>: View {
    let viewer: Viewer
    let transport: Transport
    let timeline: Timeline
    let status: Status
    let showsTimeline: Bool
    let showsStatus: Bool
    var allowsTimelineResize = false

    var showsSidebar = false
    @ViewBuilder let sidebar: () -> Sidebar
    let preferences: EditorPreferences
    // Follows the shared preference without redrawing the workspace for every other setting.
    @State private var fullHeight: Bool
    @State private var panelWidth: CGFloat = 440

    init(viewer: Viewer, transport: Transport, timeline: Timeline, status: Status, preferences: EditorPreferences,
         showsTimeline: Bool, showsStatus: Bool, allowsTimelineResize: Bool = false,
         showsSidebar: Bool = false, @ViewBuilder sidebar: @escaping () -> Sidebar = { EmptyView() }) {
        self.preferences = preferences
        _fullHeight = State(initialValue: preferences.fullHeightSidebar)
        self.viewer = viewer
        self.transport = transport
        self.timeline = timeline
        self.status = status
        self.showsTimeline = showsTimeline
        self.showsStatus = showsStatus
        self.allowsTimelineResize = allowsTimelineResize
        self.showsSidebar = showsSidebar
        self.sidebar = sidebar
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if showsSidebar && fullHeight {
                    split { editingArea }
                } else {
                    editingArea
                }
            }
            // Both dock positions use the same reader, preserving search, selection and scroll state.
            .overlayPreferenceValue(PanelBounds.self) { anchor in
                if showsSidebar {
                    GeometryReader { proxy in
                        let rect = anchor.map { proxy[$0] } ?? .zero
                        sidebar()
                            .frame(width: rect.width, height: rect.height)
                            .clipped()
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            if showsStatus {
                Divider()
                status
            }
        }
        .onReceive(preferences.$fullHeightSidebar) { if fullHeight != $0 { fullHeight = $0 } }
    }

    @ViewBuilder private var editingArea: some View {
        if showsTimeline && allowsTimelineResize {
            VSplitView {
                previewAndTransport
                timeline
            }
        } else {
            VStack(spacing: 0) {
                previewAndTransport
                if showsTimeline {
                    Divider()
                    timeline
                }
            }
        }
    }

    private func split<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HSplitView {
            content().frame(minWidth: 360, maxWidth: .infinity)
            PanelWidthBinding(width: $panelWidth)
                .frame(minWidth: 330, idealWidth: 440, maxWidth: 680)
                .anchorPreference(key: PanelBounds.self, value: .bounds) { $0 }
        }
    }

    private var previewAndTransport: some View {
        VStack(spacing: 0) {
            Group {
                if showsSidebar && !fullHeight {
                    split { viewer }
                } else {
                    viewer
                }
            }
                .frame(minHeight: 180, maxHeight: .infinity)
            if showsTimeline { transport }
        }
    }
}

private struct PanelBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Apply the requested width once per split, then remember native divider drags.
private struct PanelWidthBinding: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.width = $width }

    final class Probe: NSView {
        var width: Binding<CGFloat>?
        private weak var initializedSplit: NSSplitView?

        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in self?.sync() }
        }

        private func sync() {
            guard window != nil, let width,
                  let split = sequence(first: self as NSView, next: { $0.superview })
                    .compactMap({ $0 as? NSSplitView }).first(where: { $0.isVertical }),
                  split.arrangedSubviews.count == 2, split.bounds.width > 0 else { return }
            if initializedSplit !== split {
                initializedSplit = split
                let position = split.bounds.width - split.dividerThickness - width.wrappedValue
                split.setPosition(min(split.maxPossiblePositionOfDivider(at: 0),
                                      max(split.minPossiblePositionOfDivider(at: 0), position)), ofDividerAt: 0)
            } else if let size = split.arrangedSubviews.last?.frame.width, size >= 330, abs(width.wrappedValue - size) > 0.5 {
                width.wrappedValue = size
            }
        }
    }
}

struct PanelDockToggle: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        let fullHeight = preferences.fullHeightSidebar
        PaneIconButton(title: "Full-height panel", symbol: "arrow.up.and.down", active: fullHeight,
                       help: fullHeight ? "Tuck panel above timeline" : "Extend panel beside timeline") {
            preferences.fullHeightSidebar.toggle()
        }
        .accessibilityValue(fullHeight ? "On" : "Off")
        .accessibilityIdentifier("editor.fullHeightPanel")
    }
}

struct EditorPreview<Content: View>: View {
    let accessibilityTitle: String
    let issue: String?
    let audioWarning: String?
    /// Pictures the preview omitted, such as after a damaged picture. Playback goes on.
    var pictureNotice: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .accessibilityLabel(accessibilityTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .bottomLeading) {
                if issue == nil && (audioWarning != nil || pictureNotice != nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let pictureNotice {
                            Label(pictureNotice, systemImage: "exclamationmark.triangle.fill")
                                .modifier(PreviewNoticeStyle())
                                .accessibilityIdentifier("preview.pictureNotice")
                        }
                        if let audioWarning {
                            Label(audioWarning, systemImage: "speaker.slash.fill")
                                .modifier(PreviewNoticeStyle())
                        }
                    }
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
        ViewThatFits(in: .horizontal) {
            tools(compact: false)
            tools(compact: true)
            VStack(spacing: 4) {
                HStack {
                    playback
                    Spacer(minLength: 0)
                    accessory
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        markTools(compact: true)
                        separator
                        editTools(compact: true)
                        Spacer(minLength: 0)
                        history
                    }
                    VStack(spacing: 4) {
                        HStack {
                            markTools(compact: true)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            editTools(compact: true)
                            Spacer(minLength: 0)
                            history
                        }
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 43)
        .background(.bar)
    }

    private func tools(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 5) {
            playback
            separator
            markTools(compact: compact)
            separator
            editTools(compact: compact)
            Spacer(minLength: 0)
            accessory
            history
        }
        .padding(.horizontal, EditorMetrics.barInset - ClipTool.iconInset)
        .controlSize(compact ? .small : .regular)
    }

    private var playback: some View {
        HStack(spacing: 3) {
            steps(-1)
            PreviewPlayButton(preview: preview)
            steps(1)
            PreviewSpeedMenu(preview: preview)
        }
        .disabled(!canNavigate)
    }

    private func markTools(compact: Bool) -> some View {
        // Clear Marks keeps its place so the tools after it never shift.
        HStack(spacing: compact ? 2 : 4) {
            ClipTool(icon: "text.cursor", label: "Range Selection Tool", shortcut: "R",
                     toolTip: rangeTools.active ? "Use pointer (A)" : "Select range (R)",
                     active: rangeTools.active) { rangeTools.active.toggle() }
                .accessibilityValue(rangeTools.active ? "On" : "Off")
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
            editTool(addRange, icon: "text.badge.plus", shortcut: "⇧⌘A",
                     toolTip: "Queue marked range (⇧⌘A)")
        }
        .disabled(!canEdit)
    }

    private func editTools(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if rangeTools.active {
                ClipTool(icon: "scissors", label: "Split at Selection Edges", shortcut: "⌘B", action: rangeTools.split)
                    .disabled(!rangeTools.canSplit)
                ClipTool(icon: "square.and.arrow.up", label: "Export Selection…", shortcut: "⌥⌘E", action: rangeTools.export)
                ClipTool(icon: "trash", label: "Delete Selection", shortcut: "⌫", action: rangeTools.delete)
                    .disabled(!rangeTools.canDelete)
            } else {
                editTool(split, icon: "scissors", shortcut: "⌘B", visibleTitle: compact ? nil : "Split")
                    .fixedSize(horizontal: true, vertical: false)
                editTool(delete, icon: "trash", shortcut: "⌫")
            }
        }
        .disabled(!canEdit || (rangeTools.active && !rangeTools.canAct))
    }

    private var history: some View {
        HStack(spacing: 4) {
            editTool(undo, icon: "arrow.uturn.backward", shortcut: "⌘Z")
                .accessibilityIdentifier("editor.history.undo")
            editTool(redo, icon: "arrow.uturn.forward", shortcut: "⇧⌘Z")
                .accessibilityIdentifier("editor.history.redo")
        }
    }

    private var separator: some View {
        Divider().frame(height: 18)
    }

    private var cameraButtons: some View {
        HStack(spacing: 4) {
            ForEach(cameras) { camera in
                let shortcut = camera.number <= 9 ? String(camera.number) : ""
                let action = "Take camera \(camera.number)"
                ClipTool(icon: nil, label: "Take camera \(camera.number), \(camera.name), at group time",
                         visibleTitle: camera.number.formatted(), shortcut: shortcut,
                         toolTip: shortcut.isEmpty ? action : "\(action) (\(shortcut))",
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
                          visibleTitle: String? = nil, toolTip: String? = nil) -> some View {
        ClipTool(icon: icon, label: action.title, visibleTitle: visibleTitle,
                 shortcut: shortcut, toolTip: toolTip, action: action.perform)
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
        // Bar controls carry their own inset, so their glyphs start on the timeline header's line.
        .padding(.horizontal, EditorMetrics.barInset - EditorMetrics.barControlInset)
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
    /// The inset, rounded frame around lists and previews inside sheets.
    static let panelRadius: CGFloat = 8
    /// Text controls in the status bar and the timeline header.
    static let barControlHeight: CGFloat = 22
    static let barControlInset: CGFloat = 6
    /// Square icon controls in the timeline header and the side panes.
    static let paneControl: CGFloat = 24
    /// Leading and trailing inset of a side pane's header, body and footer.
    static let paneInset: CGFloat = 14
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
    let toolTip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }
        .help(toolTip)
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
        .help("Open export queue (⇧⌘E)")
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
        .help("Show preview audio controls")
        .popover(isPresented: $showVolume, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button { isMuted.toggle() } label: {
                        Image(systemName: isSilent ? "speaker.slash.fill" : "speaker.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(ToolButtonStyle(active: isMuted))
                    .accessibilityLabel(isMuted ? "Unmute preview audio" : "Mute preview audio")
                    .help(isMuted ? "Unmute preview audio" : "Mute preview audio")
                    Slider(value: Binding(get: { volume }, set: {
                        volume = $0
                        isMuted = false
                    }), in: 0...1)
                    .accessibilityLabel("Preview volume")
                    .help("Adjust preview volume")
                    Text(progressPercent(Double(isMuted ? 0 : volume)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Divider()
                Toggle("Play audio while scrubbing", isOn: $scrubSoundEnabled)
                    .help("Hear audio while scrubbing")
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
            .pickerStyle(.inline)
            .labelsHidden()
            .help("Set playback speed")
        } label: {
            Text(preview.playbackRate < 0 ? PlaybackSpeed.label(for: preview.playbackRate) : preview.displayedSpeed.label)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .barMenu()
        .accessibilityLabel("Playback Speed")
        .help("Choose playback speed")
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
                .foregroundStyle(.primary)
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
    var toolTip: String? = nil
    var active = false
    var prominent = false
    var outlined = false
    let action: () -> Void

    var body: some View {
        let title = visibleTitle ?? (icon == nil ? label : nil)
        // A tool is used by hand. The multicam editor asks after its edits. The file editor's actions arm themselves.
        Button(action: { MulticamTierGate.byHand(action) }) {
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
        .help(toolTip ?? (shortcut.isEmpty ? label : "\(label) (\(shortcut))"))
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
