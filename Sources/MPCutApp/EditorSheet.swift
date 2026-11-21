import SwiftUI

/// One layout for every sheet: a title, an optional explanation, the content, and a trailing button row.
struct EditorSheet<Content: View, Actions: View>: View {
    let title: String
    var message: String? = nil
    @ViewBuilder let content: Content
    /// Buttons in reading order. Put auxiliary actions first, a `Spacer`, then Cancel and the default button.
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 10) {
                actions
            }
        }
        .padding(EditorMetrics.sheetPadding)
    }
}

/// A small heading for a group of controls in a popover or an inspector.
struct SectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled control with a fixed label column, so stacked rows align without a Form.
struct InspectorRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 88
    @ViewBuilder let content: Content

    init(_ label: String, labelWidth: CGFloat = 88, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            content
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An inline caution or failure message.
struct IssueLabel: View {
    let message: String
    var symbol = "exclamationmark.triangle.fill"

    init(_ message: String, symbol: String = "exclamationmark.triangle.fill") {
        self.message = message
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

/// The inset, rounded frame used around lists and previews inside sheets.
struct InsetPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
    }
}

func containerDisplayName(_ container: String) -> String {
    switch container.lowercased() {
    case "mov": "QuickTime (.mov)"
    case "mp4": "MPEG-4 (.mp4)"
    case "m4v": "MPEG-4 (.m4v)"
    case "mkv": "Matroska (.mkv)"
    case "webm": "WebM (.webm)"
    case "wav": "WAVE (.wav)"
    default: container.uppercased()
    }
}
