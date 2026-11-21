import AppKit
import Darwin
import MPCutCore

struct ExportSheetOptions: Sendable {
    var mode: ExportMode = .smart
    var tracks: ExportTracks = .all
    var audioTrackOrdinal: Int?
    var effectiveMode: ExportMode { tracks == .all ? mode : .copy }
    var copyContainer = "mp4"
    var encodeContainer = "mp4"
    var proResContainer = "mov"
    var codec: ReencodeCodec = .h264
    var standardQuality: ReencodeQuality = .balanced
    var proResQuality: ReencodeQuality = .prores422
    var audio: ReencodeAudio = .auto

    var container: String {
        guard effectiveMode == .encode else { return copyContainer }
        return codec == .prores ? proResContainer : encodeContainer
    }
    var quality: ReencodeQuality { codec == .prores ? proResQuality : standardQuality }
    var effectiveAudio: ReencodeAudio { container == "mp4" && audio == .pcm ? .auto : audio }
    var settings: ReencodeSettings { .init(codec: codec, quality: quality, audio: effectiveAudio) }
}

struct ExportContainerChoices: Sendable {
    let tracks: [ExportTracks: [String]]
    let audioStreams: [Int: [String]]

    init(source: MediaInfo, clips: [ClipRequest], preferred: String?, cancelled: @escaping @Sendable () -> Bool) {
        var available: [ExportTracks: [String]] = [:]
        let audio = source.streams.filter { $0.kind == "audio" }
        if source.hasVideo {
            let all = CutEngine(cancelled: cancelled).suggestedContainers(for: source, clips: clips)
            available[.all] = all.isEmpty ? [preferred ?? "mp4"] : all
            available[.video] = CutEngine(cancelled: cancelled, tracks: .video).suggestedContainers(for: source, clips: clips)
        }
        if !audio.isEmpty {
            available[.audio] = CutEngine(cancelled: cancelled, tracks: .audio).suggestedContainers(for: source, clips: clips)
        }
        tracks = available
        audioStreams = audio.count > 1 ? Dictionary(uniqueKeysWithValues: audio.indices.map { ordinal in
            (ordinal, CutEngine(cancelled: cancelled, tracks: .audio, audioTrackOrdinal: ordinal).suggestedContainers(for: source, clips: clips))
        }) : [:]
    }

    func choices(for options: ExportSheetOptions) -> [String] {
        if options.tracks == .audio, let index = options.audioTrackOrdinal { return audioStreams[index] ?? [] }
        return tracks[options.tracks] ?? []
    }
}

enum EditorExportPlan: Sendable {
    case packets(ResolvedEdit, mode: ExportMode, tracks: ExportTracks)
    case conversion(ReencodePlan)

    var summary: String {
        switch self {
        case .packets(let edit, .smart, .all):
            guard let encoded = try? edit.encodedVideoDuration(for: .smart),
                  let copied = try? edit.copiedVideoDuration(for: .smart) else {
                return "The video durations could not be calculated."
            }
            let durations = "Copied video: \(Self.seconds(copied.seconds)) · Encoded video: \(Self.seconds(encoded.seconds))"
            return copied == .zero && encoded > .zero ? durations + "\nEvery selected video frame will be encoded." : durations
        case .packets(let edit, _, let tracks):
            let contents: String
            switch tracks {
            case .video: contents = "video"
            case .audio: contents = "audio"
            case .all: contents = "media"
            }
            return "Copy \(Self.seconds(edit.duration.seconds)) of \(contents) to \(edit.container.uppercased())."
        case .conversion(let plan):
            let video = "\(plan.settings.codec.displayName) · \(plan.settings.quality.displayName) · \(plan.width) × \(plan.height)"
            let groups = Dictionary(grouping: plan.audioActions, by: \.action)
            let audio = ReencodeAudio.allCases.compactMap { action -> String? in
                guard let tracks = groups[action] else { return nil }
                let label = tracks.count == 1 ? "Track" : "Tracks"
                let numbers = tracks.map { String($0.track) }.joined(separator: ", ")
                return "\(label) \(numbers): \(action.displayName)"
            }
            let audioSummary = "Audio: " + (audio.isEmpty ? "No audio tracks" : audio.joined(separator: ", "))
            return ([video, audioSummary] + plan.warnings).joined(separator: "\n")
        }
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3...6))) + " s"
    }
}

