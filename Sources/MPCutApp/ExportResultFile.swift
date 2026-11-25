import AppKit
import Foundation
import MPCutCore

struct ExportResultFile {
    let url: URL
    private let encode: (Int64?, [EncodedEdgeResult]?) throws -> Data

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
        encode = { outputBytes, edges in
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let written = ExportWriteNotices.recorded
            return try encoder.encode(Result(output: output.path, outputBytes: outputBytes, plan: plan, cutMap: cutMap,
                                             encodedEdgeResults: edges, writtenWarnings: written.isEmpty ? nil : written))
        }
    }

    private struct Result<Plan: Encodable>: Encodable {
        let ok = true
        let dryRun = false
        let output: String
        let outputBytes: Int64?
        let plan: Plan
        let cutMap: ExportCutMap
        /// What each Smart Trim edge cost as written, as `mpcut export` reports it. Absent when no edge was encoded.
        let encodedEdgeResults: [EncodedEdgeResult]?
        /// What writing changed that the plan could not know, as `mpcut export` reports it. Absent when nothing did.
        let writtenWarnings: [String]?
    }

    struct PacketPlan: Encodable {
        let edit: ResolvedEdit
        let mode: ExportMode
        let tracks: ExportTracks
        let audioActions: [ReencodeAudioAction]?
        let warnings: [String]
    }

    static func stillCompletionMessage(for output: URL, result: ExportResultFile?) -> String {
        let bytes = ExportOutputSize.bytes(at: output)
        return result?.completionMessage(for: output, outputBytes: bytes) ?? exportMessage(for: output, outputBytes: bytes) + "."
    }

    private static func exportMessage(for output: URL, outputBytes: Int64?) -> String {
        let message = "Exported " + output.lastPathComponent
        guard let outputBytes else { return message }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = true
        return message + " · " + formatter.string(fromByteCount: outputBytes)
    }

    /// "Exported Clip.mov and Clip.mov.export.json." after the export is written. `encodedEdges` are the Smart Trim
    /// edges it wrote, saved under `encoded_edge_results` as `mpcut export` reports them.
    func completionMessage(for output: URL, outputBytes: Int64? = nil, encodedEdges: [EncodedEdgeResult] = []) -> String {
        let message = Self.exportMessage(for: output, outputBytes: outputBytes)
        do {
            let data = try encode(outputBytes, encodedEdges.isEmpty ? nil : encodedEdges)
            let folder = url.deletingLastPathComponent().appendingPathComponent(".mpcut-export-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let staged = folder.appendingPathComponent("result.json")
            try data.write(to: staged)
            let result = publishExclusively(from: staged, to: url)
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
            return "\(message) and \(url.lastPathComponent)."
        } catch {
            return "\(message). Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
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
                                                                          audioActions: nil, warnings: reportedWarnings),
                                        cutMap: cutMap)
        case .audio(let audio):
            return try ExportResultFile(output: output,
                                        plan: ExportResultFile.PacketPlan(edit: audio.edit, mode: audio.mode, tracks: .audio,
                                                                          audioActions: audio.actions, warnings: reportedWarnings),
                                        cutMap: cutMap)
        }
    }
}
