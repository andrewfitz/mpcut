import Foundation

/// Formats and sample precision supported by the program soundtrack writer.
struct ExactSoundEncoding: Sendable {
    let codec: String
    let bitDepth: Int
    let rawFormat: String
    let arguments: [String]
    let warnings: [String]

    init(action: ReencodeAudio, streams: [StreamInfo], layout: String, silenceOnly: Bool) throws {
        let sources = silenceOnly && action != .pcm ? [] : streams
        // MOV, Matroska and CAF state the word length of FLAC and ALAC in the codec header alone.
        guard sources.allSatisfy({ !["alac", "flac"].contains($0.codec) || AudioExportEngine.declaredDepth($0) != nil }) else {
            throw CutError(code: "unsupported_audio", message: "The source does not declare its lossless sample precision.")
        }
        let floatSources = sources.filter { $0.codec.hasPrefix("pcm_f") }
        let integerDepths = sources.compactMap(AudioExportEngine.integerDepth)
        let decodedSources = sources.filter { AudioExportEngine.integerDepth($0) == nil && !$0.codec.hasPrefix("pcm_f") }
        let maximumIntegerDepth = integerDepths.max() ?? 0
        let codecName = ExportRules.displayName(audio: action)
        if action == .pcm {
            switch (floatSources.isEmpty, maximumIntegerDepth, decodedSources.isEmpty) {
            case (true, 1...16, true): bitDepth = 16
            case (true, 17...24, true): bitDepth = 24
            case (true, _, true): bitDepth = 32
            case (true, _, false): bitDepth = 32
            default: bitDepth = maximumIntegerDepth > 24 || floatSources.contains { $0.codec.hasPrefix("pcm_f64") } ? 64 : 32
            }
            guard maximumIntegerDepth <= 32 else {
                throw CutError(code: "unsupported_audio", message: "PCM MOV conversion cannot preserve \(maximumIntegerDepth)-bit integer samples.")
            }
            rawFormat = floatSources.isEmpty ? "s32le" : "f\(bitDepth)le"
            codec = floatSources.isEmpty ? "pcm_s\(bitDepth)le" : "pcm_\(rawFormat)"
            arguments = ["-c:a", codec]
        } else {
            // FFmpeg's FLAC STREAMINFO clock has a 20-bit sample-rate field.
            guard action != .flac || streams.allSatisfy({ $0.sampleRate < 1 << 20 }) else {
                throw CutError(code: "unsupported_audio", message: "FLAC cannot carry the selected sample rate.")
            }
            guard floatSources.isEmpty, maximumIntegerDepth <= 24 else {
                let precision = floatSources.isEmpty ? "\(maximumIntegerDepth)-bit integer" : "floating-point"
                throw CutError(code: "unsupported_audio", message: "The \(codecName) encoder cannot preserve \(precision) samples. Choose PCM in MOV.")
            }
            let layouts = action == .alac
                ? ["mono", "stereo", "3.0", "4.0", "5.0", "5.1", "6.1(back)", "7.1(wide)"]
                : ["mono", "stereo", "3.0", "quad", "5.0", "5.1", "6.1", "7.1"]
            guard layouts.contains(layout) else {
                throw CutError(code: "unsupported_audio", message: "\(codecName) cannot preserve the \(layout) channel layout. Choose PCM in MOV.")
            }
            bitDepth = maximumIntegerDepth <= 16 && decodedSources.isEmpty ? 16 : 24
            codec = action.rawValue
            rawFormat = "s32le"
            let format = bitDepth == 16 ? "s16" : "s32"
            // A trim can leave just one sample in the first decoded frame. Letting FFmpeg
            // infer the FLAC block size from it can fail, even when a long recording follows.
            let blockSize = action == .flac ? ["-frame_size", "4608"] : []
            arguments = ["-c:a", codec, "-sample_fmt", action == .alac ? format + "p" : format,
                         "-bits_per_raw_sample", "\(bitDepth)"] + blockSize
        }
        let decodedCodecs = Set(decodedSources.map(\.codec)).sorted().joined(separator: ", ")
        warnings = decodedSources.isEmpty ? [] :
            ["The \(decodedCodecs) source is decoded to \(bitDepth)-bit PCM for \(codecName) delivery."]
    }
}

