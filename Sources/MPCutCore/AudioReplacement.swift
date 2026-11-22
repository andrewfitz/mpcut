import AVFoundation
import Darwin
import Foundation
import PacketWriter

private struct CopiedAACEdits: Sendable {
    let source: URL
    let sourceTrackID: Int32
    let sampleRate: Int32
    let sourceStream: Int
    let destinationStream: Int
    let shift: RationalTime
}

/// A whole-recording stream substitution. Times are in the source presentation clock.
public struct AudioReplacementPlan: Encodable, Sendable {
    public let source: URL
    public let replacement: URL
    public let targetStream: Int
    public let replacementStream: Int
    public let replacementCodec: String
    public let container: String
    public let duration: RationalTime

    package let sourceIdentity: SourceIdentity
    fileprivate let replacementIdentity: SourceIdentity
    fileprivate let origin: RationalTime
    fileprivate let streams: [StreamInfo]
    fileprivate let targetOutputStream: Int
    fileprivate let audioBounds: [Int: ClosedRange<RationalTime>]
    fileprivate let replacementFormat: StreamInfo
    fileprivate let editLists: [CopiedAACEdits]
    fileprivate let priming: Int64?
    fileprivate let targetStart: RationalTime
    fileprivate let targetEnd: RationalTime
    fileprivate let offsetMicroseconds: Int64
    fileprivate let helper: URL

    package var targetAudioOrdinal: Int {
        streams.prefix(targetOutputStream).filter { $0.kind == "audio" }.count
    }

    private enum CodingKeys: String, CodingKey {
        case source, replacement, targetStream, replacementStream, replacementCodec, container, duration
    }

    fileprivate var muxer: String {
        switch container {
        case "m4a": return "ipod"
        case "mka": return "matroska"
        default: return muxerName(container)
        }
    }

    fileprivate var arguments: [String] {
        var values = ["-xerror", "-copyts", "-copy_unknown", "-i", source.path,
                      "-itsoffset", "\(offsetMicroseconds)us", "-i", replacement.path]
        // A raw MOV demux preserves the media referenced by every edit, including
        // preroll and reused access units. One extra input suffices for all tracks of a file.
        var rawInputs = [URL: Int]()
        for item in editLists where rawInputs[item.source] == nil {
            rawInputs[item.source] = 2 + rawInputs.count
            values += ["-ignore_editlist", "1", "-i", item.source.path]
        }
        let rawStreams = Dictionary(uniqueKeysWithValues: editLists.map {
            ($0.destinationStream, "\(rawInputs[$0.source]!):\($0.sourceStream)")
        })
        for (index, stream) in streams.enumerated() {
            let input = stream.index == targetStream ? "1:\(replacementStream)" : "0:\(stream.index)"
            values += ["-map", rawStreams[index] ?? input]
        }
        values += ["-map_metadata", "0", "-map_chapters", "0", "-c", "copy", "-copyinkf",
                   "-avoid_negative_ts", "disabled"]
        // ffmpeg otherwise synthesizes a default disposition when no stream has one.
        for (index, stream) in streams.enumerated() {
            values += ["-map_metadata:s:\(index)", "0:s:\(stream.index)",
                       "-disposition:\(index)", String(stream.disposition)]
        }
        if ["mov", "mp4", "m4a"].contains(container) {
            values += ["-movie_timescale", "1000000"]
        }
        return values
    }
}

public struct AudioReplacementEngine: Sendable {
    private let cancelled: (@Sendable () -> Bool)?
    private let useSidecar: Bool

    public init(cancelled: (@Sendable () -> Bool)? = nil, useSidecar: Bool = true) {
        self.cancelled = cancelled
        self.useSidecar = useSidecar
    }

    public func resolve(source: URL, replacement: URL, output: URL? = nil, container: String? = nil,
                        targetStream: Int? = nil, replacementStream: Int? = nil) throws -> AudioReplacementPlan {
        try resolve(source: source, replacement: replacement, output: output, container: container,
                    targetStream: targetStream, replacementStream: replacementStream,
                    sourceIdentity: nil, replacementIdentity: nil)
    }

    package func resolve(source: MediaInfo, replacement: MediaInfo, container: String?,
                         targetStream: Int, replacementStream: Int) throws -> AudioReplacementPlan {
        try resolve(source: source.url, replacement: replacement.url, output: nil, container: container,
                    targetStream: targetStream, replacementStream: replacementStream,
                    sourceIdentity: source.identity, replacementIdentity: replacement.identity)
    }

