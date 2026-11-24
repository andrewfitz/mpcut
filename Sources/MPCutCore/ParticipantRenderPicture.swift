import CoreImage
import Foundation
import Metal

struct ParticipantFrameGeometry {
    let appearances: [ParticipantAppearance]
    let coverage: ParticipantCoverageState

    var needsPrivacyCover: Bool {
        coverage != .verified || appearances.contains(where: \.hasUnresolvedIdentity)
    }
}

extension ParticipantAppearance {
    var hasUnresolvedIdentity: Bool {
        state == .unknown || participantID == nil
    }
}

struct ParticipantGeometryIndex {
    let sourceID: String
    let usesScannedGeometry: Bool
    private let points: [RationalTime]
    private let frames: [ParticipantFrameGeometry]
    private let selections: [Selection: [Change]]
    private let positionIDs: [String: String]

    private struct Selection: Hashable {
        let id: String
        let includeCameraOff: Bool
    }

    private struct Change {
        let time: RationalTime
        let appearanceID: String?
    }

    init(_ project: ParticipantProject, sourceID: String, slots: Set<String>,
         checkCancellation: () throws -> Void) throws {
        self.sourceID = sourceID
        let geometry = project.sources.first { $0.sourceID == sourceID }
        usesScannedGeometry = geometry?.analysisIdentity != nil
        let appearances = geometry?.appearances ?? []
        positionIDs = Dictionary(grouping: appearances, by: \.id).compactMapValues { variants in
            let positions = Set(variants.compactMap(\.slotID))
            return positions.count == 1 ? positions.first : nil
        }
        let coverage = (geometry?.coverage ?? []).sorted { $0.range.from < $1.range.from }
        let overrides = project.appearanceOverrides.filter { $0.sourceID == sourceID && slots.contains($0.participantID) }
        let changes = appearances.flatMap { [$0.range.from, $0.range.to] }
            + coverage.flatMap { [$0.range.from, $0.range.to] }
            + overrides.flatMap { [$0.range.from, $0.range.to] }
        let points = Set(changes).sorted()
        var indexed: [ParticipantFrameGeometry] = []
        var chosen: [Selection: [Change]] = [:]
        let ordered = appearances.sorted { $0.range.from < $1.range.from }
        var next = 0
        var active: [ParticipantAppearance] = []
        let pins = Dictionary(grouping: overrides, by: \.participantID).mapValues {
            $0.sorted { $0.range.from < $1.range.from }
        }
        for time in points {
            try checkCancellation()
            active.removeAll { $0.range.to <= time }
            while ordered.indices.contains(next), ordered[next].range.from <= time {
                if ordered[next].range.contains(time) { active.append(ordered[next]) }
                next += 1
            }
            let index = coverage.lowerBound { $0.range.to > time }
            let state = coverage.indices.contains(index) && coverage[index].range.contains(time)
                ? coverage[index].state : .unknown
            indexed.append(.init(appearances: active, coverage: state))
            guard !slots.isEmpty else { continue }
            let byParticipant = Dictionary(grouping: active, by: \.participantID)
            for id in slots {
                let scoped = pins[id] ?? []
                let index = scoped.lowerBound { $0.range.to > time }
                let override = scoped.indices.contains(index) && scoped[index].range.contains(time) ? scoped[index] : nil
                let available = byParticipant[id] ?? []
                for includeCameraOff in [true, false] {
                    let key = Selection(id: id, includeCameraOff: includeCameraOff)
                    let held = chosen[key]?.last?.appearanceID
                    let choice = ParticipantProject.chooseAppearance(available, override: override?.appearanceID,
                        holding: held, includeCameraOff: includeCameraOff)
                    if choice?.id != held {
                        chosen[key, default: []].append(.init(time: time, appearanceID: choice?.id))
                    }
                }
            }
        }
        self.points = points
        self.frames = indexed
        self.selections = chosen
    }

    func at(_ time: RationalTime) -> ParticipantFrameGeometry {
        let index = points.lowerBound { $0 > time } - 1
        return frames.indices.contains(index) ? frames[index] : .init(appearances: [], coverage: .unknown)
    }

    func arrangementCheckpoints(in range: MulticamRange, extra: Set<RationalTime>) -> [RationalTime] {
        let start = points.lowerBound { $0 > range.from }
        let end = points.lowerBound { $0 >= range.to }
        return Set(points[start..<end]).union(extra).union([range.from]).sorted()
    }

    func arrangementTopology(_ appearances: [ParticipantAppearance]) -> [String] {
        appearances.map { $0.slotID ?? positionIDs[$0.id] ?? $0.id }.sorted()
    }

    func destination(_ id: String, in appearances: [ParticipantAppearance]) -> ParticipantAppearance? {
        if let exact = appearances.first(where: { $0.id == id }) { return exact }
        let position = positionIDs[id] ?? id
        let matching = appearances.filter { $0.slotID == position }
        return matching.count == 1 ? matching.first : nil
    }

