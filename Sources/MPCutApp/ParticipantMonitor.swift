import AppKit
import Combine
import MPCutCore
import SwiftUI

struct ParticipantTranscriptSelection: Equatable {
    let binding: ParticipantSpeakerBinding
    let time: RationalTime
}

struct ParticipantPickedAppearance: Equatable {
    let sourceID: String
    let appearanceID: String
}

struct ParticipantDrawnBounds: Equatable {
    let sourceID: String
    let time: RationalTime
    let bounds: ParticipantBounds
}

/// Each lane contains disjoint ranges so a point lookup can binary search it.
struct ParticipantAppearanceIndex {
    private let appearances: [ParticipantAppearance]
    private let lanes: [[Int]]

    init(_ appearances: [ParticipantAppearance]) {
        self.appearances = appearances
        let starts = appearances.indices.sorted { appearances[$0].range.from < appearances[$1].range.from }
        let ends = appearances.indices.sorted { appearances[$0].range.to < appearances[$1].range.to }
        var lanes: [[Int]] = []
        var available: [Int] = []
        var assigned = Array(repeating: 0, count: appearances.count)
        var nextEnd = 0
        for index in starts {
            let from = appearances[index].range.from
            while nextEnd < ends.count, appearances[ends[nextEnd]].range.to <= from {
                available.append(assigned[ends[nextEnd]])
                nextEnd += 1
            }
            let lane = available.popLast() ?? lanes.count
            if lane == lanes.count { lanes.append([]) }
            assigned[index] = lane
            lanes[lane].append(index)
        }
        self.lanes = lanes
    }

    func at(_ time: RationalTime) -> [ParticipantAppearance] {
        let visible = lanes.compactMap { lane -> Int? in
            let i = lane.lowerBound { appearances[$0].range.to > time }
            guard lane.indices.contains(i), appearances[lane[i]].range.from <= time else { return nil }
            return lane[i]
        }
        return visible.sorted().map { appearances[$0] }
    }
}

@MainActor
final class ParticipantMonitorGeometry {
    private let index: ParticipantAppearanceIndex
    private let intervals: [ParticipantCoverage]
    private let representativeTiles: [String: ParticipantAppearance]
    let hasUncertainAppearance: Bool

    init(_ source: ParticipantSourceGeometry) {
        index = ParticipantAppearanceIndex(source.appearances)
        intervals = source.coverage.sorted { $0.range.from < $1.range.from }
        representativeTiles = source.appearances.reduce(into: [:]) { thumbnails, tile in
            guard let feed = tile.participantID, tile.state == .video || tile.state == .presentation,
                  thumbnails[feed].map({ tile.range.from < $0.range.from }) ?? true else { return }
            thumbnails[feed] = tile
        }
        hasUncertainAppearance = source.appearances.contains { $0.participantID == nil && $0.state != .presentation }
    }

    func appearances(at time: RationalTime) -> [ParticipantAppearance] { index.at(time) }

    func representativeTile(for feedID: String) -> ParticipantAppearance? { representativeTiles[feedID] }

    func coverage(at time: RationalTime) -> ParticipantCoverageState {
        let i = intervals.lowerBound { $0.range.to > time }
        return intervals.indices.contains(i) && intervals[i].range.contains(time) ? intervals[i].state : .unknown
    }
}

struct ParticipantMonitorPosition {
    let sourceID: String
    let media: MediaInfo
    let time: RationalTime
    var duration: RationalTime {
        (try? media.duration.subtracting(media.multicamClockOffset)) ?? media.duration
    }

    // Preview video uses display dimensions, including rotation and pixel aspect.
    var aspect: CGFloat {
        guard let stream = media.videoStream, stream.displayWidth > 0, stream.displayHeight > 0 else { return 1 }
        return CGFloat(stream.displayWidth) / CGFloat(stream.displayHeight)
    }

    func frameRange(atReflow boundary: RationalTime, before: Bool) -> MulticamRange? {
        let frames = media.frames
        guard let clock = try? boundary.adding(media.multicamClockOffset) else { return nil }
        let index = frames.lowerBound { $0.time >= clock } - (before ? 1 : 0)
        guard frames.indices.contains(index),
              let start = try? frames[index].time.subtracting(media.multicamClockOffset),
              let end = try? start.adding(frames[index].duration) else { return nil }
        let range = MulticamRange(from: max(.zero, start), to: min(duration, end))
        return range.from < range.to ? range : nil
    }

