import Foundation
import MPCutCore

struct FrameExportOptions {
    enum Source {
        case video(String, JPEGSelection, sample: JPEGSample, limit: Int?)
        case project(String, [RationalTime], clock: StillOptions.Clock?)
    }
    let source: Source
    let output: String
    let mcpImage: Bool
    /// An inline review answers with a list of frames, as a request for several times does.
    let batch: Bool
    let preset: JPEGPreset
    let format: FrameImageFormat
    /// The long edge and crop of review-preset pictures.
    let maxEdge: Int
    let region: CGRect?

    init(_ arguments: [String]) throws {
        var file: String?, output: String?, mode: String?, sample: JPEGSample?, preset: JPEGPreset?
        var format: FrameImageFormat?
        var project: String?
        var clock: StillOptions.Clock?
        var times: [RationalTime] = []
        var stream: Int?, threshold: Double?, minimum: Double?, limit: Int?
        var iterator = arguments.makeIterator()
        var seen = Set<String>()
        var positional = false
        var mcpImage = false, batch = false
        var maxEdge: Int?, region: CGRect?
        func invalid(_ text: String) -> CLIError { CLIError("invalid_arguments", text) }
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next(), !next.isEmpty, !next.hasPrefix("--") else { throw invalid("Missing value for \(flag).") }
            return next
        }
        while let flag = iterator.next() {
            if positional || !flag.hasPrefix("-") {
                guard file == nil else { throw invalid("Supply one source video.") }
                file = flag
                continue
            }
            guard ["--at", "--at-file"].contains(flag) || seen.insert(flag).inserted else { throw invalid("Duplicate option \(flag).") }
            switch flag {
            case "--": positional = true
            case "--json": break
            case "--mcp-image": mcpImage = true
            case "--batch": batch = true
            case "--max-edge":
                guard let edge = Int(try value(flag)) else { throw invalid("Use a whole number of pixels for --max-edge.") }
                maxEdge = try JPEGReviewSize.edge(edge)
            case "--region":
                let parts = try value(flag).split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
                guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3] else {
                    throw invalid("Give --region as X,Y,WIDTH,HEIGHT in fractions of the picture from its top left, such as 0.5,0,0.5,0.5.")
                }
                region = try JPEGReviewSize.region(x: x, y: y, width: width, height: height)
            case "--output": output = try value(flag)
            case "--project": project = try value(flag)
            case "--clock":
                guard let requested = StillOptions.Clock(rawValue: try value(flag)), requested != .source else {
                    throw invalid("Choose sequence, group or assembly.")
                }
                clock = requested
            case "--at", "--at-file":
                let raw = try value(flag)
                let entries = flag == "--at-file" ? try ListFile.scalars(raw, header: "time") : [raw]
                times += try entries.map(RationalTime.init(parsing:))
            case "--select":
                let choice = try value(flag)
                guard ["scenes", "non-silent"].contains(choice) else { throw invalid("Choose scenes or non-silent.") }
                mode = choice
            case "--sample":
                guard let choice = JPEGSample(rawValue: try value(flag)) else { throw invalid("Choose first or midpoint.") }
                sample = choice
            case "--preset":
                guard let choice = JPEGPreset(rawValue: try value(flag)) else { throw invalid("Choose review or full.") }
                preset = choice
            case "--format":
                guard let choice = FrameImageFormat(rawValue: try value(flag)) else {
                    throw invalid("Choose jpeg, png or tiff. PNG and TIFF are lossless and keep the source's depth and color profile.")
                }
                format = choice
            case "--stream":
                guard let choice = Int(try value(flag)), choice >= 0 else { throw invalid("Use a nonnegative audio stream index.") }
                stream = choice
            case "--threshold-db":
                guard let n = Double(try value(flag)), n.isFinite, (-120...0).contains(n) else {
                    throw invalid("Use a threshold between −120 and 0 dBFS.")
                }
                threshold = n
            case "--min-pause-seconds":
                guard let n = Double(try value(flag)), n.isFinite, n > 0 else { throw invalid("Use a positive minimum pause length.") }
                minimum = n
            case "--limit":
                guard let n = Int(try value(flag)), n > 0 else { throw invalid("Use a positive frame limit.") }
                limit = n
            default: throw invalid("Unknown frames option '\(flag)'.")
            }
        }
        if mcpImage {
            guard output == nil, (1...JPEGReviewSize.batchFrames).contains(times.count), times.allSatisfy({ $0 >= .zero }),
                  preset == nil, format == nil,
                  mode == nil, sample == nil, limit == nil, stream == nil, threshold == nil, minimum == nil,
                  let jobDirectory = ProcessInfo.processInfo.environment["MPCUT_REVIEW_JOB_DIRECTORY"],
                  jobDirectory.hasPrefix("/") else {
                throw invalid("Supply 1 through \(JPEGReviewSize.batchFrames) nonnegative --at times for a review image job.")
            }
            output = URL(fileURLWithPath: jobDirectory, isDirectory: true).appendingPathComponent("frames").path
        }
        guard let output, (file == nil) != (project == nil) else {
            throw invalid("Supply a source video or --project PROJECT, and --output NEW_DIRECTORY.")
        }
        self.output = output
        self.mcpImage = mcpImage
        self.batch = batch || (mcpImage && times.count > 1)
        self.preset = preset ?? .review
        self.format = format ?? .jpeg
        guard !batch || mcpImage else { throw invalid("--batch applies to --mcp-image.") }
        guard self.preset == .review || (maxEdge == nil && region == nil) else {
            throw invalid("--max-edge and --region size the review preset. Omit --preset full.")
        }
        self.maxEdge = maxEdge ?? JPEGReviewSize.defaultEdge
        self.region = region
        if let project {
            guard !times.isEmpty, mode == nil, sample == nil, limit == nil,
                  stream == nil, threshold == nil, minimum == nil else {
                throw invalid("Use --project with one or more --at times and optional --clock, --preset and --format.")
            }
            source = .project(project, times, clock: clock)
            return
        }
        guard let file else { throw invalid("Supply a source video.") }
        guard clock == nil else { throw invalid("--clock applies to project frames.") }
        if mode != "non-silent", stream != nil || threshold != nil || minimum != nil {
            throw invalid("Audio settings require --select non-silent.")
        }
        let selection: JPEGSelection
        if !times.isEmpty {
            guard mode == nil, sample == nil, limit == nil else { throw invalid("--at supplies exact times. Use --select, --sample and --limit with range exports.") }
            selection = .times(times)
        } else if mode == "non-silent" {
            selection = .nonSilent(stream: stream, thresholdDB: threshold, minimumPause: minimum ?? 1.5)
        } else {
            selection = .scenes
        }
        source = .video(file, selection, sample: sample ?? .midpoint, limit: limit)
    }
}
