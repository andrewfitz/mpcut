import Foundation

public struct TranscriptZoomParticipant: Codable, Equatable, Sendable {
    public let path: String
    public var speaker: String
}

/// A read-only Transcriberrr plan. The provider owns file discovery, meeting identity,
/// renamed-export matching, and speaker naming.
struct TranscriptZoomPlan: Decodable {
    struct File: Decodable {
        let path: String
        var zoom_audio_copy_clock_verified: Bool? = nil
        var error: String? = nil
        let zoom_segment: Int?
        let meeting: String?
        let covered_by: [String]?
        let iso: Bool?
        let speaker: String?
    }
    let schema_version: Int
    let files: [File]

    // Older helpers cover a whole meeting in one row. Only a numbered Zoom
    // recording identifies which segment's local clock it uses.
    private func legacyRecordingSegment(_ path: String, meetingID: String) -> Int? {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        let digits = String(stem.reversed().prefix(while: \.isNumber).reversed())
        let prefix = stem.dropLast(digits.count)
        if prefix == "zoom_", (1...2).contains(digits.count) { return Int(digits) }
        guard ["audio", "video", "video_"].contains(String(prefix)) ||
                ["shared_screen", "speaker_view", "gallery_view"].contains(where: { prefix.hasPrefix($0) })
        else { return nil }
        if digits == meetingID { return 0 }
        guard digits.count == 10, digits.dropFirst() == meetingID else { return nil }
        return digits.first?.wholeNumberValue
    }

    func participants(for media: URL) -> [TranscriptZoomParticipant] {
        let path = media.standardizedFileURL.resolvingSymlinksInPath().path
        guard schema_version == 1, let mix = files.first(where: {
            $0.covered_by != nil && URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == path
        }),
              let meeting = mix.meeting, let meetingID = meeting.split(separator: "|").last.map(String.init),
              let covered = mix.covered_by, !covered.isEmpty, Set(covered).count == covered.count else { return [] }
        let stem = media.deletingPathExtension().lastPathComponent.lowercased()
        let segmentByName = legacyRecordingSegment(mix.path, meetingID: meetingID)
        let undatedAudio = stem.hasPrefix("audio_only") && stem.dropFirst("audio_only".count).allSatisfy(\.isNumber)
        guard segmentByName != nil || undatedAudio || mix.zoom_audio_copy_clock_verified == true else { return [] }
        let members = Dictionary(grouping: files.filter { $0.iso == true && $0.meeting == meeting }, by: \.path)
        var tracks: [(Int, TranscriptZoomParticipant)] = []
        for path in covered {
            guard let rows = members[path], rows.count == 1, let speaker = rows[0].speaker,
                  !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  path.hasPrefix("/"), path != mix.path else { return [] }
            // covered_by is meeting-wide. A stopped/restarted recording has a separate
            // zero-based media clock for each segment. The nine trailing digits are
            // the meeting ID, preceded by a segment digit on modern participant files.
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let digits = stem.reversed().prefix(while: \.isNumber)
            let segment = rows[0].zoom_segment ?? (digits.count >= 11 ? digits.dropFirst(9).first?.wholeNumberValue : 0)
            guard let segment else { return [] }
            tracks.append((segment, .init(path: path, speaker: speaker)))
        }
        if let segment = mix.zoom_segment ?? segmentByName {
            tracks = tracks.filter { $0.0 == segment }
        } else {
            let recordings = files.filter { $0.meeting == meeting && $0.covered_by != nil }
            let segments = recordings.compactMap { $0.zoom_segment ?? legacyRecordingSegment($0.path, meetingID: meetingID) }
            guard Set(tracks.map(\.0)).union(segments).count == 1 else { return [] }
        }
        return tracks.map(\.1)
    }
}

extension TranscriptJobStore {
    public static func zoomParticipants(for media: URL, helper: URL,
                                        cancelled: () -> Bool = { false }) throws -> [TranscriptZoomParticipant] {
        let inventory = try zoomInventory(for: [media], helper: helper, cancelled: cancelled)
        if let message = inventory.errors[media] { throw CutError(code: "transcript_zoom_inventory", message: message) }
        return inventory.participants[media] ?? []
    }

    /// One provider scan for several project recordings sharing a directory.
    package static func zoomInventory(for media: [URL], helper: URL, cancelled: () -> Bool) throws
        -> (participants: [URL: [TranscriptZoomParticipant]], errors: [URL: String]) {
        guard !media.isEmpty else { return ([:], [:]) }
        let command = TranscriptProviderCommand(helper: helper, directory: FileManager.default.temporaryDirectory)
        let response = try command.run(["--plan", "--inventory-only", "--offline", "--"] + media.map(\.path),
                                       stall: 30, cancelled: cancelled)
        try response.check()
        let plan = try JSONDecoder().decode(TranscriptZoomPlan.self, from: response.output)
        var participants: [URL: [TranscriptZoomParticipant]] = [:]
        var errors: [URL: String] = [:]
        let rejected = Dictionary(plan.files.compactMap { row in
            row.error.map { (URL(fileURLWithPath: row.path).standardizedFileURL.resolvingSymlinksInPath(), $0) }
        }, uniquingKeysWith: { first, _ in first })
        for file in media {
            if cancelled() { throw CancellationError() }
            if let issue = rejected[file.standardizedFileURL.resolvingSymlinksInPath()] {
                errors[file] = issue
            } else {
                participants[file] = plan.participants(for: file)
            }
        }
        return (participants, errors)
    }
}
