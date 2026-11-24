import Foundation
import PacketWriter

enum StillMatroska {
    // A whole-tick DefaultDuration lets FFmpeg use a SimpleBlock at exactly
    // 40 ms. Every other packet duration needs a BlockGroup with BlockDuration.
    static let heldMuxArguments = ["-r:v", "25"]

    static func pictureConversionClock(_ pictures: [StillExportPicture],
                                       cancelled: (@Sendable () -> Bool)?) throws -> Int {
        let engine = CutEngine(cancelled: cancelled)
        var denominators: Set<Int64> = [1_000]
        for picture in pictures {
            guard case .camera(let media, let input, let frames, _) = picture.content else { continue }
            denominators.insert(picture.output.from.denominator)
            denominators.insert(try media.origin.adding(input.to).denominator)
            for index in frames {
                if index.isMultiple(of: 1_024) { try engine.checkCancellation() }
                denominators.insert(try media.origin.adding(media.frames[index].time).denominator)
            }
        }
        let scale = conversionTimeScale(for: Array(denominators))
        guard denominators.allSatisfy({ Int64(scale).isMultiple(of: $0) }) else {
            throw StillSampleSchedule.unsupported
        }
        return scale
    }

    static func stagePictureIfNeeded(_ plan: StillExportPlan, movie: URL, in directory: URL,
                                     cancelled: @escaping @Sendable () -> Bool) throws -> URL {
        let report = plan.report
        guard report.mode == .smart, report.generatedVideoSampleCount > 0,
              report.copiedCameraDuration > .zero || report.encodedCameraDuration > .zero,
              report.videoCodec == "h264" || report.videoCodec == "hevc" else { return movie }
        let matroska = directory.appendingPathComponent("switchable-picture.mkv")
        let cancellation = Cancellation(cancelled)
        var detail = [CChar](repeating: 0, count: 512)
        let capacity = detail.count
        let result = withExtendedLifetime(cancellation) {
            mpcut_stage_matroska_picture(movie.path, matroska.path, { context, _ in
                guard let context else { return 1 }
                return Unmanaged<Cancellation>.fromOpaque(context).takeUnretainedValue().check() ? 1 : 0
            }, Unmanaged.passUnretained(cancellation).toOpaque(), &detail, capacity)
        }
        if result == 2 { throw CutError(code: "cancelled", message: "The operation was cancelled.") }
        guard result == 0 else {
            throw CutError(code: "write_failed",
                           message: "Could not carry changing decoder configurations into Matroska. \(String(cString: detail))")
        }
        return matroska
    }

    private final class Cancellation {
        let check: @Sendable () -> Bool
        init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
    }

    static func verifyHelper(_ helper: URL, cancelled: (@Sendable () -> Bool)?) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpcut-matroska-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("probe.mov")
        let matroska = directory.appendingPathComponent("probe.mkv")
        let engine = ReencodeEngine(cancelled: cancelled)
        try engine.runHelper(helper, arguments: ["-f", "lavfi", "-i", "color=s=32x32:r=1:d=1",
                                                 "-c:v", "mjpeg", "-n", movie.path],
                             in: directory, timeout: .seconds(10))
        try engine.runHelper(helper, arguments: ["-i", movie.path, "-map", "0:v:0", "-c", "copy"] +
                             heldMuxArguments + ["-f", "matroska", "-n", matroska.path],
                             in: directory, timeout: .seconds(10))
        guard mpcut_verify_matroska_video(matroska.path, [.init(pts: 0, duration: 1_000)], 1) == 0 else {
            throw CutError(code: "unsupported_still_timing",
                           message: "This FFmpeg helper did not write the held picture's Matroska block duration.")
        }
    }

    static func verifyPicture(_ plan: StillExportPlan, file: URL,
                              cancelled: (@Sendable () -> Bool)?) throws {
        var blocks: [MPCutMatroskaBlock] = []
        func append(at time: RationalTime, duration: RationalTime?) throws {
            if blocks.count.isMultiple(of: 1_024), cancelled?() == true {
                throw CutError(code: "cancelled", message: "The operation was cancelled.")
            }
            let pts = try time.roundedToSamples(1_000)
            let length = try duration?.roundedToSamples(1_000) ?? 0
            blocks.append(.init(pts: pts, duration: length))
        }
        for picture in plan.pictures {
            switch picture.content {
            case .camera(let media, let input, let frames, _):
                let shift = try picture.output.from.subtracting(input.from)
                for index in frames {
                    let start = try media.frames[index].time.adding(shift)
                    try append(at: start, duration: nil)
                }
            case .still(_, _, _, let schedule):
                var start = picture.renderOutput.from
                for run in schedule.runs {
                    for _ in 0..<run.count {
                        try append(at: start, duration: run.duration)
                        start = try start.adding(run.duration)
                    }
                }
            }
        }
        guard mpcut_verify_matroska_video(file.path, blocks, blocks.count) == 0 else {
            throw CutError(code: "write_failed",
                           message: "The staged Matroska picture blocks differ from the planned timestamps or held durations.")
        }
    }
}
