import AppKit
import Darwin
import MPCutCore
import SwiftUI

/// A draft owns a directory lock because atomic saves replace the document's inode.
final class ProjectDraft {
    private let directory: URL
    /// Held from before decoding until the editor either cancels the open or adopts the draft.
    final class Reservation: @unchecked Sendable {
        let url: URL
        fileprivate let descriptor: Int32

        fileprivate init(_ url: URL) throws {
            self.url = url
            descriptor = try ProjectDraft.lock(url.deletingLastPathComponent())
        }

        fileprivate var ownsFolder: Bool {
            var locked = stat(), named = stat()
            let folder = url.deletingLastPathComponent()
            return fstat(descriptor, &locked) == 0 && lstat(folder.path, &named) == 0
                && locked.st_dev == named.st_dev && locked.st_ino == named.st_ino
        }

        fileprivate func checkLocation() throws {
            guard ownsFolder else {
                throw CutError(code: "draft_moved", message: "The recovery folder moved. Save the project to a new location.")
            }
        }

        fileprivate func withStagedWrite(_ save: (URL) throws -> Void,
                                         publish: (String) throws -> Void) throws {
            try checkLocation()
            let name = ".pending-\(UUID().uuidString).cut"
            defer { unlinkat(descriptor, name, 0) }
            try save(url.deletingLastPathComponent().appendingPathComponent(name))
            try publish(name)
        }

        fileprivate func publish(_ name: String) throws {
            try checkLocation()
            guard renameat(descriptor, name, descriptor, url.lastPathComponent) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        deinit { close(descriptor) }
    }

    private var reservation: Reservation?
    var url: URL? { reservation?.url }
    private var writer: DraftWriter?
    var hasScheduledWrites: Bool { writer?.isBusy ?? false }