struct ExportCutReview: Sendable {
    let original: [ClipRequest]
    let revised: [ClipRequest]
    let detail: String

    init?(original: [ClipRequest], snapped: ResolvedEdit,
          media: [URL: MediaInfo], engine: CutEngine,
          cancelled: @Sendable () -> Bool) {
        // The copy planner can combine adjacent pieces from the same source.
        // Keep their existing timeline seam when proposing new outer bounds.
        var groups: [Range<Int>] = []
        for index in original.indices {
            let current = original[index]
            if let group = groups.last, let info = media[current.file],
               engine.coalescesAdjacentRanges(in: info, container: snapped.container),
               original[index - 1].file == current.file, original[index - 1].to == current.from {
                groups[groups.count - 1] = group.lowerBound..<(index + 1)
            } else {
                groups.append(index..<(index + 1))
            }
        }
        guard groups.count == snapped.segments.count else { return nil }

        var changes: [String] = []
        var replacement: [ClipRequest] = []
        var originalDuration = RationalTime.zero
        for (group, target) in zip(groups, snapped.segments) {
            for index in group {
                let clip = original[index]
                guard let from = clip.from, let to = clip.to, clip.file == target.file else { return nil }
                let candidateFrom = index == group.lowerBound ? target.from : from
                let candidateTo = index == group.upperBound - 1 ? target.to : to
                guard candidateFrom < candidateTo,
                      let duration = try? originalDuration.adding(to.subtracting(from)) else { return nil }
                originalDuration = duration
                if from != candidateFrom || to != candidateTo {
                    let time = EditorExportPlan.seconds
                    changes.append("Clip \(index + 1) · \(clip.file.lastPathComponent)\n"
                        + "Original  \(time(from.seconds)) – \(time(to.seconds))\n"
                        + "Proposed  \(time(candidateFrom.seconds)) – \(time(candidateTo.seconds))")
                }
                replacement.append(.init(file: clip.file, from: candidateFrom, to: candidateTo))
            }
        }
        guard !changes.isEmpty, !cancelled(),
              let exact = try? engine.resolve(replacement, media: media, container: snapped.container) else { return nil }
        self.original = original
        revised = replacement
        let change = (try? exact.duration.subtracting(originalDuration).seconds)
            ?? (exact.duration.seconds - originalDuration.seconds)
        let delta = (change >= 0 ? "+" : "−") + EditorExportPlan.seconds(abs(change))
        detail = changes.joined(separator: "\n\n") + "\n\nTotal duration change: \(delta)"
    }
}

enum ExportAvailability: Sendable {
    case ready(EditorExportPlan)
    case unavailable(String, ExportCutReview?)

    static func check(_ options: ExportSheetOptions, clips: [ClipRequest], media: [URL: MediaInfo], useSidecar: Bool = true) -> Self {
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        let engine = CutEngine(cancelled: cancelled, smartTrim: options.effectiveMode == .smart, useSidecar: useSidecar,
                               tracks: options.tracks, audioTrackOrdinal: options.audioTrackOrdinal)
        do {
            if options.effectiveMode == .encode {
                return try AnalysisSidecar.$readsEnabled.withValue(useSidecar && AnalysisSidecar.readsEnabled) {
                    .ready(.conversion(try ReencodeEngine(cancelled: cancelled)
                        .resolve(clips, media: media, container: options.container, settings: options.settings)))
                }
            }
            let edit = try engine.resolve(clips, media: media, container: options.container)
            return .ready(.packets(edit, mode: options.effectiveMode, tracks: options.tracks))
        } catch {
            var message = error.localizedDescription
            var review: ExportCutReview?
            if let issue = error as? CutError {
                if let index = issue.segment, clips.indices.contains(index - 1) {
                    let clip = clips[index - 1]
                    let boundary = issue.boundary == "from" ? clip.from : issue.boundary == "to" ? clip.to : nil
                    let location = boundary.map { " at \(EditorExportPlan.seconds($0.seconds))" } ?? ""
                    message = "Clip \(index) · \(clip.file.lastPathComponent)\(location)\n\(message)"
                }
                if let times = issue.nearest, !times.isEmpty {
                    message += "\nVerified alternatives: " + times.map { EditorExportPlan.seconds($0.seconds) }.joined(separator: ", ")
                }
                if options.mode == .copy, options.tracks == .all, issue.code == "unsafe_boundary", !cancelled(),
                   let snapped = try? engine.resolve(clips, snap: .nearest, media: media, container: options.container) {
                    review = ExportCutReview(original: clips, snapped: snapped, media: media,
                                             engine: engine, cancelled: cancelled)
                }
            }
            return .unavailable(message, review)
        }
    }
}

