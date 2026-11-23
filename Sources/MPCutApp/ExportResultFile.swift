import AppKit
import Foundation
import MPCutCore

struct ExportResultFile {
    let url: URL
    let data: Data

    @MainActor
    static func checkbox() -> NSButton {
        let control = NSButton(checkboxWithTitle: "Save Export Result JSON", target: nil, action: nil)
        control.toolTip = "Save the resolved render plan and editorial cut map next to the exported media"
        return control
    }

    static func destination(beside output: URL) -> URL {
        output.appendingPathExtension("export.json")
    }

    init(output: URL, plan: some Encodable, cutMap: ExportCutMap) throws {
        url = Self.destination(beside: output)
        try CutEngine().checkDestination(url)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        data = try encoder.encode(Result(output: output.path, plan: plan, cutMap: cutMap))
    }

    private struct Result<Plan: Encodable>: Encodable {
        let ok = true
        let dryRun = false
        let output: String
        let plan: Plan
        let cutMap: ExportCutMap
    }

    struct PacketPlan: Encodable {
        let edit: ResolvedEdit
        let mode: ExportMode
        let tracks: ExportTracks
        let audioActions: [ReencodeAudioAction]?
        let warnings: [String]
    }

    func completionMessage(for output: URL) -> String {
        do {
            let folder = url.deletingLastPathComponent().appendingPathComponent(".mpcut-export-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let staged = folder.appendingPathComponent("result.json")
            try data.write(to: staged)
            let result = publishExclusively(from: staged, to: url)
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
            return "Exported \(output.lastPathComponent) and \(url.lastPathComponent)."
        } catch {
            return "Exported \(output.lastPathComponent). Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

extension ExportPlan {
    func resultFile(for output: URL, cutMap: ExportCutMap) throws -> ExportResultFile {
        switch self {
        case .conversion(let plan):
            return try ExportResultFile(output: output, plan: plan, cutMap: cutMap)
        case .packets(let edit, let mode, let tracks):
            return try ExportResultFile(output: output,
                                        plan: ExportResultFile.PacketPlan(edit: edit, mode: mode, tracks: tracks,
                                                                          audioActions: nil, warnings: warnings),
                                        cutMap: cutMap)
        case .audio(let audio):
            return try ExportResultFile(output: output,
                                        plan: ExportResultFile.PacketPlan(edit: audio.edit, mode: audio.mode, tracks: .audio,
                                                                          audioActions: audio.actions, warnings: audio.warnings),
                                        cutMap: cutMap)
        }
    }
}
