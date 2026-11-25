import Foundation

package enum MediaExportPublication {
    @TaskLocal package static var validate: (@Sendable (URL) throws -> Void)?

    static func publish(from staged: URL, to destination: URL) throws -> Int32 {
        try validate?(destination)
        return publishExclusively(from: staged, to: destination)
    }
}
