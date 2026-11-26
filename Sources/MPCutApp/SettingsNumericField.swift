import AppKit
import SwiftUI

/// A number a Settings field can show and read back.
protocol SettingsNumber: Strideable, Comparable {
    /// Reads typed text as `SettingsNumberReader` does: never a grouping separator as part of a smaller number.
    init?(settingsText: String, locale: Locale)
    /// The value as the field shows it: the locale's decimal mark and digits, no grouping, so it reads back the same.
    func settingsText(digits: Int, locale: Locale) -> String
    /// The value as a range in a sentence shows it, with its digits grouped: "8,192".
    func settingsRangeText(digits: Int, locale: Locale) -> String
    var settingsIsZero: Bool { get }
    /// The value at the field's precision, so a typed or stepped value is what the field shows.
    func settingsRounded(digits: Int) -> Self
    /// Whether the field takes whole numbers only.
    static var settingsIsWhole: Bool { get }
}

extension SettingsNumber {
    init?(settingsText: String) { self.init(settingsText: settingsText, locale: .current) }
    func settingsText(digits: Int) -> String { settingsText(digits: digits, locale: .current) }
    func settingsRangeText(digits: Int) -> String { settingsRangeText(digits: digits, locale: .current) }
}

extension Int: SettingsNumber {
    init?(settingsText: String, locale: Locale) {
        guard let number = SettingsNumberReader.read(settingsText, locale: locale), let whole = Int(exactly: number) else { return nil }
        self = whole
    }

    func settingsText(digits: Int, locale: Locale) -> String { formatted(.number.grouping(.never).locale(locale)) }
    func settingsRangeText(digits: Int, locale: Locale) -> String { formatted(.number.locale(locale)) }
    var settingsIsZero: Bool { self == 0 }
    func settingsRounded(digits: Int) -> Int { self }
    static var settingsIsWhole: Bool { true }
}

extension Double: SettingsNumber {
    init?(settingsText: String, locale: Locale) {
        guard let value = SettingsNumberReader.read(settingsText, locale: locale) else { return nil }
        self = value
    }

    var settingsIsZero: Bool { self == 0 }

    func settingsText(digits: Int, locale: Locale) -> String {
        formatted(.number.precision(.fractionLength(0...digits)).grouping(.never).locale(locale))
    }

    func settingsRangeText(digits: Int, locale: Locale) -> String {
        formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    }

    func settingsRounded(digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        let rounded = (self * scale).rounded() / scale
        return rounded.isFinite ? rounded : self
    }

    static var settingsIsWhole: Bool { false }
}

/// Reads a typed number the same way in every locale. The locale's own digits count. A grouping separator counts
/// only between groups of three digits, as in "8,192" or "8.192", so it can never make 1.5 read as 15. Otherwise
/// either "." or "," is a decimal mark: "1.5" and "1,5" are 1.5 in every locale. Anything else, such as "1e3" or
/// "1,2,3", is not a number.
enum SettingsNumberReader {
    static func read(_ text: String, locale: Locale) -> Double? {
        var plain = ""
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
               scalar.properties.numericType == .decimal, let digit = character.wholeNumberValue {
                plain += String(digit)
            } else {
                plain.append(character == "\u{2212}" ? "-" : character)
            }
        }
        var sign = ""
        if let first = plain.first, first == "-" || first == "+" {
            if first == "-" { sign = "-" }
            plain.removeFirst()
        }
        let decimal = locale.decimalSeparator ?? "."
        var groupMarks: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
        if let grouping = locale.groupingSeparator, grouping.count == 1, let mark = grouping.first { groupMarks.insert(mark) }
        let digits = number(plain, decimal: decimal, groupMarks: groupMarks)
            ?? number(plain, decimal: decimal == "." ? "," : ".", groupMarks: [])
        guard let digits, let value = Double(sign + digits), value.isFinite else { return nil }
        return value
    }

    /// `text` as ASCII digits with "." before any fraction, reading `decimal` as the decimal mark and one kind of
    /// group mark only between groups of three digits.
    private static func number(_ text: String, decimal: String, groupMarks: Set<Character>) -> String? {
        func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }
        let parts = text.components(separatedBy: decimal)
        guard parts.count <= 2 else { return nil }
        var whole = parts[0]
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.allSatisfy(isDigit), !(whole.isEmpty && fraction.isEmpty) else { return nil }
        let marks = Set(whole.filter { groupMarks.contains($0) })
        if let mark = marks.first {
            let groups = whole.split(separator: mark, omittingEmptySubsequences: false)
            // A lead group starting with 0, as in "0.125", is a whole number below 1 with a decimal mark, not a group.
            guard marks.count == 1, let lead = groups.first, (1...3).contains(lead.count), lead.first != "0",
                  groups.allSatisfy({ $0.allSatisfy(isDigit) }), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            whole = groups.joined()
        }
        guard whole.allSatisfy(isDigit) else { return nil }
        return (whole.isEmpty ? "0" : whole) + (fraction.isEmpty ? "" : "." + fraction)
    }
}

