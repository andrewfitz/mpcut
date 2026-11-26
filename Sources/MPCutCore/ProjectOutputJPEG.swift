import Foundation

package struct ProjectOutputJPEG {
    package let project: CutProject
    package let document: URL
    package let timeline: StillTimelinePlan
    let picture: ParticipantOutputPicture
    let cancelled: @Sendable () -> Bool

    package init(_ project: CutProject, document: URL?, cancelled: @escaping @Sendable () -> Bool) throws {
        self.project = project
        self.document = document ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("timeline.cut")
        self.cancelled = cancelled
        timeline = try project.resolveStills()
        picture = try ParticipantOutputPicture(project: project, document: self.document, forceSDR: true, cancelled: cancelled)
    }

    package struct Frame: Sendable {
        package let data: Data
        package let width, height: Int
        package let range: MulticamRange
        package let frameTime, duration: RationalTime
        package let privacyIssues: [ParticipantPrivacyIssue]
    }

    package func frame(at time: RationalTime, preset: JPEGPreset) throws -> Frame {
        guard let index = timeline.pictureIndex(at: time) else {
            throw CutError(code: "invalid_range", message: "Frame time \(time) is outside the program.")
        }
        let jpeg = try picture.jpeg(at: time, preset: preset)
        let timing = try picture.frameTiming(at: time)
        return Frame(data: jpeg.data, width: jpeg.width, height: jpeg.height, range: timeline.spans[index].output,
                     frameTime: timing.at, duration: timing.length, privacyIssues: try picture.privacyIssues(at: time))
    }

    package func verifySources() throws { try picture.verifySources() }

    /// The rendered program's full size, before a review scales or crops it.
    package var nativeSize: CGSize { picture.nativeSize }

    private struct Manifest: Encodable {
        let schemaVersion = 2
        let selection = "program"
        let preset: JPEGPreset
        let frames: [Entry]

        struct Entry: Encodable {
            let file: String
            let time: RationalTime
            let width, height: Int
            let privacyIssues: [ParticipantPrivacyIssue]?

            private enum CodingKeys: String, CodingKey {
                case file, time, width, height
                case privacyIssues = "privacy_issues"
            }
        }
    }

    package func writeDirectory(at times: [RationalTime], to output: URL,
                                preset: JPEGPreset) throws -> [ParticipantPrivacyIssue] {
        try project.validateDestination(output, relativeTo: document, includesContents: true)
        var issues: [ParticipantPrivacyIssue] = []
        _ = try JPEGExport.writeProgramFrameDirectory(to: output, cancelled: cancelled, validate: {
            try project.validateDestination(output, relativeTo: document, includesContents: true)
            try verifySources()
        }) { staging in
            let frames = try times.enumerated().map { index, time in
                let frame = try self.frame(at: time, preset: preset)
                let name = String(format: "%06d.jpg", index + 1)
                try frame.data.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
                issues.append(contentsOf: frame.privacyIssues)
                return Manifest.Entry(file: name, time: time, width: frame.width, height: frame.height,
                                      privacyIssues: frame.privacyIssues.isEmpty ? nil : frame.privacyIssues)
            }
            return Manifest(preset: preset, frames: frames)
        }
        return issues
    }

    @discardableResult
    package func writeStill(at time: RationalTime, to output: URL, replacing: SourceIdentity? = nil,
                            preset: JPEGPreset) throws -> Frame {
        try project.validateDestination(output, relativeTo: document)
        let rendered = try frame(at: time, preset: preset)
        try JPEGExport.publishStillJPEG(rendered.data, source: nil, sourceIdentity: nil, to: output,
                                        replacing: replacing, cancelled: cancelled) {
            try project.validateDestination(output, relativeTo: document)
            try verifySources()
        }
        return rendered
    }
}

extension ParticipantRenderReport {
    package var picturePrivacyNotice: String? {
        var notices: [String] = []
        if let first = privacyIssues.first {
            let count = privacyIssues.count
            let ranges = count == 1 ? "1 output range" : "\(count) output ranges"
            notices.append("Privacy coverage applied in \(ranges), starting at \(first.output.from).")
        }
        if let unscannedSourceIDs, !unscannedSourceIDs.isEmpty {
            let recordings = unscannedSourceIDs.map { "‘\($0)’" }.joined(separator: ", ")
            notices.append("No accepted tile scan for \(recordings). Feed treatments use accepted tile geometry.")
        }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }
}
