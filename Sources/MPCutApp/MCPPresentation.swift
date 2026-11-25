import AppKit
import Combine
import CoreFoundation
import MPCutCore

@MainActor
final class TranscriptReaderPresentation: ObservableObject {
    @Published var followsPlayback = true
}

/// Per-window state shared by the visible controls and local commands.
@MainActor
final class EditorPresentation: ObservableObject {
    enum Inspector: String, CaseIterable {
        case switches, sources, assembly, export, transcript, participants

        var label: String {
            switch self {
            case .switches: "Switch"
            case .participants: "Tiles"
            default: rawValue.capitalized
            }
        }
    }
    let transcriptReader = TranscriptReaderPresentation()
    @Published var cutSectionsHidden = false
    @Published var inspector: Inspector = .switches
    @Published var inspectorVisible = true
    @Published var sequenceTranscriptVisible = false
    @Published var sequenceParticipantsVisible = false
    @Published var pinnedParticipant: String?
    @Published var pickedParticipantAppearance: ParticipantPickedAppearance?
    @Published var requestedParticipantTileEditor: ParticipantPickedAppearance?
    @Published var participantMonitorSource = false {
        didSet {
            guard oldValue != participantMonitorSource else { return }
            participantMonitorSourceChanged?(participantMonitorSource)
            if !participantMonitorSource { participantDrawMode = false }
        }
    }
    var participantMonitorSourceChanged: ((Bool) -> Void)?
    @Published var participantTileExtent: ParticipantTileEditExtent = .untilChange
    @Published var participantDrawMode = false
    @Published var participantScanPreview: ParticipantPendingTilePreview?
    @Published var participantDrawnBounds: ParticipantDrawnBounds?
    @Published var participantTranscriptFilter: ParticipantSpeakerBinding?
    @Published var selectedTranscriptSpeaker: ParticipantTranscriptSelection?
    @Published var speakingParticipants: Set<String> = []


    func transcriptVisible(multicam: Bool) -> Bool {
        multicam ? inspectorVisible && inspector == .transcript : sequenceTranscriptVisible
    }

    func setTranscriptVisible(_ visible: Bool, multicam: Bool) {
        if multicam {
            if visible { inspector = .transcript }
            if visible || inspector == .transcript { inspectorVisible = visible }
        } else {
            sequenceTranscriptVisible = visible
            if visible { sequenceParticipantsVisible = false }
        }
    }
    @Published var waveformSpan: AudioViewerSpan = .timeline
    @Published var pauseControls = false
    var transcriptKeyHandler: ((NSEvent, NSEvent.ModifierFlags) -> Bool)?
    var showAbout: (() -> Void)?
    var showSettings: (() -> Void)?

    init() {}

    /// A new window starts from Settings: cut sections and Follow Playback are read once, and later changes
    /// to those defaults leave this window's state alone.
    init(startingFrom preferences: EditorPreferences) {
        cutSectionsHidden = !preferences.showsCutSections
        transcriptReader.followsPlayback = preferences.followsPlayback
    }
}

