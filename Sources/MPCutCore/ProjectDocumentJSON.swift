import Foundation

extension ProjectFile {
    /// The project document inside a file's bytes, as plain JSON, with the refs table written out
    /// again. Bytes that are already a plain document come back as they are.
    package static func documentJSON(_ saved: Data, multicam: Bool = false) throws -> Data {
        let code = multicam ? "invalid_multicam_project" : "invalid_cut_project"
        return ProjectHistoryStamp.verified(try ProjectKeyedLayout.expanded(saved, code: code) ?? saved)
    }

    /// The plain document of the project saved at `url`.
    package static func documentJSON(at url: URL, multicam: Bool = false) throws -> Data {
        try documentJSON(readBytes(from: url, multicam: multicam), multicam: multicam)
    }
}

extension CutProject {
    /// The plain JSON document of the project saved at `url`.
    public static func documentJSON(at url: URL) throws -> Data {
        try ProjectFile.documentJSON(at: url)
    }

    /// The plain JSON document of a project file's bytes, for a tool that reads a project
    /// without loading it.
    public static func documentJSON(saved: Data) throws -> Data {
        try ProjectFile.documentJSON(saved)
    }

    /// That document with one member to a line, for a script or a person to read. The same
    /// project gives the same text however its file is laid out.
    public static func readableDocument(saved: Data) throws -> Data {
        let plain = try ProjectFile.documentJSON(saved)
        guard !plain.contains(0), String(data: plain, encoding: .utf8) != nil, let text = ProjectSavedLayout.readable(plain) else {
            throw CutError(code: "invalid_cut_project", message: "Project must contain a UTF-8 JSON object")
        }
        return text
    }
}
