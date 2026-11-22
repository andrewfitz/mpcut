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
        switch format.lowercased() {
        case "mpcut", "cut": return destination == .cut
        case "resolve", "davinci": return destination == .drp || destination == .drt
        case "premiere", "premiere-pro": return destination == .prproj
        case "fcp", "final-cut-pro": return [.fcpbundle, .fcpxml, .fcpxmld].contains(destination)
        default: return destination.rawValue == format.lowercased()
        }
    }

    static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CutError(code: "cancelled", message: "Project conversion cancelled.") }
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
            try writeCut(document.project, undo: document.undo, redo: document.redo,
                         relativeTo: input, to: output, cancelled: cancelled)
            return []
        }
        let project: CutProject
        let warnings: [String]
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
        case .drp, .drt: (project, warnings) = try ResolveNativeInterchange.read(input, allowLoss: allowLoss, cancelled: cancelled)
        case .prproj: (project, warnings) = try PremiereInterchange.read(input, allowLoss: allowLoss)
        case .fcpxml, .fcpxmld: (project, warnings) = try FCPInterchange.read(input, allowLoss: allowLoss)
        case .fcpbundle: (project, warnings) = try FCPLibraryInterchange.read(input, allowLoss: allowLoss, cancelled: cancelled)
        }
        let exportWarnings = try write(project, relativeTo: input, to: output, allowLoss: allowLoss,
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
                             allowLoss: Bool = false, flattenMulticam: Bool = false,
                             auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try checkCancellation(cancelled)
        let destination = try checkDestination(output, allowLoss: allowLoss, flattenMulticam: flattenMulticam)
        try project.validateDestination(output, relativeTo: input,
                                        includesContents: destination == .fcpxmld || destination == .fcpbundle)
        switch destination {
        case .cut:
            try writeCut(project, undo: [], redo: [], relativeTo: input, to: output, cancelled: cancelled)
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
                                 relativeTo input: URL, to output: URL, cancelled: () -> Bool) throws {
        var paths: [String: String] = [:]
        func rebase(_ value: CutProject) throws -> CutProject {
            try checkCancellation(cancelled)
            return try value.rebased(from: input, to: output, paths: &paths)
        }
        func rebaseState(_ state: CutHistoryState) throws -> CutHistoryState {
            try CutHistoryState(action: state.action, project: rebase(state.project))
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".mpcut-\(UUID().uuidString).cut")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try rebase(project).save(to: temporary, undo: undo.map(rebaseState), redo: redo.map(rebaseState))
        try checkCancellation(cancelled)
        let code = publishExclusively(from: temporary, to: output)
        guard code == 0 else {
            throw CutError(code: "publish_failed", message: "Cannot create \(output.path): \(String(cString: strerror(code)))")
        }
    }
}
