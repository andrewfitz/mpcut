import AppKit
import MPCutCore
import SwiftUI

extension MulticamEditorModel {
    var canReplaceSourceAudio: Bool { project != nil && !isBusy }

    func chooseReplacementAudio() {
        guard canReplaceSourceAudio else { return }
        preview.pause()
        isReplacementAudioPresented = true
    }

    func chooseTrackReplacementAudio(_ selection: MulticamAudioSelection) {
        guard canReplaceSourceAudio, project?.pictureSources.contains(where: { $0.id == selection.source }) == true,
              media[selection.source]?.audio.contains(where: { $0.stream.index == selection.stream }) == true else { return }
        preview.pause()
        trackReplacementTarget = selection
    }

    @discardableResult
    func replaceTrackAudio(_ original: MulticamAudioSelection, with selection: MulticamAudioSelection,
                           external: SourceDraft, relativeOffset: RationalTime,
                           uncovered: MulticamAudioReplacement.Uncovered) -> Bool {
        guard canReplaceSourceAudio, selection.source == external.id,
              let scratch = media[original.source],
              scratch.audio.contains(where: { $0.stream.index == original.stream }),
              external.media.audio.contains(where: { $0.stream.index == selection.stream }),
              soundtrackIsCurrent(scratch), soundtrackIsCurrent(external.media) else { return false }
        if let existing = project?.sources.first(where: { $0.id == external.id }) {
            guard project?.audioSources.contains(where: { $0.id == external.id }) == true,
                  URL(fileURLWithPath: existing.file).standardizedFileURL == external.media.url.standardizedFileURL,
                  media[existing.id].map({ $0.identity == external.media.identity }) ?? true else {
                fail("The incoming recording changed. Choose it again.")
                return false
            }
        }
        cacheIndexedSource(external.media, ordinary: external.ordinaryMedia)
        let replaced = edit("Replace Track Audio") { project in
            if !project.audioSources.contains(where: { $0.id == external.id }) {
                var source = external.source
                source.offset = .zero
                source.audioStream = selection.stream
                project.audioSources.append(source)
            }
            let index = project.audioReplacements.firstIndex { $0.original == original }
            let id = index.map { project.audioReplacements[$0].id } ?? UUID().uuidString
            let binding = MulticamAudioReplacement(id: id, original: original, replacement: selection,
                                                   relativeOffset: relativeOffset, uncovered: uncovered)
            if let index { project.audioReplacements[index] = binding }
            else { project.audioReplacements.append(binding) }
        }
        if replaced { status = "Updated the recording’s audio track." }
        return replaced
    }

    @discardableResult
    func replaceProgramAudio(with selection: MulticamAudioSelection) -> Bool {
        guard canReplaceSourceAudio,
              let indexed = media[selection.source], indexed.hasFullEditIndex,
              indexed.audio.contains(where: { $0.stream.index == selection.stream }) else { return false }
        guard soundtrackIsCurrent(indexed) else { return false }
        let replaced = edit("Replace Program Audio") { $0.replaceProgramAudio(with: selection) }
        if replaced { status = "Updated the multicam soundtrack." }
        return replaced
    }

    func programAudioCoverageIssue(with selection: MulticamAudioSelection) -> String? {
        guard var candidate = project else { return nil }
        do {
            candidate.replaceProgramAudio(with: selection)
            let lanes = try candidate.resolveAudioLanes(plan: candidate.plan(), indexedSources: media)
            guard let gaps = lanes.first?.gaps, !gaps.isEmpty else { return nil }
            let ranges = gaps.map { "\($0.from)–\($0.to) s" }.joined(separator: ", ")
            return "Program audio needs continuous coverage across the cut. Uncovered output · \(ranges)"
        } catch {
            return (error as? CutError)?.message ?? error.localizedDescription
        }
    }

    private func soundtrackIsCurrent(_ indexed: MediaInfo) -> Bool {
        guard (try? SourceIdentity(indexed.url)) == indexed.identity else {
            fail("The soundtrack changed or moved after indexing. Choose the recording again.")
            return false
        }
        return true
    }

    func chooseExternalSoundtrack(onFailure: @escaping (String) -> Void,
                                  onIndexed: @escaping (SourceDraft) -> Void) {
        guard canReplaceSourceAudio else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose External Soundtrack"
        panel.prompt = "Choose"
        let generation = mcpGeneration
        ProjectPanels.present(panel, in: window, fromSheet: true) { [weak self] accepted in
            guard let self, self.mcpGeneration == generation, accepted, let url = panel.url else { return }
            self.indexExternalSoundtrack(url, onFailure: onFailure, onIndexed: onIndexed)
        }
    }

    func addExternalSoundtrack(_ url: URL) {
        indexExternalSoundtrack(url) { draft in
            if let stream = draft.source.audioStream {
                self.replaceProgramAudio(with: .init(source: draft.id, stream: stream), external: draft)
            }
        }
    }

