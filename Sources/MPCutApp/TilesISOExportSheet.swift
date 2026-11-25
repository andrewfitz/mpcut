import AppKit
import MPCutCore
import SwiftUI

@MainActor
struct TilesISOExportSheet: View {
    let session: ProjectSession
    var recordingID: String? = nil
    var recordingName: String? = nil
    /// The recording's file, for the Source folder starting rule.
    var recordingURL: URL? = nil
    var openProject: (URL) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var token: EditCancellation?
    @State private var currentPlan: TilesISOPlan?
    @State private var selected: Set<String>?
    @State private var settings = Settings()
    @State private var failure: String?
    @State private var progress: Double?
    @State private var destination: URL?
    @State private var manifest: TilesISOManifest?
    @State private var verification: TilesISOVerification?
    @State private var plannedRevision: ParticipantSpeakerIndexKey?
    @State private var availableFeeds: [TilesISOPlan.Feed] = []

    private struct Settings: Equatable {
        var size = "Source"
        var width = "1920"
        var height = "1080"
        var rate = "Source"
        var customRate = "30"
        var useMarkedRange = false
        var gapColor: UInt32 = 0
        var framing: ParticipantSlotFraming = .fit
        var keepCameraOff = true
        var blankUncertain = false
        var includeMix = true
        var includeMic = true
    }

