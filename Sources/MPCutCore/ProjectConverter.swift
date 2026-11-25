import Darwin
import Foundation

/// The CLI and desktop use the same reader, loss policy and writer for every pair.
public enum ProjectConverter {
    private enum Format: String {
        case cut, drp, drt, prproj, fcpxml, fcpxmld, fcpbundle

        init(url: URL) throws {
            guard url.isFileURL, url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true,
                  url.query == nil, url.fragment == nil, !url.path.contains("\0") else {
                throw CutError(code: "invalid_project_path", message: "Choose a local project file or package.")
            }
            guard let format = Self(rawValue: url.pathExtension.lowercased()) else {
                throw CutError(code: "unsupported_project_format",
                               message: "Use a .cut, .drp, .drt, .prproj, .fcpxml, .fcpxmld or .fcpbundle project: \(url.path)")
            }
            self = format
        }
    }

    public static func accepts(format: String, for output: URL) -> Bool {
        guard let destination = try? Format(url: output) else { return false }
        switch format {
        case "cut": return destination == .cut
        case "resolve": return destination == .drp || destination == .drt
        case "premiere": return destination == .prproj
        case "fcp": return [.fcpbundle, .fcpxml, .fcpxmld].contains(destination)
        default: return false
        }
    }

    static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CutError(code: "cancelled", message: "Project conversion cancelled.") }
    }

    /// Project the timeline into the destination format and report each omission before opening a host editor.
    static func prepareForInterchange(_ input: CutProject, for destination: String, allowLoss: Bool,
                              supportsStillInserts: Bool = false) throws -> (project: CutProject, warnings: [String]) {
        if case let .multicam(group) = input {
            let feedAngles = group.angles.filter { $0.feedAngle != nil }.map(\.id)
            if !feedAngles.isEmpty {
                throw CutError(code: "unsupported_feed_angles",
                               message: "\(destination) requires rendered media for feed angles \(feedAngles.joined(separator: ", ")). Export ISOs for handoff.")
            }
        }
        guard !input.requiresPictureProcessing else { throw ParticipantProjectExport.unsupported(destination) }
        var warnings = [String]()
        var project = input
        if !project.analysisAnnotations.isEmpty {
            warnings.append("\(destination) omits MPCut analysis annotations, including saved scene, silence and pause decisions.")
            project.analysisAnnotations = .init()
        }
        if !project.participants.pendingReviews.isEmpty {
            warnings.append("\(destination) omits MPCut pending tile reviews.")
            var participants = project.participants
            participants.pendingReviews = []
            project.participants = participants
        }
        if !input.transcripts.isEmpty {
            if !input.transcripts.attachments.isEmpty || !input.transcripts.authoring.isEmpty {
                warnings.append("\(destination) omits MPCut transcript attachments, speaker corrections and transcript selects.")
            }
            project.transcripts = .init()
        }
        func omitReplacements(_ replacements: [StillReplacement]) {
            warnings += replacements.map {
                "\(destination) cannot represent Replace Picture placement \($0.id). The underlying picture will be restored."
            }
        }
        func reportUnusedAssets(_ assets: [StillAsset], inserts: [StillInsert], replacements: [StillReplacement]) {
            let used = Set(inserts.map(\.assetID)).union(replacements.map(\.assetID))
            warnings += assets.filter { !$0.isGap && !used.contains($0.id) }.map {
                "\(destination) omits unplaced still asset \($0.id)."
            }
        }
        let insertLoss: (StillInsert, String) -> String = { insert, reason in
            "\(destination) cannot represent Insert Still placement \(insert.id): \(reason). The insert and its silence will be removed."
        }
        let gaps = Set(project.stillAssets.filter(\.isGap).map(\.id))
        func keepInsert(_ insert: StillInsert, files: [String: String]) -> Bool {
            if gaps.contains(insert.assetID) {
                warnings.append(insertLoss(insert, "this destination has no verified solid-color mapping"))
                return false
            }
            guard supportsStillInserts else {
                warnings.append(insertLoss(insert, "the destination has no verified insert mapping"))
                return false
            }
            guard insert.framing == .fit || insert.framing == .fill else {
                warnings.append(insertLoss(insert, "the image has a custom crop or background"))
                return false
            }
            guard let file = files[insert.assetID],
                  ["jpe", "jpeg", "jpg", "png", "tif", "tiff"].contains(URL(fileURLWithPath: file).pathExtension.lowercased())
            else {
                warnings.append(insertLoss(insert, "the linked asset is outside the supported JPEG, PNG and TIFF mapping"))
                return false
            }
            return true
        }
        let result: CutProject
        switch project {
        case .sequence:
            result = project
        case .stillSequence(var sequence):
            if sequence.stillSoundtrack != nil {
                warnings.append("\(destination) omits the attached still soundtrack.")
                sequence.stillSoundtrack = nil
            }
            if !sequence.sourceSelects.isEmpty {
                warnings.append("\(destination) omits MPCut named source selects.")
                sequence.sourceSelects = []
            }
            reportUnusedAssets(sequence.stillAssets, inserts: sequence.items.compactMap(\.still), replacements: sequence.stillReplacements)
            omitReplacements(sequence.stillReplacements)
            let files = Dictionary(sequence.stillAssets.map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
            sequence.items = sequence.items.filter { item in
                item.still.map { keepInsert($0, files: files) } ?? true
            }
            sequence.stillReplacements = []
            let retainedAssets = Set(sequence.items.compactMap(\.still).map(\.assetID))
            if !retainedAssets.isEmpty {
                sequence.stillAssets = sequence.stillAssets.filter { retainedAssets.contains($0.id) }
                result = .stillSequence(sequence)
            } else {
                if sequence.programColorPolicy != nil {
                    warnings.append("\(destination) omits the MPCut program color policy.")
                }
                if sequence.stillFormat != nil {
                    warnings.append("\(destination) omits the MPCut still-only project format.")
                }
                result = .sequence(sequence.items.compactMap(\.source))
            }
        case .multicam(var group):
            if group.audio == .mix {
                throw CutError(code: "unsupported_multicam_audio",
                               message: "\(destination) cannot represent simultaneous Mix lanes. Export a movie to carry the selected tracks.")
            }
            if !group.audioReplacements.isEmpty {
                throw CutError(code: "unsupported_multicam_audio",
                               message: "\(destination) cannot represent synced recording replacements. Export a movie to preserve their alignment.")
            }
            if !group.mixLanes.isEmpty {
                warnings.append("\(destination) omits the inactive Mix lane selections, labels and colours.")
                group.mixLanes = []
            }
            if let saved = group.fixedAudio, group.audio != .fixed(saved) {
                warnings.append("\(destination) omits the inactive Fixed audio selection.")
                group.fixedAudio = nil
            }
            reportUnusedAssets(group.stillAssets, inserts: group.assemblyItems?.compactMap(\.still) ?? [], replacements: group.stillReplacements)
            omitReplacements(group.stillReplacements)
            let files = Dictionary(group.stillAssets.map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
            group.assemblyItems = group.assemblyItems?.filter { item in
                guard let insert = item.still else { return true }
                return keepInsert(insert, files: files)
            }
            let retainedAssets = Set((group.assemblyItems?.compactMap(\.still) ?? []).map(\.assetID))
            group.stillAssets = group.stillAssets.filter { retainedAssets.contains($0.id) }
            if retainedAssets.isEmpty {
                if group.programColorPolicy != nil { warnings.append("\(destination) omits the MPCut program color policy.") }
                group.programColorPolicy = nil
            }
            group.stillReplacements = []
            result = .multicam(group)
        }
        if !warnings.isEmpty && !allowLoss {
            throw CutError(code: "conversion_loss", message: warnings.joined(separator: "\n"))
        }
        if !warnings.isEmpty, try result.stillTimelineDuration() == .zero {
            throw CutError(code: "empty_sequence",
                           message: "The conversion leaves no timeline material.\n" + warnings.joined(separator: "\n"))
        }
        return (result, warnings)
    }

    @discardableResult
    public static func convert(input: URL, output: URL, allowLoss: Bool = false,
                               flattenMulticam: Bool = false,
                               cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try checkCancellation(cancelled)
        let source = try Format(url: input)
        let destination = try checkDestination(output, allowLoss: allowLoss, flattenMulticam: flattenMulticam)
        let isPackage = source == .fcpxmld || source == .fcpbundle
        var sourceInfo = stat()
        guard stat(input.path, &sourceInfo) == 0,
              sourceInfo.st_mode & S_IFMT == (isPackage ? S_IFDIR : S_IFREG) else {
            throw CutError(code: "invalid_project_input", message: "Expected a readable project \(isPackage ? "package" : "file") at \(input.path).")
        }
        if isPackage {
            var ancestor = output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            while !ancestor.path.isEmpty, ancestor.path != "/" {
                var parentInfo = stat()
                if stat(ancestor.path, &parentInfo) == 0,
                   sourceInfo.st_dev == parentInfo.st_dev, sourceInfo.st_ino == parentInfo.st_ino {
                    throw CutError(code: "invalid_destination", message: "Choose an output outside the source project package.")
                }
                ancestor.deleteLastPathComponent()
            }
        }
        if source == .cut && destination == .cut {
            let document = try CutProject.loadDocument(from: input, limit: CutProject.maximumHistorySteps,
                                                       validatingDestination: output)
            try writeCut(document.project, undo: document.undo, redo: document.redo, mediaSnapshot: document.mediaSnapshot,
                         relativeTo: input, to: output, cancelled: cancelled)
            return []
        }
        let project: CutProject
        let warnings: [String]
        let mediaSnapshot: ProjectMediaSnapshot
        switch source {
        case .cut:
            let document = try CutProjectMedia.load(from: input)
            try document.validateDestination(output, relativeTo: input,
                                             includesContents: destination == .fcpxmld || destination == .fcpbundle)
            let exclusions = AnalysisSidecar.excludedSources.union(document.sidecarExclusions(relativeTo: input))
            return try AnalysisSidecar.$excludedSources.withValue(exclusions) {
                try write(document.project, relativeTo: input, to: output, allowLoss: allowLoss,
                          flattenMulticam: flattenMulticam, cancelled: cancelled)
            }
        case .drp, .drt:
            (project, warnings, mediaSnapshot) = try ResolveNativeInterchange.readDocument(input, allowLoss: allowLoss, cancelled: cancelled)
        case .prproj:
            (project, warnings, mediaSnapshot) = try PremiereInterchange.readDocument(input, allowLoss: allowLoss)
        case .fcpxml, .fcpxmld:
            (project, warnings, mediaSnapshot) = try FCPInterchange.readDocument(input, allowLoss: allowLoss)
        case .fcpbundle:
            (project, warnings, mediaSnapshot) = try FCPLibraryInterchange.readDocument(input, allowLoss: allowLoss, cancelled: cancelled)
        }
        let exportWarnings = try write(project, relativeTo: input, to: output, mediaSnapshot: mediaSnapshot, allowLoss: allowLoss,
                                       flattenMulticam: flattenMulticam, cancelled: cancelled)
        return warnings + exportWarnings
    }

    private static func checkDestination(_ output: URL, allowLoss: Bool, flattenMulticam: Bool) throws -> Format {
        let format = try Format(url: output)
        guard !flattenMulticam || (format == .prproj && allowLoss) else {
            throw CutError(code: "invalid_conversion_options", message: "Flattening multicam requires a Premiere output and explicit loss approval.")
        }
        var info = stat()
        guard lstat(output.path, &info) != 0 else {
            throw CutError(code: "destination_exists", message: "Choose a new output path: \(output.path)")
        }
        guard errno == ENOENT else {
            throw CutError(code: "invalid_destination", message: "Cannot access output path: \(output.path)")
        }
        let directory = output.deletingLastPathComponent()
        var parent = stat()
        guard stat(directory.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR else {
            throw CutError(code: "invalid_destination", message: "Choose an existing output folder: \(directory.path)")
        }
        return format
    }

    /// Export an open editor snapshot. Relative media paths use its document location.
    public static func write(_ project: CutProject, relativeTo input: URL, to output: URL,
                             mediaSnapshot: ProjectMediaSnapshot = .empty, allowLoss: Bool = false, flattenMulticam: Bool = false,
                             auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try checkCancellation(cancelled)
        let destination = try checkDestination(output, allowLoss: allowLoss, flattenMulticam: flattenMulticam)
        try project.validateDestination(output, relativeTo: input,
                                        includesContents: destination == .fcpxmld || destination == .fcpbundle)
        switch destination {
        case .cut:
            let imported = (try? Format(url: input)).map { $0 != .cut } ?? false
            try writeCut(project, undo: [], redo: [], mediaSnapshot: mediaSnapshot, relativeTo: input, to: output,
                         makeRelative: imported, cancelled: cancelled)
            return []
        case .drp, .drt:
            return try ResolveNativeInterchange.write(project, relativeTo: input, to: output, allowLoss: allowLoss,
                                                      auxiliaryOutput: auxiliaryOutput, cancelled: cancelled)
        case .prproj:
            return try PremiereInterchange.write(project, relativeTo: input, to: output, allowLoss: allowLoss,
                                                flattenMulticam: flattenMulticam, cancelled: cancelled)
        case .fcpxml, .fcpxmld:
            return try FCPInterchange.write(project, relativeTo: input, to: output, allowLoss: allowLoss,
                                            auxiliaryOutput: auxiliaryOutput, cancelled: cancelled)
        case .fcpbundle:
            return try FCPLibraryInterchange.write(project, relativeTo: input, to: output, allowLoss: allowLoss, cancelled: cancelled)
        }
    }

    private static func writeCut(_ project: CutProject, undo: [CutHistoryState], redo: [CutHistoryState],
                                 mediaSnapshot: ProjectMediaSnapshot, relativeTo input: URL, to output: URL, makeRelative: Bool = false,
                                 cancelled: () -> Bool) throws {
        var paths: [String: String] = [:]
        func rebase(_ value: CutProject) throws -> CutProject {
            try checkCancellation(cancelled)
            return try value.rebased(from: input, to: output, paths: &paths, makeRelative: makeRelative)
        }
        func rebaseState(_ state: CutHistoryState) throws -> CutHistoryState {
            try checkCancellation(cancelled)
            return try state.rebased(from: input, to: output, paths: &paths, makeRelative: makeRelative)
        }
        let document = try rebase(project)
        try document.saveNewCopy(to: output, undo: undo.map(rebaseState),
                                 redo: redo.map(rebaseState), mediaSnapshot: mediaSnapshot.rebased(
                                     from: input, to: output, makeRelative: makeRelative
                                 )) {
            try checkCancellation(cancelled)
        }
    }
}
