import AppKit
import MPCutCore

private struct AudioDeliveryTrack {
    let label: String
    let codec: String?
    let layout: String?
    let treatment: String
    let silence: [MulticamRange]

    var description: String {
        let format = [layout, codec].compactMap { $0 }.joined(separator: " · ")
        let gaps = silence.map { "\($0.from)–\($0.to) s" }.joined(separator: ", ")
        return ([label, format, treatment] + (gaps.isEmpty ? [] : ["silence \(gaps)"]))
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func treatment(for action: ReencodeAudio) -> String {
        action == .copyOriginal ? "stream copy" : action.displayName
    }

    static func summary(_ tracks: [Self]) -> String {
        guard !tracks.isEmpty else { return "No audio tracks" }
        var title = tracks.count == 1 ? "1 audio track" : "\(tracks.count) audio tracks"
        let layouts = tracks.compactMap(\.layout)
        if layouts.count == tracks.count { title += " · " + layouts.joined(separator: " + ") }
        if let treatment = tracks.first?.treatment, tracks.allSatisfy({ $0.treatment == treatment }) {
            title += " · " + treatment
        }
        return ([title] + tracks.map(\.description)).joined(separator: "\n")
    }
}

extension MulticamExportPlan {
    var audioDeliverySummary: String {
        if let participantRender {
            return AudioDeliveryTrack.summary(participantRender.audioActions.map { action in
                AudioDeliveryTrack(label: action.label ?? "Track \(action.ordinal + 1)", codec: action.codec,
                                   layout: action.channelLayout,
                                   treatment: action.treatment ?? AudioDeliveryTrack.treatment(for: action.audio),
                                   silence: action.generatedSilence)
            })
        }
        return AudioDeliveryTrack.summary(audioLanes.map { lane in
            AudioDeliveryTrack(label: lane.label, codec: lane.codec, layout: lane.channelLayout,
                               treatment: lane.retainedPCM ? "retained PCM samples + generated silence"
                                    : AudioDeliveryTrack.treatment(for: lane.action),
                               silence: lane.generatedSilence)
        })
    }
}

extension StillExportPlan {
    var audioDeliverySummary: String {
        AudioDeliveryTrack.summary(report.soundActions.map { action in
            AudioDeliveryTrack(label: action.label ?? "Track \(action.ordinal + 1)", codec: action.codec,
                               layout: action.channelLayout,
                               treatment: action.treatment ?? AudioDeliveryTrack.treatment(for: action.audio),
                               silence: action.generatedSilence)
        })
    }
}

private final class AudioDeliveryDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
func multicamDeliveryAccessory(_ summary: String, additionalControl: NSView? = nil) -> NSView {
    let label = NSTextField(wrappingLabelWithString: summary)
    label.preferredMaxLayoutWidth = 420
    label.isSelectable = true
    let scroll = NSScrollView()
    let document = AudioDeliveryDocumentView()
    document.addSubview(label)
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
        label.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
        label.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6)
    ])
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    document.frame.size = NSSize(width: 440, height: label.fittingSize.height + 12)
    scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: min(160, document.frame.height)).isActive = true
    let stack = NSStackView(views: [scroll] + (additionalControl.map { [$0] } ?? []))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    return stack
}
