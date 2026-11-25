import Foundation

/// Begins and ends process activities. `ProcessInfo` is the production provider.
public protocol ActivityProviding: AnyObject, Sendable {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol
    func endActivity(_ activity: NSObjectProtocol)
}

extension ProcessInfo: ActivityProviding {}

/// Keeps the Mac out of idle sleep while an export or transcription runs. Hold the token for
/// the whole job; it ends on `end()` or when released, whichever comes first.
public final class SleepPrevention: @unchecked Sendable {
    /// Idle system sleep only. The display may still sleep.
    public static let options: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled]

    private let provider: ActivityProviding
    private let lock = NSLock()
    private var activity: NSObjectProtocol?

    public init(reason: String, provider: ActivityProviding = ProcessInfo.processInfo) {
        self.provider = provider
        activity = provider.beginActivity(options: Self.options, reason: reason)
    }

    public var isActive: Bool { lock.withLock { activity != nil } }

    /// Ends the activity once. Later calls do nothing.
    public func end() {
        let ending: NSObjectProtocol? = lock.withLock {
            defer { activity = nil }
            return activity
        }
        if let ending { provider.endActivity(ending) }
    }

    deinit { end() }
}
