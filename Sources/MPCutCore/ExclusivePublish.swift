import Darwin
import Foundation

/// Determine the permissions the current process would give a new output,
/// without toggling the process-wide umask while other threads create files.
func publicationPermissions(_ requested: mode_t) throws -> mode_t {
    let probe = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fd = open(probe.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, requested)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    guard unlink(probe.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return info.st_mode & requested
}

/// Moves a staged file or directory to a destination that must not exist.
/// Returns 0, or the errno of the failure: EEXIST when the destination exists.
/// Volumes without an exclusive rename, such as exFAT, first claim the name.
package func publishExclusively(from staged: URL, to destination: URL, isDirectory: Bool = false,
                        exclusiveRename: (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32 = renamex_np) -> Int32 {
    if exclusiveRename(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
    var code = errno
    guard code == ENOTSUP || code == EINVAL else { return code }
    let placeholder: Int32
    var claim = stat()
    if isDirectory {
        guard mkdir(destination.path, 0o700) == 0 else { return errno }
        placeholder = -1
        guard lstat(destination.path, &claim) == 0 else { return errno }
        guard claim.st_mode & S_IFMT == S_IFDIR else { return EEXIST }
    } else {
        placeholder = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard placeholder >= 0 else { return errno }
        if fstat(placeholder, &claim) != 0 {
            code = errno
            close(placeholder)
            return code
        }
    }
    defer { if placeholder >= 0 { close(placeholder) } }

    func ownsClaim() -> Bool {
        var current = stat()
        return lstat(destination.path, &current) == 0
            && current.st_dev == claim.st_dev && current.st_ino == claim.st_ino
            && (isDirectory || current.st_size == 0)
    }

    guard ownsClaim() else { return EEXIST }
    if rename(staged.path, destination.path) == 0 { return 0 }
    code = errno
    // An empty claim is removed. Another writer's contents are left alone.
    if ownsClaim() {
        if isDirectory { rmdir(destination.path) } else { unlink(destination.path) }
    }
    return code
}
