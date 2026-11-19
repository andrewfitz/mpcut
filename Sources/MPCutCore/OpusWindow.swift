import Foundation

func supportsOpusPrefix(_ audio: AudioIndex, media: MediaInfo, container: String) -> Bool {
    (container == "webm" || container == "mkv") && matroskaAudioCodec(audio, media: media) == "Opus"
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

struct OpusPrefixWindow {
    let start: Int64
    let firstPacketEnd: Int64
    let end: Int64
    let initialPadding: Int
    let complete: Bool

    func containsEnd(_ sample: Int64) -> Bool {
        start < sample && sample <= end && (initialPadding == 0 || sample >= firstPacketEnd)
    }
}

/* Opus is clocked at 48 kHz. Matroska's default block timestamps are rounded to
 * milliseconds. Track the exact decoded sample count and check it against every
 * block timestamp before qualifying an endpoint. */
func opusPrefixWindow(_ audio: AudioIndex, origin: RationalTime) -> OpusPrefixWindow? {
    let stream = audio.stream
    let padding = stream.initialPadding
    guard stream.sampleRate == 48_000, stream.timeBase == RationalTime(numerator: 1, denominator: 1_000),
          padding >= 0, let first = audio.packets.first,
          first.skipSamples == padding, first.decodedSamples > padding,
          let firstPTSSamples = try? origin.adding(first.time).roundedToSamples(48_000) else { return nil }
    let (start, startOverflow) = firstPTSSamples.addingReportingOverflow(Int64((padding + 24) / 48 * 48))
    guard !startOverflow else { return nil }
    let (decodedStart, decodedOverflow) = start.subtractingReportingOverflow(Int64(padding))
    guard !decodedOverflow else { return nil }

    var expected = decodedStart
    var end = start
    var firstPacketEnd: Int64?
    var packetCount = 0
    for (index, packet) in audio.packets.enumerated() {
        guard let pts = try? origin.adding(packet.time).roundedToSamples(48_000) else { break }
        let (delta, deltaOverflow) = pts.subtractingReportingOverflow(expected)
        let (next, packetOverflow) = expected.addingReportingOverflow(Int64(packet.decodedSamples))
        guard !deltaOverflow, (-24...24).contains(delta), !packetOverflow, packet.dts == packet.time,
              packet.skipSamples == (index == 0 ? padding : 0),
              packet.decodedSamples > packet.skipSamples + packet.discardSamples,
              index > 0 || packet.discardSamples == 0 else { break }
        end = next - Int64(packet.discardSamples)
        packetCount += 1
        if index == 0 { firstPacketEnd = end }
        if packet.discardSamples != 0 { break }
        expected = next
    }
    guard let firstPacketEnd else { return nil }
    return OpusPrefixWindow(start: start, firstPacketEnd: firstPacketEnd, end: end,
                            initialPadding: padding, complete: packetCount == audio.packets.count)
}
