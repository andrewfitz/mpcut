import AppKit
import MPCutCore
import SwiftUI
import XCTest
@testable import MPCutApp

/// A seamless split and the tier question, times in the texts people read, the editor transport and the alternatives
/// button at their narrowest, and audio-track choices on timelines whose clips have different audio tracks.
final class ExportFindingsAppTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    @MainActor
    private func settle(_ model: EditorModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isBusy || !model.tierIsCurrent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }

    // MARK: Seamless split

    @MainActor
    func testASeamlessSplitInsideAPictureGroupKeepsTrueLosslessAndDoesNotAsk() async throws {
        let model = EditorModel()
        defer { model.endSession() }
        var prompts: [TierPrompt] = []
        model.tierPrompt = { prompt, answer in
            prompts.append(prompt)
            answer(.init(answer: .proceed))
        }
        model.importFiles([try fixture("SmartTrim-GOP", "mp4")])
        try await settle(model)
        XCTAssertEqual(model.tierState?.tier, .trueLossless)

        // Nothing is removed, so the two pieces are still the whole clip: no video is encoded and nothing is asked.
        model.seek(7.0 / 25)
        model.split()
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        XCTAssertEqual(model.timelineClips.map(\.sourceStart), [0, 7.0 / 25])
        XCTAssertEqual(model.tierState?.tier, .trueLossless)
        XCTAssertEqual(model.tierState?.factors.map(\.id), [])
        XCTAssertTrue(prompts.isEmpty, "A seam that removes nothing does not lower the tier.")
        let clips = try CutProject.sequence(model.sequenceClips).requests(relativeTo: fixture("SmartTrim-GOP", "mp4"))
        guard case .ready(let plan, _, _) = ExportPlanner(useSidecar: false).resolve(ExportRequest(clips: clips, mode: .copy)) else {
            return XCTFail("Lossless Copy refuses a split that removes nothing.")
        }
        XCTAssertEqual(plan.edit.segments.count, 1)

        // Removing a piece makes the seam a cut inside the picture group. That lowers the tier, and is asked about.
        let left = try XCTUnwrap(model.timelineClips.first?.id)
        model.byHand { model.deleteClip(left) }
        try await settle(model)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.from, .trueLossless)
        XCTAssertEqual(prompts.first?.to.tier, .lossless)
        XCTAssertEqual(model.tierState?.tier, .lossless)
        XCTAssertEqual(model.tierState?.factors.map(\.id), [.cutVideoStart])
    }

    // MARK: Times in messages

    func testThePromptAndTheBadgeShowTimesInSeconds() {
        let raw = "The picture and audio track 1 do not share a verified end boundary at 201/2."
        let factor = TierFactor(id: .cutAudioPacket, forces: .reencode, segment: 1, boundary: "to", message: raw)
        let state = TierState.known(tier: .reencode, factors: [factor], container: "mp4", warnings: [])
        let prompt = TierPrompt(action: "Trim Clip", from: .trueLossless, to: state, factors: [factor], nearest: nil, soundOnly: false)
        XCTAssertTrue(prompt.message.hasPrefix("The picture and audio track 1 do not share a verified end boundary at 100.500 s."), prompt.message)
        XCTAssertFalse(prompt.message.contains("201/2"))
        XCTAssertEqual(factor.message, raw, "The factor keeps the exact time for programs.")

        let issue = CutError(code: "unsafe_boundary", message: "Source a picture, group 0–13/25, source 0–13/25, output 0–13/25: There is no verified video end boundary at 13/25.")
        let shown = "Source a picture, group 0.000–0.520 s, source 0.000–0.520 s, output 0.000–0.520 s: There is no verified video end boundary at 0.520 s."
        XCTAssertEqual(TimelineTierBadge.help(.unavailable(issue)), shown)
        XCTAssertEqual(MulticamTierBadge.help(.unavailable(issue)), shown)
        XCTAssertEqual(MulticamTierBadge.summary(.unavailable(issue)), shown)
    }

    // MARK: Layout

    @MainActor
    func testTheEditorTransportFitsTheMinimumWindowWidthWithoutClippingSplit() throws {
        _ = NSApplication.shared
        let model = EditorModel()
        defer { model.endSession() }
        let step = EditorStepAction(enabled: true) { _ in }
        func action(_ title: String) -> EditorEditAction { .init(title: title, perform: {}) }
        let bar = EditorTransportBar(
            navigation: .picture(scenes: step, keyframes: step), frames: step, canNavigate: true, canEdit: true,
            marks: .init(hasIn: false, hasOut: false, setIn: {}, setOut: {}, clear: {}),
            addRange: action("Add Marked Range to Export Queue"), split: action("Split at Playhead"), delete: action("Delete Clip"),
            undo: action("Undo"), redo: action("Redo"),
            rangeTools: .init(active: .constant(false), canAct: false, canSplit: false, canDelete: false, split: {}, export: {}, delete: {}),
            preview: model.preview
        ) { EmptyView() }
        // 730 points is the minimum width of the editor window (ProjectSessions).
        let minimum: CGFloat = 730
        let hosting = NSHostingView(rootView: bar)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: minimum, height: 43), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        for width in [minimum, 1_200] {
            window.setContentSize(NSSize(width: width, height: 43))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(hosting.fittingSize.height, 43, accuracy: 0.5)
            // A bar that needs more than the window clips its only flexible label, "Split".
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, minimum, "The transport needs more than the minimum window width.")
        }
        // The width at which every label is shown whole, whatever each control would give up first. A bar whose ideal
        // width is more than the window truncates a label, which is how "Split" came to be cut short.
        let ideal = NSHostingView(rootView: bar.fixedSize()).fittingSize.width
        print("Editor transport ideal width: \(ideal) of \(minimum)")
        XCTAssertGreaterThan(ideal, 500)
        XCTAssertLessThanOrEqual(ideal, minimum, "The transport cannot show every label at the minimum window width.")
    }

    @MainActor
    func testTheFirstAlternativeHasALabelThatFitsTheNarrowestInspector() {
        _ = NSApplication.shared
        let smart = ExportRung.smartTrim.label(container: "mp4", audio: nil, lossless: false, source: .multicam)
        XCTAssertEqual(smart, "Use Smart Trim (encodes only the cut edges)")
        XCTAssertEqual(ExportOffersView.compactLabel(smart), "Use Smart Trim")
        XCTAssertEqual(ExportOffersView.compactLabel(smart + " in MOV"), "Use Smart Trim in MOV")
        XCTAssertEqual(ExportOffersView.compactLabel("Re-encode with PCM sound (no further quality loss)"), "Re-encode with PCM sound")
        XCTAssertEqual(ExportOffersView.compactLabel("Choose Re-encode"), "Choose Re-encode")

        // The multicam inspector is 310 points at its narrowest, with 12 points of padding on each side.
        let available: CGFloat = 310 - 24
        func width(_ title: String) -> CGFloat { NSHostingView(rootView: Button(title) {}).fittingSize.width }
        for rung in ExportRung.allCases {
            for container in ["mov", "mp4", "mkv"] {
                let label = rung.label(container: container, audio: .pcm, lossless: true, source: .multicam)
                let other = rung == .smartTrim ? label + " in \(ExportRules.containerDisplayName(container))" : label
                XCTAssertLessThanOrEqual(width(ExportOffersView.compactLabel(other)), available, other)
            }
        }
        XCTAssertGreaterThan(width(smart), available, "The whole label fits now. The compact label is no longer needed.")
    }

    // MARK: Audio tracks on a mixed timeline

    @MainActor
    func testTheExportSheetListsTheAudioTracksEveryClipHasAndSaysSo() throws {
        _ = NSApplication.shared
        let two = try fixture("Pause-Quiet", "mov"), one = try fixture("Shuttle-Chirp", "mov")
        let engine = CutEngine(useSidecar: false)
        let media = [two: try engine.inspect(two, keyframes: true), one: try engine.inspect(one, keyframes: true)]
        XCTAssertEqual([media[two]!.audio.count, media[one]!.audio.count], [2, 1])
        let mixed: [ClipRequest] = [.init(file: two), .init(file: one)]
        XCTAssertEqual(ExportFormatControl.commonAudioStreams(clips: mixed, media: media).map(\.index), [media[two]!.audio[0].stream.index],
                       "Only the first clip has a second audio track, so it cannot be chosen for the timeline.")
        XCTAssertEqual(ExportFormatControl.audioTrackRemark(clips: mixed, media: media),
                       "The clips have different numbers of audio tracks, so one track cannot be chosen for all of them.")
        // One clip, or clips with the same tracks, need no remark and list every track.
        let same: [ClipRequest] = [.init(file: two), .init(file: two)]
        XCTAssertEqual(ExportFormatControl.commonAudioStreams(clips: same, media: media).count, 2)
        XCTAssertNil(ExportFormatControl.audioTrackRemark(clips: same, media: media))

        var options = ExportSheetOptions()
        options.tracks = .audio
        func control(_ clips: [ClipRequest]) -> ExportFormatControl {
            ExportFormatControl(panel: NSSavePanel(), options: options,
                                copyContainers: ExportContainerChoices(source: media[two]!, clips: clips, preferred: "mov", cancelled: { false }),
                                clips: clips, media: media, changed: { _, _ in }, directoryChanged: { _ in })
        }
        let narrowed = control(mixed)
        defer { narrowed.stopChecking() }
        XCTAssertEqual(narrowed.audioTrackTitles.count, 2, "All audio tracks, and the one track every clip has.")
        XCTAssertEqual(narrowed.shownAudioTrackNote, ExportFormatControl.audioTrackRemark(clips: mixed, media: media))
        let plain = control(same)
        defer { plain.stopChecking() }
        XCTAssertEqual(plain.audioTrackTitles.count, 3)
        XCTAssertNil(plain.shownAudioTrackNote)
    }

    @MainActor
    func testChoosingATrackSomeClipsLackSaysWhichTrackTheyUse() async throws {
        let model = EditorModel()
        defer { model.endSession() }
        model.tierPrompt = { _, answer in answer(.init(answer: .proceed)) }
        // Two audio tracks, then a clip with one.
        model.importFiles([try fixture("Pause-Quiet", "mov"), try fixture("Shuttle-Chirp", "mov")])
        try await settle(model)
        XCTAssertEqual(model.timelineClips.count, 2)
        model.seek(0.5)
        XCTAssertEqual(model.playheadAudioTracks.count, 2)
        XCTAssertNil(model.audioTrackFallbackNote, "Following the source audio falls back nowhere.")

        model.chooseAnalysisTrack(1)
        XCTAssertEqual(model.audioMonitoringTrack, 1)
        XCTAssertEqual(model.audioTrackFallbackNote, "Shuttle-Chirp.mov has no track 2 and uses its first track.")
        model.chooseAnalysisTrack(0)
        XCTAssertNil(model.audioTrackFallbackNote, "Every clip has a first track.")
        model.chooseAnalysisTrack(1)
        model.monitorSourceAudio()
        XCTAssertNil(model.audioTrackFallbackNote)
    }
}
