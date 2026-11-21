import AppKit
import MPCutCore

extension MulticamEditorModel {
    var canExportStillFrame: Bool { !isBusy && !(mapping?.picture.isEmpty ?? true) }

    func chooseStillFrame() {
        guard canExportStillFrame, let window, let project, let mapping else { return }
        preview.pause()
        do {
            let position = try MulticamStillPosition.at(preview.currentTime(), in: mapping)
            guard let angle = project.angles.first(where: { $0.id == position.angle }) else {
                throw CutError(code: "no_frame", message: "No camera is selected at the playhead.")
            }
            let indexed = media[angle.id]
            if let indexed, indexed.hasFullEditIndex {
                _ = try JPEGExport.stillFrameTime(in: indexed, at: position.sourceTime, exclusiveEnd: position.exclusiveEnd)
            }
            let url = indexed?.url ?? projectURL.map { project.sourceURL(for: angle, relativeTo: $0) }
                ?? URL(fileURLWithPath: angle.file)
            let options = StillFrameSaveOptions()
            let panel = options.panel(source: url, directory: projectURL?.deletingLastPathComponent())
            ProjectPanels.present(panel, in: window) { [weak self, options] accepted in
                guard let self, accepted, let output = panel.url, self.project == project, self.mapping == mapping else { return }
                let confirmed = options.confirmedDestination(at: output)
                self.run("Exporting current frame…", exporting: true) { token, sidecar in
                    let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: sidecar)
                    let source = try indexed.flatMap { $0.hasFullEditIndex ? $0 : nil } ?? engine.inspectMulticamSource(url)
                    if let indexed, indexed.identity != source.identity {
                        throw CutError(code: "source_changed", message: "Relink the changed camera recording.")
                    }
                    try JPEGExport.writeStill(source, at: position.sourceTime, to: output, replacing: confirmed,
                                              exclusiveEnd: position.exclusiveEnd, cancelled: { token.isCancelled })
                } onSuccess: { self.status = "Exported " + output.lastPathComponent }
            }
        } catch { notice = Notice(title: "Export Current Frame", message: error.localizedDescription) }
    }

    func chooseJPEGExport() {
        guard !isBusy, let window, let project else { return }
        preview.pause()
        let outputTime = preview.currentTime()
        // An end handle is exclusive. Review the held outgoing picture at a parked endpoint.
        let position = outputTime == preview.duration
            ? max(.zero, (try? outputTime.subtracting(RationalTime(numerator: 1, denominator: 1_000_000_000))) ?? outputTime)
            : outputTime
        let group = groupTime(at: position)
        guard let selection = project.selection(at: group),
              let angle = project.angles.first(where: { $0.id == selection.angle }) else { return }

        let options = JPEGExportOptions(preset: preferences.jpegPreset)
        let url = projectURL.map { project.sourceURL(for: angle, relativeTo: $0) }
            ?? URL(fileURLWithPath: angle.file)
        let source = ordinaryAnalysisMedia(angle.id)
        let stream = angle.audioStream ?? media[angle.id]?.streams.first(where: { $0.kind == "audio" })?.index
        let panel = options.panel(source: url, directory: projectURL?.deletingLastPathComponent(),
                                  hasAudio: stream != nil, multicam: true)
        ProjectPanels.present(panel, in: window) { [weak self] accepted in
            guard let self, accepted, let directory = panel.url, self.project == project else { return }
            do {
                let limit = try options.frameLimit()
                let preset = options.preset, sample = options.sample, mode = options.mode
                let times = options.allSwitches ? project.switches.map(\.at) : [group]
                let indexed = self.media, document = self.projectURL
                let minimum = self.preferences.minimumPause
                let analysis = source.map(self.analysis.snapshot(for:))
                let threshold = stream.flatMap { self.analysis.threshold(for: .init(source: angle.id, stream: $0)) }
                self.run("Exporting JPEG frames…", exporting: true) { token, useSidecar in
                    let cancelled: @Sendable () -> Bool = { token.isCancelled }
                    if mode == .playhead {
                        let manifest = try JPEGExport.writeMulticam(project, document: document, at: times,
                            to: directory, preset: preset, useSidecar: useSidecar, indexedSources: indexed,
                            cancelled: cancelled)
                        return manifest.frames.filter { $0.file != nil }.count
                    }
                    let media = try source ?? CutEngine(cancelled: cancelled, useSidecar: useSidecar).inspect(url, keyframes: true)
                    if let expected = indexed[angle.id], media.identity != expected.identity {
                        throw CutError(code: "source_changed", message: "Relink the changed camera recording before exporting frames.")
                    }
                    let selection: JPEGSelection
                    if mode == .scenes {
                        selection = analysis?.scenes.map(JPEGSelection.sceneReport) ?? .scenes
                    } else if let result = analysis?.silence.first(where: { $0.stream == stream && $0.minimum == minimum }),
                              try media.extendingToAudioEnd(stream: result.stream).duration == media.duration {
                        selection = .audibleRanges(pauses: result.pauses, stream: result.stream,
                                                   thresholdDB: result.thresholdDB, minimumPause: minimum)
                    } else {
                        selection = .nonSilent(stream: stream, thresholdDB: threshold, minimumPause: minimum)
                    }
                    return try JPEGExport.write(media, to: directory, selection: selection, sample: sample,
                        preset: preset, limit: limit, useSidecar: useSidecar, cancelled: cancelled).frames.count
                } onSuccess: { count in
                    self.status = "Exported \(count) JPEG frames to \(directory.lastPathComponent)."
                }
            } catch { self.notice = Notice(title: "Export JPEG Frames", message: error.localizedDescription) }
        }
    }
}

struct MulticamStillPosition: Equatable, Sendable {
    let angle: String
    let sourceTime: RationalTime
    let exclusiveEnd: Bool

    static func at(_ time: RationalTime, in plan: MulticamPlan) throws -> Self {
        let exclusiveEnd = time == plan.duration
        let index = plan.picture.lowerBound { $0.output.to > time } - (exclusiveEnd ? 1 : 0)
        guard plan.picture.indices.contains(index) else {
            throw CutError(code: "no_frame", message: "No camera picture covers the playhead.")
        }
        let span = plan.picture[index]
        guard span.output.from <= time, exclusiveEnd ? time == span.output.to : time < span.output.to else {
            throw CutError(code: "no_frame", message: "No camera picture covers the playhead.")
        }
        let sourceTime = try span.input.from.adding(time.subtracting(span.output.from))
        return Self(angle: span.source, sourceTime: sourceTime, exclusiveEnd: exclusiveEnd)
    }
}
