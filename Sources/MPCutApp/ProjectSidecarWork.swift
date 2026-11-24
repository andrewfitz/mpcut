import Foundation
import MPCutCore

/// Detached tasks and operation queues do not inherit task-local values. Capture the
/// document at submission so another window or Save As cannot redirect running work.
struct ProjectSidecarWork: Sendable {
    let project: URL?
    let storageDirectory: URL?

    init(project: URL?, storageDirectory: URL? = SidecarLocations.storageDirectory) {
        self.project = project
        self.storageDirectory = storageDirectory
    }

    func detached<T: Sendable>(priority: TaskPriority,
                               operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        Task.detached(priority: priority) {
            await SidecarLocations.$storageDirectory.withValue(storageDirectory) {
                await SidecarLocations.$projectURL.withValue(project) { await operation() }
            }
        }
    }

    func detached<T: Sendable>(priority: TaskPriority,
                               operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        Task.detached(priority: priority) {
            try await SidecarLocations.$storageDirectory.withValue(storageDirectory) {
                try await SidecarLocations.$projectURL.withValue(project) { try await operation() }
            }
        }
    }

    func queued(_ operation: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        {
            SidecarLocations.$storageDirectory.withValue(storageDirectory) {
                SidecarLocations.$projectURL.withValue(project, operation: operation)
            }
        }
    }
}
