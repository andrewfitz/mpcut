import Darwin
import Foundation

struct MCPCommandError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    init(code: String, message: String) { self.init(code, message) }
    var errorDescription: String? { message }
}
typealias MCPFailure = MCPCommandError

/// One newline-terminated request and reply per same-user connection.
/// The serial queue owns descriptor membership; worker queues own blocking I/O.
final class MCPSocket: @unchecked Sendable {
    typealias Handler = @MainActor (Data) async -> Data
    static let limit = 4 * 1024 * 1024
    static var directory: String {
        // Packaged tests launch alongside the normal listener in a private /tmp directory.
        guard let name = ProcessInfo.processInfo.environment["MPCUT_TEST_SOCKET_DIRECTORY"], !name.isEmpty else {
            return "/tmp/mpcut-\(getuid())"
        }
        return name.wholeMatch(of: #/mpcut-test-[a-zA-Z0-9]{1,64}/#) != nil ? "/tmp/" + name : ""
    }
    private let directory: String
    private var path: String { directory + "/control.sock" }
    private let queue = DispatchQueue(label: "mpcut.mcp.connections")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var generation = UUID()
    private enum Phase {
        case reading
        case handling(DispatchSourceRead, Task<Void, Never>)
        case writing
    }
    private final class Client: @unchecked Sendable {
        let id = UUID()
        let fd: Int32
        let timer: DispatchSourceTimer
        var phase: Phase = .reading

        init(fd: Int32, timer: DispatchSourceTimer) {
            self.fd = fd
            self.timer = timer
        }

        deinit { close(fd) }
    }
    private var clients: [Int32: Client] = [:]

    init(directory: String = MCPSocket.directory) {
        self.directory = directory
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopListening() }
        else { stop() }
    }

    private static func systemError(_ action: String) -> MCPFailure {
        MCPFailure("listener_error", "\(action): \(String(cString: strerror(errno)))")
    }

