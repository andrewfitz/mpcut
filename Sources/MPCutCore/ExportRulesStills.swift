import Foundation

extension ExportRules {
    public static let stillMovieContainers = multicamMovieContainers + ["mkv"]
    public static let stillSoundCopyContainers = ["m4a", "mov", "mp4", "mkv", "mka", "wav", "caf"]
    public static let stillSoundConversions: [ReencodeAudio] = [.pcm, .alac, .flac, .aac]
    public static let stillMovieAudioActions = movieAudioActions.filter { $0 != .auto } + [.alac, .flac]

    public static func allows(stillAudio audio: ReencodeAudio, in container: String,
                              videoCodec: ReencodeCodec? = nil) -> Bool {
        if let videoCodec, [.pcm, .alac, .flac].contains(audio) {
            return stillLosslessAudioActions(codec: videoCodec, container: container).contains(audio)
        }
        switch audio {
        case .auto, .copyOriginal, .removeAudio: return true
        case .pcm: return ["mov", "mkv", "wav", "wave", "caf"].contains(container)
        case .alac: return ["mov", "mp4", "m4v", "m4a"].contains(container)
        case .flac: return ["mp4", "m4v", "mkv", "mka", "flac"].contains(container)
        case .aac: return ["mov", "mp4", "m4v", "m4a"].contains(container)
        case .mp3, .opus: return false
        }
    }

    /// Lossless sound choices for the held-picture delivery targets.
    public static func stillLosslessAudioActions(codec: ReencodeCodec, container: String) -> [ReencodeAudio] {
        guard StillTimelineFormat.containers(for: codec).contains(container) else { return [] }
        switch container {
        case "mov": return codec == .jpeg ? [.pcm] : [.alac, .pcm]
        case "mp4", "m4v": return [.alac, .flac]
        case "mkv": return [.flac]
        default: return []
        }
    }

    public static func defaultStillLosslessAudio(codec: ReencodeCodec, container: String) -> ReencodeAudio? {
        if let first = stillLosslessAudioActions(codec: codec, container: container).first { return first }
        switch container {
        case "m4a": return .alac
        case "mka", "flac": return .flac
        case "wav", "wave", "caf": return .pcm
        default: return nil
        }
    }

    public static func stillContainers(mode: ExportMode, tracks: ExportTracks, codec: ReencodeCodec,
                                       audio: ReencodeAudio) -> [String] {
        if tracks == .audio {
            let containers = stillSoundCopyContainers + ["flac"]
            return containers.filter { allows(stillAudio: audio, in: $0) }
        }
        let codecContainers = StillTimelineFormat.containers(for: codec)
        return stillMovieContainers.filter {
            (mode == .copy || codecContainers.contains($0)) &&
                (tracks == .video || allows(stillAudio: audio, in: $0, videoCodec: codec))
        }
    }

    public static func defaultStillPictureTiming(for project: CutProject) -> StillPictureTiming {
        project.stillSoundtrack != nil || project.stillInserts.contains(where: \.usesExactDuration) ? .held : .cadence
    }

    /// A request without an explicit mode generates visible still picture with Smart Trim.
    public static func defaultStillMode(tracks: ExportTracks, placements: ExportPlacementScope,
                                        otherwise mode: ExportMode) -> ExportMode {
        tracks != .audio && placements != .none ? .smart : mode
    }

    static func stillMarkdown() -> [String] {
        var lines = ["", "## Visible still placements", "",
                     "These rows apply to both sequence and multicam projects. The planner verifies the source, joins, image generation and audio independently.", "",
                     "| Selection | Lossless Copy | Smart Trim | Re-encode |",
                     "| --- | --- | --- | --- |"]
        let selections: [(String, ExportTracks, ExportPlacementScope)] = [
            ("Picture and sound", .all, .replacement),
            ("Picture only", .video, .replacement),
            ("Sound only with an insert", .audio, .insertion),
        ]
        for (label, tracks, scope) in selections {
            let answers = [ExportMode.copy, .smart, .encode].map {
                let answer = cell(source: .multicam, tracks: tracks, mode: $0, placements: scope)
                return answer.isAllowed ? answer.displayName : "Refused (`\(answer.refusal?.factor.rawValue ?? "writer_other")`)"
            }
            lines.append("| \(label) | \(answers.joined(separator: " | ")) |")
        }
        lines += ["", "Omitting the mode with visible still picture selects Smart Trim. A picture replacement alone leaves the sound-only selection on the ordinary rules. Preserve camera picture requires zero encoded camera duration. Export reports distinguish copied camera, encoded camera and generated still durations. The True Lossless tier requires every selected output packet to copy.", ""]
        lines += ["### One frame per still", "",
                  "| Container | Video codec | Program color | Lossless audio |",
                  "| --- | --- | --- | --- |"]
        for container in stillMovieContainers {
            for codec in ReencodeCodec.allCases {
                let audio = stillLosslessAudioActions(codec: codec, container: container)
                guard !audio.isEmpty else { continue }
                let color = codec == .hevc || codec == .prores ? "SDR, PQ, HLG" : "SDR"
                let actions = audio.map { displayName(audio: $0) }.joined(separator: ", ")
                lines.append("| .\(container) | `\(codec.rawValue)` | \(color) | \(actions) |")
            }
        }
        lines += ["", "Smart Trim and Re-encode support held picture. A still-and-soundtrack project defaults to held timing. Choose cadence timing to export regular video frames instead. A saved picture format supplies the codec and container when a request omits them. An explicit container must agree with the destination extension.", "",
                  "MOV-family picture uses exact sample timing. MKV rounds internal changes to the nearest millisecond with ties forward, and rounds the final picture end up. Preflight reports the requested and written intervals and refuses a hold that collapses to zero ticks or shifts a copied camera boundary.", ""]
        return lines
    }
}

