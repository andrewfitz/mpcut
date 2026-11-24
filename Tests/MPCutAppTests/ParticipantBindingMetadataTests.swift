import XCTest
@testable import MPCutApp

final class ParticipantBindingMetadataTests: XCTestCase {
    func testSpeakerNamesMatchWithoutUsingPartialNamesOrAttachmentLabels() {
        let name = "Ana María"
        XCTAssertTrue(ParticipantBindingMetadata.matches(name, label: " ANA-MARIA ", kind: .speaker))
        XCTAssertFalse(ParticipantBindingMetadata.matches(name, label: "Ana", kind: .speaker))
        XCTAssertFalse(ParticipantBindingMetadata.matches(name, label: "Ana María Interview", kind: .speaker))
        XCTAssertFalse(ParticipantBindingMetadata.matches("", label: " ", kind: .speaker))
    }

    func testAudioNameMatchesDedicatedTrackLabels() {
        XCTAssertTrue(ParticipantBindingMetadata.matches("Alex Kim", label: "Alex_Kim_ISO", kind: .audio))
        XCTAssertTrue(ParticipantBindingMetadata.matches("Alex Kim", label: "Alex Kim microphone", kind: .audio))
        XCTAssertTrue(ParticipantBindingMetadata.matches("Alex Kim", label: "Alex Kim MIC ISO", kind: .audio))
        XCTAssertFalse(ParticipantBindingMetadata.matches("Alex Kim", label: "Alex Kim Team Mix", kind: .audio))
        XCTAssertFalse(ParticipantBindingMetadata.matches("Alex Kim", label: "Alex Kim MIC", kind: .speaker))
        XCTAssertFalse(ParticipantBindingMetadata.matches("Alex Kim", label: "Sam Alex Kim mic", kind: .audio))
    }
}
