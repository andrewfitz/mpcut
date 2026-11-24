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
    let hasUncertainAppearance: Bool

    init(_ source: ParticipantSourceGeometry) {
        index = ParticipantAppearanceIndex(source.appearances)
        intervals = source.coverage.sorted { $0.range.from < $1.range.from }
        hasUncertainAppearance = source.appearances.contains { $0.participantID == nil && $0.state != .presentation }
    }

    func appearances(at time: RationalTime) -> [ParticipantAppearance] { index.at(time) }

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
            return .init(sourceID: picture.source, media: media, time: sourceTime)
        }
        guard let sequence, let source = editor.jpegSourceAtPlayhead, source.media.url == sequence.url else { return nil }
        return .init(sourceID: source.media.url.path, media: source.media, time: sequence.time)
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

    func seekParticipant(sourceID: String, range: MulticamRange) {
        if isMulticam { multicam.seekParticipantAppearance(sourceID: sourceID, range: range) }
        else { editor.seekParticipantAppearance(sourceID: sourceID, range: range) }
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
    @State private var drawing: CGRect?

    init(session: ProjectSession, interactive: Bool) {
        self.session = session
        self.interactive = interactive
        _presentation = ObservedObject(wrappedValue: session.presentation)
    }

    var body: some View {
        let project = session.participantProject
        let speakers = speakingParticipantIDs(project)
        GeometryReader { geometry in
            if let source = session.participantPosition(displaying: displayedPicture, sequence: sequencePicture),
               !source.needsReconciliation(in: project) {
                let picture = Self.pictureRect(in: geometry.size, aspect: source.aspect)
                let appearances = session.participantGeometry(for: source.sourceID)?.appearances(at: source.time) ?? []
                ZStack(alignment: .topLeading) {
                    ForEach(appearances) { appearance in
                        let active = appearance.participantID.map(speakers.contains) ?? false
                        let pinned = appearance.participantID != nil && appearance.participantID == presentation.pinnedParticipant
                        if interactive || active || pinned {
                            tile(appearance, sourceID: source.sourceID, picture: picture, project: project, active: active, pinned: pinned)
                        }
                    }
                    if interactive && appearances.isEmpty && !presentation.participantDrawMode {
                        ForEach(scanPreviewRegions(for: source), id: \.appearanceID) { region in
                            let rect = CGRect(x: region.rect.x, y: region.rect.y,
                                              width: region.rect.width, height: region.rect.height)
                            outline(Self.position(rect, in: picture), color: .orange)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    if interactive && presentation.participantDrawMode {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .frame(width: picture.width, height: picture.height)
                            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                                drawing = Self.normalizedRect(from: value.startLocation, to: value.location, size: picture.size)
                            }.onEnded { value in
                                let rect = Self.normalizedRect(from: value.startLocation, to: value.location, size: picture.size)
                                drawing = nil
                                guard rect.width >= 0.005, rect.height >= 0.005 else { return }
                                presentation.participantDrawnBounds = .init(
                                    sourceID: source.sourceID, time: source.time,
                                    bounds: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
                                presentation.participantDrawMode = false
                            })
                            .position(x: picture.midX, y: picture.midY)
                        if let drawing {
                            outline(Self.position(drawing, in: picture), color: .accentColor)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(interactive)
            }
        }
        .onReceive(session.participantPlayback.receive(on: DispatchQueue.main)) { next in
            if let selected = presentation.selectedTranscriptSpeaker, next != selected.time {
                presentation.selectedTranscriptSpeaker = nil
            }
            time = next
        }
        .onReceive(session.multicam.preview.$picture.receive(on: DispatchQueue.main)) { picture in
            if session.isMulticam, displayedPicture != picture { displayedPicture = picture }
        }
        .onReceive(session.editor.preview.sourcePicture) { picture in
            if !session.isMulticam, sequencePicture != picture { sequencePicture = picture }
        }
        .onChange(of: speakers, initial: true) { _, value in
            presentation.speakingParticipants = value
        }
        .task(id: ParticipantSpeakerIndexKey(session: session)) {
            indexes = []
            let ids = Set(project.people.flatMap { $0.speakers.map(\.attachmentID) })
            var loaded: [TranscriptIndex] = []
            for attachment in session.transcript.state.attachments where ids.contains(attachment.id) {
                if let index = try? await session.transcript.indexedTranscript(attachmentID: attachment.id) {
                    loaded.append(index)
                }
            }
            if !Task.isCancelled { indexes = loaded }
        }
    }

    private func scanPreviewRegions(for position: ParticipantMonitorPosition) -> [ParticipantRegion] {
        guard let preview = presentation.participantScanPreview, preview.sourceID == position.sourceID,
              preview.stamp == SceneSourceStamp(media: position.media),
              preview.analysis.start <= position.time, position.time < preview.analysis.end else { return [] }
        let observations = preview.analysis.observations
        let after = observations.lowerBound { $0.time > position.time }
        return after > 0 ? observations[after - 1].regions : []
    }

    private func tile(_ appearance: ParticipantAppearance, sourceID: String, picture: CGRect,
                      project: ParticipantProject, active: Bool, pinned: Bool) -> some View {
        let name = project.people.first { $0.id == appearance.participantID }?.name
            ?? (appearance.state == .presentation ? "Presentation" : "Unassigned")
        let selected = presentation.pickedParticipantAppearance == .init(sourceID: sourceID, appearanceID: appearance.id)
        let color: Color = active ? .yellow : pinned || selected ? .accentColor : .white
        let region = Self.position(appearance.bounds.rect, in: picture)
        return Button {
            presentation.pickedParticipantAppearance = .init(sourceID: sourceID, appearanceID: appearance.id)
            presentation.pinnedParticipant = appearance.participantID
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
        .accessibilityHint("Select this appearance")
        .position(x: region.midX, y: region.midY)
        .allowsHitTesting(interactive && !presentation.participantDrawMode)
    }

    private func outline(_ region: CGRect, color: Color) -> some View {
        Rectangle().strokeBorder(color, style: .init(lineWidth: 2, dash: [4, 3]))
            .frame(width: region.width, height: region.height)
            .position(x: region.midX, y: region.midY)
    }

    private func speakingParticipantIDs(_ project: ParticipantProject) -> Set<String> {
        let words = ParticipantTranscriptPlayback.bindings(session: session, time: time, indexes: indexes)
        return Set(project.people.filter { $0.speakers.contains(where: words.contains) }.map(\.id))
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
