import AppKit
import MPCutCore
import SwiftUI

extension ProjectSession {
    func presentOutputSettings() {
        guard !hasLifecycleModal else { return }
        isOutputSettingsPresented = true
    }

    var outputSettingsProject: CutProject {
        if isMulticam, let project = multicam.project { return .multicam(project) }
        return editor.stillProject
    }

    var sourceOutputCanvas: ParticipantCanvas {
        let project = outputSettingsProject
        if case .multicam(let multicamProject) = project {
            let streams = multicamProject.recordings(for: multicamProject.referenceAngle).lazy.compactMap {
                self.multicam.media[$0.id]?.videoStream
            }
            if let canvas = streams.compactMap({ project.sourceOutputCanvas(stream: $0) }).first { return canvas }
        } else if let stream = editor.stillReviewCanvas?.videoStream,
                  let canvas = project.sourceOutputCanvas(stream: stream) {
            return canvas
        }
        return project.projectOutputSettings.canvas
    }

    func changeOutputSettings(_ action: String, _ change: (CutProject) throws -> CutProject) throws {
        let current = outputSettingsProject
        let next = try change(current)
        guard current != next else { return }
        if case .multicam(let project) = next {
            guard multicam.edit(action, { $0 = project }) else {
                throw CutError(code: "invalid_project_output", message: "The output settings could not be applied.")
            }
        } else {
            try editor.applyStillProject(next, action: action, installsParticipants: true)
        }
    }
}

