import AppKit
import Combine
import Darwin
import MPCutCore
import XCTest
@testable import MPCutApp

final class MulticamPerformanceTests: XCTestCase {
    @MainActor
    func testPreviewPerformance() async throws {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_MULTICAM_BENCHMARK_PROJECT"] else {
            throw XCTSkip("Set MPCUT_MULTICAM_BENCHMARK_PROJECT to run the preview benchmark")
        }
        let location = URL(fileURLWithPath: path)
        let project = try MulticamProject.load(from: location)
        let inspection = try MulticamEngine().inspect(project, relativeTo: location)
        let media: [String: MediaInfo] = Dictionary(uniqueKeysWithValues:
            inspection.sources.map { ($0.source.id, $0.media) }
        )
        let plan = inspection.mapping
        let preview = MulticamPreview()
        let surface = PreviewSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        preview.attach(surface)
        preview.configure(plan: plan, media: media)
        defer { preview.pause() }

        let clock = ContinuousClock()
        let frameStep = RationalTime(numerator: 1, denominator: 25)
        let fourFrames = RationalTime(numerator: 4, denominator: 25)
        try await wait { preview.picture != nil }

        // Move off the keyframe so each request includes frame selection and decode.
        var seekTimes: [Double] = []
        for (index, span) in plan.picture.enumerated() {
            let target = try span.output.from.adding(fourFrames)
            let local = try span.input.from.adding(fourFrames)
            let start = clock.now
            preview.seek(to: target)
            try await wait { preview.picture?.spanIndex == index && preview.picture?.frameTime == local }
            seekTimes.append(milliseconds(start.duration(to: clock.now)))
        }

        // Measure the alternate-angle preview path while paused.
        var auditionTimes: [Double] = []
        for angle in project.angles {
            let source = try XCTUnwrap(media[angle.id])
            let target = try project.switches[9].at.adding(fourFrames)
            let start = clock.now
            preview.audition(url: source.url, sourceTime: target, media: source)
            try await wait {
                preview.picture?.spanIndex == -1 && preview.picture?.url == source.url
                    && preview.picture?.frameTime == target
            }
            auditionTimes.append(milliseconds(start.duration(to: clock.now)))
        }
        preview.endAudition()

        // Run through each saved picture join using the production output clock.
        var switchTimes: [Double] = []
        for index in plan.picture.indices.dropFirst() {
            let cut = plan.picture[index].output.from
            preview.seek(to: try cut.subtracting(fourFrames))
            try await wait { preview.picture?.spanIndex == index - 1 }
            preview.togglePlayback()
            try await wait { preview.picture?.spanIndex == index }
            switchTimes.append(try preview.currentTime().subtracting(cut).seconds * 1000)
            preview.pause()
        }

        // Count skipped picture submissions during a quiet contiguous run.
        let spanSeconds = plan.picture.map { $0.output.to.seconds - $0.output.from.seconds }
        let longest = try XCTUnwrap(spanSeconds.max())
        let stableIndex = try XCTUnwrap(spanSeconds.firstIndex(of: longest))
        let stable = plan.picture[stableIndex]
        let stableSeconds = min(3, Int(longest) - 1)
        let expectedFrames = stableSeconds * 25
        let start = try stable.output.from.adding(frameStep)
        let localStart = try stable.input.from.adding(frameStep)
        let end = try start.adding(RationalTime(numerator: Int64(stableSeconds)))
        var seen = Set<RationalTime>()
        let listener = preview.$picture.sink { picture in
            if let picture, picture.spanIndex == stableIndex { seen.insert(picture.frameTime) }
        }
        preview.seek(to: start)
        try await wait { preview.picture?.spanIndex == stableIndex && preview.picture?.frameTime == localStart }
        preview.togglePlayback()
        try await wait { preview.currentTime() >= end }
        preview.pause()
        listener.cancel()
        let localEnd = try localStart.adding(end.subtracting(start))
        let submitted = seen.filter { localStart <= $0 && $0 < localEnd }.count
        XCTAssertNil(preview.issue)
        // Exercise the filmstrip thumbnail path over the same visible window in four rows.
        let thumbnails = MulticamThumbnailService()
        let thumbnailSize = CGSize(width: 80, height: 45)
        let tileTimes = (0..<5).map { Double($0) + 0.16 }
        var thumbnailTimes: [Double] = []
        for _ in 0..<2 {
            let start = clock.now
            for angle in project.angles {
                let source = try XCTUnwrap(media[angle.id])
                for time in tileTimes {
                    let key = try XCTUnwrap(FilmstripTileKey(time: time, size: thumbnailSize))
                    let image = await thumbnails.image(media: source, key: key, reuseSidecar: false)
                    XCTAssertNotNil(image)
                }
            }
            thumbnailTimes.append(milliseconds(start.duration(to: clock.now)))
        }

        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        let report: [String: Any] = [
            "pausedSeek": summary(seekTimes),
            "pausedAngleAudition": summary(auditionTimes),
            "scheduledSwitchOutputClockLag": summary(switchTimes),
            "firstTwentyThumbnailRequestsMs": thumbnailTimes[0],
            "cachedTwentyThumbnailRequestsMs": thumbnailTimes[1],
            "steadyFramesExpected": expectedFrames,
            "steadyFramesSubmitted": submitted,
            "steadyFramesSkipped": expectedFrames - submitted,
            "peakTestProcessRssBytes": usage.ru_maxrss,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("MPCUT_MULTICAM_BENCHMARK \(String(decoding: data, as: UTF8.self))")
        withExtendedLifetime(surface) {}
    }

