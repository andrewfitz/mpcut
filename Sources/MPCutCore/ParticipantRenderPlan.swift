import Foundation

public struct ParticipantCanvas: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: RationalTime
    /// RGB, in 0xRRGGBB order.
    public var background: UInt32

    private enum CodingKeys: String, CodingKey { case width, height, background, frameRate = "frame_rate" }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_plan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try values.decodeIfPresent(Int.self, forKey: .width) ?? 1920,
                  height: try values.decodeIfPresent(Int.self, forKey: .height) ?? 1080,
                  frameRate: try values.decodeIfPresent(RationalTime.self, forKey: .frameRate) ?? .init(numerator: 30),
                  background: try values.decodeIfPresent(UInt32.self, forKey: .background) ?? 0)
    }

    public init(width: Int = 1920, height: Int = 1080, frameRate: RationalTime = .init(numerator: 30),
                background: UInt32 = 0) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.background = background
    }
}

public enum ParticipantShotLayout: String, Codable, Hashable, Sendable {
    case solo, pair, grid, flow, original, arranged
}

public enum ParticipantSlotTarget: String, Codable, Hashable, Sendable {
    case participant, camera, presentation, empty
}

public enum ParticipantSlotFraming: String, Codable, Hashable, Sendable {
    case fit, fill
}

public struct ParticipantSlot: Codable, Hashable, Sendable {
    public var target: ParticipantSlotTarget
    /// Participant ID, logical camera angle ID, or presentation appearance ID.
    public var id: String
    public var framing: ParticipantSlotFraming
    public var anchorX: Double
    public var anchorY: Double
    public var background: UInt32?
    public var includeCameraOff: Bool
    public var destinationTileID: String?

    private enum CodingKeys: String, CodingKey {
        case target, id, framing, background
        case destinationTileID = "destination_tile_id"
        case anchorX = "anchor_x", anchorY = "anchor_y", includeCameraOff = "include_camera_off"
    }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_plan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try values.decodeIfPresent(ParticipantSlotTarget.self, forKey: .target) ?? .participant,
                  id: try values.decode(String.self, forKey: .id),
                  framing: try values.decodeIfPresent(ParticipantSlotFraming.self, forKey: .framing) ?? .fit,
                  anchorX: try values.decodeIfPresent(Double.self, forKey: .anchorX) ?? 0.5,
                  anchorY: try values.decodeIfPresent(Double.self, forKey: .anchorY) ?? 0.5,
                  background: try values.decodeIfPresent(UInt32.self, forKey: .background),
                  includeCameraOff: try values.decodeIfPresent(Bool.self, forKey: .includeCameraOff) ?? true,
                  destinationTileID: try values.decodeIfPresent(String.self, forKey: .destinationTileID))
    }

    public init(target: ParticipantSlotTarget = .participant, id: String, framing: ParticipantSlotFraming = .fit,
                anchorX: Double = 0.5, anchorY: Double = 0.5, background: UInt32? = nil, includeCameraOff: Bool = true,
                destinationTileID: String? = nil) {
        self.target = target
        self.id = id
        self.framing = framing
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.background = background
        self.includeCameraOff = includeCameraOff
        self.destinationTileID = destinationTileID
    }
}

public enum ParticipantShotClock: String, Codable, Sendable {
    case output, group
}

public struct ParticipantShot: Codable, Equatable, Sendable {
    /// Nil supplies the default shot. Timed output shots override timed group shots.
    public var range: MulticamRange?
    public var clock: ParticipantShotClock
    /// A timed output shot can additionally be restricted to this assembly occurrence.
    public var occurrence: Int?
    public var layout: ParticipantShotLayout
    public var slots: [ParticipantSlot]
    public var compact: Bool

    private enum CodingKeys: String, CodingKey { case range, clock, occurrence, layout, slots, compact }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_plan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(range: try values.decodeIfPresent(MulticamRange.self, forKey: .range),
                  clock: try values.decodeIfPresent(ParticipantShotClock.self, forKey: .clock) ?? .output,
                  occurrence: try values.decodeIfPresent(Int.self, forKey: .occurrence),
                  layout: try values.decode(ParticipantShotLayout.self, forKey: .layout),
                  slots: try values.decodeIfPresent([ParticipantSlot].self, forKey: .slots) ?? [],
                  compact: try values.decodeIfPresent(Bool.self, forKey: .compact) ?? false)
    }

    public init(range: MulticamRange? = nil, clock: ParticipantShotClock = .output, occurrence: Int? = nil,
                layout: ParticipantShotLayout, slots: [ParticipantSlot] = [], compact: Bool = false) {
        self.range = range
        self.clock = clock
        self.occurrence = occurrence
        self.layout = layout
        self.slots = slots
        self.compact = compact
    }
}

