import SwiftUI
import MPCutCore

private typealias TranscriptEngines = TranscriptEngineCatalog

struct TranscriptSetupTarget: Hashable {
    let file: URL
    let sourceID: String?
    let stream: Int
    let channel: Int?

    func matches(_ track: TranscriptJobTrack) -> Bool {
        track.streamIndex == stream && (track.file.standardizedFileURL == file.standardizedFileURL ||
                                        sourceID.map { track.projectSourceID == $0 } == true)
    }
}

struct TranscriptSetupRequest: Equatable {
    let id = UUID()
    let targets: Set<TranscriptSetupTarget>
}

struct TranscriptJobSetup: View {
    let controller: LiveTranscriptController
    var targets: Set<TranscriptSetupTarget> = []
    let start: (TranscriptJobOptions, Bool) throws -> Void
    /// Read from Settings once, when the sheet is made.
    @State private var defaults: TranscriptSheetDefaults
    @Environment(\.dismiss) private var dismiss
    @State private var showsOptions = false
    @State private var contentHeight: CGFloat = 160
    @State private var tracks: [TranscriptJobTrack] = []
    @State private var excluded: Set<String> = []
    @State private var trackOptions: [String: TranscriptJobTrackOptions] = [:]
    @State private var channelText: [String: String] = [:]
    @State private var engines: [TranscriptEngines.Engine] = []
    @State private var supportsPlan = false
    @State private var zoomSuggestions: [String: [TranscriptZoomParticipant]] = [:]
    @State private var zoomOverrides: [String: Bool] = [:]
    @State private var checkingZoom = true
    @State private var skipDiscovery = false
    @State private var cancelZoomQuery: (() -> Void)?
    @State private var discoveryFailures: [String] = []
    @State private var speakerEdits: [String: [String: String]] = [:]
    @State private var selectedEngine = ""
    @State private var engineIssue: String?
    @State private var language: String?
    @State private var model = ""
    @State private var speakerCount = ""
    @State private var diarization = false
    @State private var download: Bool
    @State private var providerStatus: String? = "Checking Transcriberrr…"
    @State private var readingTracks = true
    @State private var loadAttempt = 0
    @State private var providerError: String?
    @State private var inventoryError: String?
    private var loading: Bool { providerStatus != nil || readingTracks || (checkingZoom && !skipDiscovery) }
    private func usesZoom(_ id: String) -> Bool {
        guard let participants = zoomSuggestions[id] else { return false }
        return zoomOverrides[id] ?? (Set(participants.map(\.speaker)).count > 1)
    }

    private var hasMixedAudio: Bool {
        tracks.contains { track in
            track.streamIndex != nil && !excluded.contains(track.id) && !usesZoom(track.id)
                && (trackOptions[track.id]?.role ?? track.role) != TranscriptRole.isolatedMic.rawValue
        }
    }
    @State private var error: String?

    init(controller: LiveTranscriptController, targets: Set<TranscriptSetupTarget> = [], defaults: TranscriptSheetDefaults,
         start: @escaping (TranscriptJobOptions, Bool) throws -> Void) {
        self.controller = controller
        self.targets = targets
        self.start = start
        _defaults = State(initialValue: defaults)
        _download = State(initialValue: defaults.downloadsModels)
    }

