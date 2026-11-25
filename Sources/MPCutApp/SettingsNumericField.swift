import AppKit
import SwiftUI

/// A number a Settings field can show and read back.
protocol SettingsNumber: Strideable, Comparable {
    init?(settingsText: String)
    func settingsText(digits: Int) -> String
    /// The value at the field's precision, so a typed or stepped value is what the field shows.
    func settingsRounded(digits: Int) -> Self
}

extension Int: SettingsNumber {
    init?(settingsText: String) { self.init(settingsText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func settingsText(digits: Int) -> String { String(self) }
    func settingsRounded(digits: Int) -> Int { self }
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
}

/// Every number in Settings: a field with a unit, a stepper and a range. It commits on Return, on focus loss,
/// on page change and on window close. Typing alone never commits, so a half-typed value cannot evict history.
struct SettingsNumericField<Value: SettingsNumber>: View {
    let row: SettingsRow
    let unit: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    var digits = 2
    var help: String?
    @State private var entry = ""
    @FocusState private var editing: Bool

    init(_ row: SettingsRow, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride, unit: String = "",
         digits: Int = 2, help: String? = nil) {
        self.row = row
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.digits = digits
        self.help = help
    }

    var body: some View {
        LabeledContent(row.title) {
            HStack(spacing: 6) {
                TextField(row.title, text: $entry)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .focused($editing)
                    .onSubmit(commit)
                    .accessibilityLabel(unit.isEmpty ? row.title : "\(row.title) in \(unit)")
                    .accessibilityIdentifier(row.id)
                    .help(help ?? "Enter \(row.title.lowercased())")
                // Stepping starts from the visible value.
                Stepper(row.title, value: Binding(
                    get: { entered ?? value },
                    set: { stepped in
                        let stepped = min(range.upperBound, max(range.lowerBound, stepped.settingsRounded(digits: digits)))
                        value = stepped
                        entry = stepped.settingsText(digits: digits)
                    }
                ), in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(unit.isEmpty ? row.title : "\(row.title) in \(unit)")
                .accessibilityIdentifier(row.id + ".stepper")
                .help("Adjust \(row.title.lowercased())")
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .leading).fixedSize()
                }
            }
        }
        .id(row.id)
        .onChange(of: value, initial: true) { _, current in entry = current.settingsText(digits: digits) }
        .onChange(of: editing) { _, focused in if !focused { commit() } }
        .onDisappear(perform: commit)
        .background(SettingsWindowCommit(commit: commit))
        .modifier(SettingsFieldFocus(row: row, editing: $editing))
    }

    private var entered: Value? {
        guard let number = Value(settingsText: entry) else { return nil }
        return min(range.upperBound, max(range.lowerBound, number.settingsRounded(digits: digits)))
    }

    // Only text the editor changed is committed, so showing a more precise value never rounds it.
    private func commit() {
        if entry != value.settingsText(digits: digits), let entered, entered != value { value = entered }
        entry = value.settingsText(digits: digits)
    }
}

/// A search result focuses the field itself, so the text is ready to edit.
private struct SettingsFieldFocus: ViewModifier {
    let row: SettingsRow
    var editing: FocusState<Bool>.Binding
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .listRowBackground(highlight == row.id ? Color.accentColor.opacity(0.15) : nil)
            .onChange(of: highlight, initial: true) { _, target in
                if target == row.id { editing.wrappedValue = true }
            }
    }
}

struct HistoryLimitField: View {
    @Binding var limit: Int

    var body: some View {
        SettingsNumericField(.historyLimit, value: $limit, in: EditorPreferences.historyStepRange, step: 1,
                             help: "Enter history limit")
    }
}

/// Commits a field's typed value before Settings changes it underneath, as Restore Defaults and quitting do.
enum SettingsEdits {
    fileprivate static let finishEditing = Notification.Name("MPCutFinishEditingSettings")
    @MainActor static func commitPending() {
        NotificationCenter.default.post(name: finishEditing, object: nil)
    }
}

// AppKit can retain a Settings window and its field editor after the window closes.
private struct SettingsWindowCommit: NSViewRepresentable {
    let commit: () -> Void

    func makeNSView(context: Context) -> WindowObserver { WindowObserver() }
    func updateNSView(_ view: WindowObserver, context: Context) { view.commit = commit }

    final class WindowObserver: NSView {
        var commit: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            center.addObserver(self, selector: #selector(finishEditing), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(finishEditing), name: SettingsEdits.finishEditing, object: nil)
        }

        @objc private func finishEditing() { commit?() }
    }
}
