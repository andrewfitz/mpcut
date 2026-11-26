import Foundation
import MPCutCore

/// Describes, measures and clears the on-disk stores listed on the Settings Storage page.
enum StoreKind: String, CaseIterable, Sendable {
    case generatedStills, transcriptRecognition, transcriptJobs, untitledDrafts, suggestedCameras, agentReceipts

    var title: String {
        switch self {
        case .generatedStills: "Generated stills"
        case .transcriptRecognition: "Transcript recognition results"
        case .transcriptJobs: "Transcript job scratch"
        case .untitledDrafts: "Untitled drafts"
        case .suggestedCameras: "Suggested transcript cameras"
        case .agentReceipts: "Agent job receipts"
        }
    }

    var clearable: Bool { [.generatedStills, .transcriptRecognition, .suggestedCameras].contains(self) }

    /// Why the store has no Clear button, or what Clear leaves.
    var note: String {
        switch self {
        case .generatedStills: "Clear skips stills in use."
        case .transcriptRecognition: "Shared with the CLI and Transcriberrr. Clear skips results a transcription is using or a saved transcription job can still reuse."
        case .transcriptJobs: "Guarded by locks and removed after 30 days."
        case .untitledDrafts: "Use File → Recover Untitled Project… to recover or discard drafts."
        case .suggestedCameras: "The camera MPCut suggests for each transcript attachment. Clear forgets the suggestions and changes no transcript."
        case .agentReceipts: "Clearing would break job recovery for a connected agent."
        }
    }

    /// Where a store with no folder of its own keeps its data.
    var storageDescription: String {
        switch self {
        case .suggestedCameras: "Stored in MPCut’s preferences."
        default: ""
        }
    }
}

/// Every root the inventory reads. Tests pass temporary folders; `standard` is the real set.
struct StorageLocations: Sendable {
    var generatedStills: URL?
    var transcriptRecognition: URL?
    /// The desktop's job folder inside the drafts folder, then the CLI's.
    var transcriptJobs: [URL]
    var untitledDrafts: URL
    var agentReceipts: URL

    /// Resolved without creating any folder, so a store not created yet shows as such; once per process, because the
    /// Settings window is rebuilt often and its usage list keeps the locations it started with.
    static let standard = Self(generatedStills: GeneratedStillsStore.defaultDirectory,
             transcriptRecognition: try? TranscriptRecognitionStore.defaultLocation(),
             transcriptJobs: [LiveTranscriptController.jobsDirectory, TranscriptJobStore.defaultDirectory],
             untitledDrafts: ProjectDraft.autosaveDirectory,
             agentReceipts: MCPFileReceipts.standalone.root)

    func urls(for kind: StoreKind) -> [URL] {
        switch kind {
        case .generatedStills: [generatedStills].compactMap { $0 }
        case .transcriptRecognition: [transcriptRecognition].compactMap { $0 }
        case .transcriptJobs: transcriptJobs
        case .untitledDrafts: [untitledDrafts]
        case .suggestedCameras: []
        case .agentReceipts: [agentReceipts]
        }
    }
}

enum StorageInventory {
    /// Matches `EditorPreferences.LocalKey.transcriptSuggestedAngles`.
    static let suggestedCamerasKey = "transcript_suggested_angles"
    private static let draftJobsName = ".transcript-jobs"

    /// Bytes on disk, or the stored value's length for suggested cameras. Runs off the main actor
    /// and throws `CancellationError` when its task is cancelled. Pass the defaults
    /// `TranscriptSuggestedCameras` writes; nil means nothing is stored.
    static func size(of kind: StoreKind, locations: StorageLocations = .standard, defaults: UserDefaults?) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try measure(kind, locations: locations, defaults: defaults)
        }.valueCancellingWithCaller()
    }

    static func measure(_ kind: StoreKind, locations: StorageLocations, defaults: UserDefaults?,
                        cancelled: () -> Bool = { false }) throws -> Int64 {
        switch kind {
        case .suggestedCameras:
            return Int64(defaults?.data(forKey: suggestedCamerasKey)?.count ?? 0)
        case .untitledDrafts:
            // The desktop's transcript jobs are counted under their own store.
            return try StoreMeasurement.allocatedBytes(at: locations.untitledDrafts, excluding: [draftJobsName],
                                                       cancelled: cancelled)
        default:
            return try locations.urls(for: kind).reduce(Int64.zero) {
                $0 + (try StoreMeasurement.allocatedBytes(at: $1, cancelled: cancelled))
            }
        }
    }

    /// Clears a store the table allows. Others return an empty result. Off the main actor.
    static func clear(_ kind: StoreKind, locations: StorageLocations = .standard, defaults: UserDefaults?) async -> StoreClearResult {
        await Task.detached(priority: .utility) {
            clearNow(kind, locations: locations, defaults: defaults)
        }.value
    }

    static func clearNow(_ kind: StoreKind, locations: StorageLocations, defaults: UserDefaults?) -> StoreClearResult {
        switch kind {
        case .generatedStills:
            return locations.generatedStills.map(GeneratedStillsStore.clear(in:)) ?? StoreClearResult()
        case .transcriptRecognition:
            // Results a transcription job can still read back on a retry stay.
            return locations.transcriptRecognition.map { TranscriptRecognitionStore.clear(in: $0, jobs: locations.transcriptJobs) }
                ?? StoreClearResult()
        case .suggestedCameras:
            return clearSuggestedCameras(defaults: defaults)
        case .transcriptJobs, .untitledDrafts, .agentReceipts:
            return StoreClearResult()
        }
    }

    static func clearSuggestedCameras(defaults: UserDefaults?) -> StoreClearResult {
        var result = StoreClearResult()
        guard let defaults, let data = defaults.object(forKey: suggestedCamerasKey) else { return result }
        result.reclaimedBytes = Int64((data as? Data)?.count ?? 0)
        defaults.removeObject(forKey: suggestedCamerasKey)
        return result
    }
}

private extension Task where Failure == Error {
    /// Cancelling the awaiting task cancels the detached one.
    func valueCancellingWithCaller() async throws -> Success {
        try await withTaskCancellationHandler { try await value } onCancel: { cancel() }
    }
}
