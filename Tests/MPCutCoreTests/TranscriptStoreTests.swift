import Foundation
@testable import MPCutCore
import XCTest

final class TranscriptStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testBindingDistinguishesUnverifiedChangedAndOfflineRecordings() throws {
        let root = try directory()
        let document = root.appendingPathComponent("Interview.cut")
        let recording = root.appendingPathComponent("Mic.wav")
        try Data([1]).write(to: recording)
        let binding = TranscriptBinding(trackID: "voice", file: "Mic.wav", streamIndex: 1)
        let project = CutProject.sequence([])
        XCTAssertEqual(binding.sourceStatus(in: project, relativeTo: document), .unverified)
        let inferred = binding.stamped(in: project, relativeTo: document, confirmed: false)
        XCTAssertEqual(inferred.sourceStatus(in: project, relativeTo: document), .unverified)
        let confirmed = inferred.stamped(in: project, relativeTo: document, confirmed: true)
        XCTAssertEqual(confirmed.sourceStatus(in: project, relativeTo: document), .available)
        try Data([2, 3]).write(to: recording, options: .atomic)
        XCTAssertEqual(inferred.sourceStatus(in: project, relativeTo: document), .changed)
        XCTAssertEqual(confirmed.sourceStatus(in: project, relativeTo: document), .changed)
        let rebound = confirmed.stamped(in: project, relativeTo: document, confirmed: true)
        XCTAssertEqual(rebound.sourceStatus(in: project, relativeTo: document), .available)
        try FileManager.default.removeItem(at: recording)
        XCTAssertEqual(rebound.sourceStatus(in: project, relativeTo: document), .offline)
        let group = MulticamProject(referenceAngle: "A", range: .init(from: .zero, to: .init(numerator: 1)),
                                    angles: [.init(id: "A", file: "Mic.wav")], audio: .follow,
                                    switches: [.init(at: .zero, angle: "A")])
        let missing = TranscriptBinding(trackID: "voice", sourceID: "B", streamIndex: 1)
        XCTAssertEqual(missing.sourceStatus(in: .multicam(group), relativeTo: document), .bindingMissing)
    }

    func testAuthoredPauseProtectionReanchorsOneAttachmentAndSkipsConflicts() throws {
        let root = try directory()
        let project = root.appendingPathComponent("Edit.cut")
        let file = root.appendingPathComponent("Microphone.wav")
        try Data([0]).write(to: file)
        let shift = RationalTime(numerator: 1, denominator: 8)
        func document(shift: RationalTime = .zero, firstText: String = "before") throws -> TranscriptDocument {
            let words = try [(firstText, 11, 12), ("after", 16, 17)].enumerated().map { index, value in
                let from = try RationalTime(numerator: Int64(value.1)).adding(shift)
                let to = try RationalTime(numerator: Int64(value.2)).adding(shift)
                return TranscriptWord(id: String(index), text: value.0, start: from, end: to,
                    observations: [.init(trackID: "voice", start: from, end: to, evidence: .recognized)])
            }
            return .init(clock: .presentation, tracks: [.init(id: "voice", name: "Voice")], words: words)
        }
        let original = try document()
        func attachment(_ document: TranscriptDocument, id: String, binding: TranscriptBinding) throws -> TranscriptAttachment {
            let bytes = try TranscriptCodec.encode(document, format: .json)
            return .init(id: id, asset: try TranscriptStore.put(bytes, relativeTo: project), bindings: [binding],
                         importOrigin: .init(numerator: 2))
        }
        func state(binding: TranscriptBinding) throws -> ProjectTranscripts {
            let originalAttachment = try attachment(original, id: "dialogue", binding: binding)
            let words = try TranscriptIndex.sourceOccurrences(document: original, attachment: originalAttachment)
            let anchors = try words.map { try TranscriptEditorial.anchor([$0], binding: binding) }
            let refreshed = try attachment(document(shift: shift), id: "dialogue", binding: binding)
            let unrelated = try attachment(original, id: "other", binding: binding)
            return .init(attachments: [refreshed, unrelated],
                         authoring: [.init(attachmentID: "dialogue", change: .pauseProtection(name: "A pause"), anchors: anchors)])
        }
        let binding = TranscriptBinding(trackID: "voice", file: file.path, streamIndex: 1, offset: .init(numerator: 1))
        var sequence = try state(binding: binding)
        var cache = TranscriptPauseProtectionCache()
        let protections = cache.resolve(sequence, relativeTo: project)
        XCTAssertEqual(protections.sequence(file: file.path, origin: .init(numerator: 10), stream: 1, sourceFingerprint: ""),
                       [.init(from: .init(numerator: 41, denominator: 8), to: .init(numerator: 73, denominator: 8))])
        XCTAssertEqual(protections.sequence(file: file.path, origin: .zero, stream: 0, sourceFingerprint: ""), [])
        sequence.attachments[0] = try attachment(document(firstText: "changed"), id: "dialogue", binding: binding)
        XCTAssertEqual(cache.resolve(sequence, relativeTo: project)
            .sequence(file: file.path, origin: .zero, stream: 1, sourceFingerprint: ""), [])
        var ambiguous = try document(shift: shift)
        var another = try document(shift: .init(numerator: -1, denominator: 8)).words[0]
        another.id = "another"
        ambiguous.words.insert(another, at: 0)
        sequence.attachments[0] = try attachment(ambiguous, id: "dialogue", binding: binding)
        XCTAssertTrue(cache.resolve(sequence, relativeTo: project).isEmpty)

        let groupState = try state(binding: .init(trackID: "voice", sourceID: "A", streamIndex: 1,
                                                  offset: .init(numerator: -1)))
        let group = MulticamProject(referenceAngle: "A", range: .init(from: .zero, to: .init(numerator: 30)),
            angles: [.init(id: "A", file: file.path, offset: .init(numerator: 3))], audio: .follow,
            switches: [.init(at: .zero, angle: "A")])
        XCTAssertEqual(cache.resolve(groupState, relativeTo: project).group(sources: group.sources, sourceFingerprints: ["A": ""]),
                       [.init(from: .init(numerator: 129, denominator: 8), to: .init(numerator: 161, denominator: 8))])
    }

}
