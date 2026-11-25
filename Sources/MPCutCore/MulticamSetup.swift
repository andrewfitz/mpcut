import Foundation

extension MulticamProject {
    package mutating func updateSource(_ id: String, _ change: (inout MulticamSource) -> Void) throws {
        func updateRecording(_ source: inout MulticamSource) throws {
            let oldOffset = source.offset
            change(&source)
            if let coverage = source.coverage, source.offset != oldOffset {
                let delta = try source.offset.subtracting(oldOffset)
                source.coverage = try .init(from: coverage.from.adding(delta), to: coverage.to.adding(delta))
            }
        }
        for row in angles.indices {
            if angles[row].id == id {
                try updateRecording(&angles[row])
            } else if let index = angles[row].additionalRecordings.firstIndex(where: { $0.id == id }) {
                try updateRecording(&angles[row].additionalRecordings[index])
            }
        }
        if let row = audioSources.firstIndex(where: { $0.id == id }) {
            change(&audioSources[row])
        }
    }

    package mutating func renameSource(_ id: String, to text: String) throws {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let feed = angles.first(where: { $0.id == id })?.feedAngle {
            guard !name.isEmpty else { return }
            if let index = participants.people.firstIndex(where: { $0.id == feed.feedID }) {
                participants.people[index].name = name
            }
        } else {
            try updateSource(id) { $0.name = name.isEmpty ? nil : name }
        }
    }

    package mutating func setSpeakerAngle(_ angleID: String?, for voice: ParticipantSpeakerBinding,
                                         documentURL: URL?) throws {
        let existing = speakerAngles.firstIndex(where: { $0.voice == voice })
        guard let angleID else {
            if let existing { speakerAngles.remove(at: existing) }
            return
        }
        guard angles.contains(where: { $0.id == angleID }),
              let attachment = transcripts.attachments.first(where: { $0.id == voice.attachmentID }),
              let document = attachment.asset.document else {
            throw CutError(code: "invalid_target", message: "Choose an existing transcript voice and camera angle.")
        }
        let index = try TranscriptIndex(document: document, attachment: attachment, project: .multicam(self),
                                        projectURL: documentURL, records: transcripts.authoring, spaces: [.source])
        guard index.speakers.contains(where: { $0.id == voice.speakerID }) else {
            throw CutError(code: "invalid_target", message: "Choose an existing transcript voice and camera angle.")
        }
        let link = TileSpeakerAngle(voice: voice, angleID: angleID)
        if let existing { speakerAngles[existing] = link }
        else { speakerAngles.append(link) }
    }
}
