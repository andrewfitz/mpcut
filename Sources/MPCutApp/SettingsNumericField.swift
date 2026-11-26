import AppKit
import SwiftUI

/// A number a Settings field can show and read back.
protocol SettingsNumber: Strideable, Comparable {
    init?(settingsText: String)
    func settingsText(digits: Int) -> String
    /// The value at the field's precision, so a typed or stepped value is what the field shows.
    func settingsRounded(digits: Int) -> Self
    /// Whether the field takes whole numbers only.
    static var settingsIsWhole: Bool { get }
}

extension Int: SettingsNumber {
    init?(settingsText: String) { self.init(settingsText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func settingsText(digits: Int) -> String { String(self) }
    func settingsRounded(digits: Int) -> Int { self }
    static var settingsIsWhole: Bool { true }
}

extension Double: SettingsNumber {
    init?(settingsText: String) {
        let text = settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? Double(text, format: .number), value.isFinite else { return nil }
        self = value
    }

    func settingsText(digits: Int) -> String {
        formatted(.number.precision(.fractionLength(0...digits)).grouping(.never))
    }

    func settingsRounded(digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        let rounded = (self * scale).rounded() / scale
        return rounded.isFinite ? rounded : self
    }

    static var settingsIsWhole: Bool { false }
}

/// Every number in Settings: a field with its unit right after it, a stepper and a range. It commits on Return, on focus
/// loss (a click anywhere else in the window counts, see `SettingsWindowHooks`), on page change and on window close.
/// Typing alone never commits, so a half-typed value cannot evict history. Only text the editor typed and has not
/// committed is ever written: the shown text follows the value, so a field left behind in a closed window cannot write a
/// stale number back. Restore Defaults discards typed text.
///
/// The range is stated in the tooltip and the accessibility hint. A committed entry that had to be limited to the range,
/// rounded to the field's precision or adjusted by the setting itself says so briefly under the field, with no alert and
/// no beep, so the stored value is always the one the field then shows.
struct SettingsNumericField<Value: SettingsNumber>: View {
    /// The unit column's width, so fields line up whatever their unit.
    static var unitWidth: CGFloat { 34 }

    let row: SettingsRow
    let unit: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    var digits = 2
    var help: String?
    /// The range as the tooltip, the hint and a limit notice state it, when the plain bounds would not read well.
    var rangeText: String?
    /// What 0 means for this setting, shown under the field while it holds 0.
    var zeroMeaning: String?
    /// What the editor typed since the last commit, or nil while the field shows the value.
    @State private var typed: String?
    @State private var notice: String?
    @State private var noticeReset: Task<Void, Never>?
    @FocusState private var editing: Bool

    init(_ row: SettingsRow, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride, unit: String = "",
         digits: Int = 2, help: String? = nil, rangeText: String? = nil, zeroMeaning: String? = nil) {
        self.row = row
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.digits = digits
        self.help = help
        self.rangeText = rangeText
        self.zeroMeaning = zeroMeaning
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                // Three columns on every row, so numbers, units and steppers each line up down the page: the field, a
                // unit column that is empty when there is no unit, and the stepper.
                HStack(spacing: 4) {
                    // The control's own title is its one accessibility label. An `.accessibilityLabel` here as well
                    // would be read after it, as "Width, Width".
                    TextField(row.title, text: Binding(
                        get: { typed ?? shown },
                        // AppKit also reports the unchanged text when editing ends; only a change counts as typing.
                        set: { text in
                            if text != (typed ?? shown) {
                                typed = text
                                clearNotice()
                            }
                        }
                    ))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($editing)
                        .onSubmit(commit)
                        // The unit and range are the hint.
                        .accessibilityHint(spokenHint)
                        .accessibilityIdentifier(row.id)
                        .help(tooltip)
                    Text(unitText)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.unitWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    // Stepping starts from the visible value. Its title is the row's, so it reads as that setting's stepper.
                    Stepper(row.title, value: Binding(
                        get: { entered ?? value },
                        set: { stepped in
                            let stepped = min(range.upperBound, max(range.lowerBound, stepped.settingsRounded(digits: digits)))
                            value = stepped
                            typed = nil
                            clearNotice()
                        }
                    ), in: range, step: step)
                    .labelsHidden()
                    .accessibilityHint(stepperHint)
                    .accessibilityIdentifier(row.id + ".stepper")
                    .help(stepperHelp)
                }
                // A notice floats below the field over whatever is there, so no row moves. The page draws it (see
                // `SettingsNoticeLayer`), above the grouped sections, which clip what their rows draw outside them. The
                // field and the space the notice takes below it scroll into view just enough when they are not.
                .anchorPreference(key: SettingsNoticeKey.self, value: .bounds) { bounds in
                    notice.map { [SettingsNoticeKey.Notice(id: row.id, text: $0, field: bounds)] } ?? []
                }
                .overlay(alignment: .top) {
                    if notice != nil {
                        GeometryReader { geometry in
                            SettingsRevealInScroll()
                                .frame(width: geometry.size.width, height: geometry.size.height + SettingsNoticeKey.reach)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                if let zeroMeaning, typed == nil, shown == "0" {
                    Text(zeroMeaning).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier(row.id + ".zero")
                }
            }
        } label: {
            // The field and the stepper carry the title for VoiceOver.
            Text(row.title).accessibilityHidden(true)
        }
        .id(row.id)
        .onChange(of: editing) { _, focused in if !focused { commit() } }
        .onDisappear(perform: commit)
        .background(SettingsWindowCommit(page: row.page, commit: commit, discard: { typed = nil }))
        .modifier(SettingsFieldFocus(row: row, editing: $editing))
    }

    /// Plural units that read in the singular after 1.
    private static var singularUnits: [String: String] {
        ["days": "day", "steps": "step", "items": "item", "lines": "line", "seconds": "second"]
    }

    /// `unit` as it reads after the number `text`: "1 day", "2 days".
    static func unit(_ unit: String, after text: String) -> String {
        text == "1" ? singularUnits[unit] ?? unit : unit
    }

    /// The unit beside the value the field shows.
    var unitText: String { Self.unit(unit, after: typed ?? shown) }

    /// A number with its unit for a sentence: "2 px", "1 day", or the number alone when there is no unit.
    private func withUnit(_ text: String) -> String {
        unit.isEmpty ? text : text + " " + Self.unit(unit, after: text)
    }

    private var stepText: String { withUnit(Self.text(step, digits: digits)) }

    /// The stepper's tooltip: what it does, named as its row is, and the range.
    var stepperHelp: String { "Raise or lower “\(row.title)” by \(stepText). \(rangeSentence)" }

    /// The stepper's accessibility hint.
    var stepperHint: String { "Steps by \(stepText). " + rangeSentence.replacingOccurrences(of: "–", with: " to ") }

    private var shown: String { value.settingsText(digits: digits) }

    private var entered: Value? {
        guard let number = typed.flatMap(Value.init(settingsText:)) else { return nil }
        return min(range.upperBound, max(range.lowerBound, number.settingsRounded(digits: digits)))
    }

    private static func text(_ stride: Value.Stride, digits: Int) -> String {
        if let step = stride as? Double { return step.settingsText(digits: max(digits, 2)) }
        return "\(stride)"
    }

    /// The range for display, such as "106–360 pt", or "0.02 s or more" for a range with no practical top.
    var rangeDescription: String {
        if let rangeText { return rangeText }
        let suffix = unit.isEmpty ? "" : " " + unit
        let lower = range.lowerBound.settingsText(digits: digits)
        if let top = range.upperBound as? Double, top >= Double.greatestFiniteMagnitude / 2 { return lower + suffix + " or more" }
        if let top = range.upperBound as? Int, top == Int.max { return lower + suffix + " or more" }
        return lower + "–" + range.upperBound.settingsText(digits: digits) + suffix
    }

    private var rangeSentence: String { "Range: " + rangeDescription + "." }

    /// The accessibility hint: the range in words, and what 0 means.
    var spokenHint: String {
        var hint = rangeSentence.replacingOccurrences(of: "–", with: " to ")
        if let zeroMeaning { hint += " 0: " + zeroMeaning + "." }
        return hint
    }

    /// The tooltip: the help text, the range and what 0 means.
    var tooltip: String {
        var text = help ?? "Type a value for “\(row.title)”"
        if !text.hasSuffix(".") { text += "." }
        text += " " + rangeSentence
        if let zeroMeaning { text += " 0: " + zeroMeaning + "." }
        return text
    }

    /// What committing `text` stores, if anything, and what the field says about it. A number outside the range is
    /// limited to it and a number finer than the field's precision is rounded; both say so. Text that is not a number
    /// stores nothing and says what the field takes.
    func entry(_ text: String) -> (value: Value?, notice: String?) {
        guard let number = Value(settingsText: text) else {
            return (nil, (Value.settingsIsWhole ? "Enter a whole number, " : "Enter a number, ") + rangeDescription + ".")
        }
        let rounded = number.settingsRounded(digits: digits)
        let limited = min(range.upperBound, max(range.lowerBound, rounded))
        if limited != rounded { return (limited, "Limited to " + rangeDescription + ".") }
        if rounded != number {
            return (rounded, "Rounded to " + withUnit(rounded.settingsText(digits: digits)) + ".")
        }
        return (rounded, nil)
    }

    // Only text the editor changed is committed, so showing a more precise value never rounds it.
    private func commit() {
        guard let text = typed else { return }
        typed = nil
        guard text != shown else { return }
        let (number, message) = entry(text)
        var said = message
        if let number {
            if number != value { value = number }
            // The setting can adjust a value itself, such as an even pixel count; the field then says what was kept.
            let stored = value
            if stored != number, said == nil {
                said = "Saved as " + withUnit(stored.settingsText(digits: digits)) + "."
            }
        }
        if let said { show(said) }
    }

    private func show(_ message: String) {
        notice = message
        noticeReset?.cancel()
        noticeReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            notice = nil
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: row.title + ": " + message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func clearNotice() {
        guard notice != nil else { return }
        noticeReset?.cancel()
        notice = nil
    }
}

/// A search result focuses the field itself, so the text is ready to edit.
private struct SettingsFieldFocus: ViewModifier {
    let row: SettingsRow
    var editing: FocusState<Bool>.Binding
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .settingsHighlight(highlight == row.id)
            .onChange(of: highlight, initial: true) { _, target in
                if target == row.id { settingsFocusSoon { editing.wrappedValue = true } }
            }
    }
}

/// The range notices fields show, with each field's bounds, for the page to draw.
struct SettingsNoticeKey: PreferenceKey {
    struct Notice: Identifiable {
        let id: String
        let text: String
        let field: Anchor<CGRect>
    }

    /// How far below its field a notice reaches, for scrolling it into view.
    static let reach: CGFloat = 48

    static let defaultValue: [Notice] = []
    static func reduce(value: inout [Notice], nextValue: () -> [Notice]) { value += nextValue() }
}

/// Draws the page's range notices, each just below its field with its trailing edge on the field's. It takes no space
/// and no clicks.
struct SettingsNoticeLayer: View {
    let notices: [SettingsNoticeKey.Notice]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(notices) { notice in
                    let field = geometry[notice.field]
                    SettingsFieldNotice(text: notice.text)
                        .frame(width: field.width, alignment: .topTrailing)
                        .offset(x: field.minX, y: field.maxY + 3)
                        .accessibilityIdentifier(notice.id + ".notice")
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A range notice: a small caption with its own background.
private struct SettingsFieldNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.orange.opacity(0.5)))
            .fixedSize()
            .background(SettingsNoticeMarker())
    }
}

/// Marks where a notice is drawn, so a test can find it.
struct SettingsNoticeMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}
    final class MarkerView: NSView {}
}