public enum ParticipantAudioMode: String, Codable, Sendable {
    case silence, program, lanes, iso, follow
}

public struct ParticipantRenderAudio: Codable, Equatable, Sendable {
    public var mode: ParticipantAudioMode
    /// Lane IDs for lanes, one participant ID for iso, or one angle ID for follow.
    public var ids: [String]

    private enum CodingKeys: String, CodingKey { case mode, ids }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_plan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decode(ParticipantAudioMode.self, forKey: .mode),
                  ids: try values.decodeIfPresent([String].self, forKey: .ids) ?? [])
    }

    public init(mode: ParticipantAudioMode = .silence, ids: [String] = []) {
        self.mode = mode
        self.ids = ids
    }
}

public enum ParticipantMaskTreatment: String, Codable, Sendable {
    case opaque, blur, omit
}

public struct ParticipantRedaction: Codable, Equatable, Sendable {
    public var participantID: String
    public var treatment: ParticipantMaskTreatment
    public var color: UInt32

    private enum CodingKeys: String, CodingKey { case participantID = "participant_id", treatment, color }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_plan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(participantID: try values.decode(String.self, forKey: .participantID),
                  treatment: try values.decode(ParticipantMaskTreatment.self, forKey: .treatment),
                  color: try values.decodeIfPresent(UInt32.self, forKey: .color) ?? 0)
    }

    public init(participantID: String, treatment: ParticipantMaskTreatment, color: UInt32 = 0) {
        self.participantID = participantID
        self.treatment = treatment
        self.color = color
    }
}

public enum ParticipantUnresolvedPrivacy: String, Codable, Sendable {
    case stop, cover
}

public struct ParticipantRenderPlan: Codable, Equatable, Sendable {
    public var canvas: ParticipantCanvas
    public var shots: [ParticipantShot]
    public var audio: ParticipantRenderAudio
    public var redactions: [ParticipantRedaction]
    public var unresolvedPrivacy: ParticipantUnresolvedPrivacy

    private enum CodingKeys: String, CodingKey { case canvas, shots, audio, redactions, unresolvedPrivacy = "unresolved_privacy" }

    public init(from decoder: Decoder) throws {
        try ProjectField.rejectUnknown(CodingKeys.self, in: decoder, code: "invalid_participant_plan")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(canvas: try values.decodeIfPresent(ParticipantCanvas.self, forKey: .canvas) ?? .init(),
                  shots: try values.decode([ParticipantShot].self, forKey: .shots),
                  audio: try values.decodeIfPresent(ParticipantRenderAudio.self, forKey: .audio) ?? .init(),
                  redactions: try values.decodeIfPresent([ParticipantRedaction].self, forKey: .redactions) ?? [],
                  unresolvedPrivacy: try values.decodeIfPresent(ParticipantUnresolvedPrivacy.self, forKey: .unresolvedPrivacy) ?? .stop)
    }

    public init(canvas: ParticipantCanvas = .init(), shots: [ParticipantShot],
                audio: ParticipantRenderAudio = .init(), redactions: [ParticipantRedaction] = [],
                unresolvedPrivacy: ParticipantUnresolvedPrivacy = .stop) {
        self.canvas = canvas
        self.shots = shots
        self.audio = audio
        self.redactions = redactions
        self.unresolvedPrivacy = unresolvedPrivacy
    }

