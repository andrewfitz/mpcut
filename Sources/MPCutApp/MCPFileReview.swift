import Foundation

enum MCPFileReview {
    static let requestTool = "review_file_frame_read"
    static let resultTool = "review_file_frame_result_read"
    static let directoryEnvironment = "MPCUT_REVIEW_JOB_DIRECTORY"

    static func arguments(_ fields: MCPFileRequest.Fields) throws -> [String] {
        var arguments = ["review", "frames", "export", "--json", "--mcp-image"]
        if fields.values["times"] != nil {
            guard fields.values["at"] == nil else { throw fields.invalid("Supply at for one frame or times for several, not both.") }
            // A request for several times answers with a list of frames, even for one time.
            arguments += ["--batch"] + (try fields.strings("times")).flatMap { ["--at", $0] }
        } else if let at = try fields.string("at") {
            arguments += ["--at", at]
        } else {
            throw fields.invalid("Supply at or times.")
        }
        arguments += try fields.reviewSize()
        if let project = try fields.path("project_path") {
            arguments += ["--project", project]
            if let clock = try fields.string("clock") { arguments += ["--clock", clock] }
        } else if let file = try fields.path("file") {
            arguments += ["--", file]
        } else {
            throw fields.invalid("Supply an absolute project_path or file.")
        }
        return arguments
    }

    @MainActor
    static func readResult(in jobs: MCPFileJobs, arguments: [String: Any]) throws -> [String: Any] {
        guard let raw = arguments["job_id"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPCommandError("invalid_arguments", "Supply the job_id returned by review_file_frame_read.")
        }
        // Reserve room for JSON metadata plus base64-encoded JPEGs: 2 MiB of them for several times.
        let data = try jobs.succeededResult(id: id, tool: requestTool, maxBytes: 3_200_000)
        guard var result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MCPCommandError("invalid_result", "The review frame result is invalid.")
        }
        result["job_id"] = id.uuidString
        return result
    }
}
