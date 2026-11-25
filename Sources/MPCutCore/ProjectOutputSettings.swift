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

    package func sourceOutputCanvas(width: Int, height: Int, frameRate: RationalTime) -> ParticipantCanvas? {
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 8192 / Double(max(width, height)))
        func even(_ dimension: Int) -> Int {
            max(2, Int((Double(dimension) * scale / 2).rounded()) * 2)
        }
        var canvas = projectOutputSettings.canvas
        canvas.width = even(width)
        canvas.height = even(height)
        if frameRate > .zero, frameRate.seconds <= 120, frameRate.numerator <= Int64(Int32.max) {
            canvas.frameRate = frameRate
        }
        return canvas
    }

    package func sourceOutputCanvas(stream: StreamInfo) -> ParticipantCanvas? {
        sourceOutputCanvas(width: stream.displayWidth, height: stream.displayHeight, frameRate: stream.frameRate)
    }

    package func inspectSourceOutputCanvas(relativeTo document: URL, engine: CutEngine) throws -> ParticipantCanvas? {
        let candidates: [String]
        if case .multicam(let multicam) = self {
            candidates = multicam.recordings(for: multicam.referenceAngle).map(\.file)
        } else {
            candidates = sequenceClips?.map(\.file) ?? []
        }
        var seen: Set<URL> = []
        for path in candidates {
            try engine.checkCancellation()
            let file = Self.mediaURL(path, relativeTo: document)
            guard seen.insert(file).inserted, let stream = try? engine.inspectSummary(file).videoStream else { continue }
            if let canvas = sourceOutputCanvas(stream: stream) { return canvas }
        }
        try engine.checkCancellation()
        return nil
    }

    package func settingProjectOutput(width: Int?, height: Int?, frameRate: RationalTime?, background: UInt32?,
                                      audio: ParticipantRenderAudio?, privacy: ParticipantUnresolvedPrivacy?,
                                      defaultCanvas: ParticipantCanvas) throws -> Self {
        let editsCanvas = width != nil || height != nil || frameRate != nil || background != nil
        var settings = projectOutputSettings
        if !hasStoredOutputCanvas { settings.canvas = defaultCanvas }
        if let width { settings.canvas.width = width }
        if let height { settings.canvas.height = height }
        if let frameRate { settings.canvas.frameRate = frameRate }
        if let background { settings.canvas.background = background }
        if stillFormat != nil {
            guard background == nil, audio == nil, privacy == nil else {
                throw CutError(code: "invalid_project_output",
                               message: "Still timelines only support size and frame rate here. Use the still soundtrack controls.")
            }
            return editsCanvas ? try settingProjectOutputCanvas(settings.canvas) : self
        }
        guard editsCanvas || audio.map({ $0 != settings.audio }) == true
            || privacy.map({ $0 != settings.unresolvedPrivacy }) == true else { return self }
        if let audio { settings.audio = audio }
        if let privacy { settings.unresolvedPrivacy = privacy }
        return try settingProjectTileOutput(settings, explicitCanvas: editsCanvas)
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


package struct ProjectOutputSettingsSnapshot: Encodable {
    package let settings: TileOutputSettings
    package let hasStoredCanvas: Bool
    package let stillFormat: StillTimelineFormat?
    package let stillSoundtrack: CutSequenceClip?

    package init(project: CutProject, defaultCanvas: ParticipantCanvas) {
        hasStoredCanvas = project.hasStoredOutputCanvas
        var output = project.projectOutputSettings
        if !hasStoredCanvas { output.canvas = defaultCanvas }
        settings = output
        stillFormat = project.stillFormat
        stillSoundtrack = project.stillSoundtrack
    }
}
