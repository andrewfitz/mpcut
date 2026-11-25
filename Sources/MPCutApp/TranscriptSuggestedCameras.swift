import Foundation

/// A speaker's suggested camera, keyed by transcript attachment. Stored app-wide through the shared preferences.
@MainActor
enum TranscriptSuggestedCameras {

    private struct Stored: Codable {
        var cameras: [String: [String: String]] = [:]
        var legacy: [String: String] = [:]

        init(data: Data) {
            if let decoded = try? JSONDecoder().decode(Self.self, from: data) {
                self = decoded
            } else {
                legacy = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            }
        }
    }

    static func forAttachments(_ attachments: [String], data: Data) -> [String: [String: String]] {
        let stored = Stored(data: data)
        var result = stored.cameras.filter { attachments.contains($0.key) }
        for (key, camera) in stored.legacy {
            let matches = attachments.filter { key.hasPrefix($0 + ":") }
            guard matches.count == 1, let attachment = matches.first else { continue }
            let speaker = String(key.dropFirst(attachment.count + 1))
            if result[attachment]?[speaker] == nil { result[attachment, default: [:]][speaker] = camera }
        }
        return result
    }

    static func set(_ camera: String?, attachment: String, speaker: String, in preferences: EditorPreferences) {
        var stored = Stored(data: preferences.transcriptSuggestedAngles)
        stored.legacy.removeValue(forKey: attachment + ":" + speaker)
        var angles = stored.cameras[attachment] ?? [:]
        angles[speaker] = camera
        stored.cameras[attachment] = angles.isEmpty ? nil : angles
        if let data = try? JSONEncoder().encode(stored) {
            preferences.transcriptSuggestedAngles = data
        }
    }
}
