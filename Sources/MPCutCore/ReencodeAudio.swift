import AVFoundation

extension ExportRules {
    /// The source format of one output track, from the streams of every clip that has it. The codec is kept only when
    /// every stream shares it with the same sample rate, channel layout, word length (FLAC and ALAC) and AAC profile.
    static func automaticAudioSource(_ streams: [StreamInfo]) -> AutomaticAudioSource? {
        guard let first = streams.first else { return nil }
        let layouts = streams.map { (try? audioLayout($0)) ?? $0.channelLayout }
        let depths = streams.map(AudioExportEngine.declaredDepth)
        let profiles = streams.map(AudioExportEngine.highEfficiencyProfile)
        let lossless = streams.allSatisfy { isLosslessAudio(codec: $0.codec) }
        let shared = streams.allSatisfy { $0.codec == first.codec && $0.sampleRate == first.sampleRate && $0.channels == first.channels }
            && layouts.allSatisfy { $0 == layouts[0] } && profiles.allSatisfy { $0 == profiles[0] }
            && (!["flac", "alac"].contains(first.codec) || depths.allSatisfy { $0 == depths[0] })
        return AutomaticAudioSource(codec: shared ? first.codec : nil, lossless: lossless,
                                    integerDepth: ["flac", "alac"].contains(first.codec) ? depths[0] : nil,
                                    sampleRate: first.sampleRate, channels: first.channels, layout: layouts[0],
                                    highEfficiency: profiles[0])
    }
}

extension ReencodeAudioAction {
    /// States what a FLAC, ALAC, MP3 or Opus track that keeps its source format writes: the codec, its word length or
    /// rate, and the encoder options. The rate follows the sources as a sound-only conversion to the same format does.
    mutating func describeSourceFormat(_ sources: [(media: MediaInfo, audio: AudioIndex)], channels: Int, sampleRate: Int) {
        switch action {
        case .flac, .alac:
            let depth = sources.compactMap { AudioExportEngine.declaredDepth($0.audio.stream) }.max() ?? 24
            let written = depth <= 16 ? 16 : 24
            codec = action.rawValue
            bitDepth = written
            let format = written == 16 ? "s16" : "s32"
            // A fixed block size, as in a sound-only conversion: a range can start with a very short decoded frame.
            encoderOptions = ["-sample_fmt", action == .alac ? format + "p" : format, "-bits_per_raw_sample", "\(written)"]
                + (action == .flac ? ["-frame_size", "4608"] : [])
        case .mp3:
            let profiles = sources.compactMap { MP3Profile(media: $0.media, sound: $0.audio)?.asConstant }
            let chosen = MP3Profile.encoding(matching: profiles.count == sources.count ? profiles : [],
                                             sampleRate: sampleRate, channels: channels)
            codec = "mp3"
            bitRate = chosen.bitRate
            quality = chosen.quality
            encoderOptions = chosen.arguments.map { $0 == "-b:a" ? "-b" : $0 == "-q:a" ? "-q" : $0 }
        case .opus:
            let measured = sources.compactMap(\.audio.averageBitRate)
            let rate = AudioExportEngine.opusBitRate(matching: measured.count == sources.count ? measured.max() : nil, channels: channels)
            codec = "opus"
            bitRate = rate
            // Unconstrained libopus VBR can miss the target by a third. Surround needs a named mapping family.
            encoderOptions = ["-b", "\(rate)", "-vbr", "constrained"] + (channels > 2 ? ["-mapping_family", "1"] : [])
        default:
            break
        }
    }
}

/// The encoder and options of a FLAC, ALAC, MP3 or Opus track, with the stream specifier of output track `index`.
func sourceFormatOptions(_ planned: ReencodeAudioAction, outputIndex index: Int) -> [String]? {
    let encoder: String
    switch planned.action {
    case .flac: encoder = "flac"
    case .alac: encoder = "alac"
    case .mp3: encoder = "libmp3lame"
    case .opus: encoder = "libopus"
    default: return nil
    }
    var args = ["-c:a:\(index)", encoder]
    for option in planned.encoderOptions ?? [] {
        args.append(option.hasPrefix("-") ? "\(option):a:\(index)" : option)
    }
    return args
}

/// The bundled FFmpeg 9.0.2 MOV muxer stores the final Opus packet with its trimmed duration, so the edit list ends
/// where that shortened sample does and readers (FFmpeg and AVFoundation) decode the encoder's padding after the
/// planned end, up to 19 ms. With the packet's coded 20 ms duration the edit list ends inside it, as FFmpeg 9.1 writes
/// it. libopus codes 20 ms frames, 960 samples at Opus's 48 kHz clock, unless told otherwise.
func opusTailOptions(container: String, specifier: String) -> [String] {
    guard ["mov", "mp4", "m4a"].contains(container) else { return [] }
    return ["-bsf:\(specifier)", "setts=duration=if(lt(DURATION\\,960)\\,960\\,DURATION)"]
}

