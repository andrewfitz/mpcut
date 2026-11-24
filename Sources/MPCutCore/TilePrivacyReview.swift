import Foundation

extension ParticipantProject {
    /// Identifies recordings with no saved scan while a feed treatment is active.
    public func unscannedTileRecordingIDs(in pictureMedia: [String: MediaInfo]) -> [String] {
        guard !effectiveRedactions.isEmpty else { return [] }
        let scanned = sources.filter { $0.analysisIdentity != nil }
        let scannedIDs = Set(scanned.map(\.sourceID))
        let scannedIdentities = Set(scanned.compactMap { source -> SourceIdentity? in
            guard let media = pictureMedia[source.sourceID], source.sourceStamp == SceneSourceStamp(media: media),
                  source.sourceInode == media.identity.inode else { return nil }
            return media.identity
        })
        return pictureMedia.compactMap { id, media in
            guard media.hasVideo, !scannedIDs.contains(id),
                  !scannedIdentities.contains(media.identity) else { return nil }
            return id
        }.sorted()
    }
}
