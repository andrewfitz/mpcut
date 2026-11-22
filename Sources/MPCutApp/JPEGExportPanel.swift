import AppKit
import MPCutCore
import SwiftUI

@MainActor
final class StillFrameSaveOptions: NSObject, NSOpenSavePanelDelegate {
    private var validatedOutput: (url: URL, identity: SourceIdentity)?

    func panel(source: URL, directory: URL?) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Export Current Frame"
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " Frame.jpg"
        panel.directoryURL = directory
        panel.delegate = self
        return panel
    }

    func panel(_ sender: Any, validate url: URL) throws {
        // The save panel handles the Replace prompt. Keep the approved file identity
        // so a newly created or changed destination cannot silently be overwritten.
        validatedOutput = (try? SourceIdentity(url)).map { (url.standardizedFileURL, $0) }
    }

    func confirmedDestination(at output: URL) -> SourceIdentity? {
        guard validatedOutput?.url == output.standardizedFileURL else { return nil }
        return validatedOutput?.identity
    }
}

struct EditorJPEGSource {
    let id: UUID
    let media: MediaInfo
    let frame: RationalTime?
    let scenes: SceneReport?
    let audioStream: Int?
    let pauses: [AudioSpan]?
    let manualThreshold: Double?
    let effectiveThreshold: Double?
    let minimumPause: Double

    func selection(for mode: JPEGExportMode, analyzeScenes: () throws -> SceneReport,
                   analyzeSilence: (Int) throws -> SilenceAnalysisResult) throws -> JPEGSelection {
        switch mode {
        case .playhead:
            guard let frame else { throw CutError(code: "no_frame", message: "There is no picture at the playhead.") }
            return .times([frame])
        case .scenes:
            return .sceneReport(try scenes ?? analyzeScenes())
        case .nonSilent:
            guard let audioStream else {
                throw CutError(code: "no_audio", message: "Choose a source with an audio track.")
            }
            if let pauses, let effectiveThreshold {
                return .audibleRanges(pauses: pauses, stream: audioStream, thresholdDB: effectiveThreshold,
                                      minimumPause: minimumPause)
            }
            let result = try analyzeSilence(audioStream)
            return .audibleRanges(pauses: result.pauses, stream: audioStream, thresholdDB: result.thresholdDB,
                                  minimumPause: minimumPause)
        }
    }
}

enum JPEGExportMode { case playhead, scenes, nonSilent }

@MainActor
final class JPEGExportOptions: NSObject, ObservableObject, NSOpenSavePanelDelegate {
    @Published var mode = JPEGExportMode.playhead
    @Published var preset: JPEGPreset
    @Published var sample = JPEGSample.midpoint
    @Published var limitText = ""
    @Published var allSwitches = false
    @Published var programPicture = false

    init(preset: JPEGPreset = .review) {
        self.preset = preset
        super.init()
    }

    func panel(source: URL, directory: URL? = nil, hasAudio: Bool, hasPictureAtPlayhead: Bool = true, multicam: Bool = false,
               hasAnalysisSource: Bool = true, hasProgramStill: Bool = false) -> NSSavePanel {
        if !hasPictureAtPlayhead { mode = .scenes }
        programPicture = hasProgramStill
        let panel = NSSavePanel()
        panel.title = "Export JPEG Frames"
        panel.prompt = "Export"
        panel.nameFieldLabel = "New folder:"
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " Frames"
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.delegate = self
        let accessory = NSHostingView(rootView: JPEGExportAccessory(source: source, hasAudio: hasAudio,
                                                                    hasPictureAtPlayhead: hasPictureAtPlayhead, multicam: multicam,
                                                                    hasAnalysisSource: hasAnalysisSource, hasProgramStill: hasProgramStill, options: self))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        return panel
    }

    func frameLimit() throws -> Int? {
        let text = limitText.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .playhead || text.isEmpty { return nil }
        guard let limit = Int(text), limit > 0 else {
            throw CutError(code: "invalid_limit", message: "Enter a positive whole number or leave the image limit empty.")
        }
        return limit
    }

    func panel(_ sender: Any, validate url: URL) throws {
        _ = try frameLimit()
        if FileManager.default.fileExists(atPath: url.path) {
            throw CutError(code: "output_exists", message: "Choose a new folder name for the JPEGs and their manifest.")
        }
    }
}

private struct JPEGExportAccessory: View {
    let source: URL
    let hasAudio: Bool
    let hasPictureAtPlayhead: Bool
    let multicam: Bool
    let hasAnalysisSource: Bool
    let hasProgramStill: Bool
    @ObservedObject var options: JPEGExportOptions

    var body: some View {
        Form {
            LabeledContent(hasProgramStill ? "Program image" : multicam ? "On-air camera" : "Source") {
                Text(source.lastPathComponent).lineLimit(1).truncationMode(.middle).help(source.path)
            }
            Picker("Frames", selection: $options.mode) {
                Text(multicam && !hasProgramStill ? "Compare all camera angles" : "Current picture at playhead").tag(JPEGExportMode.playhead)
                    .disabled(!hasPictureAtPlayhead)
                Text("Each scene in the source file").tag(JPEGExportMode.scenes)
                    .disabled(!hasAnalysisSource)
                Text("Each non-silent section in the source file").tag(JPEGExportMode.nonSilent)
                    .disabled(!hasAudio)
            }
            .help("Choose frames to export")
            if multicam && options.mode == .playhead && hasProgramStill && hasAnalysisSource {
                Picker("Picture", selection: $options.programPicture) {
                    Text("Program still").tag(true)
                    Text("Compare all camera angles").tag(false)
                }
                .help("Choose picture source")
            }
            if multicam && options.mode == .playhead && !options.programPicture {
                Picker("Group times", selection: $options.allSwitches) {
                    Text("Playhead").tag(false)
                    Text("Every camera switch").tag(true)
                }
                .help("Choose switches to export")
            }
            Picker("Image size", selection: $options.preset) {
                Text("Small review JPEG (up to 640 px)").tag(JPEGPreset.review)
                Text("Full resolution, high quality").tag(JPEGPreset.full)
            }
            .help("Set JPEG image size")
            Picker("Picture in range", selection: $options.sample) {
                Text("Midpoint").tag(JPEGSample.midpoint)
                Text("First frame").tag(JPEGSample.first)
            }
            .disabled(options.mode == .playhead)
            .help("Choose frame within range")
            TextField("Image limit", text: $options.limitText, prompt: Text("All"))
                .disabled(options.mode == .playhead)
                .help("Limit exported images")
            Text("The folder includes the JPEGs and a JSON manifest with frame timing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 425)
    }
}
