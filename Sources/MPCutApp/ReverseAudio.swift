import AVFoundation
import MPCutCore

/// Keep every queued block on one stereo clock, including through silent gaps and edits.
struct ReverseAudioTimeline {
    static let rate = 48_000
    struct Region {
        let url: URL
        let output: Range<Int64>
        let source: Range<Double>
        let origin: RationalTime?
        let track: Int?
        let presentationTrackID: CMPersistentTrackID?
    }

    let regions: [Region]
    let composition: AVAsset?

    init(ranges: [PreviewRange], offsets: [Double], composition: AVAsset?) {
        let starts = offsets.map(Self.frame)
        regions = ranges.enumerated().map { index, range in
            let start = starts[index]
            let end = index + 1 < starts.count
                ? starts[index + 1] : Self.frame(offsets[index] + (range.end - range.start))
            return Region(url: range.url, output: start..<end, source: range.start..<range.end,
                          origin: range.audioOrigin, track: range.audioTrack, presentationTrackID: nil)
        }
        self.composition = composition
    }

    init(regions: [Region]) {
        self.regions = regions
        composition = nil
    }

    static func frame(_ seconds: Double) -> Int64 {
        Int64((seconds * Double(rate)).rounded())
    }
}

extension ScrubAudioReader {
    /// Input boundaries are absolute timeline samples. Assemble at normal speed so an
    /// edit inside a high-speed output sample neither drops nor duplicates source time.
    func reverseBlock(_ timeline: ReverseAudioTimeline, from lower: Int64, to upper: Int64, speed: Int) -> [Float] {
        let count = Int(upper - lower)
        var forward = [Float](repeating: 0, count: count * 2)
        func copy(_ grain: ScrubGrain?, to offset: Int, count: Int) {
            guard let grain, !grain.stereo.isEmpty else { return }
            let sourceFrames = grain.stereo.count / 2
            if grain.rate == Double(ReverseAudioTimeline.rate) {
                let length = min(count, sourceFrames) * 2
                forward.replaceSubrange(offset * 2..<(offset * 2 + length), with: grain.stereo.prefix(length))
                return
            }
            let ratio = grain.rate / Double(ReverseAudioTimeline.rate)
            for i in 0..<count {
                let point = min(Double(sourceFrames - 1), max(0, (Double(i) + 0.5) * ratio - 0.5))
                let a = Int(point), b = min(a + 1, sourceFrames - 1)
                let fraction = Float(point - Double(a))
                for channel in 0..<2 {
                    let first = grain.stereo[a * 2 + channel]
                    forward[(i + offset) * 2 + channel] = first + fraction * (grain.stereo[b * 2 + channel] - first)
                }
            }
        }

        let rate = Double(ReverseAudioTimeline.rate)
        if let composition = timeline.composition, let first = timeline.regions.first {
            let window = Double(lower) / rate..<Double(upper) / rate
            // The native composition already maps all edits and mixes the linked tracks.
            copy(read(source: first.url, composition: composition, window: window,
                      reverse: false, fadeEdges: false), to: 0, count: count)
        } else {
            var index = timeline.regions.lowerBound { $0.output.upperBound > lower }
            while index < timeline.regions.count, !Task.isCancelled {
                let region = timeline.regions[index]
                let start = max(lower, region.output.lowerBound)
                let end = min(upper, region.output.upperBound)
                if start >= upper { break }
                if end > start {
                    let sourceStart = region.source.lowerBound + Double(start - region.output.lowerBound) / rate
                    let sourceEnd = min(region.source.upperBound,
                                        region.source.lowerBound + Double(end - region.output.lowerBound) / rate)
                    if sourceEnd > sourceStart {
                        let grain = read(source: region.url, composition: nil, window: sourceStart..<sourceEnd,
                                         reverse: false, fadeEdges: false, audioOrigin: region.origin,
                                         audioTrack: region.track, presentationTrackID: region.presentationTrackID)
                        copy(grain, to: Int(start - lower), count: Int(end - start))
                    }
                }
                index += 1
            }
        }

        // At shuttle speeds, average each consecutive group before decimation. There is
        // no envelope between neighboring buffers, so sustained sounds remain continuous.
        var output = [Float]()
        output.reserveCapacity(((count + speed - 1) / speed) * 2)
        var end = count
        while end > 0 {
            let start = max(0, end - speed)
            var left: Float = 0, right: Float = 0
            for i in start..<end {
                left += forward[i * 2]
                right += forward[i * 2 + 1]
            }
            let scale = 1 / Float(end - start)
            output.append(left * scale)
            output.append(right * scale)
            end = start
        }
        return output
    }
}