/// Lossless packet headers provide the coded count independently of container timestamps.
func continuousLosslessSamples(_ sound: AudioIndex) throws -> Int64? {
    let stream = sound.stream
    guard ["alac", "flac"].contains(stream.codec), !sound.hasPriming, let first = sound.packets.first,
          stream.sampleRate > 0, first.time == sound.start else { return nil }
    let rate = Int64(stream.sampleRate)
    let samplePeriod = RationalTime(numerator: 1, denominator: rate)
    let tolerance = stream.timeBase > samplePeriod ? stream.timeBase : .zero
    var total: Int64 = 0
    for packet in sound.packets {
        let next = total.addingReportingOverflow(Int64(packet.decodedSamples))
        guard packet.decodedSamples > 0, !next.overflow else { return nil }
        let expected = try first.time.adding(RationalTime(numerator: total, denominator: rate))
        let error = try packet.time.subtracting(expected)
        guard error <= tolerance, try error.adding(tolerance) >= .zero else { return nil }
        total = next.partialValue
    }
    return total
}

extension MulticamAudioConversionPlan {
    func verifyExactSound(_ sound: AudioIndex, origin: RationalTime) throws {
        guard let encoding = exactEncoding else { return }
        let rate = Int64(sampleRate)
        let samples = try edit.duration.roundedToSamples(sampleRate)
        let start = try origin.adding(sound.start)
        let end = try origin.adding(sound.end)
        let stream = sound.stream
        let codedSamples = try continuousLosslessSamples(sound)
        guard stream.codec == encoding.codec, stream.sampleRate == sampleRate, stream.channels == channels,
              writtenLayout(stream, matches: layout, in: edit.container),
              AudioExportEngine.declaredDepth(stream).map({ $0 == encoding.bitDepth }) ?? true,
              start == .zero, end == RationalTime(numerator: samples, denominator: rate),
              !sound.hasPriming, sound.pcmGaps.isEmpty,
              stream.isPCM || codedSamples == samples else {
            throw CutError(code: "audio_conversion_failed",
                           message: "The output track changed the planned codec, precision, channel order, or audible samples.",
                           track: stream.index)
        }
    }
}

/// Output boundaries are rounded cumulatively. Keep the closest source boundaries that provide
/// that many whole samples. An exact boundary stays fixed. Equal errors keep the source start.
func samplePreservingRange(from: RationalTime, to: RationalTime, count: Int64, available: Range<Int64>,
                            rate: Int) throws -> (range: Range<Int64>, rounded: Bool) {
    let first = try from.roundedToSamples(rate)
    let last = try to.roundedToSamples(rate)
    func time(_ sample: Int64) -> RationalTime {
        RationalTime(numerator: sample, denominator: Int64(rate))
    }
    let exactStart = time(first) == from
    let exactEnd = time(last) == to
    if last - first == count {
        return (first..<last, !exactStart || !exactEnd)
    }

    let keepStart = first.addingReportingOverflow(count)
    let keepEnd = last.subtractingReportingOverflow(count)
    let left = !exactEnd && !keepStart.overflow && keepStart.partialValue <= available.upperBound
    let right = !exactStart && !keepEnd.overflow && keepEnd.partialValue >= available.lowerBound
    if left && right {
        let end = time(keepStart.partialValue)
        let start = time(keepEnd.partialValue)
        let leftError = try max(end, to).subtracting(min(end, to))
        let rightError = try max(start, from).subtracting(min(start, from))
        if leftError <= rightError { return (first..<keepStart.partialValue, true) }
        return (keepEnd.partialValue..<last, true)
    }
    if left { return (first..<keepStart.partialValue, true) }
    if right { return (keepEnd.partialValue..<last, true) }
    throw CutError(code: "unsupported_audio",
                   message: "The audio cuts need a different number of samples. Move a cut to a whole audio sample boundary.")
}