/// The PCM format a converted track takes between export batches. Compressed tracks are encoded once in the final mux:
/// lossless ones are staged as 32-bit integers, which hold their samples exactly, and lossy ones as 32-bit float.
func stagedAudioCodec(_ planned: ReencodeAudioAction) -> String? {
    switch planned.action {
    case .flac, .alac: return "pcm_s32le"
    case .aac, .mp3, .opus: return "pcm_f32le"
    default: return nil
    }
}

extension ReencodeEngine {
    // FFmpeg's MOV demuxer can expose hidden AAC decoder history as audible
    // packets in empty edits. AVAssetReader renders the presentation edits.
    func stageEditedAudio(_ source: URL, track: StreamInfo, source samples: Range<Int64>,
                          count: Int64, to destination: URL, segment: Int) throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        func failure(_ reason: String) -> CutError {
            CutError(code: "audio_conversion_failed", message: reason, segment: segment, track: track.index)
        }
        guard let audio = asset.track(withTrackID: track.trackID), audio.mediaType == .audio else {
            throw failure("The source AAC track is unavailable for rendering its presentation edits.")
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw failure(error.localizedDescription) }
        let clock = CMTimeScale(track.sampleRate)
        reader.timeRange = CMTimeRange(start: CMTime(value: samples.lowerBound, timescale: clock),
                                       end: CMTime(value: samples.upperBound, timescale: clock))
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw failure("Could not configure the source AAC reader.") }
        reader.add(output)
        guard reader.startReading() else {
            throw failure(reader.error?.localizedDescription ?? "Could not start the source AAC reader.")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        try checkCancellation()
        guard let first = output.copyNextSampleBuffer() else {
            throw failure(reader.error?.localizedDescription ?? "The source AAC reader returned no audible samples.")
        }
        guard let format = CMSampleBufferGetFormatDescription(first),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mSampleRate == Double(track.sampleRate),
              description.pointee.mChannelsPerFrame == track.channels,
              description.pointee.mBytesPerFrame == track.channels * MemoryLayout<Float>.size else {
            throw failure("The AAC decoder changed the source sample rate or channel count.")
        }
        var file: AudioFileID?
        var status = AudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, description, [], &file)
        guard status == noErr, let file else { throw failure("Could not create the staged PCM track (\(status)).") }
        var needsClose = true
        defer { if needsClose { AudioFileClose(file) } }
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize) {
            status = AudioFileSetProperty(file, kAudioFilePropertyChannelLayout, UInt32(layoutSize), layout)
            guard status == noErr else { throw failure("Could not preserve the PCM channel layout (\(status)).") }
        } else if track.channels > 2 {
            throw failure("The AAC decoder did not provide a multichannel audio layout.")
        }

        let bytesPerFrame = Int(description.pointee.mBytesPerFrame)
        let silence = Data(count: 8_192 * bytesPerFrame)
        var written: Int64 = 0
        func write(_ data: Data) throws {
            var length = UInt32(data.count)
            let status = data.withUnsafeBytes { bytes in
                AudioFileWriteBytes(file, false, written * Int64(bytesPerFrame), &length, bytes.baseAddress!)
            }
            guard status == noErr, length == data.count else {
                throw failure("Could not write the staged PCM track (\(status)).")
            }
            written += Int64(data.count / bytesPerFrame)
        }
        func pad(until end: Int64) throws {
            while written < end {
                try checkCancellation()
                let frames = Int(min(end - written, 8_192))
                try write(silence.prefix(frames * bytesPerFrame))
            }
        }
        var next: CMSampleBuffer? = first
        while let sample = next, written < count {
            try checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).convertScale(clock, method: .roundHalfAwayFromZero)
            guard pts.isNumeric, let buffer = CMSampleBufferGetDataBuffer(sample) else {
                throw failure("The AAC decoder returned an invalid PCM sample buffer.")
            }
            let offset = pts.value - samples.lowerBound
            try pad(until: min(count, offset))
            let skip = written - offset
            let frames = min(count - written, Int64(CMSampleBufferGetNumSamples(sample)) - skip)
            if frames > 0 {
                var data = Data(count: Int(frames) * bytesPerFrame)
                let result = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(buffer, atOffset: Int(skip) * bytesPerFrame,
                                               dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                guard result == kCMBlockBufferNoErr else { throw failure("Could not read the decoded PCM samples.") }
                try write(data)
            }
            next = written < count ? output.copyNextSampleBuffer() : nil
        }
        guard written == count || reader.status == .completed else {
            throw failure(reader.error?.localizedDescription ?? "Could not finish reading the source AAC track.")
        }
        try pad(until: count)
        status = AudioFileClose(file)
        needsClose = false
        guard status == noErr else { throw failure("Could not close the staged PCM track (\(status)).") }
    }
}
