import AppKit
import MPCutCore
import SwiftUI

/// The question asked before an edit made by hand lowers the timeline tier.
/// Tier and mode names come from ExportRules. This file holds the wording around them.
struct TierPrompt {
    struct Choice {
        enum Answer { case nearest, proceed, cancel }
        let answer: Answer
        var dontAskAgain = false
    }

    static let settingTitle = "Warn when an edit lowers export quality"

    /// The edit, as history names it.
    let action: String
    let from: FidelityTier
    let to: TierState
    /// What the edit adds that the timeline did not have.
    let factors: [TierFactor]
    /// The same edit with its cuts moved to verified times, which keeps the tier.
    let nearest: [ClipRequest]?
    let soundOnly: Bool

    var title: String {
        guard to.tier != nil else { return "“\(action)” would prevent export" }
        if nearest != nil { return "Keep the cut here?" }
        return "Change export quality from \(ExportRules.displayName(tier: from)) to \(to.name)?"
    }

    var message: String {
        if nearest != nil, !soundOnly, from == .trueLossless, to.tier == .lossless,
           !factors.isEmpty, factors.allSatisfy({ $0.id == .cutVideoStart || $0.id == .cutVideoEnd }) {
            return "At this cut, \(ExportRules.displayName(mode: .smart)) re-encodes the surrounding video. Cut at the nearest keyframe for a \(ExportRules.displayName(tier: from)) copy."
        }
        var lines: [String] = []
        if let first = factors.first { lines.append(ExportRules.displayMessage(first.message)) }
        if makesMixed {
            lines.append(ExportRules.mixedImportNote)
        } else if factors.contains(where: { $0.id == .placementPicture || $0.id == .placementSilence }),
                  case .known(_, _, _, let warnings) = to {
            lines.append(warnings.joined(separator: "\n"))
        } else if let tier = to.tier {
            lines.append(ExportRules.summary(tier: tier, source: soundOnly ? .audio : .movie))
        } else if lines.isEmpty, case .unavailable(let issue) = to {
            lines.append(ExportRules.displayMessage(issue.message))
        }
        if nearest != nil {
            let point = soundOnly ? "exact audio boundary" : "keyframe"
            lines.append("Move the cut to the nearest \(point) to keep \(ExportRules.displayName(tier: from)).")
        }
        return lines.joined(separator: "\n\n")
    }

    var nearestTitle: String { soundOnly ? "Cut at Nearest Exact Point" : "Cut at Nearest Keyframe" }
    /// True when the edit adds a clip in another format, which leaves only Re-encode for the whole project.
    var makesMixed: Bool { to.tier != nil && factors.contains { $0.id == .joinStreamMismatch } }
    var proceedTitle: String { makesMixed ? ExportRules.mixedImportProceedTitle : nearest == nil ? "Continue" : "Cut Here" }

    /// The buttons in order. The first is the default.
    var buttons: [(title: String, answer: Choice.Answer)] {
        (nearest == nil ? [] : [(nearestTitle, Choice.Answer.nearest)]) + [(proceedTitle, .proceed), ("Cancel", .cancel)]
    }

    /// Asks on the editor window. Without a visible window there is no one to ask, so the edit goes ahead.
    @MainActor
    static func present(_ prompt: TierPrompt, in window: NSWindow?, answer: @escaping (Choice) -> Void) {
        guard let window else { return answer(Choice(answer: .proceed)) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        for button in prompt.buttons {
            let control = alert.addButton(withTitle: button.title)
            switch button.answer {
            case .nearest: control.toolTip = "Use nearest compatible boundary"
            case .proceed: control.toolTip = "Apply requested edit"
            case .cancel: control.toolTip = "Cancel edit"
            }
        }
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.suppressionButton?.toolTip = "Disable export tier warnings"
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let chosen = prompt.buttons.indices.contains(index) ? prompt.buttons[index].answer : .cancel
            // Cancelling changes nothing, including the preference.
            answer(Choice(answer: chosen, dontAskAgain: chosen != .cancel && alert.suppressionButton?.state == .on))
        }
    }
}

