import MPCutCore
import SwiftUI

@MainActor
struct MulticamAssemblyTimeline: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview
    @State private var layout: Layout?

    private struct Layout {
        let ranges: [MulticamRange]
        let groupEnd: RationalTime
        let clips: [TimelineClip]

        init(ranges: [MulticamRange], groupEnd: RationalTime, outputEnds: [RationalTime]) {
            self.ranges = ranges
            self.groupEnd = groupEnd
            clips = ranges.enumerated().map { index, range in
                let start = index == 0 ? RationalTime.zero : outputEnds[index - 1]
                let end = outputEnds[index]
                let id = MulticamAssemblyTimeline.id(index)
                return TimelineClip(id: id, sourceID: id, name: "Range \(index + 1)",
                                    sourceStart: range.from.seconds, sourceEnd: range.to.seconds,
                                    sourceDuration: groupEnd.seconds, keyframes: [], thumbnailSyncTimes: [],
                                    frames: [], sequenceRange: start.seconds..<end.seconds,
                                    displayRange: AudioSpan(from: range.from, to: range.to))
            }
        }
    }

    var body: some View {
        if let project = model.project {
            let ranges = model.ranges
            let groupEnd = project.range.to
            let current = layout.flatMap { $0.ranges == ranges && $0.groupEnd == groupEnd ? $0 : nil }
                ?? Layout(ranges: ranges, groupEnd: groupEnd, outputEnds: model.assemblyRangeEnds)
            timeline(current)
                .onChange(of: ranges, initial: true) { _, _ in layout = current }
                .onChange(of: groupEnd) { _, _ in layout = current }
                .help(model.rangeTool
                      ? "Drag to select assembly output. Click to seek."
                      : "Drag a range edge to trim. Drag the range body to reorder. Click the ruler to seek in the assembly.")
        }
    }

    private func timeline(_ current: Layout) -> SequenceTimeline {
        let ranges = current.ranges
        let clips = current.clips
        let selected = model.occurrenceIndex(at: preview.time)
        let position = model.assemblyPreview ? preview.time.seconds
            : Self.outputPosition(for: model.groupTime(at: preview.time), occurrence: selected, layout: current)
        var result = SequenceTimeline(clips: clips, playhead: position, selection: Self.id(selected),
                         markIn: model.assemblySelection?.from.seconds, markOut: model.assemblySelection?.to.seconds,
                         thumbnailHeight: 4, zoom: $model.timelineZoom, allowsClipEdits: !model.isBusy,
                         showsControls: false, allowsFileDrops: false, accessibilityTitle: "Assembly timeline",
                         onSelect: { id in
                             if let index = clips.firstIndex(where: { $0.id == id }) {
                                 model.selectAssemblyOccurrence(index)
                             }
                         }, onSeek: { model.seekAssemblyTimeline($0, scrubbing: false) },
                         onTrim: { id, edge, seconds, commit in
                             guard model.ranges == ranges,
                                   let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
                             return model.trimAssemblyOccurrence(index, edge: edge, seconds: seconds, commit: commit)
                         }, onMove: { id, slot in
                             guard model.ranges == ranges,
                                   let index = clips.firstIndex(where: { $0.id == id }) else { return }
                             model.reorderAssemblyOccurrence(index, before: slot)
                         }, onDrop: { _, _ in },
                         onScrub: { model.seekAssemblyTimeline($0, scrubbing: true) },
                         onEndScrub: { preview.endScrub() })
        if model.rangeTool && !model.isBusy { result.onRangeSelect = model.selectAssemblyRange }
        return result
    }

    private static func outputPosition(for group: RationalTime, occurrence: Int, layout: Layout) -> Double {
        guard layout.ranges.indices.contains(occurrence),
              let output = layout.clips[occurrence].sequenceRange else { return 0 }
        let input = layout.ranges[occurrence]
        let elapsed = (try? min(input.to, max(input.from, group)).subtracting(input.from)) ?? .zero
        return min(output.upperBound, output.lowerBound + elapsed.seconds)
    }

    private nonisolated static func id(_ index: Int) -> UUID {
        let value = UInt64(truncatingIfNeeded: index)
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                           UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
                           UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
                           UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                           UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)))
    }
}