/// Scrolls the enclosing scroll view by the least amount that shows this view, once it is laid out.
struct SettingsRevealInScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> RevealView { RevealView() }
    /// It reveals once, when it appears with its notice: a later update must not pull back a page the editor scrolled.
    func updateNSView(_ view: RevealView, context: Context) {}

    final class RevealView: NSView {
        /// Set once the view has been laid out in a window and revealed.
        private var revealed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            revealSoon()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            revealSoon()
        }

        func revealSoon() {
            guard !revealed else { return }
            DispatchQueue.main.async { [weak self] in self?.reveal() }
        }

        /// How far the enclosing scroll view must move, in its document's coordinates, to show this view: 0 when it
        /// already shows or there is no scroll view. The visible area leaves out what the title bar covers.
        var scrollNeeded: CGFloat {
            guard let scroll = enclosingScrollView, let document = scroll.documentView, window != nil, !bounds.isEmpty else { return 0 }
            let visible = scroll.documentVisibleRect
            let frame = convert(bounds, to: document).insetBy(dx: 0, dy: -4)
            if frame.height > visible.height { return 0 }
            if frame.maxY > visible.maxY { return frame.maxY - visible.maxY }
            if frame.minY < visible.minY { return frame.minY - visible.minY }
            return 0
        }

        func reveal() {
            guard !revealed, window != nil, !bounds.isEmpty else { return }
            revealed = true
            let distance = scrollNeeded
            guard distance != 0, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + distance))
            scroll.reflectScrolledClipView(clip)
        }
    }
}

