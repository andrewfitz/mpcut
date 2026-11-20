import AVFoundation

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