extension StillExportPlanner {
    /// Plans the complete program to determine its tier and report the actions responsible.
    public func tier(_ project: CutProject, relativeTo location: URL? = nil, preferredContainer: String? = nil) -> TierState {
        if cancelled?() == true { return .checking }
        var factors: [TierFactor] = []
        var last = CutError(code: "export_failed", message: "No still export mode is available.")
        let preferred = preferredContainer.flatMap {
            ExportRules.stillMovieContainers.contains($0) ? $0 : nil
        } ?? project.stillFormat?.container
        let compatible = project.stillFormat.map { StillTimelineFormat.containers(for: $0.codec) }
            ?? ExportRules.stillMovieContainers
        let containers = (preferred.map { [$0] } ?? []) + compatible.filter { $0 != preferred }
        let scope: ExportPlacementScope
        do { scope = try project.exportPlacementScope() }
        catch let issue as CutError { return .unavailable(issue) }
        catch { return .unavailable(CutError(code: "export_failed", message: error.localizedDescription)) }
        let source: ExportSourceKind
        if case .multicam = project { source = .multicam } else { source = .movie }
        for mode in [ExportMode.copy, .smart, .encode] {
            if let issue = ExportRules.cell(source: source, tracks: .all, mode: mode, placements: scope).refusal {
                factors.append(TierFactor(issue, forces: .lossless))
                continue
            }
            var modeFailure: CutError?
            for container in containers {
                for audio in [ReencodeAudio.copyOriginal, .alac, .flac, .pcm, .aac]
                where ExportRules.allows(stillAudio: audio, in: container, videoCodec: project.stillFormat?.codec) {
                    if cancelled?() == true { return .checking }
                    do {
                        let plan = try resolve(project, relativeTo: location, mode: mode, container: container,
                                               settings: .init(audio: audio), offerAlternatives: false)
                        let report = plan.report
                        let warnings = [
                            "Copied camera: \(report.copiedCameraDuration) s",
                            "Encoded camera: \(report.encodedCameraDuration) s",
                            "Generated stills: \(report.generatedStillDuration) s",
                        ] + report.soundActions.map {
                            "Audio track \($0.ordinal + 1) · \(ExportRules.displayName(audio: $0.audio))"
                                + ($0.generatedSilence.isEmpty ? "" : " with generated silence")
                        } + report.warnings
                        let sounds = report.selectedTier.factors.filter { $0.id == .placementSilence }
                        return .known(tier: report.fidelityTier, factors: factors + sounds, container: plan.container, warnings: warnings)
                    } catch let issue as CutError {
                        if issue.code == "cancelled" { return .checking }
                        if issue.code == "source_changed" { return .unavailable(issue) }
                        if modeFailure == nil { modeFailure = issue }
                    } catch {
                        if modeFailure == nil {
                            modeFailure = CutError(code: "export_failed", message: error.localizedDescription)
                        }
                    }
                }
            }
            if let issue = modeFailure {
                last = issue
                let factor = TierFactor(issue, forces: mode == .copy ? .lossless : .reencode)
                if !factors.contains(where: { $0.id == factor.id && $0.segment == factor.segment && $0.boundary == factor.boundary }) {
                    factors.append(factor)
                }
            }
        }
        return .unavailable(last)
    }
}

extension CutProject {
    public func exportPlacementScope() throws -> ExportPlacementScope {
        if stillInserts.isEmpty && stillReplacements.isEmpty { return .none }
        return try resolveStills().exportPlacementScope
    }
}

extension StillTimelinePlan {
    var exportPlacementScope: ExportPlacementScope {
        if spans.contains(where: { $0.origin == .insert }) { return .insertion }
        return spans.contains(where: { $0.placementID != nil }) ? .replacement : .none
    }
}

extension StillExportReport {
    /// Fidelity of this selected plan. A full-program tier may plan a different mode or container.
    public var fidelityTier: FidelityTier {
        if (mode == .encode && tracks != .audio) || soundActions.contains(where: { $0.audio == .aac }) ||
            (audioOutput != .separateTracks && !soundActions.isEmpty) {
            return .reencode
        }
        if generatedStillDuration > .zero || encodedCameraDuration > .zero ||
            soundActions.contains(where: { $0.audio != .copyOriginal }) { return .lossless }
        return .trueLossless
    }

    public var selectedTier: TierSummary {
        let tier = fidelityTier
        var factors: [TierFactor] = []
        if generatedStillDuration > .zero {
            factors.append(TierFactor(id: .placementPicture, forces: tier, message: TierFactorID.placementPicture.summary))
        }
        if soundActions.contains(where: { !$0.generatedSilence.isEmpty }) {
            factors.append(TierFactor(id: .placementSilence, forces: tier, message: TierFactorID.placementSilence.summary))
        }
        return TierSummary(id: tier.rawValue, name: ExportRules.displayName(tier: tier), mode: mode,
                           container: container, factors: factors, raise: [], warnings: warnings)
    }
}
