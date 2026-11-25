import Foundation
import MPCutCore

/// What Find Tiles starts with for a recording that has no saved layout, read from Settings → Media & Analysis
/// when the recording is chosen. A scanned recording restores its own layout from the project instead.
struct TilesScanDefaults: Equatable {
    var layout: ParticipantFeedLayout
    var columns: Int
    var rows: Int
    var detail: ParticipantSampling

    init(layout: TilesScanLayout = .videoCall, columns: Int = 2, rows: Int = 2, detail: ParticipantSampling = .adaptive,
         isAvailable: Bool = ParticipantAnalysis.isAvailable, supportsFeedLayouts: Bool = ParticipantAnalysis.supportsFeedLayouts) {
        self.columns = columns
        self.rows = rows
        self.detail = detail
        let grid = ParticipantFeedLayout.fixed(columns: UInt32(max(1, columns)), rows: UInt32(max(1, rows)))
        // A build without TileTrail has neither meeting layout, so it starts on the even grid.
        switch layout {
        case .videoCall: self.layout = isAvailable ? .meeting : grid
        case .cameraMultiview: self.layout = supportsFeedLayouts ? .automatic : isAvailable ? .meeting : grid
        case .evenGrid: self.layout = grid
        }
    }

    @MainActor init(preferences: EditorPreferences, isAvailable: Bool = ParticipantAnalysis.isAvailable,
                    supportsFeedLayouts: Bool = ParticipantAnalysis.supportsFeedLayouts) {
        self.init(layout: preferences.tilesScanLayout, columns: preferences.tilesScanColumns, rows: preferences.tilesScanRows,
                  detail: preferences.tilesScanDetail, isAvailable: isAvailable, supportsFeedLayouts: supportsFeedLayouts)
    }
}

/// The dialogue switch sheet's starting values, read from Settings when the sheet is made.
struct TilesDialogueDefaults: Equatable {
    /// The Minimum Hold field. The factory value is the "1" the sheet always started with.
    var minimumHold = "1"
    var overlap = ParticipantDialogueOptions.Overlap.hold
    var offscreen = ParticipantDialogueOptions.Offscreen.hold

    static let factory = TilesDialogueDefaults()

    init() {}

    @MainActor init(preferences: EditorPreferences) {
        minimumHold = TranscriptSheetDefaults.secondsText(preferences.dialogueMinimumHold, fractionDigits: 0)
        overlap = preferences.dialogueOverlap
        offscreen = preferences.dialogueOffscreen
    }

    /// The tile switch lane has no field. It holds for the Settings minimum, or core's own one second
    /// when that is not a positive time.
    @MainActor static func switchLaneHold(_ preferences: EditorPreferences) -> RationalTime {
        let hold = TranscriptSheetDefaults.rationalSeconds(preferences.dialogueMinimumHold)
        return hold.flatMap { $0 > .zero ? $0 : nil } ?? .init(numerator: 1)
    }
}
