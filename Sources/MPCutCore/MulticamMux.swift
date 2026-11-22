import Darwin
import Foundation

/// Installs an independently staged picture and soundtrack on their common
/// program clock. MOV sample tables and edit lists survive without demuxing.
struct MulticamMux {
    var cancelled: (@Sendable () -> Bool)?

    /// The container lists belong to the export rules.
    static var movieContainers: [String] { ExportRules.multicamMovieContainers }

    func check(container: String) throws {
        if Self.movieContainers.contains(container) { return }
        guard ExportRules.multicamContainers.contains(container) else { throw ExportRules.multicamContainerRefusal }
        _ = try ReencodeEngine.findHelper(override: nil)
    }

    func export(picture: URL, sound: URL, to output: URL, container: String, duration: RationalTime,
                progress: ((Double) -> Bool)? = nil, verifySources: () throws -> Void = {}) throws {
        try check(container: container)
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
            if Self.movieContainers.contains(container) {
                try MulticamMOV.combine(picture: picture, sound: sound, output: partial, progress: update)
            } else {
                let helper = try ReencodeEngine.findHelper(override: nil)
                let muxer = container == "mkv" ? "matroska" : container
                try runner.runHelper(helper, arguments: [
                    "-xerror", "-copyts", "-i", picture.path, "-i", sound.path,
                    "-map", "0:v:0", "-map", "1:a:0", "-map_chapters", "-1",
                    "-c", "copy", "-copyinkf", "-avoid_negative_ts", "disabled", "-f", muxer, "-n", partial.path
                ], in: staging, duration: duration) { fraction in
                    if progress?(fraction) == false { interruption.stop() }
                }
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
        // The movie is staged private. Publish it with the permissions of any other export.
        guard chmod(partial.path, 0o666 & ~creationMask) == 0 else {
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
}

private final class MuxInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
