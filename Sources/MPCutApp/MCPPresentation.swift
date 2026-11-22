import AppKit
import Combine
import CoreFoundation
import MPCutCore

/// Per-window state shared by the visible controls and local commands.
@MainActor
final class EditorPresentation: ObservableObject {
    enum Inspector: String, CaseIterable {
        case switches = "Switch", sources = "Sources", assembly = "Assembly", export = "Export"
    }
    @Published var inspector: Inspector = .switches
    @Published var inspectorVisible = true
    @Published var waveformSpan: AudioViewerSpan = .timeline
    @Published var pauseControls = false
    var showAbout: (() -> Void)?
    var showSettings: (() -> Void)?
}

extension ProjectSessions {
    func mcpPresentation(tool: String, arguments: [String: Any], session: ProjectSession,
                         checkAccess: @escaping @MainActor () throws -> Void) async throws -> [String: Any]? {
        guard tool == "get_presentation" || tool == "set_presentation" else { return nil }
        try checkAccess()
        var scan: [String: Any]?
        if tool == "set_presentation" {
            if session.hasLifecycleModal,
               !["showSettings", "showHelp", "showAbout"].contains(arguments["action"] as? String ?? "") {
                throw MCPCommandError("editor_busy", "Dismiss the sheet on the target window to change its presentation.")
            }
            let opensPauseControls = arguments["action"] as? String == "setPauseControls" &&
                (arguments["visible"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
            if opensPauseControls {
                let shouldScan = session.isMulticam ? session.multicam.canScanAnalysis(.silence) :
                    session.editor.canScanSilence && !session.editor.pauseAnalysisReady
                if shouldScan {
                    scan = try await mcpAnalysis(tool: "scan_analysis", arguments: ["kind": "silence"],
                                                 session: session, checkAccess: checkAccess)
                    try checkAccess()
                    guard !session.hasLifecycleModal else {
                        throw MCPCommandError("editor_busy", "Dismiss the sheet on the target window to change its presentation.")
                    }
                }
            }
            try session.changePresentation(arguments)
        }
        var state = session.presentationState()
        state["scan"] = scan
        return state
    }
}

extension ProjectSession {
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
            "zoom": layoutZoom, "zoomFactor": pow(2, layoutZoom), "maximumZoom": TimelineViewControls.maximumZoom,
            "largeThumbnails": editor.largeThumbnails, "pauseControlsVisible": presentation.pauseControls,
            "scope": isMulticam ? "multicam" : "sequence",
            "historyVisible": isHistoryPresented, "monitorVisible": monitor?.isVisible == true,
            "exportQueueVisible": isMulticam ? multicam.isBulkQueuePresented : editor.isBulkQueuePresented
        ]
        if isMulticam {
            result["inspectorVisible"] = presentation.inspectorVisible
            result["inspector"] = presentation.inspector.rawValue
            result["reportVisible"] = multicam.report != nil
            result["replacementAudioVisible"] = multicam.isReplacementAudioPresented
            if let size = split(vertical: false)?.arrangedSubviews.last?.frame.height { result["timelineHeight"] = size }
            if let size = split(vertical: true)?.arrangedSubviews.last?.frame.width { result["inspectorWidth"] = size }
            if let group = surface(.group), let tracks = surface(.tracks) {
                result["trackLabelWidth"] = MulticamTimeline.trackWidth(Self.savedLabelWidth, available: tracks.contentView.bounds.width)
                result["groupViewportWidth"] = group.contentView.bounds.width
            }
        } else if editor.audioPreviewClip != nil {
            result["waveformSpan"] = presentation.waveformSpan.rawValue
        }
        var scrolls: [String: Double] = [:]
        for target in ScrollSurface.allCases {
            guard let scroll = surface(target), let doc = scroll.documentView else { continue }
            let visible = scroll.contentView.bounds
            let span = target.horizontal ? doc.bounds.width - visible.width : doc.bounds.height - visible.height
            let origin = target.horizontal ? visible.minX - doc.bounds.minX : visible.minY - doc.bounds.minY
            scrolls[target.rawValue] = span > 0 ? min(1, max(0, origin / span)) : 0
        }
        result["scrollPositions"] = scrolls
        return result
    }

