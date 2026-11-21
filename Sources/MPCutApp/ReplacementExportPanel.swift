import AppKit
import MPCutCore
import SwiftUI

@MainActor
final class ReplacementExportPanel: NSObject, ObservableObject, NSOpenSavePanelDelegate {
    let source: MediaInfo
    let replacement: MediaInfo
    let sourceName: String
    let targets: [StreamInfo]
    let replacements: [StreamInfo]
    @Published var targetIndex: Int { didSet { check() } }
    @Published var replacementIndex: Int { didSet { check() } }
    @Published var container: String? { didSet { check() } }
    @Published private(set) var summary = ""
    private(set) var plan: AudioReplacementPlan?
    private var task: Task<Void, Never>?
    private var preflight: Task<AudioReplacementPlan, Error>?
    private weak var panel: NSSavePanel?
    private var fileExtension: String
    private let useSidecar: Bool

    init(source: MediaInfo, replacement: MediaInfo, sourceName: String? = nil, useSidecar: Bool = true) throws {
        self.source = source
        self.replacement = replacement
        self.sourceName = sourceName ?? source.url.lastPathComponent
        self.useSidecar = useSidecar
        targets = source.streams.filter { $0.kind == "audio" }
        replacements = replacement.streams.filter { $0.kind == "audio" }
        guard let target = targets.first, let processed = replacements.first else {
            throw CutError(code: "no_audio", message: "Choose a source and a replacement that each contain audio.")
        }
        targetIndex = target.index
        replacementIndex = processed.index
        fileExtension = source.url.pathExtension.isEmpty ? "mov" : source.url.pathExtension.lowercased()
        super.init()
    }

    func attach(to panel: NSSavePanel) {
        self.panel = panel
        panel.delegate = self
        panel.nameFieldStringValue = "\(source.url.deletingPathExtension().lastPathComponent) Audio.\(fileExtension)"
        let accessory = NSHostingView(rootView: ReplacementOptionsView(options: self))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        check()
    }

    func stopChecking() {
        preflight?.cancel()
        task?.cancel()
    }

    private func check() {
        stopChecking()
        plan = nil
        summary = "Checking track timing and container…"
        let source = source, replacement = replacement
        let requestedContainer = container, target = targetIndex, processed = replacementIndex
        let useSidecar = useSidecar
        let resolve = Task.detached(priority: .userInitiated) {
            try AudioReplacementEngine(cancelled: { Task.isCancelled }, useSidecar: useSidecar).resolve(
                source: source, replacement: replacement, container: requestedContainer,
                targetStream: target, replacementStream: processed)
        }
        preflight = resolve
        task = Task { [weak self] in
            let result = await resolve.result
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let plan):
                self.plan = plan
                if let panel {
                    let name = panel.nameFieldStringValue as NSString
                    if name.pathExtension.lowercased() == fileExtension {
                        panel.nameFieldStringValue = "\(name.deletingPathExtension).\(plan.container)"
                    }
                }
                fileExtension = plan.container
                summary = "Copy picture and sound to \(plan.container.uppercased()) · \(EditorExportPlan.seconds(plan.duration.seconds))"
            case .failure(let error):
                summary = error.localizedDescription
            }
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard let plan else { throw CutError(code: "export_unavailable", message: summary) }
        try validateExportDestination(url, container: plan.container)
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, let plan, (filename as NSString).pathExtension.isEmpty else { return filename }
        return filename + "." + plan.container
    }
}

private struct ReplacementOptionsView: View {
    @ObservedObject var options: ReplacementExportPanel

    var body: some View {
        Form {
            LabeledContent("Whole source", value: options.sourceName)
            Picker("Track to replace", selection: $options.targetIndex) {
                ForEach(options.targets, id: \.index) { Text($0.exportLabel).tag($0.index) }
            }
            LabeledContent("Replacement file", value: options.replacement.url.lastPathComponent)
            Picker("Use audio track", selection: $options.replacementIndex) {
                ForEach(options.replacements, id: \.index) { Text($0.exportLabel).tag($0.index) }
            }
            Picker("Container", selection: $options.container) {
                Text("Source compatible").tag(nil as String?)
                ForEach(["mov", "mp4", "mkv", "webm"], id: \.self) { Text(containerDisplayName($0)).tag(Optional($0)) }
            }
            Text(options.summary).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: 470)
    }
}