    func appearance(_ slot: ParticipantSlot, at time: RationalTime) -> ParticipantAppearance? {
        if slot.target == .presentation {
            let presentations = at(time).appearances.filter { $0.role == .presentation && $0.state == .presentation }
            return destination(slot.id, in: presentations)
        }
        guard let changes = selections[.init(id: slot.id, includeCameraOff: slot.includeCameraOff)] else { return nil }
        let index = changes.lowerBound { $0.time > time } - 1
        guard index >= 0, let id = changes[index].appearanceID else { return nil }
        return at(time).appearances.first { $0.id == id }
    }

    /// The selected crop can disappear even while a different tile of the feed is visible.
    func visibleRanges(for id: String, includeCameraOff: Bool, in range: MulticamRange) -> [MulticamRange] {
        let changes = selections[Selection(id: id, includeCameraOff: includeCameraOff)] ?? []
        let first = max(0, changes.lowerBound { $0.time > range.from } - 1)
        let end = changes.lowerBound { $0.time >= range.to }
        return (first..<end).compactMap { index in
            guard changes[index].appearanceID != nil else { return nil }
            let next = index + 1 < end ? changes[index + 1].time : range.to
            return .init(from: max(changes[index].time, range.from), to: next)
        }
    }
}

final class ParticipantPictureReader {
    private let media: MediaInfo
    private let renderer: JPEGRenderer
    private let seekPoints: [Int]
    private let toneMapHDR: Bool
    let scanOrientation: CGAffineTransform
    private var last: (index: Int, image: CIImage, orientation: CGAffineTransform)?
    var lastPictureIndex: Int? { last?.index }

    init(_ media: MediaInfo, control: JPEGControl, toneMapHDR: Bool) throws {
        self.media = media
        self.toneMapHDR = toneMapHDR
        renderer = try JPEGRenderer(media: media, control: control)
        seekPoints = media.frames.indices.filter { media.frames[$0].canStart && media.frames[$0].dts != nil }
        scanOrientation = Self.rotation(media.video.rotation)
    }

