import Foundation

public struct ParticipantISORenderMetrics: Codable, Sendable {
    public internal(set) var readerCount = 0
    public internal(set) var decodedPictureRequests = 0
    public internal(set) var picturePasses = 0
    public internal(set) var peakEncoders = 0
    public internal(set) var peakSurfaceBytes = 0
    public internal(set) var estimatedBytes: Int64 = 0

    private enum CodingKeys: String, CodingKey {
        case readerCount = "reader_count", decodedPictureRequests = "decoded_picture_requests", picturePasses = "picture_passes"
        case peakEncoders = "peak_encoders", peakSurfaceBytes = "peak_surface_bytes", estimatedBytes = "estimated_bytes"
    }
}

private struct ParticipantISOJob {
    let session: ParticipantRenderSession
    let output: URL
    let sound: StillSoundPlan
    let container: String
    let settings: ReencodeSettings

    var bytesPerSurface: Int {
        let canvas = session.plan.canvas
        let row = (canvas.width * 4 + 255) / 256 * 256
        return row * canvas.height
    }

    // Very large canvases render singly and use a smaller per-encoder pool.
    var surfaceLimit: Int { min(ParticipantPictureWriter.maximumSurfaces, (512 * 1_024 * 1_024) / bytesPerSurface) }
    var surfaceBytes: Int { bytesPerSurface * surfaceLimit }

    var estimatedMovieBytes: Double {
        let duration = session.timeline.timeline.duration.seconds
        let video = Double(ParticipantPictureWriter.bitRate(session.plan.canvas, quality: settings.quality)) / 8
        return ceil(video * duration * 1.25) + sound.isoEstimatedBytes(duration: session.timeline.timeline.duration)
    }
}

extension StillSoundPlan {
    func isoEstimatedBytes(duration: RationalTime) -> Double {
        let audio = treatments.reduce(0.0) { sum, treatment in
            switch treatment {
            case .convert(let plan):
                return sum + Double(plan.sampleRate) * Double(plan.channels * plan.bytesPerSample)
            case .downmix(let plan):
                return sum + Double(plan.sampleRate) * Double(plan.channels * plan.output.bytesPerSample)
            case .copy:
                return sum + 192_000
            }
        }
        // Include encoder variability and container overhead.
        return ceil(audio * duration.seconds * 1.25) + 65_536
    }
}

