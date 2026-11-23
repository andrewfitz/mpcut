import Foundation
import MediaProbe

/// The decoder asks before every packet, some 40 times for each second of AAC, and a job's
/// answer consults its record on disk. Ask the job at most every 10 ms, on one thread.
/// A clock read for every packet shows in a profile of the decode loop, so read it on every 16th call.
private final class TranscriptAudioCancellation {
    private let check: () -> Bool
    private var stopped = false
    private var calls = 0
    private var nextCheck: UInt64 = 0

    init(_ check: @escaping () -> Bool) {
        self.check = check
    }

    var isCancelled: Bool {
        if stopped { return true }
        calls &+= 1
        guard calls & 15 == 1 else { return false }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now >= nextCheck else { return false }
        nextCheck = now + 10_000_000
        stopped = check()
        return stopped
    }
}

private let transcriptAudioCancelled: MPProbeCancelled = { context in
    guard let context else { return 1 }
    return Unmanaged<TranscriptAudioCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
}

/// What the extractor measured while it wrote the staged PCM.
public struct TranscriptAudioExtraction: Sendable {
    /// Linear RMS of each 20 ms window of the written PCM, in order. The last window can be shorter.
    public let levels: [Float]
    /// The source channel written alone because the stream's channels cancel each other in a mono mix.
    public let downmixFallbackChannel: Int?
}

extension CutEngine {
    /// Extracts the chosen absolute stream on the same source clock as the
    /// supplied full index. Sample zero is the start of that clock.
    @discardableResult
    public func extractTranscriptAudio(_ media: MediaInfo, stream: Int, channel: Int? = nil,
                                       to destination: URL, cancelled: @escaping () -> Bool = { Task.isCancelled }) throws
        -> TranscriptAudioExtraction {
        guard media.hasFullEditIndex,
              let audio = media.audio.first(where: { $0.stream.index == stream }),
              audio.stream.sampleRate > 0, audio.stream.channels > 0,
              channel.map({ $0 >= 0 && $0 < audio.stream.channels }) ?? true else {
            throw CutError(code: "invalid_transcript_track", message: "Choose an indexed audio stream and a valid channel.",
                           track: stream)
        }
        func failure(_ message: String) -> CutError {
            CutError(code: "transcript_extraction_failed", message: message, track: stream)
        }
        let source = AnalysisSidecar(media: media)
        guard destination.isFileURL,
              destination.standardizedFileURL.resolvingSymlinksInPath() != media.url.resolvingSymlinksInPath(),
              (try? SourceIdentity(destination)) != media.identity else {
            throw failure("Choose a distinct local destination for the extracted audio.")
        }
        try source.checkSource()
        let duration = max(media.duration, audio.end)
        let length = try duration.roundedToSamples(16_000)
        guard length > 0 else { throw failure("The indexed audio stream has no samples.") }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staged) }
        let cancellation = TranscriptAudioCancellation(cancelled)
        let context = Unmanaged.passUnretained(cancellation).toOpaque()

        func write(channel: Int?) throws -> (levels: [Float], cancelledDownmix: Int?) {
            try withExtendedLifetime(cancellation) {
                guard let pcm = mp_transcript_pcm_open(staged.path, length, Int32(audio.stream.sampleRate),
                                                       Int32(channel ?? -1)) else {
                    throw failure("Could not create the 16 kHz WAV. Check working storage and WAV size.")
                }
                defer { mp_transcript_pcm_close(pcm) }
                mp_transcript_pcm_set_cancel(pcm, transcriptAudioCancelled, context)
                if audio.presentationEdits.isEmpty {
                    var error = [CChar](repeating: 0, count: 512)
                    let status = mp_transcript_decode(pcm, media.url.path, Int32(stream), media.origin.seconds,
                                                      duration.seconds, transcriptAudioCancelled,
                                                      context, &error, error.count)
                    if cancelled() { throw CancellationError() }
                    guard status >= 0 else { throw failure(String(cString: error)) }
                } else {
                    try visitPresentedAudio(audio, media: media, window: nil, duration: duration,
                                            cancelled: { cancellation.isCancelled },
                                            samples: { samples, frames, channels, rate, start in
                        let result = mp_transcript_pcm_float(pcm, samples, frames, channels, rate, start)
                        if cancellation.isCancelled { throw CancellationError() }
                        guard result >= 0 else { throw failure("Could not convert the presented PCM.") }
                    }, silence: { _, _ in })
                }
                let status = mp_transcript_pcm_finish(pcm, transcriptAudioCancelled, context)
                if cancelled() { throw CancellationError() }
                guard status >= 0 else { throw failure("Could not finish the staged WAV.") }
                var count: Int64 = 0
                let levels = mp_transcript_pcm_levels(pcm, &count)
                let strongest = mp_transcript_pcm_cancelled_downmix(pcm)
                return (Array(UnsafeBufferPointer(start: levels, count: Int(count))),
                        strongest >= 0 ? Int(strongest) : nil)
            }
        }

        var written = try write(channel: channel)
        var fallback: Int?
        if channel == nil, let strongest = written.cancelledDownmix {
            // A balanced signal wired across a stereo pair carries one channel inverted. Averaged,
            // the two leave silence, which a recognizer reports as a recording without speech.
            written = try write(channel: strongest)
            fallback = strongest
        }

        try source.checkSource()
        if cancelled() { throw CancellationError() }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        return TranscriptAudioExtraction(levels: written.levels, downmixFallbackChannel: fallback)
    }
}