    func needsReconciliation(in project: ParticipantProject) -> Bool {
        project.needsReconciliation(sourceID: sourceID, identity: media.identity)
    }

    struct DrawingFrame: Hashable {
        let sourceID: String
        let media: TilesThumbnailSource
        let time: RationalTime
    }

    var drawingFrame: DrawingFrame {
        .init(sourceID: sourceID, media: TilesThumbnailSource(media), time: time)
    }
}

extension ProjectSession {
    var participantProject: ParticipantProject {
        isMulticam ? (multicam.project?.participants ?? .init()) : editor.participantProject
    }

    var participantPosition: ParticipantMonitorPosition? {
        participantPosition(displaying: multicam.preview.picture, sequence: editor.preview.sourcePicture.value)
    }

    func participantPosition(displaying picture: MulticamPicturePosition?,
                             sequence: SequenceSourcePicture?) -> ParticipantMonitorPosition? {
        if isMulticam {
            guard let picture, picture.spanIndex >= 0,
                  let media = multicam.media[picture.source], media.identity == picture.identity,
                  let sourceTime = try? picture.frameTime.subtracting(picture.multicamClockOffset) else { return nil }
            let sourceID = multicam.project?.angles.first(where: { $0.id == picture.source })?.feedAngle?.sourceID ?? picture.source
            return .init(sourceID: sourceID, media: multicam.media[sourceID] ?? media, time: sourceTime)
        }
        guard let sequence, let media = editor.participantMedia(displaying: sequence) else { return nil }
        return .init(sourceID: media.url.path, media: media, time: sequence.time)
    }

    var participantTimelineTime: RationalTime {
        isMulticam ? multicam.preview.time : (timelineRationalTime(editor.playhead) ?? .zero)
    }

    var participantPlayback: AnyPublisher<RationalTime, Never> {
        if isMulticam { return multicam.preview.$time.eraseToAnyPublisher() }
        return editor.$playhead.compactMap { timelineRationalTime($0) }.eraseToAnyPublisher()
    }

    func commitParticipants(_ next: ParticipantProject, action: String) throws {
        if isMulticam { try multicam.replaceParticipantProject(next, action: action) }
        else { try editor.replaceParticipantProject(next, action: action) }
    }

    @discardableResult
    func seekParticipant(sourceID: String, range: MulticamRange, mark: Bool = false) -> Bool {
        if isMulticam { return multicam.seekParticipantAppearance(sourceID: sourceID, range: range, mark: mark) }
        return editor.seekParticipantAppearance(sourceID: sourceID, range: range, mark: mark)
    }

    func pauseParticipantPlayback() {
        if isMulticam { multicam.preview.pause() }
        else { editor.preview.pause() }
    }

    func showParticipantTranscript(_ binding: ParticipantSpeakerBinding) {
        presentation.participantTranscriptFilter = binding
        presentation.setTranscriptVisible(true, multicam: isMulticam)
    }
}

@MainActor
struct ParticipantMonitorOverlay: View {
    let session: ProjectSession
    let interactive: Bool
    @ObservedObject private var presentation: EditorPresentation
    @State private var time: RationalTime = .zero
    @State private var displayedPicture: MulticamPicturePosition?
    @State private var sequencePicture: SequenceSourcePicture?
    @State private var indexes: [TranscriptIndex] = []
    @State private var matchedVoices: [ParticipantSpeakerBinding: String] = [:]
    @State private var editingTile: ParticipantAppearance?
    @State private var error: String?
    @State private var resizing: CGRect?
    @State private var outputCells: ParticipantPreviewCells?

    init(session: ProjectSession, interactive: Bool) {
        self.session = session
        self.interactive = interactive
        _presentation = ObservedObject(wrappedValue: session.presentation)
    }