    private var engine: TranscriptEngines.Engine? { engines.first { $0.name == selectedEngine } }
    private var duration: Double {
        tracks.lazy.filter { $0.streamIndex != nil && !excluded.contains($0.id) }
            .reduce(0) { $0 + $1.duration.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !tracks.isEmpty { sources }
                    if let progress = providerStatus ?? (readingTracks ? "Reading audio streams…" : nil) {
                        ProgressView(progress).controlSize(.small)
                    } else if checkingZoom && supportsPlan && !skipDiscovery {
                        HStack {
                            ProgressView("Looking for Zoom speaker tracks…").controlSize(.small)
                            Spacer()
                            Button("Skip search") {
                                skipDiscovery = true
                                cancelZoomQuery?()
                            }
                            .controlSize(.small)
                        }
                    }
                    if !engines.isEmpty { settings }
                }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(360, ceil(contentHeight)))
            if let issue = [providerError, inventoryError, error].compactMap({ $0 }).first {
                IssueLabel(issue).accessibilityIdentifier("transcript.setup.error")
            }
            if !discoveryFailures.isEmpty {
                Text("Couldn’t check for participant audio in " + discoveryFailures.joined(separator: ", ") + ".")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .help(discoveryFailures.joined(separator: ", "))
            }
            Divider()
            HStack(spacing: 8) {
                if providerError != nil || inventoryError != nil || !discoveryFailures.isEmpty {
                    Button("Try Again") { loadAttempt += 1 }.disabled(loading)
                } else if duration > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(timelineTime(duration)) of audio")
                        if !zoomSuggestions.keys.contains(where: { usesZoom($0) && !excluded.contains($0) }),
                           let factor = engine?.estimated_realtime_factor, factor.isFinite, factor > 0 {
                            Text("Est. \(timelineTime(duration * factor)) to transcribe")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Transcribe") { submit() }
                    .accessibilityIdentifier("transcript.start")
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || engine?.available != true || !tracks.contains { $0.streamIndex != nil && !excluded.contains($0.id) })
            }
        }
        .task(id: loadAttempt) {
            checkingZoom = true
            skipDiscovery = false
            discoveryFailures = []
            defer { checkingZoom = false }
            supportsPlan = false
            zoomSuggestions = [:]
            engines = []
            tracks = []
            providerError = nil
            inventoryError = nil
            error = nil
            readingTracks = true
            providerStatus = "Checking Transcriberrr…"
            async let inventory: Void = loadTracks()
            await loadCapabilities()
            await inventory
            if supportsPlan && !Task.isCancelled { await discoverZoom() }
        }
    }

    @MainActor private func loadCapabilities() async {
        defer { providerStatus = nil }
        do {
            let data = try await controller.capabilities { providerStatus = $0 }
            let capabilities = try TranscriptEngines.read(data)
            engines = capabilities.engines
            if let inventory = capabilities.automation?.zoom_iso_inventory {
                supportsPlan = inventory == ["--plan", "--inventory-only", "--offline"]
            } else {
                supportsPlan = capabilities.automation?.plan == "--plan"
            }
            if engines.contains(where: { $0.available && $0.name == selectedEngine }) { return }
            // Settings names the engine. One that cannot run here says why and keeps the preference.
            let choice = capabilities.resolve(preferred: defaults.engine)
            engineIssue = choice.issue
            selectedEngine = choice.engine ?? ""
            seedSpeakers()
        } catch {
            if !Task.isCancelled { providerError = error.localizedDescription }
        }
    }

    @MainActor private func loadTracks() async {
        defer { readingTracks = false }
        do {
            let result = try await controller.tracks()
            try Task.checkCancellation()
            tracks = result
            if !targets.isEmpty {
                var matching: [String: [TranscriptSetupTarget]] = [:]
                for track in result {
                    let candidates = targets.filter { $0.matches(track) }
                    if !candidates.isEmpty { matching[track.id] = Array(candidates) }
                }
                excluded = Set(result.map(\.id)).subtracting(matching.keys)
                for track in result {
                    guard let sources = matching[track.id],
                          let source = sources.first, let channel = source.channel,
                          sources.allSatisfy({ $0.channel == channel }) else { continue }
                    trackOptions[track.id] = .init(channel: channel, role: track.role, speaker: track.speaker)
                    channelText[track.id] = String(channel + 1)
                }
                if matching.isEmpty { inventoryError = "The affected audio tracks are unavailable." }
            }
        } catch {
            if !Task.isCancelled { inventoryError = error.localizedDescription }
        }
    }

    @MainActor private func discoverZoom() async {
        guard let helper = try? controller.helperURL() else { return }
        let placements = Dictionary(grouping: tracks.filter { $0.streamIndex != nil }, by: \.file)
            .filter { Set($0.value.compactMap(\.streamIndex)).count == 1 }
        let folders = Dictionary(grouping: placements.keys, by: { $0.deletingLastPathComponent() })
        for files in folders.values {
            // Bound argv size for projects containing thousands of recordings.
            for offset in stride(from: 0, to: files.count, by: 64) {
                guard !Task.isCancelled && !skipDiscovery else { return }
                let batch = Array(files[offset..<min(offset + 64, files.count)])
                let work = Task.detached(priority: .utility) {
                    try TranscriptJobStore.zoomInventory(for: batch, helper: helper, cancelled: { Task.isCancelled })
                }
                cancelZoomQuery = { work.cancel() }
                defer { cancelZoomQuery = nil }
                do {
                    let result = try await withTaskCancellationHandler {
                        try await work.value
                    } onCancel: { work.cancel() }
                    guard !Task.isCancelled && !skipDiscovery else { return }
                    discoveryFailures += result.errors.keys.map(\.lastPathComponent).sorted()
                    for (file, participants) in result.participants where !participants.isEmpty {
                        for track in placements[file] ?? [] { zoomSuggestions[track.id] = participants }
                    }
                } catch {
                    if !Task.isCancelled && !skipDiscovery { discoveryFailures += batch.map(\.lastPathComponent) }
                }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Audio sources")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tracks) { track in
                    if track.id != tracks.first?.id { Divider() }
                    if let stream = track.streamIndex {
                        sourceRow(track, stream: stream)
                    } else {
                        Label("\(track.name) · Camera coverage only", systemImage: "video")
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35))
            .modifier(InsetPanel())
        }
    }

    private func sourceRow(_ track: TranscriptJobTrack, stream: Int) -> some View {
        let included = !excluded.contains(track.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { !excluded.contains(track.id) },
                    set: { if $0 { excluded.remove(track.id) } else { excluded.insert(track.id) } }
                )) {
                    Text(track.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityLabel("Include \(track.name), stream \(stream)")
                .accessibilityIdentifier("transcript.setup.track.\(track.id)")
                .help(track.file.path)
                if let lane = controller.project.transcriptLane(for: track) {
                    TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot)
                }
                Spacer(minLength: 4)
                Text("Stream \(stream)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if included {
                VStack(alignment: .leading, spacing: 6) {
                    if let participants = zoomSuggestions[track.id] {
                        Toggle("Use Zoom participant audio", isOn: Binding(
                            get: { usesZoom(track.id) },
                            set: { zoomOverrides[track.id] = $0 }
                        ))
                        .accessibilityLabel("Use Zoom participant audio for \(track.name)")
                        .accessibilityIdentifier("transcript.setup.zoom.\(track.id)")
                        let names = Set(participants.map { speakerEdits[track.id]?[$0.path] ?? $0.speaker }).sorted()
                        Text("Speakers: " + names.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if Set(participants.map(\.speaker)).count == 1 {
                            Text("Only one participant has a separate recording. Use the mix to include other voices.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if usesZoom(track.id), let participants = zoomSuggestions[track.id] {
                        DisclosureGroup("Edit speaker names") {
                            participantSettings(track, participants)
                        }
                    } else {
                        DisclosureGroup("Stream settings") { trackSettings(track) }
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(10)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 9) {
            InspectorRow("Engine", labelWidth: 52) {
                Picker("Engine", selection: $selectedEngine) {
                    ForEach(engines) { engine in
                        Text(engine.title + (engine.available ? "" : " (unavailable)"))
                            .tag(engine.name)
                            .disabled(!engine.available)
                    }
                }
                .accessibilityIdentifier("transcript.setup.engine")
                .onChange(of: selectedEngine) { _, _ in
                    seedSpeakers()
                    speakerCount = ""
                    model = ""
                }
                .help("Transcription engine supplied by Transcriberrr")
            }
            if let engineIssue, let engine {
                Text("\(engineIssue) This job uses \(engine.title).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("transcript.setup.engine.issue")
            }
            DisclosureGroup("Recognition options", isExpanded: $showsOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    InspectorRow("Model") {
                        TextField("Model", text: $model, prompt: Text(engine?.default_model ?? "Default"))
                            .accessibilityLabel("Model")
                    }
                    InspectorRow("Language") {
                        // Transcriberrr sessions recognize English only, so the choice is limited to it.
                        Picker("Language", selection: $language) {
                            Text("Automatic").tag(nil as String?)
                            Text("English").tag("en" as String?)
                        }
                        .accessibilityLabel("Language")
                        .accessibilityIdentifier("transcript.setup.language")
                        .help("Transcriberrr sessions transcribe English. Automatic uses English.")
                    }
                    if engine?.diarization == true && hasMixedAudio {
                        Toggle("Identify speakers in mixed audio", isOn: $diarization)
                        if diarization {
                            InspectorRow("Speakers") {
                                TextField("Expected speakers", text: $speakerCount,
                                          prompt: Text("Automatic · up to \(engine?.diarization_speaker_limit ?? 0)"))
                            }
                        }
                    }
                    Toggle("Download missing models", isOn: $download)
                        .accessibilityIdentifier("transcript.setup.download")
                }
                .padding(.top, 6)
            }
        }
    }

    private func participantSettings(_ track: TranscriptJobTrack, _ participants: [TranscriptZoomParticipant]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(participants, id: \.path) { participant in
                let filename = URL(fileURLWithPath: participant.path).lastPathComponent
                HStack(spacing: 10) {
                    Text(filename)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading).help(participant.path)
                    TextField("Speaker name", text: Binding(
                        get: { speakerEdits[track.id]?[participant.path] ?? participant.speaker },
                        set: { speakerEdits[track.id, default: [:]][participant.path] = $0 }
                    ))
                    .accessibilityLabel("Speaker for \(filename)")
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 4)
    }

    private func trackSettings(_ track: TranscriptJobTrack) -> some View {
        let base = TranscriptJobTrackOptions(channel: track.channel, role: track.role, speaker: track.speaker)
        return VStack(alignment: .leading, spacing: 6) {
            InspectorRow("Role") {
                Picker("Role", selection: Binding(
                    get: { trackOptions[track.id, default: base].role },
                    set: { trackOptions[track.id, default: base].role = $0 }
                )) {
                    Text("Unknown").tag(TranscriptRole.unknown.rawValue)
                    Text("Mixed audio").tag(TranscriptRole.mixedAudio.rawValue)
                    Text("Isolated microphone").tag(TranscriptRole.isolatedMic.rawValue)
                }
            }
            InspectorRow("Speaker") {
                TextField("Speaker hint", text: Binding(
                    get: { trackOptions[track.id, default: base].speaker ?? "" },
                    set: { trackOptions[track.id, default: base].speaker = $0.isEmpty ? nil : $0 }
                ), prompt: Text("Optional"))
            }
            InspectorRow("Channel") {
                TextField("Channel index", text: Binding(
                    get: { channelText[track.id] ?? base.channel.map(String.init) ?? "" },
                    set: { channelText[track.id] = $0 }
                ), prompt: Text("Mix all channels to mono"))
                .help("Enter a channel number starting at 0, or leave blank for a mono mix.")
            }
        }
        .padding(.top, 4)
    }

    /// Identify speakers starts from Settings wherever the chosen engine supports it, and again on each engine change.
    private func seedSpeakers() {
        diarization = Self.seededSpeakers(defaults, engine: engine)
    }

    static func seededSpeakers(_ defaults: TranscriptSheetDefaults, engine: TranscriptEngineCatalog.Engine?) -> Bool {
        defaults.identifiesSpeakers && engine?.diarization == true
    }

    private func submit() {
        do {
            let countText = speakerCount.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = countText.isEmpty ? nil : Int(countText)
            let identifySpeakers = diarization && hasMixedAudio
            if identifySpeakers && !countText.isEmpty {
                guard let count, (1...max(1, engine?.diarization_speaker_limit ?? 0)).contains(count) else {
                    throw CutError(code: "invalid_speaker_count", message: "Enter a speaker count supported by this engine.")
                }
            }
            let selected = tracks.filter { $0.streamIndex != nil && !excluded.contains($0.id) }
            func value(_ text: String) -> String? {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            var settings = trackOptions
            for track in selected where !usesZoom(track.id) {
                guard let input = channelText[track.id] else { continue }
                var option = settings[track.id] ?? .init(channel: track.channel, role: track.role, speaker: track.speaker)
                if let text = value(input) {
                    guard let channel = Int(text), channel >= 0 else {
                        throw CutError(code: "invalid_transcript_track",
                                       message: "Enter a nonnegative channel index for \(track.name), or leave it blank to mix to mono.")
                    }
                    option.channel = channel
                } else {
                    option.channel = nil
                }
                settings[track.id] = option
            }
            var zoom = zoomSuggestions.filter { usesZoom($0.key) && !excluded.contains($0.key) }
            for (id, participants) in zoom {
                zoom[id] = try participants.map { participant in
                    var edited = participant
                    guard let name = value(speakerEdits[id]?[participant.path] ?? participant.speaker) else {
                        throw CutError(code: "invalid_transcript_track", message: "Enter a speaker name for " +
                                       URL(fileURLWithPath: participant.path).lastPathComponent + ".")
                    }
                    edited.speaker = name
                    return edited
                }
            }
            var options = TranscriptJobOptions(engine: selectedEngine, model: value(model), language: language,
                            expectedSpeakers: identifySpeakers ? count : nil, diarization: identifySpeakers,
                            selectedTracks: excluded.isEmpty ? nil : selected.map(\.id), trackOptions: settings.filter { zoom[$0.key] == nil })
            options.zoomParticipants = zoom.isEmpty ? nil : zoom
            try start(options, download)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TranscriptRetryForm: View {
    @Environment(\.dismiss) private var dismiss
    let message: String?
    let retry: (Bool) throws -> Void
    /// Starts from Settings. The retry otherwise uses the options its job captured.
    @State private var download: Bool
    @State private var error: String?

    init(message: String?, downloadsModels: Bool = TranscriptSheetDefaults.factory.downloadsModels,
         retry: @escaping (Bool) throws -> Void) {
        self.message = message
        self.retry = retry
        _download = State(initialValue: downloadsModels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let message { Text(message).foregroundStyle(.secondary) }
            Toggle("Download missing models", isOn: $download)
            if let error { IssueLabel(error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Retry") {
                    do { try retry(download) } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
