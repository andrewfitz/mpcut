import Foundation
import MachO
import MPCutCore

struct CLIVersion: Encodable {
    struct DetectorCapabilities: Encodable {
        let participantAnalysis = ParticipantAnalysis.isAvailable
        let standaloneFixedGrid = true
        let autoFeedLayout = ParticipantAnalysis.supportsFeedLayouts
        let galleryGrid = ParticipantAnalysis.supportsGalleryHint
        let adaptiveSampling = ParticipantAnalysis.supportsAdaptiveSampling
        let autoBackend = true
        let cpuOnlyBackend = true
        let gpuRequiredBackend = ParticipantAnalysis.isGPUBackendAvailable
    }

    let version = Arguments.version
    let buildID: String
    let projectSchemaVersions = [CutProject.schemaVersion]
    let detectorCapabilities = DetectorCapabilities()

    init() throws {
        buildID = try Self.readBuildID()
    }

    static func readBuildID() throws -> String {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else {
            throw CLIError("build_identity_unavailable", "Could not read the CLI build UUID.")
        }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_UUID {
                let uuid = command.load(as: uuid_command.self).uuid
                return UUID(uuid: uuid).uuidString.lowercased()
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        throw CLIError("build_identity_unavailable", "Could not read the CLI build UUID.")
    }
}