    private static var savedLabelWidth: Double {
        UserDefaults.standard.object(forKey: MulticamTimeline.trackWidthPreference) as? Double ?? 172
    }

    fileprivate func changePresentation(_ args: [String: Any]) throws {
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

        let action = try text("action")
        switch action {
        case "zoomIn", "zoomOut", "fit", "restoreZoom", "setZoom":
            guard isMulticam ? multicam.project != nil : !editor.isEmpty else { throw unavailable }
            switch action {
            case "zoomIn": layoutZoom = TimelineViewControls.adjustedZoom(layoutZoom, by: 1)
            case "zoomOut": layoutZoom = TimelineViewControls.adjustedZoom(layoutZoom, by: -1)
            case "fit": layoutZoom = 0
            case "restoreZoom": layoutZoom = isMulticam ? multicam.previousTimelineZoom : editor.previousTimelineZoom
            default: layoutZoom = try number("zoom", range: 0...TimelineViewControls.maximumZoom)
            }
        case "setLargeThumbnails":
            editor.largeThumbnails = try flag("enabled")
        case "setWaveformSpan":
            guard !isMulticam, editor.audioPreviewClip != nil else { throw unavailable }
            guard let span = AudioViewerSpan(rawValue: try text("span")) else {
                throw MCPCommandError("invalid_arguments", "Choose a supported waveform span.")
            }
            presentation.waveformSpan = span
        case "setInspector":
            guard isMulticam, multicam.project != nil else { throw unavailable }
            let visible = args["visible"] == nil ? true : try flag("visible")
            if args["section"] != nil {
                guard let section = EditorPresentation.Inspector(rawValue: try text("section")) else {
                    throw MCPCommandError("invalid_arguments", "Choose an inspector section.")
                }
                presentation.inspector = section
            }
            presentation.inspectorVisible = visible
        case "setPauseControls":
            let visible = try flag("visible")
            if visible {
                if isMulticam {
                    guard multicam.project != nil, !multicam.isBusy else { throw unavailable }
                } else {
                    guard !editor.isBusy, !editor.audioTracks.isEmpty else { throw unavailable }
                }
            }
            presentation.pauseControls = visible
        case "revealTime":
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
        case "setScroll":
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
        case "setTrackLabelWidth":
            guard isMulticam, let tracks = surface(.tracks) else { throw unavailable }
            let requested = try number("points", range: 106...360)
            let width = MulticamTimeline.trackWidth(requested, available: tracks.contentView.bounds.width)
            UserDefaults.standard.set(width, forKey: MulticamTimeline.trackWidthPreference)
        case "setTimelineHeight", "setInspectorWidth":
            let vertical = action == "setInspectorWidth"
            guard isMulticam, let split = split(vertical: vertical) else { throw unavailable }
            let size = try number("points", range: 1...10000)
            let total = vertical ? split.bounds.width : split.bounds.height
            let requested = total - split.dividerThickness - size
            let minimum = split.minPossiblePositionOfDivider(at: 0)
            let maximum = split.maxPossiblePositionOfDivider(at: 0)
            split.setPosition(min(maximum, max(minimum, requested)), ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        case "showAbout":
            guard let show = presentation.showAbout else { throw unavailable }
            show()
        case "showSettings":
            guard let show = presentation.showSettings else { throw unavailable }
            show()
        case "showHelp":
            let topic = try text("topic")
            let document: MPCutDocument
            switch topic {
            case "guide": document = .guide
            case "agentGuide": document = .agentGuide
            case "releaseNotes": document = .releaseNotes
            default: throw MCPCommandError("invalid_arguments", "Unknown help topic.")
            }
            guard NSWorkspace.shared.open(document.url) else { throw unavailable }
        case "showLastExport":
            guard !isMulticam, editor.lastExportedURL != nil else { throw unavailable }
            editor.showExportInFinder()
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
