import SwiftUI

/// A text setting, committed the way every Settings number is: on Return, on focus loss (a click anywhere else in the
/// window counts), on page change and on window close, never while typing. Esc puts the stored text back, and Restore
/// Defaults drops typed text. The text is kept to `maximumLength` Unicode scalars as it is typed.
struct SettingsTextField: View {
    let row: SettingsRow
    @Binding var value: String
    let prompt: String
    let maximumLength: Int
    let help: String
    /// What the editor typed since the last commit, or nil while the field shows the value.
    @State private var typed: String?
    @FocusState private var editing: Bool

    init(_ row: SettingsRow, value: Binding<String>, prompt: String, maximumLength: Int, help: String) {
        self.row = row
        _value = value
        self.prompt = prompt
        self.maximumLength = maximumLength
        self.help = help
    }

    var body: some View {
        LabeledContent {
            // The field's own title is its one accessibility label.
            TextField(row.title, text: Binding(
                get: { typed ?? value },
                set: { text in
                    let kept = Self.kept(text, maximumLength)
                    if kept != (typed ?? value) { typed = kept }
                }
            ), prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 280)
                .focused($editing)
                .onSubmit(commit)
                .accessibilityIdentifier(row.id)
                .help(help)
        } label: {
            Text(row.title).accessibilityHidden(true)
        }
        .id(row.id)
        .onChange(of: editing) { _, focused in if !focused { commit() } }
        .onDisappear(perform: commit)
        .background(SettingsWindowCommit(page: row.page, commit: commit, discard: { typed = nil }))
        .modifier(SettingsFieldFocus(row: row, editing: $editing))
    }

    private func commit() {
        guard let text = typed else { return }
        typed = nil
        let kept = Self.kept(text, maximumLength)
        if kept != value { value = kept }
    }

    /// The longest start of `text` with at most `limit` Unicode scalars, which is how agents' writes are counted,
    /// never splitting a character.
    static func kept(_ text: String, _ limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text[index...].first.map { $0.unicodeScalars.count } ?? 0
            guard count + next <= limit else { break }
            count += next
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}

/// Transcripts → Filler terms.
struct SettingsFillerTermsField: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsTextField(.fillerTerms, value: $preferences.fillerTerms, prompt: "um, uh, you know",
                          maximumLength: EditorPreferences.fillerTermsMaximumLength,
                          help: "Type the filler terms transcript review starts with, separated by commas, up to "
                              + EditorPreferences.fillerTermsMaximumLength.formatted() + " characters.")
    }
}

/// A form row whose control's own title is its one accessibility label, as in every numeric field: the visible row label
/// is hidden from VoiceOver, so the control has no second name through the row's title element.
struct SettingsLabeledControl<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control.labelsHidden()
        } label: {
            Text(title).accessibilityHidden(true)
        }
    }
}