/// Writes the provider's level document: one frame for each 20 ms window of the staged PCM.
/// The bytes equal `JSONEncoder` output with sorted keys for the same values. A three-hour
/// track holds 540,000 frames, which the general encoder builds as that many keyed containers.
func transcriptActivityDocument(levels: [Float], duration: Int64, evidence: String,
                                cancelled: () -> Bool = { Task.isCancelled }) throws -> Data {
    let window: Int64 = 320
    guard duration > 0, Int64(levels.count) == (duration - 1) / window + 1 else {
        throw jobError("transcript_activity_failed", "The measured levels do not cover the staged PCM.")
    }
    var text = [UInt8]()
    text.reserveCapacity(levels.count * 64 + 256)
    func append(_ string: String) { text.append(contentsOf: string.utf8) }
    append("{\"activity\":[")
    var start: Int64 = 0
    for (index, level) in levels.enumerated() {
        if index.isMultiple(of: 1024), cancelled() { throw CancellationError() }
        guard level.isFinite else {
            throw jobError("transcript_activity_failed", "The staged PCM contains an invalid audio level.")
        }
        let end = start + min(duration - start, window)
        if index > 0 { text.append(UInt8(ascii: ",")) }
        append("{\"end_sample\":")
        append(String(end))
        append(",\"level\":")
        // The encoder writes the shortest text that reads back as the same value, without a fraction for an integer.
        let value = level.description
        append(value.hasSuffix(".0") ? String(value.dropLast(2)) : value)
        append(",\"start_sample\":")
        append(String(start))
        text.append(UInt8(ascii: "}"))
        start = end
    }
    append("],\"duration_samples\":")
    append(String(duration))
    append(",\"sample_rate\":16000,\"stream_evidence\":")
    text.append(contentsOf: try encodeJob(evidence))
    append(",\"version\":1}")
    return Data(text)
}

