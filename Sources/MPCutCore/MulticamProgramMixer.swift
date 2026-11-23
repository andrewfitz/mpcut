import CFFmpeg
import FFPreview
import Foundation

/// The sample clock, channel matrix and fixed lane weighting used for multicam program audio.
public enum MulticamProgramMixer {
    public static let sampleRate = 48_000

    /// Speaker names use FFmpeg abbreviations (FL, FR, FC and so on).
    public static func channelWeights(inputChannels: [String], outputChannels: Int) -> [[Double]] {
        precondition(outputChannels == 1 || outputChannels == 2)
        let count = inputChannels.count
        if count <= 1 {
            return Array(repeating: Array(repeating: 1, count: count), count: outputChannels)
        }
        if count == 2 && inputChannels == ["FL", "FR"] {
            return outputChannels == 1 ? [[0.5, 0.5]] : [[1, 0], [0, 1]]
        }

        let surround = 1 / sqrt(2.0)
        let stereo = inputChannels.map { name -> (Double, Double) in
            switch name {
            case "FL": return (1, 0)
            case "FR": return (0, 1)
            case "FC": return (surround, surround)
            case "FLC", "BL", "SL", "TFL", "TBL", "TML", "WL", "SDL", "BFL": return (surround, 0)
            case "FRC", "BR", "SR", "TFR", "TBR", "TMR", "WR", "SDR", "BFR": return (0, surround)
            case "LFE", "LFE2": return (0, 0)
            default: return (0.5, 0.5)
            }
        }
        let rows = outputChannels == 1 ? [stereo.map { ($0.0 + $0.1) / 2 }]
                                       : [stereo.map { $0.0 }, stereo.map { $0.1 }]
        return rows.map { row in
            let scale = max(1, row.reduce(0, +))
            return row.map { $0 / scale }
        }
    }

    /// Adds one aligned block of converted PCM to the program block. Missing lanes
    /// contribute zero, and the denominator includes every selected lane.
    static func accumulate(_ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Double>,
                           channels: Int, laneCount: Int) {
        precondition(input.count == output.count && input.count.isMultiple(of: channels))
        guard let inputBase = input.baseAddress, let outputBase = output.baseAddress else { return }
        mp_program_mix_accumulate(inputBase, outputBase, Int32(input.count / channels), Int32(channels),
                                  Int32(channels), nil, Int32(laneCount))
    }

    /// Returns speaker names in interleaved order for a standard FFmpeg layout.
    public static func channelNames(layout: String, channels: Int) -> [String]? {
        var channelLayout = AVChannelLayout()
        defer { av_channel_layout_uninit(&channelLayout) }
        guard channels > 0, let count = Int32(exactly: channels),
              av_channel_layout_from_string(&channelLayout, layout) == 0,
              channelLayout.nb_channels == count else { return nil }
        var names: [String] = []
        for index in 0..<channels {
            let speaker = av_channel_layout_channel_from_index(&channelLayout, UInt32(index))
            var characters = [CChar](repeating: 0, count: 16)
            guard av_channel_name(&characters, characters.count, speaker) >= 0 else { return nil }
            names.append(String(cString: characters))
        }
        return names
    }

    static func panFilter(layout: String, channels: Int, outputChannels: Int) throws -> String {
        guard let names = channelNames(layout: layout, channels: channels) else {
            throw CutError(code: "unsupported_audio", message: "Cannot downmix the selected channel layout.")
        }
        let weights = channelWeights(inputChannels: names, outputChannels: outputChannels)
        let assignments = weights.enumerated().map { channel, row in
            let terms = row.enumerated().map { index, coefficient in "\(coefficient)*c\(index)" }
            return "c\(channel)=" + terms.joined(separator: "+")
        }
        return "aformat=sample_fmts=flt,pan=\(outputChannels == 1 ? "mono" : "stereo")|" + assignments.joined(separator: "|") + ","
    }
}
