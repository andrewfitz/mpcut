import AppKit
import Darwin
import MPCutCore

struct ExportSheetOptions: Sendable, Equatable {
    var organization = ExportOrganization()
    var placements: ExportPlacementScope = .none
    var requireCameraCopy = false
    var pictureTiming: StillPictureTiming?
    var stillVideoCodec: ReencodeCodec?
    var mode: ExportMode = ExportRules.defaultMode(for: .movie)
    var tracks: ExportTracks = .all
    var audioTrackOrdinal: Int?
    /// A sound-only export copies packets or converts them. Smart Trim applies to picture.
    var audioMode: ExportMode = .copy
    var audioFormat: ReencodeAudio = .pcm
    var conversionContainer = "wav"
    var convertsAudio: Bool { tracks == .audio && audioMode == .encode }
    /// The mode the pickers hold for the selected tracks. The export rules decide what it is written as.
    var effectiveMode: ExportMode {
        let held = tracks == .audio ? audioMode : mode
        return ExportRules.cell(source: .movie, tracks: tracks, mode: held, placements: placements).resolvedMode
    }

    /// This selection in the terms shared with the CLI.
    func request(_ clips: [ClipRequest]) -> ExportRequest {
        ExportRequest(clips: clips, mode: effectiveMode, tracks: tracks, audioTrackOrdinal: audioTrackOrdinal,
                      container: container.isEmpty ? nil : container, audio: convertsAudio ? audioFormat : effectiveAudio,
                      codec: codec, quality: quality)
    }

    /// The selection that an offered alternative stands for.
    func applying(_ request: ExportRequest, container: String) -> ExportSheetOptions {
        var next = self
        next.tracks = request.tracks
        if request.tracks == .audio {
            if request.mode == .encode {
                next.convertAudio(to: request.audio, preferred: container)
            } else {
                next.audioMode = .copy
                next.copyContainer = container
            }
        } else {
            next.mode = request.mode
            if next.placements != .none { next.audio = request.audio }
            if request.mode != .encode {
                next.copyContainer = container
            } else {
                next.audio = request.audio
                if next.codec == .prores { next.proResContainer = container } else { next.encodeContainer = container }
            }
        }
        return next
    }
    var copyContainer = "mp4"
    var encodeContainer = "mp4"
    var proResContainer = "mov"
    var codec: ReencodeCodec = .h264
    var standardQuality: ReencodeQuality = .balanced
    var proResQuality: ReencodeQuality = .prores422
    var audio: ReencodeAudio = .auto

    var container: String {
        if convertsAudio { return conversionContainer }
        guard effectiveMode == .encode else { return copyContainer }
        return codec == .prores ? proResContainer : encodeContainer
    }

    /// Selects a conversion and a container it can be written to, keeping `preferred` when it fits.
    mutating func convertAudio(to format: ReencodeAudio, preferred: String? = nil) {
        let choices = conversionContainers(for: format)
        audioMode = .encode
        audioFormat = format
        conversionContainer = preferred.flatMap { choices.contains($0) ? $0 : nil } ?? choices.first ?? conversionContainer
    }
    func conversionContainers(for format: ReencodeAudio) -> [String] {
        let ordinary = AudioExportEngine.containers(for: format)
        guard placements == .insertion else { return ordinary }
        let still = ExportRules.stillContainers(mode: .encode, tracks: .audio, codec: codec, audio: format)
        return ordinary + still.filter { !ordinary.contains($0) }
    }
    var quality: ReencodeQuality { codec == .prores ? proResQuality : standardQuality }
    /// The audio action that is requested. A container that cannot carry it is refused by the export rules with
    /// the alternatives that work. Nothing is substituted here.
    var effectiveAudio: ReencodeAudio { audio }
    var settings: ReencodeSettings { .init(codec: codec, quality: quality, audio: effectiveAudio) }
    /// The settings of a batch, which names a conversion format through its audio action.
    var batchSettings: ReencodeSettings { convertsAudio ? ReencodeSettings(audio: audioFormat) : settings }
    var stillBatchSettings: ReencodeSettings {
        if tracks == .audio, effectiveMode == .copy { return .init(audio: .copyOriginal) }
        return batchSettings
    }

    /// The selection that an alternative reported by a batch stands for.
    func applying(_ alternative: ExportAlternative) -> ExportSheetOptions {
        var current = self
        if let video = alternative.stillVideoSettings {
            current.codec = video.codec
            current.stillVideoCodec = video.codec
            if video.codec == .prores { current.proResQuality = video.quality }
            else { current.standardQuality = video.quality }
        }
        let action = alternative.requestedStillAudio ?? alternative.audio ?? (placements == .none ? .auto : audio)
        var result = current.applying(ExportRequest(clips: [], mode: alternative.mode, tracks: alternative.tracks,
                                                    audio: action), container: alternative.container)
        if placements != .none {
            result.requireCameraCopy = alternative.arguments.contains("--require-camera-copy")
            result.pictureTiming = alternative.argument("--still-timing").flatMap(StillPictureTiming.init(rawValue:)) ?? pictureTiming
        }
        return result
    }
}

