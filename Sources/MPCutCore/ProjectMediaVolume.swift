import Foundation
import os

/// The kernel's cached mount table provides volume boundaries without asking
/// filesystems to respond. Keep disappeared mount points until this process
/// exits so an in-flight probe keeps its original key during an unmount.
package enum ProjectMediaVolume {
    @TaskLocal package static var checking: Set<String> = []
    private static let mounts = OSAllocatedUnfairLock(initialState: readMounts())

    package static func refreshMounts() {
        let updated = readMounts()
        mounts.withLock { paths in
            paths = Set(paths).union(updated).sorted { $0.count > $1.count }
        }
    }

    package static func isChecking(_ url: URL) -> Bool {
        !checking.isEmpty && checking.contains(key(for: url))
    }

    package static func key(for url: URL) -> String {
        let path = url.path
        if let mount = mounts.withLock({ paths in
            paths.first { path == $0 || path.hasPrefix($0 + "/") }
        }) { return mount }
        // An already-unmounted Finder volume no longer appears in the table.
        guard path.hasPrefix("/Volumes/"), url.pathComponents.count > 2 else { return "/" }
        return "/Volumes/" + url.pathComponents[2]
    }

    /// Resolve live editor references lexically. A parent traversal that could
    /// not be resolved on open must survive until the worker can probe it.
    package static func watchURL(_ path: String, relativeTo project: URL) -> URL {
        let absolute = path.hasPrefix("/") ? path : project.deletingLastPathComponent().path + "/" + path
        let url = URL(fileURLWithPath: absolute, isDirectory: false)
        return watchURL(url)
    }

    package static func watchURL(_ url: URL) -> URL {
        url.path.split(separator: "/").contains("..") ? url : url.standardizedFileURL
    }

    private static func readMounts() -> [String] {
        let request = Int32(MNT_NOWAIT)
        let count = getfsstat(nil, 0, request)
        guard count > 0 else { return [] }
        var mounts = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + 8)
        let read = getfsstat(&mounts, Int32(mounts.count * MemoryLayout<Darwin.statfs>.stride), request)
        guard read > 0 else { return [] }
        return mounts.prefix(Int(read)).compactMap { mount in
            let path = withUnsafeBytes(of: mount.f_mntonname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            return path == "/" || path.isEmpty ? nil : path
        }.sorted { $0.count > $1.count }
    }
}
