import Foundation

/// Premiere owns the native project codec. Its UXP companion handles open, import and save.
public enum PremiereInterchange {
    private static let protocolVersion = 3

    public static func read(_ url: URL, allowLoss: Bool) throws -> (CutProject, [String]) {
        let imported = try readDocument(url, allowLoss: allowLoss)
        return (imported.project, imported.warnings)
    }

    package static func readDocument(_ url: URL, allowLoss: Bool) throws
        -> (project: CutProject, warnings: [String], mediaSnapshot: ProjectMediaSnapshot) {
        let source = url.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "prproj",
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CutError(code: "invalid_premiere_project", message: "Choose a regular .prproj file.")
        }
        let nativeWarning = "Premiere translates its active sequence through sequence XML. Bins, keyframes, Lumetri grades, graphic templates, audio processing, and other host-only settings may be omitted."
        guard allowLoss else { throw CutError(code: "conversion_loss", message: nativeWarning) }
        let mailbox = try activeMailbox()
        return try withStage(in: FileManager.default.temporaryDirectory) { stage in
            let xml = stage.appendingPathComponent("sequence.xml")
            // A sibling clone preserves the relative media search directory and isolates unsaved host edits.
            let sibling = source.deletingLastPathComponent().appendingPathComponent(".mpcut-\(UUID().uuidString).prproj")
            let copy: URL
            do { try FileManager.default.copyItem(at: source, to: sibling); copy = sibling }
            catch {
                copy = stage.appendingPathComponent("Input.prproj")
                try FileManager.default.copyItem(at: source, to: copy)
            }
            defer { try? FileManager.default.removeItem(at: copy) }
            let warnings = try request("read", project: copy, xml: xml, mailbox: mailbox, allowLoss: allowLoss)
            let imported = try PremiereTimeline.readDocument(xml, allowLoss: allowLoss)
            var translations: [String] = []
            for log in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.fileSizeKey])
                where log.pathExtension.lowercased() == "txt" {
                let handle = try FileHandle(forReadingFrom: log)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 16_384) ?? Data()
                let lines = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasSuffix(":") }
                translations += lines.prefix(16).map { "Premiere translation: " + $0 }
                if lines.count > 16 || bytes.count == 16_384 {
                    translations.append("Premiere reported additional translation issues. Export the sequence XML in Premiere to see its complete translation log.")
                }
            }
            return (imported.project, [nativeWarning] + warnings + imported.warnings + translations, imported.mediaSnapshot)
        }
    }

    public static func write(_ project: CutProject, relativeTo location: URL, to output: URL,
                             allowLoss: Bool, flattenMulticam: Bool = false,
                             cancelled: @escaping () -> Bool = { false }) throws -> [String] {
        try ProjectConverter.checkCancellation(cancelled)
        try project.validateDestination(output, relativeTo: location)
        guard output.pathExtension.lowercased() == "prproj" else {
            throw CutError(code: "invalid_premiere_project", message: "Choose a .prproj destination.")
        }
        let conversion = try ProjectConverter.prepareForInterchange(project, for: "Adobe Premiere Pro .prproj", allowLoss: allowLoss)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CutError(code: "output_exists", message: "The destination already exists at \(output.path).")
        }
        return try withStage(in: output.deletingLastPathComponent()) { stage in
            let native = stage.appendingPathComponent(output.lastPathComponent)
            let xml = stage.appendingPathComponent("sequence.xml")
            var warnings = try conversion.warnings + PremiereTimeline.write(conversion.project, relativeTo: location, to: xml,
                                                     name: output.deletingPathExtension().lastPathComponent,
                                                     allowLoss: allowLoss, flattenMulticam: flattenMulticam)
            let expected = try PremiereTimeline.nativeAngles(in: xml)
            try ProjectConverter.checkCancellation(cancelled)
            let mailbox = try activeMailbox()
            warnings += try request("write", project: native, xml: xml, mailbox: mailbox, allowLoss: allowLoss, expectedAngles: expected)
            guard (try native.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw CutError(code: "premiere_save_failed", message: "Premiere returned an empty project.")
            }
            try ProjectConverter.checkCancellation(cancelled)
            let result = publishExclusively(from: native, to: output)
            guard result == 0 else {
                throw CutError(code: result == EEXIST ? "output_exists" : "premiere_save_failed",
                               message: "Could not publish \(output.path): \(String(cString: strerror(result)))")
            }
            return warnings
        }
    }

    private static func withStage<T>(in directory: URL, _ body: (URL) throws -> T) throws -> T {
        let stage = directory.appendingPathComponent(".mpcut-premiere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        return try body(stage)
    }

    private static func activeMailbox() throws -> URL {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Adobe/UXP/PluginsStorage/PPRO")
        let versions = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let candidates = versions.flatMap { version in
            ["External", "Developer"].map { version.appendingPathComponent("\($0)/com.mpcut.project-converter/PluginData") }
        }
        for mailbox in candidates {
            let ready = mailbox.appendingPathComponent("ready-v\(protocolVersion)")
            if let modified = try? ready.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               abs(modified.timeIntervalSinceNow) < 10 { return mailbox }
        }
        throw CutError(code: "premiere_unavailable",
                       message: "Open Premiere and its Window > UXP Plugins > MPCut Project Converter panel. Install MPCut Premiere.ccx from MPCut.app/Contents/Resources if needed. See docs/PREMIERE.md.")
    }

    private struct Request: Encodable {
        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case operation
            case project = "project_path"
            case timeline = "timeline_xml_path"
            case allowLoss = "allow_loss"
            case expectedAngles = "expected_angle_numbers"
        }
        let protocolVersion = PremiereInterchange.protocolVersion
        let operation: String
        let project: String
        let timeline: String
        let allowLoss: Bool
        let expectedAngles: [Int]
    }
    private struct Result: Decodable {
        let warnings: [String]?
        let error: String?
    }

    private static func request(_ operation: String, project: URL, xml: URL, mailbox: URL,
                                allowLoss: Bool, expectedAngles: [Int] = []) throws -> [String] {
        let id = UUID().uuidString
        let request = mailbox.appendingPathComponent("job-\(id).json")
        let response = mailbox.appendingPathComponent("result-\(id).json")
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
        }
        let job = Request(operation: operation, project: project.path, timeline: xml.path, allowLoss: allowLoss, expectedAngles: expectedAngles)
        try JSONEncoder().encode(job).write(to: request, options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        repeat {
            if let data = try? Data(contentsOf: response), let result = try? JSONDecoder().decode(Result.self, from: data) {
                if let error = result.error { throw CutError(code: "premiere_conversion_failed", message: error) }
                if let warnings = result.warnings { return warnings }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw CutError(code: "premiere_timeout", message: "Premiere did not finish in three minutes. Check its converter panel and open dialogs.")
    }
}