    static let autosaveDirectory: URL = {
        let manager = FileManager.default
        if ProcessInfo.processInfo.processName == "xctest" {
            return manager.temporaryDirectory.appendingPathComponent("MPCutTests-\(getpid())/Drafts", isDirectory: true)
        }
        return manager.urls(for: .autosavedInformationDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mpcut.desktop", isDirectory: true)
    }()

    init(directory: URL = ProjectDraft.autosaveDirectory) {
        self.directory = directory
    }

    deinit {
        writer?.invalidate()
    }

    func write(_ save: (URL) throws -> Void) throws {
        if let reservation {
            try reservation.withStagedWrite(save) { name in
                writer?.invalidate()
                writer = nil
                try reservation.publish(name)
            }
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let document = folder.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("Untitled.cut")
        let lease = try Reservation(document)
        do {
            try lease.withStagedWrite(save, publish: lease.publish)
            reservation = lease
        } catch {
            if lease.ownsFolder {
                unlinkat(lease.descriptor, document.lastPathComponent, 0)
                rmdir(folder.path)
            }
            throw error
        }
    }

    /// The initial draft is written synchronously. Large later edits can replace a pending
    /// snapshot while an earlier one is being encoded off the main thread.
    func schedule(_ save: @escaping @Sendable (URL) throws -> Void,
                  onError: @escaping @MainActor (Error) -> Void) throws {
        guard let reservation else { return try write(save) }
        try reservation.checkLocation()
        let worker = writer ?? DraftWriter(reservation: reservation)
        writer = worker
        worker.submit(save, onError: onError)
    }

    private static func lock(_ folder: URL) throws -> Int32 {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw CutError(code: "draft_in_use", message: "This untitled project is already open in MPCut.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private static func contains(_ file: URL, in directory: URL) -> Bool {
        let file = file.resolvingSymlinksInPath().standardizedFileURL
        let parent = file.deletingLastPathComponent()
        var ancestor = stat(), root = stat()
        return file.lastPathComponent == "Untitled.cut" && UUID(uuidString: parent.lastPathComponent) != nil
            && stat(parent.deletingLastPathComponent().path, &ancestor) == 0 && stat(directory.path, &root) == 0
            && ancestor.st_dev == root.st_dev && ancestor.st_ino == root.st_ino
    }

    /// Save As destinations anywhere inside recovery storage would remain hidden from the user.
    static func isManaged(_ file: URL, in directory: URL = autosaveDirectory) -> Bool {
        var root = stat()
        guard stat(directory.path, &root) == 0 else { return false }
        var ancestor = file.resolvingSymlinksInPath().deletingLastPathComponent()
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            var info = stat()
            if stat(ancestor.path, &info) == 0 && info.st_dev == root.st_dev && info.st_ino == root.st_ino { return true }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    func managesDestination(_ file: URL) -> Bool { Self.isManaged(file, in: directory) }

    static func reserveIfRecoverable(_ file: URL, in directory: URL = autosaveDirectory) throws -> Reservation? {
        guard contains(file, in: directory) else { return nil }
        let file = file.resolvingSymlinksInPath().standardizedFileURL
        let lease = try Reservation(file)
        var info = stat()
        guard fstatat(lease.descriptor, file.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileNoSuchFile) }
        return lease
    }

    func reserveIfRecoverable(_ file: URL) throws -> Reservation? {
        if let reservation, reservation.url == file.resolvingSymlinksInPath().standardizedFileURL {
            try reservation.checkLocation()
            return reservation
        }
        return try Self.reserveIfRecoverable(file, in: directory)
    }

    @discardableResult
    func adopt(_ lease: Reservation?) -> Bool {
        guard let lease else { return false }
        if lease !== reservation {
            discard()
            reservation = lease
        }
        return true
    }

    /// AppKit can close a window without asking its editor. Finish captured writes and leave
    /// the result discoverable for recovery when the worker releases its reservation.
    func relinquish() {
        writer?.stopReporting()
        writer = nil
        reservation = nil
    }

    /// Called only after a successful named save or the user's close/discard decision.
    func discard() {
        guard let lease = reservation else { return }
        writer?.invalidate()
        writer = nil
        reservation = nil
        guard lease.ownsFolder else { return }
        let folder = lease.url.deletingLastPathComponent()
        unlinkat(lease.descriptor, lease.url.lastPathComponent, 0)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(".pending-") && name.hasSuffix(".cut")
                && UUID(uuidString: String(name.dropFirst(".pending-".count).dropLast(".cut".count))) != nil {
            unlinkat(lease.descriptor, name, 0)
        }
        if lease.ownsFolder { rmdir(folder.path) }
    }

    static func recoverable(in directory: URL = autosaveDirectory) throws -> [URL] {
        let manager = FileManager.default
        let folders: [URL]
        do {
            folders = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return folders.compactMap { folder -> (URL, Date)? in
            let file = folder.appendingPathComponent("Untitled.cut")
            guard UUID(uuidString: folder.lastPathComponent) != nil, manager.fileExists(atPath: file.path),
                  let descriptor = try? lock(folder) else { return nil }
            defer { close(descriptor) }
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
            return (file, info.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// All publication and invalidation decisions share one lock. Encoding can finish
/// after Save As or Discard, but only a live owner can replace the draft.
private final class DraftWriter: @unchecked Sendable {
    private struct Job {
        let id = UUID()
        let save: @Sendable (URL) throws -> Void
        let onError: @MainActor (Error) -> Void
    }
    private let reservation: ProjectDraft.Reservation
    private let lock = NSLock()
    private var running = false
    private var invalidated = false
    private var reportsErrors = true
    private var pending: Job?
    private var latest: UUID?
    var isBusy: Bool { lock.withLock { running } }

    init(reservation: ProjectDraft.Reservation) { self.reservation = reservation }

    func submit(_ save: @escaping @Sendable (URL) throws -> Void,
                onError: @escaping @MainActor (Error) -> Void) {
        let job = Job(save: save, onError: onError)
        let start = lock.withLock {
            guard !invalidated else { return false }
            latest = job.id
            pending = job
            guard !running else { return false }
            running = true
            return true
        }
        if start { DispatchQueue.global(qos: .utility).async { self.drain() } }
    }

    func stopReporting() { lock.withLock { reportsErrors = false } }

    func invalidate() {
        lock.withLock {
            invalidated = true
            pending = nil
        }
    }

    private func next() -> Job? {
        lock.withLock {
            let job = pending
            pending = nil
            if job == nil { running = false }
            return job
        }
    }

    private func drain() {
        let document = reservation.url
        let directory = document.deletingLastPathComponent()
        while let job = next() {
            defer {
                // If the user discarded the draft mid-write, the directory can now be empty.
                if lock.withLock({ invalidated }), reservation.ownsFolder { rmdir(directory.path) }
            }
            do {
                try reservation.withStagedWrite(job.save) { name in
                    try lock.withLock {
                        if !invalidated { try reservation.publish(name) }
                    }
                }
            } catch {
                Task { @MainActor in
                    if self.lock.withLock({ self.reportsErrors && !self.invalidated && self.latest == job.id }) {
                        job.onError(error)
                    }
                }
            }
        }
    }
}

extension ProjectSessions {
    @MainActor
    func recoverUntitledProject(using action: OpenWindowAction) {
        setWindowOpener(action)
        let source = commandContext?.session
        let window = source?.window
        do {
            let files = try ProjectDraft.recoverable()
            let alert = NSAlert()
            if files.isEmpty {
                alert.messageText = "No untitled projects to recover"
                alert.informativeText = "Untitled projects from interrupted editing sessions appear here."
                ProjectPanels.present(alert, in: window)
                return
            }
            alert.messageText = "Recover an untitled project"
            alert.informativeText = "Choose a draft by its last edit time."
            let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
            for file in files {
                let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let label = date?.formatted(date: .abbreviated, time: .standard) ?? "Unknown edit time"
                choices.addItem(withTitle: "\(label) (\(file.deletingLastPathComponent().lastPathComponent.prefix(8)))")
            }
            alert.accessoryView = choices
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Cancel")
            let respond: (NSApplication.ModalResponse) -> Void = { [weak self] result in
                guard result == .alertFirstButtonReturn, files.indices.contains(choices.indexOfSelectedItem) else { return }
                let file = files[choices.indexOfSelectedItem]
                if let source { self?.openProject(file, in: source, accepting: alert.window) }
                else { self?.openFiles([file]) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: respond) }
            else { respond(alert.runModal()) }
        } catch {
            ProjectPanels.present(NSAlert(error: error), in: window)
        }
    }
}
