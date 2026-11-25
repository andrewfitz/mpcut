import AppKit
import AVFoundation
import Combine
import QuartzCore

final class PreviewSurface: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let badge = NSTextField(labelWithString: "")
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var programFrame: PreviewFrame?
    private var adaptedFrame: (source: CVPixelBuffer, mapped: CVPixelBuffer)?
    private var observations: [NSObjectProtocol] = []
    private var forceSDR = false
    private var cleanFeed = false
    // Without preferences, as in a test host, the menu changes this surface only and nothing is saved.
    private weak var preferences: EditorPreferences?
    private var preferenceObservation: AnyCancellable?
    private(set) var isVideoMonitor = false
    var otherMonitorStatus: (() -> String?)?
    var presentationDescription: String? { badge.toolTip }
    private var cachedFormat: CMVideoFormatDescription?
    private var pictureTransform = CGAffineTransform.identity
    var windowChanged: ((PreviewSurface) -> Void)?
    private(set) var displayedFrameTime: CMTime?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        self.toolTip = "Right-click for preview options"
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        badge.setAccessibilityElement(true)
        addSubview(badge)
        failure.translatesAutoresizingMaskIntoConstraints = false
        failure.textColor = .white
        failure.alignment = .center
        failure.maximumNumberOfLines = 3
        addSubview(failure)
        NSLayoutConstraint.activate([
            failure.centerXAnchor.constraint(equalTo: centerXAnchor),
            failure.centerYAnchor.constraint(equalTo: centerYAnchor),
            failure.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.85),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        ])
        setStatus("Pending", frame: nil, reason: "Waiting for a program picture and display.")
    }

    /// Force SDR and clean feed follow the shared preferences, so a change from Settings, an agent or another
    /// window's menu reaches every open surface.
    func setMonitor(_ isMonitor: Bool, preferences: EditorPreferences? = nil) {
        isVideoMonitor = isMonitor
        self.preferences = preferences
        preferenceObservation = preferences?.observeChanges { [weak self] change in
            switch change {
            case .viewerForceSDR, .monitorForceSDR, .monitorCleanFeed: self?.applyPreferences()
            default: break
            }
        }
        applyPreferences()
    }

    private func applyPreferences() {
        if let preferences {
            forceSDR = isVideoMonitor ? preferences.monitorForceSDR : preferences.viewerForceSDR
            cleanFeed = isVideoMonitor && preferences.monitorCleanFeed
        }
        applyMonitorChrome()
        present()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let status = menu.addItem(withTitle: badge.toolTip ?? badge.stringValue, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if !isVideoMonitor, let monitorStatus = otherMonitorStatus?() {
            let item = menu.addItem(withTitle: "Video Monitor · \(monitorStatus)", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        let sdr = menu.addItem(withTitle: "Force SDR Preview", action: #selector(toggleSDR), keyEquivalent: "")
        sdr.target = self
        sdr.toolTip = "Toggle SDR preview"
        sdr.state = forceSDR ? .on : .off
        if isVideoMonitor {
            let clean = menu.addItem(withTitle: "Clean Feed", action: #selector(toggleCleanFeed), keyEquivalent: "")
            clean.target = self
            clean.toolTip = "Toggle clean feed"
            clean.state = cleanFeed ? .on : .off
            let full = menu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
            full.target = window
            full.toolTip = "Toggle full screen"
            if NSScreen.screens.count > 1 {
                let displayMenu = NSMenu()
                for screen in NSScreen.screens {
                    let item = displayMenu.addItem(withTitle: screen.localizedName, action: #selector(moveToDisplay(_:)), keyEquivalent: "")
                    item.target = self
                    item.toolTip = "Move monitor here"
                    item.representedObject = screen
                    item.state = screen == window?.screen ? .on : .off
                    item.isEnabled = window?.styleMask.contains(.fullScreen) == false
                }
                let displays = menu.addItem(withTitle: "Move to Display", action: nil, keyEquivalent: "")
                displays.submenu = displayMenu
                displays.toolTip = "Choose monitor display"
            }
        }
        return menu
    }

    @objc private func toggleSDR() {
        guard let preferences else {
            forceSDR.toggle()
            present()
            return
        }
        if isVideoMonitor { preferences.monitorForceSDR.toggle() } else { preferences.viewerForceSDR.toggle() }
    }

    @objc private func toggleCleanFeed() {
        guard let preferences else {
            cleanFeed.toggle()
            applyMonitorChrome()
            return
        }
        preferences.monitorCleanFeed.toggle()
    }

    private func applyMonitorChrome() {
        badge.isHidden = cleanFeed
        failure.isHidden = cleanFeed || failure.stringValue.isEmpty
        guard isVideoMonitor, let window else { return }
        window.titleVisibility = cleanFeed ? .hidden : .visible
        window.titlebarAppearsTransparent = cleanFeed
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = cleanFeed
        }
        if !window.styleMask.contains(.fullScreen) {
            if cleanFeed { window.styleMask.insert(.fullSizeContentView) }
            else { window.styleMask.remove(.fullSizeContentView) }
        }
    }

    @objc private func moveToDisplay(_ item: NSMenuItem) {
        guard let screen = item.representedObject as? NSScreen, let window,
              !window.styleMask.contains(.fullScreen) else { return }
        let available = screen.visibleFrame
        let scale = min(1, available.width / window.frame.width, available.height / window.frame.height)
        let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        window.setFrame(CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        observations.forEach(center.removeObserver)
        observations.removeAll()
        if let window {
            applyMonitorChrome()
            let windowEvents: [Notification.Name] = [
                NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification
            ]
            for name in windowEvents {
                observations.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.present() }
                })
            }
            observations.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.present() }
            })
            observations.append(center.addObserver(forName: .AVSampleBufferDisplayLayerFailedToDecode,
                                                   object: displayLayer, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.displayLayer.status == .failed else { return }
                    self.displayedFrameTime = nil
                    self.setStatus("Unavailable", frame: self.programFrame, reason: "The display renderer rejected this picture.")
                }
            })
        } else {
            clear()
        }
        windowChanged?(self)
    }

    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidHide() {
        super.viewDidHide()
        present()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        present()
    }

    override func layout() {
        super.layout()
        layoutPicture()
    }

    private func layoutPicture() {
        let rotated = abs(pictureTransform.b) > abs(pictureTransform.a)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.bounds = CGRect(origin: .zero, size: rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        displayLayer.setAffineTransform(pictureTransform)
        CATransaction.commit()
    }

    func clear() {
        programFrame = nil
        adaptedFrame = nil
        removePresentedPicture()
        requestExtendedRange(false)
        setStatus("Pending", frame: nil, reason: "Waiting for a program picture.")
    }

    func unavailable(_ reason: String) {
        clear()
        setStatus("Unavailable", frame: nil, reason: reason)
    }

    private func removePresentedPicture() {
        displayedFrameTime = nil
        cachedFormat = nil
        displayLayer.flushAndRemoveImage()
    }

    func display(_ frame: PreviewFrame) {
        if programFrame?.buffer !== frame.buffer { adaptedFrame = nil }
        programFrame = frame
        present()
    }

    private func present() {
        guard let frame = programFrame else { return }
        guard let window, let screen = window.screen, window.isVisible,
              !isHiddenOrHasHiddenAncestor, !window.isMiniaturized else {
            requestExtendedRange(false)
            setStatus("Pending", frame: frame, reason: "The viewer is hidden or its display is unresolved.")
            return
        }
        let transfer = PreviewTransfer(frame: frame)
        let visibleOnDisplay = window.occlusionState.contains(.visible)
        let wantsHDR = visibleOnDisplay && transfer.isVerified && transfer.actualHDR != nil &&
            !transfer.convertsProgramToSDR && !forceSDR && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        requestExtendedRange(wantsHDR)
        guard transfer.isVerified else {
            removePresentedPicture()
            setStatus("Unavailable", frame: frame, reason: "The decoded surface does not have the required transfer and precision.")
            return
        }
        var output = frame.buffer
        var status = "SDR"
        var reason: String?
        if transfer.usesSDRCameraPreview {
            status = "SDR preview"
            reason = "The camera preview uses the decoded SDR picture."
        }
        if let hdr = transfer.actualHDR {
            if wantsHDR {
                // Submitting extended-range content lets macOS activate current headroom.
                // During zero headroom, the native presenter uses the display's SDR rendition.
                if screen.maximumExtendedDynamicRangeColorComponentValue > 1 {
                    status = "HDR · \(hdr)"
                } else {
                    status = "SDR preview"
                    reason = "The system presenter has no current extended dynamic range headroom."
                }
            } else {
                if adaptedFrame?.source !== frame.buffer {
                    adaptedFrame = PreviewTransfer.mapToSDR(frame.buffer).map { (frame.buffer, $0) }
                }
                guard let sdr = adaptedFrame?.mapped else {
                    removePresentedPicture()
                    setStatus("Unavailable", frame: frame, reason: "Could not map the HDR surface to SDR.")
                    return
                }
                output = sdr
                if transfer.convertsProgramToSDR {
                    status = "SDR"
                    reason = "Mapped the HDR source to the SDR program."
                } else {
                    status = "SDR preview"
                    if forceSDR { reason = "Force SDR Preview is enabled." }
                    else if !visibleOnDisplay { reason = "The viewer is obscured." }
                    else { reason = "This display has no current extended dynamic range headroom." }
                }
            }
        }
        guard enqueue(frame, buffer: output) else {
            removePresentedPicture()
            setStatus("Unavailable", frame: frame, reason: "The display renderer rejected this picture.")
            return
        }
        if transfer.program == "unspecified" {
            status = forceSDR ? "SDR" : "Unknown"
            reason = forceSDR ? "Force SDR Preview treats the untagged picture as SDR." : "The picture has no transfer signaling."
        }
        if let cover = frame.privacyCoverNote {
            setStatus("Covered", frame: frame, reason: cover)
        } else {
            setStatus(status, frame: frame, reason: reason)
        }
    }

    private func requestExtendedRange(_ enabled: Bool) {
        if #available(macOS 26, *) {
            let requested: CALayer.DynamicRange = enabled ? .high : .standard
            if displayLayer.preferredDynamicRange != requested { displayLayer.preferredDynamicRange = requested }
        } else if displayLayer.wantsExtendedDynamicRangeContent != enabled {
            displayLayer.wantsExtendedDynamicRangeContent = enabled
        }
    }

    private func setStatus(_ status: String, frame: PreviewFrame?, reason: String?) {
        let transfer = frame.map(PreviewTransfer.init)
        let display = window?.screen?.localizedName ?? "display unresolved"
        let details = ["Source \(transfer?.source ?? "unresolved")",
                       "program \(transfer?.program ?? "unresolved")", display].joined(separator: ", ")
        // Which decoder made the picture belongs with how it is shown (FFmpeg after an AVFoundation failure).
        let description = ["\(status). \(details). \(reason ?? "")", frame?.decoderNote ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if badge.stringValue != status { badge.stringValue = status }
        let error = status == "Unavailable" || status == "Covered" ? reason ?? "" : ""
        if failure.stringValue != error { failure.stringValue = error }
        failure.isHidden = cleanFeed || error.isEmpty
        if badge.toolTip != description {
            badge.toolTip = description
            badge.setAccessibilityLabel(description)
        }
    }

    private func enqueue(_ frame: PreviewFrame, buffer: CVPixelBuffer) -> Bool {
        if pictureTransform != frame.displayTransform {
            pictureTransform = frame.displayTransform
            layoutPicture()
        }
        if cachedFormat.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) != true {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                               formatDescriptionOut: &format) == noErr else { return false }
            cachedFormat = format
        }
        guard let format = cachedFormat else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(array) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
        guard displayLayer.status != .failed else { return false }
        displayedFrameTime = frame.time
        return true
    }
}
