import Darwin
import Foundation

struct MulticamAudioDownmixPlan: Sendable {
    let lanes: [MulticamAudioConversionPlan?]
    let output: MulticamAudioConversionPlan
    let contextual: @Sendable (CutError, Int, Int) throws -> CutError

    var edit: ResolvedEdit { output.edit }
    var sampleRate: Int { output.sampleRate }
    var channels: Int { output.channels }
    var layout: String { output.layout }
    var action: ReencodeAudio { output.action }
    var warnings: [String] { output.warnings }
}

extension MulticamEngine {
    func resolveDownmixedSound(_ lanes: [[ConvertedSoundSpan]], duration: RationalTime,
                               container requestedContainer: String, action: ReencodeAudio, channels: Int,
                               contextual: @escaping @Sendable (CutError, Int, Int) throws -> CutError) throws -> MulticamAudioDownmixPlan {
        let runner = ReencodeEngine(cancelled: cancelled)
        try runner.checkCancellation()
        let container = ExportRules.multicamMuxContainer(requestedContainer.lowercased())
        let sampleRate = MulticamProgramMixer.sampleRate
        let frames = try duration.roundedToSamples(sampleRate)
        guard !lanes.isEmpty, frames > 0 else {
            throw CutError(code: "missing_audio", message: "There is no soundtrack selected for downmix.")
        }
        guard channels == 1 || channels == 2, action == .pcm || action == .aac else {
            throw CutError(code: "unsupported_audio", message: "A downmix requires mono or stereo PCM or AAC.")
        }
        guard ExportRules.multicamRenderedAudioActions(container: container).contains(action) else {
            throw CutError(code: "unsupported_audio", message: "\(container.uppercased()) cannot carry the selected rendered audio codec.")
        }

        if ["wav", "wave"].contains(container), frames > 0xFFFF_F000 / Int64(channels * 4) {
            throw CutError(code: "unsupported_container", message: "This downmix exceeds the 4 GB limit of WAV. Choose CAF.")
        }

        let converted = try lanes.enumerated().map { laneIndex, lane -> MulticamAudioConversionPlan? in
            guard !lane.isEmpty else {
                throw CutError(code: "uncovered_audio", message: "A downmix lane has no planned spans.")
            }
            var end = RationalTime.zero
            var audible = false
            for (spanIndex, span) in lane.enumerated() {
                try runner.checkCancellation()
                guard span.output.from == end, span.output.to > end else {
                    throw try contextual(CutError(code: "uncovered_audio", message: "The lane has an unplanned gap on the program clock."),
                                         laneIndex, spanIndex)
                }
                if !audible, span.media != nil || span.stream != nil {
                    audible = try span.output.from.roundedToSamples(sampleRate) < span.output.to.roundedToSamples(sampleRate)
                }
                end = span.output.to
            }
            guard end == duration else {
                throw try contextual(CutError(code: "uncovered_audio", message: "The lane does not cover the entire program."),
                                     laneIndex, lane.count - 1)
            }
            guard audible else { return nil }
            return try resolveConvertedSound(lane, duration: duration, container: container, action: action,
                                             allowsSilence: true, downmixChannels: channels) { issue, spanIndex in
                try contextual(issue, laneIndex, spanIndex)
            }
        }
        let warnings = Array(Set(converted.compactMap { $0 }.flatMap(\.warnings))).sorted()
        let identities = converted.compactMap { $0 }.reduce(into: [URL: SourceIdentity]()) {
            $0.merge($1.edit.identities) { current, _ in current }
        }
        var output = MulticamAudioConversionPlan(
            edit: ResolvedEdit(segments: [], duration: duration, container: container, identities: identities, tracks: .audio),
            inputs: [], action: action, warnings: warnings, helper: try ReencodeEngine.findHelper(override: nil),
            sampleRate: sampleRate, channels: channels, layout: channels == 1 ? "mono" : "stereo", floatingPoint: true)
        switch container {
        case "m4a": output.muxer = "ipod"
        case "wave": output.muxer = "wav"
        default: break
        }
        output.verifiesSampleRange = container != "mkv"
        return MulticamAudioDownmixPlan(lanes: converted, output: output, contextual: contextual)
    }

