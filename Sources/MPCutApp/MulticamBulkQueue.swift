import AppKit
import MPCutCore
import SwiftUI

struct MulticamQueuedRange: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let range: MulticamRange
    let project: MulticamProject
    let media: [String: MediaInfo]
}

struct MulticamBulkExport: Sendable {
    struct Item: Sendable {
        let output: URL
        let plan: MulticamExportPlan
    }

    let items: [Item]

    init(ranges: [MulticamQueuedRange], directory: URL, container: String,
         mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings,
         engine: MulticamEngine) throws {
        items = try ranges.enumerated().map { index, entry in
            let suffix = String(format: "%03ld", index + 1)
            let output = directory.appendingPathComponent("\(entry.name)-\(suffix)", isDirectory: false)
                .appendingPathExtension(container)
            do {
                let plan = try engine.resolve(entry.project, output: output, mode: mode, tracks: tracks,
                                              assembly: [entry.range], settings: settings,
                                              indexedSources: entry.media)
                return Item(output: output, plan: plan)
            } catch let issue as CutError {
                throw CutError(code: issue.code, message: "Range \(index + 1): \(issue.message)")
            }
        }
    }
}

extension MulticamEditorModel {
    private var markedExportRange: MulticamRange? {
        guard let project, let marks = markedGroupSpan,
              marks.from >= project.range.from, marks.to <= project.range.to else { return nil }
        return MulticamRange(from: marks.from, to: marks.to)
    }

    var canEnqueueMarkedRange: Bool { !isBusy && markedExportRange != nil }
    var canShowBulkQueue: Bool { !isBusy && project != nil }

    func enqueueMarkedRange() {
        guard let range = markedExportRange, enqueueRanges([range]) else { return }
        markIn = nil
        markOut = nil
    }

