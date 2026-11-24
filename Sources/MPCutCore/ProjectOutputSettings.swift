import Foundation

extension CutProject {
    /// Layouts and treatments can use a canvas derived from the recording.
    public var hasStoredOutputCanvas: Bool {
        stillFormat != nil || participants.tileOutput != nil || participants.render != nil
    }

    /// A still-only sequence already stores its delivery canvas with the still format.
    public var projectOutputSettings: TileOutputSettings {
        var settings = participants.tileOutput ?? .init(
            canvas: participants.render?.canvas ?? .init(),
            audio: participants.render?.audio ?? .init(mode: .program),
            unresolvedPrivacy: participants.render?.unresolvedPrivacy ?? .stop
        )
        if let format = stillFormat {
            settings.canvas.width = format.width
            settings.canvas.height = format.height
            settings.canvas.frameRate = RationalTime(numerator: format.cadence.denominator,
                                                      denominator: format.cadence.numerator)
        }
        return settings
    }

    public func settingProjectOutputCanvas(_ canvas: ParticipantCanvas) throws -> Self {
        if let format = stillFormat {
            guard canvas.frameRate > .zero else {
                throw CutError(code: "invalid_still_format", message: "Choose a positive frame rate.")
            }
            let cadence = RationalTime(numerator: canvas.frameRate.denominator, denominator: canvas.frameRate.numerator)
            let next = StillTimelineFormat(width: canvas.width, height: canvas.height, cadence: cadence,
                                           codec: format.codec, container: format.container)
            try next.validate(color: programColorPolicy ?? StillTimelineFormat.sdrColorPolicy)
            let base = try migratingLegacyTiles()
            return try base.editingStills(sequence: { sequence in
                sequence.stillFormat = next
                if sequence.participants.render != nil {
                    sequence.participants.tileOutput?.canvas = canvas
                }
                guard cadence != format.cadence else { return }
                sequence.items = sequence.items.map { item in
                    guard var insert = item.still else { return item }
                    insert.cadence = cadence
                    if (try? next.frameCount(for: insert.duration)) == nil { insert.usesExactDuration = true }
                    return .still(insert)
                }
            }, multicam: { _ in })
        }
        var settings = projectOutputSettings
        settings.canvas = canvas
        return try settingProjectTileOutput(settings, explicitCanvas: true)
    }

    public func settingProjectOutputAudio(_ audio: ParticipantRenderAudio,
                                          defaultCanvas: ParticipantCanvas? = nil) throws -> Self {
        guard audio != projectOutputSettings.audio else { return self }
        var settings = projectOutputSettings
        if !hasStoredOutputCanvas, let defaultCanvas { settings.canvas = defaultCanvas }
        settings.audio = audio
        return try settingProjectTileOutput(settings)
    }

    public func settingProjectOutputPrivacy(_ privacy: ParticipantUnresolvedPrivacy,
                                            defaultCanvas: ParticipantCanvas? = nil) throws -> Self {
        guard privacy != projectOutputSettings.unresolvedPrivacy else { return self }
        var settings = projectOutputSettings
        if !hasStoredOutputCanvas, let defaultCanvas { settings.canvas = defaultCanvas }
        settings.unresolvedPrivacy = privacy
        return try settingProjectTileOutput(settings)
    }

    private func settingProjectTileOutput(_ settings: TileOutputSettings, explicitCanvas: Bool = false) throws -> Self {
        guard stillFormat == nil else {
            throw CutError(code: "invalid_project_output", message: "Use the still timeline soundtrack controls.")
        }
        guard settings != projectOutputSettings || (explicitCanvas && !hasStoredOutputCanvas) else { return self }
        try ParticipantRenderPlan(canvas: settings.canvas, shots: [.init(layout: .original)],
                                  audio: settings.audio).validate(allowNativeLayouts: true)
        try validateProjectOutputAudio(settings.audio)
        var updated = try migratingLegacyTiles()
        var metadata = updated.participants
        metadata.tileOutput = settings
        updated.participants = metadata
        try updated.validate()
        return updated
    }

    private func validateProjectOutputAudio(_ audio: ParticipantRenderAudio) throws {
        switch audio.mode {
        case .silence, .program:
            return
        case .iso:
            if let id = audio.ids.first, let binding = participants.audioBinding(for: id),
               isMulticam || binding.selection != nil { return }
        case .lanes:
            if case .multicam(let project) = self,
               Set(audio.ids).isSubset(of: Set(project.mixLanes.map(\.id))) { return }
        case .follow:
            if case .multicam(let project) = self, let id = audio.ids.first,
               project.recordings(for: id).contains(where: { $0.audioStream != nil }) { return }
        }
        throw CutError(code: "invalid_project_output_audio", message: "Choose an available soundtrack source.")
    }

    private var isMulticam: Bool {
        if case .multicam = self { return true }
        return false
    }
}
