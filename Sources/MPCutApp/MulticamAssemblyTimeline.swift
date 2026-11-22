import MPCutCore
import SwiftUI

@MainActor
struct MulticamAssemblyTimeline: View {
    @ObservedObject var model: MulticamEditorModel
    @ObservedObject var preview: MulticamPreview
    @State private var layout: Layout?

    var hasAssets: Bool {
        guard let project = model.project else { return false }
        return model.assemblyItems.contains { item in
            if item.still != nil { return true }
            guard let group = item.group else { return false }
            return project.stillReplacements.contains { replacement in
                guard case .group(let range) = replacement.coverage else { return false }
                return range.from < group.to && group.from < range.to
            }
        }
    }

    private struct Layout {
        let items: [StillAssemblyItem]
        let groupEnd: RationalTime
        let clips: [TimelineClip]

        let assets: [StillAsset]
        let replacements: [StillReplacement]
        let assetSpans: [MulticamAssetSpan]

        init(items: [StillAssemblyItem], groupEnd: RationalTime, outputEnds: [RationalTime],
             assets: [StillAsset], replacements: [StillReplacement], assetSpans: [MulticamAssetSpan]) {
            self.items = items
            self.assets = assets
            self.replacements = replacements
            self.assetSpans = assetSpans
            let names = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.displayName) })
            self.groupEnd = groupEnd
            clips = items.enumerated().map { index, item in
                let start = index == 0 ? RationalTime.zero : outputEnds[index - 1]
                let end = outputEnds[index]
                let id = MulticamAssemblyTimeline.id(index)
                let from = item.group?.from ?? .zero
                let to = item.group?.to ?? item.still?.duration ?? .zero
                let name = item.still.map { names[$0.assetID] ?? $0.assetID } ?? "Range \(index + 1)"
                return TimelineClip(id: id, sourceID: id, name: name,
                                    sourceStart: from.seconds, sourceEnd: to.seconds,
                                    sourceDuration: item.still == nil ? groupEnd.seconds : to.seconds,
                                    keyframes: [], thumbnailSyncTimes: [],
                                    frames: [], sequenceRange: start.seconds..<end.seconds,
                                    displayRange: AudioSpan(from: from, to: to))
            }
        }
    }

    var body: some View {
        if let project = model.project {
            let items = model.assemblyItems
            let groupEnd = project.range.to
            let current = layout.flatMap { layout in
                layout.items == items && layout.groupEnd == groupEnd && layout.assets == project.stillAssets
                    && layout.replacements == project.stillReplacements ? layout : nil
            } ?? Layout(items: items, groupEnd: groupEnd, outputEnds: model.assemblyRangeEnds, assets: project.stillAssets,
                        replacements: project.stillReplacements, assetSpans: model.assemblyAssetSpans)
            timeline(current)
                .onChange(of: items, initial: true) { _, _ in layout = current }
                .onChange(of: project.stillAssets) { _, _ in layout = current }
                .onChange(of: project.stillReplacements) { _, _ in layout = current }
                .onChange(of: groupEnd) { _, _ in layout = current }
        }
    }

    private func timeline(_ current: Layout) -> SequenceTimeline {
        let items = current.items
        let clips = current.clips
        let selected = model.occurrenceIndex(at: preview.time)
        let position = model.assemblyPreview ? preview.time.seconds
            : Self.outputPosition(for: model.groupTime(at: preview.time), occurrence: selected, layout: current)
        var result = SequenceTimeline(clips: clips, playhead: position, selection: Self.id(selected),
                         markIn: model.assemblySelection?.from.seconds, markOut: model.assemblySelection?.to.seconds,
                         thumbnailHeight: 4, zoom: $model.timelineZoom, allowsClipEdits: !model.isBusy,
                         showsControls: false, allowsFileDrops: !model.isBusy, accessibilityTitle: "Assembly timeline",
                         onSelect: { id in
                             if let index = clips.firstIndex(where: { $0.id == id }) {
                                 model.selectAssemblyOccurrence(index)
                             }
                         }, onSeek: { model.seekAssemblyTimeline($0, scrubbing: false) },
                         onTrim: { id, edge, seconds, commit in
                             guard model.assemblyItems == items,
                                   let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
                             return model.trimAssemblyOccurrence(index, edge: edge, seconds: seconds, commit: commit)
                         }, onMove: { id, slot in
                             guard model.assemblyItems == items,
                                   let index = clips.firstIndex(where: { $0.id == id }) else { return }
                             model.reorderAssemblyOccurrence(index, before: slot)
                         }, onDrop: { urls, _ in model.importSources(urls) },
                         onScrub: { model.seekAssemblyTimeline($0, scrubbing: true) },
                         onEndScrub: { preview.endScrub() })
        result.assemblyAssets = current.assetSpans
        if model.rangeTool && !model.isBusy { result.onRangeSelect = model.selectAssemblyRange }
        result.onDropStills = { urls, seconds, replace in
            if replace, urls.count == 1, let image = urls.first, model.canReplaceMulticamPicture {
                model.replaceMulticamPicture(with: image)
            } else if let time = timelineRationalTime(seconds) {
                model.insertMulticamStills(urls, atAssembly: time)
            }
        }
        return result
    }

    private static func outputPosition(for group: RationalTime, occurrence: Int, layout: Layout) -> Double {
        guard layout.items.indices.contains(occurrence),
              let output = layout.clips[occurrence].sequenceRange else { return 0 }
        guard let input = layout.items[occurrence].group else { return output.lowerBound }
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
