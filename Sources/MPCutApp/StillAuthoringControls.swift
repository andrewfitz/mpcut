import AppKit
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

struct StillPlacementRow: Identifiable {
    var id: String
    var title: String
    var details: String
    var isInsert: Bool
    var isGap = false
    var fragmentCount = 0
    var mediaStatus: ProjectMediaStatus = .online
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
        if self == .frame && row.isGap { return "Gap Color…" }
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
    var insertGap: () -> Void
    var spaceClips: () -> Void
    var canSpace: Bool
    var manage: (StillPlacementRow, StillPlacementAction) -> Void
    var soundtrack: StillSoundtrackControls? = nil

    var body: some View {
        Menu {
            Button("Replace Picture…", action: replace).disabled(!canReplace)
                .help("Replace picture with still")
            Button("Insert Still…", action: insert).disabled(!canInsert)
                .help("Insert a still image")
            Button("Space Clips…", action: spaceClips).disabled(!canSpace)
            Button("Insert Color Gap…", action: insertGap).disabled(!canInsert)
            if let soundtrack {
                Divider()
                soundtrack.menuItems
            }
            if !rows.isEmpty {
                Divider()
                ForEach(rows) { row in
                    Menu {
                        Text(row.details)
                        if row.mediaStatus != .online {
                            Label(row.mediaStatus.editorLabel, systemImage: row.mediaStatus.editorIcon)
                        }
                        ForEach(StillPlacementAction.allCases.filter { ($0 != .detach || row.fragmentCount > 1) && ($0 != .relink || !row.isGap) }, id: \.self) { action in
                            Button(action.title(for: row), role: action == .remove ? .destructive : nil) {
                                manage(row, action)
                            }
                            .help(action.title(for: row))
                        }
                    } label: {
                        if row.mediaStatus != .online && row.mediaStatus != .ignored {
                            Label(row.title, systemImage: row.mediaStatus.editorIcon)
                                .foregroundStyle(Color(nsColor: row.mediaStatus.editorColor))
                        } else {
                            Text(row.title)
                        }
                    }
                    .help("Manage this still")
                }
            }
        } label: {
            Label("Stills", systemImage: "photo.on.rectangle").labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Stills")
        .disabled(!enabled)
        .help("Manage still images")
    }
}

struct StillSoundtrackControls {
    var name: String?
    var canFit: Bool
    var attach: () -> Void
    var fit: () -> Void
    var remove: () -> Void
    @ViewBuilder var menuItems: some View {
        Button(name == nil ? "Attach Soundtrack…" : "Replace Soundtrack…", action: attach)
        if let name {
            Text(name)
            Button("Fit Image to Soundtrack", action: fit).disabled(!canFit)
            Button("Remove Soundtrack", action: remove)
        }
    }
}

enum ClipSpacingTiming {
    case fixed(RationalTime)
    case source

    func applying(to project: CutProject, cadence: RationalTime, background: String,
                  relativeTo projectURL: URL?) throws -> CutProject {
        switch self {
        case .fixed(let duration):
            return try project.spacingClips(duration: duration, cadence: cadence, background: background)
        case .source:
            return try project.spacingClipsUsingSourceTiming(cadence: cadence, background: background, relativeTo: projectURL)
        }
    }
}

private final class SpacingDurationField: NSTextField {
    @objc func updateAvailability(_ timing: NSPopUpButton) {
        isEnabled = timing.indexOfSelectedItem == 0
    }
}

@MainActor
enum StillPanels {
    private static let imageExtensions = Set(StillImage.filenameExtensions)

    static func isSupportedImage(_ url: URL) -> Bool {
        StillImage.isImageInput(url)
    }

    nonisolated static func asset(for url: URL, existing: [StillAsset] = [],
                                  cancelled: (() -> Bool)? = nil) throws -> StillAsset {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        let fingerprint = try StillImage.inspectAndFingerprint(path, cancelled: cancelled).fingerprint
        if let asset = existing.first(where: { $0.file == path.path && $0.fingerprint == fingerprint }) {
            return asset
        }
        return StillAsset(id: ProjectIdentifier.make(avoiding: existing.map(\.id)), file: path.path,
                          displayName: url.lastPathComponent, fingerprint: fingerprint)
    }

    nonisolated static func assets(for urls: [URL], existing: [StillAsset],
                                   cancelled: (() -> Bool)? = nil) throws -> [StillAsset] {
        var known = existing
        return try urls.map { url in
            let image = try asset(for: url, existing: known, cancelled: cancelled)
            if !known.contains(where: { $0.id == image.id }) { known.append(image) }
            return image
        }
    }