extension EditorModel {
    /// The tier of the timeline as a remote client reads it, in the shape `mpcut inspect` reports. Nil for an empty timeline.
    /// `current` is false while a newer timeline is still being checked.
    var tierReport: [String: Any]? {
        guard let state = tierState else { return nil }
        var report: [String: Any] = ["name": state.name, "current": tierIsCurrent]
        switch state {
        case .checking: report["id"] = "checking"
        case .unavailable: report["id"] = "unavailable"
        case .known(let tier, _, let container, let warnings):
            report["id"] = tier.rawValue
            report["mode"] = ExportRules.bestMode(for: tier, source: isAudioOnly ? .audio : .movie).rawValue
            report["container"] = container
            report["warnings"] = warnings
        }
        report["factors"] = state.factors.map { factor -> [String: Any] in
            var entry: [String: Any] = ["id": factor.id.rawValue, "message": factor.message]
            if let forces = factor.forces { entry["forces"] = forces.rawValue }
            if let segment = factor.segment { entry["segment"] = segment }
            if let boundary = factor.boundary { entry["boundary"] = boundary }
            if let track = factor.track { entry["track"] = track }
            if let nearest = factor.nearest { entry["nearest"] = nearest.map(\.description) }
            return entry
        }
        return report
    }
}

/// The badge in the editor status bar: the tier of the current timeline, and what lowers it.
struct TimelineTierBadge: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let state = editor.tierState {
            TierBadge(state: state, help: Self.help(state, soundOnly: editor.isAudioOnly)) { dismiss in
                TimelineTierDetails(editor: editor, state: state, dismiss: dismiss)
            }
        }
    }

    static func symbol(_ state: TierState) -> String {
        switch state {
        case .checking: return "ellipsis.circle"
        case .known(let tier, _, _, _):
            switch tier {
            case .trueLossless: return "checkmark.seal.fill"
            case .lossless: return "checkmark.seal"
            case .reencode: return "arrow.triangle.2.circlepath"
            }
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ state: TierState) -> Color {
        switch state {
        case .checking: return .secondary
        case .known(let tier, _, _, _):
            switch tier {
            case .trueLossless: return .green
            case .lossless: return .blue
            case .reencode: return .orange
            }
        case .unavailable: return .red
        }
    }

    /// A recording without picture has its own tiers: no video is encoded at its cuts.
    static func help(_ state: TierState, soundOnly: Bool = false) -> String {
        switch state {
        case .checking: return "Checking export options…"
        case .known(let tier, let factors, _, _):
            let description = factors.contains(where: { $0.id == .placementPicture })
                ? TierFactorID.placementPicture.summary
                : ExportRules.summary(tier: tier, source: soundOnly ? .audio : .movie)
            return description + " Click for details."
        case .unavailable(let issue): return ExportRules.displayMessage(issue.message)
        }
    }
}

/// What lowers the tier, grouped by clip.
struct TimelineTierDetails: View {
    @ObservedObject var editor: EditorModel
    let state: TierState
    let dismiss: () -> Void

    private var summary: String {
        switch state {
        case .checking: return "Checking export options…"
        case .known(let tier, let factors, let container, _):
            let source: ExportSourceKind = editor.isAudioOnly ? .audio : .movie
            let description = factors.contains(where: { $0.id == .placementPicture })
                ? TierFactorID.placementPicture.summary : ExportRules.summary(tier: tier, source: source)
            let mode = ExportRules.bestMode(for: tier, source: source)
            let name = ExportRules.cell(source: source, tracks: .all, mode: mode).displayName
            return description + "\n\n\(name) · .\(container)"
        case .unavailable(let issue): return ExportRules.displayMessage(issue.message)
        }
    }

    /// Review Cuts lives in the export sheet under Lossless Copy. It applies when a cut has verified times to move to.
    private var offersReview: Bool {
        state.tier != nil && state.tier != .trueLossless && !editor.isAudioOnly && state.factors.contains { !($0.nearest ?? []).isEmpty }
    }

    var body: some View {
        let names = editor.timelineClips.map(\.name)
        TierDetails(state: state, summary: summary, title: { key in
            key == 0 ? "Timeline" : "Clip \(key)" + (names.indices.contains(key - 1) ? " · \(names[key - 1])" : "")
        }, segmentName: "clip", canGo: editor.canNavigate, go: { factor in
            editor.goToTierFactor(factor)
            dismiss()
        }) {
            if offersReview {
                Divider()
                HStack {
                    Text("Preview nearby cuts that let you copy the original frames.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Review Cuts…") {
                        dismiss()
                        editor.chooseExport(mode: .copy)
                    }
                    .disabled(!editor.canEdit)
                    .help("Review proposed cuts")
                }
            }
        }
    }
}