@MainActor
final class ReverseAudioPlayer {
    private let reader = ScrubAudioReader()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(ReverseAudioTimeline.rate), channels: 2)!
    private var engine: AVAudioEngine?
    private var timeline: ReverseAudioTimeline?
    private var task: Task<Void, Never>?
    private var generation = 0
    private static let blockFrames: Int64 = Int64(ReverseAudioTimeline.rate / 10)
    private var scheduled: Int64 = 0
    private var manualStart: Int64 = 0
    private var tailPlayed = false
    private var speed = 1
    private var origin: Int64 = 0
    private var cursor: Int64 = 0
    private var playedBeforeRestart: Int64 = 0
    var gain: Float = 1 { didSet { node.volume = gain } }

    init(engine: AVAudioEngine? = nil) {
        if let engine { connect(engine) }
    }

    private func connect(_ engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    private var rendered: Int64 {
        guard node.isPlaying, let engine else { return playedBeforeRestart }
        if engine.isInManualRenderingMode {
            return playedBeforeRestart + max(0, engine.manualRenderingSampleTime - manualStart)
        }
        guard let renderTime = node.lastRenderTime, renderTime.isSampleTimeValid,
              let player = node.playerTime(forNodeTime: renderTime), player.isSampleTimeValid else {
            return playedBeforeRestart
        }
        return playedBeforeRestart + max(0, player.sampleTime)
    }

    /// Media time follows rendered samples, including while the first blocks prime.
    var position: Double? {
        guard timeline != nil else { return nil }
        let played = rendered
        if origin == 0 { return 0 }
        if cursor == 0 && (engine?.isInManualRenderingMode == true ? played >= scheduled : tailPlayed) { return 0 }
        return Double(max(max(1, cursor), origin - min(played, scheduled) * Int64(speed))) / Double(ReverseAudioTimeline.rate)
    }

    func tick() {
        guard timeline != nil else { return }
        if let engine, !engine.isRunning, scheduled >= 2 * Self.blockFrames || (cursor == 0 && scheduled > 0) {
            stop()
            return
        }
        guard cursor > 0 else { return }
        if node.isPlaying && rendered >= scheduled {
            // A slow read exhausted the queue. Hold the picture at the last rendered
            // sample and prime the node again when the next block becomes available.
            node.stop()
            playedBeforeRestart = scheduled
        }
        fill()
    }

    func start(_ timeline: ReverseAudioTimeline, at position: Double, speed: Int) {
        stop()
        self.timeline = timeline
        self.speed = speed
        origin = ReverseAudioTimeline.frame(position)
        cursor = origin
        fill()
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        timeline = nil
        scheduled = 0
        tailPlayed = false
        playedBeforeRestart = 0
        if let engine {
            node.stop()
            engine.pause()
        }
    }

    private func fill() {
        guard task == nil, let timeline, needsBlock else { return }
        let token = generation
        let reader = reader
        let speed = speed
        task = Task { [weak self] in
            while let upper = self?.cursor, self?.generation == token, self?.needsBlock == true {
                // A tenth of a second of output per block, at most 400 ms queued.
                let lower = max(0, upper - Self.blockFrames * Int64(speed))
                let samples = await reader.reverseBlock(timeline, from: lower, to: upper, speed: speed)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.cursor = lower
                self.enqueue(samples, generation: token)
            }
            if self?.generation == token { self?.task = nil }
        }
    }

    private var needsBlock: Bool {
        cursor > 0 && scheduled - rendered < 4 * Self.blockFrames
    }

    private func enqueue(_ samples: [Float], generation token: Int) {
        if engine == nil { connect(AVAudioEngine()) }
        guard let engine, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2)),
              let channels = buffer.floatChannelData else { stop(); return }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            channels[0][i] = samples[i * 2]
            channels[1][i] = samples[i * 2 + 1]
        }
        scheduled += Int64(buffer.frameLength)
        if cursor == 0 {
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    if self?.generation == token { self?.tailPlayed = true }
                }
            }
        } else {
            node.scheduleBuffer(buffer)
        }
        if !node.isPlaying && (scheduled - playedBeforeRestart >= 2 * Self.blockFrames || cursor == 0) {
            do {
                if !engine.isRunning { try engine.start() }
                if engine.isInManualRenderingMode { manualStart = engine.manualRenderingSampleTime }
                node.play()
            } catch {
                stop() // The sequence can continue on its host clock without an output device.
            }
        }
    }
}
