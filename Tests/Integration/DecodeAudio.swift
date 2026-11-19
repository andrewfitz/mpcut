import AVFoundation
import Foundation

@main
struct DecodeAudio {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let length = CMBlockBufferGetDataLength(buffer)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length,
                                                  destination: base)
            }
            guard status == kCMBlockBufferNoErr else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        guard reader.status == .completed else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
    }
}