    public func validate(allowNativeLayouts: Bool = false) throws {
        guard (2...8192).contains(canvas.width), (2...8192).contains(canvas.height),
              canvas.width.isMultiple(of: 2), canvas.height.isMultiple(of: 2),
              canvas.frameRate > .zero, canvas.frameRate.seconds <= 120,
              canvas.frameRate.numerator <= Int64(Int32.max),
              canvas.background <= 0xFFFFFF else { throw invalid("Choose even canvas dimensions and a frame rate up to 120.") }
        guard shots.filter({ $0.range == nil }).count == 1 else { throw invalid("Supply exactly one default shot.") }
        for shot in shots {
            let capacity: Int
            switch shot.layout {
            case .original: capacity = 0
            case .solo: capacity = 1
            case .pair: capacity = 2
            case .flow: capacity = 4
            case .grid: capacity = allowNativeLayouts ? 64 : 4
            case .arranged: capacity = allowNativeLayouts ? Int.max : 0
            }
            guard (allowNativeLayouts || shot.layout != .arranged), shot.slots.count <= capacity, (capacity == 0 || !shot.slots.isEmpty),
                  !shot.compact || shot.layout == .flow else { throw invalid("The shot layout does not accommodate those slots.") }
            if let range = shot.range {
                guard range.from < range.to, shot.clock != .output || range.from >= .zero,
                      shot.occurrence == nil || (shot.clock == .output && shot.occurrence! >= 0) else {
                    throw invalid("Choose a nonempty range for a timed shot.")
                }
            } else if shot.occurrence != nil {
                throw invalid("Choose a time range for the assembly occurrence override.")
            }
            let destinations = shot.slots.compactMap(\.arrangedDestination)
            guard shot.layout == .arranged
                ? destinations.count == shot.slots.count && destinations.allSatisfy(validStillID)
                    && Set(destinations).count == destinations.count
                : destinations.isEmpty && !shot.slots.contains(where: { $0.target == .empty }) else {
                throw invalid("Arranged slots require distinct destination tiles.")
            }
            for slot in shot.slots {
                guard !slot.id.isEmpty, (0...1).contains(slot.anchorX), (0...1).contains(slot.anchorY),
                      slot.background.map({ $0 <= 0xFFFFFF }) ?? true else { throw invalid("A shot slot has invalid geometry or color.") }
            }
        }
        for timedShots in ParticipantTimedShot.index(shots).values {
            for (previous, next) in zip(timedShots, timedShots.dropFirst()) where previous.range.to > next.range.from {
                throw invalid("Timed shots on the same clock must not overlap.")
            }
        }
        guard Set(audio.ids).count == audio.ids.count, audio.ids.allSatisfy({ !$0.isEmpty }),
              Set(redactions.map(\.participantID)).count == redactions.count,
              redactions.allSatisfy({ !$0.participantID.isEmpty && $0.color <= 0xFFFFFF }) else {
            throw invalid("Audio selections and privacy treatments require unique IDs.")
        }
        switch audio.mode {
        case .program, .silence: guard audio.ids.isEmpty else { throw invalid("This audio policy does not use IDs.") }
        case .iso, .follow: guard audio.ids.count == 1 else { throw invalid("This audio policy requires a single ID.") }
        case .lanes: guard !audio.ids.isEmpty else { throw invalid("Select at least one audio lane.") }
        }
        if !allowNativeLayouts, shots.contains(where: { $0.layout == .original }), redactions.contains(where: { $0.treatment == .omit }) {
            throw invalid("Choose blur or opaque cover when retaining the original layout.")
        }
    }

    package func mapSourcePaths(_ transform: (String) throws -> String) rethrows -> Self {
        var result = self
        for shotIndex in result.shots.indices {
            for slotIndex in result.shots[shotIndex].slots.indices where result.shots[shotIndex].slots[slotIndex].target == .camera {
                result.shots[shotIndex].slots[slotIndex].id = try transform(result.shots[shotIndex].slots[slotIndex].id)
            }
        }
        return result
    }

    private func invalid(_ message: String) -> CutError { .init(code: "invalid_participant_plan", message: message) }
}

struct ParticipantTimedShot {
    struct Scope: Hashable {
        let clock: ParticipantShotClock
        var occurrence: Int? = nil
    }

    let shot: ParticipantShot
    let range: MulticamRange

    static func index(_ shots: [ParticipantShot]) -> [Scope: [Self]] {
        let timed = shots.compactMap { shot in shot.range.map { Self(shot: shot, range: $0) } }
        return Dictionary(grouping: timed) { Scope(clock: $0.shot.clock, occurrence: $0.shot.occurrence) }
            .mapValues { $0.sorted { $0.range.from < $1.range.from } }
    }
}

extension Array where Element == ParticipantTimedShot {
    func shot(at time: RationalTime) -> ParticipantShot? {
        let index = lowerBound { $0.range.to > time }
        guard indices.contains(index), self[index].range.contains(time) else { return nil }
        return self[index].shot
    }

    func overlapping(_ range: MulticamRange) -> ArraySlice<Element> {
        let first = lowerBound { $0.range.to > range.from }
        let end = lowerBound { $0.range.from >= range.to }
        return self[first..<end]
    }
}

extension ParticipantSlot {
    package var arrangedDestination: String? {
        destinationTileID ?? (target == .empty ? id : nil)
    }
}
