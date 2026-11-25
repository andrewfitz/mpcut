import Darwin
import Foundation

/// Installs an independently staged picture and soundtrack on their common
/// program clock. MOV sample tables and edit lists survive without demuxing.
struct MulticamMux {
    var cancelled: (@Sendable () -> Bool)?

    /// The container lists belong to the export rules.
    static var movieContainers: [String] { ExportRules.multicamMovieContainers }

    func check(container: String) throws {
        if Self.movieContainers.contains(container) || container == "m4a" { return }
        guard ExportRules.multicamContainers.contains(container) || container == "mka" else { throw ExportRules.multicamContainerRefusal }
        _ = try ReencodeEngine.findHelper(override: nil)
    }

    func export(picture: URL, sound: URL, to output: URL, container: String, duration: RationalTime,
                progress: ((Double) -> Bool)? = nil, verifySources: () throws -> Void = {}) throws {
        try export(picture: picture, sounds: [sound], to: output, container: container, duration: duration,
                   progress: progress, verifySources: verifySources)
    }

    func export(picture: URL?, sounds: [URL], to output: URL, container: String, duration: RationalTime,
                audio: [MulticamExportAudioLane] = [], chapters: [ReencodeChapter] = [],
                progress: ((Double) -> Bool)? = nil, verifySources: () throws -> Void = {}) throws {
        let written = ExportRules.multicamMuxContainer(container)
        try check(container: written)
        let process = ReencodeEngine(cancelled: cancelled)
        try process.checkCancellation()
        try process.checkDestination(output, container: container)
        let destination = output.standardizedFileURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mpcut-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let partial = staging.appendingPathComponent("program").appendingPathExtension(container)
        let interruption = MuxInterruption()
        let runner = ReencodeEngine(cancelled: { [cancelled] in cancelled?() == true || interruption.stopped })
        func update(_ fraction: Double) throws {
            try runner.checkCancellation()
            if progress?(fraction) == false {
                interruption.stop()
                try runner.checkCancellation()
            }
        }
        do {
            try update(0)
            if Self.movieContainers.contains(written) || written == "m4a" {
                let track = chapters.isEmpty ? nil : MulticamChapterTrack.plan(chapters, container: written).track
                try MulticamMOV.combine(picture: picture, sounds: sounds, output: partial, chapters: track, progress: update)
            } else {
                let helper = try ReencodeEngine.findHelper(override: nil)
                let muxer = written == "mkv" || written == "mka" ? "matroska" : written
                var arguments = ["-xerror", "-copyts"]
                for input in [picture].compactMap({ $0 }) + sounds { arguments += ["-i", input.path] }
                // The chapters are one more input, without streams, after the picture and sound.
                var chapterInput = "-1"
                if !chapters.isEmpty {
                    try ReencodeChapter.metadata(chapters).write(to: staging.appendingPathComponent("chapters.ffmeta"),
                                                                 atomically: true, encoding: .utf8)
                    chapterInput = String(sounds.count + (picture == nil ? 0 : 1))
                    arguments += ["-f", "ffmetadata", "-i", "chapters.ffmeta"]
                }
                if picture != nil { arguments += ["-map", "0:v:0"] }
                for index in sounds.indices {
                    arguments += ["-map", "\(index + (picture == nil ? 0 : 1)):a:0",
                                  "-disposition:a:\(index)", index == 0 ? "default" : "0"]
                }
                arguments += ["-map_chapters", chapterInput, "-c", "copy", "-copyinkf", "-avoid_negative_ts",
                              "disabled", "-f", muxer, "-n", partial.path]
                try runner.runHelper(helper, arguments: arguments, in: staging, duration: duration) { fraction in
                    if progress?(fraction) == false { interruption.stop() }
                }
            }
            if audio.count > 1 {
                try verifyAudio(audio, in: partial)
            }
            try update(1)
        } catch let error as CutError {
            if error.code == "encode_failed" { throw CutError(code: "write_failed", message: error.message) }
            throw error
        } catch {
            throw CutError(code: "write_failed", message: error.localizedDescription)
        }
        try verifySources()
        try runner.checkCancellation()
        try Self.publishMovie(partial, to: destination)
    }

    static func publishMovie(_ partial: URL, to destination: URL) throws {
        // The movie is staged private. Publish it with the permissions of any other export.
        guard chmod(partial.path, try publicationPermissions(0o666)) == 0 else {
            throw CutError(code: "write_failed", message: String(cString: strerror(errno)))
        }
        let failure = publishExclusively(from: partial, to: destination)
        guard failure == 0 else {
            if failure == EEXIST {
                throw CutError(code: "output_exists", message: "A file already exists at the destination.")
            }
            throw CutError(code: "write_failed", message: String(cString: strerror(failure)))
        }
    }
    private func verifyAudio(_ planned: [MulticamExportAudioLane], in file: URL) throws {
        let streams = try Probe.read(file, keyframes: false, previewOnly: true, cancelled: cancelled)
            .streams.filter { $0.kind == "audio" }
        guard streams.count == planned.count else {
            throw CutError(code: "write_failed", message: "The multiplexed file did not retain every planned audio track.")
        }
        for (index, pair) in zip(streams, planned).enumerated() {
            let (stream, lane) = pair
            guard stream.codec == lane.codec, stream.sampleRate == lane.sampleRate,
                  stream.canonicalChannelLayout == lane.channelLayout,
                  (stream.disposition & 1 != 0) == (index == 0) else {
                throw CutError(code: "write_failed", message: "The multiplexed file changed lane \(lane.label) (\(lane.id)).",
                               track: stream.index, laneID: lane.id)
            }
        }
    }

}

private final class MuxInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
