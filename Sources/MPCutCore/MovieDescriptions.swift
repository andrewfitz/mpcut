import AVFoundation

// A MOV sample description can change more than the codec parameter sets.
// Compare the native display properties and the remaining sample-entry atoms
// before passing configuration switches through a copy export.
func matchingMovieDescriptions(url: URL, trackID: CMPersistentTrackID) -> Bool {
    let asset = AVURLAsset(url: url)
    guard let track = asset.track(withTrackID: trackID), track.mediaType == .video else { return false }
    let descriptions = track.formatDescriptions as! [CMVideoFormatDescription]
    guard descriptions.count > 1, let first = descriptions.first else { return false }

    func properties(_ description: CMVideoFormatDescription) -> NSDictionary {
        let type = CMFormatDescriptionGetMediaSubType(description)
        var values = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        values.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription as String)
        values.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry as String)
        let atomKey = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
        var atoms = values[atomKey] as? [String: Any] ?? [:]
        atoms.removeValue(forKey: type == kCMVideoCodecType_H264 ? "avcC" : "hvcC")
        atoms.removeValue(forKey: "btrt")
        values[atomKey] = atoms
        // Both omitted properties have explicit video-format defaults.
        let fullRange = kCMFormatDescriptionExtension_FullRangeVideo as String
        values[fullRange] = values[fullRange] ?? false
        let aspect = kCMFormatDescriptionExtension_PixelAspectRatio as String
        if values[aspect] == nil {
            values[aspect] = [kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: 1,
                              kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: 1]
        }
        return values as NSDictionary
    }

    let fields = properties(first)
    let type = CMFormatDescriptionGetMediaSubType(first)
    let dimensions = CMVideoFormatDescriptionGetDimensions(first)
    return descriptions.dropFirst().allSatisfy { description in
        let current = CMVideoFormatDescriptionGetDimensions(description)
        return CMFormatDescriptionGetMediaSubType(description) == type &&
            current.width == dimensions.width && current.height == dimensions.height &&
            fields.isEqual(properties(description))
    }
}
