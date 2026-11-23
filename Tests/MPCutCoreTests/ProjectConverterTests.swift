import Foundation
import XCTest
@testable import MPCutCore

final class ProjectConverterTests: XCTestCase {
    func testTranscriptInterchangeReportsLossAndNativeCopyOwnsItsStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("Interview.cut")
        let output = root.appendingPathComponent("Selects.cut")
        let timeline = CutProject.sequence([.init(id: "one", file: "recording.mov", from: .zero, to: .init(numerator: 1))])
        let data = Data("transcript asset".utf8)
        let asset = try TranscriptStore.put(data, relativeTo: input)
        var project = timeline
        project.transcripts = .init(attachments: [.init(id: "interview", asset: asset, bindings: [])])
        try project.save(to: input)

        XCTAssertThrowsError(try ProjectConverter.prepareForInterchange(project, for: "FCPXML", allowLoss: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "conversion_loss")
            XCTAssertTrue(($0 as? CutError)?.message.contains("transcript") == true)
        }
        let prepared = try ProjectConverter.prepareForInterchange(project, for: "FCPXML", allowLoss: true)
        XCTAssertEqual(prepared.project, timeline)
        XCTAssertEqual(prepared.warnings.count, 1)

        XCTAssertEqual(try ProjectConverter.convert(input: input, output: output), [])
        let copied = try XCTUnwrap(CutProject.load(from: output).transcripts.attachments.first)
        XCTAssertNotEqual(copied.asset.file, asset.file)
        try FileManager.default.removeItem(at: TranscriptStore.folder(relativeTo: input))
        XCTAssertEqual(try TranscriptStore.read(copied.asset, relativeTo: output), data)
    }

    func testNamedSourceSelectOmissionRequiresLossApproval() throws {
        let end = RationalTime(numerator: 1)
        let clip = CutSequenceClip(id: "one", file: "camera.mov", from: .zero, to: end)
        let select = try NamedSourceSelect(id: "take", name: "Take", range: .init(file: "other.mov", from: .zero, to: end))
        let project = CutProject.stillSequence(.init(items: [.source(clip)], sourceSelects: [select]))
        XCTAssertThrowsError(try ProjectConverter.prepareForInterchange(project, for: "FCPXML", allowLoss: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "conversion_loss")
        }
        let prepared = try ProjectConverter.prepareForInterchange(project, for: "FCPXML", allowLoss: true)
        XCTAssertEqual(prepared.project, .sequence([clip]))
        XCTAssertTrue(prepared.warnings.contains { $0.contains("named source selects") })
    }

    func testUnsupportedStillInterchangePreflightsEveryPlacementBeforeOpeningHost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let time = RationalTime(numerator: 1)
        let range = MulticamRange(from: .zero, to: time)
        let clip = CutSequenceClip(id: "recording", file: "offline.mov", from: .zero, to: time)
        let asset = StillAsset(id: "photo", file: "card.png", displayName: "Card", fingerprint: "offline")
        let insert = StillInsert(id: "insert-id", assetID: asset.id, duration: time, cadence: .init(numerator: 1, denominator: 24))
        let overlay = StillReplacement(id: "replace-id", assetID: asset.id,
                                       coverage: .sequence([.init(clipID: clip.id, range: range)]))
        let project = CutProject.stillSequence(.init(items: [.source(clip), .still(insert)],
                                                     stillAssets: [asset], stillReplacements: [overlay]))
        for ext in ["prproj", "drp", "drt"] {
            let output = folder.appendingPathComponent("Edit." + ext)
            XCTAssertThrowsError(try ProjectConverter.write(project, relativeTo: output, to: output)) {
                let error = $0 as? CutError
                XCTAssertEqual(error?.code, "conversion_loss")
                XCTAssertTrue(error?.message.contains("Insert Still placement insert-id") == true)
                XCTAssertTrue(error?.message.contains("Replace Picture placement replace-id") == true)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let approved = try ProjectConverter.prepareForInterchange(project, for: "Adobe Premiere Pro", allowLoss: true)
        XCTAssertEqual(approved.project, .sequence([clip]))
        XCTAssertEqual(approved.warnings.count, 2)
    }

    func testAnUnusedGeneratedGapDoesNotRequireLossApproval() throws {
        let clip = CutSequenceClip(id: "camera", file: "camera.mov", from: .zero, to: .init(numerator: 1))
        let gap = StillAsset(gapID: "old-gap")
        let timeline = CutProject.sequence([clip])
        let closed = try timeline.addingStillAsset(gap)
        let result = try ProjectConverter.prepareForInterchange(closed, for: "FCPXML", allowLoss: false)
        XCTAssertEqual(result.project, timeline)
        XCTAssertEqual(result.warnings, [])

        let visible = try closed.insertingStill(.init(id: "pause", assetID: gap.id, duration: .init(numerator: 1),
                                                       cadence: .init(numerator: 1, denominator: 24)), at: .zero)
        XCTAssertThrowsError(try ProjectConverter.prepareForInterchange(visible, for: "FCPXML", allowLoss: false)) {
            XCTAssertEqual(($0 as? CutError)?.code, "conversion_loss")
            XCTAssertTrue(($0 as? CutError)?.message.contains("pause") == true)
        }
    }

    func testApprovedMulticamStillOmissionPreservesEveryRetainedRange() throws {
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        let asset = StillAsset(id: "asset", file: "card.png", displayName: "Card", fingerprint: "offline")
        let insert = StillInsert(id: "title", assetID: asset.id, duration: .init(numerator: 1),
                                 cadence: .init(numerator: 1, denominator: 24))
        let group = MulticamProject(referenceAngle: "a", range: range, angles: [.init(id: "a", file: "camera.mov")],
                                    audio: .none, switches: [.init(at: .zero, angle: "a")],
                                    assemblyItems: [.group(range), .still(insert), .group(range)], stillAssets: [asset])
        XCTAssertThrowsError(try ResolveExport.validateTimelineHandoff(.multicam(group))) {
            XCTAssertTrue(($0 as? CutError)?.message.contains("Insert Still placement title") == true)
        }
        let approved = try ProjectConverter.prepareForInterchange(.multicam(group), for: "DaVinci Resolve", allowLoss: true)
        guard case .multicam(let result) = approved.project else { return XCTFail("Expected multicam") }
        XCTAssertEqual(result.assembly, [range, range])
        XCTAssertEqual(approved.warnings.count, 1)
    }

    func testInterchangeReportsUnsupportedMixAndInactiveLaneState() throws {
        let range = MulticamRange(from: .zero, to: .init(numerator: 1))
        var group = MulticamProject(referenceAngle: "a", range: range,
                                    angles: [.init(id: "a", file: "a.mov", audioStream: 1)],
                                    audio: .mix, switches: [.init(at: .zero, angle: "a")])
        group.mixLanes = group.defaultMixLanes
        for allowLoss in [false, true] {
            XCTAssertThrowsError(try ProjectConverter.prepareForInterchange(.multicam(group), for: "FCPXML",
                                                                             allowLoss: allowLoss)) {
                XCTAssertEqual(($0 as? CutError)?.code, "unsupported_multicam_audio")
            }
        }
        group.audio = .follow
        let inactive = try ProjectConverter.prepareForInterchange(.multicam(group), for: "FCPXML", allowLoss: true)
        guard case .multicam(let converted) = inactive.project else { return XCTFail("Expected multicam project") }
        XCTAssertEqual(converted.audio, .follow)
        XCTAssertTrue(converted.mixLanes.isEmpty)
        XCTAssertEqual(inactive.warnings.count, 1)
        group.audioReplacements = [.init(id: "replacement", original: .init(source: "a", stream: 1),
                                         replacement: .init(source: "recorder", stream: 0),
                                         relativeOffset: .zero, uncovered: .keepOriginal)]
        XCTAssertThrowsError(try ResolveExport.validateTimelineHandoff(.multicam(group))) {
            XCTAssertEqual(($0 as? CutError)?.code, "unsupported_multicam_audio")
        }
    }

    func testCopyRebasesRepeatedMediaAndKeepsOccurrenceOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([42]).write(to: folder.appendingPathComponent("interview.mov"))
        let input = folder.appendingPathComponent("Edit.cut")
        let output = other.appendingPathComponent("Copy.cut")
        let end = try RationalTime(parsing: "1001/24000")
        let project = CutProject.sequence(["second", "first"].map {
            CutSequenceClip(id: $0, file: "interview.mov", from: .zero, to: end)
        })
        try project.save(to: input)
        XCTAssertEqual(try ProjectConverter.convert(input: input, output: output), [])
        let copy = try CutProject.load(from: output)
        guard case .sequence(let clips) = copy else { return XCTFail("Expected sequence") }
        XCTAssertEqual(clips.map(\.id), ["second", "first"])
        XCTAssertEqual(clips.map(\.to), [end, end])
        XCTAssertEqual(try copy.requests(relativeTo: output).map { $0.file.resolvingSymlinksInPath().standardizedFileURL },
                       try project.requests(relativeTo: input).map { $0.file.resolvingSymlinksInPath().standardizedFileURL })
        let saved = try Data(contentsOf: output)
        XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: output))
        XCTAssertEqual(try Data(contentsOf: output), saved)
    }

    func testCutCopyPreservesRedoOnlyRecordingAndProtectsItsMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("Edit.cut")
        let output = sibling.appendingPathComponent("Copy.cut")
        let missing = directory.appendingPathComponent("offline.cut")
        let future = CutProject.sequence([.init(id: "clip", file: "offline.cut", from: .zero, to: .init(numerator: 1))])
        try CutProject.sequence([]).save(to: input, undo: [], redo: [.init(action: "Add Clip", project: future)])
        XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        _ = try ProjectConverter.convert(input: input, output: output)
        let copy = try CutProject.loadDocument(from: output, limit: 5)
        XCTAssertEqual(copy.project, .sequence([]))
        XCTAssertEqual(copy.redo.map(\.action), ["Add Clip"])
        guard case .sequence(let clips)? = copy.redo.first?.project else { return XCTFail("Expected a sequence") }
        XCTAssertEqual(clips.first?.file, "../offline.cut")
    }

    func testCutCopyRebasesMultifileAnglesWithoutChangingReplaysOrAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("Edit.cut")
        let output = sibling.appendingPathComponent("Copy.cut")
        let one = RationalTime(numerator: 1), two = RationalTime(numerator: 2), three = RationalTime(numerator: 3)
        let range = MulticamRange(from: .zero, to: three)
        let wide = MulticamSource(id: "wide", file: "wide.mov", coverage: .init(from: .zero, to: one),
                                 additionalRecordings: [.init(id: "later", file: "part2.mov", offset: two,
                                                             coverage: .init(from: two, to: three))])
        let group = MulticamProject(referenceAngle: "wide", range: range,
                                    angles: [wide, .init(id: "close", file: "close.mov")],
                                    audioSources: [.init(id: "sound", file: "sound.wav")],
                                    audio: .fixed(.init(source: "sound", stream: 1)),
                                    switches: [.init(at: .zero, angle: "wide")],
                                    assemblyItems: [.group(range), .group(range, angle: "close")])
        var earlier = group
        earlier.assemblyItems = [.group(range)]
        try CutProject.multicam(group).save(to: input, undo: [.init(action: "Replay", project: .multicam(earlier))], redo: [])
        XCTAssertEqual(try ProjectConverter.convert(input: input, output: output), [])
        let result = try CutProject.loadDocument(from: output, limit: 5)
        guard case .multicam(let copy) = result.project,
              case .multicam(let prior)? = result.undo.first?.project else {
            return XCTFail("Expected the current and earlier multicam edits")
        }
        XCTAssertEqual(copy.angles[0].recordings.map(\.file), ["../wide.mov", "../part2.mov"])
        XCTAssertEqual(prior.angles[0].recordings.map(\.file), copy.angles[0].recordings.map(\.file))
        XCTAssertEqual(copy.audioSources.map(\.file), ["../sound.wav"])
        XCTAssertEqual(try copy.plan(), try group.plan())
        XCTAssertEqual(try prior.plan(), try earlier.plan())
    }

    func testExternalConversionProtectsOfflineRecordingAndPackageContentsFromHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("Edit.cut")
        let output = directory.appendingPathComponent("Restorable.fcpxml")
        let package = directory.appendingPathComponent("Restorable.fcpxmld")
        let state = CutProject.sequence([.init(id: "original", file: "Restorable.fcpxml",
                                               from: .zero, to: .init(numerator: 1),
                                               originalFile: "Restorable.fcpxmld/Info.fcpxml")])
        try CutProject.sequence([]).save(to: input, undo: [.init(action: "Remove Recording", project: state)], redo: [])
        for destination in [output, package] {
            XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: destination)) {
                XCTAssertEqual(($0 as? CutError)?.code, "cut_project_source_collision")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testInvalidDestinationFailsBeforeOpeningHostProject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = directory.appendingPathComponent("Input.drp")
        let output = directory.appendingPathComponent("Output.cut")
        XCTAssertThrowsError(try ProjectConverter.convert(input: input, output: output, allowLoss: true)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_destination")
        }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/Output.cut"))
        XCTAssertThrowsError(try ProjectConverter.write(.sequence([]), relativeTo: input, to: remote)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_project_path")
        }
    }

    func testConcurrentExportsPublishExactlyOneCompleteProject() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Shared.cut")
        let projects = (1...6).map { index in
            CutProject.sequence([CutSequenceClip(id: String(index), file: "Camera.mov",
                                                 from: .zero, to: .init(numerator: 1))])
        }
        let winners = await withTaskGroup(of: CutProject?.self) { group in
            for project in projects {
                group.addTask {
                    do {
                        _ = try ProjectConverter.write(project, relativeTo: output, to: output)
                        return project
                    } catch { return nil }
                }
            }
            var winners = [CutProject]()
            for await project in group { if let project { winners.append(project) } }
            return winners
        }
        XCTAssertEqual(winners, [try CutProject.load(from: output)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Shared.cut"])
    }

    func testCannotWriteIntoSourceLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fcpbundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("Imported.cut")
        XCTAssertThrowsError(try ProjectConverter.convert(input: directory, output: output)) {
            XCTAssertEqual(($0 as? CutError)?.code, "invalid_destination")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDanglingOutputSymlinkSurvivesFailedConversion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("Output.cut")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        XCTAssertThrowsError(try ProjectConverter.convert(input: directory.appendingPathComponent("Missing.cut"), output: link)) {
            XCTAssertEqual(($0 as? CutError)?.code, "destination_exists")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing")
    }
}