    @discardableResult
    func enqueueRanges(_ ranges: [MulticamRange]) -> Bool {
        guard !isBusy, let project, !ranges.isEmpty else { return false }
        do {
            let name = projectName ?? "Multicam"
            _ = try project.plan(ranges: ranges)
            let entries = ranges.map { range in
                MulticamQueuedRange(name: name, range: range, project: project, media: media)
            }
            queuedRanges.append(contentsOf: entries)
            status = "Added \(entries.count) \(entries.count == 1 ? "range" : "ranges") to the export queue."
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    func removeQueuedRange(_ id: UUID) {
        guard !isExporting else { return }
        queuedRanges.removeAll { $0.id == id }
        reconcileSourceLoads()
    }

    func showBulkQueue() {
        guard canShowBulkQueue else { return }
        preview.pause()
        isBulkQueuePresented = true
    }

    func resetExportQueue() {
        queuedRanges.removeAll()
        isBulkQueuePresented = false
        isReplacementAudioPresented = false
        bulkExportDirectory = nil
    }

    func chooseBulkDestination(container: String, mode: ExportMode, tracks: ExportTracks, settings: ReencodeSettings) {
        guard isBulkQueuePresented, !queuedRanges.isEmpty, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Queued Ranges"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = bulkExportDirectory
        ProjectPanels.present(panel, in: window, fromSheet: true) { [weak self] accepted in
            guard let self, self.isBulkQueuePresented, accepted, let directory = panel.url else { return }
            self.exportQueuedRanges(to: directory, container: container, mode: mode, tracks: tracks, settings: settings)
        }
    }

    func exportQueuedRanges(to directory: URL, container: String, mode: ExportMode,
                            tracks: ExportTracks, settings: ReencodeSettings = .init()) {
        guard !queuedRanges.isEmpty, !isBusy else { return }
        bulkExportDirectory = directory
        isBulkQueuePresented = false
        let ranges = queuedRanges
        let protected = protectedMediaPaths
        run("Exporting queued multicam ranges…", exporting: true) { [weak self] token, useSidecar in
            try AnalysisSidecar.$readsEnabled.withValue(useSidecar) {
                let engine = MulticamEngine(cancelled: { token.isCancelled })
                let batch = try MulticamBulkExport(ranges: ranges, directory: directory, container: container,
                                                  mode: mode, tracks: tracks, settings: settings, engine: engine)
                for item in batch.items {
                    try CutProject.validateMediaDestination(item.output, absoluteSources: protected)
                }
                for (index, item) in batch.items.enumerated() {
                    do {
                        try engine.write(item.plan, to: item.output) { [weak self] fraction in
                            let progress = (Double(index) + fraction) / Double(batch.items.count)
                            Task { @MainActor [weak self] in self?.updateExportProgress(token, fraction: progress) }
                        }
                    } catch {
                        throw CutError(code: "bulk_interrupted", message: "Wrote \(index) of \(ranges.count) files. "
                                       + "Range \(index + 1): \(error.localizedDescription)")
                    }
                }
                return batch.items.count
            }
        } onSuccess: { count in
            self.status = "Exported \(count) \(count == 1 ? "file" : "files") to \(directory.lastPathComponent)."
        }
    }
}

struct MulticamBulkQueueView: View {
    @ObservedObject var model: MulticamEditorModel
    @State private var tracks: ExportTracks = .all
    @State private var mode: ExportMode
    @State private var container = "mov"
    @State private var codec: ReencodeCodec = .h264
    @State private var audio: ReencodeAudio = .copyOriginal
    @State private var quality: ReencodeQuality = .balanced
    @State private var proResQuality: ReencodeQuality = .prores422

    init(model: MulticamEditorModel) {
        self.model = model
        _mode = State(initialValue: model.preferences.defaultExportMode)
    }

    private var effectiveMode: ExportMode { tracks == .all ? mode : .copy }
    private var isProResExport: Bool { effectiveMode == .encode && codec == .prores }
    private var availableAudio: [ReencodeAudio] {
        var actions: [ReencodeAudio] = [.copyOriginal]
        if container != "mkv" { actions.append(.aac) }
        if container != "mp4" { actions.append(.pcm) }
        actions.append(.removeAudio)
        return actions
    }

    var body: some View {
        EditorSheet(title: "Export Queue", message: queueSummary(model.queuedRanges.map { ($0.range.from, $0.range.to) })) {
            if model.queuedRanges.isEmpty {
                ExportQueueEmptyState()
            } else {
                ExportQueueList(count: model.queuedRanges.count) {
                    ForEach(Array(model.queuedRanges.enumerated()), id: \.element.id) { index, entry in
                        ExportQueueRangeRow(index: index, title: entry.name, start: entry.range.from, end: entry.range.to) {
                            model.removeQueuedRange(entry.id)
                        }
                    }
                }
                options
            }
        } actions: {
            Spacer()
            Button("Close") { model.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
            Button(model.queuedRanges.count == 1 ? "Export File…" : "Export \(model.queuedRanges.count) Files…") {
                model.chooseBulkDestination(container: container, mode: effectiveMode, tracks: tracks,
                                            settings: ReencodeSettings(codec: codec,
                                                                       quality: isProResExport ? proResQuality : quality,
                                                                       audio: audio))
            }
            .keyboardShortcut(.defaultAction).disabled(model.queuedRanges.isEmpty)
        }
        .onChange(of: tracks) { _, tracks in if tracks != .audio && container == "wav" { container = "mov" } }
        .onChange(of: isProResExport) { _, proRes in if proRes && container == "mp4" { container = "mov" } }
        .onChange(of: availableAudio) { _, actions in if !actions.contains(audio) { audio = .copyOriginal } }
        .frame(width: 500)
    }

    private var availableQualities: [ReencodeQuality] {
        isProResExport ? [.proresLT, .prores422, .proresHQ] : [.smallerFile, .balanced, .highQuality]
    }

    private var options: some View {
        Form {
            Picker("Tracks", selection: $tracks) {
                Text("Project tracks").tag(ExportTracks.all)
                Text("Picture only (Lossless Copy)").tag(ExportTracks.video)
                Text("Sound only (Lossless Copy)").tag(ExportTracks.audio)
            }
            Picker("Mode", selection: Binding(get: { effectiveMode }, set: { mode = $0 })) {
                ForEach([ExportMode.smart, .copy, .encode], id: \.self) { Text($0.displayName) }
            }
            .disabled(tracks != .all)
            Picker("Container", selection: $container) {
                Text(containerDisplayName("mov")).tag("mov")
                if !isProResExport { Text(containerDisplayName("mp4")).tag("mp4") }
                Text(containerDisplayName("mkv")).tag("mkv")
                if tracks == .audio { Text(containerDisplayName("wav")).tag("wav") }
            }
            if effectiveMode == .encode {
                Picker("Video", selection: $codec) {
                    ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName) }
                }
                Picker("Quality", selection: isProResExport ? $proResQuality : $quality) {
                    ForEach(availableQualities, id: \.self) { Text($0.displayName) }
                }
                Picker("Audio", selection: $audio) {
                    ForEach(availableAudio, id: \.self) { Text($0.displayName) }
                }
            }
        }
    }
}
