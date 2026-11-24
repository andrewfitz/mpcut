import Foundation

enum ParticipantBindingMetadata {
    enum LabelKind {
        case speaker, audio
    }

    static func matches(_ participantName: String, label: String, kind: LabelKind) -> Bool {
        let name = words(participantName)
        guard !name.isEmpty else { return false }
        let labelWords = words(label)
        if labelWords == name { return true }
        guard kind == .audio else { return false }

        let audioSuffixes: Set<String> = ["iso", "mic", "microphone"]
        let audioLabel = labelWords.reversed().drop(while: audioSuffixes.contains).reversed()
        return audioLabel.elementsEqual(name)
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
