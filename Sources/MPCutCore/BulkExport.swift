import Foundation

/// Each group makes one independent movie. Every group is planned before the first write.
public struct BulkExport: Sendable {
    public struct Item: Sendable {
        public let output: URL
        /// The plan of this range from the export rules.
        public let plan: ExportPlan
        /// The alternative `auto` applied to this range.
        public let applied: ExportAlternative?
        /// What was planned. It differs from the batch request when `auto` applied an alternative.
        public let request: ExportRequest

        public var edit: ResolvedEdit { plan.edit }
        public var conversion: ReencodePlan? {
            if case .conversion(let conversion) = plan { return conversion }
            return nil
        }
        /// Set for a sound-only range exported in encode mode.
        public var audio: AudioExportPlan? {
            if case .audio(let audio) = plan { return audio }
            return nil
        }
    }

    public let items: [Item]
    public let mode: ExportMode
    private let root: URL
    private let organization: ExportOrganization
    private let useSidecar: Bool
    private let cancelled: @Sendable () -> Bool

    public init(groups: [[ClipRequest]], directory: URL, outputSuffixes: [String]? = nil, outputStems: [String]? = nil, organization: ExportOrganization = .init(), mode: ExportMode = ExportRules.defaultMode(for: .movie), tracks: ExportTracks = .all, audioStream: Int? = nil, audioTrackOrdinal: Int? = nil,
                container: String? = nil, snap: SnapMode = .exact, settings: ReencodeSettings = .init(),
                media: [URL: MediaInfo] = [:], useSidecar: Bool = true, cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        guard let first = groups.first?.first else {
            throw CutError(code: "empty_edit", message: "Add at least one range to export.")
        }
        self.root = directory
        self.organization = organization
        self.useSidecar = useSidecar
        guard outputStems == nil || outputStems?.count == groups.count else {
            throw CutError(code: "invalid_output", message: "Provide a filename stem for every export range.")
        }
        let folder = try organization.directory(in: directory, create: false)
        let plannedSubfolder = organization.subfolder.isEmpty ? nil : folder
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
        if ExportRules.cell(source: .movie, tracks: tracks, mode: mode).refusal != nil {
            // The matrix refuses this request for a movie. Probe only now, to give the refusal of the source's kind.
            let file = first.file.standardizedFileURL
            let indexed = media[file] ?? media[first.file]
            let picture = indexed?.hasVideo
                ?? (try? CutEngine(cancelled: cancelled, useSidecar: useSidecar).inspectSummary(file))?.hasVideo ?? true
            if let refusal = ExportRules.cell(source: picture ? .movie : .audio, tracks: tracks, mode: mode).refusal { throw refusal }
        }
        self.cancelled = cancelled
        let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar, tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal)
        let encoder = ReencodeEngine(cancelled: cancelled)
        var indexed = media
        var resolved: [Item] = []
        resolved.reserveCapacity(groups.count)
        let caseSensitive = (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames == true
        var namedOutputs: Set<String> = []
        let requestedFormat = container?.lowercased()
        if let format = requestedFormat, (format.isEmpty || !format.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }) {
            throw CutError(code: "unsupported_container", message: "Choose a container file extension.")
        }
        let stem = first.file.deletingPathExtension().lastPathComponent
        var boundaries = CutEngine.BoundaryCache()
        var standardized: [URL: URL] = [:]
        func sourceURL(_ file: URL) -> URL {
            if let known = standardized[file] { return known }
            let url = file.standardizedFileURL
            standardized[file] = url
            return url
        }
        var lastGroup: [URL: Int] = [:]
        for (offset, clips) in groups.enumerated() {
            if offset.isMultiple(of: 1_024) { try engine.checkCancellation() }
            for clip in clips { lastGroup[sourceURL(clip.file)] = offset }
        }
        // Every range resolves through the export rules, as a single export does. The rules decide from the first
        // source whether an encode re-encodes a movie or converts sound.
        let planner = ExportPlanner(cancelled: cancelled, useSidecar: useSidecar)
        let batch = ExportRequest(clips: [], mode: mode, tracks: tracks, audioStream: audioStream, audioTrackOrdinal: audioTrackOrdinal,
                                  container: requestedFormat, audio: settings.audio, codec: settings.codec, quality: settings.quality,
                                  snap: snap)
        for (offset, clips) in groups.enumerated() {
            do {
                try engine.checkCancellation()
                let files = clips.map { sourceURL($0.file) }
                // A batch can contain both audio and video groups. Select the probe
                // from this group's first source, as the single-export planner does.
                let reencodes: Bool
                if mode == .encode, tracks == .all, let file = files.first {
                    let info = try indexed[file] ?? engine.inspectSummary(file)
                    indexed[file] = info
                    reencodes = info.hasVideo
                } else {
                    reencodes = false
                }
                for file in files where indexed[file]?.url != file || indexed[file]?.hasFullEditIndex != true {
                    let previous = indexed[file].flatMap { $0.url == file ? $0 : nil }
                    if reencodes {
                        let source = try AnalysisSidecar.$readsEnabled.withValue(useSidecar && AnalysisSidecar.readsEnabled) {
                            try encoder.conversionMedia(file, indexed: previous)
                        }
                        if let previous, !previous.identity.matchesSnapshot(source.identity) {
                            throw CutError(code: "source_changed", message: "\(file.lastPathComponent) changed before export planning.")
                        }
                        indexed[file] = source
                    } else {
                        indexed[file] = try engine.inspect(file, keyframes: true, expectedIdentity: previous?.identity)
                    }
                }
                var request = batch
                request.clips = clips
                let item: (plan: ExportPlan, request: ExportRequest, applied: ExportAlternative?)
                switch planner.resolve(request, media: indexed, boundaries: &boundaries) {
                case .ready(let plan, let planned, let applied): item = (plan, planned, applied)
                case .unavailable(var issue, let offers):
                    // Report what would work for this range, as the single-file export does.
                    // Its arguments are `mpcut export` flags, so each alternative lists the clips of this range.
                    issue.alternatives = offers.isEmpty ? nil : offers.map { $0.alternative.listing($0.request.clips) }
                    throw issue
                }
                for file in files where lastGroup[file] == offset {
                    boundaries.discard(file)
                    indexed.removeValue(forKey: file)
                }
                let suffix = outputSuffixes?[offset] ?? String(format: "%03ld", offset + 1)
                let output = try organization.destination(in: folder, stem: outputStems?[offset] ?? stem,
                                                          suffix: suffix, container: item.plan.edit.container)
                let name = output.lastPathComponent
                let filenameKey = caseSensitive ? name : name.folding(options: .caseInsensitive, locale: nil)
                guard namedOutputs.insert(filenameKey).inserted else {
                    throw CutError(code: "invalid_output", message: "More than one range uses the output filename \(name).")
                }
                try engine.checkDestination(output, plannedSubfolder: plannedSubfolder)
                resolved.append(Item(output: output, plan: item.plan, applied: item.applied, request: item.request))
            } catch let issue as CutError {
                var failure = CutError(code: issue.code, message: "Range \(offset + 1): \(issue.message)", segment: offset + 1,
                                       boundary: issue.boundary, nearest: issue.nearest, track: issue.track)
                failure.alternatives = issue.alternatives
                failure.reason = issue.factor
                throw failure
            }
        }
        self.mode = resolved.allSatisfy { $0.plan.mode == .copy } ? .copy : mode
        items = resolved
    }

    public func write(_ item: Item, progress: @escaping @Sendable (Double) -> Void) throws {
        if cancelled() { throw CutError(code: "cancelled", message: "Operation cancelled.") }
        _ = try organization.directory(in: root, create: true)
        try ExportPlanner(cancelled: cancelled, useSidecar: useSidecar).write(item.plan, to: item.output) { progress($0); return !cancelled() }
    }
}