extension ProjectSessions {
    func mcpPresentation(tool: String, arguments: [String: Any], session: ProjectSession,
                         checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard ["workspace_layout_read", "workspace_layout_set", "workspace_panel_show", "timeline_time_reveal"].contains(tool) else { return nil }
        try checkAccess()
        var scan: [String: Any]?
        if tool != "workspace_layout_read" {
            if session.hasLifecycleModal,
               !["show_settings", "show_help", "show_about"].contains(arguments["action"] as? String ?? "") {
                throw MCPCommandError("editor_busy", "Dismiss the sheet on the target window to change its presentation.")
            }
            let opensPauseControls = arguments["action"] as? String == "set_pause_controls" &&
                (arguments["visible"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
            if opensPauseControls {
                let shouldScan = session.isMulticam ? session.multicam.canScanAnalysis(.silence) :
                    session.editor.canScanSilence && !session.editor.pauseAnalysisReady
                if shouldScan {
                    scan = try await mcpAnalysis(tool: "silence_editor_scan", arguments: [:],
                                                 session: session, checkAccess: checkAccess)
                    try checkAccess()
                    guard !session.hasLifecycleModal else {
                        throw MCPCommandError("editor_busy", "Dismiss the sheet on the target window to change its presentation.")
                    }
                }
            }
            try await session.changePresentation(arguments, revealTime: tool == "timeline_time_reveal",
                                                 checkAccess: checkAccess)
        }
        var state = session.presentationState()
        state["scan"] = scan
        return state
    }
}

extension ProjectSession {
    private enum MonitorPicture: String { case source, output }

    private var layoutZoom: Double {
        get { isMulticam ? multicam.timelineZoom : editor.timelineZoom }
        set {
            if isMulticam { multicam.timelineZoom = newValue } else { editor.timelineZoom = newValue }
        }
    }

    private enum ScrollSurface: String, CaseIterable {
        case sequence, assembly, group, tracks
        var horizontal: Bool { self != .tracks }

        @MainActor func matches(_ scroll: NSScrollView) -> Bool {
            switch self {
            case .sequence, .assembly: return scroll is TimelineScrollView
            case .group: return scroll.identifier?.rawValue == "MPCutGroupTimeScroll"
            case .tracks: return scroll.identifier?.rawValue == "MPCutGroupTrackScroll"
            }
        }
    }

    private func surface(_ surface: ScrollSurface) -> NSScrollView? {
        guard (surface == .sequence) == !isMulticam else { return nil }
        return window?.contentView?.presentationDescendant(NSScrollView.self, where: surface.matches)
    }

    private func split(vertical: Bool) -> NSSplitView? {
        window?.contentView?.presentationDescendant(NSSplitView.self) {
            $0.isVertical == vertical && $0.arrangedSubviews.count == 2
        }
    }

    fileprivate func presentationState() -> [String: Any] {
        var result: [String: Any] = [
            "zoom": layoutZoom, "zoom_factor": pow(2, layoutZoom), "maximum_zoom": TimelineViewControls.maximumZoom,
            "timeline_large_previews_enabled": editor.largeThumbnails, "pause_controls_visible": presentation.pauseControls,
            "scope": isMulticam ? "multicam" : "sequence",
            "transcript_visible": presentation.transcriptVisible(multicam: isMulticam),
            "tiles_visible": isMulticam ? presentation.inspectorVisible && presentation.inspector == .participants : presentation.sequenceParticipantsVisible,
            "history_visible": isHistoryPresented, "monitor_visible": monitor?.isVisible == true,
            "export_queue_visible": isMulticam ? multicam.isBulkQueuePresented : editor.isBulkQueuePresented
        ]
        result["monitor_picture"] = presentation.participantMonitorSource ? "source" : "output"
        if !isMulticam { result["cut_sections_visible"] = !presentation.cutSectionsHidden }
        result["full_height_panel"] = editor.preferences.fullHeightSidebar
        result["transcript_follow_playback"] = presentation.transcriptReader.followsPlayback
        if isMulticam {
            result["transcript_suggested_cameras"] = TranscriptSuggestedCameras.forAttachments(
                transcript.state.attachments.map(\.id), data: editor.preferences.transcriptSuggestedAngles
            )
            result["inspector_visible"] = presentation.inspectorVisible
            result["inspector"] = presentation.inspector == .participants ? "tiles" : presentation.inspector.rawValue
            result["report_visible"] = multicam.report != nil
            result["replacement_audio_visible"] = multicam.isReplacementAudioPresented
            if let size = split(vertical: false)?.arrangedSubviews.last?.frame.height { result["timeline_height"] = size }
            if let size = split(vertical: true)?.arrangedSubviews.last?.frame.width { result["inspector_width"] = size }
            if let group = surface(.group), let tracks = surface(.tracks) {
                result["track_label_width"] = MulticamTimeline.trackWidth(editor.preferences.trackLabelWidth,
                                                                          available: tracks.contentView.bounds.width)
                result["group_viewport_width"] = group.contentView.bounds.width
            }
        } else {
            if editor.audioPreviewClip != nil { result["waveform_span"] = presentation.waveformSpan.rawValue }
            if presentation.sequenceTranscriptVisible, let size = split(vertical: true)?.arrangedSubviews.last?.frame.width {
                result["inspector_width"] = size
            }
        }
        var scrolls: [String: Double] = [:]
        for target in ScrollSurface.allCases {
            guard let scroll = surface(target), let doc = scroll.documentView else { continue }
            let visible = scroll.contentView.bounds
            let span = target.horizontal ? doc.bounds.width - visible.width : doc.bounds.height - visible.height
            let origin = target.horizontal ? visible.minX - doc.bounds.minX : visible.minY - doc.bounds.minY
            scrolls[target.rawValue] = span > 0 ? min(1, max(0, origin / span)) : 0
        }
        result["scroll_positions"] = scrolls
        return result
    }

    fileprivate func changePresentation(_ args: [String: Any], revealTime: Bool,
                                        checkAccess: @MainActor () throws -> Void) async throws {
        let unavailable = MCPCommandError("control_unavailable", "This control is unavailable in the target window.")
        func text(_ key: String) throws -> String {
            guard let value = args[key] as? String else { throw MCPCommandError("invalid_arguments", "Supply \(key).") }
            return value
        }
        func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
            guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, range.contains(number.doubleValue) else {
                throw MCPCommandError("invalid_arguments", "Supply \(key) in \(range).")
            }
            return number.doubleValue
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = args[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw MCPCommandError("invalid_arguments", "Supply a Boolean \(key).")
            }
            return value.boolValue
        }

        let action = try revealTime ? "reveal_time" : text("action")
        switch action {
        case "zoom_in", "zoom_out", "fit", "restore_zoom", "set_zoom":
            guard isMulticam ? multicam.project != nil : !editor.isEmpty else { throw unavailable }
            switch action {
            case "zoom_in": layoutZoom = TimelineViewControls.adjustedZoom(layoutZoom, by: 1)
            case "zoom_out": layoutZoom = TimelineViewControls.adjustedZoom(layoutZoom, by: -1)
            case "fit": layoutZoom = 0
            case "restore_zoom": layoutZoom = isMulticam ? multicam.previousTimelineZoom : editor.previousTimelineZoom
            default: layoutZoom = try number("zoom", range: 0...TimelineViewControls.maximumZoom)
            }
        case "set_large_thumbnails":
            try editor.preferences.checkAgentWrite()
            editor.largeThumbnails = try flag("enabled")
        case "set_monitor_picture":
            guard isMulticam ? multicam.project != nil : editor.hasPicture else { throw unavailable }
            guard let picture = MonitorPicture(rawValue: try text("picture")) else {
                throw MCPCommandError("invalid_arguments", "Choose source or output for picture.")
            }
            presentation.participantMonitorSource = picture == .source
        case "set_cut_sections":
            guard !isMulticam, !editor.isEmpty else { throw unavailable }
            presentation.cutSectionsHidden = !(try flag("visible"))
        case "set_full_height_panel":
            try editor.preferences.checkAgentWrite()
            editor.preferences.fullHeightSidebar = try flag("enabled")
        case "set_transcript_follow_playback":
            guard isMulticam ? multicam.project != nil : !editor.isEmpty else { throw unavailable }
            presentation.transcriptReader.followsPlayback = try flag("enabled")
        case "set_transcript_suggested_camera":
            guard isMulticam, let project = multicam.project else { throw unavailable }
            let attachment = try text("attachment")
            let speaker = try text("speaker")
            guard transcript.state.attachments.contains(where: { $0.id == attachment }),
                  !speaker.isEmpty else {
                throw MCPCommandError("invalid_arguments", "Choose a project transcript attachment and speaker ID.")
            }
            let camera = args["camera"] is NSNull ? nil : try text("camera")
            if let camera {
                guard project.angles.contains(where: { $0.id == camera }) else {
                    throw MCPCommandError("invalid_arguments", "Choose a camera angle from the project.")
                }
                let dialogue = try await transcript.indexedTranscript(attachmentID: attachment, clocks: [])
                try checkAccess()
                guard !hasLifecycleModal else {
                    throw MCPCommandError("editor_busy", "Dismiss the sheet on the target window to change its presentation.")
                }
                guard dialogue.speakers.contains(where: { $0.id == speaker }) else {
                    throw MCPCommandError("invalid_arguments", "Choose a speaker ID from the transcript attachment.")
                }
            }
            TranscriptSuggestedCameras.set(camera, attachment: attachment, speaker: speaker, in: editor.preferences)
        case "set_waveform_span":
            guard !isMulticam, editor.audioPreviewClip != nil else { throw unavailable }
            guard let span = AudioViewerSpan(rawValue: try text("span")) else {
                throw MCPCommandError("invalid_arguments", "Choose a supported waveform span.")
            }
            presentation.waveformSpan = span
        case "set_inspector":
            guard isMulticam, multicam.project != nil else { throw unavailable }
            let visible = args["visible"] == nil ? true : try flag("visible")
            if args["section"] != nil {
                let name = try text("section")
                guard let section = EditorPresentation.Inspector(rawValue: name == "tiles" ? "participants" : name) else {
                    throw MCPCommandError("invalid_arguments", "Choose an inspector section.")
                }
                presentation.inspector = section
            }
            presentation.inspectorVisible = visible
        case "set_transcript":
            guard isMulticam ? multicam.project != nil : !editor.isEmpty else { throw unavailable }
            presentation.setTranscriptVisible(try flag("visible"), multicam: isMulticam)
        case "set_tiles", "show_tiles":
            guard isMulticam ? multicam.project != nil : !editor.isEmpty else { throw unavailable }
            let visible = action == "show_tiles" ? true : try flag("visible")
            if isMulticam {
                if visible { presentation.inspector = .participants }
                if presentation.inspector == .participants { presentation.inspectorVisible = visible }
            } else {
                presentation.sequenceParticipantsVisible = visible
                if visible { presentation.sequenceTranscriptVisible = false }
            }
        case "set_pause_controls":
            let visible = try flag("visible")
            if visible {
                if isMulticam {
                    guard multicam.project != nil, !multicam.isBusy else { throw unavailable }
                } else {
                    guard !editor.isBusy, !editor.audioTracks.isEmpty else { throw unavailable }
                }
            }
            presentation.pauseControls = visible
        case "reveal_time":
            guard let target = ScrollSurface(rawValue: try text("surface")), target.horizontal,
                  let scroll = surface(target) else { throw unavailable }
            let time = try RationalTime(parsing: text("time"))
            if let timeline = scroll as? TimelineScrollView, let model = timeline.surface.timeline {
                guard (0...model.duration).contains(time.seconds) else {
                    throw MCPCommandError("invalid_time", "The requested time is outside this timeline.")
                }
                timeline.surface.reveal(time: time.seconds)
            } else if let locator = scroll.presentationDescendant(MulticamScrollViewLocator.Locator.self,
                                                                  where: { $0.revealTime != nil }),
                      let reveal = locator.revealTime {
                guard reveal(time.seconds) else {
                    throw MCPCommandError("invalid_time", "The requested time is outside the displayed multicam timeline.")
                }
            } else { throw unavailable }
        case "set_scroll":
            guard let target = ScrollSurface(rawValue: try text("surface")), let scroll = surface(target),
                  let document = scroll.documentView else { throw unavailable }
            let fraction = try number("fraction", range: 0...1)
            let clip = scroll.contentView
            var proposed = clip.bounds
            if target.horizontal {
                proposed.origin.x = document.bounds.minX + fraction * max(0, document.bounds.width - proposed.width)
            } else {
                proposed.origin.y = document.bounds.minY + fraction * max(0, document.bounds.height - proposed.height)
            }
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        case "set_track_label_width":
            try editor.preferences.checkAgentWrite()
            guard isMulticam, let tracks = surface(.tracks) else { throw unavailable }
            let requested = try number("points", range: 106...360)
            editor.preferences.trackLabelWidth = MulticamTimeline.trackWidth(requested, available: tracks.contentView.bounds.width)
        case "set_timeline_height", "set_inspector_width":
            let vertical = action == "set_inspector_width"
            guard isMulticam || (vertical && presentation.sequenceTranscriptVisible),
                  let split = split(vertical: vertical) else { throw unavailable }
            let size = try number("points", range: 1...10000)
            let total = vertical ? split.bounds.width : split.bounds.height
            let requested = total - split.dividerThickness - size
            let minimum = split.minPossiblePositionOfDivider(at: 0)
            let maximum = split.maxPossiblePositionOfDivider(at: 0)
            split.setPosition(min(maximum, max(minimum, requested)), ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        case "show_about":
            guard let show = presentation.showAbout else { throw unavailable }
            show()
        case "show_settings":
            guard let show = presentation.showSettings else { throw unavailable }
            if let name = args["page"] {
                guard let page = (name as? String).flatMap(SettingsPage.init(rawValue:)) else {
                    throw MCPCommandError("invalid_arguments", "Choose a Settings page.")
                }
                SettingsWindow.open(page, preferences: editor.preferences)
            } else {
                show()
            }
        case "show_help":
            let topic = try text("topic")
            let document: MPCutDocument
            switch topic {
            case "guide": document = .guide
            case "agent_guide": document = .agentGuide
            case "release_notes": document = .releaseNotes
            default: throw MCPCommandError("invalid_arguments", "Unknown help topic.")
            }
            guard NSWorkspace.shared.open(document.url) else { throw unavailable }
        case "show_last_export":
            guard isMulticam ? multicam.lastExportedURL != nil : editor.lastExportedURL != nil else { throw unavailable }
            if isMulticam { multicam.showExportInFinder() } else { editor.showExportInFinder() }
        default:
            throw MCPCommandError("invalid_arguments", "Unknown presentation action.")
        }
    }
}

private extension NSView {
    func presentationDescendant<T: NSView>(_ type: T.Type, where matches: (T) -> Bool) -> T? {
        if let target = self as? T, matches(target) { return target }
        for child in subviews {
            if let target = child.presentationDescendant(type, where: matches) { return target }
        }
        return nil
    }
}