extension ParticipantRenderer {
    /// The delivery controls which finished movies are kept after cancellation.
    /// Run under the delivery's lock and checkpoint each publication synchronously.
    @discardableResult
    func renderISOs(_ project: CutProject, document: URL, jobs: [(plan: ParticipantRenderPlan, output: URL)],
                    blankSourceRanges: [MulticamRange] = [], additionalSpace: (file: URL, estimated: Double)? = nil,
                    sharedInputs: ParticipantSharedPictureInputs? = nil,
                    progress: ((Double) -> Bool)? = nil,
                    completed: (Int, ParticipantRenderReport) throws -> Void) throws -> ParticipantISORenderMetrics {
        var metrics = ParticipantISORenderMetrics()
        if jobs.isEmpty {
            if let additionalSpace { metrics.estimatedBytes = try Self.checkISOSpace([additionalSpace]) }
            return metrics
        }
        let interruption = ParticipantRenderInterruption()
        let isCancelled: @Sendable () -> Bool = { [cancelled] in cancelled?() == true || interruption.stopped }
        var lastProgress = 0.0
        func update(_ fraction: Double) -> Bool {
            lastProgress = max(lastProgress, fraction)
            if progress?(lastProgress) == false { interruption.stop() }
            return !isCancelled()
        }

        _ = update(0)
        var slots = Set(jobs.flatMap { $0.plan.shots.flatMap(\.slots) }.filter { $0.target == .participant }.map(\.id))
        if case .multicam(let multicam) = project {
            slots.formUnion(multicam.pictureSources.compactMap { $0.feedAngle?.feedID })
        }
        let inputs = sharedInputs ?? ParticipantSharedPictureInputs(slots: slots)
        let previousReaderCount = inputs.readerCount
        let previousPictureRequests = inputs.decodedPictureRequests
        let plans = try jobs.map { job in
            try project.validateDestination(job.output, relativeTo: document)
            let session = try prepare(project, document: document, plan: job.plan,
                                      cancelled: isCancelled, sharedInputs: inputs)
            session.blankSourceRanges = blankSourceRanges
            let sound = try ParticipantRenderSound.resolve(project, document: document, timeline: session.timeline.timeline,
                                                           audio: session.plan.audio, cancelled: isCancelled)
            try session.requirePublishable(sound: sound)
            try session.verifySources()
            try sound.verifySources()
            let settings = ReencodeSettings(codec: session.color == .sdr ? .h264 : .hevc)
            let container = try Self.validateDestination(job.output, hasAudio: !sound.actions.isEmpty,
                                                         settings: settings, color: session.color)
            return ParticipantISOJob(session: session, output: job.output, sound: sound, container: container,
                                     settings: settings)
        }
        // Picture intermediates coexist with finished movies and with the current soundtrack/mux.
        var space = plans.map { (file: $0.output, estimated: $0.estimatedMovieBytes) }
        if let additionalSpace { space.append(additionalSpace) }
        metrics.estimatedBytes = try Self.checkISOSpace(space)

        func progressFor(_ index: Int, _ movies: Int, _ fraction: Double) -> Bool {
            update((Double(index) + Double(movies) * fraction) / Double(plans.count))
        }

        func renderBatch(_ range: Range<Int>) throws {
            let group = plans[range]
            let directories: [URL]
            var created: [URL] = []
            defer { for item in created { try? FileManager.default.removeItem(at: item) } }
            for job in group { created.append(try Self.stagingDirectory(for: job.output)) }
            directories = created
            let pictures = directories.map { $0.appendingPathComponent("picture.mov") }

            inputs.resetReaders()
            do {
                defer { inputs.resetReaders() }
                var writers: [ParticipantPictureWriter] = []
                writers.reserveCapacity(group.count)
                var surfaceBytes = 0
                for (job, picture) in zip(group, pictures) {
                    writers.append(try ParticipantPictureWriter(session: job.session, file: picture,
                        settings: job.settings, surfaceLimit: job.surfaceLimit))
                    surfaceBytes += job.surfaceBytes
                    metrics.peakEncoders = max(metrics.peakEncoders, writers.count)
                    metrics.peakSurfaceBytes = max(metrics.peakSurfaceBytes, surfaceBytes)
                }
                // Every job uses the same unscoped edit and this batch shares its cadence.
                let clock = group.first!.session
                let frames = clock.frameCount
                let stride = max(1, frames / 1_000)
                let frameInputs = writers.count > 1 ? ParticipantISOFrameInputs() : nil
                metrics.picturePasses += 1
                for frame in 0..<frames {
                    let timing = try clock.frameTiming(at: frame)
                    for writer in writers { try writer.append(timing, frameInputs: frameInputs) }
                    frameInputs?.reset()
                    if (frame + 1).isMultiple(of: stride) || frame + 1 == frames {
                        _ = progressFor(range.lowerBound, range.count, 0.85 * Double(frame + 1) / Double(frames))
                    }
                }
                inputs.resetReaders()
                let finishes = try writers.map { try $0.beginFinish() }
                for (writer, finish) in zip(writers, finishes) { try writer.waitForFinish(finish) }
            } catch let error as CutError where range.count > 1 && error.code == "participant_encode_failed" {
                for item in created { try FileManager.default.removeItem(at: item) }
                created.removeAll()
                let middle = range.lowerBound + range.count / 2
                try renderBatch(range.lowerBound..<middle)
                try renderBatch(middle..<range.upperBound)
                return
            }

            for (offset, index) in range.enumerated() {
                let job = plans[index]
                let report = try job.session.publishPicture(pictures[offset], sound: job.sound, staging: directories[offset],
                    output: job.output, container: job.container, cancelled: isCancelled) {
                        let finished = (Double(offset) + $0) / Double(range.count)
                        return progressFor(range.lowerBound, range.count, 0.85 + 0.15 * finished)
                    }
                try completed(index, report)
                try FileManager.default.removeItem(at: directories[offset])
            }
        }

        // Bound the compositor's input pixel surfaces separately from codec and decoder memory.
        let budget = 192 * 1_024 * 1_024
        var first = 0
        var bytes = 0
        for index in plans.indices {
            let plan = plans[index]
            let firstPlan = plans[first]
            if index > first && (bytes + plan.surfaceBytes > budget ||
                plan.session.cadence != firstPlan.session.cadence || plan.session.frameCount != firstPlan.session.frameCount) {
                try renderBatch(first..<index)
                first = index
                bytes = 0
            }
            bytes += plan.surfaceBytes
        }
        try renderBatch(first..<plans.count)
        metrics.readerCount = inputs.readerCount - previousReaderCount
        metrics.decodedPictureRequests = inputs.decodedPictureRequests - previousPictureRequests
        return metrics
    }

    private static func checkISOSpace(_ jobs: [(file: URL, estimated: Double)]) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeAvailableCapacityKey]
        var volumes: [AnyHashable: (estimated: Double, largest: Double, available: Int64)] = [:]
        for job in jobs {
            let directory = job.file.standardizedFileURL.deletingLastPathComponent()
            let values = try directory.resourceValues(forKeys: keys)
            guard let identifier = values.volumeIdentifier as? AnyHashable, let capacity = values.volumeAvailableCapacity else { continue }
            let previous = volumes[identifier]
            let bytes = job.estimated
            volumes[identifier] = ((previous?.estimated ?? 0) + bytes,
                                   max(previous?.largest ?? 0, bytes), Int64(capacity))
        }
        for volume in volumes.values {
            let required = volume.estimated + 2 * volume.largest
            guard required <= Double(volume.available) else {
                let formatted = ByteCountFormatter.string(fromByteCount: Int64(min(required, Double(Int64.max / 2))),
                                                         countStyle: .file)
                throw CutError(code: "insufficient_disk_space", message: "ISO export needs about \(formatted) of available space.")
            }
        }
        return Int64(min(jobs.reduce(0.0) { $0 + $1.estimated }, Double(Int64.max / 2)))
    }
}