    func writeConvertedSound(_ plan: MulticamAudioDownmixPlan, to output: URL,
                             progress: (@Sendable (Double) -> Void)? = nil) throws {
        let runner = ReencodeEngine(cancelled: cancelled)
        let files = FileManager.default
        let directory = output.deletingLastPathComponent().appendingPathComponent("downmix-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        let sum = directory.appendingPathComponent("sum.raw")
        guard files.createFile(atPath: sum.path, contents: nil) else {
            throw CutError(code: "audio_conversion_failed", message: "Could not create the downmix staging file.")
        }
        let accumulator = try FileHandle(forUpdating: sum)
        defer { try? accumulator.close() }
        let totalFrames = try plan.edit.duration.roundedToSamples(plan.sampleRate)
        let channels = plan.channels
        let floatStride = UInt64(channels * MemoryLayout<Float>.stride)
        let doubleStride = UInt64(channels * MemoryLayout<Double>.stride)
        let size = UInt64(totalFrames).multipliedReportingOverflow(by: doubleStride)
        guard !size.overflow, size.partialValue <= UInt64(Int64.max) else {
            throw CutError(code: "time_overflow", message: "The downmix staging file would be too large.")
        }
        try accumulator.truncate(atOffset: size.partialValue)

        let blockFrames: Int64 = 8_192
        var converted = [Float](repeating: 0, count: Int(blockFrames) * channels)
        var mixed = [Double](repeating: 0, count: converted.count)

        func readSamples(_ file: FileHandle, into buffer: UnsafeMutableRawBufferPointer, bytes: Int) throws {
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < bytes {
                let count = Darwin.read(file.fileDescriptor, base.advanced(by: offset), bytes - offset)
                if count < 0 {
                    let failure = errno
                    if failure == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
                }
                guard count > 0 else {
                    throw CutError(code: "audio_conversion_failed", message: "A downmix staging file ended before the planned sample count.")
                }
                offset += count
            }
        }

        let laneCount = plan.lanes.count
        for (index, lane) in plan.lanes.enumerated() {
            try runner.checkCancellation()
            guard let lane else { continue }
            let laneDirectory = directory.appendingPathComponent("lane")
            try files.createDirectory(at: laneDirectory, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: laneDirectory) }
            let raw = laneDirectory.appendingPathComponent("lane.raw")
            let laneStart = 0.75 * Double(index) / Double(laneCount)
            let laneShare = 0.75 / Double(laneCount)
            do {
                // Mix each validated span while its staging file is open, without assembling a second copy of the lane.
                try stageConvertedSound(lane, to: raw, consumeSpan: { part, start, count in
                    let reader = try FileHandle(forReadingFrom: part)
                    defer { try? reader.close() }
                    var cursor = start
                    let spanEnd = start + count
                    try accumulator.seek(toOffset: UInt64(start) * doubleStride)
                    while cursor < spanEnd {
                        try runner.checkCancellation()
                        let frames = min(blockFrames, spanEnd - cursor)
                        let values = Int(frames) * channels
                        let bytes = Int(UInt64(frames) * doubleStride)
                        let offset = UInt64(cursor) * doubleStride
                        try converted.withUnsafeMutableBytes {
                            try readSamples(reader, into: $0, bytes: Int(UInt64(frames) * floatStride))
                        }
                        try mixed.withUnsafeMutableBytes { try readSamples(accumulator, into: $0, bytes: bytes) }
                        mixed.withUnsafeMutableBufferPointer { destination in
                            converted.withUnsafeBufferPointer { source in
                                MulticamProgramMixer.accumulate(
                                    UnsafeBufferPointer(start: source.baseAddress, count: values),
                                    into: UnsafeMutableBufferPointer(start: destination.baseAddress, count: values),
                                    channels: channels, laneCount: laneCount)
                            }
                        }
                        try accumulator.seek(toOffset: offset)
                        try mixed.withUnsafeBytes { try accumulator.write(contentsOf: $0.prefix(bytes)) }
                        cursor += frames
                        if cursor < spanEnd {
                            progress?(laneStart + laneShare * Double(cursor) / Double(totalFrames))
                        }
                    }
                }) {
                    progress?(laneStart + laneShare * $0)
                }
                progress?(laneStart + laneShare)
            } catch let issue as CutError where issue.code != "cancelled" {
                let stagedIndex = max(0, (issue.segment ?? 1) - 1)
                let spanIndex = lane.edit.segments.indices.contains(stagedIndex)
                    ? (lane.edit.segments[stagedIndex].sourceClipIndex ?? 0) : 0
                throw try plan.contextual(issue, index, spanIndex)
            } catch let issue where !(issue is CutError) {
                throw try plan.contextual(CutError(code: "audio_conversion_failed", message: issue.localizedDescription), index, 0)
            }
        }

        try accumulator.close()
        progress?(0.75)
        // Encode directly from the sum to keep the double-precision result until final formatting.
        try encodeConvertedSound(plan.output, from: sum, to: output, inputSampleFormat: "f64le") {
            progress?(0.75 + 0.25 * $0)
        }
    }
}
