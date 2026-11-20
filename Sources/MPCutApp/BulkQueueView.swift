import SwiftUI
import MPCutCore

struct BulkQueueView: View {
    @ObservedObject var editor: EditorModel
    @State private var options: ExportSheetOptions = {
        var value = ExportSheetOptions()
        value.copyContainer = ""
        return value
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Queue").font(.title2.bold())
            if editor.queuedRanges.isEmpty {
                ContentUnavailableView("No queued ranges", systemImage: "list.number",
                                       description: Text("Mark In and Out on the timeline, then choose Add Marked Range to Export Queue."))
            } else {
                List {
                    ForEach(Array(editor.queuedRanges.enumerated()), id: \.element.id) { index, range in
                        HStack {
                            Text(String(format: "%03d", index + 1)).monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(range.clips.first?.file.lastPathComponent ?? "")
                                Text("\(timelineTime(range.start.seconds, milliseconds: true)) – \(timelineTime(range.end.seconds, milliseconds: true))")
                                    .font(.caption).monospacedDigit()
                            }
                            Spacer()
                            Button { editor.removeQueuedRange(range.id) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).accessibilityLabel("Remove range \(index + 1)")
                        }
                    }
                }
                Form {
                    Picker("Export mode", selection: $options.mode) {
                        ForEach([ExportMode.smart, .copy, .encode], id: \.self) { Text($0.displayName) }
                    }
                    if options.mode == .encode {
                        Picker("Video", selection: $options.codec) {
                            ForEach(ReencodeCodec.allCases, id: \.self) { Text($0.displayName) }
                        }
                        let proRes = options.codec == .prores
                        Picker("Container", selection: proRes ? $options.proResContainer : $options.encodeContainer) {
                            ForEach(proRes ? ["mov", "mkv"] : ["mp4", "mov", "mkv"], id: \.self) { Text($0.uppercased()) }
                        }
                        Picker("Quality", selection: proRes ? $options.proResQuality : $options.standardQuality) {
                            ForEach(proRes ? [ReencodeQuality.proresLT, .prores422, .proresHQ] : [.smallerFile, .balanced, .highQuality],
                                    id: \.self) { Text($0.displayName) }
                        }
                        Picker("Audio", selection: $options.audio) {
                            ForEach(ReencodeAudio.allCases.filter { $0 != .pcm || options.container != "mp4" }, id: \.self) { Text($0.displayName) }
                        }
                        .onChange(of: options.container) { _, format in
                            if format == "mp4" && options.audio == .pcm { options.audio = .auto }
                        }
                    } else {
                        Picker("Container", selection: $options.copyContainer) {
                            Text("Source compatible").tag("")
                            ForEach(["mp4", "mov", "mkv", "webm"], id: \.self) { Text($0.uppercased()) }
                        }
                    }
                }
            }
            HStack {
                Button("Close") { editor.isBulkQueuePresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(editor.queuedRanges.count == 1 ? "Export File…" : "Export \(editor.queuedRanges.count) Files…") {
                    editor.chooseBulkDestination(options: options)
                }
                    .keyboardShortcut(.defaultAction).disabled(editor.queuedRanges.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}
