import Foundation
import MPCutCore

struct LiveProjectMediaArchive: Sendable {
    let project: CutProject
    var undo: [CutHistoryState]
    var redo: [CutHistoryState]
    var snapshot: ProjectMediaSnapshot
    let documentURL: URL
    let checkingVolumes: Set<String>

    static let untitledURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Untitled.cut")

    func relink(_ from: String, to: URL) async throws -> ProjectMediaRelinkResult {
        let work = Task.detached(priority: .userInitiated) {
            try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                try ProjectMedia.relink(project: project, undo: undo, redo: redo, snapshot: snapshot,
                                        relativeTo: documentURL, from: from, to: to)
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func relink(_ mappings: [ProjectMediaMapping]) async throws -> ProjectMediaBatchResult {
        let work = Task.detached(priority: .userInitiated) {
            ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                ProjectMedia.relink(project: project, undo: undo, redo: redo, snapshot: snapshot,
                                    relativeTo: documentURL, mappings: mappings)
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    @MainActor
    func applyRelinks(_ mappings: [ProjectMediaMapping], checkingVolumes: @escaping @MainActor () -> Set<String>,
                      install: (ProjectMediaBatchResult, [ProjectMediaBatchRow], @escaping @MainActor () throws -> Void) async throws -> Bool)
        async throws -> LiveProjectMediaRelinkBatch {
        var pending = mappings
        var failures: [String: String] = [:]
        while true {
            let result = try await relink(pending)
            try Task.checkCancellation()
            let rows = result.rows.filter { $0.candidate.outcome.canRelink }
            for row in result.rows where !row.candidate.outcome.canRelink {
                failures[row.from] = row.candidate.reason ?? "The recording could not be relinked."
            }
            // Install only against the unchanged archive. If a candidate changes
            // during post-probe indexing, rebuild the path map for the survivors.
            do {
                let changed = try await install(result, rows) {
                    let volumes = checkingVolumes()
                    var stale: [String: String] = [:]
                    for row in rows {
                        do {
                            try checkLiveMediaVolume(row.candidate.url, volumes: volumes)
                            try row.candidate.checkGeneration()
                        } catch {
                            stale[row.from] = error.localizedDescription
                        }
                    }
                    if !stale.isEmpty { throw StaleBatchCandidates(failures: stale) }
                }
                return .init(changed: changed, failures: failures, applied: rows.map(\.from))
            } catch let error as StaleBatchCandidates {
                failures.merge(error.failures) { _, latest in latest }
                pending = rows.filter { error.failures[$0.from] == nil }.map { .init(from: $0.from, to: $0.to) }
            }
        }
    }

    func revert(_ from: String) async throws -> ProjectMediaRelinkResult {
        let work = Task.detached(priority: .userInitiated) {
            try ProjectMediaVolume.$checking.withValue(checkingVolumes) {
                try ProjectMedia.revert(project: project, undo: undo, redo: redo, snapshot: snapshot,
                                        relativeTo: documentURL, from: from)
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func url(_ path: String) -> URL {
        let watched = ProjectMediaVolume.watchURL(path, relativeTo: documentURL)
        return checkingVolumes.contains(ProjectMediaVolume.key(for: watched))
            ? watched : CutProject.mediaURL(path, relativeTo: documentURL)
    }

    func absolutePath(_ path: String) -> String {
        path.hasPrefix("/") ? path : url(path).path
    }

    func absoluteHistory(_ states: [CutHistoryState]) -> [CutHistoryState] {
        states.map {
            .init(action: $0.action, origin: $0.origin, project: $0.project.mapMediaPaths(absolutePath),
                  bindingChanges: $0.bindingChanges?.map { $0.mappingPaths(absolutePath) })
        }
    }

    mutating func ignore(_ path: String) throws {
        guard ProjectMedia.references(in: project).contains(where: { url($0.path) == url(path) }) else {
            throw CutError(code: "missing_source", message: "This path does not reference project media.")
        }
        let absolute = url(path).path
        if let index = snapshot.entries.firstIndex(where: { url($0.path).path == absolute }) {
            snapshot.entries[index].ignored = true
        } else {
            var entry = ProjectMediaSnapshot.Entry(path: absolute)
            entry.ignored = true
            snapshot.entries.append(entry)
        }
    }
}

private struct StaleBatchCandidates: Error {
    let failures: [String: String]
}

func checkLiveMediaVolume(_ candidate: URL, volumes: Set<String>) throws {
    guard !volumes.contains(ProjectMediaVolume.key(for: candidate)) else {
        throw CutError(code: "media_volume_checking", message: "The candidate volume is still checking.")
    }
}

struct LiveProjectMediaRelinkBatch {
    let changed: Bool
    let failures: [String: String]
    let applied: [String]
}

func staleLiveProjectMedia() -> CutError {
    CutError(code: "stale_revision", message: "The project changed while the media operation was preparing.")
}

func unavailableLiveProjectMedia() -> CutError {
    CutError(code: "editor_busy", message: "Open a project and wait for the editor to finish its current operation.")
}
