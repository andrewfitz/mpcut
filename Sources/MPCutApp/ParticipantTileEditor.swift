import MPCutCore
import SwiftUI

enum ParticipantTileEditExtent: String, CaseIterable, Identifiable {
    case fromHere = "From Here On"
    case untilChange = "Until Next Layout Change"
    case whole = "Whole Recording"
    case marked = "Marked Range"

    var id: Self { self }

    @MainActor
    func range(session: ProjectSession, source: ParticipantMonitorPosition) throws -> MulticamRange {
        let range: MulticamRange?
        switch self {
        case .fromHere:
            range = .init(from: source.time, to: source.duration)
        case .untilChange:
            let changes = session.participantProject.sources.first { $0.sourceID == source.sourceID }?.layoutChangeTimes ?? []
            range = .init(from: source.time, to: changes.first { $0 > source.time } ?? source.duration)
        case .whole:
            range = .init(from: .zero, to: source.duration)
        case .marked:
            range = session.participantMarkedSourceRange(sourceID: source.sourceID)
        }
        guard let range, .zero <= range.from, range.from < range.to, range.to <= source.duration else {
            throw CutError(code: "invalid_tile_range", message: "Set both marks within this occurrence of the recording.")
        }
        return range
    }
}

@MainActor
struct ParticipantTileEditor: View {
    let session: ProjectSession
    let source: ParticipantMonitorPosition
    let appearance: ParticipantAppearance
    let allowsLayoutEdits: Bool

    @ObservedObject private var presentation: EditorPresentation
    @State private var proposedBounds: ParticipantBounds
    @State private var name: String
    @State private var error: String?

    init(session: ProjectSession, source: ParticipantMonitorPosition, appearance: ParticipantAppearance,
         allowsLayoutEdits: Bool = true) {
        self.session = session
        self.source = source
        self.appearance = appearance
        self.allowsLayoutEdits = allowsLayoutEdits
        _presentation = ObservedObject(wrappedValue: session.presentation)
        _proposedBounds = State(initialValue: appearance.bounds)
        _name = State(initialValue: session.participantProject.people.first { $0.id == appearance.participantID }?.name ?? "")
    }

