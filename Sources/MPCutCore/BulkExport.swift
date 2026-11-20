import Foundation

/// Each group makes one independent movie. Every group is planned before the first write.
public struct BulkExport: Sendable {
    public struct Item: Sendable {
        public let output: URL
        public let edit: ResolvedEdit
        public let conversion: ReencodePlan?
    }

    public let items: [Item]
    public let mode: ExportMode
    private let cancelled: @Sendable () -> Bool

    public init(groups: [[ClipRequest]], directory: URL, outputSuffixes: [String]? = nil, mode: ExportMode = .smart,
                container: String? = nil, snap: SnapMode = .exact, settings: ReencodeSettings = .init(),
                media: [URL: MediaInfo] = [:], cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        guard let first = groups.first?.first else {
            throw CutError(code: "empty_edit", message: "Add at least one range to export.")
        }
        if let outputSuffixes {
            guard outputSuffixes.count == groups.count,
                  Set(outputSuffixes.map { $0.lowercased() }).count == groups.count,
                  outputSuffixes.allSatisfy({ suffix in
                      !suffix.isEmpty && suffix.utf8.allSatisfy {
                          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                      }
                  }) else {
                throw CutError(code: "invalid_output", message: "Export filenames require unique letters, numbers or hyphens.")
            }
        }
        self.mode = mode
        self.cancelled = cancelled
        let engine = CutEngine(cancelled: cancelled, smartTrim: mode == .smart)
        let encoder = ReencodeEngine(cancelled: cancelled)
        var indexed = media
        var resolved: [Item] = []
        var format = container?.lowercased()
        if let format, (format.isEmpty || !format.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }) {
            throw CutError(code: "unsupported_container", message: "Choose a container file extension.")
        }
        let stem = first.file.deletingPathExtension().lastPathComponent
        for (offset, clips) in groups.enumerated() {
            do {
                for clip in clips {
                    let file = clip.file.standardizedFileURL
                    if indexed[file]?.frames.isEmpty != false {
                        indexed[file] = mode == .encode
                            ? try Probe.read(file, conversion: true, cancelled: cancelled)
                            : try engine.inspect(file, keyframes: true)
                    }
                }
                if format == nil {
                    if mode == .encode { format = settings.codec == .prores ? "mov" : "mp4" }
                    else if let info = indexed[first.file.standardizedFileURL] {
                        format = engine.suggestedContainers(for: info).first
                    }
                }
                guard let format else {
                    throw CutError(code: "unsupported_container", message: "No compatible output container.")
                }
                let suffix = outputSuffixes?[offset] ?? String(format: "%03ld", offset + 1)
                let name = "\(stem)-\(suffix).\(format)"
                let output = directory.appendingPathComponent(name, isDirectory: false)
                if mode == .encode {
                    let plan = try encoder.resolve(clips, output: output, media: indexed, container: format, settings: settings)
                    resolved.append(Item(output: output, edit: plan.edit, conversion: plan))
                } else {
                    let edit = try engine.resolve(clips, output: output, snap: snap, media: indexed, container: format)
                    resolved.append(Item(output: output, edit: edit, conversion: nil))
                }
            } catch let issue as CutError {
                throw CutError(code: issue.code, message: "Range \(offset + 1): \(issue.message)", segment: offset + 1,
                               boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
            }
        }
        items = resolved
    }

    public func write(_ item: Item, progress: @escaping @Sendable (Double) -> Void) throws {
        if let conversion = item.conversion {
            try ReencodeEngine(cancelled: cancelled).write(conversion, to: item.output, progress: progress)
        } else {
            try CutEngine(cancelled: cancelled, smartTrim: mode == .smart).export(item.edit, to: item.output) {
                progress($0)
                return !cancelled()
            }
        }
    }
}
