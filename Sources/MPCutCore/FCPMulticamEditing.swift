import Foundation

/// Authored group state that a flattened list of FCP multicam clips cannot express.
struct FCPMulticamEditing: Codable {
    let range: MulticamRange
    let switches: [MulticamSwitch]
    let audio: MulticamAudioPolicy
    let assemblyItems: [StillAssemblyItem]?
    let recordings: [String: [String]]
    let extractedAudio: [String: MulticamAudioSelection]?
    let sourceCoverage: [String: MulticamRange]?
    let sourceSettings: [String: FCPAngleMetadata]?
    let audioLinks: [String: AudioLink]?

    struct AudioLink: Codable {
        let path: String
        let offset: RationalTime
        let originalPath: String
        let originalOffset: RationalTime
    }

    enum CodingKeys: String, CodingKey {
        case range, switches, audio, recordings
        case assemblyItems = "assembly_items"
        case extractedAudio = "extracted_audio"
        case sourceCoverage = "source_coverage"
        case sourceSettings = "source_settings"
        case audioLinks = "audio_links"
    }
}

extension FCPGroupMetadata {
    static let editing = "com.mpcut.multicam.editing.v1"
}
