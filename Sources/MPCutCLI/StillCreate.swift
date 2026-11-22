import Foundation
import MPCutCore

struct StillCreateOptions {
    let project: URL
    let image: URL
    let format: StillTimelineFormat
    let duration: RationalTime
    let color: StillTimelineFormat.Color

    init(_ arguments: [String]) throws {
        let supported: Set<String> = [
            "--out-project", "--image", "--width", "--height", "--rate", "--codec",
            "--container", "--duration", "--frames", "--color"
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
        image = try fileURL(required("--image"), label: "Image")
        let rate = try RationalTime(parsing: required("--rate"))
        guard let width = try Int(required("--width")), let height = try Int(required("--height")),
              rate > .zero else {
            throw CLIError("invalid_still_format", "Enter a canvas size and a positive frame rate.")
        }
        guard let codec = try ReencodeCodec(rawValue: required("--codec")) else {
            throw CLIError("invalid_still_format", "--codec accepts h264, hevc or prores.")
        }
        guard let color = StillTimelineFormat.Color(rawValue: values["--color"] ?? "sdr") else {
            throw CLIError("invalid_still_format", "--color accepts sdr, pq or hlg.")
        }
        self.color = color
        let cadence = RationalTime(numerator: rate.denominator, denominator: rate.numerator)
        format = StillTimelineFormat(width: width, height: height, cadence: cadence,
                                     codec: codec, container: try required("--container"))
        try format.validate(color: color.policy)
        switch (values["--duration"], values["--frames"]) {
        case (let time?, nil):
            duration = try RationalTime(parsing: time)
        case (nil, let frames?):
            guard let count = Int64(frames), count > 0 else {
                throw CLIError("invalid_still_time", "--frames must be a positive integer.")
            }
            duration = try cadence.multiplied(by: .init(numerator: count))
        default:
            throw CLIError("invalid_arguments", "Choose either --duration or --frames.")
        }
        _ = try format.frameCount(for: duration)
    }
}

struct StillCreateReport: Encodable {
    let ok = true
    let project: String
    let format: StillTimelineFormat
    let assetID: String
    let placementID: String
    let duration: RationalTime
    let colorPolicy: StillProgramColorPolicy
}

extension StillCreateOptions {
    func create() throws -> StillCreateReport {
        let identity = try SourceIdentity(image)
        _ = try StillImage.inspect(image)
        let fingerprint = try StillImage.fingerprint(image)
        guard try SourceIdentity(image) == identity else {
            throw CutError(code: "source_changed", message: "The still image changed while creating the project.")
        }
        let asset = StillAsset(id: UUID().uuidString, file: CutProject.relativeMediaPath(image.path, to: project),
                               displayName: image.lastPathComponent, fingerprint: fingerprint)
        let placementID = UUID().uuidString
        let document = try CutProject.makeStillTimeline(format: format, asset: asset, placementID: placementID,
                                                        duration: duration, colorPolicy: color.policy)
        try document.save(to: project, undo: [], redo: [], replacingExisting: false)
        return StillCreateReport(project: project.path, format: format, assetID: asset.id,
                                 placementID: placementID, duration: duration, colorPolicy: color.policy)
    }
}
