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
    private let audioStream: Int?
    private let tracks: ExportTracks
    private let cancelled: @Sendable () -> Bool

    public init(groups: [[ClipRequest]], directory: URL, outputSuffixes: [String]? = nil, mode: ExportMode = .smart, tracks: ExportTracks = .all, audioStream: Int? = nil, audioTrackOrdinal: Int? = nil,
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
        guard mode != .encode || tracks == .all else {
            throw CutError(code: "invalid_arguments", message: "Single-track-type exports use stream copy.")
        }
        self.audioStream = audioStream
        self.tracks = tracks
        self.cancelled = cancelled
        let engine = CutEngine(cancelled: cancelled, smartTrim: mode == .smart, tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal)
        let encoder = ReencodeEngine(cancelled: cancelled)
        var indexed = media
        var resolved: [Item] = []
        let requestedFormat = container?.lowercased()
        if let format = requestedFormat, (format.isEmpty || !format.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }) {
            throw CutError(code: "unsupported_container", message: "Choose a container file extension.")
        }
        let stem = first.file.deletingPathExtension().lastPathComponent
        for (offset, clips) in groups.enumerated() {
            do {
                for clip in clips {
                    let file = clip.file.standardizedFileURL
                    if indexed[file]?.hasFullEditIndex != true {
                        indexed[file] = mode == .encode
                            ? try encoder.conversionMedia(file)
                            : try engine.inspect(file, keyframes: true)
                    }
                }
                let suffix = outputSuffixes?[offset] ?? String(format: "%03ld", offset + 1)
                let name = "\(stem)-\(suffix)"
                if mode == .encode {
                    let format = requestedFormat ?? (settings.codec == .prores ? "mov" : "mp4")
                    let output = directory.appendingPathComponent("\(name).\(format)", isDirectory: false)
                    let plan = try encoder.resolve(clips, output: output, media: indexed, container: format, settings: settings)
                    resolved.append(Item(output: output, edit: plan.edit, conversion: plan))
                } else {
                    let edit = try engine.resolve(clips, snap: snap, media: indexed, container: requestedFormat)
                    let output = directory.appendingPathComponent("\(name).\(edit.container)", isDirectory: false)
                    try engine.checkDestination(output)
                    resolved.append(Item(output: output, edit: edit, conversion: nil))
                }
            } catch let issue as CutError {
                throw CutError(code: issue.code, message: "Range \(offset + 1): \(issue.message)", segment: offset + 1,
                               boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
            }
        }
        self.mode = resolved.allSatisfy { $0.edit.tracks != .all } ? .copy : mode
        items = resolved
    }

    public func write(_ item: Item, progress: @escaping @Sendable (Double) -> Void) throws {
        if let conversion = item.conversion {
            try ReencodeEngine(cancelled: cancelled).write(conversion, to: item.output, progress: progress)
        } else {
            try CutEngine(cancelled: cancelled, smartTrim: mode == .smart, tracks: tracks, audioStream: audioStream).export(item.edit, to: item.output) {
                progress($0)
                return !cancelled()
            }
        }
    }
}
