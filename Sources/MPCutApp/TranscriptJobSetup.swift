import SwiftUI
import MPCutCore

private struct TranscriptEngines: Decodable {
    struct Engine: Decodable, Identifiable {
        let name: String
        let included: Bool
        let helper_present: Bool?
        let default_model: String
        let minimum_macos: String
        let diarization: Bool
        let diarization_speaker_limit: Int?
        let estimated_realtime_factor: Double?
        var id: String { name }

        var available: Bool {
            let version = minimum_macos.split(separator: ".").compactMap { Int($0) }
            guard let major = version.first, included, helper_present != false else { return false }
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(
                majorVersion: major, minorVersion: version.dropFirst().first ?? 0,
                patchVersion: version.dropFirst(2).first ?? 0
            ))
        }
    }

    struct Automation: Decodable {
        let plan: String?
        let zoom_iso_inventory: [String]?
    }
    let automation: Automation?
    let engines: [Engine]
}

struct TranscriptJobSetup: View {
    let controller: LiveTranscriptController
    let start: (TranscriptJobOptions, Bool) throws -> Void
    @State private var tracks: [TranscriptJobTrack] = []
    @State private var excluded: Set<String> = []
    @State private var trackOptions: [String: TranscriptJobTrackOptions] = [:]
    @State private var channelText: [String: String] = [:]
    @State private var engines: [TranscriptEngines.Engine] = []
    @State private var supportsPlan = false
    @State private var zoomSuggestions: [String: [TranscriptZoomParticipant]] = [:]
    @State private var useZoom: Set<String> = []
    @State private var checkingZoom = true
    @State private var skipDiscovery = false
    @State private var cancelZoomQuery: (() -> Void)?
    @State private var discoveryFailures: [String] = []
    @State private var speakerEdits: [String: [String: String]] = [:]
    @State private var selectedEngine = ""
    @State private var language = ""
    @State private var model = ""
    @State private var speakerCount = ""
    @State private var diarization = false
    @State private var download = false
    @State private var providerStatus: String? = "Checking Transcriberrr…"
    @State private var readingTracks = true
    @State private var loadAttempt = 0
    @State private var providerError: String?
    @State private var inventoryError: String?
    private var loading: Bool { providerStatus != nil || readingTracks || (checkingZoom && !skipDiscovery) }
    private var hasMixedAudio: Bool {
        tracks.contains { track in
            track.streamIndex != nil && !excluded.contains(track.id) && !useZoom.contains(track.id)
                && (trackOptions[track.id]?.role ?? track.role) != TranscriptRole.isolatedMic.rawValue
        }
    }
    @State private var error: String?

