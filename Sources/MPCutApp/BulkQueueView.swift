import SwiftUI
import MPCutCore

struct BulkQueueView: View {
    @ObservedObject var editor: EditorModel
    @State private var silentVideoMode: ExportMode = .copy
    @State private var options: ExportSheetOptions

    init(editor: EditorModel) {
        self.editor = editor
        var value = ExportSheetOptions()
        value.copyContainer = ""
        // Silent movies deliberately start with Lossless Copy.
        value.mode = editor.defaultExportMode
        _options = State(initialValue: value)
    }

    private var media: [MediaInfo] { editor.queuedRanges.flatMap { $0.media.values } }
    private var hasVideo: Bool { media.contains(where: \.hasVideo) }
    private var hasAudio: Bool { media.contains { $0.streams.contains { $0.kind == "audio" } } }
    private var tracks: ExportTracks {
        guard hasVideo else { return .audio }
        return hasAudio ? options.tracks : .video
    }
    private var audioStreams: [StreamInfo] {
        guard let first = editor.queuedRanges.first, let clip = first.clips.first else { return [] }
        return first.media[clip.file]?.streams.filter { $0.kind == "audio" } ?? []
    }
    private var exportOptions: ExportSheetOptions {
        var result = options
        if hasVideo && !hasAudio {
            // A movie without a soundtrack can use every full-movie export mode.
            result.mode = silentVideoMode
            result.tracks = silentVideoMode == .copy ? .video : .all
        } else {
            result.tracks = tracks
        }
        return result
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
                            Toggle("Audio", isOn: Binding(get: { hasAudio && tracks != .video },
                                                          set: { chooseTracks($0 ? .all : .video) }))
                                .disabled(!hasAudio || !hasVideo || tracks == .audio)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if tracks == .audio && audioStreams.count > 1 {
                        Picker("Tracks", selection: $options.audioTrackOrdinal) {
                            Text("All audio tracks").tag(nil as Int?)
                            ForEach(audioStreams.indices, id: \.self) { Text(audioStreams[$0].exportLabel).tag(Optional($0)) }
                        }
                    }
                    Picker("Mode", selection: Binding(get: { exportOptions.effectiveMode }, set: {
                        if hasVideo && !hasAudio { silentVideoMode = $0 }
                        else { options.mode = $0 }
                    })) {
                        ForEach([ExportMode.smart, .copy, .encode], id: \.self) { Text($0.displayName) }
                    }
                    .disabled(!hasVideo || (hasAudio && tracks != .all))
                    if exportOptions.effectiveMode == .encode {
                        Picker("Video", selection: $options.codec) {
                            ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName) }
                        }
                        let proRes = options.codec == .prores
                        Picker("Container", selection: proRes ? $options.proResContainer : $options.encodeContainer) {
                            ForEach(proRes ? ["mov", "mkv"] : ["mp4", "mov", "mkv"], id: \.self) { Text(containerDisplayName($0)) }
                        }
                        Picker("Quality", selection: proRes ? $options.proResQuality : $options.standardQuality) {
                            ForEach(proRes ? [ReencodeQuality.proresLT, .prores422, .proresHQ] : [.smallerFile, .balanced, .highQuality],
                                    id: \.self) { Text($0.displayName) }
                        }
                        if hasAudio {
                            Picker("Audio", selection: $options.audio) {
                                ForEach(ReencodeAudio.allCases.filter { $0 != .removeAudio && ($0 != .pcm || options.container != "mp4") }, id: \.self) { Text($0.displayName) }
                            }
                            .onChange(of: options.container) { _, format in
                                if format == "mp4" && options.audio == .pcm { options.audio = .auto }
                            }
                        }
                    } else {
                        Picker("Container", selection: $options.copyContainer) {
                            Text("Source compatible").tag("")
                            if tracks != .audio {
                                ForEach(["mp4", "mov", "mkv", "webm"], id: \.self) { Text(containerDisplayName($0)) }
                            }
                        }
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Close") { editor.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
            Button(editor.queuedRanges.count == 1 ? "Export File…" : "Export \(editor.queuedRanges.count) Files…") {
                editor.chooseBulkDestination(options: exportOptions)
            }
                .keyboardShortcut(.defaultAction).disabled(editor.queuedRanges.isEmpty)
        }
        .onChange(of: editor.queuedRanges.map(\.id)) { _, _ in
            if tracks != options.tracks { chooseTracks(tracks) }
            if let stream = options.audioTrackOrdinal, !audioStreams.indices.contains(stream) {
                options.audioTrackOrdinal = nil
            }
        }
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
            .help("Remove this range from the queue")
        }
        .padding(.vertical, 2)
    }
}
