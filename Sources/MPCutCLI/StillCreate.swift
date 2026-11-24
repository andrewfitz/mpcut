import Foundation
import MPCutCore

struct StillSoundtrackOptions {
    let file: URL
    let stream: Int?
    let from: RationalTime?
    let to: RationalTime?

    init(path: String?, stream: String?, from: RationalTime?, to: RationalTime?) throws {
        guard let path else { throw CLIError("invalid_arguments", "Specify --soundtrack FILE.") }
        file = try fileURL(path, label: "Soundtrack")
        if let stream {
            guard let index = Int(stream), index >= 0 else {
                throw CLIError("invalid_arguments", "--audio-stream takes a nonnegative absolute stream index.")
            }
            self.stream = index
        } else {
            self.stream = nil
        }
        self.from = from
        self.to = to
    }

    func load(relativeTo project: URL, cancelled: @escaping @Sendable () -> Bool) throws -> (CutSequenceClip, MediaInfo) {
        let media = try CutEngine(cancelled: cancelled).inspect(file, keyframes: false)
        var clip = try StillSoundtrack.reference(media: media, stream: stream, from: from, to: to)
        clip.file = CutProject.relativeMediaPath(media.url.path, to: project)
        return (clip, media)
    }
}

struct StillCreateOptions {
    let project: URL
    let image: URL?
    let framing: StillImageFraming
    let format: StillTimelineFormat
    let duration: RationalTime
    let color: StillTimelineFormat.Color
    let soundtrack: StillSoundtrackOptions?
    let fitSoundtrack: Bool

    init(_ arguments: [String]) throws {
        let supported: Set<String> = [
            "--out-project", "--image", "--gap", "--background", "--width", "--height", "--rate", "--codec",
            "--container", "--duration", "--frames", "--color", "--soundtrack", "--audio-stream", "--from", "--to", "--fit-soundtrack"
        ]
        var options = arguments.filter { $0 != "--json" }.makeIterator()
        var values: [String: String] = [:]
        while let option = options.next() {
            guard supported.contains(option) else {
                throw CLIError("invalid_arguments", "Unknown still create option '\(option)'.")
            }
            guard values[option] == nil else {
                throw CLIError("invalid_arguments", "Duplicate \(option).")
            }
            if ["--gap", "--fit-soundtrack"].contains(option) { values[option] = "true"; continue }
            guard let value = options.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw CLIError("invalid_arguments", "Missing value for \(option).")
            }
            values[option] = value
        }

        func required(_ option: String) throws -> String {
            guard let value = values[option] else {
                throw CLIError("invalid_arguments", "Specify \(option).")
            }
            return value
        }

