import CoreImage
import Foundation

struct ParticipantFrameGeometry {
    let appearances: [ParticipantAppearance]
    let verified: Bool

    var needsPrivacyCover: Bool {
        !verified || appearances.contains {
            let isPresentation = $0.role == .presentation && $0.state == .presentation
            return $0.state == .unknown || ($0.participantID == nil && !isPresentation)
        }
    }
}

struct ParticipantGeometryIndex {
    let usesScannedGeometry: Bool
    private let points: [RationalTime]
    private let frames: [ParticipantFrameGeometry]
    private let selections: [Selection: [Change]]

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
        let geometry = project.sources.first { $0.sourceID == sourceID }
        usesScannedGeometry = geometry?.analysisIdentity != nil
        let appearances = geometry?.appearances ?? []
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
            let verified = coverage.indices.contains(index) && coverage[index].range.contains(time) && coverage[index].state == .verified
            indexed.append(.init(appearances: active, verified: verified))
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
        return frames.indices.contains(index) ? frames[index] : .init(appearances: [], verified: false)
    }

    func appearance(_ slot: ParticipantSlot, at time: RationalTime) -> ParticipantAppearance? {
        if slot.target == .presentation {
            return at(time).appearances.first { $0.id == slot.id && $0.role == .presentation && $0.state == .presentation }
        }
        guard let changes = selections[.init(id: slot.id, includeCameraOff: slot.includeCameraOff)] else { return nil }
        let index = changes.lowerBound { $0.time > time } - 1
        guard index >= 0, let id = changes[index].appearanceID else { return nil }
        return at(time).appearances.first { $0.id == id }
    }
}

final class ParticipantPictureReader {
    private let media: MediaInfo
    private let renderer: JPEGRenderer
    private let seekPoints: [Int]
    private let scanOrientation: CGAffineTransform
    private var last: (index: Int, image: CIImage, orientation: CGAffineTransform)?

    init(_ media: MediaInfo, control: JPEGControl) throws {
        self.media = media
        renderer = try JPEGRenderer(media: media, control: control)
        seekPoints = media.frames.indices.filter { media.frames[$0].canStart && media.frames[$0].dts != nil }
        switch (media.video.rotation % 360 + 360) % 360 {
        case 90: scanOrientation = .init(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 180: scanOrientation = .init(scaleX: -1, y: -1)
        case 270: scanOrientation = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: scanOrientation = .identity
        }
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
        let image = try renderer.picture(at: ticks(frame.time), seekDTS: seek, preset: .full)
        let orientation = renderer.displayTransform
        last = (index, image, orientation)
        return try checked(image, orientation: orientation)
    }
}

extension ParticipantProject {
    static func chooseAppearance(_ appearances: [ParticipantAppearance], override: String?,
                                 holding: String?, includeCameraOff: Bool) -> ParticipantAppearance? {
        let candidates = appearances.filter { $0.state == .video || (includeCameraOff && $0.state == .cameraOff) }
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
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "MPCut Participant Render"])
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func rect(_ bounds: ParticipantBounds, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + bounds.x * extent.width,
               y: extent.minY + (1 - bounds.y - bounds.height) * extent.height,
               width: bounds.width * extent.width, height: bounds.height * extent.height)
    }

    static func color(_ rgb: UInt32, in extent: CGRect) -> CIImage {
        func channel(_ shift: UInt32) -> Double { Double((rgb >> shift) & 0xFF) / 255 }
        return CIImage(color: CIColor(red: channel(16), green: channel(8), blue: channel(0))).cropped(to: extent)
    }

    static func redact(_ original: CIImage, appearances: [ParticipantAppearance],
                       treatments: [String: ParticipantRedaction]) -> CIImage {
        var result = original
        // Cover layers are applied last so a neighboring blur cannot overwrite them.
        for pass in [ParticipantMaskTreatment.blur, .opaque] {
            for appearance in appearances {
                guard let id = appearance.participantID, let treatment = treatments[id],
                      pass == treatment.treatment || (pass == .opaque && treatment.treatment == .omit) else { continue }
                for bounds in [appearance.bounds, appearance.labelBounds].compactMap({ $0 }) {
                    let area = rect(bounds, in: original.extent).integral.insetBy(dx: -2, dy: -2).intersection(original.extent)
                    let overlay: CIImage
                    if pass == .blur {
                        let radius = max(10, max(area.width, area.height) / 10)
                        overlay = original.cropped(to: area).clampedToExtent()
                            .applyingGaussianBlur(sigma: radius).cropped(to: area)
                    } else {
                        overlay = color(treatment.color, in: area)
                    }
                    result = overlay.composited(over: result)
                }
            }
        }
        return result
    }

    static func place(_ picture: CIImage, inside slot: CGRect, framing: ParticipantSlotFraming,
                      anchorX: Double = 0.5, anchorY: Double = 0.5) -> CIImage {
        let extent = picture.extent
        let xScale = slot.width / extent.width
        let yScale = slot.height / extent.height
        let scale = framing == .fill ? max(xScale, yScale) : min(xScale, yScale)
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let fitted = origin.concatenating(.init(scaleX: scale, y: scale))
            .concatenating(.init(translationX: slot.minX + (slot.width - extent.width * scale) * anchorX,
                                 y: slot.minY + (slot.height - extent.height * scale) * (1 - anchorY)))
        return picture.transformed(by: fitted).cropped(to: slot)
    }

    static func slots(_ shot: ParticipantShotLayout, count: Int, extent: CGRect) -> [CGRect] {
        let columns: Int
        let rows: Int
        switch shot {
        case .solo, .original: (columns, rows) = (1, 1)
        case .pair: (columns, rows) = (2, 1)
        case .grid: (columns, rows) = (2, 2)
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
