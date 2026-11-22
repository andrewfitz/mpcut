import AVFoundation
import MPCutCore

struct ScrubAudioRequest {
    let source: URL
    let composition: AVAsset?
    let audioOrigin: RationalTime?
    let audioTrack: Int?
    let presentationTrackID: CMPersistentTrackID?
    let window: Range<Double>
    let reverse: Bool

    init?(source: URL, composition: AVAsset?, position: Double, bounds: Range<Double>, reverse: Bool,
          audioOrigin: RationalTime? = nil, audioTrack: Int? = nil,
          presentationTrackID: CMPersistentTrackID? = nil) {
        guard bounds.lowerBound < bounds.upperBound else { return nil }
        self.source = source
        self.audioOrigin = audioOrigin
        self.audioTrack = audioTrack
        self.presentationTrackID = presentationTrackID
        self.composition = composition
        self.reverse = reverse
        let point = min(max(position, bounds.lowerBound), bounds.upperBound)
        if (reverse && point > bounds.lowerBound) || point == bounds.upperBound {
            window = max(bounds.lowerBound, point - 0.065)..<point
        } else {
            window = point..<min(bounds.upperBound, point + 0.065)
        }
    }
}

// Each grain contains only the selected clip's sound. Gaps stay silent and the
// short envelope avoids a click when playing discontinuous samples.
struct ScrubGrain {
    let rate: Double
    var stereo: [Float]

    init?(samples: [CMSampleBuffer], window: Range<Double>, reverse: Bool, fadeEdges: Bool = true) {
        guard let format = samples.first?.formatDescription,
              let first = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              first.mSampleRate > 0, first.mSampleRate <= 768_000 else { return nil }
        rate = first.mSampleRate
        let count = Int(((window.upperBound - window.lowerBound) * rate).rounded())
        guard count > 0, count <= Int(rate) else { return nil }
        stereo = Array(repeating: 0, count: count * 2)
        var copied = false
        for sample in samples {
            guard let format = sample.formatDescription,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate == rate, asbd.mChannelsPerFrame == 2, asbd.mBytesPerFrame == 8,
                  asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let data = sample.dataBuffer else { continue }
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite, abs(pts - window.lowerBound) < 10 else { continue }
            let offset = Int(((pts - window.lowerBound) * rate).rounded())
            let start = max(0, -offset)
            let end = min(sample.numSamples, count - offset)
            guard start < end else { continue }
            let status = stereo.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: start * 8, dataLength: (end - start) * 8,
                                           destination: $0.baseAddress!.advanced(by: (start + offset) * 8))
            }
            if status == noErr { copied = true }
        }
        guard copied else { return nil }
        if reverse {
            for i in 0..<(count / 2) {
                let j = count - i - 1
                stereo.swapAt(i * 2, j * 2)
                stereo.swapAt(i * 2 + 1, j * 2 + 1)
            }
        }
        guard fadeEdges else { return }
        let ramp = max(1, Int(rate * 0.003))
        for i in 0..<min(count, ramp) {
            let gain = Float(i) / Float(ramp)
            stereo[2 * i] *= gain
            stereo[2 * i + 1] *= gain
            let j = count - i - 1
            stereo[2 * j] *= gain
            stereo[2 * j + 1] *= gain
        }
    }
}

actor ScrubAudioReader {
    private let fallback = FFPreviewReader(audioOnly: true)

    func grain(_ request: ScrubAudioRequest) -> ScrubGrain? {
        read(source: request.source, composition: request.composition, window: request.window,
             reverse: request.reverse, fadeEdges: true, audioOrigin: request.audioOrigin, audioTrack: request.audioTrack,
             presentationTrackID: request.presentationTrackID)
    }

    func read(source: URL, composition: AVAsset?, window: Range<Double>, reverse: Bool, fadeEdges: Bool,
              audioOrigin: RationalTime? = nil, audioTrack: Int? = nil,
              presentationTrackID: CMPersistentTrackID? = nil) -> ScrubGrain? {
        guard !Task.isCancelled else { return nil }
        let samples: [CMSampleBuffer]
        if composition != nil || presentationTrackID != nil {
            let asset = composition ?? AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let origin: CMTime
            let tracks: [AVAssetTrack]
            if let presentationTrackID {
                guard let track = asset.track(withTrackID: presentationTrackID), track.mediaType == .audio else { return nil }
                tracks = [track]
                origin = audioOrigin.map(previewTime) ?? .zero
            } else {
                tracks = asset.tracks(withMediaType: .audio)
                origin = .zero
            }
            guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: origin + CMTime(seconds: window.lowerBound, preferredTimescale: 1_000_000_000),
                                           end: origin + CMTime(seconds: window.upperBound, preferredTimescale: 1_000_000_000))
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            var buffers: [CMSampleBuffer] = []
            while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
                if origin == .zero {
                    buffers.append(sample)
                } else if let mapped = FFPreviewReader.timelineAudio(sample, target: window.lowerBound + origin.seconds,
                                                                   end: window.upperBound + origin.seconds,
                                                                   offset: .zero - origin) {
                    buffers.append(mapped)
                }
            }
            samples = buffers
        } else {
            samples = (try? fallback.perform(cancelled: { Task.isCancelled }) {
                try fallback.scrubSamples(url: source, range: window, audioOrigin: audioOrigin, audioTrack: audioTrack)
            }) ?? []
        }
        guard !Task.isCancelled else { return nil }
        return ScrubGrain(samples: samples, window: window, reverse: reverse, fadeEdges: fadeEdges)
    }
}

@MainActor
final class ScrubAudioPlayer {
    private let reader = ScrubAudioReader()
    private let node = AVAudioPlayerNode()
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var task: Task<Void, Never>?
    private var pending: ScrubAudioRequest?
    var gain: Float = 1

    init(engine: AVAudioEngine? = nil) {
        self.engine = engine
        engine?.attach(node)
    }

    func submit(_ request: ScrubAudioRequest) {
        pending = request
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, let next = self.pending, !Task.isCancelled {
                self.pending = nil
                let grain = await self.reader.grain(next)
                guard !Task.isCancelled else { return }
                if let grain, self.pending.map({ $0.source == next.source && $0.reverse == next.reverse }) ?? true {
                    self.play(grain)
                    try? await Task.sleep(for: .milliseconds(55))
                }
            }
            if !Task.isCancelled { self?.task = nil }
        }
    }

    func stop() {
        pending = nil
        task?.cancel()
        task = nil
        if let engine {
            node.stop()
            engine.pause()
        }
    }

    func play(_ grain: ScrubGrain) {
        if engine == nil {
            let engine = AVAudioEngine()
            engine.attach(node)
            self.engine = engine
        }
        guard let engine else { return }
        if format?.sampleRate != grain.rate {
            node.stop()
            engine.stop()
            format = AVAudioFormat(standardFormatWithSampleRate: grain.rate, channels: 2)
            guard let format else { return }
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        let frames = grain.stereo.count / 2
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<frames {
            channels[0][i] = grain.stereo[2 * i] * gain
            channels[1][i] = grain.stereo[2 * i + 1] * gain
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }
}