        project = try fileURL(required("--out-project"), label: "Output")
        guard (values["--gap"] != nil) != (values["--image"] != nil) else {
            throw CLIError("invalid_arguments", "Specify --gap or --image FILE.")
        }
        image = try values["--image"].map { try fileURL($0, label: "Image") }
        framing = StillImageFraming(mode: .fit, background: values["--background"] ?? "#000000")
        try framing.validate()
        let rate = try RationalTime(parsing: required("--rate"))
        guard let width = try Int(required("--width")), let height = try Int(required("--height")),
              rate > .zero else {
            throw CLIError("invalid_still_format", "Enter a canvas size and a positive frame rate.")
        }
        guard let codec = ReencodeCodec(rawValue: values["--codec"] ?? "h264") else {
            throw CLIError("invalid_still_format", "--codec accepts h264, hevc, prores or jpeg.")
        }
        guard let color = StillTimelineFormat.Color(rawValue: values["--color"] ?? "sdr") else {
            throw CLIError("invalid_still_format", "--color accepts sdr, pq or hlg.")
        }
        self.color = color
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        format = StillTimelineFormat(width: width, height: height, cadence: cadence,
                                     codec: codec, container: values["--container"] ?? "mov")
        try format.validate(color: color.policy)
        fitSoundtrack = values["--fit-soundtrack"] != nil
        if values["--soundtrack"] != nil {
            soundtrack = try StillSoundtrackOptions(path: values["--soundtrack"], stream: values["--audio-stream"],
                                                    from: values["--from"].map(RationalTime.init(parsing:)),
                                                    to: values["--to"].map(RationalTime.init(parsing:)))
        } else {
            guard ["--audio-stream", "--from", "--to"].allSatisfy({ values[$0] == nil }) else {
                throw CLIError("invalid_arguments", "Soundtrack range and track options require --soundtrack FILE.")
            }
            soundtrack = nil
        }
        if fitSoundtrack {
            guard soundtrack != nil, image != nil, values["--duration"] == nil, values["--frames"] == nil else {
                throw CLIError("invalid_arguments", "Use --fit-soundtrack with --image and --soundtrack. Omit --duration and --frames.")
            }
        }
        switch (values["--duration"], values["--frames"]) {
        case (let time?, nil):
            duration = try RationalTime(parsing: time)
        case (nil, let frames?):
            guard let count = Int64(frames), count > 0 else {
                throw CLIError("invalid_still_time", "--frames must be a positive integer.")
            }
            duration = try cadence.multiplied(by: .init(numerator: count))
        case (nil, nil) where fitSoundtrack:
            duration = cadence
        default:
            throw CLIError("invalid_arguments", "Choose --duration, --frames, or --fit-soundtrack.")
        }
        _ = try format.frameCount(for: duration)
    }
}

struct StillCreateReport: Encodable {
    let ok = true
    let projectPath: String
    let format: StillTimelineFormat
    let assetID: String
    let placementID: String
    let duration: RationalTime
    let colorPolicy: StillProgramColorPolicy
    let soundtrack: CutSequenceClip?
}

extension StillCreateOptions {
    func create(cancelled: @escaping @Sendable () -> Bool) throws -> StillCreateReport {
        let asset: StillAsset
        if let image {
            let fingerprint = try StillImage.inspectAndFingerprint(image, cancelled: cancelled).fingerprint
            asset = StillAsset(id: ProjectIdentifier.make(), file: CutProject.relativeMediaPath(image.path, to: project),
                               displayName: image.lastPathComponent, fingerprint: fingerprint)
        } else {
            asset = StillAsset(gapID: ProjectIdentifier.make())
        }
        let placementID = ProjectIdentifier.make()
        var document = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: placementID,
                                                        duration: duration, framing: framing, colorPolicy: color.policy)
        var entries = [ProjectMediaSnapshot.Entry(path: asset.file, asset: asset)].compactMap { $0 }
        let soundtrackMedia: MediaInfo?
        if let soundtrack {
            let (clip, media) = try soundtrack.load(relativeTo: project, cancelled: cancelled)
            document = try document.attachingStillSoundtrack(clip)
            if fitSoundtrack { document = try document.fittingStillToSoundtrack() }
            entries.append(.init(path: clip.file, media: media))
            soundtrackMedia = media
        } else {
            soundtrackMedia = nil
        }
        let actualDuration = try document.resolveStills().duration
        let snapshot = ProjectMediaSnapshot(entries: entries)
        _ = try document.saveRevision(to: project, undo: [], redo: [], mediaSnapshot: snapshot, replacingExisting: false, expected: nil) {
            if cancelled() { throw CancellationError() }
            if let soundtrackMedia {
                guard soundtrackMedia.identity.isCurrentSnapshot(at: soundtrackMedia.url) else {
                    throw CutError(code: "source_changed", message: "The soundtrack changed while the project was being saved.")
                }
            }
        }
        return StillCreateReport(projectPath: project.path, format: format, assetID: asset.id,
                                 placementID: placementID, duration: actualDuration, colorPolicy: color.policy, soundtrack: document.stillSoundtrack)
    }
}
