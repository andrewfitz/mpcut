import SwiftUI
import MPCutCore

struct BulkQueueView: View {
    @ObservedObject var editor: EditorModel
    @State private var options: ExportSheetOptions
    /// The failure of the last check, with the alternatives the export rules report for it.
    @State private var issue: CutError?
    @State private var isChecking = false

    init(editor: EditorModel) {
        self.editor = editor
        var value = ExportSheetOptions()
        value.copyContainer = ""
        if editor.queuedRanges.contains(where: { $0.placements != .none }) {
            value.mode = .smart
            value.audio = .copyOriginal
        } else {
            value.mode = editor.defaultExportMode
        }
        _options = State(initialValue: value)
    }

    private var media: [MediaInfo] { editor.queuedRanges.flatMap { $0.media.values } }
    /// The modes, containers, audio actions and names on offer, from the export rules.
    private var choices: ExportQueueChoices {
        let selected = options.audioTrackOrdinal.flatMap { audioStreams.indices.contains($0) ? audioStreams[$0] : nil }
        return ExportQueueChoices(media: media, audioCodec: (selected ?? audioStreams.first)?.codec, placements: placements)
    }
    private var placements: ExportPlacementScope {
        editor.queuedRanges.map(\.placements).max(by: { $0.rawValue < $1.rawValue }) ?? .none
    }
    private var hasVideo: Bool { choices.hasVideo }
    private var hasAudio: Bool { choices.hasAudio }
    private var tracks: ExportTracks { choices.tracks(options.tracks) }
    private var audioStreams: [StreamInfo] {
        guard let first = editor.queuedRanges.first else { return [] }
        if let clip = first.clips.first {
            return first.media[clip.file]?.streams.filter { $0.kind == "audio" } ?? []
        }
        if let reference = first.stillProject?.stillAudioReference {
            return first.media[URL(fileURLWithPath: reference.file).standardizedFileURL]?.streams.filter { $0.kind == "audio" } ?? []
        }
        return []
    }
    private var exportOptions: ExportSheetOptions {
        var result = options
        result.tracks = tracks
        result.placements = placements
        return result
    }

    private func chooseMode(_ mode: ExportMode) {
        if tracks != .audio {
            options.mode = mode
        } else if mode == .encode, let format = choices.conversions.first {
            // Start from the source's own format, as the Export sheet does.
            options.convertAudio(to: choices.conversions.contains(options.audioFormat) ? options.audioFormat : format)
        } else {
            options.audioMode = .copy
        }
    }

    private func export() {
        let requested = exportOptions
        let ranges = editor.queuedRanges.map(\.id)
        isChecking = true
        Task {
            // Plan every range first, so that a range that cannot be written shows the offers of the Export sheet.
            let failure = await editor.checkQueuedRanges(options: requested)
            guard isChecking else { return }
            isChecking = false
            guard requested == exportOptions, ranges == editor.queuedRanges.map(\.id) else { return }
            issue = failure
            if failure == nil { editor.chooseBulkDestination(options: requested) }
        }
    }

    private func chooseTracks(_ selection: ExportTracks) {
        options.tracks = selection
        options.copyContainer = ""
        options.audioTrackOrdinal = nil
    }