/// Every number in Settings: a field with its unit right after it, a stepper and a range. It commits on Return, on focus
/// loss (a click anywhere else in the window counts, see `SettingsWindowHooks`), on page change and on window close.
/// Esc puts the stored value back. Typed text is read the same way in every locale (see `SettingsNumberReader`).
/// Typing alone never commits, so a half-typed value cannot evict history. Only text the editor typed and has not
/// committed is ever written: the shown text follows the value, so a field left behind in a closed window cannot write a
/// stale number back. Restore Defaults discards typed text.
///
/// The range is stated in the tooltip and the accessibility hint. A committed entry that had to be limited to the range,
/// rounded to the field's precision or adjusted by the setting itself says so briefly beside or under the field, with no alert and
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
                        // A bezeled field, so it reads as one to type in and shows a focus ring when Tab reaches it.
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($editing)
                        .onSubmit(commit)
                        // The unit and range are the hint.
                        .accessibilityHint(spokenHint)
                        .accessibilityIdentifier(row.id)
                        .help(tooltip)
                    // A space where there is no unit, so the row still has a text baseline to line its label up with.
                    Text(unitText.isEmpty ? " " : unitText)
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
                // A notice floats beside the field, or below it where there is no room, so no row moves. The page draws
                // it (see `SettingsNoticeLayer` and `SettingsNoticePlacement`), above the grouped sections, which clip
                // what their rows draw outside them. The field and the space a notice below it takes scroll into view
                // just enough when they are not.
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
                if let zeroMeaning, typed == nil, value.settingsIsZero {
                    Text(zeroMeaning).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier(row.id + ".zero")
                }
            }
            // The field with what may show under it, such as what 0 means, which a notice keeps clear of too. Added to
            // the notice the controls report inside, not in place of it.
            .transformAnchorPreference(key: SettingsNoticeKey.self, value: .bounds) { parts, bounds in
                if notice != nil { parts.append(SettingsNoticeKey.Notice(id: row.id, column: bounds)) }
            }
        } label: {
            // The field and the stepper carry the title for VoiceOver. A notice keeps clear of the title.
            Text(row.title).accessibilityHidden(true)
                .anchorPreference(key: SettingsNoticeKey.self, value: .bounds) { bounds in
                    notice == nil ? [] : [SettingsNoticeKey.Notice(id: row.id, title: bounds)]
                }
        }
        .id(row.id)
        .onChange(of: editing) { _, focused in if !focused { commit() } }
        .onDisappear(perform: commit)
        // Esc, through the window's key handling, discards typed text the same way Restore Defaults does.
        .background(SettingsWindowCommit(page: row.page, commit: commit, discard: {
            typed = nil
            clearNotice()
        }))
        .modifier(SettingsFieldFocus(row: row, editing: $editing))
    }

    /// Plural units that read in the singular after 1. "days" is the only plural unit a field uses.
    private static var singularUnits: [String: String] { ["days": "day"] }

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

    /// The range for display, such as "106–360 pt" or "16–8,192 px", or "0.02 s or more" for a range with no
    /// practical top.
    var rangeDescription: String {
        if let rangeText { return rangeText }
        let suffix = unit.isEmpty ? "" : " " + unit
        let lower = range.lowerBound.settingsRangeText(digits: digits)
        if let top = range.upperBound as? Double, top >= Double.greatestFiniteMagnitude / 2 { return lower + suffix + " or more" }
        if let top = range.upperBound as? Int, top == Int.max { return lower + suffix + " or more" }
        return lower + "–" + range.upperBound.settingsRangeText(digits: digits) + suffix
    }

    private var rangeSentence: String { "Range: " + rangeDescription + "." }

    /// The accessibility hint: the range in words, and what 0 means.
    var spokenHint: String {
        var hint = rangeSentence.replacingOccurrences(of: "–", with: " to ")
        if let zeroMeaning { hint += " " + Self.zeroSentence(zeroMeaning) }
        return hint
    }

    /// What 0 means, for a sentence after the range: "0: no limit." The caption under the field starts with a capital.
    static func zeroSentence(_ meaning: String) -> String {
        "0: " + meaning.prefix(1).lowercased() + meaning.dropFirst() + "."
    }

    /// The tooltip: the help text, the range and what 0 means.
    var tooltip: String {
        var text = help ?? "Type a value for “\(row.title)”"
        if !text.hasSuffix(".") { text += "." }
        text += " " + rangeSentence
        if let zeroMeaning { text += " " + Self.zeroSentence(zeroMeaning) }
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
struct SettingsFieldFocus: ViewModifier {
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

/// The range notices fields show, for the page to draw: each field reports its notice with the bounds of its controls,
/// and its row title reports its own bounds, as separate parts with the field's identifier.
struct SettingsNoticeKey: PreferenceKey {
    struct Notice: Identifiable {
        let id: String
        var text: String?
        var field: Anchor<CGRect>?
        var title: Anchor<CGRect>?
        /// The field's whole column: its controls and any caption under them.
        var column: Anchor<CGRect>?
    }

    /// How far below its field a notice reaches, for scrolling it into view.
    static let reach: CGFloat = 48

    static let defaultValue: [Notice] = []
    static func reduce(value: inout [Notice], nextValue: () -> [Notice]) { value += nextValue() }

    /// The parts reported for each field joined into one notice, in the order the fields reported them. A notice with no
    /// text or no field bounds is left out.
    static func joined(_ parts: [Notice]) -> [Notice] {
        var order: [String] = []
        var byID: [String: Notice] = [:]
        for part in parts {
            if var notice = byID[part.id] {
                notice.text = notice.text ?? part.text
                notice.field = notice.field ?? part.field
                notice.title = notice.title ?? part.title
                notice.column = notice.column ?? part.column
                byID[part.id] = notice
            } else {
                order.append(part.id)
                byID[part.id] = part
            }
        }
        return order.compactMap { byID[$0] }.filter { $0.text != nil && $0.field != nil }
    }
}

/// Draws the page's range notices where `SettingsNoticePlacement` puts them. It takes no space and no clicks.
struct SettingsNoticeLayer: View {
    let notices: [SettingsNoticeKey.Notice]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(SettingsNoticeKey.joined(notices)) { notice in
                    if let text = notice.text, let field = notice.field {
                        SettingsNoticePlacement(field: geometry[field], title: notice.title.map { geometry[$0] },
                                                column: notice.column.map { geometry[$0] }) {
                            SettingsFieldNotice(text: text)
                                .accessibilityIdentifier(notice.id + ".notice")
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Where a range notice goes, so it covers nothing and moves nothing, in this order:
/// 1. on its field's line, just left of the field, when it fits there clear of the row's title;
/// 2. in a row with a caption under its field (what 0 means), just below the field's line and left of the caption,
///    when it fits there under the title, inside the row;
/// 3. just below the field, with its trailing edge on the field's, where it can lie over the row's divider or the
///    group's border.
struct SettingsNoticePlacement: Layout {
    /// The space kept between the notice and the field, and between the notice and the title.
    static let gap: CGFloat = 8
    /// How far below the field a notice that does not fit beside it starts.
    static let below: CGFloat = 3

    let field: CGRect
    let title: CGRect?
    var column: CGRect?

    /// The notice's frame, in the coordinates of `field` and `title`.
    static func frame(field: CGRect, title: CGRect?, column: CGRect? = nil, notice: CGSize) -> CGRect {
        if let title {
            let beside = CGRect(x: field.minX - gap - notice.width, y: field.midY - notice.height / 2,
                                width: notice.width, height: notice.height)
            if beside.minX >= title.maxX + gap { return beside }
            // Only a row with a caption under its field reaches below the field's line; in any other row the space
            // there belongs to the next row.
            if let column, column.maxY > field.maxY + 1 {
                let under = CGRect(x: min(field.minX, column.minX) - gap - notice.width, y: field.maxY + below,
                                   width: notice.width, height: notice.height)
                if under.minX >= title.minX, under.minY >= title.maxY { return under }
            }
        }
        return CGRect(x: field.maxX - notice.width, y: field.maxY + below, width: notice.width, height: notice.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let frame = Self.frame(field: field, title: title, column: column, notice: size)
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
        }
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

/// Commits a field's typed value before the app quits, drops it when Restore Defaults rewrites the page, and drops one
/// field's when Esc is pressed in it.
enum SettingsEdits {
    fileprivate static let finishEditing = Notification.Name("MPCutFinishEditingSettings")
    fileprivate static let discardEditing = Notification.Name("MPCutDiscardEditingSettings")
    fileprivate static let revertEditing = Notification.Name("MPCutRevertEditingSettings")

    /// One Esc: the field whose row contains `point` takes it.
    fileprivate final class Revert {
        let point: NSPoint
        var taken = false
        init(point: NSPoint) { self.point = point }
    }

    /// Drops the text typed into the Settings field whose row contains `point`, in `window`'s coordinates, so the field
    /// shows its stored value again and commits nothing. Returns whether a field took it.
    @MainActor static func revert(at point: NSPoint, in window: NSWindow) -> Bool {
        let request = Revert(point: point)
        NotificationCenter.default.post(name: revertEditing, object: window, userInfo: ["request": request])
        return request.taken
    }

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
struct SettingsWindowCommit: NSViewRepresentable {
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
            center.addObserver(self, selector: #selector(revertEditing(_:)), name: SettingsEdits.revertEditing, object: window)
        }

        @objc private func finishEditing() { commit?() }

        @objc private func discardEditing(_ note: Notification) {
            if note.userInfo?["page"] as? String == page?.rawValue { discard?() }
        }

        /// This view is the background of its field's row, so it covers the field.
        @objc private func revertEditing(_ note: Notification) {
            guard let request = note.userInfo?["request"] as? SettingsEdits.Revert, !request.taken, !isHiddenOrHasHiddenAncestor,
                  convert(bounds, to: nil).contains(request.point) else { return }
            request.taken = true
            discard?()
        }
    }
}
