import Darwin
import Foundation
import MPCutCore
import XCTest
@testable import MPCutApp

final class StorageInventoryTests: XCTestCase {
    private var root: URL!
    private var locations: StorageLocations!
    private var suite: String!
    private var defaults: UserDefaults!
    private let files = FileManager.default

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("mpcut-inventory-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        locations = StorageLocations(generatedStills: root.appendingPathComponent("Stills"),
                                     transcriptRecognition: root.appendingPathComponent("Claims"),
                                     transcriptJobs: [root.appendingPathComponent("Drafts/.transcript-jobs"),
                                                      root.appendingPathComponent("TranscriptJobs")],
                                     untitledDrafts: root.appendingPathComponent("Drafts"),
                                     agentReceipts: root.appendingPathComponent("Receipts"))
        suite = "com.mpcut.tests.storage-inventory." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? files.removeItem(at: root)
    }

    private func write(_ path: String, bytes: Int = 8_192) throws -> URL {
        let url = root.appendingPathComponent(path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: url)
        return url
    }

    private func allocated(_ url: URL) -> Int64 { (try? StoreMeasurement.allocatedBytes(at: url)) ?? -1 }

    func testTableDescribesClearPolicy() {
        XCTAssertEqual(StoreKind.allCases.filter(\.clearable), [.generatedStills, .transcriptRecognition, .suggestedCameras])
        XCTAssertEqual(locations.urls(for: .transcriptJobs).count, 2)
        XCTAssertTrue(locations.urls(for: .suggestedCameras).isEmpty)
        XCTAssertTrue(StoreKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.note.isEmpty })
    }

    @MainActor
    func testSuggestedCamerasKeyMatchesItsOwner() {
        XCTAssertEqual(StorageInventory.suggestedCamerasKey, EditorPreferences.LocalKey.transcriptSuggestedAngles.rawValue)
    }

    func testStandardLocationsNameTheRealStores() {
        // Paths only: nothing is read or measured.
        let standard = StorageLocations.standard
        XCTAssertEqual(standard.generatedStills?.path.hasSuffix("Caches/MPCut/GeneratedStills-v1"), true)
        XCTAssertEqual(standard.transcriptJobs.map(\.lastPathComponent), [".transcript-jobs", "TranscriptJobs"])
        XCTAssertEqual(standard.untitledDrafts, ProjectDraft.autosaveDirectory)
        XCTAssertTrue(standard.agentReceipts.path.hasSuffix("File Job Receipts/v1")
                      || ProcessInfo.processInfo.environment["MPCUT_FILE_RECEIPT_DIRECTORY"] != nil)
    }

    func testSizesCountEachStoreOnce() async throws {
        let draft = try write("Drafts/\(UUID().uuidString)/Untitled.cut")
        let desktopJob = try write("Drafts/.transcript-jobs/job/record.json", bytes: 20_000)
        let cliJob = try write("TranscriptJobs/job/record.json", bytes: 30_000)
        let still = try write("Stills/0/\(String(repeating: "a", count: 64))-mov/picture.mov", bytes: 40_000)
        let receipt = try write("Receipts/x/record.json", bytes: 1_000)
        defaults.set(Data(repeating: 1, count: 321), forKey: StorageInventory.suggestedCamerasKey)

        func size(_ kind: StoreKind) async throws -> Int64 {
            try await StorageInventory.size(of: kind, locations: locations, defaults: defaults)
        }
        let drafts = try await size(.untitledDrafts)
        let jobs = try await size(.transcriptJobs)
        let stills = try await size(.generatedStills)
        let receipts = try await size(.agentReceipts)
        let cameras = try await size(.suggestedCameras)
        let claims = try await size(.transcriptRecognition)
        XCTAssertEqual(drafts, allocated(draft))
        XCTAssertEqual(jobs, allocated(desktopJob) + allocated(cliJob))
        XCTAssertEqual(stills, allocated(still))
        XCTAssertEqual(receipts, allocated(receipt))
        XCTAssertEqual(cameras, 321)
        XCTAssertEqual(claims, 0)
        let none = try await StorageInventory.size(of: .suggestedCameras, locations: locations, defaults: nil)
        XCTAssertEqual(none, 0)
    }

    func testMeasurementStopsWhenCancelled() async throws {
        for index in 0..<50 { _ = try write("TranscriptJobs/\(index)/file") }
        XCTAssertThrowsError(try StorageInventory.measure(.transcriptJobs, locations: locations, defaults: nil, cancelled: { true }))
        let task = Task { try await StorageInventory.size(of: .transcriptJobs, locations: locations, defaults: nil) }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testClearSuggestedCamerasReportsBytes() async {
        defaults.set(Data(repeating: 1, count: 99), forKey: StorageInventory.suggestedCamerasKey)
        defaults.set(true, forKey: "unrelated")
        let result = await StorageInventory.clear(.suggestedCameras, locations: locations, defaults: defaults)
        XCTAssertEqual(result.reclaimedBytes, 99)
        XCTAssertNil(defaults.object(forKey: StorageInventory.suggestedCamerasKey))
        XCTAssertTrue(defaults.bool(forKey: "unrelated"))
        let nothing = await StorageInventory.clear(.suggestedCameras, locations: locations, defaults: nil)
        XCTAssertEqual(nothing, StoreClearResult())
    }

    func testClearRoutesToTheStoreAndRefusesOthers() async throws {
        let still = try write("Stills/2/\(String(repeating: "b", count: 64))-mov/picture.mov")
        let bytes = allocated(still.deletingLastPathComponent())
        let draft = try write("Drafts/\(UUID().uuidString)/Untitled.cut")
        let job = try write("TranscriptJobs/job/record.json")
        let receipt = try write("Receipts/x/record.json")
        let stills = await StorageInventory.clear(.generatedStills, locations: locations, defaults: defaults)
        XCTAssertEqual(stills.reclaimedBytes, bytes)
        XCTAssertFalse(files.fileExists(atPath: still.path))
        for kind in [StoreKind.untitledDrafts, .transcriptJobs, .agentReceipts] {
            let result = await StorageInventory.clear(kind, locations: locations, defaults: defaults)
            XCTAssertEqual(result, StoreClearResult(), kind.rawValue)
        }
        for kept in [draft, job, receipt] { XCTAssertTrue(files.fileExists(atPath: kept.path)) }
    }

    func testClearRecognitionSkipsAClaimInUse() async throws {
        let claims = try XCTUnwrap(locations.transcriptRecognition)
        let id = String(repeating: "c", count: 64)
        let lock = try write("Claims/\(id)", bytes: 0)
        let exchange = try write("Claims/\(id).mpx")
        let descriptor = open(lock.path, O_RDWR)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { close(descriptor) }
        let result = await StorageInventory.clear(.transcriptRecognition, locations: locations, defaults: defaults)
        XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertEqual(result.skipped.map(\.url.lastPathComponent), [id])
        XCTAssertTrue(files.fileExists(atPath: exchange.path))
        XCTAssertTrue(claims.path.hasPrefix(root.path))
    }
}
