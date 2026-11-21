import Darwin
import Foundation

/// The process creation mask, read once. Staged outputs are created private
/// and receive ordinary permissions immediately before publication.
let creationMask: mode_t = {
    let mask = umask(0)
    umask(mask)
    return mask
}()

/// Moves a staged file or directory to a destination that must not exist.
/// Returns 0, or the errno of the failure: EEXIST when the destination exists.
/// Volumes without an exclusive rename, such as exFAT, first claim the name.
func publishExclusively(from staged: URL, to destination: URL, isDirectory: Bool = false,
                        exclusiveRename: (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32 = renamex_np) -> Int32 {
    if exclusiveRename(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
    var code = errno
    guard code == ENOTSUP || code == EINVAL else { return code }
    if isDirectory {
        guard mkdir(destination.path, 0o700) == 0 else { return errno }
    } else {
        let placeholder = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard placeholder >= 0 else { return errno }
        close(placeholder)
    }
    if rename(staged.path, destination.path) == 0 { return 0 }
    code = errno
    // An empty claim is removed. Another writer's contents are left alone.
    if isDirectory { rmdir(destination.path) } else { unlink(destination.path) }
    return code
}
