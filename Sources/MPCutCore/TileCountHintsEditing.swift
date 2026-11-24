import Foundation

extension TilesCountHints {
    package func overriding(_ previous: Self?) -> Self {
        .init(expectedFeeds: expectedFeeds ?? previous?.expectedFeeds,
              maxVisibleTiles: maxVisibleTiles ?? previous?.maxVisibleTiles)
    }
}

extension ParticipantProject {
    /// Change the review expectations without changing any detected feed or tile.
    public mutating func setTileCountHints(sourceID: String, hints: TilesCountHints?) throws {
        guard let index = sources.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw invalidParticipantProject("Choose a recording whose tiles have been accepted.")
        }
        if let hints {
            guard hints.expectedFeeds.map({ $0 > 0 }) ?? true, hints.maxVisibleTiles.map({ $0 > 0 }) ?? true else {
                throw invalidParticipantProject("Enter a positive feed count or visible-tile limit.")
            }
            sources[index].countHints = hints.expectedFeeds == nil && hints.maxVisibleTiles == nil ? nil : hints
        } else {
            sources[index].countHints = nil
        }
    }
}