    @MainActor
    func testProjectSessionStartupPerformance() async throws {
        guard let countValue = ProcessInfo.processInfo.environment["MPCUT_PROJECT_STARTUP_SESSIONS"],
              let count = Int(countValue), (1...32).contains(count) else {
            throw XCTSkip("Set MPCUT_PROJECT_STARTUP_SESSIONS to 1–32 to run the session startup benchmark")
        }
        let source: URL
        if let path = ProcessInfo.processInfo.environment["MPCUT_PROJECT_STARTUP_SOURCE"] {
            source = URL(fileURLWithPath: path)
        } else {
            source = try XCTUnwrap(Bundle.module.url(forResource: "ProRes-2997", withExtension: "mov",
                                                      subdirectory: "Fixtures"))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = MulticamProject(referenceAngle: "wide",
                                      range: .init(from: .zero, to: .init(numerator: 1)),
                                      angles: [.init(id: "wide", file: source.path)], audio: .none,
                                      switches: [.init(at: .zero, angle: "wide")])
        let urls = try (0..<count).map { index in
            let url = directory.appendingPathComponent("edit-\(index).cut")
            try project.save(to: url)
            return url
        }
        let preferences = EditorPreferences()
        preferences.useAnalysisSidecars = false
        let clock = ContinuousClock()
        let start = clock.now
        let regular = urls.map { _ in ProjectSession(id: UUID(), preferences: preferences) }
        let multicam = urls.map { _ in ProjectSession(id: UUID(), preferences: preferences) }
        let construction = milliseconds(start.duration(to: clock.now))
        defer { for session in regular + multicam { session.end() } }

        var regularReady: [Double] = []
        var multicamReady: [Double] = []
        var multicamPictures: [Double] = []
        var subscriptions: [AnyCancellable] = []
        let opening = clock.now
        for session in regular {
            subscriptions.append(session.editor.$isImporting.dropFirst().filter { !$0 }.prefix(1).sink { _ in
                regularReady.append(self.milliseconds(opening.duration(to: clock.now)))
            })
            session.editor.openFiles([source])
        }
        for (session, url) in zip(multicam, urls) {
            session.isMulticam = true
            subscriptions.append(session.multicam.$media.filter { $0["wide"]?.hasFullEditIndex == true }.prefix(1).sink { _ in
                multicamReady.append(self.milliseconds(opening.duration(to: clock.now)))
            })
            subscriptions.append(session.multicam.preview.$picture.compactMap { $0 }.prefix(1).sink { _ in
                multicamPictures.append(self.milliseconds(opening.duration(to: clock.now)))
            })
            session.multicam.openProject(url)
        }
        try await wait {
            regularReady.count == count && multicamReady.count == count && multicamPictures.count == count
        }
        let sampled = try XCTUnwrap(regular.first?.editor)
        let latest = try XCTUnwrap(multicam.last?.multicam)
        XCTAssertTrue(sampled.canEdit)
        XCTAssertNil(latest.preview.issue)

        func usage() -> rusage {
            var value = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &value), 0)
            return value
        }
        func cpuTime(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        try await Task.sleep(for: .seconds(1)) // Let pending preview and analysis completions settle.
        let idleStart = usage()
        try await Task.sleep(for: .seconds(1))
        let idleEnd = usage()
        let report: [String: Any] = [
            "sessionCount": count * 2,
            "sessionConstructionMs": construction,
            "regularEditReady": summary(regularReady),
            "multicamFirstPicture": summary(multicamPictures),
            "multicamEditReady": summary(multicamReady),
            "idleProcessCpuMsOverOneSecond": (cpuTime(idleEnd) - cpuTime(idleStart)) * 1000,
            "peakTestProcessRssBytes": idleEnd.ru_maxrss,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("MPCUT_PROJECT_STARTUP_BENCHMARK \(String(decoding: data, as: UTF8.self))")
        withExtendedLifetime(subscriptions) {}
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        if !condition() {
            throw NSError(domain: "MulticamPerformance", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The preview did not produce a timed frame before the deadline"
            ])
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func summary(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return ["count": Double(sorted.count), "medianMs": median, "maxMs": sorted.last ?? 0]
    }
}
