import Darwin
import Foundation
import SwiftUI

@main
enum ApplicationEntry {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--file-worker" else {
            MPCutApp.main()
            return
        }
        let readyFD: Int32 = 3 // Passed by the stdio helper.
        guard args.count == 3, args[2].wholeMatch(of: #/\/tmp\/mpcut-files-[a-zA-Z0-9]{1,64}/#) != nil,
              fcntl(readyFD, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(readyFD, F_SETNOSIGPIPE, 1) == 0 else { exit(2) }
        let directory = args[2]
        let socket = MCPSocket(directory: directory)
        let jobs = MCPFileJobs(receipts: .standalone)
        do {
            try socket.start { data in
                do {
                    let (tool, input, integers) = try await MCPLocalControl.decode(data)
                    guard MCPFileRequest.isFileTool(tool) else {
                        throw MCPFailure("unsupported_tool", "This worker serves saved-file operations.")
                    }
                    let arguments = try MCPSchemas.loaded.get().validate(tool: tool, arguments: input, wireIntegers: integers)
                    // The socket may have stopped while the request was decoding.
                    try Task.checkCancellation()
                    return try await MCPLocalControl.encode(jobs.perform(tool: tool, validatedArguments: arguments))
                } catch { return MCPLocalControl.errorData(error) }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
        let ready = FileHandle(fileDescriptor: readyFD, closeOnDealloc: true)
        let readySent: Bool
        do {
            try ready.write(contentsOf: Data("ready\n".utf8))
            readySent = true
        } catch {
            readySent = false
        }
        try? ready.close()
        if readySent {
            // The stdio server owns the other end. EOF also handles an unexpected server exit.
            await Task.detached { _ = FileHandle.standardInput.readData(ofLength: 1) }.value
        }
        socket.stop()
        // The helper may already be gone. Only remove this worker's own files.
        unlink(directory + "/listener.lock")
        rmdir(directory)
        await jobs.cancelAndWaitForJobs()
        if !readySent { exit(1) }
    }
}