    private var engine: TranscriptEngines.Engine? { engines.first { $0.name == selectedEngine } }
    private var duration: Double {
        tracks.lazy.filter { $0.streamIndex != nil && !excluded.contains($0.id) }
            .reduce(0) { $0 + $1.duration.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let providerStatus { ProgressView(providerStatus).controlSize(.small) }
            if readingTracks { ProgressView("Reading audio streams…").controlSize(.small) }
            if !engines.isEmpty { settings }
            if !tracks.isEmpty { inventory }
            if let issue = [providerError, inventoryError, error].compactMap({ $0 }).first {
                IssueLabel(issue)
                    .accessibilityIdentifier("transcript.setup.error")
            }
            if !discoveryFailures.isEmpty {
                Text("Couldn’t check for participant audio in " + discoveryFailures.joined(separator: ", ") + ".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if providerError != nil || inventoryError != nil || !discoveryFailures.isEmpty {
                    Button("Try Again") { loadAttempt += 1 }.disabled(loading)
                }
                Spacer()
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
            useZoom.formIntersection(zoomSuggestions.keys)
        }
    }

    @MainActor private func loadCapabilities() async {
        defer { providerStatus = nil }
        do {
            let data = try await controller.capabilities { providerStatus = $0 }
            let capabilities = try JSONDecoder().decode(TranscriptEngines.self, from: data)
            engines = capabilities.engines
            if let inventory = capabilities.automation?.zoom_iso_inventory {
                supportsPlan = inventory == ["--plan", "--inventory-only", "--offline"]
            } else {
                supportsPlan = capabilities.automation?.plan == "--plan"
            }
            if engines.contains(where: { $0.available && $0.name == selectedEngine }) { return }
            selectedEngine = engines.first(where: { $0.available && $0.name == "qwen3" })?.name
                ?? engines.first(where: \.available)?.name ?? ""
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
        } catch {
            if !Task.isCancelled { inventoryError = error.localizedDescription }
        }
    }

    @MainActor private func discoverZoom() async {
        guard let helper = try? TranscriptJobStore.helperURL() else { return }
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

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Engine", selection: $selectedEngine) {
                ForEach(engines) { engine in
                    Text(engine.name + (engine.available ? "" : " (unavailable)"))
                        .tag(engine.name)
                        .disabled(!engine.available)
                }
            }
            .accessibilityIdentifier("transcript.setup.engine")
            .onChange(of: selectedEngine) { _, _ in
                diarization = false
                speakerCount = ""
                model = ""
            }
            TextField("Model (default: \(engine?.default_model ?? "automatic"))", text: $model)
            TextField("Language (default: automatic)", text: $language)
            Toggle("Identify speakers in mixed audio", isOn: $diarization)
                .disabled(engine?.diarization != true || !hasMixedAudio)
            if diarization && hasMixedAudio {
                TextField("Expected speakers (up to \(engine?.diarization_speaker_limit ?? 0))", text: $speakerCount)
            }
            Toggle("Download required models if missing", isOn: $download)
                .accessibilityIdentifier("transcript.setup.download")
        }
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading("Audio Streams")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(tracks) { track in
                        if let stream = track.streamIndex {
                            DisclosureGroup {
                                if useZoom.contains(track.id), let participants = zoomSuggestions[track.id] {
                                    participantSettings(track, participants)
                                } else {
                                    trackSettings(track)
                                        .padding(.leading, 6).padding(.top, 4)
                                }
                            } label: {
                                Toggle(isOn: Binding(
                                    get: { !excluded.contains(track.id) },
                                    set: { if $0 { excluded.remove(track.id) } else { excluded.insert(track.id) } }
                                )) {
                                    HStack {
                                        Text("\(track.name) · Stream \(stream)")
                                        if let lane = controller.project.transcriptLane(for: track) {
                                            TranscriptLaneChip(label: lane.label, colorSlot: lane.colorSlot)
                                        }
                                    }
                                }
                                .accessibilityIdentifier("transcript.setup.track.\(track.id)")
                            }
                            if let participants = zoomSuggestions[track.id] {
                                VStack(alignment: .leading, spacing: 2) {
                                    Toggle("Use Zoom participant audio", isOn: Binding(
                                        get: { useZoom.contains(track.id) && !excluded.contains(track.id) },
                                        set: { if $0 { useZoom.insert(track.id) } else { useZoom.remove(track.id) } }
                                    ))
                                    .accessibilityLabel("Use Zoom participant audio for \(track.name)")
                                    .accessibilityIdentifier("transcript.setup.zoom.\(track.id)")
                                    Text("Speakers: " + Set(participants.map {
                                        speakerEdits[track.id]?[$0.path] ?? $0.speaker
                                    }).sorted().joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if Set(participants.map(\.speaker)).count == 1 {
                                        Text("Only one participant has a separate recording. Choose the mix to include other voices.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(excluded.contains(track.id))
                                .padding(.leading, 19)
                            }
                        } else {
                            Label("\(track.name) · Camera coverage only", systemImage: "video")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 65, idealHeight: 135, maxHeight: 205)
            if checkingZoom && supportsPlan && !skipDiscovery && !readingTracks {
                HStack {
                    ProgressView("Checking for Zoom participant audio…").controlSize(.small)
                    Button("Skip remaining search") {
                        skipDiscovery = true
                        cancelZoomQuery?()
                    }.controlSize(.small)
                }
            }
            Text("Selected recording duration: \(timelineTime(duration))")
                .font(.caption).foregroundStyle(.secondary)
            if !useZoom.subtracting(excluded).isEmpty {
                Text("Each selected participant file is transcribed separately.").font(.caption).foregroundStyle(.secondary)
            } else if let factor = engine?.estimated_realtime_factor, factor.isFinite, factor > 0 {
                Text("Estimated recognition time: \(timelineTime(duration * factor))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Transcriberrr has no runtime estimate for this engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func participantSettings(_ track: TranscriptJobTrack, _ participants: [TranscriptZoomParticipant]) -> some View {
        ForEach(participants, id: \.path) { participant in
            let filename = URL(fileURLWithPath: participant.path).lastPathComponent
            VStack(alignment: .leading, spacing: 3) {
                Text(filename).font(.caption).lineLimit(1).truncationMode(.middle).help(participant.path)
                TextField("Speaker name", text: Binding(
                    get: { speakerEdits[track.id]?[participant.path] ?? participant.speaker },
                    set: { speakerEdits[track.id, default: [:]][participant.path] = $0 }
                ))
                .accessibilityLabel("Speaker for \(filename)")
            }
            .padding(.leading, 6)
        }
    }

    private func trackSettings(_ track: TranscriptJobTrack) -> some View {
        let base = TranscriptJobTrackOptions(channel: track.channel, role: track.role, speaker: track.speaker)
        return VStack(alignment: .leading, spacing: 5) {
            Picker("Role", selection: Binding(
                get: { trackOptions[track.id, default: base].role },
                set: { trackOptions[track.id, default: base].role = $0 }
            )) {
                Text("Unknown (default)").tag(TranscriptRole.unknown.rawValue)
                Text("Mixed audio").tag(TranscriptRole.mixedAudio.rawValue)
                Text("Isolated microphone").tag(TranscriptRole.isolatedMic.rawValue)
            }
            TextField("Speaker hint", text: Binding(
                get: { trackOptions[track.id, default: base].speaker ?? "" },
                set: { trackOptions[track.id, default: base].speaker = $0.isEmpty ? nil : $0 }
            ))
            TextField("Channel index (zero-based, blank mixes channels to mono)", text: Binding(
                get: { channelText[track.id] ?? base.channel.map(String.init) ?? "" },
                set: { channelText[track.id] = $0 }
            ))
        }
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
            for track in selected where !useZoom.contains(track.id) {
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
            var zoom = zoomSuggestions.filter { useZoom.contains($0.key) && !excluded.contains($0.key) }
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
            var options = TranscriptJobOptions(engine: selectedEngine, model: value(model), language: value(language),
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
    let message: String?
    let retry: (Bool) throws -> Void
    @State private var download = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let message { Text(message).foregroundStyle(.secondary) }
            Toggle("Download required models if missing", isOn: $download)
            if let error { IssueLabel(error) }
            HStack {
                Spacer()
                Button("Retry") {
                    do { try retry(download) } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