extension ExportAlternative {
    var requestedStillAudio: ReencodeAudio? {
        guard id.hasPrefix("still-") else { return nil }
        return argument("--audio").flatMap(ReencodeAudio.init(rawValue:))
    }

    var stillVideoSettings: ReencodeSettings? {
        guard id.hasPrefix("still-"), let codec = argument("--video").flatMap(ReencodeCodec.init(rawValue:)) else { return nil }
        return ReencodeSettings(codec: codec, quality: argument("--quality").flatMap(ReencodeQuality.init(rawValue:)))
    }

    func argument(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
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

    init(stillSource source: MediaInfo?, cancelled: @escaping @Sendable () -> Bool) {
        let picture = ExportRules.stillMovieContainers
        let audio = source.map { CutEngine(cancelled: cancelled, tracks: .audio).suggestedContainers(for: $0) } ?? []
        tracks = [.all: picture, .video: picture, .audio: audio.isEmpty ? ExportRules.stillSoundCopyContainers : audio]
        audioStreams = [:]
    }

    func choices(for options: ExportSheetOptions) -> [String] {
        if options.tracks == .audio, let index = options.audioTrackOrdinal, let choices = audioStreams[index] { return choices }
        return tracks[options.tracks] ?? []
    }
}

/// The plan every front end receives from the export rules.
typealias EditorExportPlan = ExportPlan

extension ExportPlan {
    var summary: String {
        switch self {
        case .audio(let plan):
            let size = plan.estimatedBytes.map { " · about " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            let fidelity = plan.isLossless ? "\nLossless conversion preserves the decoded audio samples."
                : plan.action == .pcm ? "\nPCM preserves the decoded audio but uses more disk space." : ""
            let first = "Convert \(Self.seconds(plan.edit.duration.seconds)) of audio to \(plan.formatDescription) "
                + "(.\(plan.edit.container))\(size)\(fidelity)"
            return ([first] + plan.warnings).joined(separator: "\n")
        case .packets(let edit, .smart, .all):
            guard let encoded = try? edit.encodedVideoDuration(for: .smart),
                  let copied = try? edit.copiedVideoDuration(for: .smart) else {
                return "MPCut couldn’t calculate how much video needs encoding."
            }
            let durations = "Copied video: \(Self.seconds(copied.seconds)) · Encoded video: \(Self.seconds(encoded.seconds))"
            return copied == .zero && encoded > .zero ? durations + "\nSmart Trim needs to re-encode every frame in this selection." : durations
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
            // Tracks converted alike share an entry. It states what is written: the AAC bit rate or the PCM word length.
            func format(_ track: ReencodeAudioAction) -> String {
                if track.action == .aac, let rate = track.bitRate { return " (\(rate / 1000) kbps)" }
                if track.action == .pcm, let depth = track.bitDepth {
                    return " (\(depth)-bit\(track.codec?.hasPrefix("pcm_f") == true ? " float" : ""))"
                }
                return ""
            }
            let groups = Dictionary(grouping: plan.audioActions, by: \.action)
            let audio = ReencodeAudio.allCases.flatMap { action -> [String] in
                let tracks = groups[action] ?? []
                let formats = tracks.map(format).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                return formats.map { written in
                    let alike = tracks.filter { format($0) == written }
                    let label = alike.count == 1 ? "Track" : "Tracks"
                    let numbers = alike.map { String($0.track) }.joined(separator: ", ")
                    return "\(label) \(numbers): \(action.displayName)\(written)"
                }
            }
            let audioSummary = "Audio: " + (audio.isEmpty ? "No audio tracks" : audio.joined(separator: ", "))
            return ([video, audioSummary] + plan.warnings).joined(separator: "\n")
        }
    }

    static func seconds(_ value: Double) -> String { ExportRules.seconds(value) }
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
    case stillReady(StillExportPlan)
    case unavailable(String, ExportCutReview?)

    static func check(_ options: ExportSheetOptions, clips: [ClipRequest], media: [URL: MediaInfo], useSidecar: Bool = true) -> Self {
        resolve(options, clips: clips, media: media, useSidecar: useSidecar).availability
    }

    /// Asks the shared export rules for the plan, or the failure and every alternative that works.
    static func resolve(_ options: ExportSheetOptions, clips: [ClipRequest], media: [URL: MediaInfo],
                        useSidecar: Bool = true) -> (availability: Self, failure: CutError?, offers: [ExportFallback]) {
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        let planner = ExportPlanner(cancelled: cancelled, useSidecar: useSidecar)
        switch planner.resolve(options.request(clips), media: media) {
        case .ready(let plan, _, _):
            return (.ready(plan), nil, [])
        case .unavailable(let issue, let offers):
            var review: ExportCutReview?
            // Reviewing cuts edits the timeline, which only this front end has.
            if options.mode == .copy, options.tracks == .all, issue.code == "unsafe_boundary", !cancelled() {
                let engine = CutEngine(cancelled: cancelled, useSidecar: useSidecar)
                if let snapped = try? engine.resolve(clips, snap: .nearest, media: media, container: options.container) {
                    review = ExportCutReview(original: clips, snapped: snapped, media: media, engine: engine, cancelled: cancelled)
                }
            }
            let fallbacks = offers.map { offer in
                ExportFallback(title: offer.alternative.label,
                               options: options.applying(offer.request, container: offer.alternative.container),
                               alternative: offer.alternative,
                               clips: offer.alternative.clips == nil ? nil : offer.request.clips)
            }
            return (.unavailable(ExportRules.describe(issue, clips: clips), review), issue, fallbacks)
        }
    }
}

/// The next export that works when the selected one does not, least destructive first.
/// It is offered to the user and never applied on its own.
struct ExportFallback: Sendable {
    let title: String
    let options: ExportSheetOptions
    /// The alternative as the export rules report it to every front end.
    let alternative: ExportAlternative
    /// Set when the alternative moves cuts: the clips to export instead.
    let clips: [ClipRequest]?