struct HistoryLimitField: View {
    @Binding var limit: Int

    var body: some View {
        SettingsNumericField(.historyLimit, value: $limit, in: EditorPreferences.historyStepRange, step: 1,
                             help: "Type how many steps Undo and Redo keep", zeroMeaning: "History is off")
    }
}

/// Commits a field's typed value before the app quits, and drops it when Restore Defaults rewrites the page.
enum SettingsEdits {
    fileprivate static let finishEditing = Notification.Name("MPCutFinishEditingSettings")
    fileprivate static let discardEditing = Notification.Name("MPCutDiscardEditingSettings")
    @MainActor static func commitPending() {
        NotificationCenter.default.post(name: finishEditing, object: nil)
    }

    /// Forgets text typed on `page` and not yet committed, so it cannot be committed later, for example when the
    /// window closes. The fields show their values again.
    @MainActor static func discardPending(on page: SettingsPage) {
        NotificationCenter.default.post(name: discardEditing, object: nil, userInfo: ["page": page.rawValue])
    }
}

// AppKit can retain a Settings window and its field editor after the window closes. A retained field has no typed
// text unless the editor left some, so committing it writes nothing.
private struct SettingsWindowCommit: NSViewRepresentable {
    let page: SettingsPage
    let commit: () -> Void
    let discard: () -> Void

    func makeNSView(context: Context) -> WindowObserver { WindowObserver() }
    func updateNSView(_ view: WindowObserver, context: Context) {
        view.page = page
        view.commit = commit
        view.discard = discard
    }

    final class WindowObserver: NSView {
        var page: SettingsPage?
        var commit: (() -> Void)?
        var discard: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            center.addObserver(self, selector: #selector(finishEditing), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(finishEditing), name: SettingsEdits.finishEditing, object: nil)
            center.addObserver(self, selector: #selector(discardEditing(_:)), name: SettingsEdits.discardEditing, object: nil)
        }

        @objc private func finishEditing() { commit?() }

        @objc private func discardEditing(_ note: Notification) {
            if note.userInfo?["page"] as? String == page?.rawValue { discard?() }
        }
    }
}
