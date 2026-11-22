import AppKit
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

struct StillPlacementRow: Identifiable {
    var id: String
    var title: String
    var details: String
    var isInsert: Bool
    var fragmentCount = 0
}

enum StillPlacementAction: String, CaseIterable {
    case frame = "Framing…"
    case move = "Move…"
    case resize = "Change Duration…"
    case duplicate = "Duplicate…"
    case detach = "Detach Fragment…"
    case remove = "Delete"
    case relink = "Relink Image…"

    func title(for row: StillPlacementRow) -> String {
        if self == .resize && !row.isInsert { return "Trim…" }
        if self == .duplicate && row.isInsert { return "Duplicate" }
        return rawValue
    }
}

struct StillAuthoringControls: View {
    var rows: [StillPlacementRow]
    var enabled: Bool
    var canReplace: Bool
    var canInsert: Bool
    var replace: () -> Void
    var insert: () -> Void
    var manage: (StillPlacementRow, StillPlacementAction) -> Void

    var body: some View {
        Menu {
            Button("Replace Picture…", action: replace).disabled(!canReplace)
                .help("Replace picture with still")
            Button("Insert Still…", action: insert).disabled(!canInsert)
                .help("Insert a still image")
            if !rows.isEmpty {
                Divider()
                ForEach(rows) { row in
                    Menu(row.title) {
                        Text(row.details)
                        ForEach(StillPlacementAction.allCases.filter { $0 != .detach || row.fragmentCount > 1 }, id: \.self) { action in
                            Button(action.title(for: row), role: action == .remove ? .destructive : nil) {
                                manage(row, action)
                            }
                            .help(action.title(for: row))
                        }
                    }
                    .help("Manage this still")
                }
            }
        } label: {
            Label("Stills", systemImage: "photo.on.rectangle")
        }
        .disabled(!enabled)
        .help("Manage still images")
    }
}

@MainActor
enum StillPanels {
    private static let imageExtensions = Set(StillImage.filenameExtensions)

    static func isSupportedImage(_ url: URL) -> Bool {
        StillImage.isImageInput(url)
    }

    nonisolated static func asset(for url: URL, existing: [StillAsset] = []) throws -> StillAsset {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        let identity = try SourceIdentity(path)
        _ = try StillImage.inspect(path)
        let fingerprint = try StillImage.fingerprint(path)
        guard try SourceIdentity(path) == identity else {
            throw CutError(code: "source_changed", message: "The image changed while importing it.")
        }
        if let asset = existing.first(where: { $0.file == path.path && $0.fingerprint == fingerprint }) {
            return asset
        }
        return StillAsset(id: UUID().uuidString, file: path.path,
                          displayName: url.lastPathComponent, fingerprint: fingerprint)
    }

    static func frame(title: String, framing: StillImageFraming, in window: NSWindow?,
                      completion: @escaping (StillImageFraming) -> Void) {
        let mode = NSPopUpButton()
        mode.toolTip = "Fit or fill canvas"
        mode.addItems(withTitles: ["Fit", "Fill"])
        mode.selectItem(at: framing.mode == .fit ? 0 : 1)
        let color = NSColorWell()
        color.toolTip = "Choose background color"
        let hex = UInt32(framing.background.dropFirst(), radix: 16) ?? 0
        color.color = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                              green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        let crop = framing.crop
        let x = NSTextField(string: crop?.x.description ?? "0")
        x.toolTip = "Set horizontal crop offset"
        let y = NSTextField(string: crop?.y.description ?? "0")
        y.toolTip = "Set vertical crop offset"
        let width = NSTextField(string: crop?.width.description ?? "1")
        width.toolTip = "Set crop width"
        let height = NSTextField(string: crop?.height.description ?? "1")
        height.toolTip = "Set crop height"
        present(title: title, fields: [("Mode", mode), ("Background", color), ("Crop X (0–1)", x),
                                      ("Crop Y (0–1)", y), ("Crop Width (0–1)", width), ("Crop Height (0–1)", height)],
                in: window) {
            do {
                func number(_ field: NSTextField) throws -> RationalTime {
                    try RationalTime(parsing: field.stringValue.trimmingCharacters(in: .whitespaces))
                }
                let rect = try StillImageFraming.Crop(x: number(x), y: number(y), width: number(width), height: number(height))
                let rgb = color.color.usingColorSpace(.sRGB) ?? .black
                let background = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                        Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                let unit = RationalTime(numerator: 1)
                let isIdentity = rect.x == .zero && rect.y == .zero && rect.width == unit && rect.height == unit
                let result = StillImageFraming(mode: mode.indexOfSelectedItem == 0 ? .fit : .fill,
                                                crop: isIdentity ? nil : rect, background: background)
                try result.validate()
                completion(result)
            } catch { ProjectPanels.present(NSAlert(error: error), in: window) }
        }
    }

    static func chooseImage(in window: NSWindow?, dismissed: (() -> Void)? = nil, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Still Image"
        panel.allowedContentTypes = imageExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        ProjectPanels.present(panel, in: window) { accepted in
            dismissed?()
            if accepted, let url = panel.url { completion(url) }
        }
    }

    static func text(title: String, label: String, value: String, in window: NSWindow?,
                     completion: @escaping (String) -> Void) {
        let field = NSTextField(string: value)
        field.toolTip = "Edit still name"
        present(title: title, fields: [(label, field)], in: window) { completion(field.stringValue) }
    }

    static func duration(title: String, duration: RationalTime, cadence: RationalTime, in window: NSWindow?,
                         completion: @escaping (RationalTime, RationalTime) -> Void) {
        let length = NSTextField(string: duration.description)
        length.toolTip = "Set duration in seconds"
        let rate = RationalTime(numerator: cadence.denominator, denominator: cadence.numerator)
        let fps = NSTextField(string: rate.description)
        fps.toolTip = "Set frame rate"
        present(title: title, fields: [("Duration (seconds)", length), ("Frames per second", fps)], in: window) {
            do {
                let length = try RationalTime(parsing: length.stringValue.trimmingCharacters(in: .whitespaces))
                let rate = try RationalTime(parsing: fps.stringValue.trimmingCharacters(in: .whitespaces))
                guard length > .zero, rate > .zero else {
                    throw CutError(code: "invalid_still_time", message: "Enter a positive duration and frame rate.")
                }
                completion(length, RationalTime(numerator: rate.denominator, denominator: rate.numerator))
            } catch { ProjectPanels.present(NSAlert(error: error), in: window) }
        }
    }

    static func present(title: String, fields: [(String, NSControl)], in window: NSWindow?,
                                completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Apply").toolTip = "Apply changes"
        alert.addButton(withTitle: "Cancel").toolTip = "Close without changes"
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.column(at: 1).width = 128
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        if let first = fields.first?.1 { alert.window.initialFirstResponder = first }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { result in
                if result == .alertFirstButtonReturn { completion() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            completion()
        }
    }
}