    /// The first alternative of the shared rules. The order and labels are decided in MPCutCore.
    static func find(after options: ExportSheetOptions, clips: [ClipRequest], media: [URL: MediaInfo],
                     containers: ExportContainerChoices, useSidecar: Bool = true) -> ExportFallback? {
        // Callers of this form apply `options` alone, so an alternative that moves cuts is not theirs to take.
        ExportAvailability.resolve(options, clips: clips, media: media, useSidecar: useSidecar).offers.first { $0.clips == nil }
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
    private let allowsApplyingReviewToTimeline: Bool
    private let excludedSources: Set<URL>
    private let useSidecar: Bool
    private let changed: (ExportSheetOptions, Bool) -> Void
    private let directoryChanged: (URL) -> Void
    private var preflight: Task<ExportAvailability, Never>?
    private var revision = UUID()
    private var availability: ExportAvailability?
    private(set) var fallback: ExportFallback?
    var isUnavailable: Bool {
        if case .unavailable = availability { return true }
        return false
    }
    private var review: ExportCutReview?
    /// What the ready plan of `revision` leaves behind, read off the main thread with the plan.
    private var copyOmissions: (revision: UUID, notes: [String])?
    private(set) var appliedReview: ExportCutReview?
    var selected: EditorExportPlan? {
        if case .ready(let plan) = availability { return plan }
        return nil
    }

    /// Every alternative the export rules report for the current failure, least destructive first.
    private(set) var alternatives: [ExportFallback] = []
    /// The failure as the engine reports it, with the same code and message the CLI prints.
    private(set) var failure: CutError?
    /// Clips of an applied alternative that moves cuts. Any other change returns to the timeline's clips.
    private var clipOverride: [ClipRequest]?
    private var pendingOverride: [ClipRequest]?

    var selectedStill: StillExportPlan? {
        if case .stillReady(let plan) = availability { return plan }
        return nil
    }
    private let stillProject: CutProject?
    private let expectedSoundtrackIdentity: SourceIdentity?
    private let stillAudioIssue: (ExportTracks, ReencodeAudio) -> CutError?
    private var stillExportOverride: CutProject?
    private(set) var appliedStillReview: CutProject?

    private var sourceKind: ExportSourceKind { sourceHasVideo ? .movie : .audio }
    private func cell(_ mode: ExportMode) -> ExportCell { ExportRules.cell(source: sourceKind, tracks: options.tracks, mode: mode, placements: options.placements) }
    /// The modes the matrix writes as themselves for the selected tracks.
    private var modes: [ExportMode] { ExportEntryPoint.sheet.selectableModes(source: sourceKind, tracks: options.tracks, placements: options.placements) }
    private func title(of mode: ExportMode) -> String { cell(mode).displayName }
    private var codecs: [ReencodeCodec] {
        ReencodeCodec.allCases.filter { $0 != .jpeg || stillProject?.stillFormat != nil }
    }
    /// The source's own format first, then the named conversions of the matrix.
    private var conversionFormats: [ReencodeAudio] {
        let selected = options.audioTrackOrdinal.flatMap { audioStreams.indices.contains($0) ? audioStreams[$0] : nil }
            ?? audioStreams.first
        let formats = ExportRules.namedConversions(sourceCodec: selected?.codec)
        if stillProject?.stillSoundtrack != nil || stillProject?.stillAudioReference?.audioTrack != nil {
            return ExportRules.stillSoundConversions
        }
        return options.placements == .insertion ? formats.filter(ExportRules.stillSoundConversions.contains) : formats
    }
    /// Every audio action of the cell. One the container cannot carry is refused with its alternatives.
    private var audioChoices: [ReencodeAudio] {
        if options.convertsAudio { return conversionFormats }
        if options.placements != .none {
            let actions = cell(options.effectiveMode).audioActions
            let hasSoundtrack = stillProject?.stillSoundtrack != nil || stillProject?.stillAudioReference?.audioTrack != nil
            return !hasSoundtrack || actions.contains(.auto) ? actions : [.auto] + actions
        }
        return cell(.encode).audioActions
    }
    private var qualities: [ReencodeQuality] { ExportRules.qualities(options.codec) }
    private var containers: [String] {
        if options.convertsAudio { return options.conversionContainers(for: options.audioFormat) }
        if options.placements != .none && options.tracks != .audio {
            return ExportRules.stillContainers(mode: options.effectiveMode, tracks: options.tracks,
                                               codec: options.codec, audio: options.effectiveAudio)
        }
        return options.effectiveMode == .encode ? ExportRules.reencodeContainers(options.codec) : copyContainers.choices(for: options)
    }
    private let videoCheck = NSButton(checkboxWithTitle: "Video", target: nil, action: nil)
    private let audioCheck = NSButton(checkboxWithTitle: "Audio", target: nil, action: nil)
    private let preserveCamera = NSButton(checkboxWithTitle: "Require Camera Video Copy", target: nil, action: nil)
    private let heldStills = NSButton(checkboxWithTitle: "One frame per still", target: nil, action: nil)
    private let modePicker = NSPopUpButton()
    private let containerPicker = NSPopUpButton()
    private let codecPicker = NSPopUpButton()
    private let qualityPicker = NSPopUpButton()
    private let audioPicker = NSPopUpButton()
    private let audioTrackPicker = NSPopUpButton()
    private let trackRow = NSStackView()
    /// Says, under the track picker, that the clips have different audio tracks and which ones are listed.
    private let audioTrackNote = NSTextField(wrappingLabelWithString: "")
    var audioTrackTitles: [String] { audioTrackPicker.itemTitles }
    var shownAudioTrackNote: String? { audioTrackNote.isHidden ? nil : audioTrackNote.stringValue }

    private static func audioTracks(of clips: [ClipRequest], media: [URL: MediaInfo]) -> [[StreamInfo]] {
        var seen = Set<URL>()
        return clips.filter { seen.insert($0.file).inserted }.compactMap { media[$0.file]?.streams.filter { $0.kind == "audio" } }
    }

    /// The audio tracks a sound-only export can name. The engine takes a track by its position among the audio tracks
    /// of each clip, so these are the first clip's, up to the number every clip has.
    static func commonAudioStreams(clips: [ClipRequest], media: [URL: MediaInfo]) -> [StreamInfo] {
        let tracks = audioTracks(of: clips, media: media)
        guard let first = tracks.first else { return [] }
        return Array(first.prefix(tracks.map(\.count).min() ?? 0))
    }

    /// What to say when the clips do not have the same audio tracks. Nil when they do.
    static func audioTrackRemark(clips: [ClipRequest], media: [URL: MediaInfo]) -> String? {
        let tracks = audioTracks(of: clips, media: media)
        guard let first = tracks.first, tracks.count > 1 else { return nil }
        let common = tracks.map(\.count).min() ?? 0
        if tracks.contains(where: { $0.count != common }) {
            return common > 1
                ? "The clips have different numbers of audio tracks. A track is taken by its position in each clip, so only the \(common) that every clip has are listed."
                : "The clips have different numbers of audio tracks, so one track cannot be chosen for all of them."
        }
        let differs = tracks.dropFirst().contains { other in
            zip(first, other).contains { $0.codec != $1.codec || $0.sampleRate != $1.sampleRate || $0.channels != $1.channels }
        }
        return differs && common > 1 ? "The clips have different audio formats. A track is taken by its position in each clip, and the list shows clip 1." : nil
    }
    private let settings = NSStackView()
    private var videoSettings: NSView?
    private let statusIcon = NSImageView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let stillBoundaryPicker = NSPopUpButton()
    private let applyStillBoundaryButton = NSButton(title: "Apply Reviewed Boundary", target: nil, action: nil)
    private let stillReview = NSStackView()
    private let reviewButton = NSButton(title: "Review Cuts…", target: nil, action: nil)
    private let encodeButton = NSButton(title: "", target: nil, action: nil)
    /// The alternatives after the first, in the order the export rules report them.
    private let morePicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let offerRow = NSStackView()
    /// The titles on offer: the button, then the pull-down beside it. This is the CLI's `alternatives` array.
    var offeredTitles: [String] {
        guard !offerRow.isHidden else { return [] }
        return [encodeButton.title] + (morePicker.isHidden ? [] : Array(morePicker.itemTitles.dropFirst()))
    }
    private let applyButton = NSButton(title: "Apply to Timeline", target: nil, action: nil)
    private let reviewScroll = NSScrollView()
    private let reviewText = NSTextView(frame: NSRect(x: 0, y: 0, width: 470, height: 124))
    private let accessory = NSStackView()
    private let saveExportResult = ExportResultFile.checkbox()
    var savesExportResult: Bool { saveExportResult.state == .on }

    init(panel: NSSavePanel, options: ExportSheetOptions, copyContainers: ExportContainerChoices,
         clips: [ClipRequest], media: [URL: MediaInfo], useSidecar: Bool = true, excludedSources: Set<URL> = [],
         allowsApplyingReviewToTimeline: Bool = true, stillProject: CutProject? = nil,
         expectedSoundtrackIdentity: SourceIdentity? = nil,
         stillAudioIssue: @escaping (ExportTracks, ReencodeAudio) -> CutError? = { _, _ in nil },
         changed: @escaping (ExportSheetOptions, Bool) -> Void,
         directoryChanged: @escaping (URL) -> Void) {
        self.allowsApplyingReviewToTimeline = allowsApplyingReviewToTimeline
        self.stillProject = stillProject
        self.expectedSoundtrackIdentity = expectedSoundtrackIdentity
        self.stillAudioIssue = stillAudioIssue
        self.panel = panel
        self.options = options
        self.copyContainers = copyContainers
        self.clips = clips
        self.media = media
        self.excludedSources = excludedSources
        self.useSidecar = useSidecar
        let reference = (stillProject?.stillSoundtrack ?? stillProject?.stillAudioReference).flatMap { clip in
            let streams = media[URL(fileURLWithPath: clip.file).standardizedFileURL]?.streams.filter { $0.kind == "audio" }
            if let index = clip.audioTrack, let streams, streams.indices.contains(index) {
                return [streams[index]]
            }
            return streams
        }
        audioStreams = reference ?? Self.commonAudioStreams(clips: clips, media: media)
        sourceHasVideo = stillProject != nil || media.values.contains(where: \.hasVideo)
        sourceHasAudio = stillProject?.stillSoundtrack != nil || stillProject?.stillAudioReference != nil ||
            media.values.contains { $0.streams.contains { $0.kind == "audio" } }
        self.changed = changed
        self.directoryChanged = directoryChanged
        super.init()
        panel.delegate = self

        videoCheck.target = self
        videoCheck.action = #selector(selectTracks)
        videoCheck.toolTip = "Include video"
        audioCheck.target = self
        audioCheck.action = #selector(selectTracks)
        audioCheck.toolTip = "Include audio"
        preserveCamera.target = self
        preserveCamera.action = #selector(selectPreserveCamera)
        preserveCamera.toolTip = "Require stream copy for retained camera video"
        heldStills.target = self
        heldStills.action = #selector(selectStillTiming)
        heldStills.toolTip = "Store one independently decodable video sample per still hold"
        configure(audioTrackPicker, label: "Audio tracks", action: #selector(selectAudioTrack))
        audioTrackPicker.toolTip = "Choose audio tracks"
        trackRow.addArrangedSubview(row("Tracks", audioTrackPicker))
        configure(modePicker, label: "Mode", action: #selector(selectMode))
        modePicker.toolTip = "Choose export mode"
        configure(containerPicker, label: "Container", action: #selector(selectContainer))
        containerPicker.toolTip = "Choose file format"
        configure(codecPicker, label: "Video", action: #selector(selectCodec))
        codecPicker.toolTip = "Choose video codec"
        configure(qualityPicker, label: "Quality", action: #selector(selectQuality))
        qualityPicker.toolTip = "Set video quality"
        configure(audioPicker, label: "Audio", action: #selector(selectAudio))
        audioPicker.toolTip = "Choose audio encoding"
        configure(reviewButton, action: #selector(showReview))
        reviewButton.toolTip = "Review proposed cuts"
        configure(applyStillBoundaryButton, action: #selector(applyStillBoundary))
        applyStillBoundaryButton.toolTip = "Apply reviewed boundary"
        stillBoundaryPicker.setAccessibilityLabel("Verified still placement boundaries")
        stillBoundaryPicker.toolTip = "Choose verified still boundary"
        stillReview.orientation = .vertical
        stillReview.alignment = .leading
        stillReview.addArrangedSubview(stillBoundaryPicker)
        stillReview.addArrangedSubview(applyStillBoundaryButton)
        configure(encodeButton, action: #selector(applyFallback))
        encodeButton.toolTip = "Use suggested export settings"
        configure(applyButton, action: #selector(applyReview))
        applyButton.toolTip = "Apply cuts to timeline"
        morePicker.target = self
        morePicker.action = #selector(applyListedAlternative)
        morePicker.bezelStyle = .rounded
        morePicker.setAccessibilityLabel("More export alternatives")
        morePicker.toolTip = "Show export alternatives"
        offerRow.spacing = 8
        offerRow.alignment = .centerY
        [encodeButton, morePicker].forEach(offerRow.addArrangedSubview)

        settings.orientation = .vertical
        settings.alignment = .leading
        let picture = paired(row("Video", codecPicker), row("Quality", qualityPicker))
        videoSettings = picture
        settings.addArrangedSubview(picture)
        if sourceHasAudio {
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
        reviewText.toolTip = "Compare original and proposed cuts"
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
        audioTrackNote.stringValue = Self.audioTrackRemark(clips: clips, media: media) ?? ""
        audioTrackNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        audioTrackNote.textColor = .secondaryLabelColor
        audioTrackNote.preferredMaxLayoutWidth = 446
        audioTrackNote.maximumNumberOfLines = 0
        audioTrackNote.setAccessibilityLabel("Audio tracks of the clips")
        [paired(videoCheck, audioCheck), trackRow, audioTrackNote, paired(row("Mode", modePicker), row("Container", containerPicker)), preserveCamera, heldStills, settings, result,
         reviewButton, stillReview, offerRow, reviewScroll, applyButton, saveExportResult].forEach(accessory.addArrangedSubview)
        summary.widthAnchor.constraint(equalToConstant: 446).isActive = true
        updatePickers()
        checkAvailability()
    }

    private var fallbackSearch: Task<ExportFallback?, Never>?
    /// True until the current selection has its answer from the export rules.
    private(set) var isChecking = false
    private var resolution: Task<(availability: ExportAvailability, failure: CutError?, offers: [ExportFallback]), Never>?

    func stopChecking() {
        preflight?.cancel()
        fallbackSearch?.cancel()
        resolution?.cancel()
    }

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
        audioTrackNote.isHidden = options.tracks != .audio || audioTrackNote.stringValue.isEmpty
        fill(audioTrackPicker, titles: ["All audio tracks"] + audioStreams.map(\.exportLabel),
             selected: options.audioTrackOrdinal.flatMap { audioStreams.indices.contains($0) ? $0 + 1 : nil })
        fill(modePicker, titles: modes.map(title(of:)), selected: modes.firstIndex(of: options.effectiveMode))
        modePicker.isEnabled = modes.count > 1
        preserveCamera.state = options.requireCameraCopy ? .on : .off
        preserveCamera.isHidden = options.placements == .none || options.tracks == .audio
        let defaultTiming = stillProject.map { ExportRules.defaultStillPictureTiming(for: $0) } ?? .cadence
        heldStills.state = (options.pictureTiming ?? defaultTiming) == .held ? .on : .off
        heldStills.isHidden = options.placements == .none || options.tracks == .audio
        fill(containerPicker, titles: containers.map(containerDisplayName), selected: containers.firstIndex(of: options.container))
        fill(codecPicker, titles: codecs.map(\.displayName), selected: codecs.firstIndex(of: options.codec))
        fill(qualityPicker, titles: qualities.map(\.displayName), selected: qualities.firstIndex(of: options.quality))
        fill(audioPicker, titles: audioChoices.map(\.displayName),
             selected: audioChoices.firstIndex(of: options.convertsAudio ? options.audioFormat : options.effectiveAudio))
        let stillSound = options.placements != .none && options.tracks == .all &&
            options.effectiveMode == .smart && sourceHasAudio
        let standalonePicture = stillProject?.stillFormat != nil && options.tracks != .audio && options.effectiveMode == .smart
        settings.isHidden = options.effectiveMode != .encode && !stillSound && !standalonePicture
        videoSettings?.isHidden = options.convertsAudio || (options.effectiveMode != .encode && !standalonePicture)
    }

    private func didChange(from previousContainer: String, explicitCopyContainer: Bool = false) {
        if !containers.contains(options.container), let first = containers.first, options.placements != .none {
            if options.convertsAudio {
                options.conversionContainer = first
            } else if options.effectiveMode != .encode {
                options.copyContainer = first
            } else if options.codec == .prores {
                options.proResContainer = first
            } else {
                options.encodeContainer = first
            }
        }
        if let panel, previousContainer != options.container {
            let name = panel.nameFieldStringValue as NSString
            if name.pathExtension.lowercased() == previousContainer {
                panel.nameFieldStringValue = "\(name.deletingPathExtension).\(options.container)"
            }
        }
        clipOverride = pendingOverride
        pendingOverride = nil
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

    @objc private func selectPreserveCamera() {
        options.requireCameraCopy = preserveCamera.state == .on
        didChange(from: options.container)
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
        let mode = modes[modePicker.indexOfSelectedItem]
        if options.tracks != .audio {
            options.mode = mode
        } else if mode == .encode {
            // Start from the source's own format where the helper can write it.
            let format = conversionFormats.contains(options.audioFormat) && options.audioMode == .encode
                ? options.audioFormat : conversionFormats[0]
            options.convertAudio(to: format, preferred: previousContainer)
        } else {
            options.audioMode = .copy
        }
        didChange(from: previousContainer)
    }

    /// Switches to the offered alternative. The destination is checked again when the panel is confirmed.
    @objc private func applyFallback() {
        guard let fallback else { return }
        apply(fallback)
    }

    @objc private func applyListedAlternative() {
        // Item 0 of a pull-down is its title. The rest follow the first alternative, which is the button.
        let index = morePicker.indexOfSelectedItem
        guard index > 0, alternatives.indices.contains(index) else { return }
        apply(alternatives[index])
    }

    /// Applies one of `alternatives`: the same request the CLI makes with that alternative's arguments.
    func apply(_ fallback: ExportFallback) {
        let previousContainer = options.container
        options = fallback.options
        pendingOverride = fallback.clips
        didChange(from: previousContainer)
    }

    @objc private func selectContainer() {
        let previousContainer = options.container
        let container = containers[containerPicker.indexOfSelectedItem]
        if options.convertsAudio {
            options.conversionContainer = container
        } else if options.effectiveMode != .encode {
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
        if stillProject != nil { options.stillVideoCodec = options.codec }
        didChange(from: previousContainer)
    }

    @objc private func selectStillTiming() {
        options.pictureTiming = heldStills.state == .on ? .held : .cadence
        didChange(from: options.container)
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
        let previousContainer = options.container
        let choice = audioChoices[audioPicker.indexOfSelectedItem]
        if options.convertsAudio {
            options.convertAudio(to: choice, preferred: previousContainer)
        } else {
            options.audio = choice
        }
        didChange(from: previousContainer)
    }

    private func checkAvailability() {
        stopChecking()
        let id = UUID()
        revision = id
        availability = nil
        fallback = nil
        alternatives = []
        failure = nil
        review = nil
        if let issue = stillAudioIssue(options.tracks, options.stillBatchSettings.audio) {
            availability = .unavailable(issue.message, nil)
            failure = issue
            isChecking = false
            updateActions()
            return
        }
        isChecking = true
        updateActions()
        let clips = clipOverride ?? self.clips
        let stillProject = stillExportOverride ?? self.stillProject
        // One call to the shared rules returns the plan, or the failure with the alternatives that work.
        let task = Task.detached(priority: .userInitiated) { [options, media, useSidecar, excludedSources, stillProject, expectedSoundtrackIdentity] in
            AnalysisSidecar.$excludedSources.withValue(excludedSources) {
                if let stillProject {
                    return ExportAvailability.resolve(options, project: stillProject, useSidecar: useSidecar,
                                                      expectedSoundtrackIdentity: expectedSoundtrackIdentity)
                }
                return ExportAvailability.resolve(options, clips: clips, media: media, useSidecar: useSidecar)
            }
        }
        resolution = task
        Task { [weak self] in
            let result = await task.value
            let omissions = await Task.detached(priority: .userInitiated) { result.availability.copyOmissions }.value
            guard let self, self.revision == id, !task.isCancelled else { return }
            self.copyOmissions = (id, omissions)
            self.availability = result.availability
            self.failure = result.failure
            self.alternatives = result.offers
            self.fallback = result.offers.first
            self.isChecking = false
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
            summary.stringValue = "Checking \(title(of: options.effectiveMode)) for this timeline…"
        case .stillReady(let plan):
            symbol = "checkmark.circle"
            description = "Export ready"
            statusIcon.contentTintColor = .secondaryLabelColor
            summary.stringValue = plan.inspectorSummary
        case .ready(let plan):
            symbol = "checkmark.circle"
            description = "Export ready"
            statusIcon.contentTintColor = .secondaryLabelColor
            summary.stringValue = plan.summary(noting: copyOmissions?.revision == revision ? copyOmissions?.notes ?? [] : [])
        case .unavailable(let message, _):
            symbol = "exclamationmark.triangle.fill"
            description = "Export unavailable"
            statusIcon.contentTintColor = .systemOrange
            summary.stringValue = "\(title(of: options.effectiveMode)) unavailable\n\(message)"
        }
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusIcon.setAccessibilityLabel(description)
        if case .unavailable(_, let proposed) = availability {
            reviewButton.isHidden = proposed == nil || review != nil
            offerRow.isHidden = fallback == nil
            if let fallback { encodeButton.title = fallback.title }
            // The whole ordered list is on offer: the first as the button, the rest in the pull-down.
            let titles = ["More Alternatives"] + alternatives.dropFirst().map(\.title)
            if morePicker.itemTitles != titles {
                morePicker.removeAllItems()
                morePicker.addItems(withTitles: titles)
            }
            morePicker.isHidden = alternatives.count < 2
        } else {
            reviewButton.isHidden = true
            offerRow.isHidden = true
        }
        encodeButton.isHidden = offerRow.isHidden
        let stillOptions = failure?.stillBoundaryAdjustments ?? []
        stillReview.isHidden = stillOptions.isEmpty
        stillBoundaryPicker.removeAllItems()
        stillBoundaryPicker.addItems(withTitles: stillOptions.map(\.reviewDescription))
        applyStillBoundaryButton.title = allowsApplyingReviewToTimeline ? "Apply to Timeline" : "Use for This Export"
        reviewScroll.isHidden = review == nil
        applyButton.isHidden = review == nil || !allowsApplyingReviewToTimeline
        accessory.layoutSubtreeIfNeeded()
        accessory.frame.size = accessory.fittingSize
        if panel?.accessoryView !== accessory { panel?.accessoryView = accessory }
    }

    @objc private func applyStillBoundary() {
        guard let project = stillExportOverride ?? stillProject,
              let candidates = failure?.stillBoundaryAdjustments,
              candidates.indices.contains(stillBoundaryPicker.indexOfSelectedItem),
              let adjusted = try? project.applyingStillBoundary(candidates[stillBoundaryPicker.indexOfSelectedItem]) else { return }
        if allowsApplyingReviewToTimeline {
            appliedStillReview = adjusted
            panel?.cancel(nil)
        } else {
            stillExportOverride = adjusted
            checkAvailability()
        }
    }

    @objc private func showReview() {
        guard case .unavailable(_, let proposed?) = availability else { return }
        review = proposed
        reviewText.string = proposed.detail
        reviewText.scrollToBeginningOfDocument(nil)
        updateActions()
    }

    @objc private func applyReview() {
        guard allowsApplyingReviewToTimeline, let review else { return }
        appliedReview = review
        panel?.cancel(nil)
    }

    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        if let url { directoryChanged(url) }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if let issue = stillAudioIssue(options.tracks, options.stillBatchSettings.audio) { throw issue }
        if case .unavailable(let message, _) = availability {
            throw CutError(code: "export_unavailable", message: message)
        }
        guard selected != nil || selectedStill != nil else {
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
        ExportRules.displayName(mode: self)
    }
}

extension ReencodeCodec {
    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .prores: return "ProRes"
        case .jpeg: return "JPEG"
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
        ExportRules.displayName(audio: self)
    }
}

extension StreamInfo {
    var exportLabel: String { "Stream \(index) · \(audioFormatLabel)" }

    var audioFormatLabel: String {
        let lang = language.isEmpty || language == "und" ? "" : " · " + language
        // FFmpeg names an unlabelled layout by its count, which the channel count already says.
        let layout = channelLayout.isEmpty || channelLayout.hasSuffix(" channels") ? "" : " · " + channelLayout
        return "\(codec.uppercased()) · \(channels) ch" + layout + lang
    }
}

func validateExportDestination(_ url: URL, container: String) throws {
    guard container == url.pathExtension.lowercased() else {
        throw CutError(code: "unsupported_container", message: "Use the file extension for the selected container.")
    }
    var info = stat()
    if lstat(url.path, &info) == 0 {
        throw CutError(code: "output_exists", message: "A file with this name already exists. Choose another name.")
    }
    if errno != ENOENT {
        throw CutError(code: "invalid_output", message: "MPCut couldn’t check the selected destination.")
    }
}

extension ExportAvailability {
    static func resolve(_ options: ExportSheetOptions, project: CutProject,
                        useSidecar: Bool, expectedSoundtrackIdentity: SourceIdentity? = nil)
        -> (availability: Self, failure: CutError?, offers: [ExportFallback]) {
        do {
            let plan = try options.planStills(project, useSidecar: useSidecar,
                                             expectedSoundtrackIdentity: expectedSoundtrackIdentity,
                                             cancelled: { Task.isCancelled })
            return (.stillReady(plan), nil, [])
        } catch {
            let issue = (error as? CutError) ?? CutError(code: "export_failed", message: error.localizedDescription)
            let offers = (issue.alternatives ?? []).map {
                ExportFallback(title: $0.label, options: options.applying($0), alternative: $0, clips: nil)
            }
            return (.unavailable(issue.message, nil), issue, offers)
        }
    }
}

extension ExportSheetOptions {
    func planStills(_ project: CutProject, output: URL? = nil, useSidecar: Bool = true,
                    audioAction: ReencodeAudio? = nil,
                    expectedSoundtrackIdentity: SourceIdentity? = nil,
                    cancelled: @escaping @Sendable () -> Bool) throws -> StillExportPlan {
        let settings = stillBatchSettings
        let action = settings.audio
        let explicitAudio = audioAction ?? (effectiveMode != .copy && action != .auto ? action : nil)
        return try StillExportPlanner(useSidecar: useSidecar, cancelled: cancelled, replacementReferenceAngles: [:],
                                      expectedSoundtrackIdentity: expectedSoundtrackIdentity)
            .resolve(project, tracks: tracks, audioTrackOrdinal: audioTrackOrdinal, mode: effectiveMode,
                     requireCameraCopy: tracks != .audio && requireCameraCopy, container: container.isEmpty ? nil : container,
                     output: output, settings: settings,
                     audioAction: explicitAudio,
                     pictureTiming: pictureTiming,
                     videoCodec: stillVideoCodec ?? (project.stillFormat == nil && effectiveMode == .encode ? codec : nil))
    }
}

extension StillExportPlan {
    var inspectorSummary: String {
        let counts = [
            "Copied camera: \(report.copiedCameraDuration) s",
            "Encoded camera: \(report.encodedCameraDuration) s",
            "Generated stills: \(report.generatedStillDuration) s · \(report.generatedVideoSampleCount) samples",
            "Output duration: \(duration) s",
        ] + (report.videoCodec.map { ["Video: \($0.uppercased()) · \(report.writtenPictureDuration ?? duration) s"] } ?? [])
        let picture = report.picture.filter { $0.action != .copy }.map { span in
            let range = "\(span.output.from)–\(span.output.to) s"
            if let id = span.placementID { return "Still \(id) · \(span.clock) · output \(range)" }
            return "Encode camera edge · \(span.clock) · output \(range)"
        }
        let sound = report.soundActions.map { action in
            let silence = action.generatedSilence.isEmpty ? "" :
                " · silence " + action.generatedSilence.map { "\($0.from)–\($0.to) s" }.joined(separator: ", ")
            let sources = Array(Set(action.sources.compactMap(\.codec))).sorted()
            let source = sources.isEmpty ? "" : " · source " + sources.joined(separator: ", ")
            let layout = action.channelLayout.map { " · \($0)" } ?? ""
            let rate = action.sampleRate.map { " · \($0) Hz" } ?? ""
            let precision = action.bitDepth.map { " · \($0)-bit" } ?? ""
            let codec = action.codec.map { " · \($0.uppercased())" } ?? ""
            let treatment = action.treatment ?? action.audio.displayName
            return "Audio track \(action.ordinal + 1): \(treatment)\(codec)\(layout)\(rate)\(precision)\(source)\(silence)"
        }
        return (counts + picture + sound + report.warnings).joined(separator: "\n")
    }
}

extension StillBoundaryAdjustment {
    var reviewDescription: String {
        let change = durationChange > .zero ? "+\(durationChange)" : durationChange.description
        return "Still \(placementID) · \(boundary.rawValue) in \(clock) · \(requestedTime) → \(adjustedTime) s (\(change) s)"
    }
}
