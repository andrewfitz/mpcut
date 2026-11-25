import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptStoreStorageTests: XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func transcript(_ text: String = "An interview") -> TranscriptDocument {
        .init(clock: .presentation, tracks: [.init(id: "lav", name: "Lav", activity: [
            .init(start: .init(numerator: 1, denominator: 3), end: .init(numerator: 2, denominator: 3), level: 0.25)
        ])], words: [.init(id: "word", text: text, start: .init(numerator: 1, denominator: 3),
                            end: .init(numerator: 2, denominator: 3), confidence: 0.875)])
    }

    private func project(_ document: TranscriptDocument, at url: URL) throws -> CutProject {
        let bytes = try TranscriptCodec.encodeStored(document)
        let asset = try TranscriptStore.put(bytes, relativeTo: url)
        var result = CutProject.sequence([])
        result.transcripts.attachments = [.init(id: "dialogue", asset: asset, bindings: [])]
        return result
    }

    private func expanded(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: CutProject.documentJSON(at: url)) as? [String: Any])
    }

    func testRenamedCopyRecoversItsOwnTranscriptAndAuthoredHistory() throws {
        let sourceDirectory = try folder()
        let destinationDirectory = try folder()
        let source = sourceDirectory.appendingPathComponent("Interview.cut")
        let destination = destinationDirectory.appendingPathComponent("Selects.cut")
        // A word beginning with the project reference marker is literal transcript text.
        let words = transcript("~unlisted")
        let original = try project(words, at: source)
        var corrected = original
        corrected.transcripts.authoring = [.init(attachmentID: "dialogue", change: .renameSpeaker(speakerID: "a", name: "Host"), anchors: [])]
        try corrected.save(to: source, undo: [.init(action: "Rename Speaker", project: original)], redo: [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path), ["Interview.cut"])
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.removeItem(at: source)
        let reopened = try CutProject.loadDocument(from: destination, limit: 10)
        let current = try XCTUnwrap(reopened.project.transcripts.attachments.first)
        let previous = try XCTUnwrap(reopened.undo.last?.project.transcripts.attachments.first)
        XCTAssertEqual(reopened.project.transcripts.authoring, corrected.transcripts.authoring)
        XCTAssertEqual(reopened.undo.last?.project.transcripts.authoring, [])
        XCTAssertEqual(try TranscriptStore.decoded(current.asset, relativeTo: destination), words)
        XCTAssertEqual(try TranscriptStore.read(previous.asset, relativeTo: destination), try TranscriptCodec.encodeStored(words))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path), ["Selects.cut"])
    }

    func testTwoAttachmentsShareOneAssetAndDetachRemovesUnreachableWords() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("Test.cut")
        var edit = try project(transcript(), at: url)
        let asset = edit.transcripts.attachments[0].asset
        edit.transcripts.attachments.append(.init(id: "duplicate", asset: asset, bindings: []))
        try edit.save(to: url)
        let saved = try expanded(url)
        let table = try XCTUnwrap((saved["embedded_assets"] as? [String: Any])?["transcripts"] as? [String: Any])
        XCTAssertEqual(Set(table.keys), [asset.sha256])
        let document = try XCTUnwrap(table[asset.sha256] as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 4)
        let references = try XCTUnwrap((saved["transcripts"] as? [String: Any])?["attachments"] as? [[String: Any]])
        XCTAssertEqual(references.compactMap { $0["asset"] as? [String: String] },
                       Array(repeating: ["sha256": asset.sha256], count: 2))
        edit.transcripts.attachments = []
        try edit.save(to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(asset.sha256))
    }

    func testOpenRejectsMissingAssetAndPayloadWithWrongDigest() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("Test.cut")
        let edit = try project(transcript(), at: url)
        try edit.save(to: url)
        let saved = try expanded(url)
        let key = edit.transcripts.attachments[0].asset.sha256
        let legacy = url.appendingPathExtension("transcripts")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let companion = legacy.appendingPathComponent(key + ".json")
        let original = try TranscriptCodec.encodeStored(transcript())
        try original.write(to: companion)
        let other = try JSONSerialization.jsonObject(with: TranscriptCodec.encodeStored(transcript("Replacement")))
        for (table, code): ([String: Any], String) in [([:], "missing_embedded_asset"), ([key: other], "invalid_embedded_asset")] {
            var malformed = saved
            malformed["embedded_assets"] = ["transcripts": table]
            let bytes = try JSONSerialization.data(withJSONObject: malformed)
            try bytes.write(to: url, options: .atomic)
            XCTAssertThrowsError(try CutProject.load(from: url)) {
                XCTAssertEqual(($0 as? CutError)?.code, code)
            }
            XCTAssertEqual(try Data(contentsOf: companion), original)
        }
    }

    func testEmbeddedTranscriptIntegerFieldsCannotRoundToMatchDigest() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("Test.cut")
        let edit = try project(transcript(), at: url)
        try edit.save(to: url)
        let valid = String(decoding: try CutProject.documentJSON(at: url), as: UTF8.self)
        let malformed = valid.replacingOccurrences(of: #""schema_version":4"#,
                                                   with: #""schema_version":4.00000000000000000001"#)
        XCTAssertNotEqual(malformed, valid)
        XCTAssertThrowsError(try CutProject.decode(Data(malformed.utf8))) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_cut_project")
            XCTAssertTrue(($0 as? CutError)?.message.contains("non-integer JSON number") == true)
        }
        XCTAssertEqual(try CutProject.decode(Data(valid.utf8)), edit)
    }

    func testFailedPublicationLeavesThePreviousCompleteProject() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("Test.cut")
        let original = try project(transcript("before"), at: url)
        try original.save(to: url)
        let revision = try CutProject.loadEditorDocument(from: url, limit: 0).media.diskRevision
        let revised = try project(transcript("after"), at: url)
        enum Interrupted: Error { case duringSave }
        XCTAssertThrowsError(try revised.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty,
            expected: revision, beforePublish: { throw Interrupted.duringSave }))
        XCTAssertEqual(try CutProject.load(from: url), original)
        _ = try revised.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty, expected: revision)
        XCTAssertThrowsError(try original.saveRevision(to: url, undo: [], redo: [], mediaSnapshot: .empty,
                                                       expected: revision)) {
            XCTAssertEqual(($0 as? CutError)?.code, "project_save_conflict")
        }
        XCTAssertEqual(try CutProject.load(from: url), revised)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Test.cut"])
    }
}
