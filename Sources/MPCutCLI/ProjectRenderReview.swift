import CryptoKit
import Foundation
import MPCutCore

struct ProjectRenderReview: Sendable {
    @TaskLocal static var preflight: ProjectRenderReview?

    private struct Source: Encodable, Sendable {
        let reference: String
        let relativeToProject: Bool
        let path: String
        let identity: SourceIdentity?
        let changeSeconds: Int?
        let changeNanoseconds: Int?

        init(_ reference: String, project: URL, relativeToProject: Bool = true) {
            let url = Self.resolve(reference, project: project, relativeToProject: relativeToProject)
            let identity = url.flatMap { try? SourceIdentity($0) }
            self.reference = reference
            self.relativeToProject = relativeToProject
            path = url?.resolvingSymlinksInPath().path ?? reference
            self.identity = identity
            changeSeconds = identity?.changeTime?.seconds
            changeNanoseconds = identity?.changeTime?.nanoseconds
        }

        func isCurrent(project: URL) -> Bool {
            guard let url = Self.resolve(reference, project: project, relativeToProject: relativeToProject),
                  url.resolvingSymlinksInPath().path == path else { return false }
            if let identity { return identity.isCurrentSnapshot(at: url) }
            return (try? SourceIdentity(url)) == nil
        }

        private static func resolve(_ reference: String, project: URL, relativeToProject: Bool) -> URL? {
            if relativeToProject { return CutProject.mediaURL(reference, relativeTo: project) }
            return try? fileURL(reference, label: "Replacement audio")
        }
    }

    private let project: URL
    private let projectArgument: String
    private let revision: ProjectDiskRevision
    private let output: URL
    private let outputPath: String
    private let outputArgument: String
    private let sources: [Source]
    let token: String

    init(project: URL, projectArgument: String, media: CutProjectMedia, output: URL, outputArgument: String,
         options: ExportOptions, useSidecar: Bool) throws {
        struct Binding: Encodable {
            let buildID: String
            let project: String
            let projectDestination: String
            let revision: String
            let output: String
            let sources: [Source]
            let options: ExportOptions
            let useSidecar: Bool
        }
        guard let revision = media.diskRevision else {
            throw CLIError("invalid_arguments", "A render plan token requires a saved project path.")
        }

        // Analysis-only references and former source paths do not participate in rendering.
        let nonRenderUses: Set<ProjectMediaUse.Kind> = [
            .original, .select, .transcript, .transcriptAnchor, .analysisAnnotation, .pendingTileReview
        ]
        let references = ProjectMedia.references(in: media.project, includePlannedSpans: false)
            .filter { !nonRenderUses.contains($0.kind) }
        var sources = Set(references.map(\.path)).sorted().map { Source($0, project: project) }
        if let replacement = options.replaceAudio {
            sources.append(Source(replacement, project: project, relativeToProject: false))
        }
        self.project = project
        self.projectArgument = projectArgument
        self.revision = revision
        self.output = output
        self.outputArgument = outputArgument
        outputPath = Self.resolvedOutput(output)
        self.sources = sources

        var settings = options
        settings.planToken = nil
        let binding = Binding(buildID: try CLIVersion.readBuildID(), project: project.path,
                              projectDestination: revision.resolvedPath,
                              revision: revision.contentDigest, output: outputPath, sources: sources, options: settings,
                              useSidecar: useSidecar)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(binding))
        token = "v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard let currentProject = try? fileURL(projectArgument, label: "Project"), currentProject == project else {
            throw Self.stale
        }
        do {
            try revision.checkCurrent(at: currentProject)
        } catch {
            throw Self.stale
        }
        guard let currentOutput = try? fileURL(outputArgument, label: "Output"),
              Self.resolvedOutput(currentOutput) == outputPath,
              sources.allSatisfy({ $0.isCurrent(project: project) }) else {
            throw Self.stale
        }
    }

    func validatePublication(at destination: URL) throws {
        // Some renders publish intermediate tracks into their staging directories.
        if destination.standardizedFileURL == output.standardizedFileURL {
            try validate()
        }
    }

    private static func resolvedOutput(_ output: URL) -> String {
        output.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(output.lastPathComponent).path
    }

    static var stale: CutError {
        CutError(code: "stale_render_plan",
                 message: "The project, source files, destination, or settings differ from the reviewed render plan. Run a new dry run.")
    }
}

struct ReviewedRenderResponse<Result: Encodable>: Encodable {
    let result: Result
    let review: ProjectRenderReview

    private enum CodingKeys: String, CodingKey { case planToken }

    func encode(to encoder: Encoder) throws {
        try result.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(review.token, forKey: .planToken)
    }
}
