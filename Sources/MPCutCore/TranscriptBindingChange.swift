import Foundation

/// One directional transition between two retained edit states. Transcript assets and
/// attachments created after the edit remain in the current transcript store.
package struct TranscriptBindingChange: Codable, Equatable, Sendable {
    let attachmentID: String
    package let trackID: String
    package let before: TranscriptBinding
    package let after: TranscriptBinding

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case trackID = "track_id"
        case before, after
    }

    init(attachmentID: String, trackID: String, before: TranscriptBinding, after: TranscriptBinding) {
        self.attachmentID = attachmentID
        self.trackID = trackID
        self.before = before
        self.after = after
    }

    package init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_cut_history")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachmentID = try values.decode(String.self, forKey: .attachmentID)
        trackID = try values.decode(String.self, forKey: .trackID)
        before = try values.decode(TranscriptBinding.self, forKey: .before)
        after = try values.decode(TranscriptBinding.self, forKey: .after)
        try validate()
    }

    func validate() throws {
        try before.validate()
        try after.validate()
        guard validStillID(attachmentID), trackID == before.trackID, trackID == after.trackID, before != after else {
            throw CutError(code: "invalid_cut_history", message: "Invalid transcript binding change.")
        }
    }

    package var reversed: Self {
        Self(attachmentID: attachmentID, trackID: trackID, before: after, after: before)
    }

    package func mappingPaths(_ transform: (String) -> String) -> Self {
        mappingBindings(before: { $0.mapSourcePaths(transform) }, after: { $0.mapSourcePaths(transform) })
    }

    func mappingBindings(before: (TranscriptBinding) -> TranscriptBinding,
                         after: (TranscriptBinding) -> TranscriptBinding) -> Self {
        Self(attachmentID: attachmentID, trackID: trackID, before: before(self.before), after: after(self.after))
    }

    struct Key: Hashable {
        let attachment: String
        let track: String
    }

    var key: Key { Key(attachment: attachmentID, track: trackID) }

    package static func changes(from: ProjectTranscripts, to: ProjectTranscripts) -> [Self] {
        let oldAttachments = Dictionary(from.attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Self] = []
        for attachment in to.attachments {
            guard let old = oldAttachments[attachment.id] else { continue }
            let bindings = Dictionary(old.bindings.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
            for binding in attachment.bindings {
                if let before = bindings[binding.trackID], before != binding {
                    result.append(Self(attachmentID: attachment.id, trackID: binding.trackID, before: before, after: binding))
                }
            }
        }
        return result
    }

    @discardableResult
    package static func apply(_ changes: [Self], to transcripts: inout ProjectTranscripts) -> Bool {
        guard !changes.isEmpty else { return false }
        let transitions = Dictionary(changes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for i in transcripts.attachments.indices {
            for j in transcripts.attachments[i].bindings.indices {
                let binding = transcripts.attachments[i].bindings[j]
                let key = Key(attachment: transcripts.attachments[i].id, track: binding.trackID)
                guard let transition = transitions[key], transition.before == binding else { continue }
                transcripts.attachments[i].bindings[j] = transition.after
                changed = true
            }
        }
        return changed
    }
}

extension ProjectTranscripts {
    var attachmentRecordCount: Int {
        attachments.reduce(attachments.count) { $0 + $1.bindings.count }
    }
}
