import AppKit
import SwiftUI

/// The AppKit side of the Settings window. A SwiftUI `Settings` scene makes its window non-resizable whatever the scene
/// and its content declare, on macOS 14 and later, so the window is made resizable here, with the plan's starting and
/// minimum sizes. SwiftUI can set the style mask again later, so the hooks reapply it whenever it changes.
///
/// The sizes are of the area below the title bar, where the content lays out. SwiftUI's windows extend their content view
/// under the title bar (a full-size content view), so a window minimum of 640 × 420 there would leave the content only
/// 420 minus the title bar, and the content, which needs 420, would overflow at both ends. The minimum is therefore the
/// content size plus the title bar's inset, set three ways because AppKit recomputes a window's minimum from its content
/// view's constraints: as the window's content minimum, as constraints on the content view's safe area, and again
/// whenever something lowers it.
///
/// The hooks also make a click anywhere else in the window end editing: AppKit leaves a text field editing when a click
/// lands on blank space or on a switch, so a typed number would otherwise stay uncommitted.
struct SettingsWindowHooks: NSViewRepresentable {
    static let initialSize = NSSize(width: 760, height: 560)
    static let minimumSize = NSSize(width: 640, height: 420)

    func makeNSView(context: Context) -> HookView { HookView() }

    func updateNSView(_ view: HookView, context: Context) {
        if let window = view.window { Self.configure(window) }
    }

    /// Makes the window resizable down to the minimum size. A window smaller than the minimum, as on its first showing,
    /// starts at the initial size; a size the editor chose is kept. Running it again changes nothing.
    @MainActor static func configure(_ window: NSWindow) {
        if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        let inset = titleBarInset(window)
        enforceMinimum(window)
        installMinimumConstraints(window)
        let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if window.contentMaxSize != unlimited { window.contentMaxSize = unlimited }
        let size = window.contentLayoutRect.size
        if size.width < minimumSize.width || size.height < minimumSize.height {
            window.setContentSize(NSSize(width: initialSize.width + inset.width, height: initialSize.height + inset.height))
        }
    }

    /// How much of the content view the title bar and toolbar cover: nothing for a window whose content view starts
    /// below the title bar, the title bar's height for a full-size content view.
    @MainActor static func titleBarInset(_ window: NSWindow) -> NSSize {
        let content = window.contentRect(forFrameRect: window.frame).size
        let layout = window.contentLayoutRect.size
        return NSSize(width: max(0, content.width - layout.width), height: max(0, content.height - layout.height))
    }

    /// The smallest content view that leaves the minimum size below the title bar.
    @MainActor static func contentMinimum(_ window: NSWindow) -> NSSize {
        let inset = titleBarInset(window)
        return NSSize(width: minimumSize.width + inset.width, height: minimumSize.height + inset.height)
    }

    /// Raises the window's content minimum to `contentMinimum` where it is lower. A larger minimum that the content's
    /// own constraints ask for is kept.
    @MainActor static func enforceMinimum(_ window: NSWindow) {
        let required = contentMinimum(window)
        let current = window.contentMinSize
        if current.width < required.width || current.height < required.height {
            window.contentMinSize = NSSize(width: max(current.width, required.width), height: max(current.height, required.height))
        }
    }

    static let minimumConstraintIdentifier = "MPCutSettingsWindowMinimum"

    /// The minimum as constraints on the content view's safe area, the area below the title bar. AppKit derives a
    /// window's minimum from its content view's constraints, so these keep the title bar out of the content's minimum
    /// however the window's minimum is recomputed.
    @MainActor static func installMinimumConstraints(_ window: NSWindow) {
        guard let content = window.contentView,
              !content.constraints.contains(where: { $0.identifier == minimumConstraintIdentifier }) else { return }
        let guide = content.safeAreaLayoutGuide
        let constraints = [guide.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.width),
                           guide.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height)]
        for constraint in constraints { constraint.identifier = minimumConstraintIdentifier }
        NSLayoutConstraint.activate(constraints)
    }

    /// Checks the minimum on the next turn of the run loop, outside the layout or property change that lowered it.
    @MainActor static func enforceMinimumSoon(_ window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            if let window { enforceMinimum(window) }
        }
    }

    /// Ends text editing in `window` when a click lands outside the field being edited, so its typed number commits.
    /// A click inside that field, or a window with no field editing, changes nothing. Returns whether editing ended.
    @MainActor @discardableResult
    static func finishEditing(in window: NSWindow, clickedView: NSView?) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        let field = editor.delegate as? NSView
        if let clicked = clickedView {
            if clicked === editor || clicked.isDescendant(of: editor) { return false }
            if let field, clicked === field || clicked.isDescendant(of: field) { return false }
        }
        // End editing first, so the text AppKit reports as editing ends counts as typed and is committed below with the
        // rest. The commit is explicit: a field in a window that is not key may not hear its focus change.
        window.makeFirstResponder(nil)
        SettingsEdits.commitPending()
        return true
    }

    /// The window's mouse-down monitor. It never consumes the click: the control under it still acts.
    @MainActor static func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent {
        guard event.window === window, let content = window.contentView else { return event }
        let point = content.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
        if let clicked = content.hitTest(point) { finishEditing(in: window, clickedView: clicked) }
        return event
    }

    final class HookView: NSView {
        private var monitor: Any?
        private var styleObservation: NSKeyValueObservation?
        /// The window's minimum and the area below its title bar: when either changes, the minimum is checked again.
        private var sizeObservations: [NSKeyValueObservation] = []
        private weak var observed: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observed else { return }
            detach()
            guard let window else { return }
            observed = window
            SettingsWindowHooks.configure(window)
            styleObservation = window.observe(\.styleMask) { window, _ in
                if !window.styleMask.contains(.resizable) { SettingsWindowHooks.configure(window) }
                else { SettingsWindowHooks.enforceMinimumSoon(window) }
            }
            sizeObservations = [
                window.observe(\.contentMinSize) { window, _ in SettingsWindowHooks.enforceMinimumSoon(window) },
                window.observe(\.minSize) { window, _ in SettingsWindowHooks.enforceMinimumSoon(window) },
                window.observe(\.contentLayoutRect) { window, _ in SettingsWindowHooks.enforceMinimumSoon(window) }
            ]
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak window] event in
                guard let window else { return event }
                return SettingsWindowHooks.handle(event, in: window)
            }
        }

        @objc private func windowDidBecomeKey(_ note: Notification) {
            if let window = note.object as? NSWindow { SettingsWindowHooks.configure(window) }
        }

        private func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            styleObservation?.invalidate()
            styleObservation = nil
            sizeObservations.forEach { $0.invalidate() }
            sizeObservations = []
            NotificationCenter.default.removeObserver(self)
            observed = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            styleObservation?.invalidate()
            sizeObservations.forEach { $0.invalidate() }
        }
    }
}