/// Calculates the provider's 20 ms RMS levels from MPCut's staged PCM.
func measureTranscriptActivity(audio: URL, duration: Int64, evidence: String,
                               cancelled: () -> Bool) throws -> Data {
    let file = try FileHandle(forReadingFrom: audio)
    defer { try? file.close() }
    let length = try file.seekToEnd()
    guard duration > 0, length >= 44, UInt64(duration) <= (length - 44) / 2 else {
        throw jobError("transcript_activity_failed", "The staged PCM ended before its indexed duration.")
    }
    try file.seek(toOffset: 44)
    let window = 320
    let fullPage = Int64(window * 64)
    var cursor: Int64 = 0
    var levels: [Float] = []
    levels.reserveCapacity(Int((duration - 1) / Int64(window) + 1))
    while cursor < duration {
        if cancelled() { throw CancellationError() }
        let samples = Int(min(duration - cursor, fullPage))
        guard let bytes = try file.read(upToCount: samples * 2), bytes.count == samples * 2 else {
            throw jobError("transcript_activity_failed", "The staged PCM ended before its indexed duration.")
        }
        bytes.withUnsafeBytes { buffer in
            for start in stride(from: 0, to: samples, by: window) {
                let end = min(samples, start + window)
                var squared: Float = 0
                for index in start..<end {
                    let pcm = Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    let normalized = Float(pcm) / 32_768
                    squared += normalized * normalized
                }
                levels.append((squared / Float(end - start)).squareRoot())
            }
        }
        cursor += Int64(samples)
    }
    return try transcriptActivityDocument(levels: levels, duration: duration, evidence: evidence, cancelled: cancelled)
}

/// Runs several extractions at once and hands each result to the thread that asked for it.
/// A decode is single-threaded, so the recordings of one job are otherwise staged one after another.
/// The caller keeps every record update, progress report and sidecar write on its own thread.
final class TranscriptExtractionPool<Output>: @unchecked Sendable {
    typealias Work = @Sendable (_ cancelled: @escaping @Sendable () -> Bool) throws -> Output

    private let condition = NSCondition()
    private var work: [Work] = []
    private var next = 0
    private var results: [Int: Result<Output, Error>] = [:]
    private var running = 0
    private var stopped = false
    private let cancelled: @Sendable () -> Bool

    /// `cancelled` is consulted on worker threads, where a task's cancellation is not visible.
    /// `result` watches the caller's own cancellation and stops the workers.
    init(cancelled: @escaping @Sendable () -> Bool) {
        self.cancelled = cancelled
    }

    static var width: Int { min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    /// Queue every extraction before `start`. Returns the ticket for `result`.
    func add(_ item: @escaping Work) -> Int {
        work.append(item)
        return work.count - 1
    }

    func start() {
        let priority = Thread.current.qualityOfService
        for _ in 0..<min(Self.width, work.count) {
            condition.lock()
            running += 1
            condition.unlock()
            let thread = Thread { [self] in
                let stop: @Sendable () -> Bool = { [self] in isStopped || cancelled() }
                while let (ticket, item) = take() {
                    let result = Result { try item(stop) }
                    condition.lock()
                    results[ticket] = result
                    condition.broadcast()
                    condition.unlock()
                }
                condition.lock()
                running -= 1
                condition.broadcast()
                condition.unlock()
            }
            thread.qualityOfService = priority
            thread.stackSize = 2 << 20
            thread.start()
        }
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private func take() -> (Int, Work)? {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, next < work.count else { return nil }
        next += 1
        return (next - 1, work[next - 1])
    }

    /// Waits for one extraction. Throws its error, or `CancellationError` once `cancelled` reports a stop.
    func result(_ ticket: Int, cancelled: () -> Bool) throws -> Output {
        condition.lock()
        defer { condition.unlock() }
        while results[ticket] == nil {
            condition.unlock()
            let stop = cancelled()
            condition.lock()
            if stop {
                stopped = true
                throw CancellationError()
            }
            if results[ticket] == nil { condition.wait(until: Date(timeIntervalSinceNow: 0.05)) }
        }
        return try results[ticket]!.get()
    }

    /// Stops unstarted work, cancels running work and returns when no worker can write again.
    func finish() {
        condition.lock()
        stopped = true
        while running > 0 { condition.wait() }
        condition.unlock()
    }
}
