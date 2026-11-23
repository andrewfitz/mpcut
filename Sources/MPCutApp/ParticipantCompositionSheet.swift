import AppKit
import MPCutCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ParticipantCompositionSheet: View {
    let session: ProjectSession
    let openProject: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan = ParticipantRenderPlan(shots: [.init(layout: .original)])
    @State private var shotIndex = 0
    @State private var rangeStart = ""
    @State private var rangeEnd = ""
    @State private var shotClock = ParticipantShotClock.output
    @State private var occurrenceOnly = false
    @State private var preview: CGImage?
    @State private var sourcePreview: Data?
    @State private var report: String?
    @State private var error: String?
    @State private var progress: EditCancellation?
    @State private var renderedProject: URL?
    @State private var anglePersonIDs = Set<String>()
    @State private var angleMix = true
    @State private var angleISOs = false
    @State private var angleFrom = "0"
    @State private var angleTo = ""
    @State private var angles: [ParticipantVirtualAngle] = []

    private var project: CutProject { session.transcript.project }
    private var participants: ParticipantProject { project.participants }
    private var document: URL {
        (session.isMulticam ? session.multicam.projectURL : session.editor.projectURL)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Untitled.cut")
    }

    private var targets: [(String, ParticipantSlot)] {
        var choices = participants.people.map { ($0.name, ParticipantSlot(id: $0.id)) }
        if case .multicam(let multicam) = project {
            choices += multicam.angles.map { ($0.displayName, ParticipantSlot(target: .camera, id: $0.id)) }
        }
        if let position = session.participantPosition,
           let source = participants.sources.first(where: { $0.sourceID == position.sourceID }) {
            let ids = Set(source.appearances.filter { $0.state == .presentation }.map(\.id)).sorted()
            choices += ids.enumerated().map { ("Presentation \($0.offset + 1)", ParticipantSlot(target: .presentation, id: $0.element)) }
        }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Participant Composition").font(.title2)
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        canvas
                        Divider()
                        shots
                        Divider()
                        audio
                        Divider()
                        privacy
                        Divider()
                        multicam
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 5)
                }
                .disabled(progress != nil)
                .frame(width: 390, height: 450)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionHeading("Output at Playhead")
                        Spacer()
                        Button("Preview", action: refreshPreview).disabled(progress != nil)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        previewPane("Source") {
                            if let sourcePreview, let image = NSImage(data: sourcePreview) {
                                Image(nsImage: image).resizable().scaledToFit()
                            }
                        }
                        previewPane("Composition") {
                            if let preview {
                                Image(decorative: preview, scale: 1).resizable().scaledToFit()
                            }
                        }
                    }
                    if let report {
                        ScrollView { Text(report).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .frame(width: 400)
            }
            HStack {
                if let progress {
                    ProgressView().controlSize(.small)
                    Button("Cancel Operation", role: .cancel, action: progress.cancel)
                }
                if let renderedProject {
                    Button("Open Rendered Multicam") {
                        dismiss()
                        openProject(renderedProject)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(progress != nil)
                Button("Save Composition", action: save).disabled(progress != nil)
                Button("Check Export", action: checkExport).disabled(progress != nil)
                Button("Export Movie…", action: export).buttonStyle(.borderedProminent).disabled(progress != nil)
            }
        }
        .padding(20)
        .onAppear {
            session.pauseParticipantPlayback()
            if let saved = participants.render { plan = saved }
            if session.isMulticam && !session.multicam.assemblyPreview {
                shotClock = .group
                rangeStart = session.multicam.currentGroupTime().description
            } else {
                rangeStart = session.participantTimelineTime.description
            }
            if let position = session.participantPosition { angleTo = position.media.duration.description }
        }
        .onDisappear { progress?.cancel() }
        .onChange(of: shotClock) { _, clock in
            if clock == .group {
                rangeStart = session.multicam.currentGroupTime().description
            } else {
                rangeStart = compositionPlayhead?.description ?? ""
            }
            rangeEnd = ""
        }
        .onChange(of: plan) { _, _ in
            preview = nil
            sourcePreview = nil
            report = nil
        }
        .alert("Participant Composition", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func previewPane<Picture: View>(_ title: String, @ViewBuilder picture: () -> Picture) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Rectangle().fill(.black)
                picture()
            }
            .frame(height: 112)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Canvas")
            HStack {
                LabeledContent("Width") {
                    TextField("Width", value: $plan.canvas.width, format: .number.grouping(.never))
                        .labelsHidden().frame(width: 60)
                }
                LabeledContent("Height") {
                    TextField("Height", value: $plan.canvas.height, format: .number.grouping(.never))
                        .labelsHidden().frame(width: 60)
                }
            }
            Picker("Frame rate", selection: $plan.canvas.frameRate) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { rate in
                    Text("\(rate) fps").tag(RationalTime(numerator: Int64(rate)))
                }
                if ![24, 25, 30, 50, 60].contains(where: { RationalTime(numerator: Int64($0)) == plan.canvas.frameRate }) {
                    Text(plan.canvas.frameRate.description).tag(plan.canvas.frameRate)
                }
            }
            ColorPicker("Canvas background", selection: colorBinding($plan.canvas.background), supportsOpacity: false)
        }
    }

    private var shots: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Shots")
            Picker("Shot", selection: $shotIndex) {
                ForEach(plan.shots.indices, id: \.self) { index in
                    let shot = plan.shots[index]
                    Text(shot.range.map { "\(shot.clock == .group ? "Group" : "Output") \($0.from.description)–\($0.to.description) s" }
                         ?? "Default Layout").tag(index)
                }
            }
            if plan.shots.indices.contains(shotIndex) {
                shotEditor(index: shotIndex)
            }
            DisclosureGroup("Add Timed Shot") {
                if session.isMulticam {
                    Picker("Clock", selection: $shotClock) {
                        Text("Group").tag(ParticipantShotClock.group)
                        Text("Edited Output").tag(ParticipantShotClock.output)
                    }
                    if shotClock == .output && session.multicam.assemblyPreview {
                        Toggle("Current occurrence only", isOn: $occurrenceOnly)
                    }
                }
                HStack {
                    TextField("From seconds", text: $rangeStart)
                    TextField("To seconds", text: $rangeEnd)
                }
                Button("Add Timed Shot", action: addShot)
            }
        }
    }

    private func shotEditor(index: Int) -> some View {
        let shot = $plan.shots[index]
        let layouts: [ParticipantShotLayout] = [.original, .solo, .pair, .grid, .flow]
        let capacity = slotCapacity(shot.layout.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Layout", selection: Binding(get: { shot.layout.wrappedValue }, set: {
                shot.layout.wrappedValue = $0
                shot.slots.wrappedValue = Array(shot.slots.wrappedValue.prefix(slotCapacity($0)))
                if $0 != .flow { shot.compact.wrappedValue = false }
            })) {
                ForEach(layouts, id: \.self) { layout in
                    Text(layout == .grid ? "Fixed 2 × 2" : layout.rawValue.capitalized).tag(layout)
                }
            }
            if shot.layout.wrappedValue == .flow {
                Toggle("Compact on confirmed absence", isOn: shot.compact)
            }
            ForEach(shot.slots.indices, id: \.self) { slotIndex in
                let slot = shot.slots[slotIndex]
                DisclosureGroup(slotName(slot.wrappedValue)) {
                    Picker("Framing", selection: slot.framing) {
                        Text("Fit").tag(ParticipantSlotFraming.fit)
                        Text("Fill").tag(ParticipantSlotFraming.fill)
                    }
                    HStack {
                        Text("Horizontal anchor")
                        Slider(value: slot.anchorX)
                    }
                    HStack {
                        Text("Vertical anchor")
                        Slider(value: slot.anchorY)
                    }
                    ColorPicker("Slot background", selection: colorBinding(Binding(
                        get: { slot.background.wrappedValue ?? plan.canvas.background },
                        set: { slot.background.wrappedValue = $0 })), supportsOpacity: false)
                    HStack {
                        Button("Move Earlier", systemImage: "arrow.up") {
                            shot.slots.wrappedValue.swapAt(slotIndex, slotIndex - 1)
                        }
                        .disabled(slotIndex == 0)
                        Button("Remove Slot", role: .destructive) { shot.slots.wrappedValue.remove(at: slotIndex) }
                    }
                }
            }
            if shot.slots.count < capacity {
                Menu("Add Slot") {
                    ForEach(targets.indices, id: \.self) { index in
                        Button(targets[index].0) { shot.slots.wrappedValue.append(targets[index].1) }
                    }
                }
                .disabled(targets.isEmpty)
            }
            if plan.shots[index].range != nil {
                Button("Remove Timed Shot", role: .destructive) {
                    plan.shots.remove(at: index)
                    shotIndex = plan.shots.firstIndex { $0.range == nil } ?? 0
                }
            }
        }
    }

    private func slotName(_ slot: ParticipantSlot) -> String {
        targets.first { $0.1.id == slot.id && $0.1.target == slot.target }?.0 ?? slot.id
    }

    private func slotCapacity(_ layout: ParticipantShotLayout) -> Int {
        switch layout {
        case .original: 0
        case .solo: 1
        case .pair: 2
        case .grid, .flow: 4
        }
    }

    private func addShot() {
        perform {
            let from = try RationalTime(parsing: rangeStart)
            let to = try RationalTime(parsing: rangeEnd)
            guard from < to else { throw CutError(code: "invalid_participant_range", message: "Choose a nonempty shot range.") }
            let occurrence = shotClock == .output && occurrenceOnly && session.multicam.assemblyPreview
                ? session.multicam.activeOccurrenceIndex : nil
            var shot = plan.shots[shotIndex]
            shot.clock = shotClock
            shot.range = .init(from: from, to: to)
            shot.occurrence = occurrence
            plan.shots.append(shot)
            shotIndex = plan.shots.count - 1
        }
    }

    private var audio: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Soundtrack")
            Picker("Audio", selection: Binding(get: { plan.audio.mode }, set: { plan.audio = .init(mode: $0) })) {
                Text("Silence").tag(ParticipantAudioMode.silence)
                Text("Program Audio").tag(ParticipantAudioMode.program)
                Text("Participant ISO").tag(ParticipantAudioMode.iso)
                if session.isMulticam {
                    Text("Selected Audio Lanes").tag(ParticipantAudioMode.lanes)
                    Text("Follow Primary Camera").tag(ParticipantAudioMode.follow)
                }
            }
            if plan.audio.mode == .iso {
                Picker("Participant", selection: firstAudioID) {
                    Text("Select Participant").tag("")
                    ForEach(participants.people.filter { $0.audio != nil }) { Text($0.name).tag($0.id) }
                }
            }
            if plan.audio.mode == .follow {
                Picker("Primary Camera", selection: firstAudioID) {
                    Text("Select Camera").tag("")
                    ForEach(session.multicam.project?.angles ?? []) { Text($0.displayName).tag($0.id) }
                }
            }
            if plan.audio.mode == .lanes {
                ForEach(session.multicam.project?.mixLanes ?? []) { lane in
                    Toggle(lane.label, isOn: Binding(get: { plan.audio.ids.contains(lane.id) }, set: { selected in
                        if selected { plan.audio.ids.append(lane.id) }
                        else { plan.audio.ids.removeAll { $0 == lane.id } }
                    }))
                }
            }
        }
    }

    private var firstAudioID: Binding<String> {
        Binding(get: { plan.audio.ids.first ?? "" }, set: { plan.audio.ids = $0.isEmpty ? [] : [$0] })
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Participant Masks")
            ForEach(participants.people) { person in
                Picker(person.name, selection: Binding<ParticipantMaskTreatment?>(
                    get: { plan.redactions.first { $0.participantID == person.id }?.treatment },
                    set: { treatment in
                        plan.redactions.removeAll { $0.participantID == person.id }
                        if let treatment { plan.redactions.append(.init(participantID: person.id, treatment: treatment)) }
                    })) {
                    Text("None").tag(nil as ParticipantMaskTreatment?)
                    Text("Opaque Cover").tag(Optional(ParticipantMaskTreatment.opaque))
                    Text("Blur").tag(Optional(ParticipantMaskTreatment.blur))
                    Text("Remove from Layout").tag(Optional(ParticipantMaskTreatment.omit))
                }
            }
            if !plan.redactions.isEmpty {
                Picker("Unresolved Coverage", selection: $plan.unresolvedPrivacy) {
                    Text("Stop Export").tag(ParticipantUnresolvedPrivacy.stop)
                    Text("Cover Full Frame").tag(ParticipantUnresolvedPrivacy.cover)
                }
            }
        }
    }

    private var multicam: some View {
        DisclosureGroup("Participant Multicam Angles") {
            ForEach(participants.people) { person in
                Toggle(person.name, isOn: Binding(get: { anglePersonIDs.contains(person.id) }, set: { enabled in
                    if enabled { anglePersonIDs.insert(person.id) }
                    else { anglePersonIDs.remove(person.id) }
                    angles = []
                }))
            }
            HStack {
                TextField("Source From", text: $angleFrom)
                TextField("Source To", text: $angleTo)
            }
            Toggle("Meeting mix on one program lane", isOn: $angleMix)
            Toggle("Include bound participant ISOs", isOn: $angleISOs)
            HStack {
                Button("Review Virtual Angles", action: virtualAngles)
                Button("Render Angle Media…", action: renderAngles)
            }
            .disabled(anglePersonIDs.isEmpty || session.participantPosition == nil)
            ForEach(angles) { angle in
                Text("\(angle.name) · \(angle.range.from.description)–\(angle.range.to.description) s").font(.caption)
            }
        }
    }

    private func anglePlan() throws -> [ParticipantVirtualAngle] {
        guard let source = session.participantPosition else {
            throw CutError(code: "missing_source", message: "Park the playhead on the recording to extract.")
        }
        let from = try RationalTime(parsing: angleFrom)
        let to = try RationalTime(parsing: angleTo)
        guard to <= source.media.duration else {
            throw CutError(code: "invalid_participant_range", message: "Choose a range within the selected recording.")
        }
        return try ParticipantMulticam.virtualAngles(participants, sourceID: source.sourceID,
                                                     participantIDs: participants.people.map(\.id).filter(anglePersonIDs.contains),
                                                     range: .init(from: from, to: to))
    }

    private func virtualAngles() {
        perform {
            angles = try anglePlan()
            let requestedAngles = angles
            let project = try documentForRender()
            let source = document
            let canvas = plan.canvas
            let audio = ParticipantMulticamAudioRouting(meetingMix: angleMix, includeISOs: angleISOs)
            run { token in
                try Self.formatted(ParticipantMulticam.report(requestedAngles, project: project, document: source,
                                                               canvas: canvas, audio: audio, cancelled: { token.isCancelled }))
            } onSuccess: { report = $0 }
        }
    }

    private func renderAngles() {
        perform {
            let angles = try anglePlan()
            let project = try documentForRender()
            let source = document
            let canvas = plan.canvas
            let audio = ParticipantMulticamAudioRouting(meetingMix: angleMix, includeISOs: angleISOs)
            let panel = NSSavePanel()
            panel.title = "Create Multicam Angle Folder"
            panel.nameFieldStringValue = "Participant Angles"
            ProjectPanels.present(panel, in: session.window, fromSheet: true) { accepted in
                guard accepted, let destination = panel.url else { return }
                run { token in
                    _ = try ParticipantMulticam.materialize(angles, project: project, document: source, canvas: canvas,
                                                             audio: audio, to: destination, cancelled: { token.isCancelled })
                    return destination.appendingPathComponent("multicam.cut")
                } onSuccess: { url in
                    renderedProject = url
                    report = "Rendered \(angles.count) synchronized angles in \(destination.lastPathComponent)."
                }
            }
        }
    }

    private func save() {
        perform {
            var next = participants
            next.render = plan
            try session.commitParticipants(next, action: "Save Participant Composition")
            report = "Composition saved to the project."
        }
    }

    private var compositionPlayhead: RationalTime? {
        guard session.isMulticam else { return session.participantTimelineTime }
        let model = session.multicam
        let time = model.preview.time
        return MulticamTranscriptPlaybackPosition.resolve(output: time, readerSpace: .currentCut,
                                                           assemblyPreview: model.assemblyPreview,
                                                           interval: model.interval(at: time),
                                                           assemblyItems: model.assemblyItems,
                                                           assemblyStart: model.assemblyStart(at:))?.time
    }

    private func refreshPreview() {
        perform {
            let project = try documentForRender()
            let source = document
            guard let time = compositionPlayhead else {
                throw CutError(code: "ambiguous_output_position", message: "Choose a corresponding Assembly occurrence to preview the edited output.")
            }
            let monitor = session.participantPosition.map { ($0.media, $0.time) }
            run { token in
                let picture = try ParticipantRenderer(cancelled: { token.isCancelled }).frame(project, document: source, at: time)
                let sourceData = monitor.flatMap { media, time in
                    let index = media.hasFullEditIndex ? media
                        : (try? CutEngine(cancelled: { token.isCancelled }).inspectForPreview(media.url))
                    return index.flatMap { try? JPEGExport.reviewFrame($0, at: time, exclusiveEnd: false,
                                                                       cancelled: { token.isCancelled }).0 }
                }
                return (picture, sourceData)
            } onSuccess: { picture, sourceData in
                preview = picture
                sourcePreview = sourceData
            }
        }
    }

    private func checkExport() {
        perform {
            let project = try documentForRender()
            let source = document
            run { token in
                try ParticipantRenderer(cancelled: { token.isCancelled }).report(project, document: source)
            } onSuccess: { report = Self.summary($0) }
        }
    }

    private func export() {
        perform {
            let project = try documentForRender()
            let source = document
            run { token in
                try ParticipantRenderer(cancelled: { token.isCancelled }).report(project, document: source)
            } onSuccess: { checked in
                report = Self.summary(checked)
                guard checked.publishable else { return }
                let panel = NSSavePanel()
                panel.title = "Export Participant Composition"
                panel.allowedContentTypes = [.quickTimeMovie]
                panel.nameFieldStringValue = "Participant Composition.mov"
                panel.message = "Review the canvas, soundtrack, and duration in the composition panel."
                ProjectPanels.present(panel, in: session.window, fromSheet: true) { accepted in
                    guard accepted, let destination = panel.url else { return }
                    perform {
                        if session.isMulticam { try session.multicam.validateHistoryDestination(destination) }
                        else { try session.editor.validateHistoryDestination(destination) }
                        run { token in
                            try ParticipantRenderer(cancelled: { token.isCancelled })
                                .render(project, document: source, to: destination)
                        } onSuccess: { report = "Exported \(destination.lastPathComponent).\n\n" + Self.summary($0) }
                    }
                }
            }
        }
    }

    private func documentForRender() throws -> CutProject {
        var next = project
        next.participants.render = plan
        try next.validate()
        return next
    }

    private func run<Output: Sendable>(_ work: @escaping @Sendable (EditCancellation) throws -> Output,
                                       onSuccess: @escaping (Output) -> Void) {
        guard progress == nil else { return }
        let token = EditCancellation()
        progress = token
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work(token) } }.value
            guard progress === token else { return }
            progress = nil
            guard !token.isCancelled else { return }
            switch result {
            case .success(let value): onSuccess(value)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() }
        catch { self.error = error.localizedDescription }
    }

    private static func summary(_ checked: ParticipantRenderReport) -> String {
        var lines = ["\(checked.canvas.width) × \(checked.canvas.height) at \(checked.canvas.frameRate.description) fps",
                     "\(checked.duration.description) s · \(checked.frameCount) frames",
                     "Audio · \(checked.audioActions.isEmpty ? "Silence" : checked.audio.mode.rawValue.capitalized)"]
        for action in checked.audioActions {
            let streams = action.sources.map { "\($0.file.lastPathComponent), stream \($0.stream)" }
            lines.append(action.label ?? Set(streams).sorted().joined(separator: " · "))
        }
        if !checked.privacyIssues.isEmpty {
            lines.append(checked.publishable ? "Full-frame cover for unresolved intervals" : "Export blocked by unresolved coverage")
            lines += checked.privacyIssues.prefix(12).map {
                "\($0.sourceID) · source \($0.source.from.description)–\($0.source.to.description) s, output \($0.output.from.description)–\($0.output.to.description) s"
            }
            if checked.privacyIssues.count > 12 { lines.append("Showing 12 of \(checked.privacyIssues.count) intervals.") }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func formatted(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func colorBinding(_ value: Binding<UInt32>) -> Binding<Color> {
        Binding(get: {
            let rgb = value.wrappedValue
            return Color(red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let red = UInt32((rgb.redComponent * 255).rounded())
            let green = UInt32((rgb.greenComponent * 255).rounded())
            let blue = UInt32((rgb.blueComponent * 255).rounded())
            value.wrappedValue = (red << 16) | (green << 8) | blue
        })
    }
}
