import Combine
import Foundation
import MPCutCore

@MainActor
final class EditorPreferences: ObservableObject {
    enum Change {
        case useAnalysisSidecars, defaultExportMode, snapTarget, largeThumbnails
        case minimumPause, leavePause, volume, isMuted, scrubSoundEnabled, jpegPreset
    }

    private let defaults: UserDefaults?
    // Subscribers that recalculate project state need to read the new value after it is stored.
    private let changes = PassthroughSubject<Change, Never>()

    @Published var useAnalysisSidecars = true {
        didSet { save(useAnalysisSidecars, replacing: oldValue, key: "useAnalysisSidecars", change: .useAnalysisSidecars) }
    }
    @Published var defaultExportMode = ExportMode.smart {
        didSet {
            save(defaultExportMode, replacing: oldValue, key: "defaultMovieExportMode",
                 stored: defaultExportMode.rawValue, change: .defaultExportMode)
        }
    }
    @Published var snapTarget = TimelineSnapTarget.off {
        didSet {
            save(snapTarget, replacing: oldValue, key: "timelineSnapTarget", stored: snapTarget.rawValue, change: .snapTarget)
        }
    }
    @Published var largeThumbnails = false {
        didSet { save(largeThumbnails, replacing: oldValue, key: "largeTimelineThumbnails", change: .largeThumbnails) }
    }
    @Published var minimumPause = 1.5 {
        didSet { save(minimumPause, replacing: oldValue, key: "minimumPause", change: .minimumPause) }
    }
    @Published var leavePause = 0.4 {
        didSet { save(leavePause, replacing: oldValue, key: "leavePause", change: .leavePause) }
    }
    @Published var volume: Float = 1 {
        didSet { save(volume, replacing: oldValue, key: "previewVolume", change: .volume) }
    }
    @Published var isMuted = false {
        didSet { save(isMuted, replacing: oldValue, key: "mutePreview", change: .isMuted) }
    }
    @Published var scrubSoundEnabled = true {
        didSet { save(scrubSoundEnabled, replacing: oldValue, key: "scrubSoundEnabled", change: .scrubSoundEnabled) }
    }
    @Published var jpegPreset = JPEGPreset.review {
        didSet {
            save(jpegPreset, replacing: oldValue, key: "jpegFramePreset", stored: jpegPreset.rawValue, change: .jpegPreset)
        }
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let defaults else { return }
        useAnalysisSidecars = Self.flag(defaults.object(forKey: "useAnalysisSidecars")) ?? true
        largeThumbnails = Self.flag(defaults.object(forKey: "largeTimelineThumbnails")) ?? false
        snapTarget = defaults.string(forKey: "timelineSnapTarget").flatMap(TimelineSnapTarget.init(rawValue:))
            ?? (Self.flag(defaults.object(forKey: "snapToKeyframes")) == true ? .keyframes : .off)
        defaultExportMode = defaults.string(forKey: "defaultMovieExportMode").flatMap(ExportMode.init(rawValue:)) ?? .smart
        jpegPreset = defaults.string(forKey: "jpegFramePreset").flatMap(JPEGPreset.init(rawValue:)) ?? .review
        if let minimum = Self.number(defaults.object(forKey: "minimumPause")),
           minimum >= 1.0 / Double(AudioWaveform.rate) {
            minimumPause = minimum
        }
        if let leave = Self.number(defaults.object(forKey: "leavePause")), leave >= 0 {
            leavePause = leave
        }
        if let gain = Self.number(defaults.object(forKey: "previewVolume")) {
            volume = Float(min(1, max(0, gain)))
        }
        isMuted = Self.flag(defaults.object(forKey: "mutePreview")) ?? false
        scrubSoundEnabled = Self.flag(defaults.object(forKey: "scrubSoundEnabled")) ?? true
    }

    // `defaults write` stores a string unless it is given a type, and an
    // unreadable value keeps the built-in default instead of becoming zero.
    private static func number(_ stored: Any?) -> Double? {
        let value = (stored as? NSNumber)?.doubleValue ?? (stored as? String).flatMap(Double.init)
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func flag(_ stored: Any?) -> Bool? {
        if let number = stored as? NSNumber { return number.boolValue }
        switch (stored as? String)?.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }

    func observeChanges(_ receiveValue: @escaping (Change) -> Void) -> AnyCancellable {
        changes.sink(receiveValue: receiveValue)
    }

    private func save<Value: Equatable>(_ value: Value, replacing oldValue: Value,
                                        key: String, stored: Any? = nil, change: Change) {
        guard value != oldValue else { return }
        defaults?.set(stored ?? value, forKey: key)
        changes.send(change)
    }
}
