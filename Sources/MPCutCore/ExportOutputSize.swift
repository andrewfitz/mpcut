import Foundation

public enum ExportOutputSize {
    /// Reads the logical length of the published media file, including container overhead.
    public static func bytes(at output: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}