    func indexExternalSoundtrack(_ url: URL, onFailure: ((String) -> Void)? = nil,
                                 onIndexed: @escaping (SourceDraft) -> Void) {
        guard canReplaceSourceAudio, url.isFileURL else { return }
        let url = url.standardizedFileURL
        run("Indexing external soundtrack…", additionalSources: [url]) { token, useSidecar in
            let engine = CutEngine(cancelled: { token.isCancelled }, useSidecar: useSidecar)
            let ordinary = try engine.inspect(url, keyframes: true)
            let info = try engine.multicamClock(ordinary)
            guard let stream = info.audio.first?.stream.index else {
                throw CutError(code: "invalid_source", message: "Choose a movie or audio recording with a usable audio stream.")
            }
            return (info, ordinary, stream)
        } onFailure: { message in
            if let onFailure { onFailure(message) }
            else { self.fail(message) }
        } onSuccess: { info, ordinary, stream in
            var source = self.project?.sources.first(where: { $0.file == info.url.path })
                ?? MulticamSource(id: UUID().uuidString, file: info.url.path)
            source.audioStream = source.audioStream.flatMap { index in
                info.audio.contains(where: { $0.stream.index == index }) ? index : nil
            } ?? stream
            onIndexed(.init(source: source, media: info, ordinaryMedia: ordinary))
        }
    }

    @discardableResult
    func replaceProgramAudio(with selection: MulticamAudioSelection, external: SourceDraft,
                             confirmedOffset: RationalTime? = nil) -> Bool {
        guard canReplaceSourceAudio, selection.source == external.id,
              external.media.audio.contains(where: { $0.stream.index == selection.stream }) else { return false }
        guard soundtrackIsCurrent(external.media) else { return false }
        if let existing = project?.sources.first(where: { $0.id == external.id }) {
            guard confirmedOffset == nil,
                  URL(fileURLWithPath: existing.file).standardizedFileURL == external.media.url.standardizedFileURL,
                  media[existing.id].map({ $0.identity == external.media.identity }) ?? true else {
                fail("This project recording changed. Relink the source before replacing its soundtrack.")
                return false
            }
        }
        cacheIndexedSource(external.media, ordinary: external.ordinaryMedia)
        let replaced = edit("Replace Program Audio") { project in
            if !project.sources.contains(where: { $0.id == external.id }) {
                var source = external.source
                source.audioStream = selection.stream
                if let confirmedOffset { source.offset = confirmedOffset }
                project.audioSources.append(source)
            }
            project.replaceProgramAudio(with: selection)
        }
        if replaced { status = "Updated the multicam soundtrack." }
        return replaced
    }
}

private extension MulticamProject {
    mutating func replaceProgramAudio(with selection: MulticamAudioSelection) {
        audio = .fixed(selection)
        for index in switches.indices { switches[index].audio = nil }
    }
}

struct MulticamReplacementAudioView: View {
    @ObservedObject var model: MulticamEditorModel
    @State private var selection: MulticamAudioSelection?
    @State private var external: MulticamEditorModel.SourceDraft?
    @State private var issue: String?
    @State private var aligningExternal = false
    @State private var externalStream: Int?

    var body: some View {
        if aligningExternal, let external {
            MulticamTrackReplacementView(model: model, original: nil, incoming: external, incomingStream: externalStream) {
                model.isReplacementAudioPresented = false
            }
        } else {
            programChoices
        }
    }

    private var programChoices: some View {
        EditorSheet(title: "Replace Program Audio",
                    message: "Use the same soundtrack across camera switches. This replaces any audio choices you made at those switches.") {
            Form {
                Picker("Source stream", selection: $selection) {
                    Text("Select a recording and stream").tag(nil as MulticamAudioSelection?)
                    ForEach(sources) { source in
                        ForEach(streams(for: source.id), id: \.index) { stream in
                            Text("\(source.displayName) · \(stream.exportLabel)")
                                .tag(Optional(MulticamAudioSelection(source: source.id, stream: stream.index)))
                        }
                    }
                }
                .disabled(model.isBusy)
                .help("Choose soundtrack stream")
                .onChange(of: selection) { _, _ in issue = nil }
            }
            if model.isBusy {
                ProgressView("Indexing external soundtrack…")
                    .controlSize(.small)
            }
            if let issue { IssueLabel(issue) }
        } actions: {
            Button("Choose External Soundtrack…") {
                issue = nil
                model.chooseExternalSoundtrack(onFailure: { issue = $0 }) { draft in
                    external = draft
                    externalStream = draft.source.audioStream
                    aligningExternal = true
                }
            }
            .help("Browse for soundtrack file")
            .disabled(model.isBusy)
            Spacer()
            Button("Cancel") {
                if model.isBusy { model.cancel() }
                model.isReplacementAudioPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .help("Cancel soundtrack replacement")
            Button(externalSource == nil ? "Use Soundtrack" : "Align Soundtrack…") {
                guard let selection else { return }
                if let source = externalSource, let info = model.media[source.id] {
                    external = .init(source: source, media: info, ordinaryMedia: model.ordinaryAnalysisMedia(source.id))
                    externalStream = selection.stream
                    aligningExternal = true
                    return
                }
                if let uncovered = model.programAudioCoverageIssue(with: selection) {
                    issue = uncovered
                    return
                }
                let replaced = model.byHand { model.replaceProgramAudio(with: selection) }
                if replaced { model.isReplacementAudioPresented = false }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy || selection.map { choice in
                !streams(for: choice.source).contains(where: { $0.index == choice.stream })
            } ?? true)
                .help("Apply selected soundtrack")
        }
        .frame(width: 500)
    }

    private var externalSource: MulticamSource? {
        model.project?.audioSources.first { $0.id == selection?.source }
    }

    private var sources: [MulticamSource] {
        guard let project = model.project else { return [] }
        let bound = Set(project.audioReplacements.map { $0.replacement.source })
        return project.sources.filter { !bound.contains($0.id) }
    }

    private func streams(for source: String) -> [StreamInfo] {
        guard let info = model.media[source], info.hasFullEditIndex else { return [] }
        return info.audio.map(\.stream)
    }
}
