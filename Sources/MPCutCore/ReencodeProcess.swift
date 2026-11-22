import Darwin
import Foundation

extension ReencodeEngine {
    func runHelper(_ executable: URL, arguments: [String], in directory: URL,
                   timeout: Duration? = nil, duration: RationalTime? = nil, progress: ((Double) -> Void)? = nil) throws {
        try checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        var options = ["-nostdin", "-hide_banner", "-nostats", "-loglevel", "error"]
        if duration != nil, progress != nil { options += ["-progress", "pipe:1"] }
        process.arguments = options + arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output.fileHandleForWriting
        process.standardError = errors.fileHandleForWriting
        do {
            try process.run()
        } catch {
            throw CutError(code: "encoder_unavailable", message: "Could not start the video encoder. \(error.localizedDescription)")
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        var descriptors = [output, errors].map {
            pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = Data()
        var diagnostic = Data()
        var reported = 0.0
        let deadline = timeout.map { ContinuousClock.now + $0 }
        // Service both pipes while the process is alive. An encoder can fill
        // stderr even when it has stopped printing progress.
        do {
            while descriptors.contains(where: { $0.fd >= 0 }) || process.isRunning {
                try checkCancellation()
                if let deadline, ContinuousClock.now >= deadline {
                    throw CutError(code: "encoder_unavailable", message: "The hardware encoder did not respond to its startup check. Try again.")
                }
                if descriptors.allSatisfy({ $0.fd < 0 }) {
                    // The child can close both pipes just before exiting. Wait
                    // for termination without making it pay another poll interval.
                    if exited.wait(timeout: .now() + .milliseconds(75)) == .success { break }
                    continue
                }
                let ready = poll(&descriptors, 2, 75)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw pipeError() }
                for index in descriptors.indices where descriptors[index].revents != 0 {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptors[index].fd, $0.baseAddress, $0.count)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw pipeError() }
                    if count == 0 {
                        descriptors[index].fd = -1
                    } else if index == 1 {
                        diagnostic.append(contentsOf: buffer.prefix(count))
                        if diagnostic.count > 8192 { diagnostic = Data(diagnostic.suffix(8192)) }
                    } else if let duration, duration > .zero, let progress {
                        pending.append(contentsOf: buffer.prefix(count))
                        while let newline = pending.firstIndex(of: 10) {
                            let line = String(decoding: pending[..<newline], as: UTF8.self)
                            pending.removeSubrange(...newline)
                            guard line.hasPrefix("out_time_us="),
                                  let micros = Int64(line.dropFirst("out_time_us=".count)) else { continue }
                            let fraction = min(1, Double(micros) / 1_000_000 / duration.seconds)
                            if fraction > reported {
                                reported = fraction
                                progress(fraction)
                            }
                        }
                    }
                }
            }
        } catch {
            // The child writes only inside the caller's staging directory.
            // Reap it before that directory is removed.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        try checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CutError(code: "encode_failed", message: detail.isEmpty
                ? "The encoder exited with status \(process.terminationStatus)." : detail)
        }
    }

    private func pipeError() -> CutError {
        CutError(code: "encode_failed", message: "Could not read the encoder output. \(String(cString: strerror(errno)))")
    }
}
