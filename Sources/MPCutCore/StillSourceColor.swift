import Foundation

extension StillProgramColorPolicy {
    /// Resolves the image rendition against the camera's presentation description.
    /// Untagged conventional SDR recordings use a BT.709 limited-range reference.
    public static func resolving(source: StreamInfo) throws -> Self {
        let transfer = specified(source.colorTransfer)
        let primaries = specified(source.colorPrimaries)
        let matrix = specified(source.colorMatrix)
        let range = specified(source.colorRange)
        let hdrTransfer = transfer == "smpte2084" || transfer == "arib-std-b67"
        let wide = primaries == "bt2020" || matrix?.hasPrefix("bt2020") == true
        let possibleHDR = source.bitDepth >= 10 && ["hevc", "av1", "vp9"].contains(source.codec)
        if hdrTransfer {
            guard source.bitDepth >= 10, primaries == "bt2020",
                  matrix == "bt2020nc" || matrix == "bt2020c", range != nil else { throw ambiguousColor() }
        } else if transfer == nil && (wide || possibleHDR) {
            throw ambiguousColor()
        }
        return Self(transfer: transfer ?? "bt709", primaries: primaries ?? "bt709",
                    matrix: matrix ?? "bt709", range: range ?? (source.pixelFormat.hasPrefix("yuvj") ? "pc" : "tv"),
                    viewingConditions: hdrTransfer ? "Rec.2100 reference" : "rec709-reference",
                    diffuseWhiteNits: hdrTransfer ? 203 : 100)
    }

    /// Copy-oriented interpretation may fill missing tags, but may not contradict camera signaling.
    public func validateSourceCompatibility(_ source: StreamInfo) throws {
        let fields = [(source.colorTransfer, transfer), (source.colorPrimaries, primaries),
                      (source.colorMatrix, matrix), (source.colorRange, range)]
        guard fields.allSatisfy({ signal, target in
            Self.specified(signal).map { $0 == target } ?? true
        }) else {
            throw CutError(code: "incompatible_still_color",
                           message: "The stored program color policy contradicts the retained camera description. Use a compatible interpretation or convert the program.")
        }
        if ["smpte2084", "arib-std-b67"].contains(transfer) {
            guard source.bitDepth >= 10, primaries == "bt2020",
                  matrix == "bt2020nc" || matrix == "bt2020c",
                  ["tv", "pc"].contains(range) else { throw Self.ambiguousColor() }
        }
    }

    private static func specified(_ value: String) -> String? {
        ["", "unknown", "unspecified", "reserved"].contains(value) ? nil : value
    }

    private static func ambiguousColor() -> CutError {
        CutError(code: "ambiguous_still_color",
                 message: "The camera color signaling cannot establish an HDR or SDR rendition. Set an explicit interpretation before generating matching still picture.")
    }
}
