import Foundation

/// This receipt is bound to the worker's cancellation token, even when its document revision changes.
struct MCPNativeOperation {
    let id: UUID
    let kind: String
    let label: String
    let progress: Double?
    let cancelling: Bool

    var state: [String: Any] {
        var result: [String: Any] = ["nativeOperation": id.uuidString, "kind": kind,
                                      "label": label, "state": cancelling ? "cancelling" : "running"]
        result["progress"] = progress
        return result
    }
}

extension ProjectSession {
    var activeMCPWorker: MCPNativeOperation? {
        isMulticam ? multicam.activeNativeOperation : editor.activeNativeOperation
    }

    func cancelMCPWorker(_ worker: MCPNativeOperation) {
        guard activeMCPWorker?.id == worker.id else { return }
        if isMulticam { multicam.cancel() }
        else if worker.kind == "import" { editor.cancelImport() }
        else { editor.cancelExport() }
    }
}

@MainActor
extension ProjectSessions {
    func mcpNativeOperations(tool: String, arguments: [String: Any], session: ProjectSession?) throws -> [String: Any] {
        let worker = session?.activeMCPWorker
        let sidecars = session.flatMap { $0.isMulticam ? nil : $0.editor.nativeSidecarSave }
        let conversion = conversionOwner == session?.mcpHandle ? projectConversion.map {
            MCPNativeOperation(id: $0.id, kind: "conversion", label: "Project conversion", progress: nil,
                               cancelling: $0.isCancelled)
        } : nil
        if tool == "get_native_operations" {
            return ["operations": [worker, sidecars, conversion].compactMap { $0?.state }]
        }
        guard let raw = arguments["nativeOperation"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPFailure("invalid_arguments", "Supply a native operation ID from get_native_operations.")
        }
        if id == conversion?.id {
            cancelProjectConversion()
        } else if let session, let worker, worker.id == id {
            session.cancelMCPWorker(worker)
        } else if let session, id == sidecars?.id {
            session.editor.cancelNativeSidecarSave(id: id)
        } else {
            throw MCPFailure("operation_ended", "This native operation is no longer active in the requested scope.")
        }
        return ["nativeOperation": id.uuidString, "cancellationRequested": true]
    }
}
