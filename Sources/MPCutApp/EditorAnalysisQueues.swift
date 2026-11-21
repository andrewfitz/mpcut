import Foundation

/// Share decoder capacity across project windows. Short, visible waveform requests
/// have a separate queue so a long scene scan cannot hold up timeline interaction.
enum EditorAnalysisQueues {
    static let scans = queue(named: "MPCut background media analysis")
    static let waveformDetail = queue(named: "MPCut visible audio detail")

    private static func queue(named name: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }

    static func scan<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            scans.addOperation { continuation.resume(with: Result { try work() }) }
        }
    }
}
