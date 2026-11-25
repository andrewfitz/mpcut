import Foundation
import MPCutCore

/// The starting values a new transcript sheet, form or job setup reads once from Settings.
/// Changing a value inside a sheet never writes it back, and changing Settings never alters a sheet already open.
struct TranscriptSheetDefaults: Equatable {
    var engine = ""
    var identifiesSpeakers = false
    var downloadsModels = false
    var boundary = TranscriptEditRequest.BoundaryPolicy.nearestFrame
    /// The tighten form's text field. The factory value is the "0.20" the form always started with.
    var retainedPause = "0.20"
    /// The Review Restarts and Fillers field.
    var fillerTerms = ""
    var exportFormat = TranscriptFormat.json
    var captionLimits = TranscriptCaptionLimits.standard

    /// Today's sheets, before Settings existed.
    static let factory = TranscriptSheetDefaults()

    init() {}

    @MainActor init(preferences: EditorPreferences) {
        engine = preferences.transcriptEngine
        identifiesSpeakers = preferences.identifiesSpeakers
        downloadsModels = preferences.downloadsModels
        boundary = preferences.boundaryPolicy
        retainedPause = Self.secondsText(preferences.retainedPause, fractionDigits: 2)
        fillerTerms = preferences.fillerTerms
        exportFormat = preferences.transcriptExportFormat
        captionLimits = Self.captionLimits(preferences)
    }

    @MainActor static func captionLimits(_ preferences: EditorPreferences) -> TranscriptCaptionLimits {
        TranscriptCaptionLimits(lineCharacters: preferences.captionLineCharacters, lines: preferences.captionLines,
                                longestCue: rationalSeconds(preferences.captionCueSeconds) ?? .init(numerator: 6),
                                speakerLabels: preferences.captionSpeakerLabels)
    }

    /// Seconds as a sheet's text field shows them: at least `fractionDigits` decimals, more only when needed.
    static func secondsText(_ seconds: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = 1
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: seconds)) ?? String(seconds)
    }

    /// Exact for the decimals Settings stores, so 6 s stays 6/1 and 0.2 s stays 1/5.
    static func rationalSeconds(_ seconds: Double) -> RationalTime? {
        guard seconds.isFinite else { return nil }
        return try? RationalTime(parsing: secondsText(seconds, fractionDigits: 0))
    }
}
