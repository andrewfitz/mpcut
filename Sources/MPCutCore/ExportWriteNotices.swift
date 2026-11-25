import Foundation

/// What a written export changed that no plan could know: an encoder that refused constant quality, or pictures
/// decoded in software after the hardware decoder failed. A dry run never has them, so results list them as
/// `written_warnings`, apart from the `warnings` a dry run and the export share.
///
/// Writers record them on the thread that runs the export. `collecting` gathers those of its own work, and those of
/// any `collecting` inside it, so exports running side by side keep theirs apart.
public final class ExportWriteNotices: @unchecked Sendable {
    @TaskLocal private static var current: ExportWriteNotices?

    private let parent: ExportWriteNotices?
    private let lock = NSLock()
    private var notices: [String] = []

    private init(parent: ExportWriteNotices?) {
        self.parent = parent
    }

    /// Runs `work` and returns what the writers it ran recorded, in order and without repeats.
    public static func collecting<Value>(_ work: () throws -> Value) rethrows -> (value: Value, notices: [String]) {
        let collector = ExportWriteNotices(parent: current)
        let value = try $current.withValue(collector) { try work() }
        return (value, collector.taken)
    }

    /// Adds `notices` to the export being collected. Nothing collects outside `collecting`.
    package static func record(_ notices: [String]) {
        guard !notices.isEmpty else { return }
        var collector = current
        while let next = collector {
            next.add(notices)
            collector = next.parent
        }
    }

    package static func record(_ notice: String) { record([notice]) }

    /// What the innermost `collecting` has gathered so far, for a result saved before the work returns.
    public static var recorded: [String] { current?.taken ?? [] }

    private func add(_ added: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for notice in added where !notices.contains(notice) { notices.append(notice) }
    }

    private var taken: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notices
    }
}