    private var participantID: String? {
        session.participantGeometry(for: source.sourceID)?.appearances(at: source.time)
            .first(where: { $0.id == appearance.id })?.participantID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let participantID {
                HStack {
                    Menu("Treatment") {
                        Button("None") { setTreatment(nil, id: participantID) }
                        Button("Hide") { setTreatment(.cover, id: participantID) }
                            .accessibilityIdentifier("tiles.tile.hide")
                        Button("Blur") { setTreatment(.blur, id: participantID) }
                            .accessibilityIdentifier("tiles.tile.blur")
                        Button("Remove Feed") { setTreatment(.remove, id: participantID) }
                    }
                    if allowsLayoutEdits {
                        Button("Solo") { applyLayout(.solo, slots: [.init(id: participantID, framing: .fill)]) }
                            .accessibilityIdentifier("tiles.tile.solo")
                        Menu("Swap With…") {
                            ForEach(otherVisibleFeeds, id: \.id) { person in
                                Button(person.name) { swap(with: person.id) }
                            }
                        }
                        .disabled(otherVisibleFeeds.isEmpty)
                    }
                }
                HStack {
                    TextField("Feed name", text: $name)
                    Button("Rename") {
                        change("Rename Feed") { project in
                            try project.renameFeed(participantID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if allowsLayoutEdits {
                Button("Leave This Tile Empty") {
                    let slot = ParticipantSlot(target: .empty, id: appearance.id)
                    applyLayout(.arranged, slots: TileArrangement.replacing([slot], in: currentArrangement))
                }
            }
            Divider()
            Picker("Apply correction", selection: $presentation.participantTileExtent) {
                ForEach(ParticipantTileEditExtent.allCases) { label in Text(label.rawValue).tag(label) }
            }
            .accessibilityIdentifier("tiles.tile.extent")
            Menu("Assign Feed") {
                Button("Unassigned") { assign(nil) }
                ForEach(session.participantProject.people, id: \.id) { person in
                    Button(person.name) { assign(person.id) }
                }
            }
            HStack {
                Button("Mark as Screen Share") {
                    change("Mark Screen Share") {
                        _ = try $0.setScreenShare(sourceID: source.sourceID, appearanceID: appearance.id, range: correctionRange())
                    }
                }
                if let participantID {
                    Button("Prefer This Tile") {
                        change("Prefer Tile") { project in
                            try project.preferTile(sourceID: source.sourceID, feedID: participantID,
                                                   tileID: appearance.id, range: correctionRange())
                        }
                    }
                    .accessibilityIdentifier("tiles.tile.prefer")
                    if session.participantProject.appearanceOverrides.contains(where: {
                        $0.sourceID == source.sourceID && $0.participantID == participantID
                    }) {
                        Button("Use Automatic Tile Choice") {
                            change("Clear Preferred Tile") { project in
                                try project.preferTile(sourceID: source.sourceID, feedID: participantID,
                                                       tileID: nil, range: correctionRange())
                            }
                        }
                    }
                }
            }
            Grid(alignment: .leading) {
                GridRow {
                    coordinate("Left", value: $proposedBounds.x)
                    coordinate("Top", value: $proposedBounds.y)
                }
                GridRow {
                    coordinate("Width", value: $proposedBounds.width)
                    coordinate("Height", value: $proposedBounds.height)
                }
            }
            Button("Apply Bounds") {
                change("Correct Tile Bounds") {
                    try $0.correctBounds(sourceID: source.sourceID, appearanceID: appearance.id,
                                         bounds: proposedBounds, range: correctionRange())
                }
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var otherVisibleFeeds: [ParticipantPerson] {
        let tiles = session.participantGeometry(for: source.sourceID)?.appearances(at: source.time) ?? []
        let ids = Set(tiles.compactMap(\.participantID))
        return session.participantProject.people.filter { $0.id != participantID && ids.contains($0.id) }
    }

    private func coordinate(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: value, format: .number)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    private func setTreatment(_ mode: ParticipantFeedTreatment.Mode?, id: String) {
        do {
            let color = session.participantProject.people.first(where: { $0.id == id })?.treatment?.color ?? 0
            let feedTreatment = mode.map { ParticipantFeedTreatment(mode: $0, color: color) }
            let next = try session.transcript.project.settingFeedTreatment(feedID: id, treatment: feedTreatment)
            try session.commitTileDocument(next, action: "Change Feed Treatment")
            presentation.participantMonitorSource = false
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func swap(with other: String) {
        let visible = session.participantGeometry(for: source.sourceID)?.appearances(at: source.time) ?? []
        guard let selected = visible.first(where: { $0.id == appearance.id }),
              let destination = session.participantProject.resolveAppearance(participantID: other,
                                                                              sourceID: source.sourceID, at: source.time) else { return }
        applyLayout(.arranged, slots: TileArrangement.swapping(selected, with: destination, in: currentArrangement))
    }

    private var currentArrangement: [ParticipantSlot] {
        let active = session.monitorTileLayout(at: session.participantTimelineTime)?.layout
        return active?.layout == .arranged ? active?.slots ?? [] : []
    }

    private func applyLayout(_ layout: ParticipantShotLayout, slots: [ParticipantSlot]) {
        do {
            guard allowsLayoutEdits, let displayed = session.participantPosition,
                  displayed.sourceID == source.sourceID, displayed.time == source.time else {
                throw CutError(code: "stale_tile_layout", message: "Park the playhead on this tile to change its layout.")
            }
            if session.isMulticam {
                try session.multicam.setTileLayout(layout, slots: slots, at: session.participantTimelineTime, position: displayed)
            } else {
                try session.editor.setMonitorTileLayout(layout, slots: slots, position: displayed)
            }
            session.presentation.participantMonitorSource = false
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func correctionRange() throws -> MulticamRange { try presentation.participantTileExtent.range(session: session, source: source) }

    private func assign(_ id: String?) {
        change("Assign Tile") {
            try $0.linkAppearance(sourceID: source.sourceID, appearanceID: appearance.id,
                                  participantID: id, range: correctionRange())
        }
    }

    private func change(_ action: String, _ update: (inout ParticipantProject) throws -> Void) {
        var project = session.participantProject
        do {
            try update(&project)
            try session.commitParticipants(project, action: action)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

enum TileArrangement {
    static func replacing(_ slots: [ParticipantSlot], in existing: [ParticipantSlot]) -> [ParticipantSlot] {
        let replaced = Set(slots.compactMap(\.arrangedDestination))
        return existing.filter { $0.arrangedDestination.map(replaced.contains) != true } + slots
    }

    static func swapping(_ first: ParticipantAppearance, with second: ParticipantAppearance,
                         in existing: [ParticipantSlot]) -> [ParticipantSlot] {
        func moved(_ origin: ParticipantAppearance, into destination: ParticipantAppearance) -> ParticipantSlot {
            var slot = existing.first { $0.arrangedDestination == origin.id }
                ?? origin.participantID.map { .init(id: $0, framing: .fill) }
                ?? .init(target: .empty, id: origin.id)
            slot.destinationTileID = destination.id
            return slot
        }
        return replacing([moved(first, into: second), moved(second, into: first)], in: existing)
    }
}

struct ParticipantMonitorLayout: Equatable {
    let scope: TileLayoutScope
    var layout: TileLayoutSpan
}

extension ProjectSession {
    func monitorTileLayout(at output: RationalTime) -> ParticipantMonitorLayout? {
        guard isMulticam else { return editor.monitorTileLayout(at: output) }
        guard let project = multicam.project, let interval = multicam.interval(at: output) else { return nil }
        let group = multicam.groupTime(at: output)
        if multicam.assemblyPreview, let items = project.assemblyItems, items.indices.contains(interval.assemblyIndex),
           let occurrenceID = project.tileOccurrenceID(at: interval.assemblyIndex),
           let layout = items[interval.assemblyIndex].tileLayouts.first(where: { $0.range.contains(group) }) {
            return .init(scope: .occurrence(occurrenceID), layout: layout)
        }
        return project.groupTileLayouts.first { $0.range.contains(group) }
            .map { .init(scope: .group, layout: $0) }
    }

    func reframeMonitorCell(_ slot: ParticipantSlot, in original: ParticipantMonitorLayout,
                            at output: RationalTime, anchorX: Double, anchorY: Double) throws {
        guard monitorTileLayout(at: output) == original,
              let index = original.layout.slots.firstIndex(of: slot) else {
            throw CutError(code: "stale_tile_layout", message: "The layout changed. Select the cell again.")
        }
        var span = original.layout
        span.slots[index].anchorX = min(1, max(0, anchorX))
        span.slots[index].anchorY = min(1, max(0, anchorY))
        var scope = original.scope
        if scope == .group, isMulticam && multicam.assemblyPreview,
           let index = multicam.interval(at: output)?.assemblyIndex,
           let group = multicam.assemblyRange(at: index),
           let occurrence = multicam.project?.tileOccurrenceID(at: index),
           let retained = span.range.tileIntersection(group) {
            scope = .occurrence(occurrence)
            span.range = retained
        }
        let next = try transcript.project.settingTileLayout(scope: scope, range: span.range, layout: span,
                                                           relativeTo: isMulticam ? multicam.projectURL : editor.projectURL)
        try commitTileDocument(next, action: "Reframe Tile")
    }

    func commitTileDocument(_ document: CutProject, action: String) throws {
        if isMulticam { try multicam.replaceTileLayoutProject(document, action: action) }
        else { try editor.replaceTileLayoutProject(document, action: action) }
    }

    func participantMarkedSourceRange(sourceID: String) -> MulticamRange? {
        guard isMulticam else { return editor.participantMarkedSourceRange(sourceID: sourceID) }
        guard let project = multicam.project,
              let recording = project.sources.first(where: { $0.id == sourceID }),
              let interval = multicam.interval(at: multicam.preview.time),
              let pictureSource = project.pictureSources.first(where: { $0.id == interval.pictureSourceID }),
              (pictureSource.feedAngle?.sourceID ?? pictureSource.id) == sourceID,
              let offset = try? recording.offset.adding(multicam.media[sourceID]?.multicamClockOffset ?? .zero) else { return nil }
        let occurrence = multicam.occurrenceIndex(at: multicam.preview.time)
        let group = multicam.assemblyRange(at: occurrence)
        let marked: MulticamRange
        if let selection = multicam.assemblySelection {
            guard let group, multicam.assemblyRangeEnds.indices.contains(occurrence) else { return nil }
            let base = multicam.assemblyStart(at: occurrence)
            guard base <= selection.from, selection.from < selection.to, selection.to <= multicam.assemblyRangeEnds[occurrence],
                  let from = try? group.from.adding(selection.from.subtracting(base)),
                  let to = try? group.from.adding(selection.to.subtracting(base)) else { return nil }
            marked = .init(from: from, to: to)
        } else {
            let available = multicam.assemblyPreview ? group : project.range
            guard let from = multicam.markIn, let to = multicam.markOut, let available,
                  available.from <= from, from < to, to <= available.to else { return nil }
            marked = .init(from: from, to: to)
        }
        guard let start = try? marked.from.subtracting(offset), let end = try? marked.to.subtracting(offset),
              start >= .zero else { return nil }
        return .init(from: start, to: end)
    }
}

struct ParticipantCellEditor: View {
    let label: String
    let size: CGSize
    let slot: ParticipantSlot
    let begin: () -> Void
    let apply: (Double, Double) throws -> Void

    @State private var anchorX: Double
    @State private var anchorY: Double
    @State private var error: String?
    @State private var showing = false

    init(label: String, size: CGSize, slot: ParticipantSlot, begin: @escaping () -> Void,
         apply: @escaping (Double, Double) throws -> Void) {
        self.label = label
        self.size = size
        self.slot = slot
        self.begin = begin
        self.apply = apply
        _anchorX = State(initialValue: slot.anchorX)
        _anchorY = State(initialValue: slot.anchorY)
    }

    var body: some View {
        Button {
            begin()
            anchorX = slot.anchorX
            anchorY = slot.anchorY
            showing = true
        } label: {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reframe \(label)")
        .help("Drag to reframe \(label).")
        .gesture(DragGesture(minimumDistance: 4).onChanged { _ in begin() }.onEnded { value in
            guard size.width > 0, size.height > 0 else { return }
            commit(slot.anchorX - value.translation.width / size.width,
                   slot.anchorY - value.translation.height / size.height)
        })
        .contextMenu {
            Button("Reframe…") {
                begin()
                anchorX = slot.anchorX
                anchorY = slot.anchorY
                showing = true
            }
            Button("Center") {
                begin()
                commit(0.5, 0.5)
            }
        }
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Horizontal position (0–1)", value: $anchorX, format: .number)
                TextField("Vertical position (0–1)", value: $anchorY, format: .number)
                Button("Apply Reframe") {
                    if commit(anchorX, anchorY) { showing = false }
                }
                .disabled(!(0...1).contains(anchorX) || !(0...1).contains(anchorY))
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(14)
            .frame(width: 265)
        }
    }

    @discardableResult
    private func commit(_ x: Double, _ y: Double) -> Bool {
        do {
            try apply(x, y)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            showing = true
            return false
        }
    }
}
