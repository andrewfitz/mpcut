import Foundation

func supportsOpusTrim(_ audio: AudioIndex, media: MediaInfo, container: String) -> Bool {
    guard ["webm", "mkv", "mka"].contains(container), audio.stream.codec == "opus" else { return false }
    let formats = media.format.split(separator: ",")
    return formats.contains("matroska") || formats.contains("ogg")
}

func matroskaAudioCodec(_ audio: AudioIndex, media: MediaInfo) -> String? {
    let format = media.format.split(separator: ",")
    guard format.contains("webm") || format.contains("matroska") else { return nil }
    switch audio.stream.codec {
    case "opus": return "Opus"
    case "vorbis": return "Vorbis"
    default: return nil
    }
}

struct OpusTrimWindow: Sendable {
    let start: Int64
    let firstPacketEnd: Int64
    let end: Int64
    let initialPadding: Int
    let complete: Bool
    let packetStarts: [Int64]

    func preSkip(at sample: Int64) -> Int32? {
        guard start <= sample, sample < end, !packetStarts.isEmpty else { return nil }
        // Retain decoder history before the audible cut. OpusHead has a 16-bit pre-skip.
        // Keep up to a second of decoder history for predictive speech. One extra
        // Opus packet (at most 120 ms) still fits the 16-bit pre-skip field.
        let (target, underflow) = sample.subtractingReportingOverflow(48_000)
        let index = underflow ? 0 : max(0, packetStarts.lowerBound { $0 > target } - 1)
        let (skip, overflow) = sample.subtractingReportingOverflow(packetStarts[index])
        guard !overflow, (0...65_535).contains(skip) else { return nil }
        return Int32(skip)
    }

    func containsEnd(_ sample: Int64) -> Bool {
        start < sample && sample <= end && (initialPadding == 0 || sample >= firstPacketEnd)
    }
}

/* Opus is clocked at 48 kHz. Matroska's default block timestamps are rounded to
 * milliseconds. Track the exact decoded sample count and check it against every
 * block timestamp before qualifying an endpoint. */
func opusTrimWindow(_ audio: AudioIndex, origin: RationalTime, checkCancellation: () throws -> Void = {}) rethrows -> OpusTrimWindow? {
    let stream = audio.stream
    let padding = stream.initialPadding
    let sampleClock = stream.timeBase == RationalTime(numerator: 1, denominator: 48_000)
    guard stream.sampleRate == 48_000, sampleClock || stream.timeBase == RationalTime(numerator: 1, denominator: 1_000),
          padding >= 0, let first = audio.packets.first,
          padding <= 65_535, first.skipSamples == padding, first.decodedSamples > 0,
          let firstPTSSamples = try? origin.adding(first.time).roundedToSamples(48_000) else { return nil }
    let initialOffset = sampleClock ? padding : (padding + 24) / 48 * 48
    let (start, startOverflow) = firstPTSSamples.addingReportingOverflow(Int64(initialOffset))
    guard !startOverflow else { return nil }
    let (decodedStart, decodedOverflow) = start.subtractingReportingOverflow(Int64(padding))
    guard !decodedOverflow else { return nil }

    var expected = decodedStart
    var end = start
    var firstPacketEnd: Int64?
    var packetStarts: [Int64] = []
    for (index, packet) in audio.packets.enumerated() {
        if index.isMultiple(of: 1_024) { try checkCancellation() }
        guard let pts = try? origin.adding(packet.time).roundedToSamples(48_000) else { break }
        let (delta, deltaOverflow) = pts.subtractingReportingOverflow(expected)
        let (next, packetOverflow) = expected.addingReportingOverflow(Int64(packet.decodedSamples))
        let tolerance: Int64 = sampleClock ? 0 : 24
        guard !deltaOverflow, (-tolerance...tolerance).contains(delta), !packetOverflow, packet.dts == packet.time,
              packet.skipSamples == (index == 0 ? padding : 0),
              packet.decodedSamples > packet.discardSamples,
              index > 0 || packet.discardSamples == 0 else { break }
        end = next - Int64(packet.discardSamples)
        packetStarts.append(expected)
        if index == 0 { firstPacketEnd = end }
        if packet.discardSamples != 0 { break }
        expected = next
    }
    guard let firstPacketEnd else { return nil }
    return OpusTrimWindow(start: start, firstPacketEnd: firstPacketEnd, end: end,
                            initialPadding: padding, complete: packetStarts.count == audio.packets.count,
                            packetStarts: packetStarts)
}