    private static func rotation(_ degrees: Int) -> CGAffineTransform {
        switch (degrees % 360 + 360) % 360 {
        case 90: .init(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 180: .init(scaleX: -1, y: -1)
        case 270: .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: .identity
        }
    }

    static func oriented(_ decoded: ParticipantDecodedPicture, source: MediaInfo, usingScannedGeometry: Bool,
                         toneMapHDR: Bool) throws -> CIImage {
        if usingScannedGeometry, decoded.displayTransform != rotation(source.video.rotation) {
            throw CutError(code: "participant_display_transform_changed",
                           message: "The preview rotation differs from the participant scan.")
        }
        let transfer = CVBufferCopyAttachment(decoded.buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let hdr = transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        let image = CIImage(cvPixelBuffer: decoded.buffer, options: [.toneMapHDRtoSDR: toneMapHDR && hdr])
        let aspect = source.video.sampleAspectRatio.seconds
        let transformed = image.transformed(by: CGAffineTransform(scaleX: aspect > 0 ? aspect : 1, y: 1)
            .concatenating(decoded.displayTransform))
        return transformed.transformed(by: .init(translationX: -transformed.extent.minX, y: -transformed.extent.minY))
    }

    func picture(at index: Int, usingScannedGeometry: Bool) throws -> CIImage {
        func checked(_ image: CIImage, orientation: CGAffineTransform) throws -> CIImage {
            guard !usingScannedGeometry || orientation == scanOrientation else {
                throw CutError(code: "participant_display_transform_changed",
                               message: "The decoded display rotation differs from the participant scan for ‘\(media.url.lastPathComponent)’. Review the source before rendering.")
            }
            return image
        }
        if let last, last.index == index { return try checked(last.image, orientation: last.orientation) }
        let frame = media.frames[index]
        let inverse = RationalTime(numerator: media.video.timeBase.denominator, denominator: media.video.timeBase.numerator)
        func ticks(_ time: RationalTime) throws -> Int64 {
            let value = try time.adding(media.origin).multiplied(by: inverse)
            guard value.denominator == 1 else {
                throw CutError(code: "invalid_frame", message: "A picture does not land on a source timestamp.")
            }
            return value.numerator
        }
        let backwards = last.map { index < $0.index } ?? false
        let previous = last.map { media.frames[$0.index].time } ?? .zero
        let ahead = frame.time.seconds - previous.seconds > 2
        var seek = Int64.min
        if backwards || ahead {
            let point = seekPoints.lowerBound { $0 > index } - 1
            if point >= 0, let dts = media.frames[seekPoints[point]].dts,
               backwards || dts > previous {
                seek = try ticks(dts)
            } else if backwards, let first = media.frames.first {
                seek = try ticks(first.dts ?? first.time)
            }
        }
        let image = try renderer.picture(at: ticks(frame.time), seekDTS: seek, preset: .full, toneMapHDR: toneMapHDR)
        let orientation = renderer.displayTransform
        last = (index, image, orientation)
        return try checked(image, orientation: orientation)
    }
}

extension ParticipantProject {
    static func chooseAppearance(_ appearances: [ParticipantAppearance], override: String?,
                                 holding: String?, includeCameraOff: Bool) -> ParticipantAppearance? {
        let candidates = appearances.filter {
            $0.state == .video || ($0.state == .presentation && $0.participantID != nil)
                || (includeCameraOff && $0.state == .cameraOff)
        }
        if let override { return candidates.first { $0.id == override } }
        let stages = candidates.filter { $0.role == .stage }
        let preferred = stages.isEmpty ? candidates : stages
        if let holding, let held = preferred.first(where: { $0.id == holding }) { return held }
        return preferred.min {
            let lhs = $0.bounds.width * $0.bounds.height
            let rhs = $1.bounds.width * $1.bounds.height
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
}

enum ParticipantCompositor {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false, .name: "MPCut Output Picture",
            .workingColorSpace: StillImage.linear2020, .workingFormat: CIFormat.RGBAh
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func rect(_ bounds: ParticipantBounds, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + bounds.x * extent.width,
               y: extent.minY + (1 - bounds.y - bounds.height) * extent.height,
               width: bounds.width * extent.width, height: bounds.height * extent.height)
    }

    static func color(_ rgb: UInt32, in extent: CGRect) -> CIImage {
        func channel(_ shift: UInt32) -> Double { Double((rgb >> shift) & 0xFF) / 255 }
        let color = CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        return CIImage(color: CIColor(cgColor: color)).cropped(to: extent)
    }

    static func redact(_ original: CIImage, appearances: [ParticipantAppearance],
                       treatments: [String: ParticipantRedaction], allowMetal: Bool = true) -> CIImage {
        let regions = appearances.flatMap { appearance -> [(CGRect, ParticipantRedaction)] in
            guard let id = appearance.participantID, let treatment = treatments[id] else { return [] }
            return [appearance.bounds, appearance.labelBounds].compactMap { bounds in
                guard let bounds else { return nil }
                let area = rect(bounds, in: original.extent).integral.insetBy(dx: -2, dy: -2).intersection(original.extent)
                return area.isEmpty ? nil : (area, treatment)
            }
        }
        let blurAreas = regions.filter { $0.1.treatment == .blur }.map(\.0)
        var result = original
        // Small graphs stay lazy. Dense graphs benefit from batching their blur regions on Metal.
        if allowMetal, blurAreas.count >= 16,
           let picture = ParticipantMetalBlur.shared?.apply(to: original, areas: blurAreas) {
            result = picture
        } else {
            for area in blurAreas {
                let radius = max(10, max(area.width, area.height) / 10)
                let overlay = original.cropped(to: area).clampedToExtent()
                    .applyingGaussianBlur(sigma: radius).cropped(to: area)
                result = overlay.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: color(0xffffff, in: area)
                ]).cropped(to: original.extent)
            }
        }
        // Cover layers are applied last so a neighboring blur cannot overwrite them.
        for (area, treatment) in regions where treatment.treatment == .opaque || treatment.treatment == .omit {
            result = color(treatment.color, in: area).composited(over: result)
        }
        return result
    }

    static func place(_ picture: CIImage, inside slot: CGRect, framing: ParticipantSlotFraming,
                      anchorX: Double = 0.5, anchorY: Double = 0.5) -> CIImage {
        let fitted = placementTransform(picture.extent, inside: slot, framing: framing, anchorX: anchorX, anchorY: anchorY)
        return picture.transformed(by: fitted, highQualityDownsample: true).cropped(to: slot)
    }

    static func placementTransform(_ extent: CGRect, inside slot: CGRect, framing: ParticipantSlotFraming,
                                   anchorX: Double = 0.5, anchorY: Double = 0.5) -> CGAffineTransform {
        let xScale = slot.width / extent.width
        let yScale = slot.height / extent.height
        let scale = framing == .fill ? max(xScale, yScale) : min(xScale, yScale)
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        return origin.concatenating(.init(scaleX: scale, y: scale))
            .concatenating(.init(translationX: slot.minX + (slot.width - extent.width * scale) * anchorX,
                                 y: slot.minY + (slot.height - extent.height * scale) * (1 - anchorY)))
    }

    static func slots(_ shot: ParticipantShotLayout, count: Int, extent: CGRect) -> [CGRect] {
        let columns: Int
        let rows: Int
        switch shot {
        case .solo, .original, .arranged: (columns, rows) = (1, 1)
        case .pair: (columns, rows) = (2, 1)
        case .grid:
            let side = max(2, Int(ceil(sqrt(Double(count)))))
            (columns, rows) = (side, side)
        case .flow: (columns, rows) = count <= 1 ? (1, 1) : count == 2 ? (2, 1) : (2, 2)
        }
        let width = extent.width / Double(columns)
        let height = extent.height / Double(rows)
        return (0..<count).map { index in
            .init(x: Double(index % columns) * width, y: extent.height - Double(index / columns + 1) * height,
                  width: width, height: height)
        }
    }
}