    private var markedRange: MulticamRange? {
        recordingID.flatMap { session.participantMarkedSourceRange(sourceID: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(recordingID == nil ? "Verify ISO Delivery" : "Export ISOs")
                .font(.headline)
                .accessibilityIdentifier(recordingID == nil ? "tiles.iso.verify.title" : "tiles.iso.title")
            if let recordingName { Text(recordingName).foregroundStyle(.secondary) }
            if let manifest, let destination {
                delivery(manifest, destination: destination)
            } else if recordingID != nil {
                options
                planReview
            }
            if let verification {
                verificationResult(verification)
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if token != nil {
                if let progress { ProgressView(value: progress, total: 1) }
                else { ProgressView().controlSize(.small) }
            }
            HStack {
                Spacer()
                if let token {
                    Button("Cancel", role: .cancel) { token.cancel() }.disabled(token.isCancelled)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if manifest == nil {
                        Button(recordingID == nil ? "Choose Delivery Folder…" : "Verify Existing Delivery…",
                               action: chooseVerificationFolder)
                            .accessibilityIdentifier("tiles.iso.verify.choose-folder")
                        if recordingID != nil {
                            Menu("Export…") {
                                Button("Create Delivery Folder…") { chooseDestination(resume: false) }
                                Button("Resume Existing Delivery…") { chooseDestination(resume: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(currentPlan?.requiresReview != false || plannedRevision != ParticipantSpeakerIndexKey(session: session))
                            .accessibilityIdentifier("tiles.iso.export")
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { refreshPlan() }
        .onChange(of: settings) { _, _ in refreshPlan() }
        .onChange(of: selected) { _, _ in refreshPlan() }
        .interactiveDismissDisabled(token != nil)
        .onDisappear { token?.cancel() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $settings.useMarkedRange) {
                Text("Full Recording").tag(false)
                if markedRange != nil { Text("Marked Range").tag(true) }
            }
            .accessibilityIdentifier("tiles.iso.range")
            .help("Set Mark In and Mark Out in one occurrence of this recording to export a marked range.")
            HStack {
                Picker("Size", selection: $settings.size) {
                    ForEach(["Source", "1920 × 1080", "1280 × 720", "Custom"], id: \.self) { Text($0) }
                }
                Picker("Frame Rate", selection: $settings.rate) {
                    ForEach(["Source", "24", "25", "30", "60", "Custom"], id: \.self) { Text($0) }
                }
            }
            if settings.size == "Custom" {
                HStack {
                    TextField("Width", text: $settings.width)
                    TextField("Height", text: $settings.height)
                }
            }
            if settings.rate == "Custom" { TextField("Frame rate", text: $settings.customRate) }
            Picker("Framing", selection: $settings.framing) {
                Text("Fit").tag(ParticipantSlotFraming.fit)
                Text("Fill").tag(ParticipantSlotFraming.fill)
            }
            ColorPicker("Gap Color", selection: gapColor, supportsOpacity: false)
                .accessibilityIdentifier("tiles.iso.gap-color")
            Toggle("Keep camera-off picture", isOn: $settings.keepCameraOff)
            Toggle("Include shared mix", isOn: $settings.includeMix)
            if session.isMulticam { Toggle("Include ISO microphones", isOn: $settings.includeMic) }
            Toggle("Cover unchecked footage", isOn: $settings.blankUncertain)
        }
        .disabled(progress != nil)
    }

    private var gapColor: Binding<Color> {
        Binding {
            let value = settings.gapColor
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                         blue: Double(value & 255) / 255)
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
            settings.gapColor = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
        }
    }

    private func verificationResult(_ result: TilesISOVerification) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(result.valid ? "Delivery verified" : "Delivery verification failed",
                  systemImage: result.valid ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(result.valid ? Color.secondary : Color.red)
                .accessibilityIdentifier("tiles.iso.verify.result")
            if !result.issues.isEmpty {
                ScrollView {
                    Text(result.issues.map(\.message).joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
            }
        }
    }

    private var planReview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !availableFeeds.isEmpty {
                HStack {
                    Text("Feeds").font(.headline)
                    Spacer()
                    Button("All") { selected = nil }
                    Button("None") { selected = [] }
                }
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(availableFeeds) { feed in
                            Toggle(isOn: Binding(get: { selected?.contains(feed.id) ?? true }, set: { included in
                                var next = selected ?? Set(availableFeeds.map(\.id))
                                if included { next.insert(feed.id) } else { next.remove(feed.id) }
                                selected = next
                            })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(feed.name)
                                    Text(feed.filename).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(105, CGFloat(availableFeeds.count) * 37))
            }
            if let plan = currentPlan {
                Text("\(plan.feeds.count) movies · \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file)) estimated")
                    .font(.callout)
                if !plan.withheld.isEmpty {
                    let withheld = plan.withheld.filter { $0.reason == "treatment" }.count
                    let excluded = plan.withheld.count - withheld
                    if withheld > 0 { Text("\(withheld) feeds withheld by treatment").font(.caption) }
                    if excluded > 0 { Text("\(excluded) feeds excluded from this delivery").font(.caption) }
                }
                if !plan.issues.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                                Label(issue.message, systemImage: issue.blocking ? "exclamationmark.triangle" : "info.circle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(80, CGFloat(plan.issues.count) * 22))
                    .font(.caption)
                }
            }
        }
        .disabled(progress != nil)
    }

    private func delivery(_ manifest: TilesISOManifest, destination: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Exported \(manifest.files.compactMap(\.feed).count) ISO movies", systemImage: "checkmark.circle")
            Text(destination.path).textSelection(.enabled).lineLimit(2)
            // What a movie's render gave up, such as its bit depth or constant quality.
            ForEach(Array(manifest.issues.filter { $0.code == "iso_render_warning" }.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Open Multicam Project") { openProject(destination.appending(path: "multicam.cut")) }
                Button("Show Manifest") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination.appending(path: "manifest.json")])
                }
                Button("Verify Delivery") { verify(destination) }
            }.disabled(token != nil)

        }
    }

    private func refreshPlan() {
        guard let recordingID, progress == nil else { return }
        token?.cancel()
        failure = nil
        currentPlan = nil
        plannedRevision = nil
        guard selected?.isEmpty != true else { token = nil; return }
        let revision = ParticipantSpeakerIndexKey(session: session)
        let settings = self.settings
        let project = session.transcript.project
        let selected = self.selected?.sorted()
        do {
            let range = settings.useMarkedRange ? markedRange : nil
            if settings.useMarkedRange, range == nil {
                throw CutError(code: "invalid_iso_range", message: "Set both marks in the same occurrence of this recording.")
            }
            let document = try session.transcript.assetContext()
            let size: (Int?, Int?) = switch settings.size {
            case "1920 × 1080": (1920, 1080)
            case "1280 × 720": (1280, 720)
            case "Custom": (Int(settings.width), Int(settings.height))
            default: (nil, nil)
            }
            if settings.size == "Custom", size.0 == nil || size.1 == nil {
                throw CutError(code: "invalid_iso_size", message: "Enter a width and height in pixels.")
            }
            let rate = settings.rate == "Source" ? nil
                : try RationalTime(parsing: settings.rate == "Custom" ? settings.customRate : settings.rate)
            let audio = ParticipantMulticamAudioRouting(meetingMix: settings.includeMix, includeISOs: session.isMulticam && settings.includeMic)
            run(priority: .utility) { token in
                try TilesISODelivery.plan(project: project, document: document, sourceID: recordingID,
                                          feedIDs: selected, range: range, width: size.0, height: size.1, frameRate: rate,
                                          gapColor: settings.gapColor,
                                          framing: settings.framing, keepCameraOff: settings.keepCameraOff,
                                          blankUncertain: settings.blankUncertain, audio: audio,
                                          cancelled: { token.isCancelled })
            } receive: { plan in
                currentPlan = plan
                plannedRevision = revision
                if selected == nil { availableFeeds = plan.feeds }
            }
        } catch {
            token = nil
            failure = error.localizedDescription
        }
    }

    private func chooseDestination(resume: Bool) {
        guard let recordingName else { return }
        if resume {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.title = "Choose an Existing ISO Delivery"
            if let directory = startDirectory { panel.directoryURL = directory }
            ProjectPanels.present(panel, in: session.window, fromSheet: true) { accepted in
                if accepted, let url = panel.url { export(to: url) }
            }
        } else {
            let panel = NSSavePanel()
            panel.title = "Create ISO Delivery Folder"
            panel.nameFieldStringValue = URL(fileURLWithPath: recordingName).deletingPathExtension().lastPathComponent + " ISOs"
            if let directory = startDirectory { panel.directoryURL = directory }
            ProjectPanels.present(panel, in: session.window, fromSheet: true) { accepted in
                guard accepted, let url = panel.url else { return }
                if session.editor.preferences.exportStartFolder != .automatic {
                    session.transcriptPaneMemory.exportFolder = url.deletingLastPathComponent()
                }
                export(to: url)
            }
        }
    }

    /// Settings → Export → Start export panels in. Automatic leaves the panel where AppKit opens it, as it always did.
    private var startDirectory: URL? {
        let preferences = session.editor.preferences
        guard preferences.exportStartFolder != .automatic else { return nil }
        let projectURL = session.isMulticam ? session.multicam.projectURL : session.editor.projectURL
        return ExportStartFolder.resolve(
            mode: preferences.exportStartFolder,
            chosenFolder: preferences.exportStartFolderPath.isEmpty ? nil : URL(fileURLWithPath: preferences.exportStartFolderPath),
            projectFile: projectURL.flatMap { ProjectDraft.isManaged($0) ? nil : $0 }, sourceRecording: recordingURL,
            sessionFolder: session.transcriptPaneMemory.exportFolder, automatic: nil
        ).directory
    }

    private func export(to directory: URL) {
        guard let plan = currentPlan, !plan.requiresReview, plannedRevision == ParticipantSpeakerIndexKey(session: session) else {
            refreshPlan()
            return
        }
        do {
            let document = try session.transcript.assetContext()
            if session.isMulticam { try session.multicam.validateHistoryDestination(directory, includesContents: true) }
            else { try session.editor.validateHistoryDestination(directory, includesContents: true) }
            let project = session.transcript.project
            let preferences = session.editor.preferences
            failure = nil
            progress = 0
            run(priority: .userInitiated) { token in
                // Keep the Mac awake for the whole delivery; a failure or cancel ends it as a finish does.
                let awake = SleepPrevention(reason: "Exporting ISO movies")
                defer { awake.end() }
                return try TilesISODelivery.render(plan, project: project, document: document, to: directory,
                                                   cancelled: { token.isCancelled }) { amount in
                    Task { @MainActor in
                        if self.token === token { progress = amount }
                    }
                    return !token.isCancelled
                }
            } receive: { outcome in
                destination = directory
                manifest = outcome
                ExportCompletion.shared.exportFinished(directory, title: "ISO export finished",
                                                       reveal: preferences.revealsFinishedExport,
                                                       notify: preferences.notifiesFinishedExport,
                                                       playSound: preferences.playsFinishedExportSound)
            }
        } catch { failure = error.localizedDescription }
    }

    private func chooseVerificationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.title = "Verify ISO Delivery"
        ProjectPanels.present(panel, in: session.window, fromSheet: true) { accepted in
            if accepted, let url = panel.url { verify(url) }
        }
    }

    private func verify(_ directory: URL) {
        failure = nil
        verification = nil
        run(priority: .utility) { token in
            try TilesISODelivery.verify(directory, cancelled: { token.isCancelled })
        } receive: { verification = $0 }
    }

    private func run<Value: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable (EditCancellation) throws -> Value,
                                      receive: @escaping @MainActor (Value) -> Void) {
        let next = EditCancellation()
        token = next
        Task {
            let result = await Task.detached(priority: priority) { Result { try work(next) } }.value
            guard token === next else { return }
            token = nil
            progress = nil
            do {
                let value = try result.get()
                if !next.isCancelled { receive(value) }
            } catch {
                if !next.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
