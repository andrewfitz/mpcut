import SwiftUI

// Shared chrome for the controls that sit in the editor's bars, pane headers and settings.
// Toolbar items keep the system glass. Everything below the toolbar is quiet until hovered.

extension View {
    /// Padding and height for a bar control's label. Apply inside the button, before the style draws its chrome.
    func barLabel() -> some View {
        self
            .lineLimit(1)
            .padding(.horizontal, EditorMetrics.barControlInset)
            .frame(height: EditorMetrics.barControlHeight)
    }

    /// The inset a status bar item without its own chrome needs to start on the bar's line.
    func barLeading() -> some View { padding(.leading, EditorMetrics.barControlInset) }

    /// Quiet chrome for a `Menu` or menu-style `Picker` in a bar: no bezel, a hover wash, and the system indicator.
    func barMenu() -> some View { modifier(BarMenuChrome()) }
}

private struct BarMenuChrome: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderless)
            .fixedSize()
            .padding(.horizontal, EditorMetrics.barControlInset)
            .frame(height: EditorMetrics.barControlHeight)
            .background(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: EditorMetrics.cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A button in a bar with a title and an optional symbol.
struct BarButton: View {
    let title: String
    var symbol: String? = nil
    var active = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title)
            }
            .barLabel()
        }
        .buttonStyle(ToolButtonStyle(active: active))
    }
}

/// An icon button for a pane header or footer. The same 24-point square as the timeline's view controls.
struct PaneIconButton: View {
    let title: String
    let symbol: String
    var active = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: EditorMetrics.paneControl, height: EditorMetrics.paneControl)
        }
        .buttonStyle(ToolButtonStyle(active: active))
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(help ?? title)
    }
}

/// The label of an icon-only `Menu` in a pane header, sized like `PaneIconButton`.
struct PaneMenuIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: EditorMetrics.paneControl, height: EditorMetrics.paneControl)
    }
}

/// Explanatory text under a settings group. A grouped form trails multi-line footers by default.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Start on the rows' text, not the group's edge.
            .padding(.horizontal, 10)
    }
}
