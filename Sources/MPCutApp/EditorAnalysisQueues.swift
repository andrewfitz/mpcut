import Foundation
import MPCutCore

/// Share decoder capacity across project windows. Short, visible waveform requests
/// have a separate queue so a long scene scan cannot hold up timeline interaction.
enum EditorAnalysisQueues {
    static let scans = queue(named: "MPCut background media analysis")
    static let waveformDetail = queue(named: "MPCut visible audio detail")
    static let openingAudio = queue(named: "MPCut opening audio preview", priority: .userInitiated)

    private static func queue(named name: String, priority: QualityOfService = .utility) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = priority
        queue.maxConcurrentOperationCount = 2
        return queue
    }

    static func scan<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let token = EditCancellation()
        let result: T = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                scans.addOperation {
                    continuation.resume(with: Result {
                        guard !token.isCancelled else { throw CancellationError() }
                        return try work()
                    })
                }
            }
        } onCancel: {
            token.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}
