import Foundation

/// The CLI, file jobs, and live control accept the same nested request JSON.
public enum TranscriptRequestJSON {
    // A range's `from` and `to` are read as written. Ranges decode from time strings, and
    // rewriting them would make a match override that names its observation undecodable.
    private static let timeKeys: Set<String> = [
        "offset", "position", "leading_padding", "trailing_padding", "retained_duration", "sequence_clock_origin"
    ]

    /// Convert time strings such as `"1/4"` to exact rational objects and fill an omitted binding offset.
    public static func normalize(_ value: Any, key: String) throws -> Any {
        // TranscriptJobOptions decodes this map itself. Its keys are caller-supplied track IDs.
        if key == "track_options" { return value }
        if let text = value as? String {
            if timeKeys.contains(key) {
                let time = try RationalTime(parsing: text)
                return ["numerator": time.numerator, "denominator": time.denominator]
            }
            return text
        }
        if let list = value as? [Any] {
            return try list.map { try normalize($0, key: key) }
        }
        guard let object = value as? [String: Any] else { return value }
        var normalized = [String: Any]()
        for (key, child) in object { normalized[key] = try normalize(child, key: key) }
        if key == "bindings", normalized["offset"] == nil {
            normalized["offset"] = ["numerator": 0, "denominator": 1]
        }
        return normalized
    }
}