@MainActor
struct ProjectOutputSettingsView: View {
    let session: ProjectSession
    @ObservedObject private var editor: EditorModel
    @ObservedObject private var multicam: MulticamEditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingSize = false
    @State private var editingRate = false
    @State private var width = ""
    @State private var height = ""
    @State private var rate = ""
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case width, height, rate }

    private enum Size: String, CaseIterable {
        case hd = "1920 × 1080"
        case uhd = "3840 × 2160"
        case small = "1280 × 720"
        case square = "1080 × 1080"
        case portrait = "1080 × 1920"
        case custom = "Custom…"

        var dimensions: (Int, Int)? {
            switch self {
            case .hd: (1920, 1080)
            case .uhd: (3840, 2160)
            case .small: (1280, 720)
            case .square: (1080, 1080)
            case .portrait: (1080, 1920)
            case .custom: nil
            }
        }

        init(_ canvas: ParticipantCanvas) {
            self = Self.allCases.first { size in
                size.dimensions.map { $0.0 == canvas.width && $0.1 == canvas.height } == true
            } ?? .custom
        }
    }

    init(session: ProjectSession) {
        self.session = session
        editor = session.editor
        multicam = session.multicam
    }

    private var document: CutProject { session.outputSettingsProject }
    private var settings: TileOutputSettings { document.projectOutputSettings }
    private var isStill: Bool { document.stillFormat != nil }
    private var usesOutputCanvas: Bool { document.hasStoredOutputCanvas }
    private var canvas: ParticipantCanvas {
        guard usesOutputCanvas else { return sourceCanvas }
        // A stored canvas without a chosen rate renders at the recording's rate.
        var stored = settings.canvas
        if stored.requestedFrameRate == nil { stored.frameRate = sourceCanvas.frameRate }
        return stored
    }

    private var sourceCanvas: ParticipantCanvas { session.sourceOutputCanvas }
    private var frameRates: [RationalTime] {
        [.init(numerator: 24000, denominator: 1001), .init(numerator: 24),
         .init(numerator: 25), .init(numerator: 30000, denominator: 1001),
         .init(numerator: 30), .init(numerator: 50),
         .init(numerator: 60000, denominator: 1001), .init(numerator: 60)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Settings").font(.title2)
                .accessibilityIdentifier("project.output.title")
            Form {
                sizeControls
                rateControls
                if !isStill {
                    ColorPicker("Background", selection: background, supportsOpacity: false)
                        .accessibilityIdentifier("project.output.background")
                    privacyControl
                }
                LabeledContent("Soundtrack") { soundtrack }
            }
            if let conflict = document.legacyTileCanvasConflict {
                Text(conflict.message).foregroundStyle(.red)
                Button("Use Still Timeline Format") { _ = updateCanvas { _ in } }
                    .accessibilityIdentifier("project.output.resolve_legacy_canvas")
            }
            if let error {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("project.output.error")
            }
            HStack {
                Spacer()
                Button("Done") {
                    if commitDraft() { dismiss() }
                }
                .accessibilityIdentifier("project.output.done")
            }
        }
        .padding(20)
        .frame(width: 455)
        .onAppear {
            loadSize()
            loadRate()
        }
        .onChange(of: canvas) { _, _ in
            if !editingSize { loadSize() }
            if !editingRate { loadRate() }
        }
        .onSubmit {
            _ = commitDraft()
        }
        .onChange(of: focus) { old, new in
            if old == .rate, new != .rate { _ = commitRate() }
            if old == .width || old == .height, new != .width && new != .height { _ = commitSize() }
        }
    }

    private var sizeControls: some View {
        Group {
            Picker("Canvas Size", selection: Binding<Size?>(
                get: { editingSize ? .custom : (usesOutputCanvas ? Size(canvas) : nil) },
                set: { if let value = $0 { selectSize(value) } }
            )) {
                if !usesOutputCanvas { Text("Source Size").tag(Size?.none) }
                ForEach(Size.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .accessibilityIdentifier("project.output.canvas")
            if editingSize || (usesOutputCanvas && Size(canvas) == .custom) {
                TextField("Width", text: $width)
                    .focused($focus, equals: .width)
                    .onChange(of: width) { _, _ in if focus == .width { editingSize = true } }
                    .accessibilityIdentifier("project.output.width")
                TextField("Height", text: $height)
                    .focused($focus, equals: .height)
                    .onChange(of: height) { _, _ in if focus == .height { editingSize = true } }
                    .accessibilityIdentifier("project.output.height")
            }
        }
    }

    private var rateControls: some View {
        Group {
            Picker("Frame Rate", selection: Binding<String>(
                get: {
                    if editingRate { return "custom" }
                    if !usesOutputCanvas { return "source" }
                    return frameRates.contains(canvas.frameRate) ? canvas.frameRate.description : "custom"
                },
                set: { selection in
                    if selection == "custom" { selectRate(nil) }
                    else if let value = frameRates.first(where: { $0.description == selection }) { selectRate(value) }
                }
            )) {
                if !usesOutputCanvas { Text("Source Rate").tag("source") }
                ForEach(frameRates, id: \.self) { value in
                    Text(frameRateLabel(value)).tag(value.description)
                }
                Text("Custom…").tag("custom")
            }
            .accessibilityIdentifier("project.output.frame-rate")
            if editingRate || (usesOutputCanvas && !frameRates.contains(canvas.frameRate)) {
                TextField("Frames per second", text: $rate)
                    .help("Enter a number or a fraction, such as 30000/1001.")
                    .focused($focus, equals: .rate)
                    .onChange(of: rate) { _, _ in if focus == .rate { editingRate = true } }
                    .accessibilityIdentifier("project.output.custom-rate")
            }
        }
    }

    private var background: Binding<Color> {
        Binding {
            let rgb = settings.canvas.background
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let red = UInt32((min(1, max(0, rgb.redComponent)) * 255).rounded())
            let green = UInt32((min(1, max(0, rgb.greenComponent)) * 255).rounded())
            let blue = UInt32((min(1, max(0, rgb.blueComponent)) * 255).rounded())
            _ = updateCanvas { $0.background = red << 16 | green << 8 | blue }
        }
    }

    private var privacyControl: some View {
        Picker("Unchecked Coverage", selection: Binding(get: { settings.unresolvedPrivacy }, set: { value in
            _ = apply("Change Export Coverage Policy") {
                try $0.settingProjectOutputPrivacy(value, defaultCanvas: sourceCanvas)
            }
        })) {
            Text("Stop Export").tag(ParticipantUnresolvedPrivacy.stop)
            Text("Cover Unchecked Picture").tag(ParticipantUnresolvedPrivacy.cover)
        }
        .accessibilityIdentifier("project.output.privacy")
    }

    @ViewBuilder
    private var soundtrack: some View {
        if isStill {
            if let controls = editor.stillSoundtrackControls {
                Menu(controls.name ?? "No Soundtrack") {
                    Button(controls.name == nil ? "Attach Soundtrack…" : "Replace Soundtrack…") {
                        guard commitDraft() else { return }
                        session.afterOutputSettingsDismiss = controls.attach
                        dismiss()
                    }
                    .accessibilityIdentifier("project.output.soundtrack.attach")
                    if controls.name != nil {
                        Button("Fit Image to Soundtrack") {
                            guard commitDraft() else { return }
                            _ = apply("Fit Image to Soundtrack") { try $0.fittingStillToSoundtrack() }
                        }
                        .disabled(!controls.canFit)
                        .accessibilityIdentifier("project.output.soundtrack.fit")
                        Button("Remove Soundtrack") {
                            guard commitDraft() else { return }
                            _ = apply("Remove Soundtrack") { try $0.attachingStillSoundtrack(nil) }
                        }
                        .accessibilityIdentifier("project.output.soundtrack.remove")
                    }
                }
                .accessibilityIdentifier("project.output.soundtrack")
            }
        } else {
            Menu(audioLabel) {
                audioChoice("Program Audio", .init(mode: .program), id: "program")
                audioChoice("Silence", .init(mode: .silence), id: "silence")
                ForEach(document.participants.people.filter { person in
                    guard let binding = document.participants.audioBinding(for: person.id) else { return false }
                    return session.isMulticam || binding.selection != nil
                }) { person in
                    audioChoice("Microphone · " + person.name, .init(mode: .iso, ids: [person.id]), id: "mic.\(person.id)")
                }
                if case .multicam(let project) = document {
                    ForEach(project.angles.filter { angle in
                        project.recordings(for: angle.id).contains { $0.audioStream != nil }
                    }) { angle in
                        audioChoice("Camera · " + angle.displayName, .init(mode: .follow, ids: [angle.id]), id: "camera.\(angle.id)")
                    }
                    if !project.mixLanes.isEmpty {
                        Menu("Audio Lanes") {
                            ForEach(project.mixLanes) { lane in
                                Toggle(lane.label, isOn: Binding(
                                    get: { settings.audio.mode == .lanes && settings.audio.ids.contains(lane.id) },
                                    set: { enabled in
                                        var ids = settings.audio.mode == .lanes ? Set(settings.audio.ids) : []
                                        if enabled { ids.insert(lane.id) } else { ids.remove(lane.id) }
                                        setAudio(ids.isEmpty ? .init(mode: .silence) :
                                                    .init(mode: .lanes, ids: project.mixLanes.map(\.id).filter(ids.contains)))
                                    }
                                ))
                                .accessibilityIdentifier("project.output.soundtrack.lane.\(lane.id)")
                            }
                        }
                        .accessibilityIdentifier("project.output.soundtrack.lanes")
                    }
                }
            }
            .accessibilityLabel("Soundtrack")
            .accessibilityValue(audioLabel)
            .accessibilityIdentifier("project.output.soundtrack")
        }
    }

    private var audioLabel: String {
        switch settings.audio.mode {
        case .program: return "Program Audio"
        case .silence: return "Silence"
        case .iso:
            return document.participants.people.first { $0.id == settings.audio.ids.first }.map { "Microphone · " + $0.name }
                ?? "Feed Microphone"
        case .follow:
            return multicam.project?.angles.first { $0.id == settings.audio.ids.first }.map { "Camera · " + $0.displayName }
                ?? "Camera Audio"
        case .lanes:
            return "Selected Audio Lanes"
        }
    }

    private func audioChoice(_ title: String, _ audio: ParticipantRenderAudio, id: String) -> some View {
        Button { setAudio(audio) } label: {
            if settings.audio == audio { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .accessibilityIdentifier("project.output.soundtrack.\(id)")
    }

    private func setAudio(_ audio: ParticipantRenderAudio) {
        _ = apply("Change Soundtrack") { try $0.settingProjectOutputAudio(audio, defaultCanvas: sourceCanvas) }
    }

    private func loadSize() {
        width = String(canvas.width)
        height = String(canvas.height)
    }

    private func loadRate() { rate = canvas.frameRate.description }

    private func frameRateLabel(_ value: RationalTime) -> String {
        let label = switch value.description {
        case "24000/1001": "23.976"
        case "30000/1001": "29.97"
        case "60000/1001": "59.94"
        default: value.description
        }
        return label + " fps"
    }

    private func selectSize(_ size: Size) {
        guard let (width, height) = size.dimensions else {
            editingSize = true
            focus = .width
            return
        }
        if updateCanvas({
            $0.width = width
            $0.height = height
        }) {
            editingSize = false
            loadSize()
        }
    }

    private func selectRate(_ value: RationalTime?) {
        guard let value else {
            editingRate = true
            focus = .rate
            return
        }
        if updateCanvas({ $0.frameRate = value }) {
            editingRate = false
            loadRate()
        }
    }

    private func commitDraft() -> Bool {
        commitSize() && commitRate()
    }

    private func commitSize() -> Bool {
        guard editingSize else { return true }
        guard let width = Int(width.trimmingCharacters(in: .whitespaces)),
              let height = Int(height.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter a whole number for the width and height."
            return false
        }
        guard updateCanvas({
            $0.width = width
            $0.height = height
        }) else { return false }
        editingSize = false
        return true
    }

    private func commitRate() -> Bool {
        guard editingRate else { return true }
        guard let value = try? RationalTime(parsing: rate.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter a number or fraction for the frame rate."
            return false
        }
        guard updateCanvas({ $0.frameRate = value }) else { return false }
        editingRate = false
        return true
    }

    private func updateCanvas(_ edit: (inout ParticipantCanvas) -> Void) -> Bool {
        var canvas = self.canvas
        edit(&canvas)
        return apply("Change Output Format") { try $0.settingProjectOutputCanvas(canvas) }
    }

    private func apply(_ action: String, _ change: (CutProject) throws -> CutProject) -> Bool {
        do {
            try session.changeOutputSettings(action, change)
            error = nil
            return true
        } catch {
            self.error = (error as? CutError)?.message ?? error.localizedDescription
            return false
        }
    }
}
