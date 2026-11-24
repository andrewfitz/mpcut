import CoreImage
import Foundation

/// One render operation owns the project preparation, indexes and serial picture readers.
final class ParticipantSharedPictureInputs {
    private let slots: Set<String>?
    private var media: [URL: MediaInfo] = [:]
    private var indexes: [String: ParticipantGeometryIndex] = [:]
    private var privacyDigests: [URL: String]
    private var readers: [(file: URL, toneMapHDR: Bool, reader: ParticipantPictureReader)] = []
    private var savedPlan: ParticipantRenderPlan??
    private var originalTimeline: StillTimelinePlan?
    private var treatmentSets: [[String: ParticipantRedaction]] = []
    private(set) var readerCount = 0
    private(set) var decodedPictureRequests = 0

    init(slots: Set<String>? = nil, privacyDigests: [URL: String] = [:]) {
        self.slots = slots
        self.privacyDigests = privacyDigests
    }

    func validatedSavedPlan(_ project: CutProject) throws -> ParticipantRenderPlan? {
        if let savedPlan { return savedPlan }
        let plan = try project.tileRenderPlan()
        try project.validate()
        savedPlan = .some(plan)
        return plan
    }

    func timeline(_ project: CutProject) throws -> StillTimelinePlan {
        if let originalTimeline { return originalTimeline }
        let timeline = try project.resolveStillsUnchecked()
        originalTimeline = timeline
        return timeline
    }

    func treatmentIndex(_ treatments: [String: ParticipantRedaction]) -> Int {
        if let index = treatmentSets.firstIndex(of: treatments) { return index }
        treatmentSets.append(treatments)
        return treatmentSets.count - 1
    }

    func source(_ file: URL, engine: CutEngine) throws -> MediaInfo {
        if let cached = media[file] { return cached }
        let indexed = try engine.inspect(file, keyframes: true)
        media[file] = indexed
        return indexed
    }

    func privacyDigest(_ media: MediaInfo, control: JPEGControl) throws -> String {
        if let digest = privacyDigests[media.url] { return digest }
        let digest = try verifiedParticipantPrivacyDigest(media, cancelled: control.cancelled)
        privacyDigests[media.url] = digest
        return digest
    }

    func geometry(_ project: ParticipantProject, sourceID: String, slots: Set<String>,
                  control: JPEGControl) throws -> ParticipantGeometryIndex {
        if let cached = indexes[sourceID] { return cached }
        let index = try ParticipantGeometryIndex(project, sourceID: sourceID, slots: self.slots ?? slots,
                                                 checkCancellation: control.check)
        indexes[sourceID] = index
        return index
    }

    func picture(_ source: MediaInfo, index: Int, control: JPEGControl, toneMapHDR: Bool,
                 usingScannedGeometry: Bool) throws -> CIImage {
        let reader: ParticipantPictureReader
        if let found = readers.firstIndex(where: { $0.file == source.url && $0.toneMapHDR == toneMapHDR }) {
            reader = readers.remove(at: found).reader
        } else {
            if readers.count >= 4 { readers.removeFirst() }
            reader = try ParticipantPictureReader(source, control: control, toneMapHDR: toneMapHDR)
            readerCount += 1
        }
        readers.append((source.url, toneMapHDR, reader))
        if reader.lastPictureIndex != index { decodedPictureRequests += 1 }
        return try reader.picture(at: index, usingScannedGeometry: usingScannedGeometry)
    }

    func resetReaders() { readers.removeAll() }
}

/// Shared only by the writers working on one output frame. Cap retained source graphs
/// for layouts that draw from many recordings or use different treatments.
final class ParticipantISOFrameInputs {
    private struct SourceFrame: Hashable {
        let route: ParticipantRenderRoute
        let time: RationalTime
    }

    struct TreatedPicture: Hashable {
        let file: URL
        let geometryID: String
        let index: Int
        let treatmentIndex: Int
        let toneMapHDR: Bool
        let scanned: Bool
        let allowMetal: Bool
    }

    private var sourceFrames: [SourceFrame: Int?] = [:]
    private var pictures: [TreatedPicture: CIImage] = [:]

    func sourceFrame(_ route: ParticipantRenderRoute, at time: RationalTime, resolve: () throws -> Int?) rethrows -> Int? {
        let key = SourceFrame(route: route, time: time)
        if let cached = sourceFrames[key] { return cached }
        let index = try resolve()
        if sourceFrames.count < 16 { sourceFrames.updateValue(index, forKey: key) }
        return index
    }

    func treatedPicture(_ key: TreatedPicture, render: () throws -> CIImage) rethrows -> CIImage {
        if let cached = pictures[key] { return cached }
        let result = try render()
        if pictures.count < 4 { pictures[key] = result }
        return result
    }

    func reset() {
        sourceFrames.removeAll(keepingCapacity: true)
        pictures.removeAll(keepingCapacity: true)
    }
}