    func start(handler: @escaping Handler) throws {
        try queue.sync {
            guard source == nil else { return }
            guard !directory.isEmpty else {
                throw MCPFailure("listener_error", "Invalid MPCut test socket directory.")
            }
            guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw Self.systemError("Create socket directory") }
            var info = stat()
            guard lstat(directory, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
                throw MCPFailure("listener_error", "The local control directory must be private and owned by your account.")
            }
            // The lock remains held until the socket is unlinked. This also handles unclean app exits.
            let lock = open(directory + "/listener.lock", O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw Self.systemError("Open control lock") }
            guard fstat(lock, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
                close(lock)
                throw MCPFailure("listener_error", "The local control lock must be a private file owned by your account.")
            }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                close(lock)
                throw MCPFailure("listener_error", "Another instance of MPCut is already serving local control.")
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { let error = Self.systemError("Create control socket"); close(lock); throw error }
            var bound = false
            do {
                if lstat(path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), unlink(path) == 0 else {
                        throw MCPFailure("listener_error", "The local control socket path is occupied.")
                    }
                } else if errno != ENOENT { throw Self.systemError("Inspect control socket") }
                var address = sockaddr_un()
                let bytes = Array(path.utf8CString)
                guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                    throw MCPFailure("listener_error", "The local control socket path is too long.")
                }
                address.sun_family = sa_family_t(AF_UNIX)
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
                let status = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard status == 0 else { throw Self.systemError("Bind control socket") }
                bound = true
                guard chmod(path, 0o600) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                      fcntl(fd, F_SETFL, O_NONBLOCK) == 0, listen(fd, 16) == 0 else {
                    throw Self.systemError("Listen for local control")
                }
            } catch {
                if bound { unlink(path) }
                close(fd)
                close(lock)
                throw error
            }
            lockFD = lock
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let epoch = generation
            reader.setEventHandler { [weak self] in self?.acceptClient(fd, epoch: epoch, handler: handler) }
            reader.setCancelHandler { close(fd) }
            source = reader
            reader.resume()
        }
    }

    func stop() {
        queue.sync { stopListening() }
    }

    private func stopListening() {
        guard let source else { return }
        self.source = nil
        generation = UUID()
        source.cancel()
        unlink(path)
        close(lockFD)
        lockFD = -1
        for (fd, client) in clients { cancel(fd, id: client.id) }
    }

    private func acceptClient(_ server: Int32, epoch: UUID, handler: @escaping Handler) {
        guard generation == epoch else { return }
        let fd = accept(server, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0, yes: Int32 = 1
        guard clients.count < 32, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, 0) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
            close(fd)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let client = Client(fd: fd, timer: timer), id = client.id
        timer.setEventHandler { [weak self] in self?.cancel(fd, id: id) }
        timer.schedule(deadline: .now() + .seconds(15))
        clients[fd] = client
        timer.resume()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, queue] in
            let request = Self.readLine(client.fd)
            queue.async { [weak self] in
                guard let self else { return }
                let fd = client.fd
                guard let request, self.generation == epoch else { self.finish(fd, id: id); return }
                self.handle(request, from: fd, id: id, handler: handler)
            }
        }
    }

    private func handle(_ request: Data, from fd: Int32, id: UUID, handler: @escaping Handler) {
        guard let client = clients[fd], client.id == id else { return }
        // A complete frame may already be followed by extra data or disconnect.
        var byte: UInt8 = 0
        var pending: Int
        repeat { pending = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) }
        while pending < 0 && errno == EINTR
        guard pending < 0, errno == EAGAIN || errno == EWOULDBLOCK else { finish(fd, id: id); return }
        let watchedFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard watchedFD >= 0 else { finish(fd, id: id); return }
        let watcher = DispatchSource.makeReadSource(fileDescriptor: watchedFD, queue: queue)
        watcher.setCancelHandler { close(watchedFD) }
        watcher.setEventHandler { [weak self] in self?.cancel(fd, id: id) }
        let task = Task { @MainActor [weak self, queue] in
            guard !Task.isCancelled else { return }
            let result = await handler(request)
            queue.async { [weak self] in self?.write(result, to: fd, id: id) }
        }
        client.phase = .handling(watcher, task)
        client.timer.schedule(deadline: .now() + .seconds(5 * 60))
        watcher.resume()
    }

    private func write(_ result: Data, to fd: Int32, id: UUID) {
        guard let client = clients[fd], client.id == id,
              case let .handling(watcher, _) = client.phase else { return }
        watcher.cancel()
        client.phase = .writing
        client.timer.schedule(deadline: .now() + .seconds(15))
        DispatchQueue.global(qos: .userInitiated).async { [weak self, queue] in
            Self.reply(result, to: client.fd)
            queue.async { [weak self] in
                self?.finish(client.fd, id: id)
            }
        }
    }

    private func cancel(_ fd: Int32, id: UUID) {
        guard let client = clients[fd], client.id == id else { return }
        shutdown(fd, SHUT_RDWR)
        switch client.phase {
        case let .handling(_, task):
            task.cancel()
            finish(fd, id: id)
        case .reading, .writing:
            // A worker still owns I/O on this descriptor until its queue callback.
            client.timer.cancel()
        }
    }

    private func finish(_ fd: Int32, id: UUID) {
        guard let client = clients[fd], client.id == id else { return }
        clients[fd] = nil
        client.timer.cancel()
        if case let .handling(watcher, _) = client.phase { watcher.cancel() }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let end = buffer[..<count].firstIndex(of: 10) {
                guard end == count - 1 else { return nil }
                data.append(contentsOf: buffer[..<end])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        return nil
    }

    private static func reply(_ data: Data, to fd: Int32) {
        let overflow = Data(#"{"error":{"code":"response_too_large","message":"Request a smaller result page."}}"#.utf8)
        var line = data.count < limit ? data : overflow
        line.append(10)
        line.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
