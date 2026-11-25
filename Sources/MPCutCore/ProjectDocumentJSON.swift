import Foundation

extension ProjectFile {
    /// The project document inside a file's bytes, as plain JSON, with the refs table written out
    /// again. Bytes that are already a plain document come back as they are.
    package static func documentJSON(_ saved: Data, multicam: Bool = false) throws -> Data {
        let code = multicam ? "invalid_multicam_project" : "invalid_cut_project"
        return try ProjectKeyedLayout.expanded(saved, code: code, verifyingHistory: true) ?? ProjectHistoryStamp.verified(saved)
    }

    /// The plain document of the project saved at `url`.
    package static func documentJSON(at url: URL, multicam: Bool = false) throws -> Data {
        try documentJSON(readBytes(from: url, multicam: multicam), multicam: multicam)
    }
}

extension CutProject {
    package static func allowsFraction(at locations: [JSONInputLocation]) -> Bool {
        ProjectFile.allowsProjectFraction(locations)
    }

    /// A fractional number in a refs entry takes its meaning from the field that references it.
    /// Extract the inline document before Foundation can round a token in an integer field.
    package static func validateInlineProjectNumbers(in request: Data, at keys: [String]) throws {
        let invalid = CutError(code: "invalid_cut_project", message: "Invalid inline project JSON.")
        guard var node = ProjectSavedLayout.parse(request) else { throw invalid }
        for key in keys {
            guard case .object(let members) = node,
                  let member = members.first(where: {
                      (try? JSONDecoder().decode(String.self, from: Data($0.key))) == key
                  }) else { throw invalid }
            node = member.value
        }
        let plain = try ProjectFile.documentJSON(ProjectSavedLayout.text(node, capacity: request.count))
        if let issue = jsonInputIssue(plain, integerNumbersOnly: true, allowsFraction: CutProject.allowsFraction) {
            throw CutError(code: "invalid_cut_project", message: "Project \(issue).")
        }
    }

    /// The plain JSON document of the project saved at `url`.
    public static func documentJSON(at url: URL) throws -> Data {
        try ProjectFile.documentJSON(at: url)
    }

    /// The plain JSON document of a project file's bytes, for a tool that reads a project
    /// without loading it.
    public static func documentJSON(saved: Data) throws -> Data {
        try ProjectFile.documentJSON(saved)
    }

    public static func readableDocument(at url: URL) throws -> Data {
        try readableDocument(saved: ProjectFile.readBytes(from: url))
    }

    /// That document with one member to a line, for a script or a person to read. The same
    /// project gives the same text however its file is laid out.
    public static func readableDocument(saved: Data) throws -> Data {
        let plain = try validatedDocumentJSON(saved)
        guard let text = ProjectSavedLayout.readable(plain) else {
            throw CutError(code: "invalid_cut_project", message: "Project must contain a UTF-8 JSON object")
        }
        return text
    }
}