    var body: some View {
        EditorSheet(title: "Export Queue", message: queueSummary(editor.queuedRanges.map { ($0.start, $0.end) })) {
            if editor.queuedRanges.isEmpty {
                ExportQueueEmptyState()
            } else {
                ExportQueueList(count: editor.queuedRanges.count) {
                    ForEach(Array(editor.queuedRanges.enumerated()), id: \.element.id) { index, range in
                        ExportQueueRangeRow(index: index, title: range.clips.first?.file.lastPathComponent ?? "",
                                            start: range.start, end: range.end) {
                            editor.removeQueuedRange(range.id)
                        }
                    }
                }
                Form {
                    LabeledContent("Include") {
                        HStack(spacing: 14) {
                            Toggle("Video", isOn: Binding(get: { hasVideo && tracks != .audio },
                                                          set: { chooseTracks($0 ? .all : .audio) }))
                                .disabled(!hasVideo || !hasAudio || tracks == .video)
                                .help("Include video")
                            Toggle("Audio", isOn: Binding(get: { hasAudio && tracks != .video },
                                                          set: { chooseTracks($0 ? .all : .video) }))
                                .disabled(!hasAudio || !hasVideo || tracks == .audio)
                                .help("Include audio")
                        }
                        .toggleStyle(.checkbox)
                    }
                    if tracks == .audio && audioStreams.count > 1 {
                        Picker("Tracks", selection: $options.audioTrackOrdinal) {
                            Text("All audio tracks").tag(nil as Int?)
                            ForEach(audioStreams.indices, id: \.self) { Text(audioStreams[$0].exportLabel).tag(Optional($0)) }
                        }
                        .help("Choose audio tracks")
                    }
                    // Exactly the modes the export rules write as themselves for this selection.
                    let modes = choices.modes(tracks: tracks)
                    Picker("Mode", selection: Binding(get: { exportOptions.effectiveMode }, set: chooseMode)) {
                        ForEach(modes, id: \.self) { Text(choices.title($0, tracks: tracks)) }
                    }
                    .disabled(modes.count < 2)
                    .help("Choose export mode")
                    if placements != .none && tracks != .audio {
                        Toggle("Preserve camera picture", isOn: $options.requireCameraCopy)
                            .help("Copy camera footage")
                    }
                    if exportOptions.convertsAudio {
                        Picker("Audio", selection: Binding(get: { options.audioFormat },
                                                           set: { options.convertAudio(to: $0, preferred: options.conversionContainer) })) {
                            ForEach(choices.conversions, id: \.self) { Text($0.displayName) }
                        }
                        .help("Choose audio format")
                        Picker("Container", selection: $options.conversionContainer) {
                            ForEach(ExportRules.conversionContainers(options.audioFormat), id: \.self) { Text(containerDisplayName($0)) }
                        }
                        .help("Choose file format")
                    } else if exportOptions.effectiveMode == .encode {
                        Picker("Video", selection: $options.codec) {
                            ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName) }
                        }
                        .help("Choose video codec")
                        let proRes = options.codec == .prores
                        Picker("Container", selection: proRes ? $options.proResContainer : $options.encodeContainer) {
                            ForEach(placements == .none ? ExportRules.reencodeContainers(options.codec) :
                                ExportRules.stillContainers(mode: .encode, tracks: tracks, codec: options.codec, audio: options.audio), id: \.self) { Text(containerDisplayName($0)) }
                        }
                        .help("Choose file format")
                        Picker("Quality", selection: proRes ? $options.proResQuality : $options.standardQuality) {
                            ForEach(ExportRules.qualities(options.codec), id: \.self) { Text($0.displayName) }
                        }
                        .help("Set video quality")
                        if hasAudio && tracks != .video {
                            // Every audio action of the cell. One the container cannot carry is refused with its alternatives.
                            Picker("Audio", selection: $options.audio) {
                                ForEach(choices.movieAudio(mode: .encode), id: \.self) { Text($0.displayName) }
                            }
                            .help("Choose audio encoding")
                        }
                    } else {
                        Picker("Container", selection: $options.copyContainer) {
                            Text("Source compatible").tag("")
                            let listed = tracks == .audio ? [] :
                                placements == .none ? ExportRules.movieCopyContainers : ExportRules.stillMovieContainers
                            ForEach(listed, id: \.self) { Text(containerDisplayName($0)) }
                            // A container chosen by applying an alternative stays selectable.
                            if !options.copyContainer.isEmpty, !listed.contains(options.copyContainer) {
                                Text(containerDisplayName(options.copyContainer)).tag(options.copyContainer)
                            }
                        }
                        .help("Choose file format")
                        if placements != .none && tracks == .all && hasAudio && exportOptions.effectiveMode == .smart {
                            Picker("Audio", selection: $options.audio) {
                                ForEach(choices.movieAudio(mode: .smart), id: \.self) { Text($0.displayName) }
                            }
                            .help("Choose audio encoding")
                        }
                    }
                }
                ExportOrganizationFields(organization: $options.organization,
                                         stem: editor.queuedRanges.first?.clips.first?.file.deletingPathExtension().lastPathComponent ?? "Clip",
                                         container: exportOptions.container)
                if let issue {
                    ExportOffersView(message: ExportRules.describe(issue, clips: []), alternatives: ExportQueueChoices.offers(for: issue)) {
                        options = exportOptions.applying($0)
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Close") { editor.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
                .help("Close export queue")
            Button(editor.queuedRanges.count == 1 ? "Export File…" : "Export \(editor.queuedRanges.count) Files…", action: export)
                .keyboardShortcut(.defaultAction).disabled(editor.queuedRanges.isEmpty || isChecking)
                .help("Export queued ranges")
        }
        .onChange(of: options) { _, _ in issue = nil }
        .onChange(of: editor.queuedRanges.map(\.id)) { _, _ in
            issue = nil
            if tracks != options.tracks { chooseTracks(tracks) }
            if let stream = options.audioTrackOrdinal, !audioStreams.indices.contains(stream) {
                options.audioTrackOrdinal = nil
            }
        }
        .onDisappear { isChecking = false }
        .frame(width: 500)
    }
}

/// "3 ranges · 00:12.500 total", or nothing for an empty queue.
func queueSummary(_ ranges: [(RationalTime, RationalTime)]) -> String? {
    guard !ranges.isEmpty else { return nil }
    let total = ranges.reduce(0.0) { $0 + max(0, $1.1.seconds - $1.0.seconds) }
    return "\(ranges.count == 1 ? "1 range" : "\(ranges.count) ranges") · \(timelineTime(total, milliseconds: true)) total"
}

struct ExportQueueEmptyState: View {
    var body: some View {
        ContentUnavailableView("No Queued Ranges", systemImage: "list.number",
                               description: Text("Mark In and Out on the timeline, then choose Add Marked Range to Export Queue (⇧⌘A)."))
            .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct ExportQueueList<Rows: View>: View {
    let count: Int
    @ViewBuilder let rows: Rows

    var body: some View {
        // Hug a short queue; scroll a long one.
        List { rows }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: min(228, CGFloat(max(2, count)) * 44 + 8))
            .modifier(InsetPanel())
    }
}

struct ExportQueueRangeRow: View {
    let index: Int
    let title: String
    let start: RationalTime
    let end: RationalTime
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%03d", index + 1))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text("\(timelineTime(start.seconds, milliseconds: true)) – \(timelineTime(end.seconds, milliseconds: true))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(timelineTime(max(0, end.seconds - start.seconds), milliseconds: true))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Duration")
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove range \(index + 1)")
            .help("Remove queued range")
        }
        .padding(.vertical, 2)
    }
}

struct ExportOrganizationFields: View {
    @Binding var organization: ExportOrganization
    let stem: String
    let container: String

    var body: some View {
        DisclosureGroup {
            Form {
                TextField("Subfolder", text: $organization.subfolder, prompt: Text("Selected folder"))
                    .help("Set output subfolder")
                TextField("Base name", text: $organization.baseName, prompt: Text(stem))
                    .help("Set base filename")
                if let error = validationError {
                    IssueLabel(error)
                } else {
                    let file = organization.filename(stem: stem, suffix: "001", container: container)
                    LabeledContent(container.isEmpty ? "First file (before extension)" : "First file", value: organization.subfolder.isEmpty ? file : "\(organization.subfolder)/\(file)")
                        .font(.caption)
                }
            }
        } label: {
            Text("Folders and filenames").help("Show naming options")
        }
    }

    private var validationError: String? {
        do {
            try organization.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
