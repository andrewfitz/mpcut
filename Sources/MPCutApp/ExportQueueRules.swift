import Foundation
import MPCutCore
import SwiftUI

/// What the Export Queue offers for its ranges. Every list and name comes from the export rules.
struct ExportQueueChoices {
    let hasVideo: Bool
    let hasAudio: Bool
    /// The codec of the first queued audio track, whose own format leads the conversions.
    let audioCodec: String?

    init(media: [MediaInfo], audioCodec: String? = nil) {
        hasVideo = media.contains(where: \.hasVideo)
        hasAudio = media.contains { $0.streams.contains { $0.kind == "audio" } }
        self.audioCodec = audioCodec
    }

    var source: ExportSourceKind { hasVideo ? .movie : .audio }

    /// The selection the queue requests. A movie without sound keeps both track types, as the Export sheet does.
    func tracks(_ selected: ExportTracks) -> ExportTracks {
        guard hasVideo else { return .audio }
        return hasAudio ? selected : .all
    }

    func cell(tracks: ExportTracks, mode: ExportMode) -> ExportCell {
        ExportEntryPoint.queue.answer(source: source, tracks: tracks, mode: mode)
    }
    func modes(tracks: ExportTracks) -> [ExportMode] { ExportEntryPoint.queue.selectableModes(source: source, tracks: tracks) }
    func title(_ mode: ExportMode, tracks: ExportTracks) -> String { cell(tracks: tracks, mode: mode).displayName }
    /// The named formats of Convert Audio, the source's own first.
    var conversions: [ReencodeAudio] { ExportRules.namedConversions(sourceCodec: audioCodec) }
    /// The audio actions of a movie re-encode.
    var movieAudio: [ReencodeAudio] { cell(tracks: .all, mode: .encode).audioActions }

    /// Plans every range as the export will, without writing. Nil when all of them can be written.
    static func check(_ groups: [[ClipRequest]], media: [URL: MediaInfo], options: ExportSheetOptions,
                      cancelled: @escaping @Sendable () -> Bool = { false }) -> CutError? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-queue-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: scratch) }
            _ = try BulkExport(groups: groups, directory: scratch, organization: options.organization, mode: options.effectiveMode, tracks: options.tracks,
                               audioTrackOrdinal: options.audioTrackOrdinal,
                               container: options.container.isEmpty ? nil : options.container,
                               settings: options.batchSettings, media: media, cancelled: cancelled)
            return nil
        } catch let issue as CutError {
            return issue
        } catch {
            return CutError(code: "export_failed", message: error.localizedDescription)
        }
    }

    /// The alternatives a queue can apply. Its settings are shared by every range, so cuts are not moved.
    static func offers(for issue: CutError) -> [ExportAlternative] {
        (issue.alternatives ?? []).filter { $0.rung != .copySampleAligned }
    }
}

extension EditorModel {
    /// Checks the queued ranges with these settings: nil, or the failure with the alternatives of the export rules.
    func checkQueuedRanges(options: ExportSheetOptions) async -> CutError? {
        let groups = queuedRanges.map(\.clips)
        var media: [URL: MediaInfo] = [:]
        for range in queuedRanges { media.merge(range.media) { first, _ in first } }
        let indexed = media
        return await Task.detached(priority: .userInitiated) {
            ExportQueueChoices.check(groups, media: indexed, options: options)
        }.value
    }
}

/// An unavailable export with the alternatives the export rules report for it, least destructive first:
/// the first as the button, the rest in the menu beside it.
struct ExportOffersView: View {
    let message: String
    let alternatives: [ExportAlternative]
    let apply: (ExportAlternative) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IssueLabel(message)
            if let first = alternatives.first {
                HStack {
                    Button(first.label) { apply(first) }
                    if alternatives.count > 1 {
                        Menu("More Alternatives") {
                            ForEach(alternatives.dropFirst(), id: \.id) { alternative in
                                Button(alternative.label) { apply(alternative) }
                            }
                        }
                        .fixedSize()
                        .accessibilityLabel("More export alternatives")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