    static func frame(title: String, framing: StillImageFraming, gap: Bool = false, in window: NSWindow?,
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
        if gap {
            present(title: "Gap Color", fields: [("Color", color)], in: window) {
                completion(StillImageFraming(mode: .fit, background: rgbHex(color)))
            }
            return
        }
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
                let background = rgbHex(color)
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
        durationFields(title: title, duration: duration, cadence: cadence, color: nil, in: window, completion: completion)
    }

    private static func rgbHex(_ well: NSColorWell) -> String {
        let rgb = well.color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    static func gap(cadence: RationalTime?, in window: NSWindow?,
                    completion: @escaping (RationalTime, RationalTime, StillImageFraming) -> Void) {
        let well = NSColorWell()
        well.color = .black
        let (duration, interval) = defaultGapTiming(cadence: cadence)
        durationFields(title: "Insert Color Gap", duration: duration, cadence: interval, color: well, in: window) { length, rate in
            completion(length, rate, StillImageFraming(mode: .fit, background: rgbHex(well)))
        }
    }

    static func spaceClips(cadence: RationalTime?, in window: NSWindow?,
                           completion: @escaping (ClipSpacingTiming, RationalTime, String) -> Void) {
        let (duration, interval) = defaultGapTiming(cadence: cadence)
        let length = SpacingDurationField(string: duration.description)
        length.toolTip = "Set the same duration in seconds for every gap"
        let timing = NSPopUpButton()
        timing.addItems(withTitles: ["Fixed Duration", "Source Timing"])
        timing.selectItem(at: 0)
        timing.toolTip = "Use a fixed duration or restore the elapsed time between consecutive source ranges"
        timing.target = length
        timing.action = #selector(SpacingDurationField.updateAvailability(_:))
        let fps = frameRateField(cadence: interval)
        let color = NSColorWell()
        color.color = .black
        present(title: "Space Clips", fields: [
            ("Gap timing", timing), ("Duration (seconds)", length), ("Frames per second", fps), ("Color", color)
        ], in: window) {
            do {
                let rate = try readTime(fps)
                guard rate > .zero else {
                    throw CutError(code: "invalid_still_time", message: "Enter a positive frame rate.")
                }
                let choice: ClipSpacingTiming
                if timing.indexOfSelectedItem == 0 {
                    let duration = try readTime(length)
                    guard duration >= .zero else {
                        throw CutError(code: "invalid_still_time", message: "Enter a nonnegative duration.")
                    }
                    choice = .fixed(duration)
                } else {
                    choice = .source
                }
                completion(choice, RationalTime(numerator: rate.denominator, denominator: rate.numerator), rgbHex(color))
            } catch { ProjectPanels.present(NSAlert(error: error), in: window) }
        }
    }

    private static func defaultGapTiming(cadence: RationalTime?) -> (duration: RationalTime, cadence: RationalTime) {
        let interval = cadence ?? RationalTime(numerator: 1, denominator: 30)
        let frames = Int64(max(1, min(1_000, (2 / interval.seconds).rounded())))
        let duration = (try? interval.multiplied(by: .init(numerator: frames))) ?? interval
        return (duration, interval)
    }

    private static func frameRateField(cadence: RationalTime) -> NSTextField {
        let rate = RationalTime(numerator: cadence.denominator, denominator: cadence.numerator)
        let fps = NSTextField(string: rate.description)
        fps.toolTip = "Set frame rate"
        return fps
    }

    private static func readTime(_ field: NSTextField) throws -> RationalTime {
        try RationalTime(parsing: field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    private static func durationFields(title: String, duration: RationalTime, cadence: RationalTime, color: NSColorWell?,
                                       in window: NSWindow?, completion: @escaping (RationalTime, RationalTime) -> Void) {
        let length = NSTextField(string: duration.description)
        length.toolTip = "Set duration in seconds"
        let fps = frameRateField(cadence: cadence)
        var fields: [(String, NSControl)] = [("Duration (seconds)", length), ("Frames per second", fps)]
        if let color { fields.append(("Color", color)) }
        present(title: title, fields: fields, in: window) {
            do {
                let length = try readTime(length)
                let rate = try readTime(fps)
                guard length > .zero, rate > .zero else {
                    throw CutError(code: "invalid_still_time", message: "Enter a positive duration and frame rate.")
                }
                completion(length, RationalTime(numerator: rate.denominator, denominator: rate.numerator))
            } catch { ProjectPanels.present(NSAlert(error: error), in: window) }
        }
    }

    static func present(title: String, fields: [(String, NSControl)], in window: NSWindow?,
                        dismissed: (() -> Void)? = nil,
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
                dismissed?()
                if result == .alertFirstButtonReturn { completion() }
            }
        } else {
            let result = alert.runModal()
            dismissed?()
            if result == .alertFirstButtonReturn { completion() }
        }
    }
}