@MainActor
final class ExportFormatControl: NSObject, NSOpenSavePanelDelegate {
    private weak var panel: NSSavePanel?
    private var options: ExportSheetOptions
    private let copyContainers: ExportContainerChoices
    private let audioStreams: [StreamInfo]
    private let sourceHasVideo: Bool
    private let sourceHasAudio: Bool
    private let clips: [ClipRequest]
    private let media: [URL: MediaInfo]
    private let useSidecar: Bool
    private let changed: (ExportSheetOptions, Bool) -> Void
    private let directoryChanged: (URL) -> Void
    private var preflight: Task<ExportAvailability, Never>?
    private var revision = UUID()
    private var availability: ExportAvailability?
    private var review: ExportCutReview?
    private(set) var appliedReview: ExportCutReview?
    var selected: EditorExportPlan? {
        if case .ready(let plan) = availability { return plan }
        return nil
    }

    private let modes: [ExportMode] = [.smart, .copy, .encode]
    private let codecs: [ReencodeCodec] = [.h264, .hevc, .prores]
    private var audioChoices: [ReencodeAudio] {
        ReencodeAudio.allCases.filter { $0 != .removeAudio && (options.container != "mp4" || $0 != .pcm) }
    }
    private var qualities: [ReencodeQuality] {
        options.codec == .prores ? [.proresLT, .prores422, .proresHQ] : [.smallerFile, .balanced, .highQuality]
    }
    private var containers: [String] {
        options.effectiveMode == .encode ? (options.codec == .prores ? ["mov", "mkv"] : ["mp4", "mov", "mkv"]) : copyContainers.choices(for: options)
    }
    private let videoCheck = NSButton(checkboxWithTitle: "Video", target: nil, action: nil)
    private let audioCheck = NSButton(checkboxWithTitle: "Audio", target: nil, action: nil)
    private let modePicker = NSPopUpButton()
    private let containerPicker = NSPopUpButton()
    private let codecPicker = NSPopUpButton()
    private let qualityPicker = NSPopUpButton()
    private let audioPicker = NSPopUpButton()
    private let audioTrackPicker = NSPopUpButton()
    private let trackRow = NSStackView()
    private let settings = NSStackView()
    private let statusIcon = NSImageView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let reviewButton = NSButton(title: "Review Cuts…", target: nil, action: nil)
    private let encodeButton = NSButton(title: "Choose Re-encode", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply to Timeline", target: nil, action: nil)
    private let reviewScroll = NSScrollView()
    private let reviewText = NSTextView(frame: NSRect(x: 0, y: 0, width: 470, height: 124))
    private let accessory = NSStackView()

    init(panel: NSSavePanel, options: ExportSheetOptions, copyContainers: ExportContainerChoices,
         clips: [ClipRequest], media: [URL: MediaInfo], useSidecar: Bool = true,
         changed: @escaping (ExportSheetOptions, Bool) -> Void,
         directoryChanged: @escaping (URL) -> Void) {
        self.panel = panel
        self.options = options
        self.copyContainers = copyContainers
        self.clips = clips
        self.media = media
        self.useSidecar = useSidecar
        audioStreams = clips.first.flatMap { media[$0.file] }?.streams.filter { $0.kind == "audio" } ?? []
        sourceHasVideo = media.values.contains(where: \.hasVideo)
        sourceHasAudio = media.values.contains { $0.streams.contains { $0.kind == "audio" } }
        self.changed = changed
        self.directoryChanged = directoryChanged
        super.init()
        panel.delegate = self

        videoCheck.target = self
        videoCheck.action = #selector(selectTracks)
        audioCheck.target = self
        audioCheck.action = #selector(selectTracks)
        configure(audioTrackPicker, label: "Audio tracks", action: #selector(selectAudioTrack))
        trackRow.addArrangedSubview(row("Tracks", audioTrackPicker))
        configure(modePicker, label: "Mode", action: #selector(selectMode))
        configure(containerPicker, label: "Container", action: #selector(selectContainer))
        configure(codecPicker, label: "Video", action: #selector(selectCodec))
        configure(qualityPicker, label: "Quality", action: #selector(selectQuality))
        configure(audioPicker, label: "Audio", action: #selector(selectAudio))
        configure(reviewButton, action: #selector(showReview))
        configure(encodeButton, action: #selector(chooseEncode))
        configure(applyButton, action: #selector(applyReview))

        settings.orientation = .vertical
        settings.alignment = .leading
        settings.addArrangedSubview(paired(row("Video", codecPicker), row("Quality", qualityPicker)))
        if media.values.contains(where: { !$0.audio.isEmpty }) {
            settings.addArrangedSubview(row("Audio", audioPicker))
        }
        statusIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        statusIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        summary.preferredMaxLayoutWidth = 446
        summary.maximumNumberOfLines = 0
        summary.setContentCompressionResistancePriority(.required, for: .vertical)
        let result = NSStackView(views: [statusIcon, summary])
        result.spacing = 8
        result.alignment = .top

        reviewText.isEditable = false
        reviewText.isRichText = false
        reviewText.isVerticallyResizable = true
        reviewText.autoresizingMask = [.width]
        reviewText.textContainer?.widthTracksTextView = true
        reviewText.textContainerInset = NSSize(width: 6, height: 6)
        reviewText.font = .systemFont(ofSize: NSFont.systemFontSize)
        reviewText.setAccessibilityLabel("Original and proposed cuts")
        reviewScroll.documentView = reviewText
        reviewScroll.borderType = .bezelBorder
        reviewScroll.hasVerticalScroller = true
        reviewScroll.heightAnchor.constraint(equalToConstant: 124).isActive = true
        reviewScroll.widthAnchor.constraint(equalToConstant: 470).isActive = true

        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        [paired(videoCheck, audioCheck), trackRow, paired(row("Mode", modePicker), row("Container", containerPicker)), settings, result,
         reviewButton, encodeButton, reviewScroll, applyButton].forEach(accessory.addArrangedSubview)
        summary.widthAnchor.constraint(equalToConstant: 446).isActive = true
        updatePickers()
        checkAvailability()
    }

    func stopChecking() { preflight?.cancel() }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func configure(_ picker: NSPopUpButton, label: String, action: Selector) {
        picker.target = self
        picker.action = action
        picker.setAccessibilityLabel(label)
        picker.widthAnchor.constraint(equalToConstant: 144).isActive = true
    }

    private func row(_ title: String, _ picker: NSPopUpButton) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 66).isActive = true
        let row = NSStackView(views: [label, picker])
        row.alignment = .centerY
        return row
    }

    private func paired(_ left: NSView, _ right: NSView) -> NSStackView {
        let row = NSStackView(views: [left, right])
        row.spacing = 28
        row.alignment = .centerY
        return row
    }

    private func fill(_ picker: NSPopUpButton, titles: [String], selected: Int?) {
        picker.removeAllItems()
        picker.addItems(withTitles: titles)
        if !titles.isEmpty { picker.selectItem(at: selected ?? 0) }
        picker.isEnabled = titles.count > 1
    }

    private func updatePickers() {
        videoCheck.state = options.tracks != .audio && sourceHasVideo ? .on : .off
        audioCheck.state = options.tracks != .video && sourceHasAudio ? .on : .off
        videoCheck.isEnabled = sourceHasVideo && audioCheck.state == .on
        audioCheck.isEnabled = sourceHasAudio && videoCheck.state == .on
        trackRow.isHidden = options.tracks != .audio || audioStreams.count < 2
        fill(audioTrackPicker, titles: ["All audio tracks"] + audioStreams.map(\.exportLabel),
             selected: options.audioTrackOrdinal.flatMap { audioStreams.indices.contains($0) ? $0 + 1 : nil })
        fill(modePicker, titles: modes.map(\.displayName), selected: modes.firstIndex(of: options.effectiveMode))
        modePicker.isEnabled = options.tracks == .all
        fill(containerPicker, titles: containers.map(containerDisplayName), selected: containers.firstIndex(of: options.container))
        fill(codecPicker, titles: codecs.map(\.displayName), selected: codecs.firstIndex(of: options.codec))
        fill(qualityPicker, titles: qualities.map(\.displayName), selected: qualities.firstIndex(of: options.quality))
        fill(audioPicker, titles: audioChoices.map(\.displayName), selected: audioChoices.firstIndex(of: options.effectiveAudio))
        settings.isHidden = options.effectiveMode != .encode
    }

    private func didChange(from previousContainer: String, explicitCopyContainer: Bool = false) {
        if let panel, previousContainer != options.container {
            let name = panel.nameFieldStringValue as NSString
            if name.pathExtension.lowercased() == previousContainer {
                panel.nameFieldStringValue = "\(name.deletingPathExtension).\(options.container)"
            }
        }
        changed(options, explicitCopyContainer)
        updatePickers()
        checkAvailability()
    }

    @objc private func selectTracks() {
        let previousContainer = options.container
        if videoCheck.state == .on && audioCheck.state == .on { options.tracks = .all }
        else { options.tracks = videoCheck.state == .on ? .video : .audio }
        options.audioTrackOrdinal = nil
        let available = copyContainers.choices(for: options)
        if options.tracks == .audio || !available.contains(previousContainer) {
            options.copyContainer = available.first ?? previousContainer
        } else {
            options.copyContainer = previousContainer
        }
        didChange(from: previousContainer)
    }

    @objc private func selectAudioTrack() {
        let previousContainer = options.container
        let index = audioTrackPicker.indexOfSelectedItem
        options.audioTrackOrdinal = index > 0 ? index - 1 : nil
        options.copyContainer = copyContainers.choices(for: options).first ?? previousContainer
        didChange(from: previousContainer)
    }

    @objc private func selectMode() {
        let previousContainer = options.container
        options.mode = modes[modePicker.indexOfSelectedItem]
        didChange(from: previousContainer)
    }

    @objc private func chooseEncode() {
        modePicker.selectItem(at: 2)
        selectMode()
    }

    @objc private func selectContainer() {
        let previousContainer = options.container
        let container = containers[containerPicker.indexOfSelectedItem]
        if options.effectiveMode != .encode {
            options.copyContainer = container
        } else if options.codec == .prores {
            options.proResContainer = container
        } else {
            options.encodeContainer = container
        }
        didChange(from: previousContainer, explicitCopyContainer: options.tracks == .all && options.effectiveMode != .encode)
    }

    @objc private func selectCodec() {
        let previousContainer = options.container
        options.codec = codecs[codecPicker.indexOfSelectedItem]
        didChange(from: previousContainer)
    }

    @objc private func selectQuality() {
        let quality = qualities[qualityPicker.indexOfSelectedItem]
        if options.codec == .prores {
            options.proResQuality = quality
        } else {
            options.standardQuality = quality
        }
        didChange(from: options.container)
    }

    @objc private func selectAudio() {
        options.audio = audioChoices[audioPicker.indexOfSelectedItem]
        didChange(from: options.container)
    }

    private func checkAvailability() {
        stopChecking()
        let id = UUID()
        revision = id
        availability = nil
        review = nil
        updateActions()
        let task = Task.detached(priority: .userInitiated) { [options, clips, media, useSidecar] in
            ExportAvailability.check(options, clips: clips, media: media, useSidecar: useSidecar)
        }
        preflight = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.revision == id, !task.isCancelled else { return }
            self.availability = result
            self.updateActions()
        }
    }

    private func updateActions() {
        let symbol: String
        let description: String
        switch availability {
        case nil:
            symbol = "clock"
            description = "Checking export"
            statusIcon.contentTintColor = .secondaryLabelColor
            summary.stringValue = "Checking \(options.effectiveMode.displayName) for this timeline…"
        case .ready(let plan):
            symbol = "checkmark.circle"
            description = "Export ready"
            statusIcon.contentTintColor = .secondaryLabelColor
            summary.stringValue = plan.summary
        case .unavailable(let message, _):
            symbol = "exclamationmark.triangle.fill"
            description = "Export unavailable"
            statusIcon.contentTintColor = .systemOrange
            summary.stringValue = "\(options.effectiveMode.displayName) unavailable\n\(message)"
        }
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusIcon.setAccessibilityLabel(description)
        if case .unavailable(_, let proposed) = availability {
            reviewButton.isHidden = proposed == nil || review != nil
            encodeButton.isHidden = options.effectiveMode != .smart
        } else {
            reviewButton.isHidden = true
            encodeButton.isHidden = true
        }
        reviewScroll.isHidden = review == nil
        applyButton.isHidden = review == nil
        accessory.layoutSubtreeIfNeeded()
        accessory.frame.size = accessory.fittingSize
        if panel?.accessoryView !== accessory { panel?.accessoryView = accessory }
    }

    @objc private func showReview() {
        guard case .unavailable(_, let proposed?) = availability else { return }
        review = proposed
        reviewText.string = proposed.detail
        reviewText.scrollToBeginningOfDocument(nil)
        updateActions()
    }

    @objc private func applyReview() {
        guard let review else { return }
        appliedReview = review
        panel?.cancel(nil)
    }

    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        if let url { directoryChanged(url) }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if case .unavailable(let message, _) = availability {
            throw CutError(code: "export_unavailable", message: message)
        }
        guard selected != nil else {
            throw CutError(code: "export_preflight_pending", message: "Wait for the export check to finish.")
        }
        try validateExportDestination(url, container: options.container)
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag else { return filename }
        let name = filename as NSString
        return name.pathExtension.lowercased() == options.container ? filename : "\(filename).\(options.container)"
    }
}

extension ExportMode {
    var displayName: String {
        switch self {
        case .smart: return "Smart Trim"
        case .copy: return "Lossless Copy"
        case .encode: return "Re-encode"
        }
    }
}

extension ReencodeCodec {
    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .prores: return "ProRes"
        }
    }
}

extension ReencodeQuality {
    var displayName: String {
        switch self {
        case .smallerFile: return "Smaller File"
        case .balanced: return "Balanced"
        case .highQuality: return "High Quality"
        case .proresLT: return "422 LT"
        case .prores422: return "422"
        case .proresHQ: return "422 HQ"
        }
    }
}

extension ReencodeAudio {
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .copyOriginal: return "Copy Original"
        case .aac: return "AAC"
        case .pcm: return "PCM"
        case .removeAudio: return "Remove Audio"
        }
    }
}

extension StreamInfo {
    var exportLabel: String {
        let lang = language.isEmpty || language == "und" ? "" : " · " + language
        return "Track \(index) · \(codec.uppercased()) · \(channels) ch" + lang
    }
}

func validateExportDestination(_ url: URL, container: String) throws {
    guard container == url.pathExtension.lowercased() else {
        throw CutError(code: "unsupported_container", message: "The filename must use the selected container.")
    }
    var info = stat()
    if lstat(url.path, &info) == 0 {
        throw CutError(code: "output_exists", message: "Choose a new filename. MPCut preserves existing files.")
    }
    if errno != ENOENT {
        throw CutError(code: "invalid_output", message: "MPCut couldn’t check the selected destination.")
    }
}