    package func resolve(source: MediaInfo, replacement: URL, output: URL,
                         targetStream: Int?, replacementStream: Int?) throws -> AudioReplacementPlan {
        try resolve(source: source.url, replacement: replacement, output: output, container: nil,
                    targetStream: targetStream, replacementStream: replacementStream,
                    sourceIdentity: source.identity, replacementIdentity: nil)
    }

    private func resolve(source: URL, replacement: URL, output: URL?, container: String?,
                         targetStream: Int?, replacementStream: Int?, sourceIdentity: SourceIdentity?,
                         replacementIdentity: SourceIdentity?) throws -> AudioReplacementPlan {
        let inspector = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
        if let sourceIdentity { try inspector.verifyIdentity(source, identity: sourceIdentity) }
        if let replacementIdentity { try inspector.verifyIdentity(replacement, identity: replacementIdentity) }
        let movie = try inspector.inspect(source, keyframes: false, expectedIdentity: sourceIdentity)
        let incoming = try inspector.inspect(replacement, keyframes: false, expectedIdentity: replacementIdentity)
        let target = try audio(in: movie, index: targetStream)
        let track = try audio(in: incoming, index: replacementStream)
        if let issue = movie.timelineIssue, issue != "Multiple video tracks are unsupported." {
            throw CutError(code: "unsupported_tracks", message: issue)
        }
        guard !movie.streams.contains(where: { $0.multipleDescriptions }) else {
            throw CutError(code: "unsupported_tracks", message: "The picture changes sample descriptions within this recording.")
        }
        let incomingBounds = try audibleBounds(of: track, in: incoming)
        let incomingLength = try incomingBounds.upperBound.subtracting(incomingBounds.lowerBound)
        let tolerance = Self.tolerance(target.stream, track.stream)
        var targetBounds = try audibleBounds(of: target, in: movie)
        var targetLength = try targetBounds.upperBound.subtracting(targetBounds.lowerBound)
        // Audio workstations may export either the isolated track or its full MOV edit,
        // including leading empty time. Align the beginning of the corresponding span.
        if abs(incomingLength.seconds - targetLength.seconds) > tolerance,
           abs(incomingLength.seconds - (target.end.seconds - target.start.seconds)) <= tolerance {
            targetBounds = target.start...target.end
            targetLength = try target.end.subtracting(target.start)
        }
        guard targetLength > .zero, incomingLength > .zero else {
            throw CutError(code: "unsupported_tracks", message: "Both selected audio tracks need a measurable presentation duration.")
        }
        guard abs(targetLength.seconds - incomingLength.seconds) <= tolerance else {
            throw CutError(code: "duration_mismatch",
                           message: "Replacement audio lasts \(incomingLength)s. Original track \(target.stream.index) lasts \(targetLength)s.",
                           track: target.stream.index)
        }
        let offset = try movie.origin.adding(targetBounds.lowerBound).subtracting(incoming.origin.adding(incomingBounds.lowerBound))
        let start = try movie.origin.adding(targetBounds.lowerBound)
        let end = try start.adding(incomingLength)
        if track.stream.codec == "mp3", let first = track.packets.first, first.skipSamples > 0,
           try incoming.origin.adding(first.time).adding(offset) > .zero {
            throw CutError(code: "unsupported_tracks",
                           message: "A delayed MP3 replacement cannot preserve its encoder delay in the movie. Use a different audio render format.",
                           track: track.stream.index)
        }
        let chapterCarriers = Self.chapterCarriers(in: movie)
        guard chapterCarriers.count <= 1 else {
            throw CutError(code: "unsupported_tracks", message: "Multiple chapter list tracks cannot be preserved during audio replacement.")
        }
        // The muxer regenerates the linked chapter text track from -map_chapters.
        // Mapping it directly as binary data fails even for a MOV-to-MOV copy.
        let streams = movie.streams.filter { !chapterCarriers.contains($0.trackID) }
        let outputIndexes = Dictionary(uniqueKeysWithValues: streams.enumerated().map { ($0.element.index, $0.offset) })
        guard let targetOutputStream = outputIndexes[target.stream.index] else {
            throw CutError(code: "unsupported_tracks", message: "The selected audio stream is a chapter list track.")
        }
        var editLists = movie.audio.compactMap { audio -> CopiedAACEdits? in
            guard audio.stream.index != target.stream.index, !audio.presentationEdits.isEmpty,
                  let outputIndex = outputIndexes[audio.stream.index] else { return nil }
            return CopiedAACEdits(source: movie.url, sourceTrackID: audio.stream.trackID, sampleRate: Int32(audio.stream.sampleRate),
                                  sourceStream: audio.stream.index,
                                  destinationStream: outputIndex, shift: .zero)
        }
        if !track.presentationEdits.isEmpty {
            editLists.append(CopiedAACEdits(source: incoming.url, sourceTrackID: track.stream.trackID, sampleRate: Int32(track.stream.sampleRate),
                                            sourceStream: track.stream.index, destinationStream: targetOutputStream, shift: offset))
        }
        var audioBounds = try Dictionary(uniqueKeysWithValues: movie.audio.map { ($0.stream.index, try audibleBounds(of: $0, in: movie)) })
        audioBounds[target.stream.index] = targetBounds
        let formats = ExportRules.replacementContainers(hasVideo: movie.hasVideo)
        let explicit = container?.lowercased() ?? output.flatMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension.lowercased() }
        if let explicit, !formats.contains(explicit) {
            throw ExportRules.replacementContainerRefusal(hasVideo: movie.hasVideo)
        }
        let candidates = explicit.map { [$0] } ?? ([source.pathExtension.lowercased()] + formats)
        let process = ReencodeEngine(cancelled: cancelled)
        let helper = try ReencodeEngine.findHelper(override: nil)
        var tried = Set<String>()
        var failure: CutError?
        for format in candidates where formats.contains(format) && tried.insert(format).inserted {
            if let output { try process.checkDestination(output, container: format) }
            if !editLists.isEmpty && !["mov", "mp4", "m4a"].contains(format) {
                failure = CutError(code: "unsupported_container",
                                   message: "Choose \(movie.hasVideo ? "MOV or MP4" : "MOV, MP4 or M4A") to preserve the audio presentation edit list.")
                continue
            }
            // Matroska's PCM tracks store the channel count without a speaker mask.
            // The muxer accepts these streams but the output loses any named surround layout.
            if ["mka", "mkv"].contains(format), let namedPCM = streams.first(where: { stream in
                let format = stream.index == target.stream.index ? track.stream : stream
                return format.kind == "audio" && format.codec.hasPrefix("pcm_") && format.channels > 2
                    && !format.channelLayout.isEmpty && format.channelLayout != "\(format.channels) channels"
            }) {
                failure = CutError(code: "unsupported_container",
                                   message: "Matroska cannot preserve the speaker layout of PCM track \(namedPCM.index). Choose MOV.",
                                   track: namedPCM.index)
                continue
            }
            var priming: Int64?
            if ["mov", "mp4", "m4a"].contains(format), track.stream.codec == "aac", start > .zero,
               let first = track.packets.first {
                let skipped = try incomingBounds.lowerBound.subtracting(first.time).roundedToSamples(track.stream.sampleRate)
                if skipped > 0 { priming = skipped }
            }
            let plan = AudioReplacementPlan(source: movie.url, replacement: incoming.url, targetStream: target.stream.index,
                                            replacementStream: track.stream.index, replacementCodec: track.stream.codec,
                                            container: format, duration: movie.duration, sourceIdentity: movie.identity,
                                            replacementIdentity: incoming.identity, origin: movie.origin,
                                            streams: streams, targetOutputStream: targetOutputStream, audioBounds: audioBounds,
                                            replacementFormat: track.stream, editLists: editLists, priming: priming, targetStart: start, targetEnd: end,
                                            offsetMicroseconds: try offset.roundedToSamples(1_000_000), helper: helper)
            // Exercise the actual muxer's header, including every untouched stream, even on a dry run.
            do {
                try process.runHelper(helper, arguments: plan.arguments + ["-t", "0", "-f", plan.muxer, "-y", "/dev/null"],
                                      in: FileManager.default.temporaryDirectory)
                try verify(plan, with: process)
                return plan
            } catch let error as CutError where error.code == "encode_failed" {
                failure = CutError(code: "unsupported_container", message: "\(format.uppercased()) cannot copy this track combination. \(error.message)")
            }
        }
        throw failure ?? CutError(code: "unsupported_container", message: "No compatible output container was found.")
    }

    private func audio(in media: MediaInfo, index: Int?) throws -> AudioIndex {
        guard let track = media.audio.first(where: { index == nil || $0.stream.index == index }) else {
            throw CutError(code: "no_audio", message: "The selected audio stream is unavailable in \(media.url.lastPathComponent).", track: index)
        }
        return track
    }

    private static func tolerance(_ a: StreamInfo, _ b: StreamInfo) -> Double {
        max(1 / Double(max(1, min(a.sampleRate, b.sampleRate))), max(a.timeBase.seconds, b.timeBase.seconds)) + 1e-9
    }

    private static func chapterCarriers(in media: MediaInfo) -> Set<Int32> {
        guard media.format.split(separator: ",").contains("mov"),
              media.streams.contains(where: { $0.kind == "data" && $0.codecTag == "text" }) else { return [] }
        let asset = AVURLAsset(url: media.url)
        let associated = Set(asset.tracks.flatMap { $0.associatedTracks(ofType: .chapterList).map(\.trackID) })
        return Set(media.streams.filter { $0.kind == "data" && $0.codecTag == "text" && associated.contains($0.trackID) }.map(\.trackID))
    }

    private func audibleBounds(of audio: AudioIndex, in media: MediaInfo) throws -> ClosedRange<RationalTime> {
        // Matroska rounds packet timestamps to milliseconds. Recover the audible
        // endpoint from Opus sample counts and the first block's rounded codec delay.
        if audio.stream.codec == "opus", media.format.split(separator: ",").contains("matroska"),
           let window = try audio.opusWindow ?? opusTrimWindow(audio, origin: media.origin, checkCancellation: {
               if cancelled?() == true { throw CutError(code: "cancelled", message: "Export cancelled.") }
           }), window.complete {
            let start = try RationalTime(numerator: window.start, denominator: 48_000).subtracting(media.origin)
            let end = try RationalTime(numerator: window.end, denominator: 48_000).subtracting(media.origin)
            return start...end
        }
        return try audio.audibleBounds(origin: media.origin)
    }

    private func verify(_ plan: AudioReplacementPlan, with process: ReencodeEngine) throws {
        try process.checkCancellation()
        try process.verifyIdentity(plan.source, plan.sourceIdentity)
        try process.verifyIdentity(plan.replacement, plan.replacementIdentity)
    }

    public func export(_ plan: AudioReplacementPlan, to output: URL, progress: ((Double) -> Bool)? = nil) throws {
        _ = try exportWorkingCopy(plan, to: output, progress: progress)
    }

    /// `beforePublishing` receives the finished, verified copy while it is still in its private staging folder.
    /// Throwing from it leaves nothing at `output`. The plan does not decide how the muxer packs the copied tracks
    /// (PCM chunking, container time base, rewritten AAC edit lists), so what the copy can be cut into is known
    /// only from these bytes.
    package func exportWorkingCopy(_ plan: AudioReplacementPlan, to output: URL,
                                   progress: ((Double) -> Bool)? = nil,
                                   beforePublishing: ((URL) throws -> Void)? = nil) throws -> SourceIdentity {
        let process = ReencodeEngine(cancelled: cancelled)
        try verify(plan, with: process)
        try process.checkDestination(output, container: plan.container)
        let destination = output.standardizedFileURL
        let folder = destination.deletingLastPathComponent().appendingPathComponent(".mpcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = folder.appendingPathComponent("replacement").appendingPathExtension(plan.container)
        let cancellation = ReplacementCancellation()
        let runner = ReencodeEngine(cancelled: { cancelled?() == true || cancellation.isCancelled })
        do {
            try runner.runHelper(plan.helper, arguments: plan.arguments + ["-f", plan.muxer, "-n", partial.path], in: folder,
                                 duration: plan.duration) { fraction in
                if progress?(fraction) == false { cancellation.cancel() }
            }
        } catch let error as CutError where error.code == "encode_failed" {
            throw CutError(code: "write_failed", message: error.message)
        }
        try verify(plan, with: runner)
        if let priming = plan.priming {
            let start = MPCutTime(numerator: plan.targetStart.numerator, denominator: plan.targetStart.denominator)
            let end = MPCutTime(numerator: plan.targetEnd.numerator, denominator: plan.targetEnd.denominator)
            var message = [CChar](repeating: 0, count: 512)
            let size = message.count
            guard mpcut_align_copied_aac(partial.path, UInt32(plan.targetOutputStream), Int32(plan.replacementFormat.sampleRate),
                                         priming, start, end, 1_000_000, &message, size) == 0 else {
                throw CutError(code: "write_failed", message: String(cString: message))
            }
        }
        for item in plan.editLists {
            try runner.checkCancellation()
            var message = [CChar](repeating: 0, count: 512)
            let size = message.count
            let shift = MPCutTime(numerator: item.shift.numerator, denominator: item.shift.denominator)
            guard mpcut_restore_copied_aac(item.source.path, item.sourceTrackID, item.sampleRate, partial.path,
                                           UInt32(item.destinationStream), shift, 1_000_000, &message, size) == 0 else {
                throw CutError(code: "write_failed", message: String(cString: message))
            }
        }
        try verifyOutput(partial, plan: plan, cancelled: { cancelled?() == true || cancellation.isCancelled })
        let identity = try SourceIdentity(partial)
        try verify(plan, with: runner)
        try beforePublishing?(partial)
        try verify(plan, with: runner)
        guard identity.isCurrentSnapshot(at: partial) else {
            throw CutError(code: "write_failed", message: "The working copy changed before it could be saved.")
        }
        let failure = publishExclusively(from: partial, to: destination)
        guard failure == 0 else {
            throw CutError(code: failure == EEXIST ? "output_exists" : "write_failed", message: String(cString: strerror(failure)))
        }
        // An exclusive rename can update ctime. Pin the published location for
        // the next indexing job after verifying it still names our staged inode.
        let published = try SourceIdentity(destination)
        guard published == identity else {
            throw CutError(code: "source_changed", message: "The working copy changed after it was saved.")
        }
        return published
    }

    private func verifyOutput(_ file: URL, plan: AudioReplacementPlan, cancelled: @escaping @Sendable () -> Bool) throws {
        let output = try CutEngine(cancelled: cancelled, useSidecar: false).inspect(file)
        let changed = CutError(code: "unsupported_container", message: "The output container changed a track's presentation or timing during stream copy.")
        let chapterCarriers = Self.chapterCarriers(in: output)
        let streams = output.streams.filter { !chapterCarriers.contains($0.trackID) }
        guard streams.count == plan.streams.count else { throw changed }
        for (original, written) in zip(plan.streams, streams) {
            let expected = original.index == plan.targetStream ? plan.replacementFormat : original
            guard written.kind == expected.kind, written.codec == expected.codec,
                  original.language.isEmpty || original.language == "und" || written.language == original.language else { throw changed }
            if written.kind == "video" {
                let tolerance = max(written.timeBase.seconds, original.timeBase.seconds) + 1e-9
                guard written.width == original.width, written.height == original.height,
                      written.rotation == original.rotation, written.hasAlpha == original.hasAlpha,
                      written.sampleAspectRatio == original.sampleAspectRatio,
                      written.hasAdditionalVideoLayers == original.hasAdditionalVideoLayers,
                      written.codecMetadata == original.codecMetadata,
                      abs(written.start.seconds + output.origin.seconds - original.start.seconds - plan.origin.seconds) <= tolerance,
                      abs(written.duration.seconds - original.duration.seconds) <= tolerance else { throw changed }
            }
            if written.kind == "audio" {
                guard written.sampleRate == expected.sampleRate, written.channels == expected.channels,
                      (written.channelLayout == expected.channelLayout ||
                       (expected.channels <= 2 && (try? audioLayout(written)) == (try? audioLayout(expected)))),
                      let bounds = plan.audioBounds[original.index],
                      let actual = output.audio.first(where: { $0.stream.index == written.index }) else { throw changed }
                let tolerance = Self.tolerance(original, written)
                let audible = try audibleBounds(of: actual, in: output)
                guard abs(bounds.lowerBound.seconds - audible.lowerBound.seconds) <= tolerance,
                      abs(bounds.upperBound.seconds - audible.upperBound.seconds) <= tolerance else { throw changed }
            }
        }
    }
}

private final class ReplacementCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}
