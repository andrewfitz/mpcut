import AVFoundation
import FFPreview
import MPCutCore

struct MulticamMixedAudioTimeline: Equatable, Sendable {
    struct Lane: Equatable, Sendable {
        let label: String
        let spans: [MulticamPreviewAudioSpan]
    }

    let lanes: [Lane]

    func hasAudio(at lower: RationalTime, before upper: RationalTime) -> Bool {
        guard lower < upper else { return false }
        return lanes.contains { lane in
            let index = lane.spans.lowerBound { $0.output.upperBound > lower }
            return lane.spans.indices.contains(index) && lane.spans[index].output.lowerBound < upper
        }
    }

    func hasAudio(at lower: Double, before upper: Double) -> Bool {
        guard let from = time(lower), let to = time(upper) else { return false }
        return hasAudio(at: from, before: to)
    }

    private func time(_ seconds: Double) -> RationalTime? {
        let rate = Int64(MulticamProgramMixer.sampleRate)
        guard let sample = Int64(exactly: (seconds * Double(rate)).rounded()) else { return nil }
        return RationalTime(numerator: sample, denominator: rate)
    }

    func grain(window: Range<Double>, reverse: Bool, fadeEdges: Bool) -> ScrubGrain? {
        guard let from = time(window.lowerBound), let to = time(window.upperBound),
              hasAudio(at: from, before: to),
              let reader = try? MulticamProgramAudioReader(timeline: self, from: from, to: to) else { return nil }
        var samples: [CMSampleBuffer] = []
        while !Task.isCancelled {
            guard let batch = try? reader.read(cancelled: { Task.isCancelled }) else { return nil }
            samples.append(contentsOf: batch.samples)
            if batch.end { break }
        }
        guard !Task.isCancelled else { return nil }
        return ScrubGrain(samples: samples, window: from.seconds..<to.seconds, reverse: reverse, fadeEdges: fadeEdges)
    }
}

struct MulticamProgramAudioBatch {
    var samples: [CMSampleBuffer] = []
    var end = false
    var issue: String?
}

/// Keeps one forward cursor per lane. The same timestamped mixer also serves short
/// bounded reads for scrub and reverse, including grains that straddle a source edit.
final class MulticamProgramAudioReader {
    private final class LaneReader {
        private let lane: MulticamMixedAudioTimeline.Lane
        private let decoder = MulticamPreviewAudioDecoder(preserveChannels: true)
        private let upperBound: RationalTime?
        private var index: Int
        private let start: RationalTime
        private var prepared: (span: MulticamPreviewAudioSpan, sourceSamples: Int64)?
        private var open = true
        private var discontinuity = true
        private var queued: [CMSampleBuffer] = []
        private var channelLayout = ""
        private var matrixFormat: CMAudioFormatDescription?
        private var matrix: [Double] = []
        var issue: String?

        init(lane: MulticamMixedAudioTimeline.Lane, from start: RationalTime, to upperBound: RationalTime?) {
            self.lane = lane
            self.upperBound = upperBound
            index = lane.spans.lowerBound { $0.output.upperBound > start }
            self.start = start
        }

        func submitNext(to mixer: OpaquePointer, laneIndex: Int32, cancelled: @escaping () -> Bool) {
            guard let input = next(cancelled: cancelled),
                  let prepared, let format = input.formatDescription,
                  let matrix = channelMatrix(for: format) else {
                mp_program_mix_submit(mixer, laneIndex, nil, nil, false, .zero, 0, .zero, .zero)
                return
            }
            let span = prepared.span
            matrix.withUnsafeBufferPointer {
                mp_program_mix_submit(mixer, laneIndex, input, $0.baseAddress, discontinuity, span.timestampTick,
                                      prepared.sourceSamples, previewTime(span.output.lowerBound),
                                      previewTime(span.output.upperBound))
            }
            discontinuity = false
        }

        private func next(cancelled: @escaping () -> Bool) -> CMSampleBuffer? {
            while !cancelled() {
                if !queued.isEmpty { return queued.removeFirst() }
                guard lane.spans.indices.contains(index) else { return nil }
                let stored = lane.spans[index]
                if let upperBound, stored.output.lowerBound >= upperBound { return nil }
                do {
                    if open {
                        prepared = try stored.mixerSlice(from: start, to: upperBound)
                        discontinuity = true
                    }
                    guard let span = prepared?.span else {
                        advance()
                        continue
                    }
                    let batch = try decoder.read(span: span, from: span.input.lowerBound, open: open,
                                                 cancelled: cancelled)
                    if channelLayout != span.channelLayout {
                        channelLayout = span.channelLayout
                        matrixFormat = nil
                    }
                    open = false
                    queued = batch.audio
                    if batch.noAudio { report(MulticamDecodeError.audio(span.url)) }
                    if batch.end { advance() }
                } catch {
                    report(error)
                    advance()
                }
            }
            return nil
        }

        func channelMatrix(for format: CMAudioFormatDescription) -> [Double]? {
            if let matrixFormat, CFEqual(format, matrixFormat) { return matrix }
            guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
            let channels = Int(description.pointee.mChannelsPerFrame)
            let names = (0..<channels).map { channel in
                mp_program_mix_speaker(format, Int32(channel)).map { String(cString: $0) } ?? ""
            }
            let speakers = names.allSatisfy(\.isEmpty)
                ? MulticamProgramMixer.channelNames(layout: channelLayout, channels: channels) ?? names
                : names
            matrix = MulticamProgramMixer.channelWeights(inputChannels: speakers, outputChannels: 2).flatMap { $0 }
            matrixFormat = format
            return matrix
        }

        private func advance() {
            index += 1
            open = true
        }

        private func report(_ error: Error) {
            issue = "\(lane.label): \(error.localizedDescription)"
        }
    }

    private enum Failure: LocalizedError {
        case mix
        var errorDescription: String? { "The program audio mix could not be decoded." }
    }

    private let mixer: OpaquePointer
    private let readers: [LaneReader]
    init(timeline: MulticamMixedAudioTimeline, from start: RationalTime, to end: RationalTime? = nil) throws {
        guard let mixer = mp_program_mix_create(Int32(timeline.lanes.count)) else { throw Failure.mix }
        self.mixer = mixer
        readers = timeline.lanes.map { LaneReader(lane: $0, from: start, to: end) }
    }

    deinit { mp_program_mix_close(mixer) }

    func read(cancelled: @escaping () -> Bool) throws -> MulticamProgramAudioBatch {
        var batch = MulticamProgramAudioBatch()
        while batch.samples.count < 4, !cancelled() {
            var sample: CMSampleBuffer?
            var requested: Int32 = -1
            let result = mp_program_mix_next(mixer, &sample, &requested)
            if result == MPPreviewEnd.rawValue {
                batch.end = true
                break
            }
            if result == MPPreviewError.rawValue { throw Failure.mix }
            if let sample { batch.samples.append(sample) }
            if requested >= 0 {
                let reader = readers[Int(requested)]
                reader.submitNext(to: mixer, laneIndex: requested, cancelled: cancelled)
                batch.issue = batch.issue ?? reader.issue
            }
        }
        return batch
    }
}