    var body: some View {
        let project = session.participantProject
        let speakers = speakingParticipantIDs(project)
        let editable = interactive || !project.isEmpty
        GeometryReader { geometry in
            if presentation.participantMonitorSource,
               let source = session.participantPosition(displaying: displayedPicture, sequence: sequencePicture) {
                let picture = Self.pictureRect(in: geometry.size, aspect: source.aspect)
                let pending = scanPreviewBoxes(for: source)
                let canEdit = !source.needsReconciliation(in: project) && pending == nil
                let appearances = canEdit ? session.participantGeometry(for: source.sourceID)?.appearances(at: source.time) ?? [] : []
                ZStack(alignment: .topLeading) {
                    ForEach(appearances) { appearance in
                        let active = appearance.participantID.map(speakers.contains) ?? false
                        let pinned = appearance.participantID != nil && appearance.participantID == presentation.pinnedParticipant
                        if editable || active || pinned {
                            tile(appearance, source: source, picture: picture, project: project, active: active, pinned: pinned)
                        }
                    }
                    if editable && !presentation.participantDrawMode,
                       let picked = presentation.pickedParticipantAppearance, picked.sourceID == source.sourceID,
                       let tile = appearances.first(where: { $0.id == picked.appearanceID }) {
                        resizeHandles(tile, source: source, picture: picture)
                    }
                    if interactive && !presentation.participantDrawMode, let pending {
                        ForEach(pending.indices, id: \.self) { index in
                            outline(Self.position(pending[index], in: picture), color: .orange)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    if canEdit && interactive && presentation.participantDrawMode {
                        let frame = source.drawingFrame
                        ParticipantBoxDrawing { rect in
                            guard session.participantPosition?.drawingFrame == frame else { return }
                            presentation.participantDrawnBounds = .init(
                                sourceID: source.sourceID, time: source.time,
                                bounds: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
                            presentation.participantDrawMode = false
                        }
                        .id(frame)
                        .frame(width: picture.width, height: picture.height)
                        .position(x: picture.midX, y: picture.midY)
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(editable)
            } else if !presentation.participantMonitorSource, let outputCells {
                outputControls(outputCells, in: geometry.size)
            }
        }
        .overlay(alignment: .topLeading) {
            if editable || session.transcript.project.requiresPictureProcessing {
                Picker("Monitor picture", selection: $presentation.participantMonitorSource) {
                    Text("Output").tag(false).accessibilityIdentifier("tiles.monitor.output")
                    Text("Source").tag(true).accessibilityIdentifier("tiles.monitor.source")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(8)
                .accessibilityIdentifier("tiles.monitor.picture")
            }
        }
        .alert("Tile Edit", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onChange(of: requestedEditorAppearance) { _, appearance in
            if let appearance {
                editingTile = appearance
                presentation.requestedParticipantTileEditor = nil
            }
        }
        .onChange(of: presentation.participantMonitorSource) { _, source in
            if !source {
                editingTile = nil
                resizing = nil
            }
        }
        .onChange(of: presentation.participantDrawMode) { _, drawing in
            if drawing { presentation.participantMonitorSource = true }
        }
        .onReceive(session.isMulticam ? session.multicam.preview.participantPreviewCells : session.editor.preview.participantPreviewCells) {
            outputCells = $0
        }
        .onReceive(session.participantPlayback.receive(on: DispatchQueue.main)) { next in
            if let selected = presentation.selectedTranscriptSpeaker, next != selected.time {
                presentation.selectedTranscriptSpeaker = nil
            }
            if next != time {
                editingTile = nil
                resizing = nil
            }
            time = next
        }
        .onReceive(session.multicam.preview.$picture.receive(on: DispatchQueue.main)) { picture in
            if session.isMulticam, displayedPicture != picture {
                displayedPicture = picture
                if picture == nil { editingTile = nil }
            }
        }
        .onReceive(session.editor.preview.sourcePicture) { picture in
            if !session.isMulticam, sequencePicture != picture {
                sequencePicture = picture
                if picture == nil { editingTile = nil }
            }
        }
        .onChange(of: speakers, initial: true) { _, value in
            presentation.speakingParticipants = value
        }
        .task(id: ParticipantSpeakerIndexKey(session: session)) {
            indexes = []
            matchedVoices = [:]
            guard !project.people.isEmpty else { return }
            let ids = Set(project.people.flatMap { $0.speakers.map(\.attachmentID) })
            let multicam = session.isMulticam ? session.multicam.project : nil
            var loaded: [TranscriptIndex] = []
            for attachment in session.transcript.state.attachments where multicam != nil || ids.contains(attachment.id) {
                if Task.isCancelled { return }
                if let index = try? await session.transcript.indexedTranscript(attachmentID: attachment.id) {
                    loaded.append(index)
                }
            }
            let voices = if let multicam {
                await Task.detached(priority: .utility) { [loaded] in
                    TileFeedAttachments.voices(in: multicam, indexes: loaded)
                }.value
            } else { [:] as [ParticipantSpeakerBinding: String] }
            guard !Task.isCancelled else { return }
            indexes = loaded
            matchedVoices = voices
        }
    }

    private func scanPreviewBoxes(for position: ParticipantMonitorPosition) -> [CGRect]? {
        guard let preview = presentation.participantScanPreview, preview.sourceID == position.sourceID,
              preview.stamp == SceneSourceStamp(media: position.media),
              preview.analysis.start <= position.time, position.time < preview.analysis.end else { return nil }
        return preview.boxes(at: position.time)
    }

    private var requestedEditorAppearance: ParticipantAppearance? {
        guard interactive, presentation.participantMonitorSource,
              let request = presentation.requestedParticipantTileEditor,
              let position = session.participantPosition(displaying: displayedPicture, sequence: sequencePicture),
              request.sourceID == position.sourceID,
              !position.needsReconciliation(in: session.participantProject) else { return nil }
        return session.participantGeometry(for: request.sourceID)?.appearances(at: position.time)
            .first { $0.id == request.appearanceID }
    }

    private func tile(_ appearance: ParticipantAppearance, source: ParticipantMonitorPosition, picture: CGRect,
                      project: ParticipantProject, active: Bool, pinned: Bool) -> some View {
        let name = project.people.first { $0.id == appearance.participantID }?.name
            ?? (appearance.state == .presentation ? "Presentation" : "Unassigned")
        let sourceID = source.sourceID
        let selected = presentation.pickedParticipantAppearance == .init(sourceID: sourceID, appearanceID: appearance.id)
        let color: Color = active ? .yellow : pinned || selected ? .accentColor : .white
        let region = Self.position(appearance.bounds.rect, in: picture)
        return Button {
            session.pauseParticipantPlayback()
            presentation.pickedParticipantAppearance = .init(sourceID: sourceID, appearanceID: appearance.id)
            presentation.pinnedParticipant = appearance.participantID
            editingTile = appearance
        } label: {
            Rectangle()
                .fill(color.opacity(0.07))
                .overlay { Rectangle().strokeBorder(color, lineWidth: selected || pinned || active ? 3 : 1.5) }
                .overlay(alignment: .topLeading) {
                    Text(name).font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.8))
                }
                .frame(width: region.width, height: region.height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint("Open tile edits")
        .popover(isPresented: Binding(get: { editingTile?.id == appearance.id }, set: { if !$0 { editingTile = nil } })) {
            if let editingTile {
                ParticipantTileEditor(session: session, source: source, appearance: editingTile)
                    .id(editingTile.id)
            }
        }
        .accessibilityIdentifier("participant.appearance.\(sourceID).\(appearance.id)")
        .position(x: region.midX, y: region.midY)
        .allowsHitTesting(!presentation.participantDrawMode)
    }

    @ViewBuilder
    private func outputControls(_ output: ParticipantPreviewCells, in size: CGSize) -> some View {
        if let layout = session.monitorTileLayout(at: output.time), output.size.width > 0, output.size.height > 0 {
            let picture = Self.pictureRect(in: size, aspect: output.size.width / output.size.height)
            let scale = picture.width / output.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(output.cells.enumerated()), id: \.offset) { _, cell in
                    if cell.slot.target != .empty {
                        let label = session.participantProject.people.first { $0.id == cell.slot.id }?.name
                            ?? session.multicam.project?.angles.first { $0.id == cell.slot.id }?.displayName
                            ?? cell.slot.id
                        ParticipantCellEditor(label: label, size: .init(width: cell.rect.width * scale, height: cell.rect.height * scale),
                                              slot: cell.slot, begin: session.pauseParticipantPlayback) { x, y in
                            try session.reframeMonitorCell(cell.slot, in: layout, at: output.time, anchorX: x, anchorY: y)
                        }
                        .position(x: picture.minX + cell.rect.midX * scale, y: picture.minY + cell.rect.midY * scale)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func resizeHandles(_ tile: ParticipantAppearance, source: ParticipantMonitorPosition,
                               picture: CGRect) -> some View {
        let original = tile.bounds.rect
        let visible = resizing ?? original
        return ZStack(alignment: .topLeading) {
            if let resizing {
                outline(Self.position(resizing, in: picture), color: .accentColor).allowsHitTesting(false)
            }
            ForEach(0..<4) { corner in
                let left = corner.isMultiple(of: 2)
                let top = corner < 2
                let moving = CGPoint(x: left ? original.minX : original.maxX, y: top ? original.minY : original.maxY)
                let fixed = CGPoint(x: left ? original.maxX : original.minX, y: top ? original.maxY : original.minY)
                Circle().fill(.white).overlay { Circle().strokeBorder(.black, lineWidth: 1) }
                    .frame(width: 12, height: 12)
                    .padding(5)
                    .contentShape(Rectangle())
                    .position(x: picture.minX + (left ? visible.minX : visible.maxX) * picture.width,
                              y: picture.minY + (top ? visible.minY : visible.maxY) * picture.height)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            if resizing == nil { session.pauseParticipantPlayback() }
                            resizing = Self.resizedTile(moving: moving, fixed: fixed, translation: value.translation,
                                                        picture: picture.size)
                        }
                        .onEnded { value in
                            let rect = Self.resizedTile(moving: moving, fixed: fixed, translation: value.translation,
                                                        picture: picture.size)
                            resizing = nil
                            guard rect.width >= 0.005, rect.height >= 0.005 else { return }
                            do {
                                let range = try presentation.participantTileExtent.range(session: session, source: source)
                                var project = session.participantProject
                                try project.correctBounds(sourceID: source.sourceID, appearanceID: tile.id,
                                                          bounds: .init(x: rect.minX, y: rect.minY, width: rect.width,
                                                                        height: rect.height), range: range)
                                try session.commitParticipants(project, action: "Correct Tile Bounds")
                            } catch { self.error = error.localizedDescription }
                        })
                    .accessibilityHidden(true)
            }
        }
    }

    private static func resizedTile(moving: CGPoint, fixed: CGPoint, translation: CGSize, picture: CGSize) -> CGRect {
        let start = CGPoint(x: fixed.x * picture.width, y: fixed.y * picture.height)
        let end = CGPoint(x: moving.x * picture.width + translation.width,
                          y: moving.y * picture.height + translation.height)
        return normalizedRect(from: start, to: end, size: picture)
    }

    private func outline(_ region: CGRect, color: Color) -> some View {
        Rectangle().strokeBorder(color, style: .init(lineWidth: 2, dash: [4, 3]))
            .frame(width: region.width, height: region.height)
            .position(x: region.midX, y: region.midY)
    }

    private func speakingParticipantIDs(_ project: ParticipantProject) -> Set<String> {
        let words = ParticipantTranscriptPlayback.bindings(session: session, time: time, indexes: indexes)
        let explicit = project.people.filter { $0.speakers.contains(where: words.contains) }.map(\.id)
        return Set(explicit + words.compactMap { matchedVoices[$0] })
    }

    static func pictureRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return .init(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func normalizedRect(from start: CGPoint, to end: CGPoint, size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let x0 = min(1, max(0, min(start.x, end.x) / size.width))
        let y0 = min(1, max(0, min(start.y, end.y) / size.height))
        let x1 = min(1, max(0, max(start.x, end.x) / size.width))
        let y1 = min(1, max(0, max(start.y, end.y) / size.height))
        return .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func position(_ rect: CGRect, in picture: CGRect) -> CGRect {
        .init(x: picture.minX + rect.minX * picture.width, y: picture.minY + rect.minY * picture.height,
              width: rect.width * picture.width, height: rect.height * picture.height)
    }
}

struct ParticipantSpeakerIndexKey: Equatable {
    let generation: UUID
    let revision: Int
    let transcriptRevision: UInt64

    @MainActor init(session: ProjectSession) {
        generation = session.isMulticam ? session.multicam.mcpGeneration : session.editor.mcpGeneration
        revision = session.transcript.timelineRevision
        transcriptRevision = session.transcript.state.revision
    }
}

@MainActor
enum ParticipantTranscriptPlayback {
    static func bindings(session: ProjectSession, time: RationalTime, indexes: [TranscriptIndex]) -> Set<ParticipantSpeakerBinding> {
        let group = session.isMulticam && !session.multicam.assemblyPreview
        let clock = group ? session.multicam.groupTime(at: time) : time
        guard let end = try? clock.adding(.init(numerator: 1, denominator: 1_000_000_000)) else { return [] }
        var result = Set(indexes.flatMap { index in
            index.overlapping(.init(from: clock, to: end), space: group ? .group : .currentCut)
                .filter { $0.range.contains(clock) }
                .compactMap { word -> ParticipantSpeakerBinding? in
                    guard let attachment = word.attachmentID ?? index.attachment?.id,
                          let speaker = word.speakerID ?? word.originalSpeakerID else { return nil }
                    return .init(attachmentID: attachment, speakerID: speaker)
                }
        })
        if let selected = session.presentation.selectedTranscriptSpeaker, selected.time == time {
            result.insert(selected.binding)
        }
        return result
    }
}
